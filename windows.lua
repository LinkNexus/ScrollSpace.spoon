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
---tiling anchor when no focused window is available for the workspace's
---bucket on this screen. Minimized windows are skipped -- they stay in
---window_list by design but have no meaningful on-screen position.
---@param workspace number
---@param screen userdata hs.screen
---@param direction Direction|nil either LEFT or RIGHT, defaults to LEFT
---@return Window|nil
function Windows.getFirstVisibleWindow(workspace, screen, direction)
    direction = direction or Direction.LEFT
    local screen_frame = screen:frame()
    local on_screen_distance = math.huge
    local on_screen_closest = nil
    local off_screen_distance = -math.huge
    local off_screen_closest = nil

    for _, windows in ipairs(Windows.ScrollSpace.state.windowList(workspace, screen:getUUID())) do
        local window = (function() -- take first non-minimized window in column
            for _, candidate in ipairs(windows) do
                if not candidate:isMinimized() then return candidate end
            end
        end)()
        if window then
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

---get the tileable bounds for a screen
---@param screen userdata hs.screen
---@return Frame
function Windows.getCanvas(screen)
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

---get all managed windows and retile any workspace that gained one
function Windows.refreshWindows()
    local state = Windows.ScrollSpace.state
    state.pruneDead()

    -- hs.window.allWindows(), not window_filter:getWindows() -- the
    -- latter only returns currently-visible windows, which would miss
    -- any minimized-but-untracked window entirely (e.g. one orphaned by
    -- a past bug, or an app that starts out minimized).
    local all_windows = Window.allWindows()

    -- isWindowAllowed(window) is unreliable on its own -- confirmed live
    -- (2026-08-14) that it can return false for a window that is visible,
    -- eligible, and even present in this exact window_filter's own
    -- getWindows() output moments earlier (a kitty.main window survived a
    -- theme-change-triggered prune/re-add and came back with a new
    -- CGWindowID; isWindowAllowed refused to ever let it back into
    -- tracking, permanently breaking that workspace's tiling until fixed
    -- by hand). getWindows() membership is the trustworthy signal for any
    -- currently-visible window since it's the same list events.lua's own
    -- subscriptions are built from.
    local visible_allowed = {}
    for _, window in ipairs(Windows.ScrollSpace.window_filter:getWindows()) do
        visible_allowed[window:id()] = true
    end

    local retile_workspaces = {}
    for _, window in ipairs(all_windows) do
        -- the scratchpad window is deliberately kept out of index_table
        -- too (not a workspace member, see scratchpad.lua) -- without
        -- this check it looks exactly like an untracked window and
        -- would get pulled back into a workspace's tiling.
        if window:id() ~= state.scratchpad
            and not Windows.ScrollSpace.floating.isFloating(window)
            and not state.windowIndex(window) then
            local allowed = visible_allowed[window:id()]
            if not allowed then
                -- isAppAllowed() is a cheap, visibility-independent
                -- pre-check -- confirmed live this is required, not
                -- optional: without it, EVERY minimized window belonging
                -- to a fully app-rejected app (Finder, System Settings --
                -- see the setAppFilter calls) got unminimized then
                -- immediately re-minimized below on every refreshWindows()
                -- call (i.e. every reload), a visible open/close flicker
                -- for a window that was never going to pass
                -- isWindowAllowed regardless of visibility. Confirmed live:
                -- two minimized Finder windows flickering open/closed on
                -- every reload, including the automatic one on wake.
                local app = window:application()
                if app and Windows.ScrollSpace.window_filter:isAppAllowed(app:name()) then
                    -- config.lua's window_filter has a blanket
                    -- `visible = true` override criterion, so
                    -- isWindowAllowed() can NEVER return true for a
                    -- minimized window -- not flakiness, structural.
                    -- Minimized-and-untracked is exactly the orphan case
                    -- this function exists to recover (confirmed live: a
                    -- minimized, untracked Thunderbird window stayed stuck
                    -- invisible forever, even after switching to its
                    -- workspace, because this function could never
                    -- reclaim it). Unminimize briefly to get a real
                    -- verdict out of the filter's actual per-window title
                    -- rules, then put it back if it turns out not to
                    -- belong here after all -- addWindow() below already
                    -- restores the correct minimized state for whichever
                    -- workspace it lands on, so no cleanup is needed on
                    -- the "allowed" path.
                    local was_minimized = window:isMinimized()
                    if was_minimized then window:unminimize() end
                    allowed = Windows.ScrollSpace.window_filter:isWindowAllowed(window)
                    if was_minimized and not allowed then window:minimize() end
                end
            end
            if allowed then
                local workspace = Windows.addWindow(window)
                if workspace then retile_workspaces[workspace] = true end
            end
        end
    end

    for workspace, _ in pairs(retile_workspaces) do
        Windows.ScrollSpace:tileWorkspace(workspace)
    end

    state.save()
