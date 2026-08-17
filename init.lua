--- === ScrollSpace.spoon ===
---
--- i3/niri-style virtual workspaces with built-in PaperWM-style scrolling
--- column tiling, without using native macOS Spaces or FlashSpace.
---
--- # Usage
---
--- `ScrollSpace:start()` will begin automatically tiling new and existing
--- windows on the current workspace.
--- `ScrollSpace:stop()` will release control over windows.
---
--- Assign windows to workspaces at creation time with `ScrollSpace.rules`:
--- ```
--- ScrollSpace.rules = {
---     { app = "kitty", title = "^btop", workspace = 3 },
---     { app = "Zen Browser", title = "Anthropic", workspace = 2 },
---     { app = "Zen Browser", workspace = 1 },
--- }
--- ```
---
--- See CLAUDE.md in this directory for the full design.
---
--- Download: [https://github.com/LinkNexus/ScrollSpace.spoon](https://github.com/LinkNexus/ScrollSpace.spoon)

local ScrollSpace = {}
ScrollSpace.__index = ScrollSpace

-- Metadata
ScrollSpace.name = "ScrollSpace"
ScrollSpace.version = "0.1"
ScrollSpace.author = "LinkNexus"
ScrollSpace.homepage = "https://github.com/LinkNexus/ScrollSpace.spoon"
ScrollSpace.license = "MIT - https://opensource.org/licenses/MIT"

-- Types

---@alias ScrollSpace table ScrollSpace module object
---@alias Window userdata a ui.window
---@alias Frame table hs.geometry.rect

-- logger
ScrollSpace.logger = hs.logger.new(ScrollSpace.name)

-- Load modules
ScrollSpace.config = dofile(hs.spoons.resourcePath("config.lua"))
ScrollSpace.state = dofile(hs.spoons.resourcePath("state.lua"))
ScrollSpace.windows = dofile(hs.spoons.resourcePath("windows.lua"))
ScrollSpace.tiling = dofile(hs.spoons.resourcePath("tiling.lua"))
-- named rule_engine, not rules -- ScrollSpace.rules is the user-facing
-- assignment-rules table (from config.lua's Config.rules), and the config
-- apply loop below would silently clobber the module table if both used
-- the same key
ScrollSpace.rule_engine = dofile(hs.spoons.resourcePath("rules.lua"))
ScrollSpace.floating = dofile(hs.spoons.resourcePath("floating.lua"))
ScrollSpace.scratchpad = dofile(hs.spoons.resourcePath("scratchpad.lua"))
ScrollSpace.workspace = dofile(hs.spoons.resourcePath("workspace.lua"))
ScrollSpace.events = dofile(hs.spoons.resourcePath("events.lua"))
ScrollSpace.actions = dofile(hs.spoons.resourcePath("actions.lua"))

-- Apply config defaults directly onto ScrollSpace (window_gap, window_ratios,
-- screen_margin, window_filter, rules, default_workspace, state_file,
-- default_hotkeys, infinite_loop_window all become ScrollSpace.<key>)
for k, v in pairs(ScrollSpace.config) do
    ScrollSpace[k] = v
end

-- Initialize modules. Order doesn't matter for cross-module references --
-- each module's init() just stores the parent ScrollSpace reference; actual
-- calls between modules only happen later, once every module is loaded.
ScrollSpace.state.init(ScrollSpace)
ScrollSpace.windows.init(ScrollSpace)
ScrollSpace.tiling.init(ScrollSpace)
ScrollSpace.rule_engine.init(ScrollSpace)
ScrollSpace.floating.init(ScrollSpace)
ScrollSpace.scratchpad.init(ScrollSpace)
ScrollSpace.workspace.init(ScrollSpace)
ScrollSpace.events.init(ScrollSpace)
ScrollSpace.actions.init(ScrollSpace)

---start automatic window tiling
---@return ScrollSpace
function ScrollSpace:start()
    self.state.clear()
    self.state.load() -- reconcile persisted layout against windows that still exist

    -- pick up anything the loaded snapshot didn't cover. hs.window.filter's
    -- own internals can transiently error here (observed live: a
    -- momentarily-unfetchable NSRunningApplication during getWindows()),
    -- which must not be allowed to abort events.start() below -- without
    -- live event tracking nothing else works either, so a partial/failed
    -- initial catch-up pass is far better than no event system at all
    local ok, err = pcall(self.workspace.refreshWindows)
    if not ok then
        self.logger.e("refreshWindows failed during start(), continuing anyway: " .. tostring(err))
    end

    -- events.start()'s own window_filter:subscribe() call hits the same
    -- class of transient hs.window.filter internal error (observed live,
    -- a second, differently-shaped crash from the one above) -- without
    -- this guard, that error propagates out of ScrollSpace:start()
    -- entirely, and since Hammerspoon loads the whole init.lua as one
    -- chunk under a single xpcall, it silently aborts every hotkey
    -- binding and require() declared after ScrollSpace:start() in the
    -- parent config too. One retry shortly after: these have all been
    -- transient races that succeed on a second attempt.
    local events_ok, events_err = pcall(self.events.start)
    if not events_ok then
        self.logger.e("events.start() failed during start(), retrying shortly: " .. tostring(events_err))
        hs.timer.doAfter(2, function()
            local retry_ok, retry_err = pcall(self.events.start)
            if not retry_ok then
                self.logger.e("events.start() retry also failed: " .. tostring(retry_err))
            end
        end)
    end

    return self
end

---stop automatic window tiling
---@return ScrollSpace
function ScrollSpace:stop()
    self.events.stop()

    -- unminimize everything on every workspace (not just the active one) so
    -- nothing is left stranded hidden once we stop managing visibility
    for _, workspace in ipairs(self.state.allWorkspaces()) do
        for _, columns in pairs(self.state.windowList(workspace)) do
            for _, column in ipairs(columns) do
                for _, window in ipairs(column) do
                    window:unminimize()
                end
            end
        end
    end
    for id, _ in pairs(self.state.is_floating) do
        local window = hs.window.get(id)
        if window then window:unminimize() end
    end
    if self.state.scratchpad then
        local window = hs.window.get(self.state.scratchpad)
        if window then window:unminimize() end
    end

    for _, window in ipairs(self.window_filter:getWindows()) do
        window:setFrameInScreenBounds()
    end
    return self
end

---tile windows for a workspace
---optionally starting with anchor_window and moving out
---@param workspace number
---@param anchor_window Window|nil
function ScrollSpace:tileWorkspace(workspace, anchor_window)
    self.tiling.tileWorkspace(workspace, anchor_window)
end

---bind userdefined hotkeys to ScrollSpace actions
---use ScrollSpace.default_hotkeys for suggested defaults
---@param mapping table
function ScrollSpace:bindHotkeys(mapping)
    self.actions.bindHotkeys(mapping)
end

return ScrollSpace
