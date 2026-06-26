--- Pick a saved ACP session under <project>/.acp/codecompanion/sessions and resume by id.

local M = {}

local CONFIG = {
  base_dir = ".acp/codecompanion/sessions",
  preview_len = 72,
}

local USER_ROLE = "user"

local config = require("codecompanion.config")

local LOADING_STAGES = {
  preparing = "准备恢复会话",
  connecting = "正在连接 ACP agent",
  loading_agent = "正在从 agent 加载 session",
  restoring_local = "正在恢复本地历史到 buffer",
  finishing = "即将完成",
}

local SPINNER_FRAMES = { "● · ·", "· ● ·", "· · ●", "· ● ·" }

--- Virtual lines below buffer content (not EOL-attached _set_status).
local LOADING_FOOTER_NS = vim.api.nvim_create_namespace("codecompanion_acp_resume_loading")

---@type table<number, { session_id: string, stage: string, timer: userdata?, start_ns: number, buffer_shown: boolean, footer_mark?: number }>
local loading_by_chat = {}

---@param chat CodeCompanion.Chat
local function clear_loading_footer(chat)
  local state = loading_by_chat[chat.id]
  if state and state.footer_mark then
    pcall(vim.api.nvim_buf_del_extmark, chat.bufnr, LOADING_FOOTER_NS, state.footer_mark)
    state.footer_mark = nil
  end
end

---@param chat CodeCompanion.Chat
local function stop_loading(chat)
  local state = loading_by_chat[chat.id]
  if not state then
    return
  end
  if state.timer then
    pcall(function()
      state.timer:stop()
      state.timer:close()
    end)
  end
  chat:_clear_status()
  clear_loading_footer(chat)
  loading_by_chat[chat.id] = nil
end

---Show chat window and redraw before any blocking ACP RPC.
---@param chat CodeCompanion.Chat
local function open_chat_for_resume(chat)
  if not chat.ui:is_visible() then
    chat.ui:open()
  end
  pcall(function()
    require("codecompanion").restore(chat.bufnr)
  end)
  vim.cmd("redraw")
end

---@param chat CodeCompanion.Chat
---@param session_id string
local function ensure_loading_buffer(chat, session_id)
  local state = loading_by_chat[chat.id]
  if state and state.buffer_shown then
    return
  end

  open_chat_for_resume(chat)

  chat:clear()
  chat:add_buf_message({
    role = config.constants.LLM_ROLE,
    content = table.concat({
      "### 正在恢复历史会话",
      "",
      string.format("**Session:** `%s`", session_id),
      "",
      "连接 agent 并加载 transcript 可能需要十几秒，请稍候。",
      "",
      "_进度显示在下方独立状态区（非 Vim 底部 statusline）。_",
    }, "\n"),
  }, { type = chat.MESSAGE_TYPES.SYSTEM_MESSAGE })

  state = loading_by_chat[chat.id] or { session_id = session_id }
  state.buffer_shown = true
  state.session_id = session_id
  loading_by_chat[chat.id] = state

  if chat.ui and chat.ui.winnr and vim.api.nvim_win_is_valid(chat.ui.winnr) then
    local last = math.max(1, vim.api.nvim_buf_line_count(chat.bufnr))
    pcall(vim.api.nvim_win_set_cursor, chat.ui.winnr, { last, 0 })
  end
end

