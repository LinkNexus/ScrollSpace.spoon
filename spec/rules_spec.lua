---@diagnostic disable

package.preload["spec_helper"] = function() return dofile("spec/spec_helper.lua") end

describe("ScrollSpace.rules", function()
    local H = require("spec_helper")
    local Rules, State, mock_window = H.Rules, H.State, H.Mocks.mock_window

    before_each(function() H.reset() end)

    describe("assign", function()
        it("matches on app name alone", function()
            H.scrollspace.rules = { { app = "Zen", workspace = 3 } }
            assert.are.equal(3, Rules.assign(mock_window(1, "anything", nil, { app = "Zen" })))
        end)

        it("matches app name plus a title pattern, first rule wins", function()
            H.scrollspace.rules = {
                { app = "kitty", title = "^kitty%.btop$", workspace = 2 },
                { app = "kitty", workspace = 1 },
            }
            assert.are.equal(2, Rules.assign(mock_window(1, "kitty.btop", nil, { app = "kitty" })))
            assert.are.equal(1, Rules.assign(mock_window(2, "kitty.main", nil, { app = "kitty" })))
        end)

        it("returns nil rather than current_workspace when nothing matches", function()
            -- the fallback belongs to the caller: folding it in here made a
            -- retitled window on an inactive workspace look like a match for
            -- whatever workspace happened to be active
            H.scrollspace.rules = { { app = "Zen", workspace = 3 } }
            State.current_workspace = 1
            assert.is_nil(Rules.assign(mock_window(1, "notes", nil, { app = "Terminal" })))
        end)
    end)
end)
