---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.floating", function()
    local H = require("spec_helper")
    local Floating, Windows, State, Scratchpad, Mocks =
        H.Floating, H.Windows, H.State, H.Scratchpad, H.Mocks
    local mock_window = Mocks.mock_window

    before_each(function() H.reset() end)

    describe("toggleFloating", function()
        it("pulls a window out of the tiled list, tagged with its workspace", function()
            local win = mock_window(1, "floater")
            Windows.addWindow(win, 2)
            Mocks.focused_window = win

            Floating.toggleFloating(win)

            assert.is_true(Floating.isFloating(win))
            assert.is_false(State.isTiled(1))
            assert.are.equal(2, State.is_floating[1])
        end)

        it("returns the window to the workspace it was floating on", function()
            -- explicitly the same workspace, not whatever the rules say now
            H.scrollspace.rules = { { app = "Terminal", workspace = 9 } }
            local win = mock_window(1, "floater")
            Windows.addWindow(win, 2)
            Mocks.focused_window = win

            Floating.toggleFloating(win)
            Floating.toggleFloating(win)

            assert.is_false(Floating.isFloating(win))
            assert.are.equal(2, State.windowIndex(win).workspace)
        end)
    end)

    describe("scratchpad", function()
        it("lives outside window_list and index_table entirely", function()
            local win = mock_window(1, "scratch")
            Windows.addWindow(win, 1)
            Mocks.focused_window = win

            Scratchpad.setScratchpad(win)

            assert.are.equal(1, State.scratchpad)
            assert.is_false(State.isTiled(1))
            assert.is_true(win:isMinimized())
        end)

        it("toggles visibility independently of the active workspace", function()
            local win = mock_window(1, "scratch")
            Windows.addWindow(win, 1)
            Mocks.focused_window = win
            Scratchpad.setScratchpad(win)

            Scratchpad.toggleScratchpad()
            assert.is_false(win:isMinimized())
            Scratchpad.toggleScratchpad()
            assert.is_true(win:isMinimized())
        end)

        it("releases a previous scratchpad back into a workspace, visible", function()
            -- the released window is minimized at that point, so without an
            -- unminimize on the way back in it stays invisible forever
            State.current_workspace = 1
            local old = mock_window(1, "old scratch")
            local new = mock_window(2, "new scratch")
            Windows.addWindow(old, 1)
            Mocks.focused_window = old
            Scratchpad.setScratchpad(old)

            Mocks.focused_window = new
            Scratchpad.setScratchpad(new)

            assert.are.equal(2, State.scratchpad)
            assert.is_true(State.isTiled(1))
            assert.is_false(old:isMinimized())
        end)
    end)
end)
