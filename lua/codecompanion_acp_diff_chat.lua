--- Force ACP tool/permission diffs into the CodeCompanion chat buffer.
--- threshold_for_chat only applies to approval_prompt.present_diff; ACP tool_call
--- lines are single-line updates, so we patch those paths here.

local M = {}

local DIFF_NS = vim.api.nvim_create_namespace("codecompanion_acp_diff_hl")
local diff_utils = require("codecompanion.diff.utils")

---@param path string|nil
---@return string|nil
local function ft_from_path(path)
  if not path or path == "" then
    return nil
  end
  local ft = vim.filetype.match({ filename = path })
  if ft and ft ~= "" and ft ~= "diff" then
    return ft
  end
  return nil
end

---@param lines string[]
---@param fence_line integer 1-based line index of opening fence
---@return string|nil
local function path_from_context(lines, fence_line)
  for j = fence_line - 1, 1, -1 do
    local path = lines[j]:match("`([^`]+)`")
    if path then
      return path
    end
  end
  return nil
end

---@param bufnr number
---@param start_row integer 0-based
---@param end_row integer 0-based
local function unfold_range(bufnr, start_row, end_row)
  if start_row > end_row then
    return
  end
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd(string.format("%d,%dfoldopen!", start_row + 1, end_row + 1))
  end)
end

---@param bufnr number
---@param row integer 0-based
---@param line string
---@param ft string|nil
local function apply_syntax_extmarks(bufnr, row, line, ft)
  if not ft or line == "" then
    return
  end
  if line:match("^@@") then
    return
  end

  local marker = line:sub(1, 1)
  if marker ~= "+" and marker ~= "-" and marker ~= " " then
    return
  end

  local code = line:sub(2)
  if code == "" then
    return
  end

  local vl = diff_utils.create_vl(code, { ft = ft })
  local segments = vl and vl[1]
  if not segments then
    return
  end

  local col = 1
  for _, segment in ipairs(segments) do
    local text = segment[1]
    local hl = segment[2]
    if type(hl) == "table" then
      hl = hl[1]
    end
    if text and text ~= "" then
      if hl and hl ~= "Normal" then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_NS, row, col, {
          end_col = col + #text,
          hl_group = hl,
          hl_mode = "combine",
          priority = 120,
        })
      end
      col = col + #text
    end
  end
end

---Apply diff line colors and optional in-line syntax highlighting.
---@param bufnr number
function M.highlight_diff_blocks(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, DIFF_NS, 0, -1)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local i = 1
  while i <= #lines do
    if lines[i]:match("^`````+diff") then
      local path = path_from_context(lines, i)
      local ft = ft_from_path(path)
      local body_start = i
      i = i + 1
      while i <= #lines and not lines[i]:match("^`````+%s*$") do
        local line = lines[i]
        local row = i - 1
        local hl
        if line:match("^@@") then
          hl = "DiffText"
        elseif line:match("^%+") and not line:match("^%+%+%+") then
          hl = "DiffAdd"
        elseif line:match("^%-") and not line:match("^%-%-%-") then
          hl = "DiffDelete"
        end
        if hl then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_NS, row, 0, {
            line_hl_group = hl,
            priority = 100,
          })
        end
        apply_syntax_extmarks(bufnr, row, line, ft)
        i = i + 1
      end
      unfold_range(bufnr, body_start, i - 1)
    else
      i = i + 1
    end
  end
end

local function schedule_diff_highlight(bufnr)
  vim.schedule(function()
    M.highlight_diff_blocks(bufnr)
  end)
end

local function find_diff(tool_call)
  if type(tool_call) ~= "table" or type(tool_call.content) ~= "table" then
    return nil
  end
  for _, block in ipairs(tool_call.content) do
    if block and block.type == "diff" then
      return block
    end
  end
end

local function unified_diff(diff_block)
  if not diff_block then
    return nil
  end
  local old = type(diff_block.oldText) == "string" and diff_block.oldText or ""
  local new = type(diff_block.newText) == "string" and diff_block.newText or ""
  if old == "" and new == "" then
    return nil
  end
  local text = diff_utils.unified(
    vim.split(old, "\n", { plain = true }),
    vim.split(new, "\n", { plain = true })
  )
  if not text or text == "" then
    return nil
  end
  return text
end

local function diff_chat_block(diff_block)
  local text = unified_diff(diff_block)
  if not text then
    return nil
  end
  return ("`````diff\n%s\n`````"):format(text)
end

