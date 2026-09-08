local Fnutils <const> = hs.fnutils

local Actions = {}
Actions.__index = Actions

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Actions.init(scrollspace)
    Actions.ScrollSpace = scrollspace
end

---supported actions, same naming convention as PaperWM's default_hotkeys
---for familiarity (see config.lua's default_hotkeys)
function Actions.actions()
    local Direction = Actions.ScrollSpace.windows.Direction
    local spec = {
        stop_events = Fnutils.partial(Actions.ScrollSpace.stop, Actions.ScrollSpace),
        refresh_windows = Actions.ScrollSpace.windows.refreshWindows,
        dump_state = Actions.ScrollSpace.state.dump,
        focus_left = Fnutils.partial(Actions.ScrollSpace.windows.focusWindow, Direction.LEFT),
        focus_right = Fnutils.partial(Actions.ScrollSpace.windows.focusWindow, Direction.RIGHT),
        focus_up = Fnutils.partial(Actions.ScrollSpace.windows.focusWindow, Direction.UP),
        focus_down = Fnutils.partial(Actions.ScrollSpace.windows.focusWindow, Direction.DOWN),
        swap_left = Fnutils.partial(Actions.ScrollSpace.windows.swapWindows, Direction.LEFT),
        swap_right = Fnutils.partial(Actions.ScrollSpace.windows.swapWindows, Direction.RIGHT),
        swap_up = Fnutils.partial(Actions.ScrollSpace.windows.swapWindows, Direction.UP),
        swap_down = Fnutils.partial(Actions.ScrollSpace.windows.swapWindows, Direction.DOWN),
        cycle_width = Fnutils.partial(Actions.ScrollSpace.windows.cycleWindowSize, Direction.ASCENDING),
        center_window = Actions.ScrollSpace.windows.centerWindow,
        full_width = Actions.ScrollSpace.windows.toggleWindowFullWidth,
        slurp_in = Actions.ScrollSpace.windows.slurpWindow,
        barf_out = Actions.ScrollSpace.windows.barfWindow,
        toggle_floating = Actions.ScrollSpace.floating.toggleFloating,
        move_window_to_next_screen = Actions.ScrollSpace.workspace.moveWindowToNextScreen,
        toggle_scratchpad = Actions.ScrollSpace.scratchpad.toggleScratchpad,
        set_scratchpad = Actions.ScrollSpace.scratchpad.setScratchpad,
    }

    for n = 1, 9 do
        spec["switch_workspace_" .. n] = Fnutils.partial(Actions.ScrollSpace.workspace.switchWorkspace, n)
        spec["move_window_" .. n] = function()
            Actions.ScrollSpace.workspace.moveWindowToWorkspace(nil, n)
        end
    end

    return spec
end

---bind userdefined hotkeys to ScrollSpace actions
---use ScrollSpace.default_hotkeys for suggested defaults
---@param mapping table table of actions and hotkeys
function Actions.bindHotkeys(mapping)
    local spec = Actions.actions()
    hs.spoons.bindHotkeysToSpec(spec, mapping)
end

return Actions
