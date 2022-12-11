return {
    tools = {
        runnables = {
            use_telescope = true,
        },
        autoSetHints = true,
        hover_with_actions = true,
        inlay_hints = {
            show_parameter_hints = true,
            parameter_hints_prefix = "",
            other_hints_prefix = "",
        }
    },

    server = {
        settings = {
            ["rust-analyzer"] = {
                cargo = {
                    allFeatures = true
                }
            }
        }
    }
}
