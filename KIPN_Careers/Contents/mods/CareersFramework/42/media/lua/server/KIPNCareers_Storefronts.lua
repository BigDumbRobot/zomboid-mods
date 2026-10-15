require "KIPNCareers_Shared"
require "KIPNCareers_ZoneBridge"

-- KIPNCareers_Storefronts
--
-- Cross-career storefront registry. Each career registers a provider that
-- returns its own storefront records, so a new shop in any career is checked
-- against every installed career's shops without careers reading each other's
-- data slices. A career that isn't installed simply never registers.
--
--   KIPNCareers.Storefronts.Register("mechanic", function()
--       local data = state()
--       return data and data.shops    -- { [id] = { bounds = rect, active = bool, ownerKey = }, ... }
--   end)
--
-- A career registered through KIPNCareers.Careers.Register is registered here
-- for it. rect / bounds = { x1, y1, x2, y2 } in world tiles.
--
-- On top of the registry:
--   * CheckSite runs everything a new storefront must pass, in one call;
--   * At / ForOwner find a storefront in any career by place or by owner.

local Shared = KIPNCareers.Shared
local ZoneBridge = KIPNCareers.ZoneBridge
local Storefronts = KIPNCareers.Storefronts or {}
KIPNCareers.Storefronts = Storefronts
Storefronts._providers = Storefronts._providers or {}

local function log(level, message)
    Shared.Log("Storefronts", level, message)
end

function Storefronts.RectanglesOverlap(a, b)
    return math.max(a.x1, b.x1) <= math.min(a.x2, b.x2)
        and math.max(a.y1, b.y1) <= math.min(a.y2, b.y2)
end

function Storefronts.Contains(bounds, x, y, z)
    if type(bounds) ~= "table" then return false end
    return x >= bounds.x1 and x <= bounds.x2 and y >= bounds.y1 and y <= bounds.y2
        and (z == nil or (z >= (bounds.z1 or 0) and z <= (bounds.z2 or 8)))
end

-- Re-registering the same careerId replaces its provider (safe on Lua reload).
function Storefronts.Register(careerId, provider)
    if type(careerId) ~= "string" or careerId == "" or type(provider) ~= "function" then
        log("Error", "Register ignored: careerId and provider function are required")
        return false
    end
    Storefronts._providers[careerId] = provider
    log("Info", "Registered storefront provider career=" .. careerId)
    return true
end

-- Returns overlaps, careerId, storefrontId. `ignoreCareerId` + `ignoreId`
-- skip one record (e.g. a shop being re-drawn over its own building). A
-- provider that errors fails closed, so a broken career can't let shops stack.
function Storefronts.Overlaps(rect, ignoreCareerId, ignoreId)
    for careerId, provider in pairs(Storefronts._providers) do
        local ok, records = pcall(provider)
        if not ok then
            log("Error", "Provider failed career=" .. careerId .. " error=" .. tostring(records))
            return true, careerId, nil
        end
        for id, record in pairs(type(records) == "table" and records or {}) do
            local ignored = careerId == ignoreCareerId and id == ignoreId
            if not ignored and type(record) == "table" and record.active ~= false and record.bounds
                and Storefronts.RectanglesOverlap(rect, record.bounds)
            then
                return true, careerId, id
            end
        end
    end
    return false, nil, nil
end

------------------------------------------------------------
-- LOOKUP
------------------------------------------------------------

-- Calls visit(careerId, id, record) for every open storefront in every
-- career until it returns true. A provider that errors is skipped: a lookup
-- has nothing to protect by failing closed.
local function eachOpen(visit)
    for careerId, provider in pairs(Storefronts._providers) do
        local ok, records = pcall(provider)
        if ok and type(records) == "table" then
            for id, record in pairs(records) do
                if type(record) == "table" and record.active ~= false and visit(careerId, id, record) then return end
            end
        end
    end
end

-- The open storefront whose building contains this tile: careerId, id, record.
function Storefronts.At(x, y, z)
    local foundCareer, foundId, foundRecord
    eachOpen(function(careerId, id, record)
        if Storefronts.Contains(record.bounds, x, y, z) then
            foundCareer, foundId, foundRecord = careerId, id, record
            return true
        end
    end)
    return foundCareer, foundId, foundRecord
