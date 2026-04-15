return {
  -- 补全引擎主插件
  {
    "hrsh7th/nvim-cmp",
    event = { "InsertEnter"}, -- 懒加载：进入插入模式或命令行模式时加载
    dependencies = {
      "hrsh7th/cmp-nvim-lsp",     -- LSP 补全源
      "hrsh7th/cmp-buffer",       -- 文本缓冲区补全源
      "hrsh7th/cmp-path",         -- 文件路径补全源
      "hrsh7th/cmp-cmdline",      -- 命令行补全源
      "saadparwaiz1/cmp_luasnip", -- snippet 补全源
      {
        "L3MON4D3/LuaSnip",       -- snippet 引擎
        version = "v2.*",
        build = "make install_jsregexp",
        dependencies = { "rafamadriz/friendly-snippets" }, -- 预定义的代码片段库
      },
      "onsails/lspkind.nvim",     -- 补全菜单的美化图标
    },
    config = function()
      local cmp = require("cmp")
      local luasnip = require("luasnip")
      local lspkind = require("lspkind")

      -- 加载 friendly-snippets
      require("luasnip.loaders.from_vscode").lazy_load()

      cmp.setup({
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        window = {
          completion = cmp.config.window.bordered(), -- 补全窗口边框
          documentation = cmp.config.window.bordered(), -- 文档窗口边框
        },
        mapping = cmp.mapping.preset.insert({
          ["<C-k>"] = cmp.mapping.select_prev_item(), -- 上移
          ["<C-j>"] = cmp.mapping.select_next_item(), -- 下移
          ["<C-d>"] = cmp.mapping.scroll_docs(-4),
          ["<C-f>"] = cmp.mapping.scroll_docs(4),
          ["<C-Space>"] = cmp.mapping.complete(),     -- 手动触发补全
          ["<C-e>"] = cmp.mapping.abort(),            -- 取消补全
          ["<CR>"] = cmp.mapping.confirm({ select = true }), -- 回车确认
          
          -- Tab 键处理 (兼容 snippet 跳转)
          ["<Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_next_item()
            elseif luasnip.expand_or_jumpable() then
              luasnip.expand_or_jump()
            else
              fallback()
            end
          end, { "i", "s" }),
          
          ["<S-Tab>"] = cmp.mapping(function(fallback)
            if cmp.visible() then
              cmp.select_prev_item()
            elseif luasnip.jumpable(-1) then
              luasnip.jump(-1)
            else
              fallback()
            end
          end, { "i", "s" }),
        }),
        
        -- 补全数据源 (顺序决定权重)
        sources = cmp.config.sources({
          { name = "nvim_lsp" },   -- LSP 
          -- { name = "luasnip" },    -- Snippets
          { name = "buffer" },     -- 文本内容
          { name = "path" },       -- 路径
        }),

        -- 菜单美化
        formatting = {
          format = lspkind.cmp_format({
            mode = 'symbol_text', 
            maxwidth = 50,
            ellipsis_char = '...',
            before = function (entry, vim_item)
              return vim_item
            end
          })
        },
      })

      -- / 模式补全
      cmp.setup.cmdline('/', {
        mapping = cmp.mapping.preset.cmdline(),
        sources = {
          { name = 'buffer' }
        }
      })

      -- : 模式补全
      cmp.setup.cmdline(':', {
        mapping = cmp.mapping.preset.cmdline(),
        sources = cmp.config.sources({
          { name = 'path' }
        }, {
          { name = 'cmdline' }
        })
      })
    end,
  },
}
