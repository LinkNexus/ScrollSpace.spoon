-- Screen topology: which connected displays form a single continuous
-- horizontal strip, and in what left-to-right order.
--
-- A workspace used to tile one independent column strip per display
-- (window_list[workspace][screen_uuid]). That's right for displays
-- stacked vertically -- a strip has no business flowing through the
-- bezel between a screen and the one above it -- but wrong for displays
-- arranged side by side, where the natural reading is that the strip
-- simply continues onto the next display. This module decides which of
-- those two cases a given arrangement is in; tiling.lua consumes the
-- answer.
--
-- Adjacency is judged on fullFrame(), not frame(). frame() is the
-- *usable* area (menu bar and Dock excluded), so a Dock pinned to the
-- left or right edge insets it and two physically abutting displays
-- would no longer look adjacent. fullFrame() is the physical geometry,
-- which is what topology questions are about. frame() is still the right
-- thing for the tiling canvas -- that genuinely is about usable area.

local Screens = {}
Screens.__index = Screens

---initialize module with reference to ScrollSpace
---@param scrollspace ScrollSpace
function Screens.init(scrollspace)
    Screens.ScrollSpace = scrollspace
end

---points of slop allowed when deciding two display edges touch. macOS's
---Displays > Arrangement snaps displays flush, so this only absorbs
---rounding on fractional-scale modes rather than any real gap.
local TOLERANCE <const> = 2

---a strip flowing from one display to the next only makes sense if the
---two actually line up vertically for most of their height -- a display
---that merely clips a corner of its neighbour would have the strip
---vanish into the bezel. Expressed as a share of the *shorter*
---display's height so a short display abutting a tall one (a built-in
---next to an ultrawide) still counts as continuing the strip.
local MIN_VERTICAL_OVERLAP <const> = 0.5

---@param screen userdata hs.screen
---@return table fullFrame rect
local function geometry(screen)
    return screen:fullFrame()
end

---vertical overlap of two displays, in points (negative when disjoint)
---@param a userdata hs.screen
---@param b userdata hs.screen
---@return number
local function vertical_overlap(a, b)
    local af, bf = geometry(a), geometry(b)
    return math.min(af.y2, bf.y2) - math.max(af.y, bf.y)
end

---whether b sits immediately to the right of a, closely enough aligned
---for a column strip to flow across the boundary
---@param a userdata hs.screen
---@param b userdata hs.screen
---@return boolean
function Screens.isRightOf(a, b)
    local af, bf = geometry(a), geometry(b)
    if math.abs(af.x2 - bf.x) > TOLERANCE then return false end

    local overlap = vertical_overlap(a, b)
    if overlap <= 0 then return false end

    local shorter = math.min(af.h, bf.h)
    if shorter <= 0 then return false end
    return (overlap / shorter) >= MIN_VERTICAL_OVERLAP
end

---whether two displays are horizontally adjacent in either order
---@param a userdata hs.screen
---@param b userdata hs.screen
---@return boolean
function Screens.adjacent(a, b)
    return Screens.isRightOf(a, b) or Screens.isRightOf(b, a)
end

---pick the best continuation of the strip to the right of `from` among
---`candidates`: the one overlapping it most vertically, breaking ties
---toward the topmost. Returns nil when nothing abuts it.
---
---A strip is one-dimensional, so each display can have at most one
---right-hand neighbour. That matters for arrangements where two
---vertically stacked displays both abut a third one's right edge: only
---one of them can continue the strip, and the other becomes its own
---group rather than silently joining and making column order ambiguous.
---@param from userdata hs.screen
---@param candidates userdata[] hs.screen
---@return userdata|nil
local function best_right_neighbour(from, candidates)
    local best, best_overlap
    for _, candidate in ipairs(candidates) do
        if candidate ~= from and Screens.isRightOf(from, candidate) then
            local overlap = vertical_overlap(from, candidate)
            local better = best == nil
                or overlap > best_overlap
                or (overlap == best_overlap and geometry(candidate).y < geometry(best).y)
            if better then
                best, best_overlap = candidate, overlap
            end
        end
    end
    return best
end

---partition the connected displays into strip groups: maximal
---left-to-right chains of horizontally adjacent displays. A lone display
---is a group of one, so callers can treat every arrangement uniformly.
---
---The group's key is its leftmost display's UUID. For a single display
---that is just its own UUID, which means a single-monitor setup's
---persisted window_list needs no migration at all -- its existing
---screen-UUID bucket already is the group bucket.
---@param screens userdata[]|nil defaults to hs.screen.allScreens()
---@return { key: string, screens: userdata[] }[] groups, ordered by their
---leftmost display (x, then y, then uuid -- a total order, so group order
---is fully determined by the arrangement)
function Screens.groups(screens)
    screens = screens or hs.screen.allScreens()
    if #screens == 0 then return {} end

    -- a total order, not just by x: two displays stacked at the same x
    -- would otherwise sort unstably and emit groups in a different order
    -- run to run. Ties break top-to-bottom, then by uuid so the result is
    -- fully determined by the arrangement.
    local sorted = {}
    for _, screen in ipairs(screens) do table.insert(sorted, screen) end
    table.sort(sorted, function(a, b)
        local af, bf = geometry(a), geometry(b)
        if af.x ~= bf.x then return af.x < bf.x end
        if af.y ~= bf.y then return af.y < bf.y end
        return a:getUUID() < b:getUUID()
    end)

    -- link each display to its single best right-hand neighbour, keeping
    -- only mutual pairs: `from` must be the best *left*-hand match of the
    -- neighbour it picked, or the link is dropped. Without that check two
    -- stacked displays could both claim the same left neighbour and end
    -- up in one chain.
    local right_of, claimed = {}, {}
    for _, screen in ipairs(sorted) do
        local neighbour = best_right_neighbour(screen, sorted)
        if neighbour then
            local rival = claimed[neighbour]
            if rival == nil then
                right_of[screen], claimed[neighbour] = neighbour, screen
            elseif vertical_overlap(screen, neighbour) > vertical_overlap(rival, neighbour) then
                right_of[rival] = nil
                right_of[screen], claimed[neighbour] = neighbour, screen
            end
        end
    end

    local groups = {}
    for _, screen in ipairs(sorted) do
        if not claimed[screen] then -- a chain head: nothing abuts its left edge
            local chain, cursor = {}, screen
            while cursor do
                table.insert(chain, cursor)
                cursor = right_of[cursor]
            end
            table.insert(groups, { key = chain[1]:getUUID(), screens = chain })
        end
    end
    return groups
end

---the strip group containing a given display
---@param uuid string hs.screen:getUUID()
---@param screens userdata[]|nil defaults to hs.screen.allScreens()
---@return { key: string, screens: userdata[] }|nil
function Screens.groupFor(uuid, screens)
    for _, group in ipairs(Screens.groups(screens)) do
        for _, screen in ipairs(group.screens) do
            if screen:getUUID() == uuid then return group end
        end
    end
    return nil
end

return Screens
