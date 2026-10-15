if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_ZoneCompatibility"
require "SacrificialOffering/SO_Storage"
require "SacrificialOffering/SO_FixtureService"

local SO = SacrificialOffering
SO.ZoneService = SO.ZoneService or {}
local Zones = SO.ZoneService

local function publicZone(zone)
    return {
        id = zone.id,
        name = zone.name,
        x1 = zone.x1,
        y1 = zone.y1,
        x2 = zone.x2,
        y2 = zone.y2,
        z = zone.z or 0,
        fixtures = SO.Util.DeepCopy(zone.fixtures),
        pendingFixtures = zone.pendingFixtures == true,
    }
end

function Zones.GetPublicZones()
    local result = {}
    for _, zone in ipairs(SO.Storage.Get().zones) do table.insert(result, publicZone(zone)) end
    return result
end

function Zones.SendResult(player, resultType, translation, fields)
    local args = SO.Util.ShallowCopy(fields)
    args.type = resultType
    args.translation = translation
    if isServer() then
        sendServerCommand(player, SO.MODULE, SO.SERVER_COMMAND.RESULT, args)
    elseif SO.Client and SO.Client.HandleResult then
        SO.Client.HandleResult(args)
    end
end

function Zones.Sync(player)
    local args = { zones = Zones.GetPublicZones(), schemaVersion = SO.SCHEMA_VERSION }
    if isServer() then
        if player then
            sendServerCommand(player, SO.MODULE, SO.SERVER_COMMAND.SYNC_ZONES, args)
        else
            sendServerCommand(SO.MODULE, SO.SERVER_COMMAND.SYNC_ZONES, args)
        end
    elseif SO.Client and SO.Client.HandleZoneSync then
        SO.Client.HandleZoneSync(args)
    end
end

function Zones.IsAuthorized(player)
    if not player then return false end
    if not isServer() then return true end
    local role = player:getRole()
    if not role then return false end
    return role:hasCapability(Capability.CanSetupNonPVPZone) or role:hasCapability(Capability.CanSetupSafehouses)
end

local function rectFromSafehouse(safehouse)
    if not safehouse then return nil end
    local x1, y1 = safehouse:getX(), safehouse:getY()
    local x2 = safehouse.getX2 and safehouse:getX2() or x1 + safehouse:getW()
    local y2 = safehouse.getY2 and safehouse:getY2() or y1 + safehouse:getH()
    return SO.Util.NormalizeRect(x1, y1, x2, y2)
end

function Zones.IntersectsTemple(rect, ignoreZoneId)
    for _, zone in ipairs(SO.Storage.Get().zones) do
        if tonumber(zone.id) ~= tonumber(ignoreZoneId) and SO.Util.RectsIntersect(rect, zone) then return true end
    end
    return false
end

SO.ZoneCompatibility.SetTempleProvider(Zones.IntersectsTemple)

-- A temple may not be drawn over another temple, a player Safehouse, or an
-- opted-in third-party managed zone. It deliberately DOES coexist with vanilla
-- Non-PVP zones, and never removes or modifies any zone it overlaps.
function Zones.CheckManagedOverlap(rect, ignoreZoneId)
    if Zones.IntersectsTemple(rect, ignoreZoneId) then return true, "SatanicTemple" end

    if SafeHouse and SafeHouse.getSafehouseList then
        local list = SafeHouse.getSafehouseList()
        for index = 0, list:size() - 1 do
            if SO.Util.RectsIntersect(rect, rectFromSafehouse(list:get(index))) then return true, "SafeHouse" end
        end
    end

    local overlap, provider = SO.ZoneCompatibility.CheckExternalOverlap(rect)
    if overlap then return true, provider end
    return false, nil
end

function Zones.ValidateRect(rect, ignoreZoneId)
    if not rect then return false, "coordinates" end
    local width, height = rect.x2 - rect.x1, rect.y2 - rect.y1
    local minimum, maximum = SO.Sandbox.ZoneSizeRange()
    if width < minimum or height < minimum then return false, "minimum-size" end
    if width > maximum or height > maximum then return false, "maximum-size" end
    if math.abs(rect.x1) > 10000000 or math.abs(rect.y1) > 10000000 or
        math.abs(rect.x2) > 10000000 or math.abs(rect.y2) > 10000000 then return false, "coordinates" end
    local overlap, provider = Zones.CheckManagedOverlap(rect, ignoreZoneId)
    if overlap then return false, "overlap:" .. tostring(provider) end
    return true, nil
end

