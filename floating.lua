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
        Floating.ScrollSpace.workspace.addWindow(window, workspace)
    else
        -- float: remove from tiled window_list, add to is_floating tagged with its workspace
        local index = Floating.ScrollSpace.state.windowIndex(window)
        workspace = index and index.workspace or Floating.ScrollSpace.state.current_workspace
        Floating.ScrollSpace.workspace.removeWindow(window, true)
        Floating.ScrollSpace.state.is_floating[window:id()] = workspace
    end

    if workspace then
        window:focus()
        Floating.ScrollSpace:tileWorkspace(workspace)
    end

    Floating.ScrollSpace.state.save()
end

return Floating
