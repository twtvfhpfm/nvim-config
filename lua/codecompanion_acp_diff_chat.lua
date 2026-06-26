--- Force ACP tool/permission diffs into the CodeCompanion chat buffer.
--- threshold_for_chat only applies to approval_prompt.present_diff; ACP tool_call
--- lines are single-line updates, so we patch those paths here.

local M = {}

local DIFF_LINE_NS = vim.api.nvim_create_namespace("codecompanion_acp_diff_line_hl")
local DIFF_SYNTAX_NS = vim.api.nvim_create_namespace("codecompanion_acp_diff_syntax_hl")
local diff_utils = require("codecompanion.diff.utils")

local DEBOUNCE_MS = 50
local pending_highlight = {} ---@type table<number, { generation: number, force: boolean }>
local buf_state = {} ---@type table<number, { fingerprint: string, blocks: table<string, DiffBlock>, folded: table<string, boolean>, syntax_rows: table<number, boolean> }>

---@class DiffBlock
---@field id string
---@field start_row integer 0-based, opening fence
---@field end_row integer 0-based, closing fence
---@field path string|nil
---@field ft string|nil

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
---@return number|nil
local function find_win_for_buf(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
end

---@param bufnr number
---@param row integer 0-based
---@return boolean
local function is_inside_closed_fold(bufnr, row)
  local lnum = row + 1
  local ok, closed = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.foldclosed(lnum)
  end)
  return ok and closed ~= -1
end

---@param bufnr number
---@param start_row integer 0-based
---@param end_row integer 0-based
local function fold_diff_range(bufnr, start_row, end_row)
  if start_row >= end_row then
    return
  end
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd(string.format("%d,%dfold", start_row + 1, end_row + 1))
  end)
end

---@param line string
---@return string|nil
local function diff_line_hl_group(line)
  if line:match("^@@") then
    return "DiffText"
  end
  if line:match("^%+") and not line:match("^%+%+%+") then
    return "DiffAdd"
  end
  if line:match("^%-") and not line:match("^%-%-%-") then
    return "DiffDelete"
  end
end

---@param line string
---@return string|nil code without diff marker
local function diff_code_line(line)
  if line:match("^@@") or line == "" then
    return nil
  end
  local marker = line:sub(1, 1)
  if marker ~= "+" and marker ~= "-" and marker ~= " " then
    return nil
  end
  local code = line:sub(2)
  if code == "" then
    return nil
  end
  return code
end

