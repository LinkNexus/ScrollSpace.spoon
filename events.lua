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

---refresh window layout on screen change (resolution/arrangement change,
---or a display connecting/disconnecting). reconcileScreens() first, so a
---disconnected monitor's windows merge onto the remaining screen instead
---of staying stranded on a screen_uuid nothing will ever tile again.
local screen_watcher = Screen.watcher.new((function()
    local pending_timer = nil
    return function()
        if not pending_timer then
            pending_timer = Timer.doAfter(Window.animationDuration, function()
                pending_timer = nil
                Events.ScrollSpace.state.reconcileScreens()
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
            self.state.save()
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
            self.state.uiWatcherDelete(window:id())
            self.state.save()
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
            -- set before the switch below: switchWorkspace() focuses the
            -- target workspace's last_focused window, so recording this
            -- one first makes it land back on exactly the window that was
            -- just focused rather than whatever was focused there before.
            self.state.last_focused[index.workspace] = window:id()

            -- Something outside ScrollSpace -- a Dock icon, a notification,
            -- cmd-tab, an `open -a` or URL handler -- can focus a window
            -- living on a workspace we're not currently on. macOS just
            -- unminimizes it in place, so it lands on top of the active
            -- workspace's strip: one stray window overlaying a layout it
            -- isn't part of, and nothing re-minimizes it until the next
            -- manual switch. Follow the window to its own workspace
            -- instead.
            --
            -- Re-entrancy is safe. The minimize()/unminimize() storm this
            -- kicks off re-enters this handler as windowNotVisible (a
            -- no-op branch) and windowVisible (early-returns for windows
            -- already in index_table, which all of these are), and
            -- switchWorkspace's closing focus() call re-enters as
            -- windowFocused for `window`, which the prev_focused_window
            -- guard above has already claimed.
            if index.workspace ~= self.state.current_workspace then
                self.logger.df("following externally focused window to workspace %d", index.workspace)
                self.workspace.switchWorkspace(index.workspace)
            end

            -- falls through to the tileWorkspace() at the bottom with this
            -- window as the anchor, so a window that was scrolled off its
            -- strip's viewport is scrolled back into view rather than
            -- being focused somewhere off-canvas
            workspace, anchor_window = index.workspace, window
        end
    elseif event == "windowVisible" or event == "windowUnfullscreened" then
        if self.state.windowIndex(window) then
            -- already tracked: our own unminimize() during a workspace
            -- switch re-triggered this event, not a genuinely new window
            return
        end
        workspace, anchor_window = self.windows.addWindow(window), window
    elseif event == "windowNotVisible" then
        -- do NOT remove the window from window_list here -- this fires for
        -- our own minimize() calls during a workspace switch too, and
        -- removing it would defeat the entire point of this design.
        -- Only windowDestroyed does real list surgery.
    elseif event == "windowFullscreened" then
        workspace = self.windows.removeWindow(window, true) -- don't focus new window if fullscreened
    elseif event == "windowDestroyed" then
        workspace = self.windows.removeWindow(window)
        self.state.save()
    elseif event == "windowTitleChanged" then
        -- re-run the assignment rules so a window can follow its own
        -- title between workspaces. Only an explicit rule match moves it:
        -- assign() returns nil when nothing matched, and a non-match must
        -- leave the window where it already is rather than pulling it
        -- onto whatever workspace happens to be active.
        local index = self.state.windowIndex(window)
        if index then
            local reassigned = self.rule_engine.assign(window)
            if reassigned and reassigned ~= index.workspace then
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
