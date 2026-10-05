---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.state", function()
    local H = require("spec_helper")
    local State, Windows, Mocks = H.State, H.Windows, H.Mocks
    local mock_window = Mocks.mock_window

    before_each(function() H.reset() end)

    describe("windowList", function()
        it("tracks a window's workspace, strip, column and row", function()
            local win = mock_window(1, "shell")
            State.windowList(2, "screen_b")[1] = { win }

            local index = State.windowIndex(win)
            assert.are.equal(2, index.workspace)
            assert.are.equal("screen_b", index.strip)
            assert.are.equal(1, index.col)
            assert.are.equal(1, index.row)
            assert.is_true(State.isTiled(1))
        end)

        it("keeps each strip's columns independent within a workspace", function()
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            State.windowList(1, "screen_a")[1] = { a }
            State.windowList(1, "screen_b")[1] = { b }

            assert.are.equal(1, #State.windowList(1, "screen_a"))
            assert.are.equal(1, #State.windowList(1, "screen_b"))
            assert.are.equal("screen_a", State.windowIndex(a).strip)
            assert.are.equal("screen_b", State.windowIndex(b).strip)
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

    describe("reconcileStrips", function()
        ---two displays stacked vertically: genuinely separate strips, so
        ---each keeps its own bucket until the arrangement changes
        local function stacked()
            Mocks.set_screens({
                { uuid = "screen_a", x = 0, y = 0, h = 800 },
                { uuid = "screen_b", x = 0, y = 800, h = 800 },
            })
        end

        it("merges a strip whose display is gone onto the primary's", function()
            stacked()
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            State.windowList(1, "screen_a")[1] = { a }
            State.windowList(1, "screen_b")[1] = { b }

            Mocks.set_screens({ { uuid = "screen_a", x = 0, y = 0, h = 800 } })
            assert.is_true(State.reconcileStrips())

            assert.are.equal(2, #State.windowList(1, "screen_a"))
            assert.is_nil(State.windowList(1)["screen_b"])
            assert.are.equal("screen_a", State.windowIndex(b).strip)
        end)

        it("reports no change when the arrangement is unchanged", function()
            stacked()
            local a = mock_window(1, "a")
            State.windowList(1, "screen_a")[1] = { a }
            assert.is_false(State.reconcileStrips())
        end)

        it("merges two strips that have become one side-by-side run", function()
            -- the displays start stacked (two strips), then get rearranged
            -- side by side, which makes them a single strip keyed by the
            -- leftmost. Leaving them as two buckets would tile two
            -- overlapping strips across the same pair of displays.
            stacked()
            local a = mock_window(1, "a")
            local b = mock_window(2, "b")
            State.windowList(1, "screen_a")[1] = { a }
            State.windowList(1, "screen_b")[1] = { b }

            Mocks.set_screens({
                { uuid = "screen_a", x = 0, w = 1000 },
                { uuid = "screen_b", x = 1000, w = 1000 },
            })
            assert.is_true(State.reconcileStrips())

            assert.are.equal(2, #State.windowList(1, "screen_a"))
            assert.is_nil(State.windowList(1)["screen_b"])
            assert.are.equal("screen_a", State.windowIndex(b).strip)
        end)

        it("re-keys a strip when a display is plugged in to its left", function()
            -- the strip key is its leftmost display, so a newcomer on the
            -- left takes over the key and the existing bucket has to
            -- migrate onto it
            Mocks.set_screens({ { uuid = "screen_a", x = 0, w = 1000 } })
            local a = mock_window(1, "a")
            State.windowList(1, "screen_a")[1] = { a }

            Mocks.set_screens({
                { uuid = "newcomer", x = -1000, w = 1000 },
                { uuid = "screen_a", x = 0, w = 1000 },
            })
            assert.is_true(State.reconcileStrips())

            assert.are.equal("newcomer", State.windowIndex(a).strip)
            assert.is_nil(State.windowList(1)["screen_a"])
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

        it("merges a strip that isn't connected any more onto the primary", function()
            -- stacked, so screen_b is genuinely its own strip rather than
            -- sharing screen_a's
            Mocks.set_screens({
                { uuid = "screen_a", x = 0, y = 0, h = 800 },
                { uuid = "screen_b", x = 0, y = 800, h = 800 },
            })
            local win = mock_window(1, "a", nil, { screen = "screen_b" })
            Windows.addWindow(win, 1)
            assert.are.equal("screen_b", State.windowIndex(win).strip)
            State.save()

            State.clear()
            Mocks.set_screens({ { uuid = "screen_a", x = 0, y = 0, h = 800 } })
            State.load()

            assert.are.equal("screen_a", State.windowIndex(win).strip)
        end)
    end)
end)
