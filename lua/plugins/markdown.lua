return {
      -- Make sure to set this up properly if you have lazy=true
      'MeanderingProgrammer/render-markdown.nvim',
      opts = {
        file_types = { "markdown", "Avante", "codecompanion" },
           exclude_filetypes = {
          "avante",
          "avante-input",
          "avante-selected-code",
          "Avante",
          "AvanteInput"
        },
        code = {
          highlight_inline = "RenderMarkdownCodeInline",
          -- diff 自带 +/- 配色，跳过 render-markdown 背景以免盖住 Treesitter
          disable_background = { "diff" },
        },
      },
      config = function(_, opts)
        require("render-markdown").setup(opts)

        local function clear_inline_code_bg()
          vim.api.nvim_set_hl(0, "RenderMarkdownCodeInline", { bg = "NONE" })
          vim.api.nvim_set_hl(0, "@markup.raw", { bg = "NONE" })
          vim.api.nvim_set_hl(0, "@markup.raw.markdown_inline", { bg = "NONE" })
          vim.api.nvim_set_hl(0, "@text.literal", { bg = "NONE" })
          vim.api.nvim_set_hl(0, "@text.literal.markdown_inline", { bg = "NONE" })
        end

        local function link_diff_hl()
          -- 统一 diff 代码块配色（依赖 treesitter diff 解析器）
          vim.api.nvim_set_hl(0, "@diff.plus", { link = "DiffAdd", default = true })
          vim.api.nvim_set_hl(0, "@diff.minus", { link = "DiffDelete", default = true })
        end

        clear_inline_code_bg()
        link_diff_hl()
        vim.api.nvim_create_autocmd("ColorScheme", {
          pattern = "*",
          callback = function()
            clear_inline_code_bg()
            link_diff_hl()
          end,
        })
      end,
      ft = { "markdown", "Avante", "codecompanion"},
    }