end

-- Every open storefront this owner runs, in any career:
-- { { careerId = , id = , record = }, ... }
function Storefronts.ForOwner(ownerKey)
    local found = {}
    if not ownerKey then return found end
    eachOpen(function(careerId, id, record)
        if record.ownerKey == ownerKey then found[#found + 1] = { careerId = careerId, id = id, record = record } end
    end)
    return found
end

------------------------------------------------------------
-- OPENING A STOREFRONT
------------------------------------------------------------

-- The bounds of the building the player stands in, or nil and a reason.
function Storefronts.BuildingRectangle(player)
    local square = player and player:getSquare()
    local building = square and square:getBuilding()
    if not building then return nil, "PLAYER_NOT_IN_BUILDING" end
    local def = type(building.getDef) == "function" and building:getDef() or nil
    if not def then return nil, "BUILDING_DEFINITION_UNAVAILABLE" end
    local function read(method, field)
        if type(def[method]) == "function" then
            local ok, value = pcall(def[method], def)
            if ok then return tonumber(value) end
        end
        return tonumber(def[field])
    end
    local x1, y1 = read("getX", "x"), read("getY", "y")
    local x2, y2 = read("getX2", "x2"), read("getY2", "y2")
    if not x1 or not y1 or not x2 or not y2 then return nil, "BUILDING_BOUNDS_UNAVAILABLE" end
    return {
        x1 = math.min(x1, x2), y1 = math.min(y1, y2),
        x2 = math.max(x1, x2), y2 = math.max(y1, y2), z1 = 0, z2 = 8,
    }
end

-- True when the building is someone else's safehouse -- or anyone's, with
-- the BlockAnySafehouseStorefront sandbox option on.
function Storefronts.SafehouseBlocked(rect, player)
    if not SafeHouse or type(SafeHouse.getSafehouseList) ~= "function" then return false end
    local list = SafeHouse.getSafehouseList()
    if not list then return false end
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    local username
    do
        local ok, value = pcall(function() return player and player:getUsername() end)
        username = ok and tostring(value or "Unknown") or "Unknown"
    end
    for index = 0, list:size() - 1 do
        local safehouse = list:get(index)
        local ok, bounds = pcall(function()
            return { x1 = safehouse:getX(), y1 = safehouse:getY(), x2 = safehouse:getX() + safehouse:getW(), y2 = safehouse:getY() + safehouse:getH() }
        end)
        if ok and bounds and Storefronts.RectanglesOverlap(rect, bounds) then
            if raw.BlockAnySafehouseStorefront == true then return true end
            local owns = false
            if type(safehouse.isOwner) == "function" then
                local o, v = pcall(safehouse.isOwner, safehouse, player)
                owns = o and v == true
            end
            if not owns and type(safehouse.getOwner) == "function" then
                local o, v = pcall(safehouse.getOwner, safehouse)
                owns = o and tostring(v or "") == username
            end
            if not owns then return true end
        end
    end
    return false
end

-- Everything a new storefront has to pass, in order: the player is in a
-- building, it is clear of No Claim zones, no career has a storefront there,
-- and it is not another player's safehouse. Returns the building rectangle,
-- or nil and one of:
--   PLAYER_NOT_IN_BUILDING, BUILDING_DEFINITION_UNAVAILABLE,
--   BUILDING_BOUNDS_UNAVAILABLE, NO_CLAIM_ZONE, STOREFRONT_OCCUPIED,
--   SAFEHOUSE_OWNERSHIP_REQUIRED
-- `ignoreCareerId` + `ignoreId` skip one record, for moving a storefront.
function Storefronts.CheckSite(player, ignoreCareerId, ignoreId)
    local rect, reason = Storefronts.BuildingRectangle(player)
    if not rect then return nil, reason end
    if ZoneBridge.OverlapsNoClaim(rect) then return nil, "NO_CLAIM_ZONE" end
    if Storefronts.Overlaps(rect, ignoreCareerId, ignoreId) then return nil, "STOREFRONT_OCCUPIED" end
    if Storefronts.SafehouseBlocked(rect, player) then return nil, "SAFEHOUSE_OWNERSHIP_REQUIRED" end
    return rect
end

return Storefronts
