local Rect <const> = hs.geometry.rect
local Timer <const> = hs.timer
local Window <const> = hs.window

local Windows = {}
Windows.__index = Windows

---@enum Direction
local Direction <const> = {
    LEFT = -1,
    RIGHT = 1,
    UP = -2,
    DOWN = 2,
    ASCENDING = 6,
    DESCENDING = 7,
}
Windows.Direction = Direction

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Windows.init(scrollspace)
    Windows.ScrollSpace = scrollspace
end

---return the first window that's completely on the screen, for use as a
---tiling anchor when no focused window is available for the workspace
---@param workspace number
---@param screen_frame Frame the coordinates of the screen
---@param direction Direction|nil either LEFT or RIGHT, defaults to LEFT
---@return Window|nil
function Windows.getFirstVisibleWindow(workspace, screen_frame, direction)
    direction = direction or Direction.LEFT
    local on_screen_distance = math.huge
    local on_screen_closest = nil
    local off_screen_distance = -math.huge
    local off_screen_closest = nil

    for _, windows in ipairs(Windows.ScrollSpace.state.windowList(workspace)) do
        local window = windows[1] -- take first window in column
        local d = (function()
            if direction == Direction.LEFT then
                return window:frame().x - screen_frame.x
            elseif direction == Direction.RIGHT then
                return screen_frame.x2 - window:frame().x2
            end
        end)() or math.huge
        if d >= 0 and d < on_screen_distance then
            on_screen_distance = d
            on_screen_closest = window
        end
        if d < 0 and d > off_screen_distance then
            off_screen_distance = d
            off_screen_closest = window
        end
    end

    return on_screen_closest or off_screen_closest
end

---get the gap value for the specified side
---@param side string "top", "bottom", "left", or "right"
---@return number gap size in pixels
function Windows.getGap(side)
    local gap = Windows.ScrollSpace.window_gap
    if type(gap) == "number" then
        return gap            -- single number applies to all sides
    elseif type(gap) == "table" then
        return gap[side] or 8 -- default to 8 if missing
    else
        return 8              -- fallback default
    end
end

---get the tileable bounds for the (single, primary) screen
---@return Frame
function Windows.getCanvas()
    local screen = hs.screen.primaryScreen()
    local screen_frame = screen:frame()
    local left_gap = Windows.getGap("left")
    local right_gap = Windows.getGap("right")
    local top_gap = Windows.getGap("top")
    local bottom_gap = Windows.getGap("bottom")

    return Rect(
        screen_frame.x + left_gap,
        screen_frame.y + top_gap,
        screen_frame.w - (left_gap + right_gap),
        screen_frame.h - (top_gap + bottom_gap)
    )
end

---move and resize a window to the coordinates specified by the frame
---disable watchers while window is moving and re-enable after
---@param window Window window to move
---@param frame Frame coordinates to set window size and location
function Windows.moveWindow(window, frame)
    -- greater than 0.017 hs.window animation step time
    local padding <const> = 0.02
    local id = window:id()

    if frame == window:frame() then
        Windows.ScrollSpace.logger.v("no change in window frame")
        return
    end

    Windows.ScrollSpace.state.uiWatcherStop(id)
    window:setFrame(frame)
    Timer.doAfter(Window.animationDuration + padding, function()
        Windows.ScrollSpace.state.uiWatcherStart(id)
    end)
end

