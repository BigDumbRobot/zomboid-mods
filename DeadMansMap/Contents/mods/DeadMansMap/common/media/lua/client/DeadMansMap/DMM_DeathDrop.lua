require "DeadMansMap/DMM_MapSnapshot"

DeadMansMap = DeadMansMap or {}

local DeathDrop = {}
local Core = DeadMansMap.Core
local Logger = DeadMansMap.Logger
local Snapshot = DeadMansMap.Snapshot

-- The annotated map remains a loose world object so it survives reanimation.
-- Corpse synchronization is best-effort and never blocks the ground drop.
DeathDrop.PENDING_TIMEOUT_TICKS = 1800
DeathDrop.RETRY_INTERVAL_TICKS = 15
DeathDrop.SEARCH_RADIUS = 4
DeathDrop.COMPLETED_HISTORY = 16
DeathDrop.CORPSE_DEATH_TIME_TOLERANCE_HOURS = 0.1
DeathDrop.NETWORK_BATCH_SIZE = 40

local state = {
    tick = 0,
    pending = nil,
    completedDeathIds = {},
}

local function getNumber(target, methodName, fallback)
    local ok, value = Core.tryMethod(target, methodName)
    if ok and value ~= nil then
        return tonumber(value) or fallback
    end
    return fallback
end

local function isMultiplayerClient()
    if not isClient then
        return false
    end
    local ok, result = pcall(isClient)
    return ok and result == true
end

local function sendNetworkCommand(player, command, args)
    if not sendClientCommand then
        return false
    end
    local ok, err = pcall(sendClientCommand, player, Core.MOD_ID, command, args)
    if not ok then
        Logger.error("DeathDrop.sendNetworkCommand", "Client command failed", {
            command = command,
            error = err,
        })
    end
    return ok
end

local function sendCorpseLinkToServer(record)
    if not isMultiplayerClient() or not record or not record.dropped
        or not record.corpseTagged or record.corpseLinkSent then
        return false
    end

    local sent = sendNetworkCommand(record.player, "linkDeathMapCorpse", {
        deathId = record.deathId,
        corpseObjectId = record.corpseObjectId or "",
        corpseCharacterOnlineId = record.corpseCharacterOnlineId or -1,
        corpseDeathTime = record.corpseDeathTime or record.worldAgeHours or 0,
    })
    record.corpseLinkSent = sent
    return sent
end

local function wasCompleted(deathId)
    for _, id in ipairs(state.completedDeathIds) do
        if id == deathId then
            return true
        end
    end
    return false
end

local function rememberCompleted(deathId)
    table.insert(state.completedDeathIds, deathId)
    while #state.completedDeathIds > DeathDrop.COMPLETED_HISTORY do
        table.remove(state.completedDeathIds, 1)
    end
end

local function buildDeathRecord(player)
    local trace = Logger.traceStart("DeathDrop.buildDeathRecord")
    local characterName = Core.getCharacterName(player)
    local record = {
        player = player,
        characterName = characterName,
        onlineId = math.floor(getNumber(player, "getOnlineID", -1)),
        x = math.floor(getNumber(player, "getX", 0)),
        y = math.floor(getNumber(player, "getY", 0)),
        z = math.floor(getNumber(player, "getZ", 0)),
        worldAgeHours = Core.getWorldAgeHours(),
        createdTick = state.tick,
        expiresTick = state.tick + DeathDrop.PENDING_TIMEOUT_TICKS,
        item = nil,
        stats = nil,
        config = nil,
        deadBody = nil,
        corpseTagged = false,
        dropped = false,
        dropX = nil,
        dropY = nil,
    }
    record.deathId = Core.makeDeathId(player, characterName)

    Logger.info("DeathDrop.buildDeathRecord", "Death record created", {
        deathId = record.deathId,
        characterName = record.characterName,
        x = record.x,
        y = record.y,
        z = record.z,
    })
    Logger.traceEnd(trace, "ok", record.deathId)
    return record
end

local function getListSize(list)
    local ok, size = Core.tryMethod(list, "size")
    if not ok then
        return 0
    end
    return math.max(0, math.floor(tonumber(size) or 0))
end

local function getCellSafe()
    if not getCell then
        return nil
    end
    local ok, cell = pcall(getCell)
    if ok and cell then
        return cell
    end
    return nil
end

