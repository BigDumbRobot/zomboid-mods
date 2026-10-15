require "DeadMansMap/DMM_Logger"

DeadMansMap = DeadMansMap or {}

local Core = {}
local Logger = DeadMansMap.Logger

Core.VERSION = "1.5.0"
Core.MOD_ID = "DeadMansMap"
Core.MAP_ID = "DeadMansMap"
Core.ITEM_VERSION = 3

-- Non-configurable guard so a drawing mod that produced tens of thousands of
-- tiny symbols cannot create an oversized item/player save. The death map is
-- meant to contain every note and symbol, so this is set well above any
-- realistic hand-annotated map.
Core.SAFETY_MAX_ANNOTATIONS = 5000

Core.DEFAULT_CONFIG = {
    DebugLogging = false,
}

local function copyDefaults()
    local copied = {}
    for key, value in pairs(Core.DEFAULT_CONFIG) do
        copied[key] = value
    end
    return copied
end

function Core.getConfig()
    local trace = Logger.traceStart("Core.getConfig")
    local config = copyDefaults()
    local sandbox = SandboxVars and SandboxVars.DeadMansMap or nil

    if sandbox then
        for key in pairs(config) do
            if sandbox[key] ~= nil then
                config[key] = sandbox[key]
            end
        end
    end

    config.SafetyMaxAnnotations = Core.SAFETY_MAX_ANNOTATIONS

    Logger.setDebugConsoleEnabled(config.DebugLogging == true)
    Logger.traceEnd(trace, "ok", config)
    return config
end

function Core.tryMethod(target, methodName, ...)
    if not target then
        Logger.debug("Core.tryMethod", "Guarded method skipped because target was nil", {
            method = methodName,
        })
        return false, nil
    end

    local args = { ... }
    local ok, result = pcall(function()
        local method = target[methodName]
        if not method then
            error("method unavailable: " .. tostring(methodName))
        end
        return method(target, unpack(args))
    end)

    if not ok then
        Logger.debug("Core.tryMethod", "Optional method call failed", {
            method = methodName,
            error = result,
        })
        return false, nil
    end

    return true, result
end

function Core.getCharacterName(player)
    local trace = Logger.traceStart("Core.getCharacterName")
    local name = nil

    local descriptorOk, descriptor = Core.tryMethod(player, "getDescriptor")
    if descriptorOk and descriptor then
        local forenameOk, forename = Core.tryMethod(descriptor, "getForename")
        local surnameOk, surname = Core.tryMethod(descriptor, "getSurname")
        local parts = {}

        if forenameOk and forename and tostring(forename) ~= "" then
            table.insert(parts, tostring(forename))
        end
        if surnameOk and surname and tostring(surname) ~= "" then
            table.insert(parts, tostring(surname))
        end
        if #parts > 0 then
            name = table.concat(parts, " ")
        end
    end

    if not name then
        local displayOk, displayName = Core.tryMethod(player, "getDisplayName")
        if displayOk and displayName and tostring(displayName) ~= "" then
            name = tostring(displayName)
        end
    end

    if not name then
        local usernameOk, username = Core.tryMethod(player, "getUsername")
        if usernameOk and username and tostring(username) ~= "" then
            name = tostring(username)
        end
    end

    name = name or "Unknown Survivor"
    Logger.traceEnd(trace, "ok", name)
    return name
end

function Core.getDeathMapName(characterName)
    local trace = Logger.traceStart("Core.getDeathMapName", characterName)
    local name = tostring(characterName or "Unknown Survivor") .. "'s Annotated Map"
    Logger.traceEnd(trace, "ok", name)
    return name
end

function Core.getWorldAgeHours()
    local trace = Logger.traceStart("Core.getWorldAgeHours")
    local age = 0

    if getGameTime then
        local ok, gameTime = pcall(getGameTime)
        if ok and gameTime then
            local ageOk, value = Core.tryMethod(gameTime, "getWorldAgeHours")
            if ageOk and value then
                age = tonumber(value) or 0
            end
        end
    end

    Logger.traceEnd(trace, "ok", age)
    return age
end

