require "DeadMansMap/DMM_Core"

DeadMansMap = DeadMansMap or {}

local ServerDrop = {}
local Core = DeadMansMap.Core
local Logger = DeadMansMap.Logger

ServerDrop.MAX_SYMBOLS = Core.SAFETY_MAX_ANNOTATIONS
ServerDrop.MAX_BATCH_SIZE = 50
ServerDrop.TRANSACTION_TIMEOUT_TICKS = 1800

local state = {
    tick = 0,
    pending = {},
    completed = {},
}

local function getNumber(target, methodName, fallback)
    local ok, value = Core.tryMethod(target, methodName)
    if ok and value ~= nil then
        return tonumber(value) or fallback
    end
    return fallback
end

local function getKey(player, deathId)
    local onlineId = math.floor(getNumber(player, "getOnlineID", -1))
    return tostring(onlineId) .. ":" .. tostring(deathId or "")
end

-- transaction.symbols is a WorldMapSymbolsV2 API (see beginDrop). Core.rebuildMapSymbol
-- handles the add + every appearance setter, matching the client capture path.
local function appendSymbol(transaction, data)
    if not transaction or not transaction.symbols or not data then
        return false
    end

    if not Core.rebuildMapSymbol(transaction.symbols, data) then
        return false
    end

    transaction.copiedCount = transaction.copiedCount + 1
    return true
end

local function findDropSquare(player, transaction)
    local playerX = math.floor(getNumber(player, "getX", transaction.x))
    local playerY = math.floor(getNumber(player, "getY", transaction.y))
    local playerZ = math.floor(getNumber(player, "getZ", transaction.z))
    local x = math.abs(transaction.x - playerX) <= 8 and transaction.x or playerX
    local y = math.abs(transaction.y - playerY) <= 8 and transaction.y or playerY
    local z = math.abs(transaction.z - playerZ) <= 1 and transaction.z or playerZ
    local cell = getCell and getCell() or nil
    if not cell then
        return nil
    end

    for radius = 0, 4 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if radius == 0 or math.abs(dx) == radius or math.abs(dy) == radius then
                    local ok, square = Core.tryMethod(cell, "getGridSquare", x + dx, y + dy, z)
                    if ok and square then
                        return square
                    end
                end
            end
        end
    end
    return nil
end

local function acknowledgeDrop(player, transaction, square)
    if not sendServerCommand then
        return
    end
    sendServerCommand(player, Core.MOD_ID, "deathMapDropped", {
        deathId = transaction.deathId,
        x = math.floor(getNumber(square, "getX", transaction.x)),
        y = math.floor(getNumber(square, "getY", transaction.y)),
        copiedCount = transaction.copiedCount,
    })
end

local function tryFinish(player, key, transaction)
    if not transaction or not transaction.finished
        or transaction.receivedBatches < transaction.expectedBatches then
        return false
    end

    local square = findDropSquare(player, transaction)
    if not square then
        Logger.error("ServerDrop.tryFinish", "No server square was available for death map", {
            deathId = transaction.deathId,
        })
        return false
    end

    transaction.stats.copiedCount = transaction.copiedCount
    transaction.record.stats = transaction.stats
    if not Core.tagDeathMap(
        transaction.item,
        transaction.record,
        transaction.copiedCount,
        transaction.stats.sourceCount
    ) then
        Logger.error("ServerDrop.tryFinish", "Server could not tag death map", {
            deathId = transaction.deathId,
        })
        return false
    end

    local addOk, addedItem = Core.tryMethod(
        square,
        "AddWorldInventoryItem",
        transaction.item,
        0.5,
        0.5,
        0.0,
        false
    )
    if not addOk or not addedItem then
        Logger.error("ServerDrop.tryFinish", "Server could not place death map", {
            deathId = transaction.deathId,
        })
        return false
    end

    local worldOk, worldObject = Core.tryMethod(addedItem, "getWorldItem")
    if worldOk and worldObject then
        Core.tryMethod(worldObject, "setIgnoreRemoveSandbox", true)
        Core.tryMethod(worldObject, "transmitCompleteItemToClients")
    end

    transaction.item = addedItem
    transaction.worldObject = worldObject
    transaction.expiresTick = state.tick + ServerDrop.TRANSACTION_TIMEOUT_TICKS
    state.completed[key] = transaction
    state.pending[key] = nil
    acknowledgeDrop(player, transaction, square)

    Logger.info("ServerDrop.tryFinish", "Server dropped annotated map", {
        deathId = transaction.deathId,
        copiedCount = transaction.copiedCount,
        x = getNumber(square, "getX", transaction.x),
        y = getNumber(square, "getY", transaction.y),
    })
    return true
end