local function isMatchingPlayerBody(body, record)
    if not body or not record then
        return false
    end

    local playerOk, isPlayerBody = Core.tryMethod(body, "isPlayer")
    if not playerOk or isPlayerBody ~= true then
        return false
    end

    local onlineOk, onlineValue = Core.tryMethod(body, "getCharacterOnlineID")
    local bodyOnlineId = onlineOk and tonumber(onlineValue) or -1
    local deathOk, deathValue = Core.tryMethod(body, "getDeathTime")
    local bodyDeathTime = deathOk and tonumber(deathValue) or nil
    local deathTimeMatches = bodyDeathTime ~= nil
        and math.abs(bodyDeathTime - record.worldAgeHours)
            <= DeathDrop.CORPSE_DEATH_TIME_TOLERANCE_HOURS

    if record.onlineId >= 0 and bodyOnlineId >= 0 then
        -- Online IDs identify the player, while death time disambiguates old
        -- corpses left nearby by an earlier character on the same connection.
        return bodyOnlineId == record.onlineId and deathTimeMatches
    end

    return Core.getCharacterName(body) == record.characterName and deathTimeMatches
end

local function findMatchingDeadBody(record)
    local trace = Logger.traceStart("DeathDrop.findMatchingDeadBody", {
        deathId = record and record.deathId,
    })
    local cell = getCellSafe()
    if not cell or not record then
        Logger.traceEnd(trace, "failed", cell and "no-record" or "no-cell")
        return nil
    end

    for radius = 0, DeathDrop.SEARCH_RADIUS do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if radius == 0 or math.abs(dx) == radius or math.abs(dy) == radius then
                    local squareOk, square = Core.tryMethod(
                        cell,
                        "getGridSquare",
                        record.x + dx,
                        record.y + dy,
                        record.z
                    )
                    if squareOk and square then
                        local bodiesOk, bodies = Core.tryMethod(square, "getDeadBodys")
                        if bodiesOk and bodies then
                            for index = 0, getListSize(bodies) - 1 do
                                local bodyOk, body = Core.tryMethod(bodies, "get", index)
                                if bodyOk and isMatchingPlayerBody(body, record) then
                                    Logger.traceEnd(trace, "ok", {
                                        dx = dx,
                                        dy = dy,
                                    })
                                    return body
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    Logger.traceEnd(trace, "pending", "matching-corpse-not-found")
    return nil
end

local function tagPendingWithDeadBody()
    local trace = Logger.traceStart("DeathDrop.tagPendingWithDeadBody")
    local record = state.pending
    if not record or not record.item then
        Logger.traceEnd(trace, "failed", "no-pending-item")
        return false
    end

    if record.corpseTagged and record.deadBody then
        Logger.traceEnd(trace, "ok", "already-tagged")
        return true
    end

    local deadBody = record.deadBody or findMatchingDeadBody(record)
    if not deadBody then
        Logger.traceEnd(trace, "retry", "matching-corpse-not-found")
        return false
    end

    if not Core.tagDeathMapWithDeadBody(record.item, deadBody, record) then
        Logger.traceEnd(trace, "retry", "tagging-failed")
        return false
    end

    record.deadBody = deadBody
    record.corpseTagged = true
    sendCorpseLinkToServer(record)
    Logger.traceEnd(trace, "ok", record.corpseObjectId)
    return true
end

local function squareAcceptsItem(square)
    if not square then
        return false
    end
    -- A square with a floor is always fine; fall back to isFree so an outdoor
    -- square with no floor object still works.
    local floorOk, floor = Core.tryMethod(square, "getFloor")
    if floorOk and floor then
        return true
    end
    local freeOk, free = Core.tryMethod(square, "isFree", false)
    if freeOk then
        return free == true
    end
    return true
end

local function findDropSquare(record)
    local trace = Logger.traceStart("DeathDrop.findDropSquare")
    local cell = getCellSafe()
    if not cell then
        Logger.traceEnd(trace, "failed", "no-cell")
        return nil
    end

    local exactOk, exact = Core.tryMethod(cell, "getGridSquare", record.x, record.y, record.z)
    if exactOk and exact and squareAcceptsItem(exact) then
        Logger.traceEnd(trace, "ok", "death-square")
        return exact
    end

    local fallback = (exactOk and exact) or nil
    for radius = 1, DeathDrop.SEARCH_RADIUS do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local nOk, square = Core.tryMethod(
                        cell,
                        "getGridSquare",
                        record.x + dx,
                        record.y + dy,
                        record.z
                    )
                    if nOk and square then
                        if squareAcceptsItem(square) then
                            Logger.traceEnd(trace, "ok", {
                                dx = dx,
                                dy = dy,
                            })
                            return square
                        end
                        fallback = fallback or square
                    end
                end
            end
        end
    end

    Logger.traceEnd(trace, fallback and "fallback" or "no-square")
    return fallback
