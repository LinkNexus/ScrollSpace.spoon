---@diagnostic disable

local M = {}

---@type table<string, table> uuid -> screen, populated by init_mocks
M.screens = {}

---stand-in for hs.geometry.rect: x2/y2/center are computed from x/y/w/h,
---and assigning x2/y2 resizes rather than adding an unrelated field --
---tiling.lua leans on both behaviours (`frame.y2 = math.min(...)` is how
---tileColumn clips a window to its bounds)
function M.rect(x, y, w, h)
    local r = { x = x, y = y, w = w, h = h }
    return setmetatable({}, {
        __index = function(_, k)
            if k == "x2" then return r.x + r.w end
            if k == "y2" then return r.y + r.h end
            if k == "center" then return { x = r.x + r.w / 2, y = r.y + r.h / 2 } end
            return r[k]
        end,
        __newindex = function(_, k, v)
            if k == "x2" then
                r.w = v - r.x
            elseif k == "y2" then
                r.h = v - r.y
            else
                r[k] = v
            end
        end,
    })
end

function M.mock_screen(uuid, x)
    x = x or 0
    return {
        frame = function() return M.rect(x, 32, 1000, 668) end,
        fullFrame = function() return M.rect(x, 0, 1000, 800) end,
        getUUID = function() return uuid end,
    }
end

---@param id number
---@param title string
---@param frame table|nil
---@param opts table|nil { app = string, screen = string, minimized = boolean, subrole = string }
function M.mock_window(id, title, frame, opts)
    opts = opts or {}
    frame = frame or { x = 0, y = 0, w = 100, h = 100 }
    local x, y, w, h = frame.x, frame.y, frame.w, frame.h

    local minimized = opts.minimized or false
    local screen_uuid = opts.screen or "screen_a"
    local app_name = opts.app or "Terminal"

    local window
    window = {
        id = function() return id end,
        title = function() return title end,
        -- a fresh rect per call, as hs.window:frame() does -- callers
        -- mutate it freely and only setFrame() writes back
        frame = function() return M.rect(x, y, w, h) end,
        application = function()
            return {
                name = function() return app_name end,
                bundleID = function() return "com.example." .. app_name end,
            }
        end,
        tabCount = function() return 0 end,
        isMaximizable = function() return true end,
        subrole = function() return opts.subrole or "AXStandardWindow" end,
        isStandard = function() return (opts.subrole or "AXStandardWindow") == "AXStandardWindow" end,
        newWatcher = function()
            return { start = function() end, stop = function() end }
        end,
        -- focus_order records every focus() call in order, so specs can
        -- assert on which window was raised last (floating.focusFloating
        -- focuses the whole layer in turn, target last)
        focus = function()
            M.focused_window = window
            table.insert(M.focus_order, id)
        end,
        -- takes self explicitly: every hs.window call site uses method
        -- syntax, so a one-parameter setFrame would silently bind the
        -- window itself as the frame
        setFrame = function(_, new_frame)
            x, y, w, h = new_frame.x, new_frame.y, new_frame.w, new_frame.h
        end,
        setFrameInScreenBounds = function() end,
        screen = function() return M.screens[screen_uuid] end,
        isMinimized = function() return minimized end,
        minimize = function() minimized = true end,
        unminimize = function() minimized = false end,
        -- test helpers, not part of the hs.window API
        _setTitle = function(t) title = t end,
        _setScreen = function(uuid) screen_uuid = uuid end,
    }
    M.windows[id] = window
    return window
end

