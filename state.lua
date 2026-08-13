local Watcher <const> = hs.uielement.watcher
local Timer <const> = hs.timer

local State = {}
State.__index = State

---private state
local window_list = {} -- 3D array of tiles in order of [workspace][x][y]
local index_table = {} -- dictionary of {workspace, col, row} with window id for keys
local ui_watchers = {} -- dictionary of uielement watchers with window id for keys
local x_positions = {} -- dictionary of horizontal positions with [workspace][id] for keys
---public state
State.is_floating = {} -- dictionary of workspace id (not just boolean) with window id for keys
State.last_focused = {} -- dictionary of window id with workspace id for keys
State.scratchpad = nil ---@type number|nil window id, lives outside window_list/index_table entirely
State.current_workspace = nil ---@type number
State.prev_focused_window = nil ---@type Window|nil

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function State.init(scrollspace)
    State.ScrollSpace = scrollspace
    State.clear()
end

---clear all internal state
function State.clear()
    window_list = {}
    index_table = {}
    ui_watchers = {}
    x_positions = {}
    State.is_floating = {}
    State.last_focused = {}
    State.scratchpad = nil
    State.current_workspace = State.ScrollSpace.default_workspace
    State.prev_focused_window = nil
end

---walk through all tiled windows in a workspace and update the index table
---@param workspace number
local function update_index(workspace)
    for col, rows in ipairs(window_list[workspace] or {}) do
        for row, window in ipairs(rows) do
            index_table[window:id()] = { workspace = workspace, col = col, row = row }
        end
    end
end

---get a proxy table for a workspace, column, or row of tiled windows
---the proxy table can be used to iterate over, insert, remove, and access
---windows while keeping track of internal state
---@param workspace number get a list of columns for a workspace
---@param column number|nil get a list of windows for a column
---@param row number|nil get a window for a row in a column
---@return Window[][]|Window[]|Window|nil
function State.windowList(workspace, column, row)
    if workspace then
        local columns = window_list[workspace]
        if column then
            local rows = columns and columns[column]
            if row then
                return rows and rows[row]
            end

            return rows and setmetatable({}, {
                __index = function(_, row) return rows[row] end,
                __newindex = function(_, row, window)
                    rows[row] = window
                    if not next(columns[column]) then table.remove(columns, column) end
                    if not next(window_list[workspace]) then window_list[workspace] = nil end
                    update_index(workspace)
                end,
                __len = function(_) return #rows end,
                __pairs = function(_) return pairs(rows) end,
                __ipairs = function(_) return ipairs(rows) end,
            })
        end

        return setmetatable({}, columns and {
            __index = function(_, column) return columns[column] end,
            __newindex = function(_, column, rows)
                -- workspace is guaranteed to exist here
                columns[column] = rows -- add a new column
                -- handle case where all columns have been removed from a workspace
                if not next(window_list[workspace]) then window_list[workspace] = nil end
                update_index(workspace)
            end,
            __len = function(_) return #columns end,
            __pairs = function(_) return pairs(columns) end,
            __ipairs = function(_) return ipairs(columns) end,
        } or { -- metatable for a nil workspace
            __newindex = function(_, column, rows)
                -- workspace may not exist here so create it
                if not window_list[workspace] then window_list[workspace] = {} end
                window_list[workspace][column] = rows
                update_index(workspace)
            end,
        })
    end
end

---get the index { workspace, col, row } of a tiled window
---@param window Window
---@param remove boolean|nil Set to true to remove the entry
---@return table|nil
function State.windowIndex(window, remove)
    local index = index_table[window:id()]
    if remove then index_table[window:id()] = nil end
    return index
end

---create and start a UI watcher for a new window
---@param window Window
function State.uiWatcherCreate(window)
    local id = window:id()
    ui_watchers[id] = window:newWatcher(
        function(window, event, _, self)
            State.ScrollSpace.events.windowEventHandler(window, event, self)
        end, State.ScrollSpace)
    State.uiWatcherStart(id)
end

