-- Kitty CLI provider for CodeCompanion
-- Runs agents in a Kitty window/tab via remote control (kitty @).
--
-- Requirements:
--   1. Neovim started inside Kitty (KITTY_WINDOW_ID set), or KITTY_LISTEN_ON configured
--   2. kitty.conf: allow_remote_control yes  (or socket-only / partial)
--
-- Optional overrides via vim.g.codecompanion_kitty_cli:
--   kitty_bin       path to kitty binary (default: auto-detect, e.g. ~/.local/kitty.app/bin/kitty)
--   launch_type     "tab" | "window" | "os-window"  (default: "window")
--                     tab = new tab in the same Kitty OS window as Neovim
--                     window = new kitty window (split) in the current tab (default)
--                     os-window = new top-level Kitty OS window (avoid unless needed)
--   ready_delay_ms  ms to wait after launch before sending queued input (default: 1500)
--   focus_on_launch focus the Kitty agent window after launch (default: true)
--   focus_on_send   focus Kitty window on each :send (default: false)
--   keep_focus      keep Neovim focused when launching (default: true)

local Queue = require("codecompanion.utils.queue")
local log = require("codecompanion.utils.log")

local api = vim.api

local DEFAULT_OPTS = {
  launch_type = "window",
  ready_delay_ms = 1500,
  focus_on_launch = true,
  focus_on_send = true,
  keep_focus = true,
}

local cached_kitty_bin ---@type string|nil

local function opts()
  return vim.tbl_deep_extend("force", DEFAULT_OPTS, vim.g.codecompanion_kitty_cli or {})
end

---Resolve kitty binary (not always on PATH when nvim runs inside Kitty)
---@return string
local function resolve_kitty_bin()
  if cached_kitty_bin then
    return cached_kitty_bin
  end

  local o = opts()
  if o.kitty_bin and o.kitty_bin ~= "" then
    cached_kitty_bin = o.kitty_bin
    return cached_kitty_bin
  end

  local candidates = {
    vim.fn.exepath("kitty"),
    vim.fn.exepath("kitten"),
  }

  local install = vim.env.KITTY_INSTALLATION_DIR
  if install and install ~= "" then
    table.insert(candidates, install .. "/bin/kitty")
    table.insert(candidates, install .. "/bin/kitten")
  end

  local home = vim.env.HOME or vim.fn.expand("~")
  table.insert(candidates, home .. "/.local/kitty.app/bin/kitty")
  table.insert(candidates, home .. "/.local/kitty.app/bin/kitten")
  table.insert(candidates, "/usr/bin/kitty")
  table.insert(candidates, "/usr/local/bin/kitty")

  for _, path in ipairs(candidates) do
    if path ~= "" and vim.uv.fs_stat(path) then
      cached_kitty_bin = path
      return cached_kitty_bin
    end
  end

  cached_kitty_bin = "kitty"
  return cached_kitty_bin
end

