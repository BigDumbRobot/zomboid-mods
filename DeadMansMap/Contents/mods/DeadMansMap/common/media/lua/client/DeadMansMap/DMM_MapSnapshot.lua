require "ISUI/Maps/ISMapDefinitions"
require "DeadMansMap/DMM_Core"

DeadMansMap = DeadMansMap or {}

local Snapshot = {}
local Core = DeadMansMap.Core
local Logger = DeadMansMap.Logger

-- Base.Map is the engine's generic writable MapItem, but it has no built-in
-- LootMaps initializer. Give death maps a full-world data source and constrain
-- the paper view to the area containing their annotations.
--
-- This callback runs whenever a player opens an Annotated Map. Every engine call
-- here is unguarded vanilla API, so a single failure (a future API change, a
-- missing MapUtils helper) would otherwise throw a red error box on the player
-- who opened the map. Keep the whole body inside pcall and fall back to a plain
-- full-world view so the map still opens.
local function initDeathMap(mapUI)
    local mapAPI = mapUI.javaObject:getAPIv1()
    MapUtils.initDefaultMapData(mapUI)
    mapAPI:setBoundsFromWorld()

    local worldMinX = mapAPI:getMinXInSquares()
    local worldMinY = mapAPI:getMinYInSquares()
    local worldMaxX = mapAPI:getMaxXInSquares()
    local worldMaxY = mapAPI:getMaxYInSquares()
    local mapItem = mapUI.mapObj or mapUI.mapItem
    local modData = mapItem and mapItem:getModData() or nil
    local padding = 150
    local minX = modData and tonumber(modData.DMM_MapMinX) or nil
    local minY = modData and tonumber(modData.DMM_MapMinY) or nil
    local maxX = modData and tonumber(modData.DMM_MapMaxX) or nil
    local maxY = modData and tonumber(modData.DMM_MapMaxY) or nil

    if not (minX and minY and maxX and maxY) then
        local deathX = modData and tonumber(modData.DMM_DeathX) or nil
        local deathY = modData and tonumber(modData.DMM_DeathY) or nil
        if deathX and deathY then
            minX, minY = deathX, deathY
            maxX, maxY = deathX, deathY
            padding = 300
        end
    end

    if minX and minY and maxX and maxY then
        local x1 = math.max(worldMinX, math.floor(minX - padding))
        local y1 = math.max(worldMinY, math.floor(minY - padding))
        local x2 = math.min(worldMaxX, math.ceil(maxX + padding))
        local y2 = math.min(worldMaxY, math.ceil(maxY + padding))
        if x2 > x1 and y2 > y1 then
            mapAPI:setBoundsInSquares(x1, y1, x2, y2)
        end
    end

    MapUtils.initDefaultStyleV3(mapUI)
    MapUtils.overlayPaper(mapUI)
end

local function initDeathMapFallback(mapUI)
    -- Minimal vanilla full-world paper map: no custom bounds, no mod data.
    local mapAPI = mapUI.javaObject:getAPIv1()
    MapUtils.initDefaultMapData(mapUI)
    mapAPI:setBoundsFromWorld()
    MapUtils.initDefaultStyleV3(mapUI)
    MapUtils.overlayPaper(mapUI)
end

LootMaps.Init[Core.MAP_ID] = function(mapUI)
    local ok, err = pcall(initDeathMap, mapUI)
    if ok then
        return
    end

    Logger.error("LootMaps.Init", "Annotated Map init failed; using plain full-world fallback", {
        mapId = Core.MAP_ID,
        error = err,
    })

    local fallbackOk, fallbackErr = pcall(initDeathMapFallback, mapUI)
    if not fallbackOk then
        Logger.error("LootMaps.Init", "Annotated Map fallback init also failed", {
            mapId = Core.MAP_ID,
            error = fallbackErr,
        })
    end
end

