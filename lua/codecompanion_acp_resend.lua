--- Fix ACP resend after cancel (q): buffer edits must update unsent user messages.
--- Without this, Ctrl-S → q → edit → Ctrl-S still sends the first prompt because
--- `header_line` points past the user block and `self.messages` keeps stale content.

local M = {}

local config = require("codecompanion.config")
local parser = require("codecompanion.interactions.chat.parser")
local tokens = require("codecompanion.utils.tokens")

local USER_ROLE = config.constants.USER_ROLE

---@param messages table
---@return integer|nil idx
---@return table|nil msg
local function last_unsent_user(messages)
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.role == USER_ROLE then
      if msg._meta and not msg._meta.sent then
        return i, msg
      end
      return nil
    end
  end
  return nil
end

---@param chat CodeCompanion.Chat
---@return { content: string }|nil
local function parse_user_input(chat)
  local parsed = parser.messages(chat, chat.header_line)
  if parsed and parsed.content and parsed.content ~= "" then
    return parsed
  end
  return parser.messages(chat, 1)
end

---@param chat CodeCompanion.Chat
---@return boolean updated
local function sync_unsent_user_from_buffer(chat)
  local _, msg = last_unsent_user(chat.messages)
  if not msg then
    return false
  end

  local parsed = parse_user_input(chat)
  if not parsed or parsed.content == "" then
    return false
  end

  msg.content = parsed.content
  if msg._meta then
    msg._meta.estimated_tokens = tokens.calculate(parsed.content)
  end
  return true
end

---@param chat CodeCompanion.Chat
local function fix_header_line_for_resend(chat)
  local header = parser.headers(chat)
  if header then
    chat.header_line = header + 1
  end
end

---@param chat CodeCompanion.Chat
---@return boolean
local function is_acp_chat(chat)
  return chat and chat.adapter and chat.adapter.type == "acp"
end

function M.setup()
  local Chat = require("codecompanion.interactions.chat")
  if Chat._acp_resend_patched then
    return
  end
  Chat._acp_resend_patched = true

  local orig_submit = Chat.submit
  ---@diagnostic disable-next-line: duplicate-set-field
  function Chat:submit(opts)
    opts = opts or {}

    if is_acp_chat(self) and not opts.auto_submit and not opts.regenerate and self._acp_cancelled_pending_resend then
      sync_unsent_user_from_buffer(self)
      local parsed = parse_user_input(self)
      if parsed and parsed.content ~= "" then
        self._acp_resend_update = true
      end
      self._acp_cancelled_pending_resend = nil
    end

    return orig_submit(self, opts)
  end

  local orig_add_message = Chat.add_message
  ---@diagnostic disable-next-line: duplicate-set-field
  function Chat:add_message(data, opts)
    if self._acp_resend_update and data.role == USER_ROLE then
      local _, msg = last_unsent_user(self.messages)
      self._acp_resend_update = nil
      if msg then
        msg.content = data.content
        if msg._meta then
          msg._meta.estimated_tokens = type(data.content) == "string" and tokens.calculate(data.content) or nil
        end
        return self
      end
    end
    return orig_add_message(self, data, opts)
  end

  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("codecompanion_acp_resend", { clear = true }),
    pattern = "CodeCompanionChatStopped",
    callback = function(ev)
      local ok, cc = pcall(require, "codecompanion")
      if not ok then
        return
      end
      local chat = cc.buf_get_chat(ev.data.bufnr)
      if not is_acp_chat(chat) then
        return
      end

      if chat._last_role == USER_ROLE and last_unsent_user(chat.messages) then
        chat._acp_cancelled_pending_resend = true
        fix_header_line_for_resend(chat)
      end
    end,
  })
end

return M
