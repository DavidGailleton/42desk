-- {{MARK}}
local wezterm = require("wezterm")

return {
    font = wezterm.font("{{FONT}}"),
    font_size = {{FONT_SIZE}},
    window_padding = { left = 10, right = 10, top = 10, bottom = 10 },
    hide_tab_bar_if_only_one_tab = true,
    colors = {
        foreground = "{{FG}}",
        background = "{{BG}}",
        cursor_bg = "{{ACCENT}}",
        cursor_border = "{{ACCENT}}",
        cursor_fg = "{{BG}}",
        selection_bg = "{{ACCENT}}",
        selection_fg = "{{BG}}",
        ansi = { "{{C0}}", "{{C1}}", "{{C2}}", "{{C3}}", "{{C4}}", "{{C5}}", "{{C6}}", "{{C7}}" },
        brights = { "{{C8}}", "{{C9}}", "{{C10}}", "{{C11}}", "{{C12}}", "{{C13}}", "{{C14}}", "{{C15}}" },
    },
}
