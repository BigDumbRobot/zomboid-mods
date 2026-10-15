require "SVSBT_Effects"

if type(isClient) == "function" and isClient() and not isServer() then
    return
end

SVSBT.Server = SVSBT.Server or {}
SVSBT.Server.Registry = SVSBT.Server.Registry or {}

local Registry = SVSBT.Server.Registry
local Shared = SVSBT.Shared
local Logger = SVSBT.Logger

Registry.Data = Registry.Data or nil
Registry.Tag = Registry.Tag or nil
Registry.Dirty = Registry.Dirty == true
Registry.LastPersistMs = Registry.LastPersistMs or 0
Registry.Initialized = Registry.Initialized == true
Registry.Knowledge = Registry.Knowledge or {}
Registry.OrderedTrapCache = Registry.OrderedTrapCache or {}
Registry.TrapOrderDirty = Registry.TrapOrderDirty ~= false
Registry.SpatialBuckets = Registry.SpatialBuckets or {}
Registry.TrapSpatialKeys = Registry.TrapSpatialKeys or {}

local function nowMs()
    if type(getTimestampMs) == "function" then
        return getTimestampMs()
    end

    return math.floor(Shared.WorldAgeHours() * 3600000)
end

-- Project Zomboid's Lua runtime (Kahlua) does not expose the standard `next`
-- global, so `next(t) == nil` raises "Object tried to call nil". Use pairs.
local function isEmptyTable(value)
    if type(value) ~= "table" then
        return true
    end

    for _ in pairs(value) do
        return false
    end

    return true
end

local function finishFailure(run, reason)
    Logger.Finish(run, false, reason)
    return nil, tostring(reason or "UNKNOWN_ERROR")
end