---build the parent-Spoon table the modules hang their init() reference off
function M.get_mock_scrollspace(modules)
    local scrollspace = {
        state = modules.State,
        windows = modules.Windows,
        tiling = modules.Tiling,
        rule_engine = modules.Rules,
        floating = modules.Floating,
        scratchpad = modules.Scratchpad,
        workspace = modules.Workspace,
        events = modules.Events or { windowEventHandler = function() end },
        window_filter = {
            getWindows = function() return {} end,
            isWindowAllowed = function() return true end,
            isAppAllowed = function() return true end,
        },
        logger = {
            d = function(...) end,
            e = function(...) end,
            v = function(...) end,
            w = function(...) end,
            df = function(...) end,
            ef = function(...) end,
            vf = function(...) end,
            getLogLevel = function() return "warning" end,
            setLogLevel = function(...) end,
        },
        screen_margin = 1,
        window_gap = 8,
        window_ratios = { 0.23607, 0.38195, 0.61804 },
        infinite_loop_window = false,
        default_workspace = 1,
        state_file = "/dev/null",
        rules = {},
        pip_subroles = { AXSystemFloatingWindow = true, AXFloatingWindow = true },
    }
    scrollspace.tileWorkspace = function(_, workspace, anchor)
        modules.Tiling.tileWorkspace(workspace, anchor)
    end
    return scrollspace
end

function M.init_mocks()
    M.windows = {}
    M.focused_window = nil
    M.focus_order = {}
    M.screens = {
        screen_a = M.mock_screen("screen_a", 0),
        screen_b = M.mock_screen("screen_b", 1000),
    }
    M.connected = { "screen_a", "screen_b" }

    _G.hs = {
        screen = {
            find = function(uuid)
                for _, u in ipairs(M.connected) do
                    if u == uuid then return M.screens[uuid] end
                end
                return nil
            end,
            primaryScreen = function() return M.screens[M.connected[1]] end,
            mainScreen = function() return M.screens[M.connected[1]] end,
            allScreens = function()
                local out = {}
                for _, u in ipairs(M.connected) do table.insert(out, M.screens[u]) end
                return out
            end,
            watcher = { new = function(_) return { start = function() end, stop = function() end } end },
        },
        uielement = {
            watcher = { windowMoved = "windowMoved", windowResized = "windowResized" },
        },
        window = {
            animationDuration = 0.0,
            focusedWindow = function() return M.focused_window end,
            get = function(id) return M.windows[id] end,
            allWindows = function()
                local out = {}
                for _, w in pairs(M.windows) do table.insert(out, w) end
                table.sort(out, function(a, b) return a:id() < b:id() end)
                return out
            end,
            visibleWindows = function()
                local out = {}
                for _, w in pairs(M.windows) do
                    if not w:isMinimized() then table.insert(out, w) end
                end
                table.sort(out, function(a, b) return a:id() < b:id() end)
                return out
            end,
            filter = { new = function() return {} end },
        },
        application = {
            watcher = {
                terminated = "terminated",
                new = function(_) return { start = function() end, stop = function() end } end,
            },
        },
        geometry = { rect = M.rect },
        spoons = { resourcePath = function(file) return "./" .. file end },
        fnutils = {
            partial = function(func, ...)
                local args = { ... }
                return function(...)
                    local all = {}
                    for i = 1, #args do all[i] = args[i] end
                    local varargs = { ... }
                    for i = 1, #varargs do all[#args + i] = varargs[i] end
                    return func(table.unpack(all))
                end
            end,
            contains = function(t, e)
                for _, v in ipairs(t) do if v == e then return true end end
                return false
            end,
        },
        logger = {
            new = function(_)
                return {
                    d = function(...) end,
                    e = function(...) end,
                    v = function(...) end,
                    w = function(...) end,
                    df = function(...) end,
                    ef = function(...) end,
                    vf = function(...) end,
                    getLogLevel = function() return "warning" end,
                    setLogLevel = function(...) end,
                }
            end,
        },
        timer = {
            secondsSinceEpoch = function() return 0 end,
            doUntil = function(c, _, _) c() end,
            doAfter = function(_, fn) fn() end,
        },
        -- pass-through stand-in for hs.json: serialize() already emits a
        -- JSON-shaped table with string keys, and load() re-parses those
        -- keys itself, so handing the same table back models a real
        -- encode/decode round-trip faithfully enough for these specs
        json = {
            encode = function(t)
                M.encoded = t
                return "<encoded>"
            end,
            decode = function(_) return M.encoded end,
        },
        notify = { show = function(...) end },
    }
end

return M