---move focus to a new window next to the currently focused window
---@param direction Direction use either Direction UP, DOWN, LEFT, or RIGHT
---@param focused_index table|nil index of focused window within the windowList
---@return Window?
function Windows.focusWindow(direction, focused_index)
    if not focused_index then
        local focused_window = Window.focusedWindow()
        if not focused_window then
            Windows.ScrollSpace.logger.d("focused window not found")
            return
        end
        focused_index = Windows.ScrollSpace.state.windowIndex(focused_window)
    end

    if not focused_index then
        Windows.ScrollSpace.logger.e("focused index not found")
        return
    end

    local new_focused_window = nil
    if direction == Direction.LEFT or direction == Direction.RIGHT then
        for row = focused_index.row, 1, -1 do
            new_focused_window = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col + direction,
                row)
            if new_focused_window then break end
        end
        if not new_focused_window and Windows.ScrollSpace.infinite_loop_window then
            local columns = Windows.ScrollSpace.state.windowList(focused_index.workspace)
            local num_cols = columns and #columns or 0
            if num_cols > 1 then
                local wrap_col = direction == Direction.LEFT and num_cols or 1
                for row = focused_index.row, 1, -1 do
                    new_focused_window = columns[wrap_col][row]
                    if new_focused_window then
                        local windows = table.remove(columns, wrap_col)
                        table.insert(columns, wrap_col == 1 and num_cols or 1, windows)
                        Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
                        break
                    end
                end
            end
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        local target_row = focused_index.row + (direction // 2)
        new_focused_window = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col, target_row)
        if not new_focused_window and Windows.ScrollSpace.infinite_loop_window then
            local column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col)
            local num_rows = column and #column or 0
            if num_rows > 1 then
                new_focused_window = column[direction == Direction.UP and num_rows or 1]
            end
        end
    end

    if not new_focused_window then
        Windows.ScrollSpace.logger.d("new focused window not found")
        return
    end

    new_focused_window:focus()

    -- try to prevent MacOS from stealing focus away to another window
    Timer.doAfter(Window.animationDuration, function()
        if Window.focusedWindow() ~= new_focused_window then
            new_focused_window:focus()
        end
    end)

    return new_focused_window
end

