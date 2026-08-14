local Window <const> = hs.window

local Workspace = {}
Workspace.__index = Workspace

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Workspace.init(scrollspace)
    Workspace.ScrollSpace = scrollspace
end

---add a new window to be tracked and automatically tiled. Assigns a
---workspace via Rules.assign unless `workspace` is given explicitly (used
---when re-inserting a window that already had a known workspace, e.g.
---un-floating -- re-running rules there could send it somewhere other than
---where it was floating). Windows assigned to a workspace other than the
---currently active one are minimized immediately so they don't appear on
---screen while some other workspace is showing.
---@param add_window Window new window to be added
---@param workspace number|nil explicit target workspace, skips Rules.assign
---@return number|nil workspace that contains the new window
function Workspace.addWindow(add_window, workspace)
    local state = Workspace.ScrollSpace.state

    -- A window with no tabs will have a tabCount of 0 or 1. Built-in Apple
    -- apps like Finder/Terminal show each tab as a separate window that
    -- can't be told apart from a real window after creation -- same quirk
    -- PaperWM works around.
    local apple <const> = "com.apple"
    local safari <const> = "com.apple.Safari"
    local app = add_window:application()
    local bundle_id = app and app:bundleID()
    if add_window:tabCount() > 1 and bundle_id
        and bundle_id:sub(1, #apple) == apple
        and bundle_id:sub(1, #safari) ~= safari then
        hs.notify.show("ScrollSpace", "Windows with tabs are not supported!", "")
        Workspace.ScrollSpace.logger.w("ignoring window with tabs: " .. add_window:title())
        return
    end

    if not add_window:isMaximizable() then
        Workspace.ScrollSpace.logger.d("ignoring non-maximizable window")
        return
    end

    -- defensive second layer against picture-in-picture windows, on top of
    -- window_filter's allowRoles -- PiP windows are always static/global,
    -- never tracked/tiled/minimized
    local subrole = add_window:subrole()
    if subrole and Workspace.ScrollSpace.pip_subroles[subrole] then
        Workspace.ScrollSpace.logger.d("ignoring picture-in-picture window (subrole: " .. subrole .. ")")
        return
    end

    -- already tracked, tiled or floating
    if state.windowIndex(add_window) or Workspace.ScrollSpace.floating.isFloating(add_window) then
        return
    end

    workspace = workspace or Workspace.ScrollSpace.rule_engine.assign(add_window)

    -- find where to insert window
    local add_column = 1
    if state.prev_focused_window and
        ((state.windowIndex(state.prev_focused_window) or {}).workspace == workspace) and
        (state.prev_focused_window:id() ~= add_window:id()) then
        add_column = state.windowIndex(state.prev_focused_window).col + 1
    else
        local x = add_window:frame().center.x
        for col, windows in ipairs(state.windowList(workspace)) do
            if x < windows[1]:frame().center.x then
                add_column = col
                break
            else
                add_column = col + 1
            end
        end
    end

    table.insert(state.windowList(workspace), add_column, { add_window })
    state.uiWatcherCreate(add_window)

    Workspace.ScrollSpace.logger.df("adding window: %s (%d) to workspace %d", add_window:title(), add_window:id(),
        workspace)

    if workspace ~= state.current_workspace then
        add_window:minimize()
    end

    return workspace
end

---remove a window from being tracked and automatically tiled
---@param remove_window Window window to be removed
---@param skip_new_window_focus boolean|nil don't focus a nearby window if true
---@return number|nil workspace that contained removed window
---@return Window|nil newly focused window
function Workspace.removeWindow(remove_window, skip_new_window_focus)
    local state = Workspace.ScrollSpace.state
    local remove_index = state.windowIndex(remove_window, true)
    if not remove_index then
        return
    end

    local focused_window = nil
    if not skip_new_window_focus then
        local Direction = Workspace.ScrollSpace.windows.Direction
        for _, direction in ipairs({ Direction.DOWN, Direction.UP, Direction.LEFT, Direction.RIGHT }) do
            focused_window = Workspace.ScrollSpace.windows.focusWindow(direction, remove_index)
            if focused_window then break end
        end
    end

    if remove_window ~= table.remove(state.windowList(remove_index.workspace, remove_index.col), remove_index.row) then
        Workspace.ScrollSpace.logger.ef("removed window %s (%d) doesn't match", remove_window:title(),
            remove_window:id())
    end

    state.uiWatcherDelete(remove_window:id())
    state.xPositions(remove_index.workspace)[remove_window:id()] = nil

    if state.prev_focused_window == remove_window then
        state.prev_focused_window = nil
    end

    Workspace.ScrollSpace.logger.df("removing window: %s (%d)", remove_window:title(), remove_window:id())

    return remove_index.workspace, focused_window
end

---get all managed windows and retile any workspace that gained one
function Workspace.refreshWindows()
    local state = Workspace.ScrollSpace.state
    state.pruneDead()

    -- hs.window.allWindows(), not window_filter:getWindows() -- the
    -- latter only returns currently-visible windows, which would miss
    -- any minimized-but-untracked window entirely (e.g. one orphaned by
    -- a past bug, or an app that starts out minimized).
    local all_windows = hs.window.allWindows()

    -- isWindowAllowed(window) is unreliable on its own -- confirmed live
    -- (2026-08-14) that it can return false for a window that is visible,
    -- eligible, and even present in this exact window_filter's own
    -- getWindows() output moments earlier (a kitty.main window survived a
    -- theme-change-triggered prune/re-add and came back with a new
    -- CGWindowID; isWindowAllowed refused to ever let it back into
    -- tracking, permanently breaking that workspace's tiling until fixed
    -- by hand). getWindows() membership is the trustworthy signal for any
    -- currently-visible window since it's the same list events.lua's own
    -- subscriptions are built from; isWindowAllowed is only trusted as a
    -- fallback for windows getWindows() can't see at all (minimized ones)
    -- -- the orphan-recovery case this function exists for in the first
    -- place.
    local visible_allowed = {}
    for _, window in ipairs(Workspace.ScrollSpace.window_filter:getWindows()) do
        visible_allowed[window:id()] = true
    end

    local retile_workspaces = {}
    for _, window in ipairs(all_windows) do
        -- the scratchpad window is deliberately kept out of index_table
        -- too (not a workspace member, see scratchpad.lua) -- without
        -- this check it looks exactly like an untracked window and
        -- would get pulled back into a workspace's tiling. Pre-existing
        -- gap, not new: it could already trigger whenever the
        -- scratchpad window was visible, this change just makes it far
        -- more likely to hit (minimized scratchpad windows are now in
        -- scope too via allWindows()).
        if window:id() ~= state.scratchpad
            and (visible_allowed[window:id()] or Workspace.ScrollSpace.window_filter:isWindowAllowed(window))
            and not Workspace.ScrollSpace.floating.isFloating(window)
            and not state.windowIndex(window) then
            local workspace = Workspace.addWindow(window)
            if workspace then retile_workspaces[workspace] = true end
        end
    end

    for workspace, _ in pairs(retile_workspaces) do
        Workspace.ScrollSpace:tileWorkspace(workspace)
    end

    state.save()
end

---minimize every window (tiled + floating) belonging to a workspace
---@param workspace number
local function hideWorkspace(workspace)
    local state = Workspace.ScrollSpace.state
    for _, column in ipairs(state.windowList(workspace)) do
        for _, window in ipairs(column) do
            window:minimize()
        end
    end
    for id, floating_workspace in pairs(state.is_floating) do
        if floating_workspace == workspace then
            local window = Window.get(id)
            if window then window:minimize() end
        end
    end
end

---unminimize every window (tiled + floating) belonging to a workspace
---@param workspace number
local function showWorkspace(workspace)
    local state = Workspace.ScrollSpace.state
    for _, column in ipairs(state.windowList(workspace)) do
        for _, window in ipairs(column) do
            window:unminimize()
        end
    end
    for id, floating_workspace in pairs(state.is_floating) do
        if floating_workspace == workspace then
            local window = Window.get(id)
            if window then window:unminimize() end
        end
    end
end

---switch to another workspace: minimize everything on the current one,
---unminimize everything on the target one, retile, focus the target's
---last-focused window. Pure visibility operation -- layout position of
---hidden windows is never touched, so switching back needs no restore.
---@param n number target workspace id
function Workspace.switchWorkspace(n)
    local state = Workspace.ScrollSpace.state
    if n == state.current_workspace then return end

    local previous = state.current_workspace

    local focused = Window.focusedWindow()
    if focused then
        local index = state.windowIndex(focused)
        local floating_workspace = state.is_floating[focused:id()]
        if (index and index.workspace == previous) or floating_workspace == previous then
            state.last_focused[previous] = focused:id()
        end
    end

    hideWorkspace(previous)
    state.current_workspace = n
    showWorkspace(n)

    Workspace.ScrollSpace:tileWorkspace(n)

    local last_window = state.last_focused[n] and Window.get(state.last_focused[n])
    if last_window then
        last_window:focus()
    else
        local columns = state.windowList(n)
        if columns[1] and columns[1][1] then columns[1][1]:focus() end
    end

    state.save()
end

---move a window to another workspace: list surgery only (remove from its
---current column, insert as a new column at the end of the target
---workspace's list), keeping its uielement watcher alive. Minimizes the
---window if the target workspace isn't the active one.
---@param window Window|nil defaults to the focused window
---@param n number target workspace id
function Workspace.moveWindowToWorkspace(window, n)
    window = window or Window.focusedWindow()
    if not window then
        Workspace.ScrollSpace.logger.d("focused window not found")
        return
    end

    local state = Workspace.ScrollSpace.state
    local current = state.current_workspace

    if Workspace.ScrollSpace.floating.isFloating(window) then
        if state.is_floating[window:id()] == n then return end
        state.is_floating[window:id()] = n
    else
        local index = state.windowIndex(window)
        if not index then
            Workspace.ScrollSpace.logger.e("window index not found")
            return
        end
        if index.workspace == n then return end
        table.remove(state.windowList(index.workspace, index.col), index.row)
        table.insert(state.windowList(n), { window })
    end

    if n == current then
        Workspace.ScrollSpace:tileWorkspace(n)
    else
        window:minimize()
        Workspace.ScrollSpace:tileWorkspace(current)
    end

    state.save()
end

return Workspace