function Core.isLocalPlayer(player)
    local trace = Logger.traceStart("Core.isLocalPlayer")
    if not player then
        Logger.traceEnd(trace, "false", "no-player")
        return false
    end

    local playerNumOk, playerNum = Core.tryMethod(player, "getPlayerNum")
    if playerNumOk and getSpecificPlayer then
        local ok, localPlayer = pcall(getSpecificPlayer, playerNum)
        if ok and localPlayer then
            local result = localPlayer == player
            Logger.traceEnd(trace, tostring(result), {
                playerNum = playerNum,
            })
            return result
        end
    end

    Logger.traceEnd(trace, "true", "single-player-fallback")
    return true
end

function Core.makeDeathId(player, characterName)
    local trace = Logger.traceStart("Core.makeDeathId", characterName)
    local onlineId = -1
    local onlineOk, onlineValue = Core.tryMethod(player, "getOnlineID")
    if onlineOk and onlineValue then
        onlineId = tonumber(onlineValue) or -1
    end

    local xOk, xValue = Core.tryMethod(player, "getX")
    local yOk, yValue = Core.tryMethod(player, "getY")
    local zOk, zValue = Core.tryMethod(player, "getZ")
    local x = math.floor(xOk and tonumber(xValue) or 0)
    local y = math.floor(yOk and tonumber(yValue) or 0)
    local z = math.floor(zOk and tonumber(zValue) or 0)
    local worldTicks = math.floor(Core.getWorldAgeHours() * 3600000)
    local nameHash = 0

    for index = 1, #characterName do
        nameHash = (nameHash * 31 + string.byte(characterName, index)) % 1000000
    end

    local deathId = string.format(
        "%d-%d-%d-%d-%d-%06d",
        onlineId,
        x,
        y,
        z,
        worldTicks,
        nameHash
    )

    Logger.traceEnd(trace, "ok", deathId)
    return deathId
end

function Core.tagDeathMap(item, record, copiedCount, sourceCount)
    local trace = Logger.traceStart("Core.tagDeathMap", {
        deathId = record and record.deathId,
        copiedCount = copiedCount,
    })

    if not item or not record then
        Logger.traceEnd(trace, "invalid", "missing-item-or-record")
        return false
    end

    local name = Core.getDeathMapName(record.characterName)
    Core.tryMethod(item, "setName", name)
    Core.tryMethod(item, "setCustomName", true)

    local modDataOk, modData = Core.tryMethod(item, "getModData")
    if not modDataOk or not modData then
        Logger.error("Core.tagDeathMap", "Unable to access map mod data", {
            deathId = record.deathId,
        })
        Logger.traceEnd(trace, "failed", "no-mod-data")
        return false
    end

    modData.DMM_IsDeathMap = true
    modData.DMM_ItemVersion = Core.ITEM_VERSION
    modData.DMM_DeathId = record.deathId
    modData.DMM_OwnerName = record.characterName
    modData.DMM_CopiedCount = copiedCount or 0
    modData.DMM_SourceCount = sourceCount or 0
    modData.DMM_MapMinX = record.stats and record.stats.minX or nil
    modData.DMM_MapMinY = record.stats and record.stats.minY or nil
    modData.DMM_MapMaxX = record.stats and record.stats.maxX or nil
    modData.DMM_MapMaxY = record.stats and record.stats.maxY or nil
    modData.DMM_WipedPersonalMap = record.wipedPersonalMap == true
    modData.DMM_DeathX = record.x or 0
    modData.DMM_DeathY = record.y or 0
    modData.DMM_DeathZ = record.z or 0
    modData.DMM_DeathWorldAgeHours = record.worldAgeHours or 0
    modData.DMM_CorpseTagged = false

    Logger.info("Core.tagDeathMap", "Death map tagged", {
        deathId = record.deathId,
        name = name,
        copiedCount = copiedCount,
        sourceCount = sourceCount,
    })
    Logger.traceEnd(trace, "ok", record.deathId)
    return true
end