local function sanitizeToken(value)
    local run = Logger.Begin("Registry.sanitizeToken")
    local token = tostring(value or ""):gsub("[^%w%-]", "")

    if #token < 16 or #token > 96 then
        return finishFailure(run, "INVALID_REGISTRY_TOKEN")
    end

    Logger.Finish(run, true, "length=" .. tostring(#token))
    return token
end

local function readToken()
    local run = Logger.Begin("Registry.readToken")

    if type(getFileReader) ~= "function" then
        return finishFailure(run, "FILE_READER_UNAVAILABLE")
    end

    local ok, value = pcall(function()
        local reader = getFileReader(Shared.RegistryKeyFile, false)

        if not reader then
            return nil
        end

        local token = reader:readLine()
        reader:close()
        return token
    end)

    if not ok then
        return finishFailure(run, "REGISTRY_TOKEN_READ_FAILED: " .. tostring(value))
    end

    if not value then
        Logger.Finish(run, true, "not found")
        return nil, "NOT_FOUND"
    end

    local token, reason = sanitizeToken(value)

    if not token then
        return finishFailure(run, reason)
    end

    Logger.Finish(run, true, "loaded")
    return token
end

local function createToken()
    local run = Logger.Begin("Registry.createToken")
    local token

    if type(getRandomUUID) == "function" then
        token = getRandomUUID()
    else
        local left = type(ZombRand) == "function" and ZombRand(100000000, 1000000000) or math.random(100000000, 999999999)
        local right = type(ZombRand) == "function" and ZombRand(100000000, 1000000000) or math.random(100000000, 999999999)
        token = tostring(nowMs()) .. "-" .. tostring(left) .. "-" .. tostring(right)
    end

    local result, reason = sanitizeToken(token)

    if not result then
        return finishFailure(run, reason)
    end

    Logger.Finish(run, true, "created")
    return result
end

local function writeToken(token)
    local run = Logger.Begin("Registry.writeToken")

    if type(getFileWriter) ~= "function" then
        return finishFailure(run, "FILE_WRITER_UNAVAILABLE")
    end

    local ok, result = pcall(function()
        local writer = getFileWriter(Shared.RegistryKeyFile, true, false)

        if not writer then
            return false
        end

        writer:writeln(token)
        writer:close()
        return true
    end)

    if not ok or result ~= true then
        return finishFailure(run, "REGISTRY_TOKEN_WRITE_FAILED")
    end

    Logger.Finish(run, true, "saved")
    return true
end

local function resolveTag()
    local run = Logger.Begin("Registry.resolveTag")

    if Registry.Tag then
        Logger.Finish(run, true, "cached")
        return Registry.Tag
    end

    local token = readToken()

    if not token then
        token = createToken()

        if token and not writeToken(token) then
            token = nil
        end
    end

    if token then
        Registry.Tag = "SVSBoobyTraps.Private_" .. token
        Logger.Finish(run, true, "private tag selected")
        return Registry.Tag
    end

    Registry.Tag = Shared.LegacyRegistryKey
    Logger.Error("Registry.resolveTag", "private key unavailable; legacy registry fallback selected")
    Logger.Finish(run, false, "legacy fallback")
    return Registry.Tag
end

local function ensureShape(data)
    local run = Logger.Begin("Registry.ensureShape")
    data = type(data) == "table" and data or {}
    data.schemaVersion = Shared.SchemaVersion
    data.nextSerial = math.max(1, math.floor(tonumber(data.nextSerial) or 1))
    data.traps = type(data.traps) == "table" and data.traps or {}
    data.documents = type(data.documents) == "table" and data.documents or {}
    data.exposures = type(data.exposures) == "table" and data.exposures or {}
    data.trapInjuries = type(data.trapInjuries) == "table" and data.trapInjuries or {}
    data.pendingTrapKills = type(data.pendingTrapKills) == "table" and data.pendingTrapKills or {}
    data.trapFires = type(data.trapFires) == "table" and data.trapFires or {}
    data.bleedingCreatures = type(data.bleedingCreatures) == "table" and data.bleedingCreatures or {}
    Logger.Finish(run, true, "schema=" .. tostring(data.schemaVersion))
    return data
end

local function spatialKey(record)
    if not record or record.x == nil or record.y == nil or record.z == nil then return nil end
    return tostring(math.floor(tonumber(record.z) or 0)) .. ":"
        .. tostring(math.floor((tonumber(record.x) or 0) / 10)) .. ":"
        .. tostring(math.floor((tonumber(record.y) or 0) / 10))
end

local function removeFromSpatialIndex(trapId)
    local id = tostring(trapId or "")
    local key = Registry.TrapSpatialKeys[id]
    local bucket = key and Registry.SpatialBuckets[key] or nil

    if bucket then
        bucket[id] = nil
        if isEmptyTable(bucket) then Registry.SpatialBuckets[key] = nil end
    end

    Registry.TrapSpatialKeys[id] = nil
end

function Registry.ReindexTrap(record)
    if not record or not record.id then return false end
    local id = tostring(record.id)
    local key = spatialKey(record)

    if Registry.TrapSpatialKeys[id] == key then return false end
    removeFromSpatialIndex(id)

    if key then
        Registry.SpatialBuckets[key] = Registry.SpatialBuckets[key] or {}
        Registry.SpatialBuckets[key][id] = record
        Registry.TrapSpatialKeys[id] = key
    end

    return true
end

local function rebuildRuntimeIndexes()
    Registry.SpatialBuckets = {}
    Registry.TrapSpatialKeys = {}
    Registry.OrderedTrapCache = {}

    for _, record in pairs(Registry.Data.traps) do
        Registry.ReindexTrap(record)
        Registry.OrderedTrapCache[#Registry.OrderedTrapCache + 1] = record
    end

    table.sort(Registry.OrderedTrapCache,
        function(first, second) return tostring(first.id) < tostring(second.id) end)
    Registry.TrapOrderDirty = false
end

function Registry.Initialize()
    local run = Logger.Begin("Registry.Initialize")

    if Registry.Initialized and Registry.Data then
        Logger.Finish(run, true, "already initialized")
        return true
    end

    local tag = resolveTag()
    local data = ModData.getOrCreate(tag)

    if tag ~= Shared.LegacyRegistryKey then
        local legacy = ModData.getOrCreate(Shared.LegacyRegistryKey)
        local legacyHasData = not isEmptyTable(type(legacy) == "table" and legacy.traps)
            or not isEmptyTable(type(legacy) == "table" and legacy.documents)
        local privateHasData = not isEmptyTable(type(data) == "table" and data.traps)
            or not isEmptyTable(type(data) == "table" and data.documents)

        if legacyHasData and not privateHasData then
            data = legacy
            ModData.add(tag, data)
            Logger.Warn("Registry.Initialize", "migrated legacy public registry into private server registry")
        end
    end

    Registry.Data = ensureShape(data)
    rebuildRuntimeIndexes()
    Registry.Initialized = true
    Registry.Dirty = true
    Registry.Persist("initialize")
    Logger.Finish(run, true, "tag ready")
    return true
end

function Registry.Persist(reason)
    local run = Logger.Begin("Registry.Persist", reason)

    if not Registry.Data then
        return finishFailure(run, "REGISTRY_NOT_INITIALIZED")
    end

    ModData.add(Registry.Tag or resolveTag(), Registry.Data)
    Registry.Dirty = false
    Registry.LastPersistMs = nowMs()
    Logger.Finish(run, true, tostring(reason or "unspecified"))
    return true
end

function Registry.MarkDirty(reason)
    local run = Logger.Begin("Registry.MarkDirty", reason)
    Registry.Dirty = true
    Logger.Finish(run, true)
    return true
end

function Registry.NextId(prefix)
    local run = Logger.Begin("Registry.NextId", prefix)
    Registry.Initialize()
    local serial = Registry.Data.nextSerial
    Registry.Data.nextSerial = serial + 1
    Registry.MarkDirty("serial")
    local id = tostring(prefix or "BT") .. "-" .. string.format("%08d", serial)
    Logger.Finish(run, true, id)
    return id
end

function Registry.AddTrap(record)
    local run = Logger.Begin("Registry.AddTrap", record and record.kind)
    Registry.Initialize()

    if type(record) ~= "table" or not record.kind then
        return finishFailure(run, "INVALID_TRAP_RECORD")
    end

    record.id = record.id or Registry.NextId("TRAP")
    record.createdAtHours = tonumber(record.createdAtHours) or Shared.WorldAgeHours()
    record.updatedAtHours = Shared.WorldAgeHours()
    record.state = record.state or Shared.State.Armed
    record.condition = math.max(0, math.min(100, tonumber(record.condition) or 100))
    record.maxCondition = math.max(record.condition, math.min(100, tonumber(record.maxCondition) or 100))
    record.triggerCount = math.max(0, math.floor(tonumber(record.triggerCount) or 0))
    Registry.Data.traps[tostring(record.id)] = record
    Registry.TrapOrderDirty = true
    Registry.ReindexTrap(record)
    Registry.MarkDirty("add trap")
    Logger.Finish(run, true, "id=" .. tostring(record.id))
    return record
end

function Registry.GetTrap(trapId)
    local run = Logger.Begin("Registry.GetTrap", trapId)
    Registry.Initialize()
    local record = Registry.Data.traps[tostring(trapId or "")]
    Logger.Finish(run, true, "found=" .. tostring(record ~= nil))
    return record
end

function Registry.RemoveTrap(trapId, reason)
    local run = Logger.Begin("Registry.RemoveTrap", trapId)
    Registry.Initialize()
    local key = tostring(trapId or "")
    local record = Registry.Data.traps[key]

    if not record then
        return finishFailure(run, "TRAP_NOT_FOUND")
    end

    Registry.Data.traps[key] = nil
    removeFromSpatialIndex(key)
    Registry.TrapOrderDirty = true
    Registry.MarkDirty(reason or "remove trap")
    Logger.Finish(run, true, tostring(reason or "removed"))
    return record
end

function Registry.AddDocument(record)
    local run = Logger.Begin("Registry.AddDocument")
    Registry.Initialize()

    if type(record) ~= "table" or not record.itemId then
        return finishFailure(run, "INVALID_DOCUMENT_RECORD")
    end

    record.id = record.id or Registry.NextId("DOC")
    record.kind = Shared.Kind.AnthraxDocument
    record.state = record.state or Shared.State.Armed
    record.createdAtHours = tonumber(record.createdAtHours) or Shared.WorldAgeHours()
    Registry.Data.documents[tostring(record.itemId)] = record
    Registry.MarkDirty("add document")
    Logger.Finish(run, true, "id=" .. tostring(record.id))
    return record
end

function Registry.GetDocument(itemId)
    local run = Logger.Begin("Registry.GetDocument", itemId)
    Registry.Initialize()
    local record = Registry.Data.documents[tostring(itemId or "")]
    Logger.Finish(run, true, "found=" .. tostring(record ~= nil))
    return record
end

function Registry.RemoveDocument(itemId, reason)
    local run = Logger.Begin("Registry.RemoveDocument", itemId)
    Registry.Initialize()
    local key = tostring(itemId or "")

    if not Registry.Data.documents[key] then
        return finishFailure(run, "DOCUMENT_NOT_FOUND")
    end

    Registry.Data.documents[key] = nil
    Registry.MarkDirty(reason or "remove document")
    Logger.Finish(run, true, tostring(reason or "removed"))
    return true
end

function Registry.AddExposure(username, record)
    local run = Logger.Begin("Registry.AddExposure", username)
    Registry.Initialize()
    Registry.Data.exposures[tostring(username)] = record
    Registry.MarkDirty("add exposure")
    Logger.Finish(run, true)
    return record
end

function Registry.GetExposure(username)
    local run = Logger.Begin("Registry.GetExposure", username)
    Registry.Initialize()
    local record = Registry.Data.exposures[tostring(username or "")]
    Logger.Finish(run, true, "found=" .. tostring(record ~= nil))
    return record
end

function Registry.RemoveExposure(username)
    local run = Logger.Begin("Registry.RemoveExposure", username)
    Registry.Initialize()
    Registry.Data.exposures[tostring(username or "")] = nil
    Registry.MarkDirty("remove exposure")
    Logger.Finish(run, true)
    return true
end

function Registry.CountTraps(predicate)
    local run = Logger.Begin("Registry.CountTraps")
    Registry.Initialize()
    local count = 0

    for _, record in pairs(Registry.Data.traps) do
        if not predicate or predicate(record) then
            count = count + 1
        end
    end

    Logger.Finish(run, true, "count=" .. tostring(count))
    return count
end

function Registry.FindTraps(predicate)
    local run = Logger.Begin("Registry.FindTraps")
    Registry.Initialize()
    local results = {}

    for _, record in pairs(Registry.Data.traps) do
        if not predicate or predicate(record) then
            results[#results + 1] = record
        end
    end

    Logger.Finish(run, true, "count=" .. tostring(#results))
    return results
end

function Registry.OrderedTraps()
    Registry.Initialize()

    if Registry.TrapOrderDirty then
        Registry.OrderedTrapCache = {}
        for _, record in pairs(Registry.Data.traps) do
            Registry.OrderedTrapCache[#Registry.OrderedTrapCache + 1] = record
        end
        table.sort(Registry.OrderedTrapCache,
            function(first, second) return tostring(first.id) < tostring(second.id) end)
        Registry.TrapOrderDirty = false
    end

    return Registry.OrderedTrapCache
end

function Registry.FindNearby(x, y, z, radius, predicate)
    Registry.Initialize()
    local results = {}
    local seen = {}
    radius = math.max(0, tonumber(radius) or 0)
    local minimumX = math.floor(((tonumber(x) or 0) - radius) / 10)
    local maximumX = math.floor(((tonumber(x) or 0) + radius) / 10)
    local minimumY = math.floor(((tonumber(y) or 0) - radius) / 10)
    local maximumY = math.floor(((tonumber(y) or 0) + radius) / 10)
    local floorZ = math.floor(tonumber(z) or 0)

    for bucketX = minimumX, maximumX do
        for bucketY = minimumY, maximumY do
            local key = tostring(floorZ) .. ":" .. tostring(bucketX) .. ":" .. tostring(bucketY)
            for id, record in pairs(Registry.SpatialBuckets[key] or {}) do
                if not seen[id] and Shared.Distance(x, y, record.x, record.y) <= radius
                    and (not predicate or predicate(record)) then
                    seen[id] = true
                    results[#results + 1] = record
                end
            end
        end
    end

    return results
end

function Registry.GrantKnowledge(username, trapId, durationSeconds)
    local run = Logger.Begin("Registry.GrantKnowledge", trapId)
    local name = tostring(username or "unknown")
    Registry.Knowledge[name] = Registry.Knowledge[name] or {}
    Registry.Knowledge[name][tostring(trapId)] = nowMs() + (math.max(1, tonumber(durationSeconds) or 60) * 1000)
    Logger.Finish(run, true, "player=" .. name)
    return true
end

function Registry.HasKnowledge(username, trapId)
    local run = Logger.Begin("Registry.HasKnowledge", trapId)
    local bucket = Registry.Knowledge[tostring(username or "unknown")]
    local expires = bucket and tonumber(bucket[tostring(trapId)]) or 0
    local result = expires > nowMs()

    if bucket and not result then
        bucket[tostring(trapId)] = nil
    end

    Logger.Finish(run, true, "known=" .. tostring(result))
    return result
end

function Registry.PruneKnowledge(activeNames)
    local current = nowMs()
    local removed = 0

    for username, bucket in pairs(Registry.Knowledge) do
        for trapId, expires in pairs(bucket) do
            if tonumber(expires) <= current or Registry.Data.traps[tostring(trapId)] == nil then
                bucket[trapId] = nil
                removed = removed + 1
            end
        end

        if isEmptyTable(bucket) or (activeNames and not activeNames[username]) then
            Registry.Knowledge[username] = nil
        end
    end

    return removed
end

Logger.Info("SVSBT_Registry.load", "private persistent registry module initialized")

return Registry
