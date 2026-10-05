local Window <const> = hs.window

local Tiling = {}
Tiling.__index = Tiling

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Tiling.init(scrollspace)
    Tiling.ScrollSpace = scrollspace
end

---update the virtual x position for a table of windows on the specified
---workspace+strip
---@param workspace number
---@param strip string strip key, see State.windowList
---@param windows Window[]
local function update_virtual_positions(workspace, strip, windows, x)
    local x_positions = Tiling.ScrollSpace.state.xPositions(workspace, strip)
    for _, window in ipairs(windows) do
        x_positions[window:id()] = x
    end
end

---project a strip's columns down to just the windows that are actually
---on screen right now, preserving column indices so an anchor's `col`
---stays meaningful.
---
---Minimized windows deliberately stay in window_list -- that's the whole
---point of this design, it's what lets a workspace's column order
---survive a hide/show cycle untouched. They must not take part in layout
---math though: a minimized window would otherwise claim a share of its
---column's height and, if a whole column were hidden, leave a gap that
---shifts every column to its right.
---@param workspace number
---@param strip string
---@return Window[][] columns indexed as in window_list, minus hidden windows
local function visible_columns(workspace, strip)
    local columns = {}
    for col, rows in ipairs(Tiling.ScrollSpace.state.windowList(workspace, strip)) do
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

