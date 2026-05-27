--- Multi-instance Kitty CLI helpers for CodeCompanion
local M = {}

local api = vim.api

---@type table<number, CodeCompanion.CLI>
M.instances = {}

---@param cwd string
---@return string
local function shorten_cwd(cwd)
  local home = vim.env.HOME or ""
  if home ~= "" and cwd:sub(1, #home) == home then
    cwd = "~" .. cwd:sub(#home + 1)
  end
  if #cwd > 40 then
    cwd = "…" .. cwd:sub(-39)
  end
  return cwd
end

---@param bufnr number
---@return CodeCompanion.CLI|nil
function M.get(bufnr)
  return M.instances[bufnr]
end

---@param inst CodeCompanion.CLI
---@param name string User-chosen name (shown as-is in picker and Kitty tab)
function M.set_user_name(inst, name)
  local p = inst.provider
  if not p or not name or name == "" then
    return
  end
  if p.set_display_name then
    p:set_display_name(name)
  else
    p.display_name = name
  end
  p.prompt_labeled = true
end

---@param inst CodeCompanion.CLI
---@param label string Auto label from prompt or file context
function M.set_label(inst, label)
  local p = inst.provider
  if not p or not label or label == "" then
    return
  end
  local idx = p.agent_index or 1
  local name = string.format("#%d · %s", idx, label)
  if p.set_display_name then
    p:set_display_name(name)
  else
    p.display_name = name
  end
  p.prompt_labeled = true
end

---@param inst CodeCompanion.CLI
function M.register(inst)
  if M.instances[inst.bufnr] then
    return
  end
  M.instances[inst.bufnr] = inst
  local p = inst.provider
  local idx = 0
  for _ in pairs(M.instances) do
    idx = idx + 1
  end
  p.agent_index = idx
  if p.prompt_labeled or (p.display_name and p.display_name ~= "") then
    return
  end
  local cwd = shorten_cwd(p.launch_cwd or vim.fn.getcwd())
  if p.set_display_name then
    p:set_display_name(string.format("#%d · %s", idx, cwd))
  else
    p.display_name = string.format("#%d · %s", idx, cwd)
  end
end

---List configured CLI agents (sorted by id)
---@return { id: string, label: string }[]
function M.list_agents()
  local config = require("codecompanion.config")
  local agents = config.interactions.cli.agents or {}
  local list = {}
  for id, spec in pairs(agents) do
    list[#list + 1] = {
      id = id,
      label = spec.description or id,
    }
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

---Pick a CLI agent from config
---@param on_done fun(agent_id: string|nil)
function M.select_agent(on_done)
  local agents = M.list_agents()
  if #agents == 0 then
    vim.notify("No CLI agents configured", vim.log.levels.ERROR)
    return on_done(nil)
  end
  if #agents == 1 then
    return on_done(agents[1].id)
  end

  local labels = {}
  for i, a in ipairs(agents) do
    labels[i] = a.label
  end

  vim.ui.select(labels, { prompt = "CLI agent" }, function(choice)
    if not choice then
      return on_done(nil)
    end
    for _, a in ipairs(agents) do
      if a.label == choice then
        return on_done(a.id)
      end
    end
    on_done(nil)
  end)
end

---Select CLI agent, then prompt for name and launch Kitty instance
function M.select_agent_and_create()
  M.select_agent(function(agent_id)
    if not agent_id then
      return
    end
    M.prompt_and_create({ agent = agent_id })
  end)
end

---Prompt for a name, then launch a new Kitty CLI agent
---@param opts? { agent?: string, prompt?: string, default?: string, on_done?: fun(inst: CodeCompanion.CLI|nil) }
function M.prompt_and_create(opts)
  opts = opts or {}
  vim.ui.input({
    prompt = opts.prompt or "Agent name: ",
    default = opts.default or "",
  }, function(name)
    if name == nil then
      return
    end
    name = vim.trim(name)
    if name == "" then
      vim.notify("Agent name is required", vim.log.levels.WARN)
      return
    end

    local cli_mod = require("codecompanion.interactions.cli")
    local create_args = opts.agent and { agent = opts.agent } or nil
    -- Apply before create() so Kitty launch --title uses the user's name
    vim.g.codecompanion_kitty_pending_label = name
    local inst = cli_mod.create(create_args)
    vim.g.codecompanion_kitty_pending_label = nil
    if not inst then
      vim.notify("Failed to create Kitty CLI agent", vim.log.levels.ERROR)
      return
    end

    vim.g.codecompanion_active_cli_bufnr = inst.bufnr
    M.set_user_name(inst, name)
    vim.notify("Created agent: " .. M.label(inst), vim.log.levels.INFO)

    if opts.on_done then
      opts.on_done(inst)
    end
  end)
end

---Agent to send to: active (from <leader>as) if still running, else nil
---@param agent_name? string
---@return CodeCompanion.CLI|nil
function M.get_target_instance(agent_name)
  M.prune()
  local active = vim.g.codecompanion_active_cli_bufnr
  if active then
    local inst = M.get(active)
    if inst and inst.provider:is_running() then
      if not agent_name or inst.agent_name == agent_name then
        return inst
      end
    end
  end
  return nil
end

---@param bufnr number
function M.unregister(bufnr)
  M.instances[bufnr] = nil
  if vim.g.codecompanion_active_cli_bufnr == bufnr then
    vim.g.codecompanion_active_cli_bufnr = nil
  end
end

---@return CodeCompanion.CLI[]
function M.prune()
  for bufnr, inst in pairs(M.instances) do
    if not api.nvim_buf_is_valid(bufnr) or not inst.provider:is_running() then
      M.unregister(bufnr)
    end
  end
  return M.live()
end

---@return CodeCompanion.CLI[]
function M.live()
  local list = {}
  for _, inst in pairs(M.instances) do
    if api.nvim_buf_is_valid(inst.bufnr) and inst.provider:is_running() then
      list[#list + 1] = inst
    end
  end
  table.sort(list, function(a, b)
    return a.bufnr < b.bufnr
  end)
  return list
end

---Build picker label from prompt text or editor context
---@param text string
---@param buffer_context CodeCompanion.BufferContext
---@return string|nil
function M.label_from_context(text, buffer_context)
  local t = vim.trim(text or "")
  if t ~= "" then
    t = t:gsub("[\r\n]+", " "):gsub("%s+", " ")
    if #t > 52 then
      t = t:sub(1, 49) .. "…"
    end
    return t
  end
  if buffer_context.filename and buffer_context.filename ~= "" then
    if buffer_context.is_visual then
      return string.format(
        "%s:%d-%d",
        buffer_context.filename,
        buffer_context.start_line,
        buffer_context.end_line
      )
    end
    return "@" .. buffer_context.filename
  end
  return nil
end

---@param bufnr number
---@param text string
---@param buffer_context? CodeCompanion.BufferContext
function M.note_prompt(bufnr, text, buffer_context)
  local inst = M.get(bufnr)
  if not inst then
    return
  end
  if inst.provider.prompt_labeled then
    return
  end
  local label = M.label_from_context(text, buffer_context or { filename = "" })
  if label then
    M.set_label(inst, label)
  end
end

---@param inst CodeCompanion.CLI
---@return string
function M.label(inst)
  local p = inst.provider
  if p.display_name and p.display_name ~= "" then
    return p.display_name
  end
  local idx = p.agent_index or inst.bufnr
  local cwd = p.launch_cwd and shorten_cwd(p.launch_cwd) or "agent"
  return string.format("#%d · %s", idx, cwd)
end

---@param inst CodeCompanion.CLI
function M.focus(inst)
  if not inst.provider:is_running() then
    return false
  end
  if inst.provider.focus_agent then
    inst.provider:focus_agent()
  end
  vim.g.codecompanion_active_cli_bufnr = inst.bufnr
  return true
end

---@param direction? number 1 next, -1 prev
---@return boolean
function M.cycle(direction)
  local live = M.prune()
  if #live == 0 then
    return false
  end
  if #live == 1 then
    return M.focus(live[1])
  end

  direction = direction or 1
  local active = vim.g.codecompanion_active_cli_bufnr
  local idx = 1
  for i, inst in ipairs(live) do
    if inst.bufnr == active then
      idx = i
      break
    end
  end

  local next_idx = direction > 0 and (idx % #live) + 1 or ((idx - 2 + #live) % #live) + 1
  return M.focus(live[next_idx])
end

---Resolve instance from picker label
---@param live CodeCompanion.CLI[]
---@param labels string[]
---@param choice string
---@return CodeCompanion.CLI|nil
local function inst_from_choice(live, labels, choice)
  if choice == "+ New agent" then
    return nil
  end
  for i, inst in ipairs(live) do
    if labels[i] == choice then
      return inst
    end
  end
  return nil
end

---@param opts? { force_new?: boolean, pick_always?: boolean, focus_kitty?: boolean }
---@param on_done fun(inst: CodeCompanion.CLI|nil)
function M.pick(opts, on_done)
  opts = opts or {}
  local live = M.prune()

  if opts.force_new then
    return on_done(nil)
  end

  if not opts.pick_always then
    local active = vim.g.codecompanion_active_cli_bufnr
    if active then
      local inst = M.get(active)
      if inst and inst.provider:is_running() then
        return on_done(inst)
      end
    end
  end

  if #live == 0 then
    return on_done(nil)
  end
  if #live == 1 then
    if opts.focus_kitty ~= false then
      M.focus(live[1])
    else
      vim.g.codecompanion_active_cli_bufnr = live[1].bufnr
    end
    return on_done(live[1])
  end

  local labels = {}
  for i, inst in ipairs(live) do
    labels[i] = M.label(inst)
  end
  labels[#labels + 1] = "+ New agent"

  vim.ui.select(labels, { prompt = "Kitty CLI agent" }, function(choice)
    if not choice then
      local active = vim.g.codecompanion_active_cli_bufnr
      local inst = active and M.get(active) or live[1]
      if inst and opts.focus_kitty ~= false then
        M.focus(inst)
      end
      return on_done(inst)
    end

    local inst = inst_from_choice(live, labels, choice)
    if inst and opts.focus_kitty ~= false then
      M.focus(inst)
    elseif inst then
      vim.g.codecompanion_active_cli_bufnr = inst.bufnr
    end
    on_done(inst)
  end)
end

return M