---@param result vim.SystemObj
---@param cmd_display? string
---@return string
local function format_error(result, cmd_display)
  local lines = {}
  if result.code ~= nil then
    lines[#lines + 1] = string.format("exit code: %s", tostring(result.code))
  end

  local stderr = (result.stderr or ""):gsub("%s+$", "")
  local stdout = (result.stdout or ""):gsub("%s+$", "")
  if stderr ~= "" then
    lines[#lines + 1] = stderr
  end
  if stdout ~= "" and stdout ~= stderr then
    lines[#lines + 1] = stdout
  end

  if #lines == 0 then
    lines[#lines + 1] = "no output from kitty"
    if vim.fn.exepath("kitty") == "" and resolve_kitty_bin() == "kitty" then
      lines[#lines + 1] = "kitty not found in PATH"
      lines[#lines + 1] = "set: vim.g.codecompanion_kitty_cli = { kitty_bin = \"...\" }"
    end
  end

  if cmd_display then
    lines[#lines + 1] = ""
    lines[#lines + 1] = cmd_display
  end
  return table.concat(lines, "\n")
end

---Environment for kitty subprocesses (vim.system may not inherit everything)
---@return table<string, string>
local function kitty_env()
  local env = {}
  for _, entry in ipairs(vim.fn.environ()) do
    local key, value = entry:match("^([^=]+)=(.*)$")
    if key then
      env[key] = value
    end
  end
  for _, key in ipairs({
    "KITTY_WINDOW_ID",
    "KITTY_PID",
    "KITTY_LISTEN_ON",
    "KITTY_INSTANCE",
    "HOME",
    "USER",
    "PATH",
    "TERM",
    "XDG_RUNTIME_DIR",
  }) do
    if vim.env[key] and vim.env[key] ~= "" then
      env[key] = vim.env[key]
    end
  end
  return env
end

---@return boolean
local function in_kitty()
  return vim.env.KITTY_WINDOW_ID ~= nil and vim.env.KITTY_WINDOW_ID ~= ""
end

---@param result vim.SystemObj
---@return boolean
local function is_ok(result)
  if result.code == 0 then
    return true
  end
  -- Some kitty builds return nil code but still print the window id on stdout
  if (result.code == nil or result.code == 1) and (result.stdout or ""):match("%d+") then
    return true
  end
  return false
end

---@class CodeCompanion.CLI.Provider.Kitty
---@field agent table
---@field bufnr number
---@field nvim_pid number
---@field marker string
---@field title string
---@field match_title string
---@field match_env string
---@field running boolean
---@field ready boolean
---@field window_id number|nil
---@field queue CodeCompanion.Queue
---@field ready_timer uv.uv_timer_t|nil
---@field consumer_timer uv.uv_timer_t|nil
---@field watch_timer uv.uv_timer_t|nil
local Kitty = {}

---Kitty --match value: prefer window id (exact), fall back to unique title
---@return string
function Kitty:_match()
  if self.window_id then
    return "id:" .. tostring(self.window_id)
  end
  return self.match_title
end

---Append --match to a kitty @ subcommand
---@param subcmd string[]
---@param stdin? string
---@return vim.SystemObj
function Kitty:_target(subcmd, stdin)
  local args = vim.list_extend({ subcmd[1], "--match", self:_match() }, vim.list_slice(subcmd, 2))
  return self:_kitty(args, stdin)
end

---`--to` target for remote control when not attached to a TTY (e.g. vim.system)
---@return string[]
function Kitty:_rc_prefix()
  local listen = vim.env.KITTY_LISTEN_ON
  if listen and listen ~= "" then
    return { "--to", listen }
  end
  return {}
end

---Run `kitty @ …` (PTY + full env; needed when vim.system has no TTY)
---@param args string[]
---@param stdin? string
---@return vim.SystemObj
function Kitty:_kitty(args, stdin)
  local bin = resolve_kitty_bin()
  local cmd = vim.list_extend({ bin, "@" }, self:_rc_prefix())
  vim.list_extend(cmd, args)

  if stdin then
    return vim.system(cmd, { stdin = stdin, text = true, env = kitty_env() })
  end

  local out_lines = {}
  local err_lines = {}
  local jid = vim.fn.jobstart(cmd, {
    pty = true,
    env = kitty_env(),
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(out_lines, data)
    end,
    on_stderr = function(_, data)
      vim.list_extend(err_lines, data)
    end,
  })

  if jid <= 0 then
    return { code = 1, stdout = "", stderr = "jobstart failed for kitty @" }
  end

  local rv = vim.fn.jobwait({ jid }, 10000)
  local code = type(rv[1]) == "number" and rv[1] or 1
  return {
    code = code,
    stdout = table.concat(out_lines, "\n"),
    stderr = table.concat(err_lines, "\n"),
  }
end

---@param args string[]
---@return string
function Kitty:_cmd_display(args)
  local parts = vim.list_extend({ resolve_kitty_bin(), "@" }, self:_rc_prefix())
  vim.list_extend(parts, args)
  return table.concat(parts, " ")
end

---Launch agent inside the current Kitty instance (`kitty @ launch`, not `kitty --detach`)
---@return vim.SystemObj
function Kitty:_launch_rc()
  local o = opts()
  local launch_title = (self.display_name and self.display_name ~= "") and self.display_name or self.title
  local launch_args = {
    "launch",
    "--type",
    o.launch_type,
    "--title",
    launch_title,
    "--cwd",
    vim.fn.getcwd(),
    "--env",
    "CODECOMPANION_CLI_ID=" .. self.marker,
  }
  if o.keep_focus and not o.focus_on_launch then
    table.insert(launch_args, "--keep-focus")
  end
  local cmd = vim.list_extend(launch_args, { "--", self.agent.cmd })
  vim.list_extend(cmd, self.agent.args or {})
  return self:_kitty(cmd)
end

---Extract window id from `kitty @ ls` JSON (single object or os-window list)
---@param data table
---@return number|nil
local function parse_window_id(data)
  if data.id and type(data.id) == "number" then
    return data.id
  end
  if data.windows and data.windows[1] and data.windows[1].id then
    return data.windows[1].id
  end
  for _, os_win in ipairs(data) do
    for _, tab in ipairs(os_win.tabs or {}) do
      for _, win in ipairs(tab.windows or {}) do
        if win.id then
          return win.id
        end
      end
    end
  end
  return nil
end

---Find kitty window id for this instance (env marker is most reliable)
---@return number|nil
function Kitty:_find_window_id()
  local result = self:_kitty({ "ls", "--match", self.match_env })
  if is_ok(result) then
    local ok, data = pcall(vim.json.decode, result.stdout or "[]")
    if ok then
      local wid = parse_window_id(data)
      if wid then
        return wid
      end
    end
  end

  -- Fallback: title (cursor-agent may override TTY title)
  result = self:_kitty({ "ls", "--match", self.match_title })
  if is_ok(result) then
    local ok, data = pcall(vim.json.decode, result.stdout or "[]")
    if ok then
      return parse_window_id(data)
    end
  end

  return nil
end

---@param bufnr number
---@param lines string[]
function Kitty:_set_status(bufnr, lines)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = bufnr })
end

---@return boolean
function Kitty:_window_exists()
  if not self.window_id then
    return false
  end
  local result = self:_kitty({ "ls", "--match", "id:" .. tostring(self.window_id) })
  if result.code ~= 0 then
    return false
  end
  local out = (result.stdout or ""):gsub("%s+$", "")
  return out ~= "" and out ~= "[]"
end

---@param args { bufnr: number, agent: table }
---@return CodeCompanion.CLI.Provider.Kitty
function Kitty.new(args)
  local nvim_pid = vim.fn.getpid()
  -- pid + bufnr: unique across multiple Neovim instances in one Kitty
  local title = string.format("codecompanion-cli-%d-%d", nvim_pid, args.bufnr)
  local marker = string.format("%d-%d", nvim_pid, args.bufnr)
  local self = setmetatable({
    agent = args.agent,
    bufnr = args.bufnr,
    nvim_pid = nvim_pid,
    marker = marker,
    title = title,
    match_title = "title:" .. title,
    match_env = "env:CODECOMPANION_CLI_ID=" .. marker,
    running = false,
    ready = false,
    window_id = nil,
    queue = Queue.new(),
    ready_timer = nil,
    consumer_timer = nil,
    watch_timer = nil,
    launch_cwd = nil,
    display_name = nil,
    agent_index = nil,
    prompt_labeled = false,
  }, { __index = Kitty })
  return self
end

---@param cwd string
---@return string
local function shorten_cwd(cwd)
  local home = vim.env.HOME or ""
  if home ~= "" and cwd:sub(1, #home) == home then
    cwd = "~" .. cwd:sub(#home + 1)
  end
  if #cwd > 44 then
    cwd = "…" .. cwd:sub(-43)
  end
  return cwd
end

---@param name string
---@return nil
function Kitty:set_kitty_title(name)
  if not name or name == "" then
    return
  end
  if not self.running or not self.window_id then
    self._pending_kitty_title = name
    return
  end
  self._pending_kitty_title = nil
  -- Permanent title: cursor-agent may override TTY title; re-apply after ready_delay_ms too
  self:_target({ "set-window-title", name })
end

---@param name string
---@return nil
function Kitty:set_display_name(name)
  self.display_name = name
  self:set_kitty_title(name)
  self:_set_status(self.bufnr, {
    "CodeCompanion · Kitty",
    "",
    string.format("Name: %s", name),
    string.format("Cwd: %s", shorten_cwd(self.launch_cwd or vim.fn.getcwd())),
    string.format("Kitty window id: %s", self.window_id and tostring(self.window_id) or "?"),
    "",
    "Prompts are sent from Neovim. Use <leader>as to focus this Kitty window.",
  })
end

---@param text string
---@return nil
function Kitty:note_prompt(text)
  -- Naming is handled by codecompanion_kitty_multi.set_label
end

---Poll until the Kitty agent window is closed, then notify Neovim to tear down CLI state
---@private
function Kitty:_start_watchdog()
  self:_close_timer("watch_timer")
  self.watch_timer = vim.uv.new_timer()
  self.watch_timer:start(
    1000,
    1000,
    vim.schedule_wrap(function()
      if not self.running then
        return self:_close_timer("watch_timer")
      end
      if self:_window_exists() then
        return
      end
      self.running = false
      self.ready = false
      self.window_id = nil
      self:_close_timers()
      if _G.codecompanion_kitty_providers then
        _G.codecompanion_kitty_providers[self.bufnr] = nil
      end
      vim.api.nvim_exec_autocmds("User", {
        pattern = "CodeCompanionKittyAgentExited",
        data = { bufnr = self.bufnr },
      })
      self:_close_timer("watch_timer")
    end)
  )
end

---@return boolean
function Kitty:start()
  local o = opts()
  local pending = vim.g.codecompanion_kitty_pending_label
  if pending and pending ~= "" then
    self.display_name = pending
    self.prompt_labeled = true
  end

  if not in_kitty() then
    self:_set_status(self.bufnr, {
      "CodeCompanion Kitty provider",
      "",
      "Error: Neovim is not running inside Kitty.",
      "Start nvim from a Kitty window, or set KITTY_LISTEN_ON.",
      "",
      "Also ensure kitty.conf contains:",
      "  allow_remote_control yes",
    })
    log:error("Kitty CLI provider: not running inside Kitty")
    return false
  end

  -- kitty @ launch: stays inside the same Kitty app (tab/window), unlike `kitty --detach`
  -- which opens a new OS-level Kitty window.
  local launch_result = self:_launch_rc()
  local wid = is_ok(launch_result) and tonumber((launch_result.stdout or ""):match("%d+")) or nil

  if not wid then
    for _ = 1, 30 do
      wid = self:_find_window_id()
      if wid then
        break
      end
      vim.uv.sleep(100)
    end
  end

  if not wid and not is_ok(launch_result) then
    local err = format_error(launch_result, self:_cmd_display({
      "launch",
      "--type",
      o.launch_type,
      "--title",
      self.title,
      "--cwd",
      vim.fn.getcwd(),
      "--env",
      "CODECOMPANION_CLI_ID=" .. self.marker,
      "--",
      self.agent.cmd,
    }))
    local err_lines = vim.split(err, "\n", { plain = true })
    local status_lines = {
      "CodeCompanion Kitty provider",
      "",
      "Failed to launch agent in Kitty:",
    }
    vim.list_extend(status_lines, err_lines)
    vim.list_extend(status_lines, {
      "",
      "Check: allow_remote_control yes in kitty.conf",
      "Restart Kitty after changing config (KITTY_LISTEN_ON must be set).",
    })
    self:_set_status(self.bufnr, status_lines)
    log:error("Kitty launch failed: %s", err)
    return false
  end

  if not wid then
    self:_set_status(self.bufnr, {
      "CodeCompanion Kitty provider",
      "",
      "Agent started in Kitty but window id could not be resolved.",
      "Marker: CODECOMPANION_CLI_ID=" .. self.marker,
      "",
      "KITTY_LISTEN_ON=" .. (vim.env.KITTY_LISTEN_ON or "(not set)"),
    })
    log:error("Kitty: could not resolve window id for marker %s", self.marker)
    return false
  end

  self.window_id = wid
  self.running = true
  self.launch_cwd = vim.fn.getcwd()

  if self.display_name and self.display_name ~= "" then
    self:set_kitty_title(self.display_name)
  end

  if o.focus_on_launch and wid then
    self:_target({ "focus-window" })
  end

  self.ready_timer = vim.uv.new_timer()
  self.ready_timer:start(
    o.ready_delay_ms,
    0,
    vim.schedule_wrap(function()
      self.ready = true
      self.ready_timer = nil
      local title = self.display_name or self._pending_kitty_title
      if title and title ~= "" then
        self:set_kitty_title(title)
      end
      if not self.queue:is_empty() then
        self:_consume()
      end
    end)
  )

  self:_start_watchdog()

  _G.codecompanion_kitty_providers = _G.codecompanion_kitty_providers or {}
  _G.codecompanion_kitty_providers[self.bufnr] = self

  log:debug(
    "Kitty CLI launched: %s (nvim_pid=%d bufnr=%d window_id=%s)",
    self.agent.cmd,
    self.nvim_pid,
    self.bufnr,
    wid or "nil"
  )
  return true
end

---@param text string
---@param send_opts? { submit: boolean }
---@return boolean
function Kitty:send(text, send_opts)
  if not self.running then
    log:warn("Kitty CLI agent is not running")
    return false
  end

  self.queue:push({ text = text, submit = send_opts and send_opts.submit })
  if self.ready then
    self:_consume()
  end
  return true
end

---@return boolean
function Kitty:is_running()
  if not self.running then
    return false
  end
  if not self:_window_exists() then
    self.running = false
    return false
  end
  return true
end

---Focus the Kitty agent window (called after send)
---@return nil
function Kitty:focus_agent()
  if self.running and self.window_id then
    self:_target({ "focus-window" })
  end
end

---@return nil
function Kitty:stop()
  if _G.codecompanion_kitty_providers then
    _G.codecompanion_kitty_providers[self.bufnr] = nil
  end
  self:_close_timers()
  if self.running and self.window_id then
    pcall(function()
      self:_target({ "close-window" })
    end)
  end
  self.running = false
  self.ready = false
  self.window_id = nil
end

---@private
function Kitty:_consume()
  if self.consumer_timer then
    return
  end

  local o = opts()
  self.consumer_timer = vim.uv.new_timer()
  self.consumer_timer:start(0, 100, vim.schedule_wrap(function()
    if self.queue:is_empty() or not self.running then
      self:_close_timer("consumer_timer")
      return
    end

    local item = self.queue:pop()
    if item.text and item.text ~= "" then
      local payload = item.text:gsub("\r\n", "\n")
      self:_target({ "send-text", "--stdin" }, payload)
    end
    if item.submit then
      self:_target({ "send-key", "enter" })
    end

    if self.queue:is_empty() and o.focus_on_send then
      self:focus_agent()
    end
  end))
end

---@private
---@param field string
function Kitty:_close_timer(field)
  local timer = self[field]
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
  self[field] = nil
end

---@private
function Kitty:_close_timers()
  self:_close_timer("ready_timer")
  self:_close_timer("consumer_timer")
  self:_close_timer("watch_timer")
end

return Kitty