---delete a UI watcher
---@param id number Window ID
function State.uiWatcherDelete(id)
    State.uiWatcherStop(id)
    ui_watchers[id] = nil
end

---start a UI watcher
---@param id number Window ID
function State.uiWatcherStart(id)
    local watcher = ui_watchers[id]
    if watcher then watcher:start({ Watcher.windowMoved, Watcher.windowResized }) end
end

---stop a UI watcher
---@param id number Window ID
function State.uiWatcherStop(id)
    local watcher = ui_watchers[id]
    if watcher then watcher:stop() end
end

---stop all UI watchers
function State.uiWatcherStopAll()
    for _, watcher in pairs(ui_watchers) do watcher:stop() end
end

---return a table that provides accessor methods to x_positions via a metatable
---@param workspace number
function State.xPositions(workspace)
    return setmetatable({}, {
        __index = function(_, id) return (x_positions[workspace] or {})[id] end,
        __newindex = function(_, id, x)
            if not x_positions[workspace] then x_positions[workspace] = {} end
            x_positions[workspace][id] = x
            if not next(x_positions[workspace]) then x_positions[workspace] = nil end
        end,
        __pairs = function(_) return pairs(x_positions[workspace] or {}) end,
    })
end

---check for the presence of a window in the tiled list
---@param id number Window ID
---@return boolean
function State.isTiled(id)
    return index_table[id] ~= nil
end

---list of all workspace ids that currently have any tracked windows
---(tiled or floating), for iterating without guessing bounds
---@return number[]
function State.allWorkspaces()
    local seen, workspaces = {}, {}
    for workspace, _ in pairs(window_list) do
        if not seen[workspace] then
            seen[workspace] = true
            table.insert(workspaces, workspace)
        end
    end
    for _, workspace in pairs(State.is_floating) do
        if not seen[workspace] then
            seen[workspace] = true
            table.insert(workspaces, workspace)
        end
    end
    table.sort(workspaces)
    return workspaces
end

---return internal state for debugging purposes
function State.get()
    return {
        window_list = window_list,
        index_table = index_table,
        ui_watchers = ui_watchers,
        x_positions = x_positions,
        is_floating = State.is_floating,
        last_focused = State.last_focused,
        scratchpad = State.scratchpad,
        current_workspace = State.current_workspace,
        prev_focused_window = State.prev_focused_window,
    }
end

---pretty print the current state
function State.dump()
    local output = { "--- ScrollSpace State ---" }

    table.insert(output, string.format("current_workspace: %s", tostring(State.current_workspace)))

    table.insert(output, "window_list:")
    for workspace, columns in pairs(window_list) do
        table.insert(output, string.format("  Workspace %s:", tostring(workspace)))
        for col_idx, column in ipairs(columns) do
            table.insert(output, string.format("    Column %d:", col_idx))
            for row_idx, window in ipairs(column) do
                table.insert(output, string.format("      Row %d: %s (%d)", row_idx, window:title(), window:id()))
            end
        end
    end

    table.insert(output, "\nindex_table:")
    for id, index in pairs(index_table) do
        table.insert(output, string.format("  Window ID %d: workspace=%s, col=%d, row=%d",
            id, tostring(index.workspace), index.col, index.row))
    end

    table.insert(output, "\nis_floating:")
    for id, workspace in pairs(State.is_floating) do
        table.insert(output, string.format("  Window ID %d is floating on workspace %s", id, tostring(workspace)))
    end

    if State.scratchpad then
        table.insert(output, string.format("\nscratchpad: %d", State.scratchpad))
    else
        table.insert(output, "\nscratchpad: nil")
    end

    table.insert(output, "---------------------")
    print(table.concat(output, "\n"))
end

