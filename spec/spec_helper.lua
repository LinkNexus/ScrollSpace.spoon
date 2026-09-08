---@diagnostic disable
---shared bootstrap for the ScrollSpace specs: loads every module against the
---mock hs namespace and wires them to a stand-in Spoon table, the same way
---init.lua does at runtime.

local Mocks = dofile("spec/mocks.lua")
Mocks.init_mocks()

local H = { Mocks = Mocks }

H.State = dofile("state.lua")
H.Windows = dofile("windows.lua")
H.Workspace = dofile("workspace.lua")
H.Floating = dofile("floating.lua")
H.Tiling = dofile("tiling.lua")
H.Rules = dofile("rules.lua")
H.Scratchpad = dofile("scratchpad.lua")
H.Events = dofile("events.lua")

H.scrollspace = Mocks.get_mock_scrollspace(H)

---reset the mock hs namespace and every module's state between tests
function H.reset()
    Mocks.init_mocks()
    H.State.init(H.scrollspace)
    H.Windows.init(H.scrollspace)
    H.Workspace.init(H.scrollspace)
    H.Floating.init(H.scrollspace)
    H.Tiling.init(H.scrollspace)
    H.Rules.init(H.scrollspace)
    H.Scratchpad.init(H.scrollspace)
    H.Events.init(H.scrollspace)
    H.scrollspace.rules = {}
    H.scrollspace.infinite_loop_window = false
end

return H