local function createPhysicalMap()
    local trace = Logger.traceStart("Snapshot.createPhysicalMap")
    local item = nil

    if instanceItem then
        local ok, result = pcall(instanceItem, "Base.Map")
        if ok then
            item = result
        else
            Logger.warn("Snapshot.createPhysicalMap", "instanceItem failed", result)
        end
    end

    if not item and InventoryItemFactory then
        local ok, result = pcall(function()
            return InventoryItemFactory.CreateItem("Base.Map")
        end)
        if ok then
            item = result
        else
            Logger.error("Snapshot.createPhysicalMap", "InventoryItemFactory failed", result)
        end
    end

    if item then
        Core.tryMethod(item, "setMapID", Core.MAP_ID)
    end

    Logger.traceEnd(trace, item and "ok" or "failed")
    return item
end

-- Reads every user annotation off a symbols API into plain Lua tables, and
-- tracks the bounding box + counts. Pure data: safe to hold across the wipe.
local function serializeAll(sourceAPI, safetyMax)
    local trace = Logger.traceStart("Snapshot.serializeAll", { safetyMax = safetyMax })
    local countOk, rawCount = Core.tryMethod(sourceAPI, "getSymbolCount")
    if not countOk then
        Logger.error("Snapshot.serializeAll", "Unable to count personal-map annotations")
        Logger.traceEnd(trace, "failed", "count-unavailable")
        return nil, nil
    end

    local sourceCount = math.max(0, math.floor(tonumber(rawCount) or 0))
    local list = {}
    local stats = {
        sourceCount = sourceCount,
        copiedCount = 0,
        skippedCount = 0,
        failedCount = 0,
        capReached = false,
        minX = nil,
        minY = nil,
        maxX = nil,
        maxY = nil,
    }

    for index = 0, sourceCount - 1 do
        if #list >= safetyMax then
            stats.skippedCount = stats.skippedCount + (sourceCount - index)
            stats.capReached = true
            Logger.warn("Snapshot.serializeAll", "Internal safety cap reached", {
                safetyMax = safetyMax,
                sourceCount = sourceCount,
            })
            break
        end

        local symbolOk, symbol = Core.tryMethod(sourceAPI, "getSymbolByIndex", index)
        if not symbolOk or not symbol then
            stats.failedCount = stats.failedCount + 1
        else
            local data = Core.serializeMapSymbol(symbol)
            if not data then
                stats.skippedCount = stats.skippedCount + 1
            else
                table.insert(list, data)
                if data.x == data.x and data.y == data.y then
                    stats.minX = stats.minX and math.min(stats.minX, data.x) or data.x
                    stats.minY = stats.minY and math.min(stats.minY, data.y) or data.y
                    stats.maxX = stats.maxX and math.max(stats.maxX, data.x) or data.x
                    stats.maxY = stats.maxY and math.max(stats.maxY, data.y) or data.y
                end
            end
        end
    end

    stats.copiedCount = #list
    Logger.info("Snapshot.serializeAll", "Personal annotations captured", stats)
    Logger.traceEnd(trace, "ok", stats)
    return list, stats
end

-- Writes serialized annotations onto a fresh death-map symbols API.
local function rebuildAll(destinationAPI, serializedSymbols)
    local trace = Logger.traceStart("Snapshot.rebuildAll", {
        count = serializedSymbols and #serializedSymbols or 0,
    })
    local written = 0
    local failed = 0
    for _, data in ipairs(serializedSymbols or {}) do
        if Core.rebuildMapSymbol(destinationAPI, data) then
            written = written + 1
        else
            failed = failed + 1
            Logger.warn("Snapshot.rebuildAll", "Annotation could not be recreated", {
                symbolType = data.symbolType,
                x = data.x,
                y = data.y,
            })
        end
    end
    Logger.traceEnd(trace, "ok", { written = written, failed = failed })
    return written, failed
end

