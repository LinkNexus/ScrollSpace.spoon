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
---or the window's title matches rule.title as a Lua pattern). No match
---falls back to current_workspace.
---@param window Window
---@return number workspace
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

    return Rules.ScrollSpace.state.current_workspace
end

return Rules
