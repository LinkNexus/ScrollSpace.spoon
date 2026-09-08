local WindowFilter <const> = hs.window.filter

local Config = {}
Config.__index = Config

---default hotkey mapping, same naming convention as PaperWM's default_hotkeys
Config.default_hotkeys = {
    stop_events         = { { "alt", "cmd", "shift" }, "q" },
    refresh_windows     = { { "alt", "cmd", "shift" }, "r" },
    dump_state          = { { "alt", "cmd", "shift" }, "d" },
    focus_left          = { { "alt", "cmd" }, "left" },
    focus_right         = { { "alt", "cmd" }, "right" },
    focus_up            = { { "alt", "cmd" }, "up" },
    focus_down          = { { "alt", "cmd" }, "down" },
    swap_left           = { { "alt", "cmd", "shift" }, "left" },
    swap_right          = { { "alt", "cmd", "shift" }, "right" },
    swap_up             = { { "alt", "cmd", "shift" }, "up" },
    swap_down           = { { "alt", "cmd", "shift" }, "down" },
    cycle_width         = { { "alt", "cmd" }, "r" },
    center_window       = { { "alt", "cmd" }, "c" },
    full_width          = { { "alt", "cmd" }, "f" },
    slurp_in            = { { "alt", "cmd" }, "," },
    barf_out            = { { "alt", "cmd", "shift" }, "," },
    toggle_floating     = { { "alt", "cmd", "shift" }, "escape" },
    move_window_to_next_screen = { { "alt", "cmd" }, "o" },
    toggle_scratchpad   = { { "alt", "cmd" }, "s" },
    set_scratchpad      = { { "alt", "cmd", "shift" }, "s" },
    switch_workspace_1  = { { "alt", "cmd" }, "1" },
    switch_workspace_2  = { { "alt", "cmd" }, "2" },
    switch_workspace_3  = { { "alt", "cmd" }, "3" },
    switch_workspace_4  = { { "alt", "cmd" }, "4" },
    switch_workspace_5  = { { "alt", "cmd" }, "5" },
    switch_workspace_6  = { { "alt", "cmd" }, "6" },
    switch_workspace_7  = { { "alt", "cmd" }, "7" },
    switch_workspace_8  = { { "alt", "cmd" }, "8" },
    switch_workspace_9  = { { "alt", "cmd" }, "9" },
    move_window_1       = { { "alt", "cmd", "shift" }, "1" },
    move_window_2       = { { "alt", "cmd", "shift" }, "2" },
    move_window_3       = { { "alt", "cmd", "shift" }, "3" },
    move_window_4       = { { "alt", "cmd", "shift" }, "4" },
    move_window_5       = { { "alt", "cmd", "shift" }, "5" },
    move_window_6       = { { "alt", "cmd", "shift" }, "6" },
    move_window_7       = { { "alt", "cmd", "shift" }, "7" },
    move_window_8       = { { "alt", "cmd", "shift" }, "8" },
    move_window_9       = { { "alt", "cmd", "shift" }, "9" },
}

---filter for windows to manage. allowRoles already excludes most
---non-standard windows (PiP included, in practice); a defensive
---window:subrole() check against known PiP subroles is applied in
---windows.lua's addWindow as a second layer, since native PiP windows
---aren't reliably distinguishable through the window_filter API alone.
Config.window_filter = WindowFilter.new():setOverrideFilter({
    visible = true,
    fullscreen = false,
    hasTitlebar = true,
    allowRoles = "AXStandardWindow",
})

---subrole values known to be reported by native picture-in-picture windows
---(observed on Safari/Chrome video PiP). Best-effort set: confirm against
---`hs.window.focusedWindow():subrole()` on an actual PiP window and extend
---if a given browser/app reports something else.
Config.pip_subroles = {
    AXSystemFloatingWindow = true,
    AXFloatingWindow = true,
}

---window gaps: can be set as a single number or a table with top, bottom, left, right values
Config.window_gap = 8 ---@type number|{ top: number, bottom: number, left: number, right: number }

---ratios to use when cycling widths, golden ratio by default
Config.window_ratios = { 0.23607, 0.38195, 0.61804 } ---@type number[]

---size of the on-screen margin to place off-screen windows
Config.screen_margin = 1 ---@type number

---wrap focus around when reaching the edge of the window list
Config.infinite_loop_window = false ---@type boolean

---per-window assignment rules, evaluated at window creation against app
---name + window title using Lua patterns. First matching rule wins; no
---match falls back to current_workspace.
---@type { app: string, title: string?, workspace: number }[]
Config.rules = {}

---workspace to use for windows that don't match any rule and are created
---before any workspace has been switched to
Config.default_workspace = 1 ---@type number

---file to persist window_list/index_table/floating/scratchpad/current_workspace to,
---so state survives hs.reload() and can be read by external consumers (e.g. sketchybar)
Config.state_file = os.getenv("HOME") .. "/.hammerspoon/scrollspace-state.json" ---@type string

return Config
