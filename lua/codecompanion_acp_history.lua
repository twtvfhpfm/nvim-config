--- Persist ACP chat history under <project>/.acp and rehydrate on /resume.
--- Each ChatDone appends new chat.messages entries to the JSON file (no full overwrite).
--- Restored entries are display-only (add_buf_message), so they are never sent
--- as prompt payload.

local M = {}
local config = require("codecompanion.config")

local CONFIG = {
  base_dir = ".acp/codecompanion/sessions",
  version = 1,
}

local USER_ROLE = "user"
local SYSTEM_ROLE = "system"

---@param path string
local function ensure_parent(path)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    vim.fn.mkdir(dir, "p")
  end
end

---@param chat CodeCompanion.Chat
---@return string
local function project_root(chat)
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
  return vim.fn.getcwd()
end

---@param chat CodeCompanion.Chat
---@param session_id string
---@return string
local function history_file(chat, session_id)
  return vim.fs.joinpath(project_root(chat), CONFIG.base_dir, session_id .. ".json")
end

---@param msg table
---@return boolean
local function is_visible_message(msg)
  if type(msg) ~= "table" then
    return false
  end
  if msg.role == SYSTEM_ROLE then
    return false
  end
  if msg.opts and msg.opts.visible == false then
    return false
  end
  return type(msg.content) == "string"
end

---@param existing table[]
---@param incoming table[]
---@param prev_stack_count number Messages already merged from chat.messages
---@return table[] merged
---@return number new_stack_count
local function append_stack_messages(existing, incoming, prev_stack_count)
  local merged = vim.deepcopy(existing)
  if #incoming < prev_stack_count then
    prev_stack_count = 0
  end
  for i = prev_stack_count + 1, #incoming do
    merged[#merged + 1] = incoming[i]
  end
  return merged, #incoming
end

---@param chat CodeCompanion.Chat
---@return table[]
local function snapshot_messages(chat)
  local out = {}
  for _, msg in ipairs(chat.messages or {}) do
    if is_visible_message(msg) then
      out[#out + 1] = {
        role = msg.role,
        content = msg.content,
      }
    end
  end
  return out
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

---@param path string
---@param payload table
local function write_json(path, payload)
  local encoded = vim.json.encode(payload)
  ensure_parent(path)
  vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
end

---@param bufnr number
---@return CodeCompanion.Chat|nil
local function get_chat(bufnr)
  local ok, cc = pcall(require, "codecompanion")
  if not ok then
    return nil
  end
  local chat = cc.buf_get_chat(bufnr)
  if type(chat) ~= "table" then
    return nil
  end
  if not chat.adapter or chat.adapter.type ~= "acp" then
    return nil
  end
  return chat
end

---@param chat CodeCompanion.Chat
---@param session_id string
local function save_history(chat, session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return
  end

  local path = history_file(chat, session_id)
  local existing = read_json(path) or {}
  local stored = type(existing.messages) == "table" and existing.messages or {}
  local incoming = snapshot_messages(chat)
  local prev_stack = type(existing.stack_snapshot_count) == "number" and existing.stack_snapshot_count or 0
  local messages, stack_snapshot_count = append_stack_messages(stored, incoming, prev_stack)

  local payload = {
    version = CONFIG.version,
    session_id = session_id,
    chat_id = chat.id,
    cwd = project_root(chat),
    saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    stack_snapshot_count = stack_snapshot_count,
    messages = messages,
  }

  write_json(path, payload)
end

---Rehydrate chat buffer from <project>/.acp/codecompanion/sessions/<session_id>.json.
---@param chat CodeCompanion.Chat
---@param session_id string
---@return boolean restored
function M.restore_for_session(chat, session_id)
  if type(session_id) ~= "string" or session_id == "" then
    return false
  end

  local payload = read_json(history_file(chat, session_id))
  if not payload or type(payload.messages) ~= "table" then
    return false
  end

  chat:clear()

  for _, msg in ipairs(payload.messages) do
    if type(msg) == "table" and type(msg.content) == "string" then
      local role = msg.role == USER_ROLE and USER_ROLE or config.constants.LLM_ROLE
      local opts = role == config.constants.LLM_ROLE and { type = chat.MESSAGE_TYPES.LLM_MESSAGE } or nil
      chat:add_buf_message({ role = role, content = msg.content }, opts)
    end
  end

  chat:ready_for_input()
  return true
end

function M.setup()
  local aug = vim.api.nvim_create_augroup("codecompanion_acp_history", { clear = true })

  -- utils.fire("ChatDone") → pattern "CodeCompanionChatDone" (must be full name on nvim 0.11+)
  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionChatDone",
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr
      if not bufnr then
        return
      end
      local chat = get_chat(bufnr)
      if not chat or not chat.acp_connection then
        return
      end
      save_history(chat, chat.acp_connection.session_id)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = aug,
    pattern = "CodeCompanionACPChatRestored",
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr
      local session_id = ev.data and ev.data.session_id
      if not bufnr or not session_id then
        return
      end
      local chat = get_chat(bufnr)
      if not chat then
        return
      end
      M.restore_for_session(chat, session_id)
    end,
  })
end

return M
