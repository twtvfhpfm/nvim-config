return {
  "olimorris/codecompanion.nvim",
  version = "^19.13.0",
  opts = {},
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    "nvim-treesitter/nvim-treesitter",
    "stevearc/dressing.nvim", -- for input provider dressing
  },
  config = function ()
    require("codecompanion").setup({
      display = {
        chat = {
          window = {
            opts = {
              number = false,
              relativenumber = false,
            },
          },
        },
      },
      adapters = {
        http = {
          deepseek = function()
            return require("codecompanion.adapters").extend("deepseek", {
              url = "https://ocean-code-cn.tuya-inc.com:7799/v1/chat/completions",
              env = {
                api_key = "sk-JLqy1Q646JWirLNds1oKHtYzL4U1X0s710y3-emhtD-aFtNA",
              },
              schema = {
                model = {
                  default = "deepseek-v4-flash",
                },
                ["thinking.type"] = {
                  default = "disabled",
                },
              },
            })
          end,
        },
        acp = {
          cursor_cli = function()
            return require("codecompanion.adapters").extend("cursor_cli", {
              commands = {
                default = {
                  "/home/xu/.local/bin/cursor-agent",
                  "acp",
                },
              },
            })
          end,
        }
      },
      interactions = {
        cli = {
          agent = "claude_agent",
          providers = {
            kitty = {
              path = vim.fn.stdpath("config") .. "/lua/cli_providers/kitty.lua",
              description = "Run CLI agents in a Kitty window",
            },
          },
          agents = {
            cursor_agent = {
              cmd = "/home/xu/.local/bin/cursor-agent",
              args = {},
              description = "Cursor CLI (Kitty)",
              provider = "kitty",
            },
            claude_agent = {
              cmd = "/home/xu/.local/bin/claude",
              args = {},
              description = "Claude CLI (Kitty)",
              provider = "kitty",
            },
          },
        },
        chat = {adapter = "cursor_cli", input_ui = "float"},
        inline = {adapter = "deepseek", input_ui = "float"},
        agent = {adapter = "cursor_cli"},
      },
    })

    -- Neovim :terminal 在窗口反复 resize 时会把 TUI 每次整屏重绘都记入 scrollback；
    -- Kitty 等外置终端表现不同。限制 scrollback 可避免历史无限膨胀（按需调大/调小）。
    vim.api.nvim_create_autocmd("FileType", {
      pattern = "codecompanion_cli",
      callback = function(args)
        vim.bo[args.buf].scrollback = 8000
      end,
    })
    local multi = require("codecompanion_kitty_multi")
    local api = vim.api

    local function send_to_instance(inst, prompt, extra)
      local cli = require("codecompanion.interactions.cli")
      local context_utils = require("codecompanion.utils.context")
      local ctx_buf = extra and extra.ctx_bufnr or api.nvim_get_current_buf()
      local context = context_utils.get(ctx_buf, extra and extra.args)
      local resolved = cli.resolve_editor_context(prompt or "", context)
      -- Only send Enter to Kitty when explicitly requested (ap never auto-submits)
      local submit = extra and extra.submit == true
      inst:send(resolved, { submit = submit })
      if not (extra and extra.stay_in_nvim) then
        multi.focus(inst)
      end
    end

    -- After <leader>ap submit: focus Kitty; when user returns to nvim, stay in Normal
    vim.api.nvim_create_autocmd({ "FocusGained", "VimEnter" }, {
      callback = function()
        if not vim.g.cc_ap_restore_normal then
          return
        end
        vim.g.cc_ap_restore_normal = false
        vim.schedule(function()
          if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
            vim.cmd.stopinsert()
          end
        end)
      end,
    })

    local shared_input = require("codecompanion.interactions.shared.input")

    local function open_ap_prompt(initial_content, ctx_opts)
      ctx_opts = ctx_opts or {}
      if shared_input.is_visible() then
        return shared_input.hide()
      end

      -- Capture source buffer while keymap runs; visual marks live in '< '>
      local code_bufnr = api.nvim_get_current_buf()

      shared_input.open({
        title = " CodeCompanion CLI ",
        initial_content = initial_content,
        on_submit = function(text, _submit_opts)
          vim.g.cc_ap_restore_normal = true
          local context_utils = require("codecompanion.utils.context")
          local ctx_args = vim.tbl_deep_extend("force", ctx_opts.args or {}, { user_prompt = text })
          local buffer_context = context_utils.get(code_bufnr, ctx_args)
          local inst = multi.get_target_instance()
          local label = multi.label_from_context(text, buffer_context)
          if inst and label and not inst.provider.prompt_labeled then
            multi.set_label(inst, label)
          end
          if not inst then
            local cli_mod = require("codecompanion.interactions.cli")
            inst = cli_mod.create()
            if inst then
              vim.g.codecompanion_active_cli_bufnr = inst.bufnr
              if label and not inst.provider.prompt_labeled then
                multi.set_label(inst, label)
              end
            end
          end
          if inst then
            send_to_instance(inst, text, {
              submit = false,
              args = ctx_args,
              ctx_bufnr = code_bufnr,
            })
          end
          -- Prompt closes in insert; if Kitty focus does not grab OS focus, fix now
          vim.defer_fn(function()
            if vim.api.nvim_get_mode().mode:match("^i") then
              vim.cmd.stopinsert()
            end
          end, 80)
        end,
      })
    end

    ---@param prompt? string
    ---@param extra? table
    local function cli_to_kitty(prompt, extra)
      extra = extra or {}

      if extra.prompt then
        return open_ap_prompt(type(prompt) == "string" and prompt or nil, extra)
      end

      multi.pick({ force_new = extra.force_new, focus_kitty = false }, function(inst)
        if inst then
          send_to_instance(inst, prompt, extra)
          return
        end

        local opts = vim.tbl_extend("force", {
          focus = false,
          submit = extra.submit == true,
        }, extra)
        if prompt ~= nil then
          require("codecompanion").cli(prompt, opts)
        else
          require("codecompanion").cli(opts)
        end
      end)
    end

    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionCLICreated",
      callback = function(ev)
        local cli = require("codecompanion.interactions.cli")
        local inst = cli.last_cli()
        if inst and inst.bufnr == ev.data.bufnr then
          multi.register(inst)
          vim.g.codecompanion_active_cli_bufnr = ev.data.bufnr
        end
      end,
    })

    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionCLIClosed",
      callback = function(ev)
        multi.unregister(ev.data.bufnr)
      end,
    })

    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionKittyAgentExited",
      callback = function(ev)
        local inst = multi.get(ev.data.bufnr)
        if inst then
          if inst.ui:is_visible() then
            inst.ui:hide()
          end
          inst:close()
          multi.unregister(ev.data.bufnr)
        end
      end,
    })

    vim.api.nvim_create_autocmd("User", {
      pattern = "CodeCompanionCLISent",
      callback = function(ev)
        local inst = multi.get(ev.data.bufnr) or require("codecompanion.interactions.cli").last_cli()
        if not inst or inst.bufnr ~= ev.data.bufnr then
          return
        end
        vim.g.codecompanion_active_cli_bufnr = ev.data.bufnr
        multi.note_prompt(ev.data.bufnr, ev.data.text, nil)
        if inst.provider.focus_agent then
          inst.provider:focus_agent()
        end
        if inst.ui:is_visible() then
          inst.ui:hide()
        end
        pcall(function()
          require("codecompanion.interactions.cli.input").hide()
        end)
      end,
    })

    local function ap_keymap()
      local mode = vim.fn.mode()
      local extra = { prompt = true, submit = false }
      if mode == "v" or mode == "V" or mode == "\22" then
        extra.args = { range = 1 }
      end
      cli_to_kitty(nil, extra)
    end

    vim.keymap.set({ "n", "v" }, "<LocalLeader>ap", ap_keymap, { desc = "Prompt the CLI agent" })

    vim.keymap.set("n", "<leader>as", function()
      if #multi.prune() == 0 then
        vim.notify("No running Kitty CLI agents", vim.log.levels.WARN)
        return
      end
      multi.pick({ pick_always = true, focus_kitty = true }, function(inst)
        if inst then
          multi.focus(inst)
          vim.notify("Active agent: " .. multi.label(inst), vim.log.levels.INFO)
        end
      end)
    end, { desc = "Switch Kitty CLI agent" })

    vim.keymap.set("n", "<leader>an", function()
      multi.prompt_and_create()
    end, { desc = "New Kitty CLI agent" })
  end
}