-- Cross-links a death map with the engine's persistent representation of the
-- dead player. The map remains a loose world item that can be traced to the
-- exact IsoDeadBody, not just a name and coordinates.
function Core.tagDeathMapWithDeadBody(item, deadBody, record)
    local trace = Logger.traceStart("Core.tagDeathMapWithDeadBody", {
        deathId = record and record.deathId,
    })

    if not item or not deadBody or not record then
        Logger.traceEnd(trace, "invalid", "missing-item-body-or-record")
        return false
    end

    local playerOk, isPlayerBody = Core.tryMethod(deadBody, "isPlayer")
    if not playerOk or isPlayerBody ~= true then
        Logger.warn("Core.tagDeathMapWithDeadBody", "Refused to tag a non-player corpse", {
            deathId = record.deathId,
        })
        Logger.traceEnd(trace, "failed", "not-player-corpse")
        return false
    end

    local itemDataOk, itemData = Core.tryMethod(item, "getModData")
    local bodyDataOk, bodyData = Core.tryMethod(deadBody, "getModData")
    if not itemDataOk or not itemData or not bodyDataOk or not bodyData then
        Logger.error("Core.tagDeathMapWithDeadBody", "Unable to access map or corpse mod data", {
            deathId = record.deathId,
            itemData = itemData ~= nil,
            bodyData = bodyData ~= nil,
        })
        Logger.traceEnd(trace, "failed", "no-mod-data")
        return false
    end

    local objectIdOk, objectId = Core.tryMethod(deadBody, "getObjectIDAsLong")
    local onlineIdOk, onlineId = Core.tryMethod(deadBody, "getCharacterOnlineID")
    local deathTimeOk, deathTime = Core.tryMethod(deadBody, "getDeathTime")
    local corpseObjectId = objectIdOk and objectId ~= nil and tostring(objectId) or ""
    local corpseOnlineId = onlineIdOk and tonumber(onlineId) or -1
    local corpseDeathTime = deathTimeOk and tonumber(deathTime) or record.worldAgeHours or 0
    local mapName = Core.getDeathMapName(record.characterName)

    itemData.DMM_CorpseTagged = true
    itemData.DMM_CorpseObjectId = corpseObjectId
    itemData.DMM_CorpseCharacterOnlineId = corpseOnlineId
    itemData.DMM_CorpseDeathTime = corpseDeathTime

    bodyData.DMM_HasDeathMap = true
    bodyData.DMM_DeathMapId = record.deathId
    bodyData.DMM_DeathMapName = mapName
    bodyData.DMM_DeathMapOwnerName = record.characterName
    bodyData.DMM_DeathMapItemVersion = Core.ITEM_VERSION
    bodyData.DMM_DeathMapCopiedCount = itemData.DMM_CopiedCount or 0
    bodyData.DMM_DeathMapSourceCount = itemData.DMM_SourceCount or 0

    record.corpseObjectId = corpseObjectId
    record.corpseCharacterOnlineId = corpseOnlineId
    record.corpseDeathTime = corpseDeathTime

    -- IsoDeadBody inherits IsoObject's mod-data transmitter. In single-player
    -- this is harmless; in multiplayer it publishes the reciprocal corpse tag.
    Core.tryMethod(deadBody, "transmitModData")

    Logger.info("Core.tagDeathMapWithDeadBody", "Death map linked to player corpse", {
        deathId = record.deathId,
        corpseObjectId = corpseObjectId,
        corpseCharacterOnlineId = corpseOnlineId,
        corpseDeathTime = corpseDeathTime,
    })
    Logger.traceEnd(trace, "ok", corpseObjectId)
    return true
end

