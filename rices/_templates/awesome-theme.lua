-- {{MARK}}
-- awesome theme for the {{NAME}} rice: the default theme, recolored.
local gears = require("gears")
local dpi = require("beautiful.xresources").apply_dpi

local theme = dofile(gears.filesystem.get_themes_dir() .. "default/theme.lua")

theme.font = "{{FONT}} {{FONT_SIZE_SMALL}}"
theme.icon_theme = "{{ICONS}}"
theme.wallpaper = "{{WALLPAPER}}"

theme.bg_normal = "{{BG}}"
theme.bg_focus = "{{BG_ALT}}"
theme.bg_urgent = "{{URGENT}}"
theme.bg_minimize = "{{BG}}"
theme.bg_systray = "{{BG}}"
theme.fg_normal = "{{FG}}"
theme.fg_focus = "{{ACCENT}}"
theme.fg_urgent = "{{BG}}"
theme.fg_minimize = "{{FG_DIM}}"

theme.useless_gap = dpi({{GAP_HALF}})
theme.border_width = dpi({{BORDER}})
theme.border_normal = "{{BG_ALT}}"
theme.border_focus = "{{ACCENT}}"
theme.border_marked = "{{URGENT}}"

theme.taglist_bg_focus = "{{ACCENT}}"
theme.taglist_fg_focus = "{{BG}}"
theme.tasklist_bg_focus = "{{BG_ALT}}"
theme.tasklist_fg_focus = "{{FG}}"
theme.titlebar_bg_focus = "{{BG_ALT}}"
theme.titlebar_bg_normal = "{{BG}}"
theme.menu_bg_focus = "{{ACCENT}}"
theme.menu_fg_focus = "{{BG}}"
theme.menu_border_color = "{{ACCENT}}"
theme.hotkeys_bg = "{{BG}}"
theme.hotkeys_fg = "{{FG}}"
theme.hotkeys_modifiers_fg = "{{ACCENT}}"
theme.hotkeys_border_color = "{{ACCENT}}"
theme.notification_bg = "{{BG}}"
theme.notification_fg = "{{FG}}"
theme.notification_border_color = "{{ACCENT}}"

return theme
