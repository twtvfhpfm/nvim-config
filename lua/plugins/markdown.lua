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

        clear_inline_code_bg()
        vim.api.nvim_create_autocmd("ColorScheme", {
          pattern = "*",
          callback = clear_inline_code_bg,
        })
      end,
      ft = { "markdown", "Avante", "codecompanion"},
    }
