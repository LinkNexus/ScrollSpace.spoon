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

---project a screen's column strip down to just the windows that are
---actually on screen right now, preserving column indices so an
---anchor's `col` stays meaningful.
---
---Minimized windows deliberately stay in window_list -- that's the whole
---point of this design, it's what lets a workspace's column order
---survive a hide/show cycle untouched. They must not take part in layout
---math though: a minimized window would otherwise claim a share of its
---column's height and, if a whole column were hidden, leave a gap that
---shifts every column to its right.
---@param workspace number
---@param screen_uuid string
---@return Window[][] columns indexed as in window_list, minus hidden windows
local function visible_columns(workspace, screen_uuid)
    local columns = {}
    for col, rows in ipairs(Tiling.ScrollSpace.state.windowList(workspace, screen_uuid)) do
        local visible = {}
        for _, window in ipairs(rows) do
            if not window:isMinimized() then table.insert(visible, window) end
        end
        columns[col] = visible
    end
    return columns
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
        if bounds.x then -- set either left or right x coord
            frame.x = bounds.x
        elseif bounds.x2 then
            frame.x = bounds.x2 - w
        end
        if h then              -- set height if given
            if id and h4id and window:id() == id then
                frame.h = h4id -- use this height for window with id
            else
                frame.h = h    -- use this height for all other windows
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
    local columns = visible_columns(workspace, screen_uuid)

    ---a window can anchor tiling only if it's tracked on this exact
    ---screen and currently on screen (a hidden window has no frame worth
    ---laying the rest of the strip out from)
    local function canAnchor(window)
        if not window or window:isMinimized() then return false end
        local index = state.windowIndex(window)
        return index ~= nil and index.workspace == workspace and index.screen == screen_uuid
    end

    -- if anchor window is on this screen, tile from that. otherwise use focused window
    if not canAnchor(anchor_window) then
        local focused_window = Window.focusedWindow()
        if focused_window and not Tiling.ScrollSpace.floating.isFloating(focused_window) and canAnchor(focused_window) then
            anchor_window = focused_window
        else
            anchor_window = Tiling.ScrollSpace.windows.getFirstVisibleWindow(workspace, screen)
        end
    end

    if not canAnchor(anchor_window) then
        return -- nothing visible on this screen to tile
    end

    local anchor_index = state.windowIndex(anchor_window)
    if not anchor_index then
        Tiling.ScrollSpace.logger.e("anchor index not found")
        return
    end

    -- get some global coordinates
    local screen_frame <const> = screen:frame()
    local left_margin <const> = screen_frame.x + Tiling.ScrollSpace.screen_margin
    local right_margin <const> = screen_frame.x2 - Tiling.ScrollSpace.screen_margin
    local canvas <const> = Tiling.ScrollSpace.windows.getCanvas(screen)

    -- make sure anchor window is on screen
    local anchor_frame = anchor_window:frame()
    anchor_frame.x = math.max(anchor_frame.x, canvas.x)
    anchor_frame.w = math.min(anchor_frame.w, canvas.w)
    anchor_frame.h = math.min(anchor_frame.h, canvas.h)
    if anchor_frame.x2 > canvas.x2 then
        anchor_frame.x = canvas.x2 - anchor_frame.w
    end

    -- adjust anchor window column
    local column = columns[anchor_index.col]
    if not column or #column == 0 then
        Tiling.ScrollSpace.logger.e("no anchor window column")
        return
    end

    if #column == 1 then
        anchor_frame.y, anchor_frame.h = canvas.y, canvas.h
        Tiling.ScrollSpace.windows.moveWindow(anchor_window, anchor_frame)
    else
        local n = #column - 1 -- number of other windows in column
        local bottom_gap = Tiling.ScrollSpace.windows.getGap("bottom")
        local h = math.max(0, canvas.h - anchor_frame.h - (n * bottom_gap)) // n
        local bounds = { x = anchor_frame.x, x2 = nil, y = canvas.y, y2 = canvas.y2 }
        Tiling.tileColumn(column, bounds, h, anchor_frame.w, anchor_window:id(), anchor_frame.h)
    end
    update_virtual_positions(workspace, screen_uuid, column, anchor_frame.x)

    local right_gap = Tiling.ScrollSpace.windows.getGap("right")
    local left_gap = Tiling.ScrollSpace.windows.getGap("left")

    -- tile windows from anchor right. fully hidden columns are skipped
    -- outright rather than consuming a slot's worth of x -- they occupy
    -- no space on screen, so the strip closes up over them
    local x = anchor_frame.x2 + right_gap
    for col = anchor_index.col + 1, #columns do
        local col_windows = columns[col]
        if #col_windows > 0 then
            local bounds = { x = math.min(x, right_margin), x2 = nil, y = canvas.y, y2 = canvas.y2 }
            local width = Tiling.tileColumn(col_windows, bounds)
            update_virtual_positions(workspace, screen_uuid, col_windows, x)
            x = x + width + right_gap
        end
    end

    -- tile windows from anchor left
    local x2 = anchor_frame.x - left_gap
    for col = anchor_index.col - 1, 1, -1 do
        local col_windows = columns[col]
        if #col_windows > 0 then
            local bounds = { x = nil, x2 = math.max(x2, left_margin), y = canvas.y, y2 = canvas.y2 }
            local width = Tiling.tileColumn(col_windows, bounds)
            update_virtual_positions(workspace, screen_uuid, col_windows, x2 - width)
            x2 = x2 - width - left_gap
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