function M.setup()
  local config = require("codecompanion.config")

  local hl_group = vim.api.nvim_create_augroup("codecompanion_acp_diff_hl", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = hl_group,
    pattern = { "CodeCompanionChatDone", "CodeCompanionToolsFinished", "CodeCompanionChatRestored" },
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr
      if bufnr and vim.bo[bufnr].filetype == "codecompanion" then
        schedule_diff_highlight(bufnr)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = hl_group,
    pattern = "*",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "codecompanion" then
        schedule_diff_highlight(ev.buf)
      end
    end,
  })

  -- 1) Permission UI: always embed diff in chat (not only when changed_lines <= threshold)
  local approval = require("codecompanion.interactions.chat.helpers.approval_prompt")
  if not approval._cc_diff_chat_patched then
    approval._cc_diff_chat_patched = true
    local orig_present = approval.present_diff
    approval.present_diff = function(opts)
      local block = diff_chat_block({
        oldText = table.concat(opts.from_lines or {}, "\n"),
        newText = table.concat(opts.to_lines or {}, "\n"),
      })
      if block then
        local ret = opts.approve({
          title = opts.title,
          prompt = block,
        })
        if opts.chat_bufnr then
          schedule_diff_highlight(opts.chat_bufnr)
        end
        return ret
      end
      return orig_present(opts)
    end
  end

  -- 2) ACP allow_always (g1): persist locally and auto-approve follow-up requests.
  -- Built-in tools call Approvals:always(); ACP only forwards allow_always to the agent,
  -- so cursor-agent may keep re-prompting unless we cache approvals on the client.
  local request_permission = require("codecompanion.interactions.chat.acp.request_permission")
  if not request_permission._cc_approvals_patched then
    request_permission._cc_approvals_patched = true
    local Approvals = require("codecompanion.interactions.chat.tools.approvals")
    local orig_confirm = request_permission.confirm

    ---@param options table[]|nil
    ---@param kind string
    ---@return string|nil
    local function option_id_for_kind(options, kind)
      for _, opt in ipairs(options or {}) do
        if opt.kind == kind then
          return opt.optionId
        end
      end
    end

    ---@param bufnr number
    ---@param tool_name string|nil
    ---@return boolean
    local function acp_tool_approved(bufnr, tool_name)
      if Approvals:is_approved(bufnr) then
        return true
      end
      if tool_name then
        return Approvals:is_approved(bufnr, { tool_name = tool_name })
      end
      return false
    end

    function request_permission.confirm(chat, request)
      local tool_name = request.tool_call and request.tool_call.kind

      if acp_tool_approved(chat.bufnr, tool_name) then
        local allow_once = option_id_for_kind(request.options, "allow_once")
        if allow_once then
          request.respond(allow_once, false)
          return
        end
      end

      local orig_respond = request.respond
      request.respond = function(option_id, cancelled)
        if not cancelled and option_id and tool_name then
          for _, opt in ipairs(request.options or {}) do
            if opt.optionId == option_id and opt.kind == "allow_always" then
              Approvals:always(chat.bufnr, { tool_name = tool_name })
              break
            end
          end
        end
        return orig_respond(option_id, cancelled)
      end

      return orig_confirm(chat, request)
    end
  end

  -- 3) ACP tool_call: append full diff when the call completes (tool line stays one line)
  local ACPHandler = require("codecompanion.interactions.chat.acp.handler")
  if not ACPHandler._cc_diff_chat_patched then
    ACPHandler._cc_diff_chat_patched = true
    local orig_process = ACPHandler.process_tool_call
    function ACPHandler:process_tool_call(tool_call)
      orig_process(self, tool_call)
      if tool_call.status ~= "completed" then
        return
      end
      local id = tool_call.toolCallId
      if not id then
        return
      end
      self._diff_in_chat = self._diff_in_chat or {}
      if self._diff_in_chat[id] then
        return
      end
      local block = find_diff(tool_call)
      local content = diff_chat_block(block)
      if not content then
        return
      end
      self._diff_in_chat[id] = true
      local path = block.path and vim.fn.fnamemodify(block.path, ":.") or "file"
      -- Title must not start with "**" at col 0: completed tool icons use
      -- virt_text overlay by default and cover ~4 cells ("**Dif" → looks like "f for").
      self.chat:add_buf_message({
        role = config.constants.LLM_ROLE,
        content = ("    Diff for `%s`\n\n%s"):format(path, content),
      }, {
        type = self.chat.MESSAGE_TYPES.TOOL_MESSAGE,
        tools = { call_id = id .. ":diff" },
        virt_text_pos = "inline",
        -- Prevent CodeCompanion from auto-folding this tool output block
        status = "completed",
      })
      schedule_diff_highlight(self.chat.bufnr)
    end
  end
end

return M
