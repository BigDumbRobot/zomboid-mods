if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Logger"

local SO = SacrificialOffering
SO.Storage = SO.Storage or {}
local Storage = SO.Storage

local cachedRoot = nil

local function initializeRoot(root)
    root.schemaVersion = tonumber(root.schemaVersion) or SO.SCHEMA_VERSION
    root.nextZoneId = tonumber(root.nextZoneId) or 1
    root.zones = type(root.zones) == "table" and root.zones or {}
    root.players = type(root.players) == "table" and root.players or {}
    -- Retired identity keys -> the identity their record was copied to.
    root.identityAliases = type(root.identityAliases) == "table" and root.identityAliases or {}
    root.fixtureTombstones = type(root.fixtureTombstones) == "table" and root.fixtureTombstones or {}
    return root
end

function Storage.AddFixtureTombstone(fixtures)
    if not fixtures then return end
    table.insert(Storage.Get().fixtureTombstones, SO.Util.DeepCopy(fixtures))
end

function Storage.Get()
    if cachedRoot then return cachedRoot end
    cachedRoot = initializeRoot(ModData.getOrCreate(SO.MOD_DATA_KEY))
    return cachedRoot
end

function Storage.NextZoneId()
    local root = Storage.Get()
    local id = root.nextZoneId
    root.nextZoneId = id + 1
    return id
end

-- Wipe every persisted trace of the mod: zones, per-account recovery ledgers,
-- deferred fixture cleanup. Used by the pre-uninstall purge. Fixture objects in
-- the world must be removed by the caller first (SO.ZoneService.PurgeAll).
function Storage.Wipe()
    local root = Storage.Get()
    root.zones = {}
    root.players = {}
    root.identityAliases = {}
    root.fixtureTombstones = {}
    root.nextZoneId = 1
    root.schemaVersion = SO.SCHEMA_VERSION
    if ModData and ModData.remove then
        pcall(function() ModData.remove(SO.MOD_DATA_KEY) end)
    end
    cachedRoot = nil
    SO.Logger.Info("Wiped Satanic Temples mod data")
end

function Storage.FindZone(zoneId)
    zoneId = tonumber(zoneId)
    for index, zone in ipairs(Storage.Get().zones) do
        if tonumber(zone.id) == zoneId then return zone, index end
    end
    return nil, nil
end

function Storage.GetPlayer(identity)
    if not identity then return nil end
    local players = Storage.Get().players
    local record = players[identity]
    if not record then
        record = {
            bestXP = {},
            deathGeneration = 0,
            recoveredGeneration = 0,
            recoveryStrengthGeneration = 0,
            recoveryStrengthRedeemed = 0,
            recoveryBaselineXP = {},
            recoveryCeilingXP = {},
            playerCorpseSacrifices = {},
            lastHours = nil,
            lastTotalXP = nil,
            lastDeathMs = 0,
            awaitingRespawn = false,
        }
        players[identity] = record
    end
    record.bestXP = type(record.bestXP) == "table" and record.bestXP or {}
    record.deathGeneration = tonumber(record.deathGeneration) or 0
    record.recoveredGeneration = tonumber(record.recoveredGeneration) or 0
    record.recoveryStrengthGeneration = tonumber(record.recoveryStrengthGeneration) or -1
    record.recoveryStrengthRedeemed = tonumber(record.recoveryStrengthRedeemed) or 0
    record.recoveryBaselineXP = type(record.recoveryBaselineXP) == "table" and record.recoveryBaselineXP or {}
    record.recoveryCeilingXP = type(record.recoveryCeilingXP) == "table" and record.recoveryCeilingXP or {}
    record.playerCorpseSacrifices = type(record.playerCorpseSacrifices) == "table"
        and record.playerCorpseSacrifices or {}
    return record
end

function Storage.Initialize(isNewGame)
    cachedRoot = nil
    local root = Storage.Get()
    SO.Logger.Info("Global mod data initialized", {
        newGame = tostring(isNewGame == true),
        schema = root.schemaVersion,
        zones = #root.zones,
        players = SO.Util and SO.Util.TableCount(root.players) or 0,
    })
end

Events.OnInitGlobalModData.Add(Storage.Initialize)

return Storage