end

local function finishPending(status, summary)
    local record = state.pending
    state.pending = nil
    if record and record.deathId then
        rememberCompleted(record.deathId)
    end
    Logger.finishRun(status, summary)
end

local function capturePendingMap()
    local trace = Logger.traceStart("DeathDrop.capturePendingMap")
    local record = state.pending
    if not record then
        Logger.traceEnd(trace, "failed", "no-pending-record")
        return false
    end

    if record.item then
        Logger.traceEnd(trace, "ok", "already-captured")
        return true
    end

    -- Capture immediately while the OnPlayerDeath player and its personal-map
    -- singleton are still the dead character's. Corpse creation/synchronization
    -- may be delayed (or the body may reanimate), so it must not gate the map.
    local item, stats, serializedSymbols = Snapshot.createDeathMap(
        record.player,
        record,
        record.config
    )
    if not item then
        Logger.traceEnd(trace, "failed", stats)
        finishPending("capture-failed", stats)
        return false
    end

    record.item = item
    record.stats = stats
    record.serializedSymbols = serializedSymbols or {}

    Logger.info("DeathDrop.capturePendingMap", "Annotated map captured", {
        deathId = record.deathId,
        copiedCount = stats.copiedCount,
        wipedPersonalMap = stats.wipedPersonalMap,
    })

    -- Tag now if the body already exists; otherwise the retry loop will keep
    -- trying after the map has safely reached the ground.
    tagPendingWithDeadBody()
    Logger.traceEnd(trace, "ok", {
        corpseTagged = record.corpseTagged == true,
    })
    return true
end

