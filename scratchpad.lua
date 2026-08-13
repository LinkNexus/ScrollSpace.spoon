local Window <const> = hs.window

local Scratchpad = {}
Scratchpad.__index = Scratchpad

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Scratchpad.init(scrollspace)
    Scratchpad.ScrollSpace = scrollspace
end

---assign a window as the scratchpad: pull it out of window_list/index_table
---(or is_floating) entirely -- it's not a workspace member and isn't tiled --
---then minimize it. If a different scratchpad was already set, that window
---is released back into the current workspace first so it isn't stranded
---outside all tracking.
---@param window Window|nil defaults to the focused window
function Scratchpad.setScratchpad(window)
    local ScrollSpace = Scratchpad.ScrollSpace
    local state = ScrollSpace.state

    window = window or Window.focusedWindow()
    if not window then
        ScrollSpace.logger.d("focused window not found")
        return
    end

    if state.scratchpad and state.scratchpad ~= window:id() then
        local old = Window.get(state.scratchpad)
        state.scratchpad = nil
        if old then
            local workspace = ScrollSpace.workspace.addWindow(old)
            if workspace then ScrollSpace:tileWorkspace(workspace) end
        end
    end

    if ScrollSpace.floating.isFloating(window) then
        ScrollSpace.floating.removeFloating(window)
    elseif state.windowIndex(window) then
        local workspace = ScrollSpace.workspace.removeWindow(window, true)
        if workspace then ScrollSpace:tileWorkspace(workspace) end
    end

    state.scratchpad = window:id()
    window:minimize()
    state.save()
end

---toggle the scratchpad window: unminimize + focus if hidden, minimize if
---shown. Works from any workspace, independent of current_workspace.
function Scratchpad.toggleScratchpad()
    local state = Scratchpad.ScrollSpace.state
    if not state.scratchpad then
        Scratchpad.ScrollSpace.logger.d("no scratchpad set")
        return
    end

    local window = Window.get(state.scratchpad)
    if not window then
        state.scratchpad = nil
        return
    end

    if window:isMinimized() then
        window:unminimize()
        window:focus()
    else
        window:minimize()
    end
end

return Scratchpad
