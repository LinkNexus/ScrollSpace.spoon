---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.events", function()
    local H = require("spec_helper")
    local Events, Windows, State, Floating, Mocks =
        H.Events, H.Windows, H.State, H.Floating, H.Mocks
    local mock_window = Mocks.mock_window

    local function fire(window, event) Events.windowEventHandler(window, event, H.scrollspace) end

    before_each(function() H.reset() end)

    describe("windowTitleChanged", function()
        it("moves a window when its new title matches a rule", function()
            H.scrollspace.rules = { { app = "kitty", title = "^btop", workspace = 3 } }
            local win = mock_window(1, "shell", nil, { app = "kitty" })
            Windows.addWindow(win, 1)

            win._setTitle("btop - system monitor")
            fire(win, "windowTitleChanged")

            assert.are.equal(3, State.windowIndex(win).workspace)
        end)

        it("leaves a window alone when the new title matches no rule", function()
            -- the fallback-to-current_workspace behaviour meant any retitle
            -- of a window on an inactive workspace (a browser switching tabs,
            -- a shell changing directory) dragged it onto the active one and
            -- popped it back on screen
            H.scrollspace.rules = { { app = "kitty", title = "^btop", workspace = 3 } }
            State.current_workspace = 1
            local win = mock_window(1, "mail", nil, { app = "Thunderbird" })
            Windows.addWindow(win, 2)

            win._setTitle("mail - 3 unread")
            fire(win, "windowTitleChanged")

            assert.are.equal(2, State.windowIndex(win).workspace)
            assert.is_true(win:isMinimized())
        end)
    end)

    describe("windowNotVisible", function()
        it("keeps the window in the list", function()
            -- this fires for the Spoon's own minimize() calls during a
            -- workspace switch; removing here would defeat the design
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)
            fire(win, "windowNotVisible")
            assert.is_true(State.isTiled(1))
        end)
    end)

    describe("windowVisible", function()
        it("adopts a genuinely new window", function()
            local win = mock_window(1, "new")
            fire(win, "windowVisible")
            assert.is_true(State.isTiled(1))
        end)

        it("ignores a window it already tracks", function()
            -- the Spoon's own unminimize() during a workspace switch
            -- re-triggers this event
            local win = mock_window(1, "shell", { x = 0, y = 0, w = 100, h = 100 })
            Windows.addWindow(win, 1)
            local col = State.windowIndex(win).col
            fire(win, "windowVisible")
            assert.are.equal(col, State.windowIndex(win).col)
            assert.are.equal(1, #State.windowList(1, "screen_a"))
        end)
    end)

    describe("windowDestroyed", function()
        it("removes the window from the list", function()
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)
            fire(win, "windowDestroyed")
            assert.is_false(State.isTiled(1))
        end)

        it("clears a destroyed scratchpad", function()
            local win = mock_window(1, "scratch")
            State.scratchpad = 1
            fire(win, "windowDestroyed")
            assert.is_nil(State.scratchpad)
        end)

        it("clears a destroyed floating window", function()
            local win = mock_window(1, "floater")
            State.is_floating[1] = 1
            fire(win, "windowDestroyed")
            assert.is_nil(State.is_floating[1])
        end)
    end)

    describe("windowFocused", function()
        it("records the workspace's last focused window", function()
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)
            fire(win, "windowFocused")
            assert.are.equal(1, State.last_focused[1])
        end)

        -- a Dock icon, a notification, cmd-tab or an `open -a` can focus a
        -- window living on an inactive workspace; macOS unminimizes it in
        -- place, so without this it lands on top of the active workspace's
        -- strip and nothing re-minimizes it until the next manual switch
        it("follows an externally focused window to its own workspace", function()
            State.current_workspace = 1
            local here = mock_window(1, "shell")
            local there = mock_window(2, "chat")
            Windows.addWindow(here, 1)
            Windows.addWindow(there, 2)
            assert.is_true(there:isMinimized())

            there:unminimize() -- what the Dock click itself does
            fire(there, "windowFocused")

            assert.are.equal(2, State.current_workspace)
            assert.is_true(here:isMinimized())
            assert.is_false(there:isMinimized())
            assert.are.equal(2, State.last_focused[2])
        end)

        it("leaves the outgoing workspace's last_focused intact", function()
            State.current_workspace = 1
            local here = mock_window(1, "shell")
            local there = mock_window(2, "chat")
            Windows.addWindow(here, 1)
            Windows.addWindow(there, 2)
            fire(here, "windowFocused")
            assert.are.equal(1, State.last_focused[1])

            State.prev_focused_window = nil
            there:unminimize()
            fire(there, "windowFocused")

            -- switching back to 1 must still restore the window that was
            -- actually in use there, not the one that pulled us away
            assert.are.equal(1, State.last_focused[1])
        end)

        it("does not switch for a window already on the active workspace", function()
            State.current_workspace = 1
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            Windows.addWindow(a, 1)
            Windows.addWindow(b, 1)

            fire(b, "windowFocused")

            assert.are.equal(1, State.current_workspace)
            assert.is_false(a:isMinimized())
            assert.is_false(b:isMinimized())
        end)
    end)
end)