end

---add a new window to be tracked and automatically tiled. Assigns a
---workspace via the rule engine unless `workspace` is given explicitly
---(used when re-inserting a window that already had a known workspace,
---e.g. un-floating -- re-running rules there could send it somewhere
---other than where it was floating). Screen defaults to wherever the
---window actually is (add_window:screen()) unless given explicitly -- a
---workspace spans every connected screen, each with its own independent
---column strip. The window's minimized state is then set to match
---whether its workspace is the active one.
---@param add_window Window new window to be added
---@param workspace number|nil explicit target workspace, skips the rule engine
---@param screen string|nil explicit target screen (hs.screen:getUUID()), skips add_window:screen()
---@return number|nil workspace that contains the new window
function Windows.addWindow(add_window, workspace, screen)
    local state = Windows.ScrollSpace.state

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
        Windows.ScrollSpace.logger.w("ignoring window with tabs: " .. add_window:title())
        return
    end

    if not add_window:isMaximizable() then
        Windows.ScrollSpace.logger.d("ignoring non-maximizable window")
        return
    end

    -- defensive second layer against picture-in-picture windows, on top of
    -- window_filter's allowRoles -- PiP windows are always static/global,
    -- never tracked/tiled/minimized
    local subrole = add_window:subrole()
    if subrole and Windows.ScrollSpace.pip_subroles[subrole] then
        Windows.ScrollSpace.logger.d("ignoring picture-in-picture window (subrole: " .. subrole .. ")")
        return
    end

    -- already tracked, tiled or floating
    if state.windowIndex(add_window) or Windows.ScrollSpace.floating.isFloating(add_window) then
        return
    end

    -- the rule engine returns nil when nothing matched, so the caller owns
    -- the fallback: a brand new window belongs on whatever workspace is
    -- active right now
    workspace = workspace or Windows.ScrollSpace.rule_engine.assign(add_window) or state.current_workspace

    if not screen then
        -- a minimized window can report no screen at all, so fall back to
        -- the primary one rather than indexing nil
        local window_screen = add_window:screen()
        screen = (window_screen or hs.screen.primaryScreen()):getUUID()
    end

    -- find where to insert window (within this screen's own column list --
    -- a workspace spans every connected screen, each tiling independently)
    local add_column = 1
    local prev_focused_index = state.prev_focused_window and state.windowIndex(state.prev_focused_window)
    if prev_focused_index and prev_focused_index.workspace == workspace and prev_focused_index.screen == screen and
        (state.prev_focused_window:id() ~= add_window:id()) then
        add_column = prev_focused_index.col + 1
    else
        local x = add_window:frame().center.x
        for col, windows in ipairs(state.windowList(workspace, screen)) do
            if x < windows[1]:frame().center.x then
                add_column = col     -- insert left of window
                break                -- add_window will take this window's column
            else                     -- everything after insert column will be pushed right
                add_column = col + 1 -- insert right of window
            end
        end
    end

    table.insert(state.windowList(workspace, screen), add_column, { add_window })
    state.uiWatcherCreate(add_window)

    Windows.ScrollSpace.logger.df("adding window: %s (%d) to workspace %d, screen %s", add_window:title(),
        add_window:id(), workspace, screen)

    -- match the window's visibility to its workspace. Both directions
    -- matter: a window joining an inactive workspace must be hidden, and
    -- one joining the active workspace must be shown -- windows arrive
    -- here already minimized often enough (an orphan reclaimed by
    -- refreshWindows, a released scratchpad, a window un-floated while
    -- hidden) that skipping the unminimize leaves them invisible forever.
    if workspace ~= state.current_workspace then
        add_window:minimize()
    elseif add_window:isMinimized() then
        add_window:unminimize()
    end

    return workspace
end

