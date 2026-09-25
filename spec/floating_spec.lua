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

    describe("focusFloating", function()
        it("raises the whole floating layer, leaving the target focused last", function()
            State.current_workspace = 1
            local tiled = mock_window(1, "tiled")
            local floater_a = mock_window(2, "floater a")
            local floater_b = mock_window(3, "floater b")
            Windows.addWindow(tiled, 1)
            State.is_floating[2] = 1
            State.is_floating[3] = 1
            Mocks.focused_window = tiled
            Mocks.focus_order = {}

            local target = Floating.focusFloating()

            assert.are.equal(floater_a, target)
            -- both raised, target last so it ends up on top of the layer
            assert.are.same({ 3, 2 }, Mocks.focus_order)
            assert.are.equal(floater_a, Mocks.focused_window)
        end)

        it("cycles to the next floating window when one is already focused", function()
            State.current_workspace = 1
            local floater_a = mock_window(1, "floater a")
            local floater_b = mock_window(2, "floater b")
            State.is_floating[1] = 1
            State.is_floating[2] = 1

            Mocks.focused_window = nil
            assert.are.equal(floater_a, Floating.focusFloating())
            assert.are.equal(floater_b, Floating.focusFloating())
            -- wraps back around to the start of the layer
            assert.are.equal(floater_a, Floating.focusFloating())
        end)

        it("skips floating windows hidden with another workspace", function()
            State.current_workspace = 1
            local here = mock_window(1, "here")
            local elsewhere = mock_window(2, "elsewhere", nil, { minimized = true })
            State.is_floating[1] = 1
            State.is_floating[2] = 2

            assert.are.equal(here, Floating.focusFloating())
        end)

        it("includes visible windows ScrollSpace doesn't track at all", function()
            -- window_filter exclusions (Finder, System Settings) are never
            -- tiled and never minimized -- they float in practice, and
            -- focusWindow can't reach them since they aren't in window_list
            State.current_workspace = 1
            local tiled = mock_window(1, "tiled")
            local untracked = mock_window(2, "Finder", nil, { app = "Finder" })
            Windows.addWindow(tiled, 1)
            Mocks.focused_window = tiled

            assert.are.equal(untracked, Floating.focusFloating())
        end)

        it("leaves picture-in-picture panels and the scratchpad alone", function()
            State.current_workspace = 1
            mock_window(1, "PiP", nil, { subrole = "AXSystemFloatingWindow" })
            mock_window(2, "scratch")
            State.scratchpad = 2
            Mocks.focus_order = {}

            assert.is_nil(Floating.focusFloating())
            assert.are.same({}, Mocks.focus_order)
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