---swap the focused window with a window next to it
---if swapping horizontally and the adjacent window is in a column, swap the
---entire column. if swapping vertically, swap positions within the column
---@param direction Direction use Direction LEFT, RIGHT, UP, or DOWN
function Windows.swapWindows(direction)
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.ScrollSpace.logger.d("focused window not found")
        return
    end

    local focused_index = Windows.ScrollSpace.state.windowIndex(focused_window)
    if not focused_index then
        Windows.ScrollSpace.logger.e("focused index not found")
        return
    end

    if direction == Direction.LEFT or direction == Direction.RIGHT then
        local columns = Windows.ScrollSpace.state.windowList(focused_index.workspace)
        if not columns then return end

        local current_column = focused_index.col
        if not columns[current_column] then return end

        local target_column = focused_index.col + direction
        if not columns[target_column] then return end

        local focused_frame = focused_window:frame()
        local target_frame = columns[target_column][1]:frame()
        focused_frame.x = target_frame.x
        Windows.moveWindow(focused_window, focused_frame)

        local windows = table.remove(columns, current_column)
        table.insert(columns, target_column, windows)
    elseif direction == Direction.UP or direction == Direction.DOWN then
        local windows = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col)
        if not windows then return end

        local current_row = focused_index.row
        local target_row = focused_index.row + (direction // 2)

        local window = table.remove(windows, current_row)
        table.insert(windows, target_row, window)
    end

    Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
end

---move the focused window to the center of the screen, horizontally
---don't resize the window or change it's vertical position
function Windows.centerWindow()
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.ScrollSpace.logger.d("focused window not found")
        return
    end

    local focused_frame = focused_window:frame()
    local screen_frame = hs.screen.primaryScreen():frame()

    focused_frame.x = screen_frame.x + (screen_frame.w // 2) - (focused_frame.w // 2)
    Windows.moveWindow(focused_window, focused_frame)

    local index = Windows.ScrollSpace.state.windowIndex(focused_window)
    if index then Windows.ScrollSpace:tileWorkspace(index.workspace) end
end

---set the focused window to the width of the screen and cache the original width
---restore the original window size if called again, don't change the height
Windows.toggleWindowFullWidth = (function()
    local width_cache = {}
    return function()
        local focused_window = Window.focusedWindow()
        if not focused_window then
            Windows.ScrollSpace.logger.d("focused window not found")
            return
        end

        local canvas = Windows.getCanvas()
        local focused_frame = focused_window:frame()
        local id = focused_window:id()

        local width = width_cache[id]
        if width then
            focused_frame.x = canvas.x + ((canvas.w - width) / 2)
            focused_frame.w = width
            width_cache[id] = nil
        else
            width_cache[id] = focused_frame.w
            focused_frame.x, focused_frame.w = canvas.x, canvas.w
        end

        Windows.moveWindow(focused_window, focused_frame)
        local index = Windows.ScrollSpace.state.windowIndex(focused_window)
        if index then Windows.ScrollSpace:tileWorkspace(index.workspace) end
    end
end)()

---resize the width of the focused window, keeping height the same.
---cycles through the ratios specified in ScrollSpace.window_ratios
---@param cycle_direction Direction use Direction.ASCENDING or DESCENDING
function Windows.cycleWindowSize(cycle_direction)
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.ScrollSpace.logger.d("focused window not found")
        return
    end

    local canvas = Windows.getCanvas()
    local focused_frame = focused_window:frame()
    local gap = (Windows.getGap("left") + Windows.getGap("right")) / 2

    local sizes = {}
    for index, ratio in ipairs(Windows.ScrollSpace.window_ratios) do
        sizes[index] = ratio * (canvas.w + gap) - gap
    end

    local new_width = sizes[1]
    if cycle_direction == Direction.ASCENDING then
        for _, size in ipairs(sizes) do
            if size > focused_frame.w + 10 then
                new_width = size
                break
            end
        end
    else
        new_width = sizes[#sizes]
        for i = #sizes, 1, -1 do
            if sizes[i] < focused_frame.w - 10 then
                new_width = sizes[i]
                break
            end
        end
    end

    focused_frame.x = focused_frame.x + ((focused_frame.w - new_width) // 2)
    focused_frame.w = new_width
    Windows.moveWindow(focused_window, focused_frame)

    local index = Windows.ScrollSpace.state.windowIndex(focused_window)
    if index then Windows.ScrollSpace:tileWorkspace(index.workspace) end
end

---tile a column of windows so they each have an equal height
---@param windows Window[]
local function tileColumnEqually(windows)
    local first_window = windows[1]
    local num_windows = #windows
    local canvas = Windows.getCanvas()
    local bottom_gap = Windows.getGap("bottom")
    local bounds = { x = first_window:frame().x, x2 = nil, y = canvas.y, y2 = canvas.y2 }
    local h = math.max(0, canvas.h - ((num_windows - 1) * bottom_gap)) // num_windows
    Windows.ScrollSpace.tiling.tileColumn(windows, bounds, h)
end

---take the focused window and move it into the bottom of the column to
---the left, stacking it vertically with whatever's already there
function Windows.slurpWindow()
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.ScrollSpace.logger.d("focused window not found")
        return
    end

    local focused_index = Windows.ScrollSpace.state.windowIndex(focused_window)
    if not focused_index then
        Windows.ScrollSpace.logger.e("focused index not found")
        return
    end

    local current_column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col)
    if not current_column then return end

    local target_col = focused_index.col - 1
    local target_column = Windows.ScrollSpace.state.windowList(focused_index.workspace, target_col)
    if not target_column then
        Windows.ScrollSpace.logger.d("no column to the left to slurp into")
        return
    end

    assert(focused_window == table.remove(current_column, focused_index.row))
    table.insert(target_column, focused_window)

    tileColumnEqually(Windows.ScrollSpace.state.windowList(focused_index.workspace, target_col))
    Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
    Windows.ScrollSpace.state.save()
end

---remove the focused window from its column (which must have more than
---one window) and place it into a new column of its own to the right
function Windows.barfWindow()
    local focused_window = Window.focusedWindow()
    if not focused_window then
        Windows.ScrollSpace.logger.d("focused window not found")
        return
    end

    local focused_index = Windows.ScrollSpace.state.windowIndex(focused_window)
    if not focused_index then
        Windows.ScrollSpace.logger.e("focused index not found")
        return
    end

    local current_column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col)
    if not current_column then return end
    if #current_column == 1 then
        Windows.ScrollSpace.logger.d("only window in column, nothing to barf out")
        return
    end

    local target_col = focused_index.col + 1
    assert(focused_window == table.remove(current_column, focused_index.row))
    table.insert(Windows.ScrollSpace.state.windowList(focused_index.workspace), target_col, { focused_window })

    local focused_frame = focused_window:frame()
    focused_frame.x = focused_frame.x2 + Windows.getGap("right")
    Windows.moveWindow(focused_window, focused_frame)

    tileColumnEqually(Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.col))
    Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
    Windows.ScrollSpace.state.save()
end

return Windows