-- ==========================================================================
-- Map-symbol access
--
-- MapItem:getSymbols() is @HiddenFromLua and cannot be called from Lua. The
-- only Lua-legal way to read or mutate a MapItem's annotations is to bind a
-- detached UIWorldMap to it and go through getSymbolsAPIv2() -- a
-- WorldMapSymbolsV2 that wraps the item's real WorldMapSymbols, so mutations
-- through it hit the item. This is the same pattern vanilla uses in
-- ISWorldMap:getStashMapBounds().
--
-- The returned V2 API keeps the detached UIWorldMap alive through the engine
-- object graph (the item's WorldMapSymbols holds a listener -> V2 -> UIWorldMap),
-- so the caller does not need to retain anything. For the personal-map
-- singleton this leaves one inert listener per call; deaths are rare enough
-- that this is not worth pooling a reader for.
-- ==========================================================================

function Core.getValue(target, getter, fallback)
    local ok, value = Core.tryMethod(target, getter)
    if ok and value ~= nil then
        return value
    end
    return fallback
end

local function symbolCount(api)
    local ok, value = Core.tryMethod(api, "getSymbolCount")
    if not ok then
        return 0
    end
    return math.max(0, math.floor(tonumber(value) or 0))
end

-- Opens a WorldMapSymbolsV2 (or V1) bound to mapItem's real symbols.
function Core.openMapSymbols(mapItem)
    local trace = Logger.traceStart("Core.openMapSymbols")
    if not mapItem then
        Logger.traceEnd(trace, "failed", "no-map-item")
        return nil
    end
    if not UIWorldMap then
        Logger.error("Core.openMapSymbols", "UIWorldMap global is unavailable")
        Logger.traceEnd(trace, "failed", "no-uiworldmap")
        return nil
    end

    local ok, api = pcall(function()
        local proxy = {}
        proxy.javaObject = UIWorldMap.new(proxy)
        local mapAPI = proxy.javaObject:getAPIv3()
        mapAPI:setMapItem(mapItem)

        local symbolsAPI = nil
        local v2ok, v2 = Core.tryMethod(mapAPI, "getSymbolsAPIv2")
        if v2ok and v2 then
            symbolsAPI = v2
        else
            local v1ok, v1 = Core.tryMethod(mapAPI, "getSymbolsAPI")
            if v1ok and v1 then
                symbolsAPI = v1
            end
        end
        if not symbolsAPI then
            error("UIWorldMap exposed no symbols API")
        end
        return symbolsAPI
    end)

    if not ok or not api then
        Logger.error("Core.openMapSymbols", "Could not open a symbols API for the map item", {
            error = ok and "nil-api" or api,
        })
        Logger.traceEnd(trace, "failed", ok and "nil-api" or api)
        return nil
    end

    Logger.traceEnd(trace, "ok")
    return api
end

-- Serializes one WorldMapSymbolsV2 symbol to a plain table, or nil if it is
-- not a user-drawn text/texture annotation this mod can recreate.
function Core.serializeMapSymbol(symbol)
    if not symbol then
        return nil
    end
    if Core.getValue(symbol, "isUserDefined", true) ~= true then
        return nil -- skip engine default map labels
    end

    local isText = Core.getValue(symbol, "isText", false) == true
    local isTexture = Core.getValue(symbol, "isTexture", false) == true
    if not isText and not isTexture then
        return nil
    end

    local data = {
        symbolType = isText and "text" or "texture",
        x = tonumber(Core.getValue(symbol, "getWorldX", 0)) or 0,
        y = tonumber(Core.getValue(symbol, "getWorldY", 0)) or 0,
        red = tonumber(Core.getValue(symbol, "getRed", 0)) or 0,
        green = tonumber(Core.getValue(symbol, "getGreen", 0)) or 0,
        blue = tonumber(Core.getValue(symbol, "getBlue", 0)) or 0,
        alpha = tonumber(Core.getValue(symbol, "getAlpha", 1)) or 1,
        anchorX = tonumber(Core.getValue(symbol, "getAnchorX", 0.5)) or 0.5,
        anchorY = tonumber(Core.getValue(symbol, "getAnchorY", 0.5)) or 0.5,
        scale = tonumber(Core.getValue(symbol, "getScale", 1.0)) or 1.0,
        rotation = tonumber(Core.getValue(symbol, "getRotation", 0)) or 0,
        matchPerspective = Core.getValue(symbol, "isMatchPerspective", false) == true,
        applyZoom = Core.getValue(symbol, "isApplyZoom", false) == true,
        minZoom = tonumber(Core.getValue(symbol, "getMinZoom", 0)) or 0,
        maxZoom = tonumber(Core.getValue(symbol, "getMaxZoom", 24)) or 24,
        visible = Core.getValue(symbol, "isVisible", true) == true,
        userDefined = true,
    }

    if isText then
        local untranslated = Core.getValue(symbol, "getUntranslatedText", nil)
        local translated = Core.getValue(symbol, "getTranslatedText", nil)
        if untranslated ~= nil and tostring(untranslated) ~= "" then
            data.text = tostring(untranslated)
            data.textKind = "untranslated"
        elseif translated ~= nil and tostring(translated) ~= "" then
            data.text = tostring(translated)
            data.textKind = "translated"
        else
            return nil
        end
        local layer = Core.getValue(symbol, "getLayerID", nil)
        data.layerId = layer and tostring(layer) or nil
    else
        local symbolId = Core.getValue(symbol, "getSymbolID", nil)
        if not symbolId or tostring(symbolId) == "" then
            return nil
        end
        data.symbolId = tostring(symbolId)
    end

    return data
end

-- Recreates a serialized symbol on a destination WorldMapSymbolsV2 API.
-- The V2 add* methods take fewer args than the raw WorldMapSymbols ones
-- (text: text/layer/x/y; texture: id/x/y), so colour and the rest are applied
-- afterwards with setters.
function Core.rebuildMapSymbol(api, data)
    if not api or not data then
        return nil
    end

    local created = nil
    if data.symbolType == "text" then
        local layerId = data.layerId
        if not layerId or layerId == "" then
            layerId = Core.getValue(api, "getDefaultTextLayerID", nil)
                or Core.getValue(api, "getDefaultLayerID", nil)
                or "text-note"
        end
        local method = (data.textKind == "untranslated")
            and "addUntranslatedText" or "addTranslatedText"
        local ok, symbol = Core.tryMethod(
            api, method, tostring(data.text or ""), tostring(layerId), data.x, data.y
        )
        if ok then
            created = symbol
        end
    elseif data.symbolType == "texture" then
        local ok, symbol = Core.tryMethod(
            api, "addTexture", tostring(data.symbolId or ""), data.x, data.y
        )
        if ok then
            created = symbol
        end
    end

    if not created then
        return nil
    end

    Core.tryMethod(created, "setRGBA", data.red or 0, data.green or 0, data.blue or 0, data.alpha or 1)
    Core.tryMethod(created, "setAnchor", data.anchorX or 0.5, data.anchorY or 0.5)
    Core.tryMethod(created, "setScale", data.scale or 1.0)
    Core.tryMethod(created, "setRotation", data.rotation or 0)
    Core.tryMethod(created, "setMatchPerspective", data.matchPerspective == true)
    Core.tryMethod(created, "setApplyZoom", data.applyZoom == true)
    Core.tryMethod(created, "setMinZoom", data.minZoom or 0)
    Core.tryMethod(created, "setMaxZoom", data.maxZoom or 24)
    Core.tryMethod(created, "setVisible", data.visible ~= false)
    -- Must stay user-defined: WorldMapSymbols.save() only persists
    -- isUserDefined() && getNetworkInfo()==nil symbols with the item.
    Core.tryMethod(created, "setUserDefined", true)
    return created
end

-- Flushes the personal map to map_symbols.bin. Shared by every path that
-- mutates MapItem.getSingleton()'s symbols (the mandatory death-map wipe and
-- the reverse copy-in merge below).
function Core.saveWorldMap()
    if not (MapItem and MapItem.SaveWorldMap) then
        return false
    end
    local saveOk, saveErr = pcall(MapItem.SaveWorldMap)
    if not saveOk then
        Logger.warn("Core.saveWorldMap", "MapItem.SaveWorldMap failed", {
            error = saveErr,
        })
        return false
    end
    return true
