local Window <const> = hs.window

local Workspace = {}
Workspace.__index = Workspace

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Workspace.init(scrollspace)
    Workspace.ScrollSpace = scrollspace
end

---minimize every window (tiled + floating) belonging to a workspace
---@param workspace number
local function hide_workspace(workspace)
    local state = Workspace.ScrollSpace.state
    for _, columns in pairs(state.windowList(workspace)) do
        for _, column in ipairs(columns) do
            for _, window in ipairs(column) do
                window:minimize()
            end
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
local function show_workspace(workspace)
    local state = Workspace.ScrollSpace.state
    for _, columns in pairs(state.windowList(workspace)) do
        for _, column in ipairs(columns) do
            for _, window in ipairs(column) do
                window:unminimize()
            end
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

    hide_workspace(previous)
    state.current_workspace = n
    show_workspace(n)

    Workspace.ScrollSpace:tileWorkspace(n)

    local last_window = state.last_focused[n] and Window.get(state.last_focused[n])
    if last_window and not last_window:isMinimized() then
        last_window:focus()
    else
        -- no remembered window: fall back to the leftmost column of the
        -- main display's strip, then any other strip. pairs() order over
        -- the strip buckets is arbitrary, so pick the main display's strip
        -- explicitly rather than landing on a random monitor
        local main_screen = hs.screen.mainScreen()
        local preferred = main_screen and state.resolveStrip(main_screen:getUUID())
        local fallback = nil
        for strip, columns in pairs(state.windowList(n)) do
            local window = columns[1] and columns[1][1]
            if window and not window:isMinimized() then
                if strip == preferred then
                    fallback = window
                    break
                end
                fallback = fallback or window
            end
        end
        if fallback then fallback:focus() end
    end

    state.save()
end

---move a window to another workspace: list surgery only (remove from its
---current column, insert as a new column at the end of the target
---workspace's list, on the SAME screen it was already on), keeping its
---uielement watcher alive. The window's minimized state is then matched
---to whether the target workspace is the active one.
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
        table.remove(state.windowList(index.workspace, index.strip, index.col), index.row)
        table.insert(state.windowList(n, index.strip), { window })
    end

    if n == current then
        -- moving onto the active workspace: the window may have been
        -- hidden with the workspace it came from, so show it again
        if window:isMinimized() then window:unminimize() end
        Workspace.ScrollSpace:tileWorkspace(n)
    else
        window:minimize()
        Workspace.ScrollSpace:tileWorkspace(current)
    end

    state.save()
end

---move a window to the next strip (cycling, wraps around), keeping it on
---the same workspace: list surgery only (remove from its current strip's
---column, insert as a new column at the end of the target strip's list),
---same shape as moveWindowToWorkspace above but keyed by strip instead of
---workspace.
---
---Strips, not displays: within a side-by-side run of displays the column
---sequence already flows across them, so there is nothing to move the
---window *to* -- scrolling the strip is what puts a window on the next
---display over. This action is for the case displays genuinely are
---separate strips, i.e. stacked vertically, so it no-ops on a setup whose
---displays all form a single strip.
---
---Floating/scratchpad windows have no strip in this data model (they're
---just minimized/unminimized wherever the OS already put them), so this
---is a no-op for them.
---@param window Window|nil defaults to the focused window
function Workspace.moveWindowToNextStrip(window)
    window = window or Window.focusedWindow()
    if not window then
        Workspace.ScrollSpace.logger.d("focused window not found")
        return
    end

    local state = Workspace.ScrollSpace.state
    local index = state.windowIndex(window)
    if not index then
        Workspace.ScrollSpace.logger.d(
            "window is not tiled (floating/scratchpad windows don't have a strip to move between)")
        return
    end

    local groups = Workspace.ScrollSpace.screens.groups()
    if #groups < 2 then return end

    local current_pos = nil
    for i, group in ipairs(groups) do
        if group.key == index.strip then
            current_pos = i
            break
        end
    end
    if not current_pos then
        Workspace.ScrollSpace.logger.e("window's strip not found among the connected displays")
        return
    end

    local target = groups[(current_pos % #groups) + 1]

    table.remove(state.windowList(index.workspace, index.strip, index.col), index.row)
    table.insert(state.windowList(index.workspace, target.key), { window })

    Workspace.ScrollSpace:tileWorkspace(index.workspace)
    state.save()
end

return Workspace
