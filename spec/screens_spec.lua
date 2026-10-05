---@diagnostic disable
local H = dofile("spec/spec_helper.lua")
local Screens, Mocks = H.Screens, H.Mocks

---collapse groups to { key = { uuid, ... } } for readable assertions
local function shape()
    local out = {}
    for _, group in ipairs(Screens.groups()) do
        local uuids = {}
        for _, screen in ipairs(group.screens) do
            table.insert(uuids, screen:getUUID())
        end
        table.insert(out, { key = group.key, screens = uuids })
    end
    return out
end

describe("screens", function()
    before_each(function() H.reset() end)

    describe("groups", function()
        it("treats a lone display as a group of one keyed by its own uuid", function()
            -- the key property that makes single-monitor state need no
            -- migration: the group key already is the screen uuid
            Mocks.set_screens({ { uuid = "solo", x = 0 } })
            assert.are.same({ { key = "solo", screens = { "solo" } } }, shape())
        end)

        it("joins two flush side-by-side displays into one strip", function()
            Mocks.set_screens({
                { uuid = "left", x = 0, w = 1000 },
                { uuid = "right", x = 1000, w = 1000 },
            })
            assert.are.same({ { key = "left", screens = { "left", "right" } } }, shape())
        end)

        it("orders a group left-to-right regardless of allScreens order", function()
            Mocks.set_screens({
                { uuid = "c", x = 2000, w = 1000 },
                { uuid = "a", x = 0, w = 1000 },
                { uuid = "b", x = 1000, w = 1000 },
            })
            assert.are.same({ { key = "a", screens = { "a", "b", "c" } } }, shape())
        end)

        it("keeps vertically stacked displays as separate strips", function()
            -- a strip has no business flowing through the bezel between a
            -- display and the one above it
            Mocks.set_screens({
                { uuid = "top", x = 0, y = 0, h = 800 },
                { uuid = "bottom", x = 0, y = 800, h = 800 },
            })
            assert.are.same({
                { key = "top", screens = { "top" } },
                { key = "bottom", screens = { "bottom" } },
            }, shape())
        end)

        it("joins an ultrawide and a shorter built-in beside it", function()
            -- the actual setup this feature exists for: mismatched heights
            -- still read as one strip because the overlap threshold is a
            -- share of the SHORTER display's height
            Mocks.set_screens({
                { uuid = "ultrawide", x = 0, w = 3440, h = 1440 },
                { uuid = "builtin", x = 3440, w = 1512, h = 982, y = 458 },
            })
            assert.are.same(
                { { key = "ultrawide", screens = { "ultrawide", "builtin" } } }, shape())
        end)

        it("separates displays with a gap between them", function()
            Mocks.set_screens({
                { uuid = "left", x = 0, w = 1000 },
                { uuid = "right", x = 1100, w = 1000 },
            })
            assert.are.same({
                { key = "left", screens = { "left" } },
                { key = "right", screens = { "right" } },
            }, shape())
        end)

        it("separates displays that only clip each other's corner", function()
            -- flush in x but overlapping for only 100 of the shorter
            -- display's 800pt height: a strip flowing across would mostly
            -- disappear into the bezel
            Mocks.set_screens({
                { uuid = "left", x = 0, y = 0, h = 800 },
                { uuid = "right", x = 1000, y = 700, h = 800 },
            })
            assert.are.same({
                { key = "left", screens = { "left" } },
                { key = "right", screens = { "right" } },
            }, shape())
        end)

        it("ignores a side-pinned Dock when judging adjacency", function()
            -- dock_left insets frame() but not fullFrame(); adjacency is
            -- judged on fullFrame() precisely so this stays one strip
            Mocks.set_screens({
                { uuid = "left", x = 0, w = 1000 },
                { uuid = "right", x = 1000, w = 1000, dock_left = 80 },
            })
            assert.are.same({ { key = "left", screens = { "left", "right" } } }, shape())
        end)

        it("gives a display at most one right-hand neighbour", function()
            -- two stacked displays both abut `tall`'s right edge, but a
            -- strip is one-dimensional: only the best-overlapping one
            -- continues it, the other becomes its own group rather than
            -- making column order ambiguous
            Mocks.set_screens({
                { uuid = "tall", x = 0, w = 1000, y = 0, h = 800 },
                { uuid = "upper", x = 1000, w = 1000, y = 0, h = 400 },
                { uuid = "lower", x = 1000, w = 1000, y = 400, h = 400 },
            })
            assert.are.same({
                { key = "tall", screens = { "tall", "upper" } },
                { key = "lower", screens = { "lower" } },
            }, shape())
        end)

        it("gives a display at most one left-hand neighbour", function()
            -- mirror case: two stacked displays both abut `tall`'s left
            -- edge. `big` overlaps it more (500 vs 300), so it wins the
            -- claim deterministically whichever order allScreens reports.
            Mocks.set_screens({
                { uuid = "small", x = 0, w = 1000, y = 500, h = 300 },
                { uuid = "big", x = 0, w = 1000, y = 0, h = 500 },
                { uuid = "tall", x = 1000, w = 1000, y = 0, h = 800 },
            })
            assert.are.same({
                { key = "big", screens = { "big", "tall" } },
                { key = "small", screens = { "small" } },
            }, shape())
        end)

        it("returns nothing when no display is connected", function()
            Mocks.set_screens({})
            assert.are.same({}, shape())
        end)
    end)

    describe("groupFor", function()
        it("finds the group containing a given display", function()
            Mocks.set_screens({
                { uuid = "left", x = 0, w = 1000 },
                { uuid = "right", x = 1000, w = 1000 },
                { uuid = "other", x = 0, y = 900, h = 800 },
            })
            assert.are.equal("left", Screens.groupFor("right").key)
            assert.are.equal("other", Screens.groupFor("other").key)
        end)

        it("returns nil for a display that isn't connected", function()
            Mocks.set_screens({ { uuid = "left", x = 0 } })
            assert.is_nil(Screens.groupFor("unplugged"))
        end)
    end)
end)