end

-- Removes every user-drawn annotation from a personal-map symbols API and
-- flushes the personal map to map_symbols.bin. Mirrors vanilla's "Forget map"
-- button (WorldMapSymbolsV2:clearUserAnnotations), with a manual fallback.
-- Returns (fullyWiped, removedCount).
function Core.wipeUserAnnotations(api)
    local trace = Logger.traceStart("Core.wipeUserAnnotations")
    if not api then
        Logger.traceEnd(trace, "failed", "no-api")
        return false, 0
    end

    local before = symbolCount(api)
    local cleared = Core.tryMethod(api, "clearUserAnnotations")

    if not cleared then
        -- Fallback: walk the list and remove user-defined symbols by hand.
        local n = symbolCount(api)
        local index = 0
        while index < n do
            local ok, symbol = Core.tryMethod(api, "getSymbolByIndex", index)
            if ok and symbol and Core.getValue(symbol, "isUserDefined", false) == true then
                Core.tryMethod(api, "removeSymbolByIndex", index)
                n = n - 1
            else
                index = index + 1
            end
        end
        if n > 0 then
            -- Last resort: nuke everything (default labels get regenerated).
            Core.tryMethod(api, "clear")
        end
    end

    local remainingUser = 0
    local after = symbolCount(api)
    for index = 0, after - 1 do
        local ok, symbol = Core.tryMethod(api, "getSymbolByIndex", index)
        if ok and symbol and Core.getValue(symbol, "isUserDefined", false) == true then
            remainingUser = remainingUser + 1
        end
    end

    Core.saveWorldMap()

    local fullyWiped = remainingUser == 0
    Logger.traceEnd(trace, fullyWiped and "ok" or "partial", {
        before = before,
        remainingUser = remainingUser,
    })
    return fullyWiped, math.max(0, before - after)