---remove a window from being tracked and automatically tiled
---@param remove_window Window window to be removed
---@param skip_new_window_focus boolean|nil don't focus a nearby window if true
---@return number|nil workspace that contained removed window
---@return Window|nil newly focused window
function Windows.removeWindow(remove_window, skip_new_window_focus)
    local state = Windows.ScrollSpace.state
    local remove_index = state.windowIndex(remove_window, true)
    if not remove_index then
        Windows.ScrollSpace.logger.e("remove index not found")
        return
    end

    local focused_window = nil
    if not skip_new_window_focus then -- find nearby window to focus
        for _, direction in ipairs({ Direction.DOWN, Direction.UP, Direction.LEFT, Direction.RIGHT }) do
            focused_window = Windows.focusWindow(direction, remove_index)
            if focused_window then break end
        end
    end

    if remove_window ~=
        table.remove(state.windowList(remove_index.workspace, remove_index.screen, remove_index.col), remove_index.row) then
        Windows.ScrollSpace.logger.ef("removed window %s (%d) doesn't match", remove_window:title(),
            remove_window:id())
    end

    state.uiWatcherDelete(remove_window:id())
    state.xPositions(remove_index.workspace, remove_index.screen)[remove_window:id()] = nil

    if state.prev_focused_window == remove_window then
        state.prev_focused_window = nil
    end

    Windows.ScrollSpace.logger.df("removing window: %s (%d)", remove_window:title(), remove_window:id())

    return remove_index.workspace, focused_window
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
        -- walk down column, looking for match in neighbor column
        for row = focused_index.row, 1, -1 do
            new_focused_window = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
                focused_index.col + direction, row)
            if new_focused_window then break end
        end
        -- wrap around: if no window found, go to the opposite end
        if not new_focused_window and Windows.ScrollSpace.infinite_loop_window then
            local columns = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen)
            local num_cols = columns and #columns or 0
            if num_cols > 1 then
                local wrap_col = direction == Direction.LEFT and num_cols or 1
                for row = focused_index.row, 1, -1 do
                    new_focused_window = columns[wrap_col][row]
                    if new_focused_window then
                        local windows = table.remove(columns, wrap_col)
                        table.insert(columns, wrap_col == 1 and num_cols or 1, windows)
                        Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
                        -- the wrap reorders columns, which is persisted layout
                        Windows.ScrollSpace.state.save()
                        break
                    end
                end
            end
        end
    elseif direction == Direction.UP or direction == Direction.DOWN then
        local target_row = focused_index.row + (direction // 2)
        new_focused_window = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
            focused_index.col, target_row)
        if not new_focused_window and Windows.ScrollSpace.infinite_loop_window then
            local column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
                focused_index.col)
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
        local columns = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen)
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
        local windows = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
            focused_index.col)
        if not windows then return end

        local current_row = focused_index.row
        local target_row = focused_index.row + (direction // 2)

        -- there's nothing to swap with past either end of the column, and
        -- table.insert would raise "position out of bounds" rather than
        -- no-op if we let an out-of-range row through
        if target_row < 1 or target_row > #windows then
            Windows.ScrollSpace.logger.d("no window to swap with in that direction")
            return
        end

        local window = table.remove(windows, current_row)
        table.insert(windows, target_row, window)
    end

    Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
    -- swapping reorders columns/rows, which is exactly what gets persisted
    Windows.ScrollSpace.state.save()
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
    local screen_frame = focused_window:screen():frame()

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

        local canvas = Windows.getCanvas(focused_window:screen())
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

    local canvas = Windows.getCanvas(focused_window:screen())
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
local function tile_column_equally(windows)
    local first_window = windows[1]
    if not first_window then return end
    local num_windows = #windows
    local canvas = Windows.getCanvas(first_window:screen())
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

    local current_column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
        focused_index.col)
    if not current_column then return end

    local target_col = focused_index.col - 1
    local target_column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen, target_col)
    if not target_column then
        Windows.ScrollSpace.logger.d("no column to the left to slurp into")
        return
    end

    assert(focused_window == table.remove(current_column, focused_index.row))
    table.insert(target_column, focused_window)

    tile_column_equally(Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen, target_col))
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

    local current_column = Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
        focused_index.col)
    if not current_column then return end
    if #current_column == 1 then
        Windows.ScrollSpace.logger.d("only window in column, nothing to barf out")
        return
    end

    local target_col = focused_index.col + 1
    assert(focused_window == table.remove(current_column, focused_index.row))
    table.insert(Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen), target_col,
        { focused_window })

    local focused_frame = focused_window:frame()
    focused_frame.x = focused_frame.x2 + Windows.getGap("right")
    Windows.moveWindow(focused_window, focused_frame)

    tile_column_equally(Windows.ScrollSpace.state.windowList(focused_index.workspace, focused_index.screen,
        focused_index.col))
    Windows.ScrollSpace:tileWorkspace(focused_index.workspace)
    Windows.ScrollSpace.state.save()
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

return Windows
