---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.tiling", function()
    local H = require("spec_helper")
    local Tiling, Windows, State, Mocks = H.Tiling, H.Windows, H.State, H.Mocks
    local mock_window = Mocks.mock_window

    before_each(function() H.reset() end)

    describe("tileWorkspace", function()
        it("stretches a lone window to the full canvas height", function()
            local win = mock_window(1, "only", { x = 0, y = 0, w = 100, h = 100 })
            Windows.addWindow(win, 1)
            Mocks.focused_window = win

            Tiling.tileWorkspace(1)

            local frame = win:frame()
            assert.are.equal(8, frame.x)   -- canvas.x: screen 0 + left gap 8
            assert.are.equal(40, frame.y)  -- canvas.y: menu bar 32 + top gap 8
            assert.are.equal(100, frame.w) -- width is preserved
            assert.are.equal(652, frame.h) -- canvas.h: 668 - (8 + 8)
        end)

        it("lays columns out left to right from the anchor", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local b = mock_window(2, "b", { x = 200, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a

            Tiling.tileWorkspace(1)

            assert.are.equal(8, a:frame().x)
            assert.are.equal(116, b:frame().x) -- a.x2 (108) + right gap 8
            assert.are.equal(652, b:frame().h)
        end)

        it("splits a column's height between its windows", function()
            local top = mock_window(1, "top", { x = 0, y = 0, w = 100, h = 100 })
            local bottom = mock_window(2, "bottom", { x = 0, y = 0, w = 100, h = 100 })
            Windows.addWindow(top, 1)
            State.windowList(1, "screen_a")[1] = { top, bottom }
            Mocks.focused_window = top

            Tiling.tileWorkspace(1)

            assert.are.equal(40, top:frame().y)
            assert.are.equal(100, top:frame().h)     -- anchor keeps its height
            assert.are.equal(148, bottom:frame().y)  -- top.y2 (140) + bottom gap 8
            assert.are.equal(544, bottom:frame().h)  -- fills the rest to canvas.y2
        end)

        it("skips minimized windows when splitting a column", function()
            -- hidden windows stay in window_list by design; letting one claim
            -- a share of its column's height would shrink the visible ones
            local visible = mock_window(1, "visible", { x = 0, y = 0, w = 100, h = 100 })
            local hidden = mock_window(2, "hidden", { x = 0, y = 0, w = 100, h = 100 },
                { minimized = true })
            Windows.addWindow(visible, 1)
            State.windowList(1, "screen_a")[1] = { visible, hidden }
            Mocks.focused_window = visible

            Tiling.tileWorkspace(1)

            assert.are.equal(40, visible:frame().y)
            assert.are.equal(652, visible:frame().h) -- treated as a lone window
        end)

        it("closes the strip over a fully hidden column", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 })
            local hidden = mock_window(2, "hidden", { x = 200, y = 0, w = 100, h = 100 })
            local c = mock_window(3, "c", { x = 400, y = 0, w = 100, h = 100 })
            Windows.addWindow(a, 1); Windows.addWindow(hidden, 1); Windows.addWindow(c, 1)
            hidden:minimize()
            Mocks.focused_window = a

            Tiling.tileWorkspace(1)

            -- c takes the slot the hidden column would have occupied rather
            -- than leaving a gap where nothing is drawn
            assert.are.equal(116, c:frame().x)
        end)

        it("tiles each screen's strip independently", function()
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 }, { screen = "screen_a" })
            -- b is bucketed to screen_b but sitting at screen_a's origin;
            -- tiling should pull it onto its own screen's canvas
            local b = mock_window(2, "b", { x = 0, y = 0, w = 100, h = 100 }, { screen = "screen_b" })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a

            Tiling.tileWorkspace(1)

            assert.are.equal(8, a:frame().x)    -- screen_a canvas starts at 8
            assert.are.equal(1008, b:frame().x) -- screen_b canvas starts at 1008
        end)

        it("does nothing for a workspace that is not active", function()
            local win = mock_window(1, "hidden", { x = 0, y = 0, w = 100, h = 100 })
            Windows.addWindow(win, 2) -- current_workspace is 1
            Mocks.focused_window = nil

            Tiling.tileWorkspace(2)

            assert.are.equal(0, win:frame().x) -- untouched
        end)
    end)
end)
