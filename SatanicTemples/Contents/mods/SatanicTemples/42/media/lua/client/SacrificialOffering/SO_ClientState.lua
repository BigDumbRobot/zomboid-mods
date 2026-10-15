require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_ZoneCompatibility"
require "SacrificialOffering/SO_Announce"
require "SacrificialOffering/SO_Sound"

local SO = SacrificialOffering
SO.Client = SO.Client or {}
local Client = SO.Client

Client.Zones = Client.Zones or {}
Client.ZoneRevision = Client.ZoneRevision or 0

function Client.HandleZoneSync(args)
    Client.Zones = type(args and args.zones) == "table" and args.zones or {}
    Client.ZoneRevision = Client.ZoneRevision + 1
    SO.Logger.Debug("Client temple cache synchronized", { zones = #Client.Zones, revision = Client.ZoneRevision })
end

function Client.FindZone(zoneId)
    for _, zone in ipairs(Client.Zones) do
        if tonumber(zone.id) == tonumber(zoneId) then return zone end
    end
    return nil
end

function Client.FindZoneByAltar(x, y, z)
    for _, zone in ipairs(Client.Zones) do
        local altar = zone.fixtures and zone.fixtures.altar
        if altar and altar.x == x and altar.y == y and altar.z == z then return zone end
    end
    return nil
end

function Client.IntersectsTemple(rect, ignoreZoneId)
    for _, zone in ipairs(Client.Zones) do
        if tonumber(zone.id) ~= tonumber(ignoreZoneId) and SO.Util.RectsIntersect(rect, zone) then return true end
    end
    return false
end

SO.ZoneCompatibility.SetTempleProvider(Client.IntersectsTemple)

local function translatedMessage(args)
    local key = args and args.translation
    if not key then return getText("IGUI_SO_InternalError") end
    if key == SO.TRANSLATION.SUCCESS_ITEM or key == SO.TRANSLATION.SUCCESS_CORPSE
        or key == SO.TRANSLATION.SUCCESS_CORPSE_PRIZE then
        local totalStrength = tonumber(args and args.recoveryStrength) or 0
        local addedStrength = tonumber(args and args.recoveryAddedStrength) or totalStrength
        return getText(key, string.format("%.1f", addedStrength), string.format("%.1f", totalStrength))
    end
    return getText(key)
end

function Client.HandleResult(args)
    local player = getPlayer()
    if not player then return end
    if args and args.endsRitual and SO_OfferingRitualAction and SO_OfferingRitualAction.Resolve then
        SO_OfferingRitualAction.Resolve(args.tx)
    end
    SO.Sound.ResolveRitual(args)

    local message = translatedMessage(args)

    local isBad = args and (args.type == SO.RESULT.ERROR or args.type == SO.RESULT.INVALID
        or args.type == SO.RESULT.WRATH or args.type == SO.RESULT.SELF_CORPSE)
    SO.Announce.Show(message, isBad and "bad" or "good")
    if args and args.greedTranslation then
        SO.Announce.Enqueue(getText(args.greedTranslation), "bad")
    end
end

function Client.SendCommand(command, args)
    args = type(args) == "table" and args or {}
    if isClient() then
        sendClientCommand(getPlayer(), SO.MODULE, command, args)
    elseif SO.Server and SO.Server.HandleClientCommand then
        SO.Server.HandleClientCommand(SO.MODULE, command, getPlayer(), args)
    end
end

function Client.RequestZones()
    Client.SendCommand(SO.COMMAND.REQUEST_ZONES, { tx = SO.Util.NewTransactionId("zone-sync", getPlayer()) })
end

function Client.OnServerCommand(module, command, args)
    if module ~= SO.MODULE then return end
    if command == SO.SERVER_COMMAND.SYNC_ZONES then
        Client.HandleZoneSync(args)
    elseif command == SO.SERVER_COMMAND.RESULT then
        Client.HandleResult(args)
    elseif command == SO.SERVER_COMMAND.EFFECT and Client.HandleEffect then
        Client.HandleEffect(args)
    elseif command == SO.SERVER_COMMAND.SOUND_CUE then
        SO.Sound.HandleFirstBeat(args)
    end
end

Events.OnServerCommand.Add(Client.OnServerCommand)

return Client
