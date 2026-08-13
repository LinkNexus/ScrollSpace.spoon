local Window <const> = hs.window

local Tiling = {}
Tiling.__index = Tiling

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Tiling.init(scrollspace)
    Tiling.ScrollSpace = scrollspace
end

---update the virtual x position for a table of windows on the specified workspace
---@param workspace number
---@param windows Window[]
local function update_virtual_positions(workspace, windows, x)
    local x_positions = Tiling.ScrollSpace.state.xPositions(workspace)
    for _, window in ipairs(windows) do
        x_positions[window:id()] = x
    end
end

---tile a column of window by moving and resizing
---@param windows Window[] column of windows
---@param bounds Frame bounds to constrain column of tiled windows
---@param h number|nil set windows to specified height
---@param w number|nil set windows to specified width
---@param id number|nil id of window to set specific height
---@param h4id number|nil specific height for provided window id
---@return number width of tiled column
function Tiling.tileColumn(windows, bounds, h, w, id, h4id)
    local last_window, frame
    local bottom_gap = Tiling.ScrollSpace.windows.getGap("bottom")

    for _, window in ipairs(windows) do
        frame = window:frame()
        w = w or frame.w -- take given width or width of first window
        if bounds.x then
            frame.x = bounds.x
        elseif bounds.x2 then
            frame.x = bounds.x2 - w
        end
        if h then
            if id and h4id and window:id() == id then
                frame.h = h4id
            else
                frame.h = h
            end
        end
        frame.y = bounds.y
        frame.w = w
        frame.y2 = math.min(frame.y2, bounds.y2) -- don't overflow bottom of bounds
        Tiling.ScrollSpace.windows.moveWindow(window, frame)
        bounds.y = math.min(frame.y2 + bottom_gap, bounds.y2)
        last_window = window
    end
    -- expand last window height to bottom
    if frame and frame.y2 ~= bounds.y2 then
        frame.y2 = bounds.y2
        Tiling.ScrollSpace.windows.moveWindow(last_window, frame)
    end
    return w -- return width of column
end

---tile all columns in a workspace by moving and resizing windows
---optionally starting with anchor_window and moving out. Only ever tiles
---the single primary screen -- multi-monitor spanning is deferred.
---@param workspace number
---@param anchor_window Window|nil
function Tiling.tileWorkspace(workspace, anchor_window)
    if not workspace then
        Tiling.ScrollSpace.logger.e("tileWorkspace called without a workspace")
        return
    end

    -- only tile the currently active workspace -- inactive workspaces are
    -- fully minimized, so there is nothing on screen to move/resize
    if workspace ~= Tiling.ScrollSpace.state.current_workspace then
        return
    end

    local screen = hs.screen.primaryScreen()
    if not screen then
        Tiling.ScrollSpace.logger.e("no primary screen")
        return
    end

    local function windowOnWorkspace(window)
        local index = Tiling.ScrollSpace.state.windowIndex(window)
        return index ~= nil and index.workspace == workspace
    end

    -- if anchor window is in workspace, tile from that. otherwise use focused window
    anchor_window = anchor_window or (function()
        local focused_window = Window.focusedWindow()
        if focused_window and not Tiling.ScrollSpace.floating.isFloating(focused_window) and windowOnWorkspace(focused_window) then
            return focused_window
        else
            return Tiling.ScrollSpace.windows.getFirstVisibleWindow(workspace, screen:frame())
        end
    end)()

    if not anchor_window or not windowOnWorkspace(anchor_window) then
        -- nothing visible to anchor from (e.g. workspace has only just-hidden
        -- windows momentarily) -- fall back to the first column's first window
        local columns = Tiling.ScrollSpace.state.windowList(workspace)
        if columns and columns[1] and columns[1][1] then
            anchor_window = columns[1][1]
        else
            return -- nothing tiled on this workspace
        end
    end

    local anchor_index = Tiling.ScrollSpace.state.windowIndex(anchor_window)
    if not anchor_index then
        Tiling.ScrollSpace.logger.e("anchor index not found")
        return
    end

    local screen_frame <const> = screen:frame()
    local left_margin <const> = screen_frame.x + Tiling.ScrollSpace.screen_margin
    local right_margin <const> = screen_frame.x2 - Tiling.ScrollSpace.screen_margin
    local canvas <const> = Tiling.ScrollSpace.windows.getCanvas()

    local anchor_frame = anchor_window:frame()
    anchor_frame.x = math.max(anchor_frame.x, canvas.x)
    anchor_frame.w = math.min(anchor_frame.w, canvas.w)
    anchor_frame.h = math.min(anchor_frame.h, canvas.h)
    if anchor_frame.x2 > canvas.x2 then
        anchor_frame.x = canvas.x2 - anchor_frame.w
    end

    local column = Tiling.ScrollSpace.state.windowList(workspace, anchor_index.col)
    if not column then
        Tiling.ScrollSpace.logger.e("no anchor window column")
        return
    end

    if #column == 1 then
        anchor_frame.y, anchor_frame.h = canvas.y, canvas.h
        Tiling.ScrollSpace.windows.moveWindow(anchor_window, anchor_frame)
    else
        local n = #column - 1
        local bottom_gap = Tiling.ScrollSpace.windows.getGap("bottom")
        local h = math.max(0, canvas.h - anchor_frame.h - (n * bottom_gap)) // n
        local bounds = { x = anchor_frame.x, x2 = nil, y = canvas.y, y2 = canvas.y2 }
        Tiling.tileColumn(column, bounds, h, anchor_frame.w, anchor_window:id(), anchor_frame.h)
    end
    update_virtual_positions(workspace, column, anchor_frame.x)

    local right_gap = Tiling.ScrollSpace.windows.getGap("right")
    local left_gap = Tiling.ScrollSpace.windows.getGap("left")

    -- tile windows from anchor right
    local x = anchor_frame.x2 + right_gap
    for col = anchor_index.col + 1, #(Tiling.ScrollSpace.state.windowList(workspace)) do
        local bounds = { x = math.min(x, right_margin), x2 = nil, y = canvas.y, y2 = canvas.y2 }
        local col_windows = Tiling.ScrollSpace.state.windowList(workspace, col)
        local width = Tiling.tileColumn(col_windows, bounds)
        update_virtual_positions(workspace, col_windows, x)
        x = x + width + right_gap
    end

    -- tile windows from anchor left
    local x2 = anchor_frame.x - left_gap
    for col = anchor_index.col - 1, 1, -1 do
        local bounds = { x = nil, x2 = math.max(x2, left_margin), y = canvas.y, y2 = canvas.y2 }
        local col_windows = Tiling.ScrollSpace.state.windowList(workspace, col)
        local width = Tiling.tileColumn(col_windows, bounds)
        update_virtual_positions(workspace, col_windows, x2 - width)
        x2 = x2 - width - left_gap
    end
end

return Tiling
