require "BonkZone/BonkZone_Constants"
require "BonkZone/BonkZone_Logger"

BonkZone = BonkZone or {}
BonkZone.Storage = BonkZone.Storage or {}

local Storage = BonkZone.Storage
local Constants = BonkZone.Constants
local Logger = BonkZone.Logger

Storage.Data = Storage.Data or nil

local function getData()
    local startedAt = Logger.Begin("Storage.getData")
    if Storage.Data then
        Logger.Finish("Storage.getData", startedAt, true, "cached")
        return Storage.Data
    end
    local data = ModData.getOrCreate(Constants.MODDATA_KEY)
    if type(data.zones) ~= "table" then data.zones = {} end
    if tonumber(data.dataVersion) ~= Constants.DATA_VERSION then
        data.dataVersion = Constants.DATA_VERSION
    end
    data.revision = tonumber(data.revision) or 0
    data.nextId = tonumber(data.nextId) or 1
    Storage.Data = data
    Logger.Finish("Storage.getData", startedAt, true, { zones = #data.zones, revision = data.revision })
    return data
end

local function copyZone(zone)
    local startedAt = Logger.Begin("Storage.copyZone", { id = zone and zone.id })
    local result = {
        id = tostring(zone.id),
        name = tostring(zone.name),
        x1 = tonumber(zone.x1),
        y1 = tonumber(zone.y1),
        x2 = tonumber(zone.x2),
        y2 = tonumber(zone.y2),
        z1 = tonumber(zone.z1),
        z2 = tonumber(zone.z2),
        createdBy = tostring(zone.createdBy or ""),
        createdAt = tonumber(zone.createdAt) or 0,
        updatedAt = tonumber(zone.updatedAt) or 0,
    }
    Logger.Finish("Storage.copyZone", startedAt, true)
    return result
end

local function findIndexById(id)
    local startedAt = Logger.Begin("Storage.findIndexById", { id = id })
    local idString = tostring(id or "")
    local data = getData()
    for index, zone in ipairs(data.zones) do
        if tostring(zone.id) == idString then
            Logger.Finish("Storage.findIndexById", startedAt, true, { index = index })
            return index
        end
    end
    Logger.Finish("Storage.findIndexById", startedAt, true, "not found")
    return nil
end

local function nextId()
    local startedAt = Logger.Begin("Storage.nextId")
    local data = getData()
    local id
    if getRandomUUID then
        id = tostring(getRandomUUID())
    else
        id = "BZ-" .. tostring(data.nextId)
        data.nextId = data.nextId + 1
    end
    Logger.Finish("Storage.nextId", startedAt, true, { id = id })
    return id
end

local function touchData()
    local startedAt = Logger.Begin("Storage.touchData")
    local data = getData()
    data.revision = data.revision + 1
    Logger.Finish("Storage.touchData", startedAt, true, { revision = data.revision })
    return data.revision
end

function Storage.Initialize()
    local startedAt = Logger.Begin("Storage.Initialize")
    local data = getData()
    Logger.Info("Storage", "persistent data initialized", { zones = #data.zones, revision = data.revision })
    Logger.Finish("Storage.Initialize", startedAt, true)
    return data
end

function Storage.GetRevision()
    local revision = getData().revision
    Logger.Trace("Storage.GetRevision", "read", { revision = revision })
    return revision
end

function Storage.GetPublicZones()
    local startedAt = Logger.Begin("Storage.GetPublicZones")
    local result = {}
    for _, zone in ipairs(getData().zones) do result[#result + 1] = copyZone(zone) end
    Logger.Finish("Storage.GetPublicZones", startedAt, true, { count = #result })
    return result
end

function Storage.GetById(id)
    local startedAt = Logger.Begin("Storage.GetById", { id = id })
    local index = findIndexById(id)
    local zone = index and getData().zones[index] or nil
    Logger.Finish("Storage.GetById", startedAt, true, { found = zone ~= nil })
    return zone
end

function Storage.AddZone(name, x1, y1, x2, y2, createdBy)
    local startedAt = Logger.Begin("Storage.AddZone", { name = name })
    local normalizedName = Constants.NormalizeName(name)
    local nx1, ny1, nx2, ny2 = Constants.NormalizeBounds(x1, y1, x2, y2)
    if normalizedName == "" then
        Logger.Finish("Storage.AddZone", startedAt, false, "empty name")
        return nil, "Zone name cannot be empty."
    end
    if not Constants.IsBoundsValid(nx1, ny1, nx2, ny2) then
        Logger.Finish("Storage.AddZone", startedAt, false, "invalid bounds")
        return nil, "Zone bounds are invalid."
    end
    local now = Constants.NowMs()
    local zone = {
        id = nextId(),
        name = normalizedName,
        x1 = nx1,
        y1 = ny1,
        x2 = nx2,
        y2 = ny2,
        z1 = Constants.ALL_FLOORS_MIN,
        z2 = Constants.ALL_FLOORS_MAX,
        createdBy = tostring(createdBy or ""),
        createdAt = now,
        updatedAt = now,
    }
    local data = getData()
    data.zones[#data.zones + 1] = zone
    touchData()
    Logger.Info("Storage", "zone added", { id = zone.id, name = zone.name, x1 = nx1, y1 = ny1, x2 = nx2, y2 = ny2 })
    Logger.Finish("Storage.AddZone", startedAt, true, { id = zone.id })
    return copyZone(zone), nil
end

function Storage.UpdateBounds(id, x1, y1, x2, y2, updatedBy)
    local startedAt = Logger.Begin("Storage.UpdateBounds", { id = id })
    local zone = Storage.GetById(id)
    if not zone then
        Logger.Finish("Storage.UpdateBounds", startedAt, false, "not found")
        return nil, "Zone was not found."
    end
    local nx1, ny1, nx2, ny2 = Constants.NormalizeBounds(x1, y1, x2, y2)
    if not Constants.IsBoundsValid(nx1, ny1, nx2, ny2) then
        Logger.Finish("Storage.UpdateBounds", startedAt, false, "invalid bounds")
        return nil, "Zone bounds are invalid."
    end
    zone.x1, zone.y1, zone.x2, zone.y2 = nx1, ny1, nx2, ny2
    zone.updatedAt = Constants.NowMs()
    zone.updatedBy = tostring(updatedBy or "")
    touchData()
    Logger.Info("Storage", "zone bounds updated", { id = zone.id, by = zone.updatedBy })
    Logger.Finish("Storage.UpdateBounds", startedAt, true)
    return copyZone(zone), nil
end

function Storage.RenameZone(id, name, updatedBy)
    local startedAt = Logger.Begin("Storage.RenameZone", { id = id })
    local zone = Storage.GetById(id)
    if not zone then
        Logger.Finish("Storage.RenameZone", startedAt, false, "not found")
        return nil, "Zone was not found."
    end
    local normalizedName = Constants.NormalizeName(name)
    if normalizedName == "" then
        Logger.Finish("Storage.RenameZone", startedAt, false, "empty name")
        return nil, "Zone name cannot be empty."
    end
    zone.name = normalizedName
    zone.updatedAt = Constants.NowMs()
    zone.updatedBy = tostring(updatedBy or "")
    touchData()
    Logger.Info("Storage", "zone renamed", { id = zone.id, name = zone.name, by = zone.updatedBy })
    Logger.Finish("Storage.RenameZone", startedAt, true)
    return copyZone(zone), nil
end

function Storage.RemoveZone(id, removedBy)
    local startedAt = Logger.Begin("Storage.RemoveZone", { id = id })
    local index = findIndexById(id)
    if not index then
        Logger.Finish("Storage.RemoveZone", startedAt, false, "not found")
        return false, "Zone was not found."
    end
    local data = getData()
    local zone = table.remove(data.zones, index)
    touchData()
    Logger.Info("Storage", "zone removed", { id = zone.id, name = zone.name, by = removedBy })
    Logger.Finish("Storage.RemoveZone", startedAt, true)
    return true, nil
end

function Storage.RefreshSharedRegistry()
    local startedAt = Logger.Begin("Storage.RefreshSharedRegistry")
    BonkZone.Registry.ReplaceAll(Storage.GetPublicZones(), Storage.GetRevision())
    Logger.Finish("Storage.RefreshSharedRegistry", startedAt, true)
end

return Storage

