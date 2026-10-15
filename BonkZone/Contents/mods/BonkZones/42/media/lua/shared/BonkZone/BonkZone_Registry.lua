require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"

BonkZone = BonkZone or {}
BonkZone.Registry = BonkZone.Registry or {}

local Registry = BonkZone.Registry
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger

Registry.Zones = Registry.Zones or {}
Registry.ById = Registry.ById or {}
Registry.Revision = Registry.Revision or 0
Registry.Ready = Registry.Ready or false

local function copyZone(zone)
    return {
        id = tostring(zone.id or ""),
        name = Constants.NormalizeName(zone.name),
        x1 = math.floor(tonumber(zone.x1) or 0),
        y1 = math.floor(tonumber(zone.y1) or 0),
        x2 = math.ceil(tonumber(zone.x2) or 0),
        y2 = math.ceil(tonumber(zone.y2) or 0),
        z1 = math.floor(tonumber(zone.z1) or Constants.ALL_FLOORS_MIN),
        z2 = math.ceil(tonumber(zone.z2) or Constants.ALL_FLOORS_MAX),
        createdBy = tostring(zone.createdBy or ""),
        createdAt = tonumber(zone.createdAt) or 0,
        updatedAt = tonumber(zone.updatedAt) or 0,
    }
end

function Registry.ReplaceAll(zones, revision)
    local startedAt = Logger.Begin("Registry.ReplaceAll", { revision = revision })
    Registry.Zones = {}
    Registry.ById = {}
    if type(zones) == "table" then
        for _, rawZone in ipairs(zones) do
            if type(rawZone) == "table" and rawZone.id ~= nil and Constants.IsBoundsValid(rawZone.x1, rawZone.y1, rawZone.x2, rawZone.y2) then
                local zone = copyZone(rawZone)
                Registry.Zones[#Registry.Zones + 1] = zone
                Registry.ById[zone.id] = zone
            end
        end
    end
    table.sort(Registry.Zones, function(a, b)
        local an = string.lower(a.name or "")
        local bn = string.lower(b.name or "")
        if an == bn then return a.id < b.id end
        return an < bn
    end)
    Registry.Revision = tonumber(revision) or (Registry.Revision + 1)
    Registry.Ready = true
    Logger.Info("Registry", "zone cache replaced", { count = #Registry.Zones, revision = Registry.Revision })
    Logger.Finish("Registry.ReplaceAll", startedAt, true)
end

function Registry.GetZones()
    Logger.RateLimited("TRACE", "Registry.GetZones", 5000, "Registry.GetZones", "read", { count = #Registry.Zones })
    return Registry.Zones
end

function Registry.GetById(id)
    local zone = Registry.ById[tostring(id or "")]
    Logger.Trace("Registry.GetById", "lookup", { id = id, found = zone ~= nil })
    return zone
end

function Registry.PointInZone(zone, x, y, z)
    if not zone then
        Logger.Trace("Registry.PointInZone", "missing zone")
        return false
    end
    local px = tonumber(x)
    local py = tonumber(y)
    local pz = tonumber(z) or 0
    if not px or not py then
        Logger.Trace("Registry.PointInZone", "invalid point")
        return false
    end
    local inside = px >= zone.x1 and px < zone.x2 and py >= zone.y1 and py < zone.y2 and pz >= zone.z1 and pz <= zone.z2
    Logger.RateLimited("TRACE", "Registry.PointInZone." .. zone.id, 5000, "Registry.PointInZone", "checked", { id = zone.id, inside = inside })
    return inside
end

function Registry.GetZonesAt(x, y, z)
    local result = {}
    for _, zone in ipairs(Registry.Zones) do
        if Registry.PointInZone(zone, x, y, z) then result[#result + 1] = zone end
    end
    Logger.RateLimited("TRACE", "Registry.GetZonesAt", 2000, "Registry.GetZonesAt", "checked", { count = #result })
    return result
end

function Registry.IsInside(x, y, z)
    for _, zone in ipairs(Registry.Zones) do
        if Registry.PointInZone(zone, x, y, z) then
            Logger.RateLimited("TRACE", "Registry.IsInside.true", 2000, "Registry.IsInside", "inside", { id = zone.id })
            return true, zone
        end
    end
    Logger.RateLimited("TRACE", "Registry.IsInside.false", 5000, "Registry.IsInside", "outside")
    return false, nil
end

function Registry.IsCharacterInside(character)
    if not character then
        Logger.Trace("Registry.IsCharacterInside", "missing character")
        return false, nil
    end
    return Registry.IsInside(character:getX(), character:getY(), character:getZ())
end

function Registry.ShouldBlockRangedPvp(attacker, target)
    local startedAt = Logger.Begin("Registry.ShouldBlockRangedPvp")
    if not Constants.IsPlayerObject(attacker) or not Constants.IsPlayerObject(target) then
        Logger.Finish("Registry.ShouldBlockRangedPvp", startedAt, true, "non-player participant")
        return false, nil
    end
    local targetInside, targetZone = Registry.IsCharacterInside(target)
    local blocked = targetInside
    local zone = targetZone
    Logger.Finish("Registry.ShouldBlockRangedPvp", startedAt, true, { blocked = blocked, zone = zone and zone.id or "" })
    return blocked, zone
end

return Registry
