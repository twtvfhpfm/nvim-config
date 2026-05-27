--- Lualine: CodeCompanion chat status (spinner + model) — chat buffer only.
local M = require("lualine.component"):extend()

M.processing_by_buf = {}
M.spinner_index = 1
M._spinner_timer = nil

local SPINNER_MS = 500

-- Three dots bouncing: highlight cycles left → center → right → center
local spinner_frames = {
  "● · ·",
  "· ● ·",
  "· · ●",
  "· ● ·",
}
local spinner_len = #spinner_frames

local HL_MODEL = "CodeCompanionLualineModel"

---@param bufnr? number
---@return table|nil
local function chat_metadata(bufnr)
  if not package.loaded.codecompanion then
    return nil
  end
  local meta_tbl = _G.codecompanion_chat_metadata
  if not meta_tbl then
    return nil
  end
  return meta_tbl[bufnr or vim.api.nvim_get_current_buf()]
end

local function is_dark_background()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local bg = normal.bg
  if not bg then
    return true
  end
  local r = math.floor(bg / 65536) % 256
  local g = math.floor(bg / 256) % 256
  local b = bg % 256
  return (0.299 * r + 0.587 * g + 0.114 * b) < 128
end

local function setup_highlights()
  if is_dark_background() then
    vim.api.nvim_set_hl(0, HL_MODEL, { fg = "#7dcfff", bg = "#283457", bold = true })
  else
    vim.api.nvim_set_hl(0, HL_MODEL, { fg = "#1d4ed8", bg = "#dbeafe", bold = true })
  end
end

---@return string
local function next_spinner()
  M.spinner_index = (M.spinner_index % spinner_len) + 1
  return spinner_frames[M.spinner_index]
end

local function refresh_lualine()
  vim.schedule(function()
    pcall(function()
      require("lualine").refresh({ force = true })
    end)
  end)
end

local function sync_spinner_timer()
  if next(M.processing_by_buf) == nil then
    if M._spinner_timer then
      M._spinner_timer:stop()
      M._spinner_timer:close()
      M._spinner_timer = nil
    end
    return
  end
  if M._spinner_timer then
    return
  end
  M._spinner_timer = vim.uv.new_timer()
  M._spinner_timer:start(SPINNER_MS, SPINNER_MS, vim.schedule_wrap(refresh_lualine))
end

---@param text string
---@return string
local function hl_model(text)
  return string.format("%%#%s#%s", HL_MODEL, text)
end

function M:init(options)
  M.super.init(self, options)

  setup_highlights()

  local group = vim.api.nvim_create_augroup("CodeCompanionLualineStatus", { clear = true })

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      setup_highlights()
      refresh_lualine()
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = {
      "CodeCompanionRequest*",
      "CodeCompanionChatOpened",
      "CodeCompanionChatClosed",
      "CodeCompanionChatModel",
      "CodeCompanionChatAdapter",
    },
    callback = function(ev)
      local bufnr = ev.data and ev.data.bufnr
      if bufnr and ev.match == "CodeCompanionRequestStarted" then
        M.processing_by_buf[bufnr] = true
      elseif bufnr and ev.match == "CodeCompanionRequestFinished" then
        M.processing_by_buf[bufnr] = nil
      end
      sync_spinner_timer()
      refresh_lualine()
    end,
  })
end

function M:update_status()
  if vim.bo.filetype ~= "codecompanion" then
    return nil
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local meta = chat_metadata(bufnr)
  if not meta or not meta.adapter then
    return nil
  end

  local model = meta.adapter.model or meta.adapter.name
  if not model or model == "" then
    return nil
  end

  if M.processing_by_buf[bufnr] then
    return hl_model(" " .. next_spinner() .. "  󰚩 " .. model .. " ")
  end

  return hl_model(" 󰚩 " .. model .. " ")
end

return M