---@param chat CodeCompanion.Chat
---@param stage_key string
local function refresh_loading_status(chat, stage_key)
  local state = loading_by_chat[chat.id]
  if not state then
    return
  end

  if not vim.api.nvim_buf_is_valid(chat.bufnr) then
    stop_loading(chat)
    return
  end

  state.stage = stage_key
  local elapsed = 0
  if state.start_ns then
    elapsed = math.floor((vim.loop.hrtime() - state.start_ns) / 1e9)
  end
  local frame = SPINNER_FRAMES[(elapsed % #SPINNER_FRAMES) + 1]
  local label = LOADING_STAGES[stage_key] or stage_key
  local status = string.format("%s %s…", frame, label)
  local detail = string.format("已等待 %d 秒", elapsed)

  clear_loading_footer(chat)
  local anchor = math.max(0, vim.api.nvim_buf_line_count(chat.bufnr) - 1)
  state.footer_mark = vim.api.nvim_buf_set_extmark(chat.bufnr, LOADING_FOOTER_NS, anchor, 0, {
    virt_lines = {
      { { "", "Normal" } },
      { { "────────────────", "Comment" } },
      { { status, "CodeCompanionVirtualText" } },
      { { detail, "CodeCompanionChatSubtext" } },
    },
    virt_lines_above = false,
    priority = (vim.hl or vim.highlight).priorities.user + 20,
  })
end

---@param chat CodeCompanion.Chat
---@param session_id string
---@param stage_key string
local function start_loading(chat, session_id, stage_key)
  local state = loading_by_chat[chat.id]
  if not state then
    state = {
      session_id = session_id,
      stage = stage_key,
      start_ns = vim.loop.hrtime(),
      buffer_shown = false,
    }
    loading_by_chat[chat.id] = state
    state.timer = vim.uv.new_timer()
    state.timer:start(500, 500, vim.schedule_wrap(function()
      refresh_loading_status(chat, loading_by_chat[chat.id] and loading_by_chat[chat.id].stage or stage_key)
    end))
  end

  ensure_loading_buffer(chat, session_id)
  refresh_loading_status(chat, stage_key)
end

---@param chat? CodeCompanion.Chat
---@return string
local function project_root(chat)
  if chat then
    local ok, ctx = pcall(function()
      return chat:make_system_prompt_context()
    end)
    if ok and type(ctx) == "table" then
      if type(ctx.project_root) == "string" and ctx.project_root ~= "" then
        return ctx.project_root
      end
      if type(ctx.cwd) == "string" and ctx.cwd ~= "" then
        return ctx.cwd
      end
    end
  end
  return vim.fn.getcwd()
end

---@param chat? CodeCompanion.Chat
---@return string
local function sessions_dir(chat)
  return vim.fs.joinpath(project_root(chat), CONFIG.base_dir)
end

---@param path string
---@return table|nil
local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local lines = vim.fn.readfile(path)
  if not lines or vim.tbl_isempty(lines) then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

---Cwd recorded when the session was saved (agent-agnostic; used for session/load).
---@param session_id string
---@param chat? CodeCompanion.Chat
---@return string
local function session_cwd(session_id, chat)
  local local_path = vim.fs.joinpath(sessions_dir(chat), session_id .. ".json")
  local payload = read_json(local_path)
  if payload and type(payload.cwd) == "string" and payload.cwd ~= "" then
    return payload.cwd
  end

  return project_root(chat)
end

---Run fn under cwd, then restore the previous directory.
---@param cwd string
---@param fn fun(): any
---@return any
local function with_cwd(cwd, fn)
  local prev = vim.fn.getcwd()
  local changed = cwd ~= "" and cwd ~= prev
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

---Connect without async_utils.sync (RPC must not yield) and without ensure_session.
---@param chat CodeCompanion.Chat
---@return boolean
local function connect_acp_for_resume(chat)
  if chat.acp_connection and chat.acp_connection:is_ready() then
    return true
  end

  local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
  return ACPHandler.new(chat):ensure_connection()
end

---Skip Chat.new's scheduled create_acp_connection while we resume synchronously.
---@param chat CodeCompanion.Chat
---@param session_id string
local function mark_resume_pending(chat, session_id)
  chat._acp_resume_pending = session_id
end

---@param chat CodeCompanion.Chat
local function clear_resume_pending(chat)
  chat._acp_resume_pending = nil
end

local resume_patch_installed = false

local function ensure_resume_connection_patch()
  if resume_patch_installed then
    return
  end
  resume_patch_installed = true

  local helpers = require("codecompanion.interactions.chat.helpers")
  local orig = helpers.create_acp_connection
  helpers._acp_resume_orig = orig
  helpers.create_acp_connection = function(chat, cb)
    if chat._acp_resume_pending then
      if cb then
        vim.schedule(cb)
      end
      return
    end
    return orig(chat, cb)
  end
end

---@param text string
---@param max_len number
---@return string
local function truncate(text, max_len)
  text = vim.trim(text:gsub("%s+", " "))
  if #text <= max_len then
    return text
  end
  return text:sub(1, max_len - 1) .. "…"
end

---Convert UTC ISO8601 (e.g. 2026-05-28T01:30:18Z) to local time for display.
---@param iso string|nil
---@return string|nil
local function format_saved_at_local(iso)
  if type(iso) ~= "string" or iso == "" then
    return iso
  end
  local y, mo, d, h, mi, s = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not y then
    return iso
  end
  local ts = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  })
  local now = os.time()
  local offset = os.difftime(now, os.time(os.date("!*t", now)))
  return os.date("%Y-%m-%d %H:%M:%S", ts + offset)
