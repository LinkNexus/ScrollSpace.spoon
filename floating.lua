local Timer <const> = hs.timer
local Window <const> = hs.window

local Floating = {}
Floating.__index = Floating

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Floating.init(scrollspace)
    Floating.ScrollSpace = scrollspace
end

---return true if window is floating, false if not
---@param window Window
---@return boolean
function Floating.isFloating(window)
    return Floating.ScrollSpace.state.is_floating[window:id()] ~= nil
end

---remove window from the floating list before it is destroyed
---@param window Window
function Floating.removeFloating(window)
    Floating.ScrollSpace.state.is_floating[window:id()] = nil
end

---add or remove focused window from the floating layer and retile the workspace.
---floating windows are still assigned to a workspace (they hide/show with it,
---see workspace.lua's switchWorkspace) -- they're just excluded from tileColumn math.
---@param window Window|nil optional window to float and focus
function Floating.toggleFloating(window)
    window = window or Window.focusedWindow()
    if not window then
        Floating.ScrollSpace.logger.d("focused window not found")
        return
    end

    local workspace
    if Floating.isFloating(window) then
        -- un-float: remove from is_floating, add back into tiled window_list
        -- on the SAME workspace it was floating on (explicit workspace, not
        -- Rules.assign -- rules could otherwise send it somewhere else)
        workspace = Floating.ScrollSpace.state.is_floating[window:id()]
        Floating.removeFloating(window)
        Floating.ScrollSpace.windows.addWindow(window, workspace)
    else
        -- float: remove from tiled window_list, add to is_floating tagged with its workspace
        local index = Floating.ScrollSpace.state.windowIndex(window)
        workspace = index and index.workspace or Floating.ScrollSpace.state.current_workspace
        Floating.ScrollSpace.windows.removeWindow(window, true)
        Floating.ScrollSpace.state.is_floating[window:id()] = workspace
    end

    if workspace then
        window:focus()
        Floating.ScrollSpace:tileWorkspace(workspace)
    end

    Floating.ScrollSpace.state.save()
end

---every window on screen right now that isn't part of the tiled strip, in a
---stable order: the workspace's own floating windows first (is_floating,
---ordered by window id -- pairs() over it has no defined order), then any
---visible window ScrollSpace doesn't track at all.
---
---That second group is deliberate: windows excluded at the window_filter
---level (Finder, System Settings, and anything else the user filters out)
---are never tiled and never minimized by a workspace switch, so they float
---in exactly the same way from the user's point of view -- and, being
---outside window_list, focusWindow can't reach them either. Non-standard
---windows and picture-in-picture panels are left out: focusing a PiP panel
---would defeat the point of it staying out of the way.
---@param workspace number
---@return Window[]
function Floating.floatingWindows(workspace)
    local state = Floating.ScrollSpace.state
    local by_id = function(a, b) return a:id() < b:id() end

    local floating = {}
    for id, floating_workspace in pairs(state.is_floating) do
        if floating_workspace == workspace then
            local window = Window.get(id)
            if window and not window:isMinimized() then
                table.insert(floating, window)
            end
        end
    end
    table.sort(floating, by_id)

    local untracked = {}
    for _, window in ipairs(Window.visibleWindows()) do
        local id = window:id()
        local subrole = window:subrole()
        local is_pip = subrole and Floating.ScrollSpace.pip_subroles[subrole]
        if id and not state.isTiled(id) and state.is_floating[id] == nil
            and state.scratchpad ~= id and not is_pip and window:isStandard() then
            table.insert(untracked, window)
        end
    end
    table.sort(untracked, by_id)

    for _, window in ipairs(untracked) do table.insert(floating, window) end
    return floating
end

---bring the floating layer to the front and focus one of its windows.
---Floating windows are excluded from tiling math, so a tiled window laid
---over the same area simply covers them, and focusWindow can't dig them
---back out -- it only walks window_list, which floating windows aren't in.
---
---macOS has no dependable cross-app "raise without activating"
---(window:raise() only reorders within the window's own app), so every
---floating window is focused in turn: that activates each one's app and
---pulls it above the tiled strip. The target is focused last so it ends up
---on top and keeps the focus. Repeated calls cycle through the layer.
---@return Window|nil the window left focused
function Floating.focusFloating()
    local windows = Floating.floatingWindows(Floating.ScrollSpace.state.current_workspace)
    if #windows == 0 then
        Floating.ScrollSpace.logger.d("no visible floating windows on the current workspace")
        return
    end

    -- cycle: if the focus is already on a floating window, move on to the
    -- next one, so holding the hotkey walks the layer instead of toggling
    -- between the same two windows
    local target_index = 1
    local focused = Window.focusedWindow()
    if focused then
        for i, window in ipairs(windows) do
            if window:id() == focused:id() then
                target_index = (i % #windows) + 1
                break
            end
        end
    end
    local target = windows[target_index]

    for _, window in ipairs(windows) do
        if window ~= target then window:focus() end
    end
    target:focus()

    -- try to prevent MacOS from stealing focus away to another window,
    -- same guard windows.focusWindow uses
    Timer.doAfter(Window.animationDuration, function()
        if Window.focusedWindow() ~= target then target:focus() end
    end)

    return target
end

return Floating