function Zones.Create(player, args)
    local tx = args and args.tx or SO.Util.NewTransactionId("zone-create", player)
    local run = SO.Logger.BeginRun("zone-create", tx, { player = SO.PlayerLedger and SO.PlayerLedger.GetIdentity(player) })
    if not Zones.IsAuthorized(player) then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.NOT_AUTHORIZED, { tx = tx })
        SO.Logger.EndRun(run, "denied")
        return false
    end
    local rect = SO.Util.NormalizeRect(args and args.x1, args and args.y1, args and args.x2, args and args.y2)
    local valid, reason = Zones.ValidateRect(rect)
    SO.Logger.Step(run, "validated", { valid = tostring(valid), reason = reason })
    if not valid then
        local translation = reason and reason:sub(1, 8) == "overlap:" and SO.TRANSLATION.ZONE_OVERLAP or SO.TRANSLATION.ZONE_INVALID
        Zones.SendResult(player, SO.RESULT.ERROR, translation, { tx = tx, reason = reason })
        SO.Logger.EndRun(run, "rejected", { reason = reason })
        return false
    end

    local root = SO.Storage.Get()
    local id = SO.Storage.NextZoneId()
    local zone = {
        id = id,
        name = SO.Util.SanitizeName(args and args.name, "Satanic Temple " .. tostring(id)),
        x1 = rect.x1,
        y1 = rect.y1,
        x2 = rect.x2,
        y2 = rect.y2,
        z = 0,
        fixtures = nil,
        pendingFixtures = true,
        createdBy = SO.PlayerLedger and SO.PlayerLedger.GetIdentity(player) or "unknown",
        createdAt = SO.Util.NowMs(),
    }
    table.insert(root.zones, zone)
    -- Fixture placement must never abort zone creation: an unplaceable altar or a
    -- streaming square should leave the temple registered and "pending", not
    -- swallow the sync that tells every client the temple now exists.
    local ok, complete, fixtureReason = pcall(SO.Fixtures.Provision, zone)
    if not ok then
        zone.pendingFixtures = true
        SO.Logger.Error("Fixture provisioning raised during zone creation", { zoneId = id, error = tostring(complete) })
        complete, fixtureReason = false, "error"
    end
    SO.Logger.Step(run, "fixtures", { complete = tostring(complete), reason = fixtureReason })
    Zones.Sync()
    Zones.SendResult(player, SO.RESULT.INFO, "IGUI_SO_ZoneCreated", { tx = tx, zoneId = id })
    SO.Logger.EndRun(run, "created", { zoneId = id, pending = tostring(not complete) })
    return true
end

function Zones.Resize(player, args)
    local tx = args and args.tx or SO.Util.NewTransactionId("zone-resize", player)
    local run = SO.Logger.BeginRun("zone-resize", tx)
    if not Zones.IsAuthorized(player) then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.NOT_AUTHORIZED, { tx = tx })
        SO.Logger.EndRun(run, "denied")
        return false
    end
    local zone = SO.Storage.FindZone(args and args.zoneId)
    local rect = SO.Util.NormalizeRect(args and args.x1, args and args.y1, args and args.x2, args and args.y2)
    local valid, reason = false, "missing-zone"
    if zone then valid, reason = Zones.ValidateRect(rect, zone.id) end
    if not valid then
        local translation = reason and reason:sub(1, 8) == "overlap:" and SO.TRANSLATION.ZONE_OVERLAP or SO.TRANSLATION.ZONE_INVALID
        Zones.SendResult(player, SO.RESULT.ERROR, translation, { tx = tx, reason = reason })
        SO.Logger.EndRun(run, "rejected", { reason = reason })
        return false
    end
    if zone.fixtures then
        local oldFixtures = SO.Util.DeepCopy(zone.fixtures)
        if not SO.Fixtures.Remove(zone) then SO.Storage.AddFixtureTombstone(oldFixtures) end
    end
    zone.x1, zone.y1, zone.x2, zone.y2 = rect.x1, rect.y1, rect.x2, rect.y2
    zone.fixtures = nil
    zone.pendingFixtures = true
    local ok, err = pcall(SO.Fixtures.Provision, zone)
    if not ok then
        zone.pendingFixtures = true
        SO.Logger.Error("Fixture provisioning raised during zone resize", { zoneId = zone.id, error = tostring(err) })
    end
    Zones.Sync()
    Zones.SendResult(player, SO.RESULT.INFO, "IGUI_SO_ZoneResized", { tx = tx, zoneId = zone.id })
    SO.Logger.EndRun(run, "resized", { zoneId = zone.id })
    return true
end

