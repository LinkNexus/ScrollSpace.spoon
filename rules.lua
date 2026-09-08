local Rules = {}
Rules.__index = Rules

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Rules.init(scrollspace)
    Rules.ScrollSpace = scrollspace
end

---find the workspace a window should be assigned to, by walking
---ScrollSpace.rules in order. First matching rule wins. A rule matches
---when the window's app name equals rule.app and (rule.title is absent
---or the window's title matches rule.title as a Lua pattern).
---
---Returns nil when nothing matched, rather than defaulting to
---current_workspace here. The fallback belongs to the caller because the
---two callers need different behaviour: a brand new window with no rule
---does belong on whatever workspace is active (windows.addWindow applies
---that), but a window whose *title* merely changed must be left exactly
---where it is -- folding the fallback in here made every retitle of an
---already-tracked window (a browser switching tabs, a shell changing
---directory) look like a match for the active workspace and drag the
---window out of the workspace it was living on.
---@param window Window
---@return number|nil workspace, or nil if no rule matched
function Rules.assign(window)
    local app = window:application()
    local app_name = app and app:name() or nil
    local title = window:title() or ""

    for _, rule in ipairs(Rules.ScrollSpace.rules) do
        if app_name == rule.app then
            if not rule.title or title:match(rule.title) then
                return rule.workspace
            end
        end
    end

    return nil
end

return Rules
