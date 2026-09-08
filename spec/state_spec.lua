---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.state", function()
    local H = require("spec_helper")
    local State, Windows, Mocks = H.State, H.Windows, H.Mocks
    local mock_window = Mocks.mock_window

    before_each(function() H.reset() end)

    describe("windowList", function()
        it("tracks a window's workspace, screen, column and row", function()
            local win = mock_window(1, "shell")
            State.windowList(2, "screen_b")[1] = { win }

            local index = State.windowIndex(win)
            assert.are.equal(2, index.workspace)
            assert.are.equal("screen_b", index.screen)
            assert.are.equal(1, index.col)
            assert.are.equal(1, index.row)
            assert.is_true(State.isTiled(1))
        end)

        it("keeps each screen's columns independent within a workspace", function()
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            State.windowList(1, "screen_a")[1] = { a }
            State.windowList(1, "screen_b")[1] = { b }

            assert.are.equal(1, #State.windowList(1, "screen_a"))
            assert.are.equal(1, #State.windowList(1, "screen_b"))
            assert.are.equal("screen_a", State.windowIndex(a).screen)
            assert.are.equal("screen_b", State.windowIndex(b).screen)
        end)
    end)

    describe("pruneDead", function()
        it("drops tracked windows whose OS window is gone", function()
            -- windowDestroyed doesn't reliably fire when an app is killed
            -- abruptly, so this is the safety net
            local alive = mock_window(1, "alive", { x = 0, y = 0, w = 100, h = 100 })
            local dead = mock_window(2, "dead", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(alive, 1); Windows.addWindow(dead, 1)

            Mocks.windows[2] = nil -- app killed
            State.pruneDead()

            assert.is_true(State.isTiled(1))
            assert.is_false(State.isTiled(2))
            assert.are.equal(1, #State.windowList(1, "screen_a"))
        end)

        it("drops dead floating windows too", function()
            local win = mock_window(1, "floater")
            State.is_floating[1] = 1
            Mocks.windows[1] = nil

            State.pruneDead()

            assert.is_nil(State.is_floating[1])
        end)
    end)

    describe("reconcileScreens", function()
        it("merges a disconnected screen's columns onto the primary", function()
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            State.windowList(1, "screen_a")[1] = { a }
            State.windowList(1, "screen_b")[1] = { b }

            Mocks.connected = { "screen_a" } -- screen_b unplugged
            assert.is_true(State.reconcileScreens())

            assert.are.equal(2, #State.windowList(1, "screen_a"))
            assert.is_nil(State.windowList(1)["screen_b"])
            assert.are.equal("screen_a", State.windowIndex(b).screen)
        end)

        it("reports no change when every screen is still connected", function()
            local a = mock_window(1, "a")
            State.windowList(1, "screen_a")[1] = { a }
            assert.is_false(State.reconcileScreens())
        end)
    end)

    describe("save and load", function()
        local path

        before_each(function()
            path = os.tmpname()
            H.scrollspace.state_file = path
        end)

        it("round-trips column order, workspace and floating tags", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            local floater = mock_window(3, "floater")
            Windows.addWindow(a, 2); Windows.addWindow(b, 2)
            State.is_floating[3] = 2
            State.current_workspace = 2
            State.save()

            State.clear()
            assert.is_false(State.isTiled(1))
            State.load()

            assert.are.equal(2, State.current_workspace)
            assert.are.equal(1, State.windowIndex(a).col)
            assert.are.equal(2, State.windowIndex(b).col)
            assert.are.equal(2, State.is_floating[3])
        end)

        it("drops windows that no longer exist on load", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            State.save()

            State.clear()
            Mocks.windows[1] = nil -- gone while Hammerspoon was reloading
            State.load()

            assert.is_false(State.isTiled(1))
            assert.are.equal(1, State.windowIndex(b).col)
        end)

        it("merges a screen that isn't connected any more onto the primary", function()
            local win = mock_window(1, "a", nil, { screen = "screen_b" })
            Windows.addWindow(win, 1)
            State.save()

            State.clear()
            Mocks.connected = { "screen_a" }
            State.load()

            assert.are.equal("screen_a", State.windowIndex(win).screen)
        end)
    end)
end)
