local fn = vim.fn

-- Automatically install packer
local install_path = fn.stdpath("data") .. "/site/pack/packer/start/packer.nvim"
if fn.empty(fn.glob(install_path)) > 0 then
	PACKER_BOOTSTRAP = fn.system({
		"git",
		"clone",
		"--depth",
		"1",
		"https://github.com/wbthomason/packer.nvim",
		install_path,
	})
	print("Installing packer close and reopen Neovim...")
	vim.cmd([[packadd packer.nvim]])
end

-- Autocommand that reloads neovim whenever you save the plugins.lua file
vim.cmd([[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins.lua source <afile> | PackerSync
  augroup end
]])

-- Use a protected call so we don't error out on first use
local status_ok, packer = pcall(require, "packer")
if not status_ok then
	return
end

-- Have packer use a popup window
packer.init({
	display = {
		open_fn = function()
			return require("packer.util").float({ border = "rounded" })
		end,
	},
})

-- Install your plugins here
return packer.startup(function(use)
  use { "wbthomason/packer.nvim", commit="1d0cf98a561f7fd654c970c49f917d74fafe1530"} -- Have packer manage itself
  use { "nvim-lua/plenary.nvim", commit="253d34830709d690f013daf2853a9d21ad7accab"} -- Useful lua functions used by lots of plugins
  use { "windwp/nvim-autopairs", commit="e755f366721bc9e189ddecd39554559045ac0a18"} -- Autopairs, integrates with both cmp and treesitter
  use { "numToStr/Comment.nvim", commit="8d3aa5c22c2d45e788c7a5fe13ad77368b783c20"}
  use { "JoosepAlviste/nvim-ts-context-commentstring", commit="729d83ecb990dc2b30272833c213cc6d49ed5214"}
  use { "kyazdani42/nvim-web-devicons", commit="f1b1cee3a561590a6c1637a9326c406f6e4af914"}
  use { "kyazdani42/nvim-tree.lua", commit="1d79a64a88af47ddbb55f4805ab537d11d5b908e"}
  use { "akinsho/bufferline.nvim", commit="3677aceb9a72630b0613e56516c8f7151b86f95c"}
	use { "moll/vim-bbye", commit="25ef93ac5a87526111f43e5110675032dbcacf56"}
  use { "nvim-lualine/lualine.nvim", commit="e99d733e0213ceb8f548ae6551b04ae32e590c80"}
  use { "akinsho/toggleterm.nvim", commit="c8e982ad2739eeb0b13d0fecb14820c9bf5e3da0"}
  use { "ahmedkhalf/project.nvim", commit="1c2e9c93c7c85126c2197f5e770054f53b1926fb"}
  use { "lewis6991/impatient.nvim", commit="c90e273f7b8c50a02f956c24ce4804a47f18162e"}
  use { "lukas-reineke/indent-blankline.nvim", commit="018bd04d80c9a73d399c1061fa0c3b14a7614399"}
  use { "goolord/alpha-nvim", commit="3847d6baf74da61e57a13e071d8ca185f104dc96"}
	use {"folke/which-key.nvim", commit="fb027738340502b556c3f43051f113bcaa7e8e63"}

	-- Colorschemes
  use { "folke/tokyonight.nvim", commit="0f7b6a5b6cf232f34cb8f51123a084a6eee96b89"}
  use { "lunarvim/darkplus.nvim", commit="1826879d9cb14e5d93cd142d19f02b23840408a6"}

	-- Cmp 
  use { "hrsh7th/nvim-cmp", commit="feed47fd1da7a1bad2c7dca456ea19c8a5a9823a"} -- The completion plugin
  use { "hrsh7th/cmp-buffer", commit="3022dbc9166796b644a841a02de8dd1cc1d311fa"} -- buffer completions
  use { "hrsh7th/cmp-path", commit="91ff86cd9c29299a64f968ebb45846c485725f23"} -- path completions
	use { "saadparwaiz1/cmp_luasnip", commit="18095520391186d634a0045dacaa346291096566"} -- snippet completions
	use { "hrsh7th/cmp-nvim-lsp", commit="0e6b2ed705ddcff9738ec4ea838141654f12eeef"}
	use { "hrsh7th/cmp-nvim-lua", commit="f3491638d123cfd2c8048aefaf66d246ff250ca6"}

	-- Snippets
  use { "L3MON4D3/LuaSnip", commit="a835e3d680c5940b61780c6af07885db95382478"} --snippet engine
  use { "rafamadriz/friendly-snippets", commit="2f5b8a41659a19bd602497a35da8d81f1e88f6d9"} -- a bunch of snippets to use

	-- LSP
	use { "neovim/nvim-lspconfig", commit="4bb0f1845c5cc6465aecedc773fc2d619fcd8faf"} -- enable LSP
  use { "williamboman/mason.nvim", commit="441c9ea2ab385c2e6407a637775b4b392533d265"} -- simple to use language server installer
  use { "williamboman/mason-lspconfig.nvim", commit="3924f2d264097b2caf13e713485dbc3e9d616574"}
	use { "jose-elias-alvarez/null-ls.nvim", commit="09e99259f4cdd929e7fb5487bf9d92426ccf7cc1"} -- for formatters and linters
  use { "RRethy/vim-illuminate", commit="49062ab1dd8fec91833a69f0a1344223dd59d643"}

	-- Telescope
	use { "nvim-telescope/telescope.nvim",
		commit="a3f17d3baf70df58b9d3544ea30abe52a7a832c2",
        requires = {
            {"nvim-telescope/telescope-live-grep-args.nvim", commit="7de3baef1ec4fb77f7a8195fe87bebd513244b6a"},
        },
        config = function()
            require("telescope").load_extension("live_grep_args")
            require("telescope").load_extension("fzf")
        end
    }

	-- Treesitter
	use {
		"nvim-treesitter/nvim-treesitter",
		commit="89e5fa66cf53854f45cfcfae45afb93171cf5c05"
	}

	-- Git
	use { "lewis6991/gitsigns.nvim", commit="b1f9cf7c5c5639c006c937fc1819e09f358210fc"}
    use {"simrat39/rust-tools.nvim", commit="71d2cf67b5ed120a0e31b2c8adb210dd2834242f"}
    use {"phaazon/hop.nvim", event = "BufRead",
        config = function ()
            require("hop").setup()
            vim.api.nvim_set_keymap("n", "s", ":HopChar2<cr>", {silent = true})
            vim.api.nvim_set_keymap("n", "S", ":HopWord<cr>", {silent = true})
        end}
    use { "ojroques/vim-oscyank", commit="ffe827a27dae98aa826e2295336c650c9a434da0"}
	use { "fgheng/winbar.nvim", commit="13739fdb31be51a1000486189662596f07a59a31"}
	use { "SmiteshP/nvim-gps",
		commit= "f4734dff6fc2f33b5fd13412e56c4fce06650a74",
		requires = "nvim-treesitter/nvim-treesitter"
	}
	use {'mfussenegger/nvim-lint', commit="cadebae41e11610ba22a7c95dcf5ebc0f8af8f13"}
	use {'nvim-telescope/telescope-fzf-native.nvim', commit="580b6c48651cabb63455e97d7e131ed557b8c7e2", run = 'make' }

	-- Automatically set up your configuration after cloning packer.nvim
	-- Put this at the end after all plugins
	if PACKER_BOOTSTRAP then
		require("packer").sync()
	end
end)