local function beginDrop(player, args)
    local deathId = args and tostring(args.deathId or "") or ""
    if deathId == "" then
        return
    end

    local deadOk, isDead = Core.tryMethod(player, "isDead")
    if deadOk and isDead ~= true then
        Logger.warn("ServerDrop.beginDrop", "Rejected death-map request from living player", {
            deathId = deathId,
        })
        return
    end

    local item = instanceItem and instanceItem("Base.Map") or nil
    if not item then
        Logger.error("ServerDrop.beginDrop", "Server could not create Base.Map", deathId)
        return
    end
    Core.tryMethod(item, "setMapID", Core.MAP_ID)

    -- MapItem:getSymbols() is @HiddenFromLua; go through a detached UIWorldMap.
    -- If the dedicated server cannot construct one, the MP drop is not possible
    -- and we bail rather than spawn a blank map.
    local symbols = Core.openMapSymbols(item)
    if not symbols then
        Logger.error("ServerDrop.beginDrop", "Server could not open a symbols API for the death map", {
            deathId = deathId,
        })
        return
    end

    local expectedBatches = math.max(0, math.floor(tonumber(args.expectedBatches) or 0))
    local key = getKey(player, deathId)
    local stats = {
        sourceCount = math.max(0, math.floor(tonumber(args.sourceCount) or 0)),
        copiedCount = 0,
        wipedPersonalMap = args.wipedPersonalMap == true,
        minX = tonumber(args.minX),
        minY = tonumber(args.minY),
        maxX = tonumber(args.maxX),
        maxY = tonumber(args.maxY),
    }
    local record = {
        deathId = deathId,
        characterName = Core.getCharacterName(player),
        x = math.floor(getNumber(player, "getX", tonumber(args.x) or 0)),
        y = math.floor(getNumber(player, "getY", tonumber(args.y) or 0)),
        z = math.floor(getNumber(player, "getZ", tonumber(args.z) or 0)),
        worldAgeHours = Core.getWorldAgeHours(),
        wipedPersonalMap = args.wipedPersonalMap == true,
        stats = stats,
    }

    state.pending[key] = {
        deathId = deathId,
        item = item,
        symbols = symbols,
        record = record,
        stats = stats,
        x = record.x,
        y = record.y,
        z = record.z,
        expectedBatches = expectedBatches,
        receivedBatches = 0,
        seenBatches = {},
        copiedCount = 0,
        finished = false,
        expiresTick = state.tick + ServerDrop.TRANSACTION_TIMEOUT_TICKS,
    }
end

local function appendBatch(player, args)
    local deathId = args and tostring(args.deathId or "") or ""
    local key = getKey(player, deathId)
    local transaction = state.pending[key]
    if not transaction then
        return
    end

    local batchIndex = math.max(1, math.floor(tonumber(args.batchIndex) or 1))
    if transaction.seenBatches[batchIndex] then
        return
    end
    transaction.seenBatches[batchIndex] = true
    transaction.receivedBatches = transaction.receivedBatches + 1

    local symbols = args.symbols
    local count = math.min(
        ServerDrop.MAX_BATCH_SIZE,
        math.max(0, math.floor(tonumber(args.count) or 0))
    )
    for index = 1, count do
        if transaction.copiedCount >= ServerDrop.MAX_SYMBOLS then
            break
        end
        appendSymbol(transaction, symbols and symbols[index] or nil)
    end
    tryFinish(player, key, transaction)
end

local function finishDrop(player, args)
    local deathId = args and tostring(args.deathId or "") or ""
    local key = getKey(player, deathId)
    local transaction = state.pending[key]
    if not transaction then
        return
    end
    transaction.expectedBatches = math.max(
        transaction.expectedBatches,
        math.floor(tonumber(args.expectedBatches) or 0)
    )
    transaction.finished = true
    tryFinish(player, key, transaction)
end

local function linkCorpse(player, args)
    local deathId = args and tostring(args.deathId or "") or ""
    local transaction = state.completed[getKey(player, deathId)]
    if not transaction or not transaction.item then
        return
    end

    local modDataOk, modData = Core.tryMethod(transaction.item, "getModData")
    if not modDataOk or not modData then
        return
    end
    modData.DMM_CorpseTagged = true
    modData.DMM_CorpseObjectId = tostring(args.corpseObjectId or "")
    modData.DMM_CorpseCharacterOnlineId = tonumber(args.corpseCharacterOnlineId) or -1
    modData.DMM_CorpseDeathTime = tonumber(args.corpseDeathTime) or 0
    if transaction.worldObject then
        Core.tryMethod(transaction.worldObject, "transmitCompleteItemToClients")
    end
end

function ServerDrop.onClientCommand(module, command, player, args)
    if module ~= Core.MOD_ID or not player or not args then
        return
    end
    if command == "beginDeathMapDrop" then
        beginDrop(player, args)
    elseif command == "appendDeathMapSymbols" then
        appendBatch(player, args)
    elseif command == "finishDeathMapDrop" then
        finishDrop(player, args)
    elseif command == "linkDeathMapCorpse" then
        linkCorpse(player, args)
    end
end

function ServerDrop.onTick()
    state.tick = state.tick + 1
    if state.tick % 60 ~= 0 then
        return
    end
    for key, transaction in pairs(state.pending) do
        if state.tick >= transaction.expiresTick then
            state.pending[key] = nil
        end
    end
    for key, transaction in pairs(state.completed) do
        if state.tick >= transaction.expiresTick then
            state.completed[key] = nil
        end
    end
end

DeadMansMap.ServerDrop = ServerDrop

if Events and Events.OnClientCommand then
    Events.OnClientCommand.Add(ServerDrop.onClientCommand)
end
if Events and Events.OnTick then
    Events.OnTick.Add(ServerDrop.onTick)
end

Logger.info("DMM_ServerDrop", "Server death-map receiver loaded")

return ServerDrop