---build a JSON-safe snapshot: only order/membership/workspace-tags, not
---frames -- tileWorkspace recomputes frames from the canvas on every
---call, so persisting them would just be stale data to reconcile later.
---Numeric keys (workspace ids, window ids) are stringified since
---hs.json.encode can't reliably tell a sparse numeric-keyed table from
---a JSON array.
local function serialize()
    local snapshot = {
        current_workspace = State.current_workspace,
        scratchpad = State.scratchpad,
        window_list = {},
        is_floating = {},
        last_focused = {},
    }

    for workspace, columns in pairs(window_list) do
        local cols = {}
        for _, rows in ipairs(columns) do
            local ids = {}
            for _, window in ipairs(rows) do
                table.insert(ids, window:id())
            end
            table.insert(cols, ids)
        end
        snapshot.window_list[tostring(workspace)] = cols
    end

    for id, workspace in pairs(State.is_floating) do
        snapshot.is_floating[tostring(id)] = workspace
    end

    for workspace, id in pairs(State.last_focused) do
        snapshot.last_focused[tostring(workspace)] = id
    end

    return snapshot
end

local save_timer = nil
local change_listeners = {}

---register a callback to run after every debounced State.save() write.
---Lets external consumers (e.g. a sketchybar feed) react to state changes
---without ScrollSpace needing to know they exist -- keeps the Spoon
---portable rather than baking in a dependency on any particular consumer.
---@param fn fun()
function State.onChange(fn)
    table.insert(change_listeners, fn)
end

---write the current state to State.ScrollSpace.state_file, debounced so a
---burst of events (e.g. refreshWindows adding several windows) only
---triggers one disk write, then notify onChange listeners
function State.save()
    if save_timer then save_timer:stop() end
    save_timer = Timer.doAfter(1, function()
        save_timer = nil
        local ok, json = pcall(hs.json.encode, serialize())
        if not ok then
            State.ScrollSpace.logger.e("failed to encode state: " .. tostring(json))
            return
        end
        local f = io.open(State.ScrollSpace.state_file, "w")
        if not f then
            State.ScrollSpace.logger.e("failed to open state file for writing: " .. State.ScrollSpace.state_file)
            return
        end
        f:write(json)
        f:close()

        for _, fn in ipairs(change_listeners) do
            local listener_ok, err = pcall(fn)
            if not listener_ok then
                State.ScrollSpace.logger.e("onChange listener failed: " .. tostring(err))
            end
        end
    end)
end

---load the persisted snapshot and reconcile it against currently existing
---managed windows: drop entries for windows that no longer exist by id,
---keep everything else -- including currently-minimized windows -- so a
---workspace's column order survives hs.reload(). Called once from
---ScrollSpace:start(), before the first refreshWindows().
function State.load()
    local f = io.open(State.ScrollSpace.state_file, "r")
    if not f then return end
    local content = f:read("*a")
    f:close()
    if not content or content == "" then return end

    local ok, snapshot = pcall(hs.json.decode, content)
    if not ok or type(snapshot) ~= "table" then
        State.ScrollSpace.logger.e("failed to decode state file: " .. State.ScrollSpace.state_file)
        return
    end

    local by_id = {}
    for _, window in ipairs(State.ScrollSpace.window_filter:getWindows()) do
        by_id[window:id()] = window
    end

    window_list = {}
    for workspace_str, columns in pairs(snapshot.window_list or {}) do
        local workspace = tonumber(workspace_str)
        for _, ids in ipairs(columns) do
            local rows = {}
            for _, id in ipairs(ids) do
                local window = by_id[id]
                if window then
                    table.insert(rows, window)
                    State.uiWatcherCreate(window)
                end
            end
            if #rows > 0 then
                if not window_list[workspace] then window_list[workspace] = {} end
                table.insert(window_list[workspace], rows)
            end
        end
        if window_list[workspace] then update_index(workspace) end
    end

    State.is_floating = {}
    for id_str, workspace in pairs(snapshot.is_floating or {}) do
        local id = tonumber(id_str)
        if by_id[id] then State.is_floating[id] = workspace end
    end

    State.last_focused = {}
    for workspace_str, id in pairs(snapshot.last_focused or {}) do
        State.last_focused[tonumber(workspace_str)] = id
    end

    if snapshot.scratchpad and by_id[snapshot.scratchpad] then
        State.scratchpad = snapshot.scratchpad
    end

    if snapshot.current_workspace then
        State.current_workspace = snapshot.current_workspace
    end
end

return State
