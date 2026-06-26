--- ACP (cursor_cli) model switch via cursor-agent --model flag.
--- session/set_config_option only updates config UI; inference requires --model at startup.
--- On switch: save session id → restart agent with --model → session/load to keep agent context.

local M = {}

local adapters = require("codecompanion.adapters")
local utils = require("codecompanion.utils")

---@param chat CodeCompanion.Chat
---@return string
local function chat_cwd(chat)
  local ok, ctx = pcall(function()
    return chat:make_system_prompt_context()
  end)
  if ok and type(ctx) == "table" then
    if type(ctx.cwd) == "string" and ctx.cwd ~= "" then
      return ctx.cwd
    end
    if type(ctx.project_root) == "string" and ctx.project_root ~= "" then
      return ctx.project_root
    end
  end
  return vim.fn.getcwd()
end

---@param cwd string
---@param fn fun(): any
---@return any
local function with_cwd(cwd, fn)
  local prev = vim.fn.getcwd()
  local changed = cwd ~= prev
  if changed then
    vim.fn.chdir(cwd)
  end
  local ok, result = pcall(fn)
  if changed then
    vim.fn.chdir(prev)
  end
  if not ok then
    error(result)
  end
  return result
end

---@param conn CodeCompanion.ACP.Connection|nil
---@param model_id string
---@return string
local function model_cli_name(conn, model_id)
  if model_id == "default[]" then
    return "auto"
  end
  if conn then
    local models = conn:get_models()
    if models and models.availableModels then
      for _, entry in ipairs(models.availableModels) do
        if entry.modelId == model_id and entry.name and entry.name ~= "" then
          return entry.name
        end
      end
    end
  end
  return model_id:match("^([^%[]+)") or model_id
end

---@param chat CodeCompanion.Chat
---@return string
local function agent_bin(chat)
  local cmd = chat.adapter.commands.selected or chat.adapter.commands.default
  return cmd and cmd[1] or "/home/xu/.local/bin/cursor-agent"
end

---@param chat CodeCompanion.Chat
---@param model_id string
---@param cli_name string
local function persist_model(chat, model_id, cli_name)
  chat.adapter.defaults = chat.adapter.defaults or {}
  chat.adapter.defaults.model = model_id
  chat.adapter.defaults.model_cli = cli_name
  chat.adapter.defaults.session_config_options = vim.tbl_deep_extend(
    "force",
    chat.adapter.defaults.session_config_options or {},
    { model = model_id }
  )
end

---@param chat CodeCompanion.Chat
---@param cli_name? string When nil/empty/"auto", omit --model (agent default).
local function set_agent_command(chat, cli_name)
  local bin = agent_bin(chat)
  if cli_name and cli_name ~= "" and cli_name:lower() ~= "auto" then
    chat.adapter.commands.selected = { bin, "--model", cli_name, "acp" }
  else
    chat.adapter.commands.selected = { bin, "--model", cli_name, "acp" }
  end
end

---@param chat CodeCompanion.Chat
---@return boolean
local function ensure_acp_ready(chat)
  if chat.adapter.defaults and chat.adapter.defaults.model_cli then
    set_agent_command(chat, chat.adapter.defaults.model_cli)
  end

  local handler = require("codecompanion.interactions.chat.acp.handler").new(chat)
  if not handler:ensure_connection() then
    return false
  end
  return handler:ensure_session()
end

---@param chat CodeCompanion.Chat
local function relink_session(chat)
  local conn = chat.acp_connection
  if not conn or not conn.session_id then
    return
  end
  require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(chat.bufnr, conn.session_id)
end

---Connect with --model, then session/load (preferred) or session/new.
---Does not modify the chat buffer.
---@param chat CodeCompanion.Chat
---@param saved_session_id? string
---@return boolean ok
---@return string|nil err
---@return boolean resumed
local function reconnect_and_resume(chat, saved_session_id)
  if chat.acp_connection then
    pcall(function()
      chat.acp_connection:disconnect()
    end)
    chat.acp_connection = nil
  end

  if chat.adapter.defaults and chat.adapter.defaults.model_cli then
    set_agent_command(chat, chat.adapter.defaults.model_cli)
  end

  local handler = require("codecompanion.interactions.chat.acp.handler").new(chat)
  if not handler:ensure_connection() then
    return false, "连接 ACP agent 失败", false
  end

  local conn = chat.acp_connection
  if not conn then
    return false, "ACP 连接为空", false
  end

  local cwd = chat_cwd(chat)

  if type(saved_session_id) == "string" and saved_session_id ~= "" and conn:can_load_session() then
    local loaded_id = saved_session_id
    local load_ok = with_cwd(cwd, function()
      -- load_session must be the first session RPC (same as codecompanion_acp_resume).
      conn.session_id = nil
      return conn:load_session(loaded_id)
    end)

    if load_ok and conn.session_id == saved_session_id then
      relink_session(chat)
      return true, nil, true
    end

    vim.notify(
      "session/load 未能恢复 "
        .. saved_session_id
        .. "，将创建新 session（本地 chat 不变）",
      vim.log.levels.WARN
    )
    conn.session_id = nil
  end

  local session_ok = with_cwd(cwd, function()
    return handler:ensure_session()
  end)

  if session_ok then
    relink_session(chat)
    return true, nil, false
  end

  return false, "创建 ACP session 失败", false
