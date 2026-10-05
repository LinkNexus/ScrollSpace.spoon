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

        it("flows one strip continuously across side-by-side displays", function()
            -- the default arrangement is two flush 1000pt displays, so the
            -- column sequence continues across the boundary instead of
            -- each display starting its own strip: b lands right after a
            -- on the FIRST display, not at the second display's origin
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 }, { screen = "screen_a" })
            local b = mock_window(2, "b", { x = 0, y = 0, w = 100, h = 100 }, { screen = "screen_b" })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a

            Tiling.tileWorkspace(1)

            assert.are.equal(8, a:frame().x)   -- strip starts at the first canvas
            assert.are.equal(116, b:frame().x) -- 8 + 100 wide + 8 gap
        end)

        it("never lets a column straddle two displays", function()
            -- a is wide enough that the next column would cross the bezel
            -- at x=992 (screen_a's canvas edge), so b starts at screen_b's
            -- canvas origin instead, leaving the slack as dead space
            local a = mock_window(1, "a", { x = 8, y = 0, w = 900, h = 100 }, { screen = "screen_a" })
            local b = mock_window(2, "b", { x = 1000, y = 0, w = 200, h = 100 }, { screen = "screen_b" })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a

            Tiling.tileWorkspace(1)

            assert.are.equal(908, a:frame().x2)  -- a ends well short of 992
            assert.are.equal(1008, b:frame().x)  -- pushed to the next canvas
        end)

        it("flows leftward across the bezel instead of parking at an interior edge", function()
            -- the bug this feature fixes: with per-display strips, a column
            -- scrolled off the left of the second display got parked 1pt
            -- inside THAT display's left edge, which put almost the whole
            -- window on the first display. It should simply continue the
            -- strip onto the first display instead.
            local a = mock_window(1, "a", { x = 0, y = 0, w = 900, h = 100 }, { screen = "screen_a" })
            local anchor_win = mock_window(2, "b", { x = 1008, y = 0, w = 900, h = 100 }, { screen = "screen_b" })
            Windows.addWindow(a, 1); Windows.addWindow(anchor_win, 1)
            Mocks.focused_window = anchor_win

            Tiling.tileWorkspace(1)

            -- 992 (first canvas's right edge) - 900 wide
            assert.are.equal(92, a:frame().x)
        end)

        it("parks a column scrolled off the strip at the strip's outer edge", function()
            -- only once a column runs off the END of the whole strip does it
            -- get parked off-canvas, and then at the strip's outer margin
            -- (first display's left edge + screen_margin), where there is no
            -- other display for it to bleed onto
            local p1 = mock_window(1, "p", { x = 0, y = 0, w = 900, h = 100 })
            local p2 = mock_window(2, "q", { x = 0, y = 0, w = 900, h = 100 })
            local p3 = mock_window(3, "r", { x = 0, y = 0, w = 900, h = 100 })
            local anchor_win = mock_window(4, "anchor", { x = 1008, y = 0, w = 900, h = 100 })
            local strip = State.windowList(1, "screen_a")
            strip[1] = { p1 }
            strip[2] = { p2 }
            strip[3] = { p3 }
            strip[4] = { anchor_win }
            Mocks.focused_window = anchor_win

            Tiling.tileWorkspace(1)

            assert.are.equal(92, p3:frame().x)    -- still flowing, on display one
            assert.are.equal(1, p1:frame().x2)    -- parked at the strip's left margin
        end)

        it("tiles vertically stacked displays as separate strips", function()
            -- stacked displays get one strip each, so each tiles to its own
            -- vertical canvas rather than flowing across the bezel
            Mocks.set_screens({
                { uuid = "screen_a", x = 0, y = 0, h = 800 },
                { uuid = "screen_b", x = 0, y = 800, h = 800 },
            })
            local a = mock_window(1, "a", { x = 0, y = 0, w = 100, h = 100 }, { screen = "screen_a" })
            local b = mock_window(2, "b", { x = 0, y = 0, w = 100, h = 100 }, { screen = "screen_b" })
            Windows.addWindow(a, 1); Windows.addWindow(b, 1)
            Mocks.focused_window = a

            Tiling.tileWorkspace(1)

            assert.are.equal(40, a:frame().y)  -- top display's canvas
            assert.are.equal(840, b:frame().y) -- bottom display's canvas
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