function Zones.Rename(player, args)
    local tx = args and args.tx or SO.Util.NewTransactionId("zone-rename", player)
    if not Zones.IsAuthorized(player) then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.NOT_AUTHORIZED, { tx = tx })
        return false
    end
    local zone = SO.Storage.FindZone(args and args.zoneId)
    if not zone then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.ZONE_INVALID, { tx = tx })
        return false
    end
    zone.name = SO.Util.SanitizeName(args and args.name, zone.name)
    Zones.Sync()
    Zones.SendResult(player, SO.RESULT.INFO, "IGUI_SO_ZoneRenamed", { tx = tx, zoneId = zone.id })
    return true
end

function Zones.Delete(player, args)
    local tx = args and args.tx or SO.Util.NewTransactionId("zone-delete", player)
    local run = SO.Logger.BeginRun("zone-delete", tx)
    if not Zones.IsAuthorized(player) then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.NOT_AUTHORIZED, { tx = tx })
        SO.Logger.EndRun(run, "denied")
        return false
    end
    local zone, index = SO.Storage.FindZone(args and args.zoneId)
    if not zone then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.ZONE_INVALID, { tx = tx })
        SO.Logger.EndRun(run, "missing")
        return false
    end
    if zone.fixtures then
        local oldFixtures = SO.Util.DeepCopy(zone.fixtures)
        if not SO.Fixtures.Remove(zone) then SO.Storage.AddFixtureTombstone(oldFixtures) end
    end
    table.remove(SO.Storage.Get().zones, index)
    Zones.Sync()
    Zones.SendResult(player, SO.RESULT.INFO, "IGUI_SO_ZoneDeleted", { tx = tx })
    SO.Logger.EndRun(run, "deleted", { zoneId = zone.id })
    return true
end

-- Remove every temple's fixtures and zone record in one pass. `wipeData` also
-- clears the per-account recovery ledgers and drops the persisted mod data
-- entirely -- the pre-uninstall path. `player` may be nil for a server-console
-- call; when present they must be authorized.
function Zones.PurgeAll(player, wipeData)
    local tx = SO.Util.NewTransactionId("zone-purge", player)
    local run = SO.Logger.BeginRun("zone-purge", tx)
    if player and not Zones.IsAuthorized(player) then
        Zones.SendResult(player, SO.RESULT.ERROR, SO.TRANSLATION.NOT_AUTHORIZED, { tx = tx })
        SO.Logger.EndRun(run, "denied")
        return false
    end

    local root = SO.Storage.Get()
    local zoneCount = #root.zones
    for _, zone in ipairs(root.zones) do
        if zone.fixtures then
            local oldFixtures = SO.Util.DeepCopy(zone.fixtures)
            if not SO.Fixtures.Remove(zone) then SO.Storage.AddFixtureTombstone(oldFixtures) end
        end
    end
    root.zones = {}
    -- Chase any fixture whose square was not loaded during Remove.
    pcall(SO.Fixtures.CleanupTombstones)
    Zones.Sync()
    if player then
        Zones.SendResult(player, SO.RESULT.INFO, "IGUI_SO_TemplesPurged", { tx = tx, count = zoneCount })
    end

    -- Do the data wipe last so nothing re-materializes the root this frame.
    if wipeData and SO.Storage.Wipe then
        SO.Storage.Wipe()
    end
    SO.Logger.EndRun(run, "purged", { zones = zoneCount, wipedData = tostring(wipeData == true) })
    return true
end

function Zones.ProvisionAndRepair()
    local changed = false
    -- Remove deferred fixtures before provisioning, so a resized zone can safely
    -- reuse a coordinate in the same integrity pass.
    pcall(SO.Fixtures.CleanupTombstones)
    for _, zone in ipairs(SO.Storage.Get().zones) do
        local hadLayout = zone.fixtures ~= nil
        local hadLanterns = hadLayout and zone.fixtures.lanterns ~= nil
        local wasPending = zone.pendingFixtures == true
        -- One temple whose square is unavailable (or whose altar raises) must not
        -- stop the pass from repairing the others or from syncing.
        local ok, complete = pcall(SO.Fixtures.Provision, zone)
        if not ok then
            SO.Logger.Error("Fixture integrity pass raised for temple", { zoneId = zone.id, error = tostring(complete) })
            complete = false
        end
        if hadLayout ~= (zone.fixtures ~= nil) or wasPending ~= (not complete) then changed = true end
        -- Temples built before jack-o'-lanterns gain their positions here; sync
        -- so clients can light them.
        if not hadLanterns and zone.fixtures and zone.fixtures.lanterns then changed = true end
    end
    if changed then Zones.Sync() end
    SO.Logger.Trace("Temple fixture integrity pass", { zones = #SO.Storage.Get().zones })
end

Events.EveryOneMinute.Add(Zones.ProvisionAndRepair)

return Zones
