vim.defer_fn(function()
require("interestingwords").setup {
    colors = {
      '#f5e0dc', -- Rosewater
      '#f2cdcd', -- Flamingo
      '#f5c2e7', -- Pink
      '#cba6f7', -- Mauve
      '#f38ba8', -- Red
      '#fab387', -- Peach
      '#f9e2af', -- Yellow
      '#a6e3a1', -- Green
      '#94e2d5', -- Teal
      '#89dceb', -- Sky
      '#89b4fa', -- Blue
      '#b4befe', -- Lavender
    },
    search_count = true,
    navigation = true,
    scroll_center = false,
    search_key = "<leader>m",
    cancel_search_key = "<leader>M",
    color_key = "<leader>k",
    cancel_color_key = "<leader>K",
    select_mode = "random",  -- random or loop
}
end, 1000)
