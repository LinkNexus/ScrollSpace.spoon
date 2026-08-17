local Window <const> = hs.window

local Tiling = {}
Tiling.__index = Tiling

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Tiling.init(scrollspace)
    Tiling.ScrollSpace = scrollspace
end

---update the virtual x position for a table of windows on the specified
---workspace+screen
---@param workspace number
---@param screen string hs.screen:getUUID()
---@param windows Window[]
local function update_virtual_positions(workspace, screen, windows, x)
    local x_positions = Tiling.ScrollSpace.state.xPositions(workspace, screen)
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

---tile all columns on one screen within a workspace by moving and
---resizing windows, optionally starting with anchor_window and moving
---out. anchor_window is only honored if it's actually tracked on this
---screen -- tileWorkspace below is responsible for only passing it to
---the bucket that contains it.
---@param workspace number
---@param screen userdata hs.screen
---@param anchor_window Window|nil
local function tileScreen(workspace, screen, anchor_window)
    local state = Tiling.ScrollSpace.state
    local screen_uuid = screen:getUUID()

    local function windowOnScreen(window)
        local index = state.windowIndex(window)
        return index ~= nil and index.workspace == workspace and index.screen == screen_uuid
    end

    -- if anchor window is on this screen, tile from that. otherwise use focused window
    if not (anchor_window and windowOnScreen(anchor_window)) then
        local focused_window = Window.focusedWindow()
        if focused_window and not Tiling.ScrollSpace.floating.isFloating(focused_window) and windowOnScreen(focused_window) then
            anchor_window = focused_window
        else
            anchor_window = Tiling.ScrollSpace.windows.getFirstVisibleWindow(workspace, screen)
        end
    end

    if not anchor_window or not windowOnScreen(anchor_window) then
        -- nothing visible to anchor from (e.g. screen has only just-hidden
        -- windows momentarily) -- fall back to the first column's first window
        local columns = state.windowList(workspace, screen_uuid)
        if columns and columns[1] and columns[1][1] then
            anchor_window = columns[1][1]
        else
            return -- nothing tiled on this screen
        end
    end

    local anchor_index = state.windowIndex(anchor_window)
    if not anchor_index then
        Tiling.ScrollSpace.logger.e("anchor index not found")
        return
    end

    local screen_frame <const> = screen:frame()
    local left_margin <const> = screen_frame.x + Tiling.ScrollSpace.screen_margin
    local right_margin <const> = screen_frame.x2 - Tiling.ScrollSpace.screen_margin
    local canvas <const> = Tiling.ScrollSpace.windows.getCanvas(screen)

    local anchor_frame = anchor_window:frame()
    anchor_frame.x = math.max(anchor_frame.x, canvas.x)
    anchor_frame.w = math.min(anchor_frame.w, canvas.w)
    anchor_frame.h = math.min(anchor_frame.h, canvas.h)
    if anchor_frame.x2 > canvas.x2 then
        anchor_frame.x = canvas.x2 - anchor_frame.w
    end

    local column = state.windowList(workspace, screen_uuid, anchor_index.col)
    if not column then
        Tiling.ScrollSpace.logger.e("no anchor window column")
        return
    end

    for _, window in ipairs(column) do window:unminimize() end
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
    update_virtual_positions(workspace, screen_uuid, column, anchor_frame.x)

    local right_gap = Tiling.ScrollSpace.windows.getGap("right")
    local left_gap = Tiling.ScrollSpace.windows.getGap("left")

    -- tile windows from anchor right, minimizing any column that doesn't
    -- fit within the canvas instead of positioning it off-canvas.
    -- Confirmed live: macOS always clamps a window's frame back to
    -- overlap the nearest connected screen, no matter how far off-canvas
    -- you try to push it via setFrame -- there is no x-coordinate that's
    -- genuinely invisible once the desktop has monitor coverage in that
    -- direction, so coordinate placement can't reliably hide a column
    -- that doesn't fit. minimize()/unminimize() is the only mechanism
    -- that actually works (same one already used for inactive
    -- workspaces) -- windowNotVisible/windowVisible already no-op for
    -- our own minimize()/unminimize() calls (see events.lua), so no
    -- further event-handling changes are needed. Peek at each column's
    -- own natural width (same value tileColumn falls back to via
    -- `w or frame.w`) to decide whether it actually fits -- checking
    -- only the starting x against right_margin misses a single wide
    -- column that starts within the margin but is wide enough to carry
    -- its far edge past the screen anyway.
    local x = anchor_frame.x2 + right_gap
    local overflowed = false
    for col = anchor_index.col + 1, #(state.windowList(workspace, screen_uuid)) do
        local col_windows = state.windowList(workspace, screen_uuid, col)
        if not overflowed then
            local natural_w = (col_windows[1] and col_windows[1]:frame().w) or 0
            if x + natural_w <= right_margin then
                local bounds = { x = x, x2 = nil, y = canvas.y, y2 = canvas.y2 }
                local width = Tiling.tileColumn(col_windows, bounds)
                update_virtual_positions(workspace, screen_uuid, col_windows, x)
                for _, window in ipairs(col_windows) do window:unminimize() end
                x = x + width + right_gap
            else
                overflowed = true
            end
        end
        if overflowed then
            for _, window in ipairs(col_windows) do window:minimize() end
        end
    end

    -- tile windows from anchor left (same minimize-off-viewport reasoning as above)
    local x2 = anchor_frame.x - left_gap
    local overflowed_left = false
    for col = anchor_index.col - 1, 1, -1 do
        local col_windows = state.windowList(workspace, screen_uuid, col)
        if not overflowed_left then
            local natural_w = (col_windows[1] and col_windows[1]:frame().w) or 0
            if x2 - natural_w >= left_margin then
                local bounds = { x = nil, x2 = x2, y = canvas.y, y2 = canvas.y2 }
                local width = Tiling.tileColumn(col_windows, bounds)
                update_virtual_positions(workspace, screen_uuid, col_windows, x2 - width)
                for _, window in ipairs(col_windows) do window:unminimize() end
                x2 = x2 - width - left_gap
            else
                overflowed_left = true
            end
        end
        if overflowed_left then
            for _, window in ipairs(col_windows) do window:minimize() end
        end
    end
end

---tile every connected screen's columns in a workspace, optionally
---starting from anchor_window (on whichever screen actually has it) and
---moving out from there. A workspace spans every connected screen at
---once -- each tiles its own independent column strip, all showing/
---hiding together when the workspace switches, but scrolling/navigation
---(focus/swap/slurp/barf) stays within one screen at a time.
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

    for screen_uuid, _ in pairs(Tiling.ScrollSpace.state.windowList(workspace)) do
        local screen = hs.screen.find(screen_uuid)
        if screen then
            tileScreen(workspace, screen, anchor_window)
        end
    end
end

return Tiling
