return {
	{
    'nvim-telescope/telescope.nvim', tag = 'v0.2.1',
    dependencies = {
        'nvim-lua/plenary.nvim',
        -- optional but recommended
        { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make' },
	{ 
        "nvim-telescope/telescope-live-grep-args.nvim" ,
        -- This will not install any breaking changes.
        -- For major updates, this must be adjusted manually.
        version = "^1.0.0",
	},
    }
},
{"nvim-tree/nvim-tree.lua", tag = "v1.16.0"},
{"nvim-tree/nvim-web-devicons"},
{
  "folke/tokyonight.nvim",
  lazy = false,
  priority = 1000,
  opts = {},
},
{ -- Adds git related signs to the gutter, as well as utilities for managing changes
    'lewis6991/gitsigns.nvim',
    tag = "v2.0.0",
    ---@module 'gitsigns'
    ---@type Gitsigns.Config
    ---@diagnostic disable-next-line: missing-fields
    opts = {
      signs = {
        add = { text = '+' }, ---@diagnostic disable-line: missing-fields
        change = { text = '~' }, ---@diagnostic disable-line: missing-fields
        delete = { text = '_' }, ---@diagnostic disable-line: missing-fields
        topdelete = { text = '‾' }, ---@diagnostic disable-line: missing-fields
        changedelete = { text = '~' }, ---@diagnostic disable-line: missing-fields
      },
    },
  },
  {"mfussenegger/nvim-lint" },
{'akinsho/bufferline.nvim', version = "*", dependencies = 'nvim-tree/nvim-web-devicons'},
{"Mr-LLLLL/interestingwords.nvim"},
{"phaazon/hop.nvim", event = "BufRead", commit="1a1eceafe54b5081eae4cb91c723abd1d450f34b",
        config = function ()
            require("hop").setup()
            vim.api.nvim_set_keymap("n", "s", ":HopChar2<cr>", {silent = true})
            vim.api.nvim_set_keymap("n", "S", ":HopWord<cr>", {silent = true})
        end},
{
    'nvim-lualine/lualine.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' }
},
{
    'windwp/nvim-autopairs',
    event = "InsertEnter",
    config = true
    -- use opts = {} for passing setup options
    -- this is equivalent to setup({}) function
},
-- 在你的插件安装列表里添加
{ "famiu/bufdelete.nvim" },
{
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    tag = "v3.9.1",
    ---@module "ibl"
    ---@type ibl.config
    opts = {},
},
{'akinsho/toggleterm.nvim', version = "*"},
-- {
--     "SmiteshP/nvim-navic",
--     dependencies = {"neovim/nvim-lspconfig"},
--     config = true
-- },
{
    'Bekaboo/dropbar.nvim',
    tag = "v14.2.1",
    -- optional, but required for fuzzy finder support
    dependencies = {
      'nvim-telescope/telescope-fzf-native.nvim',
      build = 'make'
    },
    config = function()
      local dropbar_api = require('dropbar.api')
      -- vim.keymap.set('n', '<Leader>;', dropbar_api.pick, { desc = 'Pick symbols in winbar' })
      vim.keymap.set('n', '<leader>lb', dropbar_api.goto_context_start, { desc = 'Go to start of current context' })
      -- vim.keymap.set('n', '];', dropbar_api.select_next_context, { desc = 'Select next context' })
    end
},
}