end

---@param chat CodeCompanion.Chat
---@param model_id string
---@return boolean ok
---@return string|nil err
---@return boolean resumed
local function apply_model(chat, model_id)
  if not ensure_acp_ready(chat) then
    return false, "ACP 未连接", false
  end

  local conn = chat.acp_connection
  local cli_name = model_cli_name(conn, model_id)
  local current_cli = chat.adapter.defaults and chat.adapter.defaults.model_cli
  local current_id = chat.adapter.defaults and chat.adapter.defaults.model

  if current_id == model_id and current_cli == cli_name and conn and conn.session_id then
    return true, nil, false
  end

  local saved_session_id = conn and conn.session_id or nil

  persist_model(chat, model_id, cli_name)
  set_agent_command(chat, cli_name)

  vim.notify(
    string.format(
      "正在以 --model %s 重启 ACP agent%s…",
      cli_name,
      saved_session_id and (" 并恢复 session " .. saved_session_id) or ""
    ),
    vim.log.levels.WARN
  )

  return reconnect_and_resume(chat, saved_session_id)
end

---@param chat CodeCompanion.Chat
local function sync_metadata_model_display(chat)
  local meta = _G.codecompanion_chat_metadata and _G.codecompanion_chat_metadata[chat.bufnr]
  if not meta or not meta.adapter then
    return
  end
  local cli = chat.adapter.defaults and chat.adapter.defaults.model_cli
  if cli and cli ~= "" then
    meta.adapter.model = cli
    if meta.config_options and meta.config_options.model then
      meta.config_options.model.name = cli
      meta.config_options.model.current = chat.adapter.defaults.model
    end
  end
end

---@param chat CodeCompanion.Chat
---@param args { model?: string }
---@return CodeCompanion.Chat
local function change_model_acp(chat, args)
  local model_id = args.model
  if type(model_id) ~= "string" or model_id == "" then
    return chat
  end

  local ok, err, resumed = apply_model(chat, model_id)
  chat:update_metadata()
  sync_metadata_model_display(chat)

  if ok then
    local cli = chat.adapter.defaults.model_cli or model_id
    local sid = chat.acp_connection and chat.acp_connection.session_id
    utils.fire("ChatModel", {
      adapter = adapters.make_safe(chat.adapter),
      bufnr = chat.bufnr,
      model = cli,
    })
    local msg = "模型已切换: " .. cli
    if resumed and sid then
      msg = msg .. "（已重启 ACP agent 并恢复 session " .. sid .. "）"
    elseif sid then
      msg = msg .. "（已重启 ACP agent，新 session: " .. sid .. "）"
    else
      msg = msg .. "（已重启 ACP agent）"
    end
    vim.notify(msg, vim.log.levels.INFO)
  else
    vim.notify("模型切换失败: " .. (err or "unknown"), vim.log.levels.ERROR)
  end

  return chat
end

function M.setup()
  local Chat = require("codecompanion.interactions.chat")
  local orig_change_model = Chat.change_model

  ---@param self CodeCompanion.Chat
  ---@param args { model?: string }
  function Chat:change_model(args)
    if self.adapter.type == "acp" then
      return change_model_acp(self, args)
    end
    return orig_change_model(self, args)
  end

  local change_adapter_mod = require("codecompanion.interactions.chat.keymaps.change_adapter")
  local orig_select_model = change_adapter_mod.select_model

  ---@param chat CodeCompanion.Chat
  function change_adapter_mod.select_model(chat)
    if chat.adapter.type == "acp" then
      if not ensure_acp_ready(chat) then
        vim.notify("ACP 尚未就绪，请稍后再切换模型", vim.log.levels.WARN)
        return
      end
    end
    return orig_select_model(chat)
  end
end

return M
