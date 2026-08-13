local Timer <const> = hs.timer
local Window <const> = hs.window
local WindowFilter <const> = hs.window.filter
local Screen <const> = hs.screen

local Events = {}
Events.__index = Events

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Events.init(scrollspace)
    Events.ScrollSpace = scrollspace
end

---refresh window layout on screen change (resolution/arrangement change --
---the canvas every workspace tiles against depends on the primary screen)
local screen_watcher = Screen.watcher.new((function()
    local pending_timer = nil
    return function()
        if not pending_timer then
            pending_timer = Timer.doAfter(Window.animationDuration, function()
                pending_timer = nil
                Events.ScrollSpace.logger.d("refreshing window layout on screen change")
                Events.ScrollSpace:tileWorkspace(Events.ScrollSpace.state.current_workspace)
            end)
        end
    end
end)())

---safety net for windowDestroyed not firing reliably when an app is
---killed abruptly (SIGTERM/force-quit/crash) instead of closed normally
----- prune any tracked windows left dangling once the app is confirmed
---gone. See State.pruneDead().
local app_watcher = hs.application.watcher.new(function(_, event)
    if event == hs.application.watcher.terminated then
        Events.ScrollSpace.state.pruneDead()
    end
end)

---callback for window events
---@param window Window
---@param event string name of the event
---@param self ScrollSpace
function Events.windowEventHandler(window, event, self)
    if not window["id"] then
        self.logger.ef("no id method for window %s in windowEventHandler", window)
        return
    end

    self.logger.df("%s for [%s]: %d", event, window:title(), window:id())

    -- the scratchpad window is not tracked in window_list/index_table at
    -- all -- its own minimize()/unminimize() calls (from toggleScratchpad)
    -- are not meaningful events here, only its destruction is
    if self.state.scratchpad == window:id() then
        if event == "windowDestroyed" then
            self.state.scratchpad = nil
        end
        return
    end

    -- floating windows: only destruction is meaningful. Their
    -- windowVisible/windowNotVisible events fire from our own
    -- minimize()/unminimize() during a workspace switch and shouldn't
    -- touch tiling state
    if self.floating.isFloating(window) then
        if event == "windowDestroyed" then
            self.floating.removeFloating(window)
        end
        return
    end

    local workspace, anchor_window = nil, nil

    if event == "windowFocused" then
        if self.state.prev_focused_window == window then
            self.logger.df("ignoring already focused window: [%s]: %d", window:title(), window:id())
            return
        end
        self.state.prev_focused_window = window -- for addWindow() insertion point
        local index = self.state.windowIndex(window)
        if index then
            workspace, anchor_window = index.workspace, window
            self.state.last_focused[index.workspace] = window:id()
        end
    elseif event == "windowVisible" or event == "windowUnfullscreened" then
        if self.state.windowIndex(window) then
            -- already tracked: our own unminimize() during a workspace
            -- switch re-triggered this event, not a genuinely new window
            return
        end
        workspace, anchor_window = self.workspace.addWindow(window), window
    elseif event == "windowNotVisible" then
        -- do NOT remove the window from window_list here -- this fires for
        -- our own minimize() calls during a workspace switch too, and
        -- removing it would defeat the entire point of this design.
        -- Only windowDestroyed does real list surgery.
    elseif event == "windowFullscreened" then
        workspace = self.workspace.removeWindow(window, true) -- don't focus new window if fullscreened
    elseif event == "windowDestroyed" then
        workspace = self.workspace.removeWindow(window)
        self.state.save()
    elseif event == "windowTitleChanged" then
        local index = self.state.windowIndex(window)
        if index then
            local reassigned = self.rule_engine.assign(window)
            if reassigned ~= index.workspace then
                self.workspace.moveWindowToWorkspace(window, reassigned)
            end
        end
    elseif event == "AXWindowMoved" or event == "AXWindowResized" then
        local index = self.state.windowIndex(window)
        workspace = index and index.workspace
    end

    if workspace then
        self:tileWorkspace(workspace, anchor_window)
        self.state.save()
    end
end

---start monitoring for window events
function Events.start()
    Events.ScrollSpace.window_filter:subscribe({
        WindowFilter.windowFocused, WindowFilter.windowVisible,
        WindowFilter.windowNotVisible, WindowFilter.windowFullscreened,
        WindowFilter.windowUnfullscreened, WindowFilter.windowDestroyed,
        WindowFilter.windowTitleChanged,
    }, function(window, _, event) Events.windowEventHandler(window, event, Events.ScrollSpace) end)

    screen_watcher:start()
    app_watcher:start()
end

---stop monitoring for window events
function Events.stop()
    Events.ScrollSpace.window_filter:unsubscribeAll()
    Events.ScrollSpace.state.uiWatcherStopAll()
    app_watcher:stop()
    screen_watcher:stop()
end

return Events