local function enforcePersonalMapWipe(sourceAPI, record, stats)
    local wiped, removed = Core.wipeUserAnnotations(sourceAPI)
    record.wipedPersonalMap = wiped

    if stats then
        stats.wipedPersonalMap = wiped
        stats.wipedCount = removed
    end

    if not wiped then
        Logger.error("Snapshot.enforcePersonalMapWipe", "Mandatory personal-map wipe was incomplete", {
            deathId = record.deathId,
            removed = removed,
        })
    else
        Logger.info("Snapshot.enforcePersonalMapWipe", "Personal map annotations wiped", {
            deathId = record.deathId,
            removed = removed,
        })
    end

    return wiped, removed
end

-- Produces the dropped Annotated Map item for a death.
--
-- Order is fixed: read the personal map into plain data, THEN wipe it, THEN
-- build the death map from that data. The wipe is an invariant of the mod, so
-- once the personal-map API is in hand every path wipes before returning --
-- a failure to build the physical map must not leave the markings behind.
function Snapshot.createDeathMap(player, record, config)
    local trace = Logger.traceStart("Snapshot.createDeathMap", {
        deathId = record and record.deathId,
    })

    if not player or not record then
        Logger.error("Snapshot.createDeathMap", "Capture request was missing player or death data")
        Logger.traceEnd(trace, "failed", "invalid-input")
        return nil, nil
    end

    config = config or Core.getConfig()
    local safetyMax = math.max(1, math.floor(
        tonumber(config.SafetyMaxAnnotations) or Core.SAFETY_MAX_ANNOTATIONS
    ))

    local sourceMap = MapItem and MapItem.getSingleton and MapItem.getSingleton() or nil
    if not sourceMap then
        Logger.error("Snapshot.createDeathMap", "The personal MapItem singleton was unavailable")
        Logger.traceEnd(trace, "failed", "no-personal-map")
        return nil, nil
    end

    local sourceAPI = Core.openMapSymbols(sourceMap)
    if not sourceAPI then
        -- Nothing can be done without a symbols API: no capture, no wipe.
        Logger.traceEnd(trace, "failed", "source-symbols-api")
        return nil, nil
    end

    -- 1. Capture to plain data.
    local serializedSymbols, stats = serializeAll(sourceAPI, safetyMax)
    if not serializedSymbols then
        -- Still enforce the wipe before bailing.
        enforcePersonalMapWipe(sourceAPI, record, nil)
        Logger.traceEnd(trace, "failed", "serialize")
        return nil, nil
    end
    record.stats = stats

    -- 2. Wipe the personal map and flush it.
    enforcePersonalMapWipe(sourceAPI, record, stats)

    -- 3. Build the death map from the captured data.
    local destinationMap = createPhysicalMap()
    if not destinationMap then
        Logger.error("Snapshot.createDeathMap", "Unable to create Base.Map")
        Logger.traceEnd(trace, "failed", "no-destination-map")
        return nil, stats, serializedSymbols
    end

    local destinationAPI = Core.openMapSymbols(destinationMap)
    if not destinationAPI then
        Logger.error("Snapshot.createDeathMap", "Unable to open death-map symbols API")
        Logger.traceEnd(trace, "failed", "destination-symbols-api")
        return nil, stats, serializedSymbols
    end

    local written = rebuildAll(destinationAPI, serializedSymbols)
    stats.copiedCount = written

    if not Core.tagDeathMap(destinationMap, record, written, stats.sourceCount) then
        Logger.traceEnd(trace, "failed", "tagging")
        return nil, stats, serializedSymbols
    end

    Logger.info("Snapshot.createDeathMap", "Death map snapshot created", {
        deathId = record.deathId,
        copiedCount = written,
        wipedPersonalMap = stats.wipedPersonalMap,
    })
    Logger.traceEnd(trace, "ok", stats)
    return destinationMap, stats, serializedSymbols
end

DeadMansMap.Snapshot = Snapshot

Logger.info("DMM_MapSnapshot", "Map snapshot module loaded")

return Snapshot
