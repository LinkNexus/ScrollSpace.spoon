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
---or a display connecting/disconnecting). reconcileStrips() first, so a
---disconnected monitor's windows merge onto the remaining screen instead
---of staying stranded on a screen_uuid nothing will ever tile again.
local screen_watcher = Screen.watcher.new((function()
    local pending_timer = nil
    return function()
        if not pending_timer then
            pending_timer = Timer.doAfter(Window.animationDuration, function()
                pending_timer = nil
                Events.ScrollSpace.state.reconcileStrips()
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

---minimum gap between two follows. A hard loop breaker, not a nicety:
---switchWorkspace() minimizes a whole workspace and unminimizes another,
---so if anything re-surfaces a window that was just minimized, each
---follow can provoke the next one and the two workspaces ping-pong
---indefinitely. Confirmed live: a `darwin-rebuild switch` relaunches
---apps, every restored window lands on its rule's workspace, addWindow()
---minimizes the ones that aren't current, the apps re-show them as they
---finish starting up, and the result was a continuous minimize/unminimize
---storm that never settled. Dropping follows that arrive inside this
---window bounds the damage to one switch however bad the event storm is.
---Lives on State rather than as a local here so State.clear() resets it
---with the rest of the runtime bookkeeping.
local FOLLOW_COOLDOWN <const> = 1.0

---whether a window surfacing can be attributed to the user asking for it,
---as opposed to an app restoring or recreating its own window in the
---background. This is the signal windowFocused got for free -- a focused
---window's app is frontmost by definition -- and that windowVisible has
---to ask for explicitly, since it fires for background windows too.
---@param window Window
---@return boolean
local function surfaced_by_user(window)
    if Window.focusedWindow() == window then return true end
    local app = window:application()
    return app ~= nil and app:isFrontmost()
end

---follow a window that surfaced from outside ScrollSpace to its own
---workspace, rather than letting it sit on top of a strip it isn't part
---of. Shared by the windowFocused and windowVisible branches below.
---
---last_focused is set before the switch on purpose: switchWorkspace()
---focuses the target workspace's last_focused window, so recording this
---one first makes it land back on exactly the window that surfaced
---rather than whatever was focused there before.
---@param self ScrollSpace
---@param window Window
---@param workspace number the workspace the window belongs to
---@return boolean whether the switch actually happened
local function follow_to_own_workspace(self, window, workspace)
    local now = Timer.secondsSinceEpoch()
    if now - self.state.last_follow_at < FOLLOW_COOLDOWN then
        self.logger.df("not following to workspace %d: within follow cooldown", workspace)
        return false
    end
    self.state.last_follow_at = now

    self.state.last_focused[workspace] = window:id()
    self.logger.df("following externally surfaced window to workspace %d", workspace)
    self.workspace.switchWorkspace(workspace)
    return true
end

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

    -- floating windows: destruction and being surfaced from outside are
    -- the only meaningful events. Their windowVisible/windowNotVisible
    -- otherwise fire from our own minimize()/unminimize() during a
    -- workspace switch and shouldn't touch tiling state -- they're
    -- excluded from tiling math entirely.
    if self.floating.isFloating(window) then
        if event == "windowDestroyed" then
            self.floating.removeFloating(window)
            self.state.uiWatcherDelete(window:id())
            self.state.save()
            return
        end

        -- a floating window is still a workspace member (is_floating
        -- stores the workspace id, not just a boolean), so the same
        -- external-surface problem applies to it: a Dock click or URL
        -- handler can unminimize and focus one belonging to an inactive
        -- workspace, leaving it on top of a strip it isn't part of.
        -- Same both-events reasoning as the tiled path below.
        local floating_workspace = self.state.is_floating[window:id()]
        if (event == "windowFocused" or event == "windowVisible")
            and floating_workspace
            and floating_workspace ~= self.state.current_workspace
            and surfaced_by_user(window) then
            follow_to_own_workspace(self, window, floating_workspace)
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
            -- instead. windowVisible below does the same, because the two
            -- events are not reliably ordered -- see the note there.
            --
            -- Re-entrancy is safe. The minimize()/unminimize() storm this
            -- kicks off re-enters this handler as windowNotVisible (a
            -- no-op branch) and windowVisible (which early-returns once
            -- current_workspace matches), and switchWorkspace's closing
            -- focus() call re-enters as windowFocused for `window`, which
            -- the prev_focused_window guard above has already claimed.
            if index.workspace ~= self.state.current_workspace then
                follow_to_own_workspace(self, window, index.workspace)
            end

            -- falls through to the tileWorkspace() at the bottom with this
            -- window as the anchor, so a window that was scrolled off its
            -- strip's viewport is scrolled back into view rather than
            -- being focused somewhere off-canvas
            workspace, anchor_window = index.workspace, window
        end
    elseif event == "windowVisible" or event == "windowUnfullscreened" then
        local index = self.state.windowIndex(window)
        if index then
            -- already tracked, so this is not a genuinely new window.
            -- Usually it's our own unminimize() during a workspace switch,
            -- which is a no-op here -- but not always.
            --
            -- switchWorkspace() sets current_workspace to the target
            -- BEFORE unminimizing it, so anything we surface ourselves
            -- always has index.workspace == current_workspace. A tracked
            -- window surfacing while its workspace is NOT current can
            -- therefore only have been unminimized from outside
            -- ScrollSpace, which is exactly the overlay case: follow it.
            --
            -- windowFocused does this too, but the two events are not
            -- reliably ordered. When macOS unminimizes and focuses in one
            -- go (clicking a link in another app, a Dock icon), the filter
            -- can deliver the focus event while the window is still
            -- minimized, and `visible = true` on the window_filter drops
            -- it -- leaving windowVisible as the only event that arrives.
            -- Handling both makes the follow order-independent; whichever
            -- arrives second finds current_workspace already matching and
            -- falls through to the plain retile.
            -- gated on surfaced_by_user: windowVisible fires for
            -- background windows too, and following those is what turned
            -- an app-launch burst into an endless workspace ping-pong.
            -- A window an app merely restored in the background is left
            -- where it is -- it overlays until the next switch, which is
            -- the behaviour that predates following at all, and is vastly
            -- preferable to a storm.
            if index.workspace ~= self.state.current_workspace
                and surfaced_by_user(window) then
                follow_to_own_workspace(self, window, index.workspace)
            end
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