end

-- Builds a dedup key for a serialized symbol: type + rounded position + its
-- content (text or texture id). Used only to skip re-adding a marking that is
-- already on the destination map, so float jitter in world coordinates is
-- deliberately rounded away rather than compared exactly.
local function symbolSignature(data)
    if not data then
        return nil
    end
    local x = math.floor((data.x or 0) + 0.5)
    local y = math.floor((data.y or 0) + 0.5)
    if data.symbolType == "text" then
        return string.format("text:%d:%d:%s", x, y, tostring(data.text or ""))
    elseif data.symbolType == "texture" then
        return string.format("texture:%d:%d:%s", x, y, tostring(data.symbolId or ""))
    end
    return nil
end

-- Copies every user-drawn annotation from sourceMapItem onto destMapItem --
-- the reverse of the death-drop capture path (personal map -> death map),
-- run personal map <- found map instead, using the same serialize/rebuild
-- primitives. Markings already present on the destination at the same
-- position with the same content are skipped, and the destination is never
-- grown past options.safetyMax total annotations.
--
-- Returns a result table: { ok, sourceCount, existingCount, addedCount,
-- duplicateCount, skippedCount, failedCount, capReached }. ok is false only
-- when the merge could not run at all (missing item or symbols API); a
-- partial merge (e.g. capReached) still reports ok = true.
function Core.mergeMapSymbols(sourceMapItem, destMapItem, options)
    local trace = Logger.traceStart("Core.mergeMapSymbols")
    options = options or {}
    local safetyMax = math.max(1, math.floor(
        tonumber(options.safetyMax) or Core.SAFETY_MAX_ANNOTATIONS
    ))

    local result = {
        ok = false,
        sourceCount = 0,
        existingCount = 0,
        addedCount = 0,
        duplicateCount = 0,
        skippedCount = 0,
        failedCount = 0,
        capReached = false,
    }

    if not sourceMapItem or not destMapItem then
        Logger.traceEnd(trace, "failed", "missing-map-item")
        return result
    end

    local sourceAPI = Core.openMapSymbols(sourceMapItem)
    local destAPI = Core.openMapSymbols(destMapItem)
    if not sourceAPI or not destAPI then
        Logger.traceEnd(trace, "failed", "no-symbols-api")
        return result
    end

    local seen = {}
    local destCount = symbolCount(destAPI)
    result.existingCount = destCount
    for index = 0, destCount - 1 do
        local ok, symbol = Core.tryMethod(destAPI, "getSymbolByIndex", index)
        if ok and symbol then
            local key = symbolSignature(Core.serializeMapSymbol(symbol))
            if key then
                seen[key] = true
            end
        end
    end

    local sourceCount = symbolCount(sourceAPI)
    result.sourceCount = sourceCount
    local budget = safetyMax - destCount

    for index = 0, sourceCount - 1 do
        local ok, symbol = Core.tryMethod(sourceAPI, "getSymbolByIndex", index)
        if not ok or not symbol then
            result.failedCount = result.failedCount + 1
        else
            local data = Core.serializeMapSymbol(symbol)
            if not data then
                result.skippedCount = result.skippedCount + 1
            else
                local key = symbolSignature(data)
                if key and seen[key] then
                    result.duplicateCount = result.duplicateCount + 1
                elseif budget <= 0 then
                    result.capReached = true
                    result.skippedCount = result.skippedCount + 1
                elseif Core.rebuildMapSymbol(destAPI, data) then
                    result.addedCount = result.addedCount + 1
                    budget = budget - 1
                    if key then
                        seen[key] = true
                    end
                else
                    result.failedCount = result.failedCount + 1
                end
            end
        end
    end

    if result.addedCount > 0 then
        Core.saveWorldMap()
    end

    result.ok = true
    Logger.info("Core.mergeMapSymbols", "Merged annotations onto destination map", result)
    Logger.traceEnd(trace, "ok", result)
    return result
end

DeadMansMap.Core = Core

Logger.info("DMM_Core", "Core loaded", {
    version = Core.VERSION,
    modId = Core.MOD_ID,
})

return Core
