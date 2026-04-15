return {
  "yetone/avante.nvim",
  -- if you want to build from source then do `make BUILD_FROM_SOURCE=true`
  -- ⚠️ must add this setting! ! !
  build = vim.fn.has("win32") ~= 0
      and "powershell -ExecutionPolicy Bypass -File Build.ps1 -BuildFromSource false"
      or "make",
  event = "VeryLazy",
  version = false, -- Never set this value to "*"! Never!
  ---@module 'avante'
  ---@type avante.Config
    opts = {
      render_markdown = false,
      provider = "cursor",
      mode = "agentic",
      acp_providers = {
        ["cursor"] = {
          command = os.getenv("HOME") .. "/.local/bin/agent",
          args = { "acp" },
          auth_method = "cursor_login",
          env = {
            HOME = os.getenv("HOME"),
            PATH = os.getenv("PATH"),
          },
        },
      },
        windows = {
          ---@type "right" | "left" | "top" | "bottom"
          position = "right", 
          wrap = true, -- 是否换行
          width = 30,  -- 侧边栏宽度
          spinner = {
              editing = { ""},
              generating = { ""}, -- Spinner characters for the 'generating' state
              thinking = { ""}, -- Spinner characters for the 'thinking' state
            },
          sidebar_header = {
            enabled = true,
            align = "center",
            rounded = true,
          },
          input = {
            prefix = "> ",
            height = 12, -- 【关键】在这里修改输入框的高度，默认通常是 1 或 5，改为 8-10 会舒服很多
          },
          edit = {
            border = "rounded",
            start_insert = true, -- 打开时自动进入插入模式
          },
          ask = {
            floating = false, -- 是否使用浮动窗口进行提问
            start_insert = true,
            border = "rounded",
          },
        },
    },
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
    --- The below dependencies are optional,
    "nvim-mini/mini.pick", -- for file_selector provider mini.pick
    "nvim-telescope/telescope.nvim", -- for file_selector provider telescope
    "hrsh7th/nvim-cmp", -- autocompletion for avante commands and mentions
    "ibhagwan/fzf-lua", -- for file_selector provider fzf
    "stevearc/dressing.nvim", -- for input provider dressing
    "folke/snacks.nvim", -- for input provider snacks
    "nvim-tree/nvim-web-devicons", -- or echasnovski/mini.icons
    -- "zbirenbaum/copilot.lua", -- for providers='copilot'
    {
      -- support for image pasting
      "HakonHarnes/img-clip.nvim",
      event = "VeryLazy",
      opts = {
        -- recommended settings
        default = {
          embed_image_as_base64 = false,
          prompt_for_file_name = false,
          drag_and_drop = {
            insert_mode = true,
          },
          -- required for Windows users
          use_absolute_path = true,
        },
      },
    },
    {
      -- Make sure to set this up properly if you have lazy=true
      'MeanderingProgrammer/render-markdown.nvim',
      opts = {
        -- file_types = { "markdown", "Avante" },
           exclude_filetypes = {
          "avante",
          "avante-input",
          "avante-selected-code",
          "Avante",
          "AvanteInput"
        },
      },
      -- ft = { "markdown", "Avante" },
    },
  },
}