end

---@param payload table
---@return string
local function preview_from_payload(payload)
  if type(payload.messages) ~= "table" then
    return ""
  end
  for _, msg in ipairs(payload.messages) do
    if type(msg) == "table" and msg.role == USER_ROLE and type(msg.content) == "string" then
      local line = msg.content:match("^[^\n]+") or msg.content
      if line ~= "" then
        return truncate(line, CONFIG.preview_len)
      end
    end
  end
  return ""
end

---@class CodeCompanionAcpSavedSession
---@field session_id string
---@field path string
---@field saved_at string|nil local time display
---@field saved_at_utc string|nil raw UTC for sorting
---@field preview string
---@field message_count number

---@return CodeCompanionAcpSavedSession[]
function M.list_saved_sessions()
  local dir = sessions_dir(nil)
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}
  end

  local sessions = {}
  for name, typ in vim.fs.dir(dir) do
    if typ == "file" and name:match("%.json$") then
      local session_id = name:gsub("%.json$", "")
      local path = vim.fs.joinpath(dir, name)
      local payload = read_json(path) or {}
      local messages = type(payload.messages) == "table" and payload.messages or {}
      local saved_at_utc = payload.saved_at
      sessions[#sessions + 1] = {
        session_id = payload.session_id or session_id,
        path = path,
        saved_at = format_saved_at_local(saved_at_utc),
        saved_at_utc = saved_at_utc,
        preview = preview_from_payload(payload),
        message_count = #messages,
      }
    end
  end

  table.sort(sessions, function(a, b)
    return (a.saved_at_utc or "") > (b.saved_at_utc or "")
  end)

  return sessions
end