---@param bufnr number
---@param row integer 0-based
---@param segments table
local function set_syntax_extmarks(bufnr, row, segments)
  local col = 1
  for _, segment in ipairs(segments) do
    local text = segment[1]
    local hl = segment[2]
    if type(hl) == "table" then
      hl = hl[1]
    end
    if text and text ~= "" then
      if hl and hl ~= "Normal" then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_SYNTAX_NS, row, col, {
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

---@param bufnr number
---@param entries { row: integer, code: string }[]
---@param ft string|nil
---@return integer[] highlighted_rows
local function apply_batch_syntax_extmarks(bufnr, entries, ft)
  if not ft or #entries == 0 then
    return {}
  end

  local codes = {}
  for _, entry in ipairs(entries) do
    codes[#codes + 1] = entry.code
  end

  local vl = diff_utils.create_vl(table.concat(codes, "\n"), { ft = ft })
  if not vl then
    return {}
  end

  local highlighted = {}
  for idx, entry in ipairs(entries) do
    local segments = vl[idx]
    if segments then
      set_syntax_extmarks(bufnr, entry.row, segments)
      highlighted[#highlighted + 1] = entry.row
    end
  end
  return highlighted
end

---@param lines string[]
---@return DiffBlock[]
local function find_diff_blocks(lines)
  local blocks = {}
  local i = 1
  while i <= #lines do
    if lines[i]:match("^`````+diff") then
      local path = path_from_context(lines, i)
      local start_row = i - 1
      local id = string.format("%d:%s", start_row, path or "")
      i = i + 1
      while i <= #lines and not lines[i]:match("^`````+%s*$") do
        i = i + 1
      end
      local end_row = i - 1
      if i <= #lines and lines[i]:match("^`````+%s*$") then
        end_row = i - 1
      end
      blocks[#blocks + 1] = {
        id = id,
        start_row = start_row,
        end_row = end_row,
        path = path,
        ft = ft_from_path(path),
      }
      if i <= #lines and lines[i]:match("^`````+%s*$") then
        i = i + 1
      end
    else
      i = i + 1
    end
  end
  return blocks
end

---@param blocks DiffBlock[]
---@return string
local function blocks_fingerprint(blocks)
  local parts = {}
  for _, block in ipairs(blocks) do
    parts[#parts + 1] = string.format("%s:%d-%d", block.id, block.start_row, block.end_row)
  end
  return table.concat(parts, "|")
end

---@param bufnr number
---@param start_row integer 0-based
---@param end_row integer 0-based
local function clear_line_extmarks(bufnr, start_row, end_row)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, DIFF_LINE_NS, start_row, end_row + 1)
end

---@param bufnr number
---@param start_row integer 0-based
---@param end_row integer 0-based
local function clear_syntax_extmarks(bufnr, start_row, end_row)
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, DIFF_SYNTAX_NS, start_row, end_row + 1)
end

---@param bufnr number
---@param block DiffBlock
---@param lines string[]
local function apply_line_highlights(bufnr, block, lines)
  for row = block.start_row, block.end_row do
    local line = lines[row + 1]
    if line then
      local hl = diff_line_hl_group(line)
      if hl then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_LINE_NS, row, 0, {
          line_hl_group = hl,
          priority = 100,
        })
      end
    end
  end
end

---@param bufnr number
---@param blocks DiffBlock[]
---@param lines string[]
---@param visible_start integer 0-based
---@param visible_end integer 0-based
---@param st table
local function highlight_syntax_viewport(bufnr, blocks, lines, visible_start, visible_end, st)
  st.syntax_rows = st.syntax_rows or {}

  for _, block in ipairs(blocks) do
    if not block.ft then
      goto continue
    end

    local batch = {}
    for row = math.max(block.start_row, visible_start), math.min(block.end_row, visible_end) do
      if is_inside_closed_fold(bufnr, row) then
        if st.syntax_rows[row] then
          pcall(vim.api.nvim_buf_clear_namespace, bufnr, DIFF_SYNTAX_NS, row, row + 1)
          st.syntax_rows[row] = nil
        end
      else
        if not st.syntax_rows[row] then
          local line = lines[row + 1]
          local code = line and diff_code_line(line)
          if code then
            batch[#batch + 1] = { row = row, code = code }
          end
        end
      end
    end

    if #batch > 0 then
      local highlighted = apply_batch_syntax_extmarks(bufnr, batch, block.ft)
      for _, row in ipairs(highlighted) do
        st.syntax_rows[row] = true
      end
    end

    ::continue::
  end
end

---@param bufnr number
---@param blocks DiffBlock[]
---@param lines string[]
---@param st table
local function highlight_dirty_blocks(bufnr, blocks, lines, st)
  local prev_blocks = st.blocks or {}
  local current_ids = {}

  for _, block in ipairs(blocks) do
    current_ids[block.id] = true
    local prev = prev_blocks[block.id]
    local dirty = not prev or prev.start_row ~= block.start_row or prev.end_row ~= block.end_row
    if dirty then
      clear_line_extmarks(bufnr, block.start_row, block.end_row)
      clear_syntax_extmarks(bufnr, block.start_row, block.end_row)
      for row = block.start_row, block.end_row do
        st.syntax_rows[row] = nil
      end
      apply_line_highlights(bufnr, block, lines)
      if not st.folded[block.id] then
        fold_diff_range(bufnr, block.start_row, block.end_row)
        st.folded[block.id] = true
      end
    end
  end

  for id, prev in pairs(prev_blocks) do
    if not current_ids[id] then
      clear_line_extmarks(bufnr, prev.start_row, prev.end_row)
      clear_syntax_extmarks(bufnr, prev.start_row, prev.end_row)
      for row = prev.start_row, prev.end_row do
        st.syntax_rows[row] = nil
      end
      st.folded[id] = nil
    end
  end

  local indexed = {}
  for _, block in ipairs(blocks) do
    indexed[block.id] = block
  end
  st.blocks = indexed
end

---@param bufnr number
---@return integer visible_start 0-based
---@return integer visible_end 0-based
local function visible_row_range(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return 0, -1
  end

  local win = find_win_for_buf(bufnr)
  if not win then
    return 0, line_count - 1
  end

  local w0, w1
  local ok = pcall(vim.api.nvim_win_call, win, function()
    w0 = vim.fn.line("w0") - 1
    w1 = vim.fn.line("w$") - 1
  end)
  if not ok or w0 == nil or w1 == nil then
    return 0, line_count - 1
  end
  return w0, w1
end

---Expand viewport to include open (unfolded) manual folds.
---@param bufnr number
---@param visible_start integer 0-based
---@param visible_end integer 0-based
---@return integer start_row 0-based
---@return integer end_row 0-based
local function syntax_row_range(bufnr, visible_start, visible_end)
  local start_row, end_row = visible_start, visible_end
  local win = find_win_for_buf(bufnr)
  if not win then
    return start_row, end_row
  end

  pcall(vim.api.nvim_win_call, win, function()
    ---@param lnum integer 1-based
    local function merge_open_fold(lnum)
      if vim.fn.foldlevel(lnum) == 0 then
        return
      end
      local level = vim.fn.foldlevel(lnum)
      local fs = lnum
      while fs > 1 and vim.fn.foldlevel(fs - 1) >= level do
        fs = fs - 1
      end
      local last = vim.api.nvim_buf_line_count(bufnr)
      local fe = lnum
      while fe < last and vim.fn.foldlevel(fe + 1) >= level do
        fe = fe + 1
      end
      if vim.fn.foldclosed(fs) == -1 then
        start_row = math.min(start_row, fs - 1)
        end_row = math.max(end_row, fe - 1)
      end
    end

    merge_open_fold(vim.api.nvim_win_get_cursor(0)[1])

    for lnum = visible_start + 1, visible_end + 1 do
      if vim.fn.foldlevel(lnum) > vim.fn.foldlevel(lnum - 1) then
        merge_open_fold(lnum)
      end
    end
  end)

  return start_row, end_row
end

---Apply diff line colors and optional in-line syntax highlighting.
---@param bufnr number
---@param opts? { force?: boolean }
function M.highlight_diff_blocks(bufnr, opts)
  opts = opts or {}
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = find_diff_blocks(lines)
  local fingerprint = blocks_fingerprint(blocks)

  local st = buf_state[bufnr]
  if not st then
    st = { fingerprint = "", blocks = {}, folded = {}, syntax_rows = {} }
    buf_state[bufnr] = st
  end

  local visible_start, visible_end = visible_row_range(bufnr)
  local syn_start, syn_end = syntax_row_range(bufnr, visible_start, visible_end)

  if not opts.force and st.fingerprint == fingerprint and next(st.blocks) ~= nil then
    if syn_end >= syn_start then
      highlight_syntax_viewport(bufnr, blocks, lines, syn_start, syn_end, st)
    end
    return
  end

  if opts.force or st.fingerprint ~= fingerprint then
    highlight_dirty_blocks(bufnr, blocks, lines, st)
    st.fingerprint = fingerprint
  end

  if syn_end >= syn_start then
    highlight_syntax_viewport(bufnr, blocks, lines, syn_start, syn_end, st)
  end
end

---@param bufnr number
---@param opts? { force?: boolean }
local function schedule_diff_highlight(bufnr, opts)
  opts = opts or {}
  local pending = pending_highlight[bufnr]
  if not pending then
    pending = { generation = 0, force = false }
    pending_highlight[bufnr] = pending
  end
  pending.generation = pending.generation + 1
  pending.force = pending.force or opts.force or false
  local generation = pending.generation

  vim.defer_fn(function()
    local current = pending_highlight[bufnr]
    if not current or current.generation ~= generation then
      return
    end
    pending_highlight[bufnr] = nil
    M.highlight_diff_blocks(bufnr, { force = current.force })
  end, DEBOUNCE_MS)
end

---@param bufnr number
local function schedule_syntax_refresh(bufnr)
  schedule_diff_highlight(bufnr, { force = false })
end

---Neovim has no FoldChanged; refresh syntax after native fold commands instead.
---@param bufnr number
local function setup_fold_refresh_maps(bufnr)
  if vim.b[bufnr].cc_acp_diff_fold_maps then
    return
  end
  vim.b[bufnr].cc_acp_diff_fold_maps = true

  local fold_keys = { "zo", "zO", "zv", "za", "zA", "zc", "zC", "zr", "zR", "zm", "zM" }
  for _, key in ipairs(fold_keys) do
    vim.keymap.set("n", key, function()
      local count = vim.v.count
      local cmd = count > 0 and (count .. key) or key
      vim.cmd("normal! " .. cmd)
      schedule_syntax_refresh(bufnr)
    end, { buffer = bufnr, silent = true, desc = "Fold and refresh diff syntax" })
  end
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

---@param diff_block table|nil
---@return integer added
---@return integer deleted
local function diff_line_stats(diff_block)
  if not diff_block then
    return 0, 0
  end
  local old = type(diff_block.oldText) == "string" and diff_block.oldText or ""
  local new = type(diff_block.newText) == "string" and diff_block.newText or ""
  local hunks = require("codecompanion.diff")._diff(
    vim.split(old, "\n", { plain = true }),
    vim.split(new, "\n", { plain = true })
  )
  local added, deleted = 0, 0
  for _, hunk in ipairs(hunks) do
    deleted = deleted + (hunk[2] or 0)
    added = added + (hunk[4] or 0)
  end
  return added, deleted
end

---@param path string
---@param diff_block table|nil
---@return string
local function diff_message_title(path, diff_block)
  local added, deleted = diff_line_stats(diff_block)
  local stats = (added > 0 or deleted > 0) and string.format(" (+%d/-%d)", added, deleted) or ""
  return string.format("Diff for `%s`%s", path, stats)
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
        if ev.match == "CodeCompanionChatRestored" then
          buf_state[bufnr] = nil
          schedule_diff_highlight(bufnr, { force = true })
        else
          schedule_diff_highlight(bufnr)
        end
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = hl_group,
    pattern = "*",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "codecompanion" then
        setup_fold_refresh_maps(ev.buf)
        schedule_diff_highlight(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinScrolled", "CursorMoved" }, {
    group = hl_group,
    pattern = "*",
    callback = function(ev)
      if vim.bo[ev.buf].filetype == "codecompanion" then
        schedule_syntax_refresh(ev.buf)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = hl_group,
    callback = function(ev)
      buf_state[ev.buf] = nil
      pending_highlight[ev.buf] = nil
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
        content = ("%s\n\n%s"):format(diff_message_title(path, block), content),
      }, {
        type = self.chat.MESSAGE_TYPES.TOOL_MESSAGE,
        tools = { call_id = id .. ":diff" },
        virt_text_pos = "inline",
        status = "completed",
      })
      schedule_diff_highlight(self.chat.bufnr)
    end
  end
end

return M