---tile all columns of one strip by moving and resizing windows,
---optionally starting with anchor_window and moving out. anchor_window is
---only honored if it's actually tracked on this strip -- tileWorkspace
---below is responsible for only passing it to the bucket that contains
---it.
---
---A strip may be backed by several side-by-side displays (see
---screens.lua), so this walks a left-to-right list of per-display
---canvases rather than assuming one rectangle. Two consequences:
---  - a column takes its vertical bounds from the display it lands on,
---    so a short display beside a tall one tiles to its own height.
---  - no column is allowed to straddle the boundary between two
---    displays. A column that won't fit in the rest of the current
---    display starts at the next display's left edge instead, leaving
---    the slack as dead space at the previous display's right edge.
---    Straddling would put one window across a physical bezel at two
---    different scale factors, which looks broken; the dead space is the
---    lesser cost. Widening the preceding column to absorb it is
---    deliberately NOT done -- column widths are read back out of window
---    frames on the next pass (tileColumn's `w or frame.w`), so
---    stretching here would permanently overwrite the width the user
---    picked with cycleWindowSize.
---@param workspace number
---@param group table strip group from screens.lua: { key, screens }
---@param anchor_window Window|nil
local function tileGroup(workspace, group, anchor_window)
    local state = Tiling.ScrollSpace.state
    local strip = group.key
    local columns = visible_columns(workspace, strip)

    ---a window can anchor tiling only if it's tracked on this exact strip
    ---and currently on screen (a hidden window has no frame worth laying
    ---the rest of the strip out from)
    local function canAnchor(window)
        if not window or window:isMinimized() then return false end
        local index = state.windowIndex(window)
        return index ~= nil and index.workspace == workspace and index.strip == strip
    end

    -- if anchor window is on this strip, tile from that. otherwise use focused window
    if not canAnchor(anchor_window) then
        local focused_window = Window.focusedWindow()
        if focused_window and not Tiling.ScrollSpace.floating.isFloating(focused_window) and canAnchor(focused_window) then
            anchor_window = focused_window
        else
            anchor_window = Tiling.ScrollSpace.windows.getFirstVisibleWindow(workspace, group)
        end
    end

    if not canAnchor(anchor_window) then
        return -- nothing visible on this strip to tile
    end

    local anchor_index = state.windowIndex(anchor_window)
    if not anchor_index then
        Tiling.ScrollSpace.logger.e("anchor index not found")
        return
    end

    -- one tileable canvas per display, left to right
    local panes = {}
    for i, screen in ipairs(group.screens) do
        panes[i] = Tiling.ScrollSpace.windows.getCanvas(screen)
    end

    -- the off-canvas parking positions for columns scrolled past the
    -- strip's ends. These are the strip's OUTER edges, not each display's:
    -- an interior display edge is no longer somewhere to park, which is
    -- exactly the bug that made a column scrolled off an ultrawide show up
    -- nearly whole on the built-in beside it.
    local first_frame <const> = group.screens[1]:frame()
    local last_frame <const> = group.screens[#group.screens]:frame()
    local left_margin <const> = first_frame.x + Tiling.ScrollSpace.screen_margin
    local right_margin <const> = last_frame.x2 - Tiling.ScrollSpace.screen_margin

    ---index of the display whose canvas contains x, clamped to the ends
    ---@param x number
    ---@return number
    local function pane_at(x)
        for i, pane in ipairs(panes) do
            if x < pane.x2 then return i end
        end
        return #panes
    end

    -- make sure anchor window is within one display's canvas: a straddling
    -- anchor gets pulled back into the display holding its left edge,
    -- since every other column is laid out relative to it
    local anchor_frame = anchor_window:frame()
    local anchor_pane = panes[pane_at(anchor_frame.x)]
    anchor_frame.x = math.max(anchor_frame.x, panes[1].x)
    anchor_frame.w = math.min(anchor_frame.w, anchor_pane.w)
    anchor_frame.h = math.min(anchor_frame.h, anchor_pane.h)
    if anchor_frame.x2 > anchor_pane.x2 then
        anchor_frame.x = anchor_pane.x2 - anchor_frame.w
    end

    -- adjust anchor window column
    local column = columns[anchor_index.col]
    if not column or #column == 0 then
        Tiling.ScrollSpace.logger.e("no anchor window column")
        return
    end

    if #column == 1 then
        anchor_frame.y, anchor_frame.h = anchor_pane.y, anchor_pane.h
        Tiling.ScrollSpace.windows.moveWindow(anchor_window, anchor_frame)
    else
        local n = #column - 1 -- number of other windows in column
        local bottom_gap = Tiling.ScrollSpace.windows.getGap("bottom")
        local h = math.max(0, anchor_pane.h - anchor_frame.h - (n * bottom_gap)) // n
        local bounds = { x = anchor_frame.x, x2 = nil, y = anchor_pane.y, y2 = anchor_pane.y2 }
        Tiling.tileColumn(column, bounds, h, anchor_frame.w, anchor_window:id(), anchor_frame.h)
    end
    update_virtual_positions(workspace, strip, column, anchor_frame.x)

    local right_gap = Tiling.ScrollSpace.windows.getGap("right")
    local left_gap = Tiling.ScrollSpace.windows.getGap("left")

    -- tile windows from anchor right. fully hidden columns are skipped
    -- outright rather than consuming a slot's worth of x -- they occupy
    -- no space on screen, so the strip closes up over them
    local x = anchor_frame.x2 + right_gap
    local pane_i = pane_at(anchor_frame.x)
    for col = anchor_index.col + 1, #columns do
        local col_windows = columns[col]
        if #col_windows > 0 then
            -- peek at the column's natural width (the same value tileColumn
            -- falls back to via `w or frame.w`) to see whether it still
            -- fits on this display. The fits-on-the-next-one guard keeps a
            -- column wider than any single display from walking the panes
            -- forever -- it just gets placed and clipped where it is.
            local natural_w = col_windows[1]:frame().w
            while pane_i < #panes and x + natural_w > panes[pane_i].x2
                and natural_w <= panes[pane_i + 1].w do
                pane_i = pane_i + 1
                x = math.max(x, panes[pane_i].x)
            end

            local pane = panes[pane_i]
            local bounds = { x = math.min(x, right_margin), x2 = nil, y = pane.y, y2 = pane.y2 }
            local width = Tiling.tileColumn(col_windows, bounds)
            update_virtual_positions(workspace, strip, col_windows, x)
            x = x + width + right_gap
        end
    end

    -- tile windows from anchor left (same no-straddling rule, mirrored)
    local x2 = anchor_frame.x - left_gap
    local pane_j = pane_at(anchor_frame.x)
    for col = anchor_index.col - 1, 1, -1 do
        local col_windows = columns[col]
        if #col_windows > 0 then
            local natural_w = col_windows[1]:frame().w
            while pane_j > 1 and x2 - natural_w < panes[pane_j].x
                and natural_w <= panes[pane_j - 1].w do
                pane_j = pane_j - 1
                x2 = math.min(x2, panes[pane_j].x2)
            end

            local pane = panes[pane_j]
            local bounds = { x = nil, x2 = math.max(x2, left_margin), y = pane.y, y2 = pane.y2 }
            local width = Tiling.tileColumn(col_windows, bounds)
            update_virtual_positions(workspace, strip, col_windows, x2 - width)
            x2 = x2 - width - left_gap
        end
    end
end

---tile every strip's columns in a workspace, optionally starting from
---anchor_window (on whichever strip actually has it) and moving out from
---there. A workspace spans every connected display at once; displays
---arranged side by side share one strip that flows across them, while
---displays stacked vertically get one strip each (screens.lua decides).
---All strips show/hide together when the workspace switches, but
---scrolling/navigation (focus/swap/slurp/barf) stays within one strip.
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

    -- a bucket whose key is no longer any strip's key (a display that's
    -- been unplugged, or a rearrangement that re-keyed its group) is
    -- skipped rather than guessed at; State.reconcileStrips is what folds
    -- those back in, driven by the screen watcher
    local groups = {}
    for _, group in ipairs(Tiling.ScrollSpace.screens.groups()) do
        groups[group.key] = group
    end

    for strip, _ in pairs(Tiling.ScrollSpace.state.windowList(workspace)) do
        local group = groups[strip]
        if group then
            tileGroup(workspace, group, anchor_window)
        end
    end
end

return Tiling