---@param entry CodeCompanionAcpSavedSession
---@return string
local function format_entry(entry)
  local parts = {}
  if entry.saved_at then
    parts[#parts + 1] = "(" .. entry.saved_at .. ")"
  end
  if entry.preview ~= "" then
    parts[#parts + 1] = entry.preview
  else
    parts[#parts + 1] = entry.session_id
  end
  parts[#parts + 1] = string.format("[%d msgs]", entry.message_count)
  return table.concat(parts, " ")
end

---Always open a fresh chat for resume so we never reuse a stale ACP session.
---@param session_id string
---@return CodeCompanion.Chat
local function prepare_chat(session_id)
  ensure_resume_connection_patch()

  local Chat = require("codecompanion.interactions.chat")
  local context_utils = require("codecompanion.utils.context")
  local last = Chat.last_chat()

  if last and last.ui:is_visible() then
    last.ui:hide()
  end

  local chat = Chat.new({
    buffer_context = context_utils.get(vim.api.nvim_get_current_buf(), {}),
  })
  mark_resume_pending(chat, session_id)
  return chat
end

---@param chat CodeCompanion.Chat
---@param session_id string
local function resume_on_chat(chat, session_id)
  local utils = require("codecompanion.utils")
  local history = require("codecompanion_acp_history")

  local function do_resume()
    if not chat.acp_connection or not chat.acp_connection:is_ready() then
      stop_loading(chat)
      utils.notify("ACP connection is not ready", vim.log.levels.ERROR)
      return
    end

    if chat.cycle > 1 then
      stop_loading(chat)
      utils.notify("Open a new chat before resuming a session", vim.log.levels.WARN)
      return
    end

    local requested_id = session_id
    local agent_loaded = false
    local updates = {}
    local cwd = session_cwd(requested_id, chat)

    start_loading(chat, requested_id, "loading_agent")

    with_cwd(cwd, function()
      local can_load = chat.acp_connection:can_load_session()
      if not can_load then
        utils.notify("Agent 不支持 session/load；仅恢复本地聊天记录", vim.log.levels.WARN)
        return
      end

      -- Never call ensure_session here; load_session must be the first session RPC.
      chat.acp_connection.session_id = nil

      local ok = chat.acp_connection:load_session(requested_id, {
        on_session_update = function(update)
          updates[#updates + 1] = update
        end,
      })

      local active_id = chat.acp_connection.session_id
      agent_loaded = ok and active_id == requested_id

      if agent_loaded then
        local acp_commands = require("codecompanion.interactions.chat.acp.commands")
        acp_commands.link_buffer_to_session(chat.bufnr, active_id)
        if #updates > 0 then
          require("codecompanion.interactions.chat.acp.render").restore_session(chat, updates)
        end
      elseif ok then
        utils.notify(
          "Agent 创建了新 session（"
            .. (active_id or "?")
            .. "），未能加载 "
            .. requested_id
            .. "；仅恢复本地聊天记录",
          vim.log.levels.WARN
        )
      else
        utils.notify("ACP session/load 失败: " .. requested_id, vim.log.levels.ERROR)
      end
    end)

    start_loading(chat, requested_id, "restoring_local")

    local restored = history.restore_for_session(chat, requested_id)
    if not restored then
      utils.notify("无本地历史文件: " .. requested_id, vim.log.levels.WARN)
    end

    stop_loading(chat)
    open_chat_for_resume(chat)

    if agent_loaded then
      utils.notify("已恢复 agent 会话: " .. requested_id, vim.log.levels.INFO)
    elseif restored then
      utils.notify(
        "已恢复本地聊天记录: "
          .. requested_id
          .. "（agent 未绑定该 session，继续对话将使用新 session）",
        vim.log.levels.WARN
      )
    else
      utils.notify("恢复失败: " .. requested_id, vim.log.levels.ERROR)
    end
  end

  start_loading(chat, session_id, "connecting")
  if not connect_acp_for_resume(chat) then
    stop_loading(chat)
    utils.notify("无法连接 ACP agent", vim.log.levels.ERROR)
    clear_resume_pending(chat)
    return
  end

  do_resume()
  clear_resume_pending(chat)
end

---Resume an ACP session by id (agent load + local history rehydrate).
---@param session_id string
function M.resume(session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return
  end

  local chat = prepare_chat(session_id)
  local path = vim.fs.joinpath(sessions_dir(chat), session_id .. ".json")
  if vim.fn.filereadable(path) ~= 1 then
    clear_resume_pending(chat)
    vim.notify("No saved session file: " .. path, vim.log.levels.WARN)
    return
  end

  open_chat_for_resume(chat)
  start_loading(chat, session_id, "preparing")

  -- Defer blocking ACP work so the loading chat buffer paints immediately.
  vim.schedule(function()
    local ok, err = pcall(resume_on_chat, chat, session_id)
    if not ok then
      clear_resume_pending(chat)
      error(err)
    end
  end)
end

---List saved sessions under .acp/codecompanion/sessions and resume the chosen one.
function M.pick_and_resume()
  local sessions = M.list_saved_sessions()
  if #sessions == 0 then
    vim.notify("No saved sessions in " .. sessions_dir(nil), vim.log.levels.INFO)
    return
  end

  local choices = vim.tbl_map(format_entry, sessions)
  vim.ui.select(choices, {
    prompt = "Resume ACP session",
    kind = "codecompanion.nvim",
  }, function(_, idx)
    if not idx then
      return
    end
    M.resume(sessions[idx].session_id)
  end)
end

return M
