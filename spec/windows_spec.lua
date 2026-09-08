---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.windows", function()
    local H = require("spec_helper")
    local Windows, State, Mocks = H.Windows, H.State, H.Mocks
    local mock_window = Mocks.mock_window
    local Direction = Windows.Direction

    before_each(function() H.reset() end)

    describe("addWindow", function()
        it("assigns via the rule engine when no workspace is given", function()
            H.scrollspace.rules = { { app = "Zen", workspace = 3 } }
            local win = mock_window(1, "page", nil, { app = "Zen" })
            assert.are.equal(3, Windows.addWindow(win))
            assert.are.equal(3, State.windowIndex(win).workspace)
        end)

        it("falls back to the active workspace when no rule matches", function()
            State.current_workspace = 2
            local win = mock_window(1, "shell")
            assert.are.equal(2, Windows.addWindow(win))
        end)

        it("hides a window that lands on an inactive workspace", function()
            State.current_workspace = 1
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 4)
            assert.is_true(win:isMinimized())
        end)

        it("shows a minimized window that lands on the active workspace", function()
            -- windows reach addWindow already hidden often enough (an orphan
            -- reclaimed by refreshWindows, a released scratchpad, a window
            -- un-floated while its workspace was hidden) that skipping the
            -- unminimize left them invisible forever
            State.current_workspace = 1
            local win = mock_window(1, "orphan", nil, { minimized = true })
            Windows.addWindow(win, 1)
            assert.is_false(win:isMinimized())
        end)

        it("inserts a new column by comparing frame centers", function()
            local left = mock_window(1, "left", { x = 0, y = 0, w = 100, h = 100 })
            local right = mock_window(2, "right", { x = 500, y = 0, w = 100, h = 100 })
            local middle = mock_window(3, "middle", { x = 250, y = 0, w = 100, h = 100 })
            Windows.addWindow(left, 1)
            Windows.addWindow(right, 1)
            Windows.addWindow(middle, 1)
            assert.are.equal(1, State.windowIndex(left).col)
            assert.are.equal(2, State.windowIndex(middle).col)
            assert.are.equal(3, State.windowIndex(right).col)
        end)

        it("ignores picture-in-picture windows", function()
            local pip = mock_window(1, "video", nil, { subrole = "AXSystemFloatingWindow" })
            assert.is_nil(Windows.addWindow(pip, 1))
            assert.is_false(State.isTiled(1))
        end)

        it("does not add the same window twice", function()
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)
            assert.is_nil(Windows.addWindow(win, 1))
            assert.are.equal(1, #State.windowList(1, "screen_a"))
        end)
    end)

    describe("removeWindow", function()
        it("drops the window from the list and the index", function()
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)
            assert.are.equal(1, Windows.removeWindow(win, true))
            assert.is_false(State.isTiled(1))
            assert.is_nil(State.windowList(1, "screen_a", 1))
        end)

        it("closes the gap left by a removed middle column", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            local c = mock_window(3, "c", { x = 400, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1); Windows.addWindow(c, 1)
            Windows.removeWindow(b, true)
            assert.are.equal(1, State.windowIndex(a).col)
            assert.are.equal(2, State.windowIndex(c).col)
        end)
    end)

    describe("swapWindows", function()
        it("swaps two columns horizontally", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a
            Windows.swapWindows(Direction.RIGHT)
            assert.are.equal(2, State.windowIndex(a).col)
            assert.are.equal(1, State.windowIndex(b).col)
        end)

        it("swaps two rows vertically within a column", function()
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            Windows.addWindow(a, 1)
            State.windowList(1, "screen_a")[1] = { a, b }
            Mocks.focused_window = a
            Windows.swapWindows(Direction.DOWN)
            assert.are.equal(2, State.windowIndex(a).row)
            assert.are.equal(1, State.windowIndex(b).row)
        end)

        it("is a no-op past either end of a column", function()
            -- table.insert raises "position out of bounds" for row 0 or
            -- #column + 1, so an unguarded swap at the edge of a column
            -- crashed instead of doing nothing
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            Windows.addWindow(a, 1)
            State.windowList(1, "screen_a")[1] = { a, b }

            Mocks.focused_window = a
            Windows.swapWindows(Direction.UP)
            Mocks.focused_window = b
            Windows.swapWindows(Direction.DOWN)

            assert.are.equal(1, State.windowIndex(a).row)
            assert.are.equal(2, State.windowIndex(b).row)
        end)

        it("is a no-op past either end of a row of columns", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a
            Windows.swapWindows(Direction.LEFT)
            Mocks.focused_window = b
            Windows.swapWindows(Direction.RIGHT)
            assert.are.equal(1, State.windowIndex(a).col)
            assert.are.equal(2, State.windowIndex(b).col)
        end)
    end)

    describe("focusWindow", function()
        it("moves focus to the neighbouring column", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a
            assert.are.equal(b, Windows.focusWindow(Direction.RIGHT))
        end)

        it("stays put at the edge when infinite_loop_window is off", function()
            local a = mock_window(1, "a")
            Windows.addWindow(a, 1)
            Mocks.focused_window = a
            assert.is_nil(Windows.focusWindow(Direction.LEFT))
        end)

        it("does not cross screens", function()
            -- navigation is per-screen: a workspace spans every connected
            -- screen but each tiles its own independent strip
            local a = mock_window(1, "a", nil, { screen = "screen_a" })
            local b = mock_window(2, "b", nil, { screen = "screen_b" })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a
            assert.is_nil(Windows.focusWindow(Direction.RIGHT))
        end)
    end)

    describe("refreshWindows", function()
        it("adopts untracked windows and leaves tracked ones alone", function()
            State.current_workspace = 1
            local tracked = mock_window(1, "tracked")
            Windows.addWindow(tracked, 1)
            local untracked = mock_window(2, "untracked", { x = 300, y = 0, w = 100, h = 100 })

            Windows.refreshWindows()

            assert.is_true(State.isTiled(1))
            assert.is_true(State.isTiled(2))
            assert.are.equal(1, State.windowIndex(untracked).workspace)
        end)

        it("skips the scratchpad window", function()
            State.scratchpad = 7
            mock_window(7, "scratch", nil, { minimized = true })
            Windows.refreshWindows()
            assert.is_false(State.isTiled(7))
        end)
    end)
end)