local function sendPendingMapToServer(record)
    if record.networkSent then
        return true
    end

    local symbols = record.serializedSymbols or {}
    local batchSize = DeathDrop.NETWORK_BATCH_SIZE
    local batchCount = math.ceil(#symbols / batchSize)
    local stats = record.stats or {}
    local beginArgs = {
        deathId = record.deathId,
        characterName = record.characterName,
        x = record.x,
        y = record.y,
        z = record.z,
        worldAgeHours = record.worldAgeHours,
        sourceCount = stats.sourceCount or 0,
        copiedCount = #symbols,
        wipedPersonalMap = stats.wipedPersonalMap == true,
        minX = stats.minX,
        minY = stats.minY,
        maxX = stats.maxX,
        maxY = stats.maxY,
        expectedBatches = batchCount,
    }

    if not sendNetworkCommand(record.player, "beginDeathMapDrop", beginArgs) then
        return false
    end

    for batchIndex = 1, batchCount do
        local first = (batchIndex - 1) * batchSize + 1
        local last = math.min(#symbols, first + batchSize - 1)
        local batch = {}
        for index = first, last do
            table.insert(batch, symbols[index])
        end
        if not sendNetworkCommand(record.player, "appendDeathMapSymbols", {
            deathId = record.deathId,
            batchIndex = batchIndex,
            count = #batch,
            symbols = batch,
        }) then
            return false
        end
    end

    if not sendNetworkCommand(record.player, "finishDeathMapDrop", {
        deathId = record.deathId,
        expectedBatches = batchCount,
    }) then
        return false
    end

    record.networkSent = true
    Logger.info("DeathDrop.sendPendingMapToServer", "Annotated map sent for server drop", {
        deathId = record.deathId,
        symbolCount = #symbols,
        batchCount = batchCount,
    })
    return true
end

local function dropPendingOnGround()
    local trace = Logger.traceStart("DeathDrop.dropPendingOnGround")
    local record = state.pending
    if not record or not record.item then
        Logger.traceEnd(trace, "failed", "no-pending-item")
        return false
    end

    if record.dropped then
        Logger.traceEnd(trace, "ok", "already-dropped")
        return true
    end

    if isMultiplayerClient() then
        if not sendPendingMapToServer(record) then
            Logger.traceEnd(trace, "retry", "server-send-failed")
            return false
        end
        Logger.traceEnd(trace, "pending", "waiting-for-server-drop")
        return false
    end

    local square = findDropSquare(record)
    if not square then
        Logger.warn("DeathDrop.dropPendingOnGround", "No square available yet for the annotated map", {
            deathId = record.deathId,
        })
        Logger.traceEnd(trace, "retry", "no-square")
        return false
    end

    -- Match vanilla ISDropWorldItemAction: create the world item first, then
    -- transmit that concrete object. The AddWorldInventoryItem boolean only
    -- broadcasts when this code is already running on the server.
    local addOk, addedItem = Core.tryMethod(
        square,
        "AddWorldInventoryItem",
        record.item,
        0.5,
        0.5,
        0.0,
        false
    )
    if not addOk or not addedItem then
        Logger.error("DeathDrop.dropPendingOnGround", "AddWorldInventoryItem failed", {
            deathId = record.deathId,
            returnedItem = addedItem ~= nil,
        })
        Logger.traceEnd(trace, "retry", "add-failed")
        return false
    end

    local worldObjectOk, worldObject = Core.tryMethod(addedItem, "getWorldItem")
    if worldObjectOk and worldObject then
        -- Death maps are intentional persistent loot and must not be culled by
        -- the sandbox world-item removal list.
        Core.tryMethod(worldObject, "setIgnoreRemoveSandbox", true)
        Core.tryMethod(worldObject, "transmitCompleteItemToClients")
    end

    local squareX = math.floor(getNumber(square, "getX", record.x))
    local squareY = math.floor(getNumber(square, "getY", record.y))
    record.dropped = true
    record.dropX = squareX
    record.dropY = squareY
    Logger.info("DeathDrop.dropPendingOnGround", "Annotated map dropped as a world object", {
        deathId = record.deathId,
        itemName = Core.getDeathMapName(record.characterName),
        x = squareX,
        y = squareY,
        copiedCount = record.stats and record.stats.copiedCount or 0,
        wipedPersonalMap = record.stats and record.stats.wipedPersonalMap or false,
        corpseObjectId = record.corpseObjectId,
        addedItem = addedItem ~= nil,
        transmitted = worldObject ~= nil,
    })
    Logger.traceEnd(trace, "ok", {
        x = squareX,
        y = squareY,
    })

    return true
end

local function buildSuccessSummary(record)
    return {
        deathId = record.deathId,
        x = record.dropX or record.x,
        y = record.dropY or record.y,
        copiedCount = record.stats and record.stats.copiedCount or 0,
        wipedPersonalMap = record.stats and record.stats.wipedPersonalMap or false,
        corpseTagged = record.corpseTagged == true,
        corpseObjectId = record.corpseObjectId,
    }
end

local function processPending()
    if not state.pending then
        return false
    end

    if not capturePendingMap() then
        return false
    end

    if not dropPendingOnGround() then
        return false
    end

    if tagPendingWithDeadBody() then
        local record = state.pending
        finishPending("success", buildSuccessSummary(record))
        return true
    end

    -- The user-visible result is complete. Keep the transaction alive only so
    -- delayed corpse synchronization can add the reciprocal metadata link.
    return false
end

function DeathDrop.onServerCommand(module, command, args)
    if module ~= Core.MOD_ID or command ~= "deathMapDropped" then
        return
    end

    local record = state.pending
    if not record or not args or tostring(args.deathId) ~= record.deathId then
        return
    end

    record.dropped = true
    record.dropX = tonumber(args.x) or record.x
    record.dropY = tonumber(args.y) or record.y
    sendCorpseLinkToServer(record)

    Logger.info("DeathDrop.onServerCommand", "Server confirmed annotated-map drop", {
        deathId = record.deathId,
        x = record.dropX,
        y = record.dropY,
        copiedCount = tonumber(args.copiedCount) or 0,
    })
    processPending()
end

function DeathDrop.onPlayerDeath(player)
    local bootTrace = Logger.traceStart("DeathDrop.onPlayerDeath")
    if not Core.isLocalPlayer(player) then
        Logger.traceEnd(bootTrace, "skipped", "non-local-player")
        return
    end

    Logger.beginRun("PlayerDeathMapDrop", {
        eventTick = state.tick,
    })
    Logger.traceEnd(bootTrace, "accepted")

    local trace = Logger.traceStart("DeathDrop.onPlayerDeath.run")
    local config = Core.getConfig()
    local record = buildDeathRecord(player)

    if wasCompleted(record.deathId) then
        Logger.warn("DeathDrop.onPlayerDeath", "Duplicate death event ignored", {
            deathId = record.deathId,
        })
        Logger.traceEnd(trace, "duplicate")
        Logger.finishRun("duplicate-ignored", {
            deathId = record.deathId,
        })
        return
    end

    if state.pending then
        Logger.error("DeathDrop.onPlayerDeath", "A prior death transaction was still pending", {
            abandonedDeathId = state.pending.deathId,
        })
        state.pending = nil
    end

    record.config = config
    state.pending = record

    Logger.info("DeathDrop.onPlayerDeath", "Death transaction queued for IsoDeadBody tagging", {
        deathId = record.deathId,
    })

    processPending()

    Logger.traceEnd(trace, state.pending and "pending" or "complete", {
        deathId = record.deathId,
    })
end

function DeathDrop.onTick()
    state.tick = state.tick + 1

    if state.tick % DeathDrop.RETRY_INTERVAL_TICKS ~= 0 then
        return
    end

    if not state.pending then
        return
    end

    local trace = Logger.traceStart("DeathDrop.onTick", {
        tick = state.tick,
    })

    if state.tick >= state.pending.expiresTick then
        local record = state.pending
        local deathId = record.deathId
        if record.dropped then
            Logger.warn("DeathDrop.onTick", "Annotated map was dropped, but corpse tagging timed out", {
                deathId = deathId,
                timeoutTicks = DeathDrop.PENDING_TIMEOUT_TICKS,
            })
            Logger.traceEnd(trace, "complete-untagged", deathId)
            finishPending("success-untagged", buildSuccessSummary(record))
            return
        end

        Logger.error("DeathDrop.onTick", "Timed out placing the annotated map", {
            deathId = deathId,
            timeoutTicks = DeathDrop.PENDING_TIMEOUT_TICKS,
        })
        Logger.traceEnd(trace, "timeout", deathId)
        finishPending("drop-timeout", {
            deathId = deathId,
        })
        return
    end

    processPending()
    Logger.traceEnd(trace, state.pending and "still-pending" or "complete")
end

function DeathDrop.dumpMetaTimeRunLog()
    local trace = Logger.traceStart("DeathDrop.dumpMetaTimeRunLog")
    local runId = Logger.currentRun and Logger.currentRun.id or nil
    local compiled = Logger.dumpMetaTimeRunLog(runId, "manual-dump", {
        pending = state.pending and state.pending.deathId or "none",
        tick = state.tick,
    })
    Logger.traceEnd(trace, "ok", runId)
    return compiled
end

DeadMansMap.DeathDrop = DeathDrop
DeadMansMap.DumpMetaTimeRunLog = DeathDrop.dumpMetaTimeRunLog

if Events and Events.OnPlayerDeath then
    Events.OnPlayerDeath.Add(DeathDrop.onPlayerDeath)
    Logger.info("DMM_DeathDrop", "Registered OnPlayerDeath")
else
    Logger.error("DMM_DeathDrop", "OnPlayerDeath event was unavailable")
end

if Events and Events.OnTick then
    Events.OnTick.Add(DeathDrop.onTick)
    Logger.info("DMM_DeathDrop", "Registered OnTick retry loop")
else
    Logger.error("DMM_DeathDrop", "OnTick event was unavailable")
end

if Events and Events.OnServerCommand then
    Events.OnServerCommand.Add(DeathDrop.onServerCommand)
    Logger.info("DMM_DeathDrop", "Registered OnServerCommand")
else
    Logger.warn("DMM_DeathDrop", "OnServerCommand event was unavailable")
end

Logger.info("DMM_DeathDrop", "Death-drop module loaded", {
    pendingTimeoutTicks = DeathDrop.PENDING_TIMEOUT_TICKS,
    searchRadius = DeathDrop.SEARCH_RADIUS,
    corpseDeathTimeToleranceHours = DeathDrop.CORPSE_DEATH_TIME_TOLERANCE_HOURS,
})

return DeathDrop
