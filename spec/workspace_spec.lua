---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.workspace", function()
    local H = require("spec_helper")
    local Workspace, Windows, State, Floating, Mocks =
        H.Workspace, H.Windows, H.State, H.Floating, H.Mocks
    local mock_window = Mocks.mock_window

    before_each(function() H.reset() end)

    describe("switchWorkspace", function()
        it("hides the outgoing workspace and shows the incoming one", function()
            local one = mock_window(1, "on ws1")
            local two = mock_window(2, "on ws2")
            Windows.addWindow(one, 1)
            Windows.addWindow(two, 2)
            assert.is_true(two:isMinimized())

            Workspace.switchWorkspace(2)

            assert.are.equal(2, State.current_workspace)
            assert.is_true(one:isMinimized())
            assert.is_false(two:isMinimized())
        end)

        it("preserves column order across a hide/show cycle", function()
            -- this is the whole reason the Spoon exists: PaperWM drops hidden
            -- windows out of window_list and re-inserts them by frame center,
            -- so the strip reflows every time you come back to a workspace
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            local c = mock_window(3, "c", { x = 400, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1); Windows.addWindow(c, 1)

            Workspace.switchWorkspace(2)
            Workspace.switchWorkspace(1)

            assert.are.equal(1, State.windowIndex(a).col)
            assert.are.equal(2, State.windowIndex(b).col)
            assert.are.equal(3, State.windowIndex(c).col)
        end)

        it("hides and shows floating windows along with their workspace", function()
            local win = mock_window(1, "floater")
            Windows.addWindow(win, 1)
            Mocks.focused_window = win
            Floating.toggleFloating(win)
            assert.is_true(Floating.isFloating(win))

            Workspace.switchWorkspace(2)
            assert.is_true(win:isMinimized())
            Workspace.switchWorkspace(1)
            assert.is_false(win:isMinimized())
        end)

        it("restores focus to the workspace's last focused window", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = b
            State.last_focused[1] = b:id()

            Workspace.switchWorkspace(2)
            Workspace.switchWorkspace(1)

            assert.are.equal(b, Mocks.focused_window)
        end)

        it("is a no-op when already on that workspace", function()
            local win = mock_window(1, "here")
            Windows.addWindow(win, 1)
            Workspace.switchWorkspace(1)
            assert.is_false(win:isMinimized())
        end)
    end)

    describe("moveWindowToWorkspace", function()
        it("moves a window to an inactive workspace and hides it", function()
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)

            Workspace.moveWindowToWorkspace(win, 3)

            assert.are.equal(3, State.windowIndex(win).workspace)
            assert.is_true(win:isMinimized())
        end)

        it("shows a window moved onto the active workspace", function()
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 2) -- lands hidden, current_workspace is 1
            assert.is_true(win:isMinimized())

            Workspace.moveWindowToWorkspace(win, 1)

            assert.are.equal(1, State.windowIndex(win).workspace)
            assert.is_false(win:isMinimized())
        end)

        it("keeps the window on the screen it was already on", function()
            local win = mock_window(1, "shell", nil, { screen = "screen_b" })
            Windows.addWindow(win, 1)
            Workspace.moveWindowToWorkspace(win, 2)
            assert.are.equal("screen_b", State.windowIndex(win).screen)
        end)

        it("retags a floating window instead of tiling it", function()
            local win = mock_window(1, "floater")
            Windows.addWindow(win, 1)
            Mocks.focused_window = win
            Floating.toggleFloating(win)

            Workspace.moveWindowToWorkspace(win, 2)

            assert.are.equal(2, State.is_floating[1])
            assert.is_false(State.isTiled(1))
        end)
    end)

    describe("moveWindowToNextScreen", function()
        it("cycles the focused window to the next screen, keeping its workspace", function()
            local win = mock_window(1, "shell", nil, { screen = "screen_a" })
            Windows.addWindow(win, 1)
            Mocks.focused_window = win

            Workspace.moveWindowToNextScreen(win)

            local index = State.windowIndex(win)
            assert.are.equal("screen_b", index.screen)
            assert.are.equal(1, index.workspace)
        end)

        it("wraps around from the last screen back to the first", function()
            local win = mock_window(1, "shell", nil, { screen = "screen_b" })
            Windows.addWindow(win, 1)
            Workspace.moveWindowToNextScreen(win)
            assert.are.equal("screen_a", State.windowIndex(win).screen)
        end)

        it("does nothing with a single screen connected", function()
            Mocks.connected = { "screen_a" }
            local win = mock_window(1, "shell")
            Windows.addWindow(win, 1)
            Workspace.moveWindowToNextScreen(win)
            assert.are.equal("screen_a", State.windowIndex(win).screen)
        end)
    end)
end)
