-- KIPN_EventHotspotService.lua
--
-- Server-authoritative hotspot validation, persistence helpers, and network
-- commands for Event Scenarios. Hotspots live on the persisted Event
-- Definition; this service owns their schema so runtime modules never invent
-- their own coordinate formats.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_AdminService"
require "KIPN_EventAccessService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventHotspotService = KIPN.Server.EventHotspotService or {}

local Service = KIPN.Server.EventHotspotService
local MAX_HOTSPOTS = 64
local MAX_HILL_HOTSPOTS = 10

local function log(message)
    print("[KIPN EVENT HOTSPOT] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT HOTSPOT] ERROR: " .. tostring(message))
end

local function getWorldDays()
    local ok, result = pcall(function() return getGameTime():getWorldAgeHours() / 24 end)
    local value = ok and result or 0
    log("getWorldDays() -> " .. tostring(value))
    return value
end

local function requireAdmin(player)
    -- Admins, and staff levels the sandbox allows (KIPN_EventAccessService.lua).
    local allowed = KIPN.Server.EventAccessService.RequireStudio(player)
    log("requireAdmin() -> " .. tostring(allowed))
    return allowed
end

local function trim(value)
    local result = type(value) == "string" and value:match("^%s*(.-)%s*$") or ""
    return result
end

local function normalizeGeometry(raw)
    if type(raw) ~= "table" then
        log("normalizeGeometry() -> INVALID_GEOMETRY")
        return nil, "INVALID_GEOMETRY"
    end

    local x1 = tonumber(raw.x1 or raw.x)
    local y1 = tonumber(raw.y1 or raw.y)
    local x2 = tonumber(raw.x2 or raw.x or raw.x1)
    local y2 = tonumber(raw.y2 or raw.y or raw.y1)
    local z1 = tonumber(raw.z1 or raw.z) or 0
    local z2 = tonumber(raw.z2 or raw.z or raw.z1) or z1

    if not x1 or not y1 or not x2 or not y2 then
        log("normalizeGeometry() -> INVALID_COORDINATES")
        return nil, "INVALID_COORDINATES"
    end

    local geometry = {
        x1 = math.floor(math.min(x1, x2)),
        y1 = math.floor(math.min(y1, y2)),
        x2 = math.floor(math.max(x1, x2)),
        y2 = math.floor(math.max(y1, y2)),
        z1 = math.floor(math.min(z1, z2)),
        z2 = math.floor(math.max(z1, z2)),
    }

    log(
        "normalizeGeometry() -> (" .. tostring(geometry.x1) .. ","
        .. tostring(geometry.y1) .. "," .. tostring(geometry.z1) .. ")-("
        .. tostring(geometry.x2) .. "," .. tostring(geometry.y2) .. ","
        .. tostring(geometry.z2) .. ")"
    )
    return geometry
end

local function generateHotspotId(definitionId)
    local now = type(getTimestampMs) == "function" and getTimestampMs() or 0
    local id = tostring(definitionId) .. "_hotspot_" .. tostring(now) .. "_" .. tostring(ZombRand(100000))
    log("generateHotspotId() -> " .. id)
    return id
end

function Service.NormalizeHotspot(raw, definitionId)
    if type(raw) ~= "table" then
        log("NormalizeHotspot() -> INVALID_HOTSPOT")
        return nil, "INVALID_HOTSPOT"
    end

    local hotspotType = trim(raw.type):upper()
    if not KIPN.Shared.EventHotspotTypes[hotspotType] then
        log("NormalizeHotspot() -> INVALID_HOTSPOT_TYPE")
        return nil, "INVALID_HOTSPOT_TYPE"
    end

    local geometry, geometryReason = normalizeGeometry(raw.geometry or raw)
    if not geometry then
        return nil, geometryReason
    end

    local roundNumber = tonumber(raw.roundNumber)
    if roundNumber then
        roundNumber = math.max(1, math.min(MAX_HILL_HOTSPOTS, math.floor(roundNumber)))
    end

    -- Phase 6: only meaningful for TEAM_BASE hotspots (Team CTF's
    -- one-base-per-team-per-round) -- see
    -- KIPN_EventCaptureService.lua's resolveTeamBaseHotspot(). nil for
    -- every other hotspot type/mode.
    local teamId = type(raw.teamId) == "string" and trim(raw.teamId) ~= "" and trim(raw.teamId) or nil

    -- Only meaningful for NARRATIVE_LOCATION hotspots -- proximity-
    -- triggered flavor text, evaluated by
    -- KIPN_EventTriggerService.lua's TickNarrativeHotspots(). GLOBAL
    -- broadcasts to every participant once for the event; LOCAL sends
    -- a private message to each player once, as they individually
    -- reach the hotspot.
    local rawMetadata = type(raw.metadata) == "table" and raw.metadata or {}
    local narrativeText = trim(rawMetadata.narrativeText):sub(1, 500)
    local metadata = {
        narrativeText = narrativeText ~= "" and narrativeText or nil,
        narrativeScope = rawMetadata.narrativeScope == "GLOBAL" and "GLOBAL" or "LOCAL",
    }

    -- Narrative text is a replayable clue unless turned off; clueTitle
    -- labels its HUD button (e.g. "Diary page").
    if hotspotType == "NARRATIVE_LOCATION" then
        metadata.replayable = rawMetadata.replayable ~= false
        local clueTitle = trim(rawMetadata.clueTitle):sub(1, 40)
        metadata.clueTitle = clueTitle ~= "" and clueTitle or nil
    end

    -- A Zombie Ambush or Bandit Camp: how many wake (before difficulty).
    if hotspotType == "BANDIT_CAMP" then
        metadata.count = math.max(1, math.min(12, math.floor(tonumber(rawMetadata.count) or 4)))
    end
    if hotspotType == "ZOMBIE_AMBUSH" then
        metadata.count = math.max(1, math.min(100, math.floor(tonumber(rawMetadata.count) or 6)))
    end

    -- The Olympics: what a course station asks of an athlete.
    local task = rawMetadata.task
    if task == "CHECKPOINT" or task == "CHOP" or task == "CRAFT" or task == "CARRY" or task == "SHOOT" then
        metadata.task = task
        local itemType = trim(rawMetadata.itemType):sub(1, 120)
        metadata.itemType = itemType ~= "" and itemType or nil
        metadata.count = math.max(1, math.min(50, math.floor(tonumber(rawMetadata.count) or 1)))
        if type(rawMetadata.kit) == "table" then
            metadata.kit = {}
            for index, fullType in ipairs(rawMetadata.kit) do
                local value = trim(fullType):sub(1, 120)
                if index <= 8 and value ~= "" then metadata.kit[#metadata.kit + 1] = value end
            end
        end
    end

    local hotspot = {
        id = trim(raw.id) ~= "" and trim(raw.id) or generateHotspotId(definitionId),
        type = hotspotType,
        label = trim(raw.label),
        geometry = geometry,
        roundNumber = roundNumber,
        teamId = teamId,
        active = raw.active ~= false,
        -- Phase 5: any hotspot (not just ZOMBIE_SPAWN) can be flagged
        -- as a Director alarm target -- see
        -- Service.GetAlarmEnabledHotspots() and
        -- KIPN_EventDirector.lua's TRIGGER_ALARM command.
        alarmEnabled = raw.alarmEnabled == true,
        metadata = metadata,
        updatedAtWorldDays = getWorldDays(),
    }

    log("NormalizeHotspot() -> id=" .. hotspot.id .. " type=" .. hotspot.type)
    return hotspot
end

function Service.NormalizeHotspots(rawList, definitionId)
    local result = {}
    if type(rawList) ~= "table" then
        log("NormalizeHotspots() -> 0")
        return result
    end

    for _, raw in ipairs(rawList) do
        if #result >= MAX_HOTSPOTS then break end
        local hotspot = Service.NormalizeHotspot(raw, definitionId)
        if hotspot then result[#result + 1] = hotspot end
    end

    log("NormalizeHotspots() -> " .. tostring(#result))
    return result
end

function Service.GetHotspots(definition, hotspotType, includeInactive)
    local result = {}
    local wanted = hotspotType and tostring(hotspotType):upper() or nil

    for _, hotspot in ipairs((definition and definition.hotspots) or {}) do
        if type(hotspot) == "table"
            and (includeInactive == true or hotspot.active ~= false)
            and (not wanted or hotspot.type == wanted)
        then
            result[#result + 1] = hotspot
        end
    end

    table.sort(result, function(a, b)
        local ar = tonumber(a.roundNumber) or 999999
        local br = tonumber(b.roundNumber) or 999999
        if ar ~= br then return ar < br end
        return tostring(a.id) < tostring(b.id)
    end)

    log("GetHotspots(type=" .. tostring(wanted) .. ") -> " .. tostring(#result))
    return result
end

function Service.GetCenter(hotspot)
    local geometry = hotspot and hotspot.geometry
    if type(geometry) ~= "table" then
        log("GetCenter() -> nil")
        return nil
    end

    local center = {
        x = math.floor((geometry.x1 + geometry.x2) / 2),
        y = math.floor((geometry.y1 + geometry.y2) / 2),
        z = geometry.z1 or 0,
    }
    log("GetCenter() -> " .. tostring(center.x) .. "," .. tostring(center.y) .. "," .. tostring(center.z))
    return center
end

function Service.IsPositionInHotspot(x, y, z, hotspot)
    local geometry = hotspot and hotspot.geometry
    if type(geometry) ~= "table" then return false end
    local inside = tonumber(x) and tonumber(y) and tonumber(z)
        and x >= geometry.x1 and x <= geometry.x2
        and y >= geometry.y1 and y <= geometry.y2
        and z >= (geometry.z1 or 0) and z <= (geometry.z2 or geometry.z1 or 0)
    log("IsPositionInHotspot(" .. tostring(hotspot.id) .. ") -> " .. tostring(inside == true))
    return inside == true
end

-- Phase 5: the Event Director's alarm target selector's "every
-- alarm-enabled hotspot" option. See KIPN_EventDirector.lua's
-- handleTriggerAlarm().
function Service.GetAlarmEnabledHotspots(definition)
    local result = {}

    for _, hotspot in ipairs((definition and definition.hotspots) or {}) do
        if hotspot.alarmEnabled == true and hotspot.active ~= false then
            result[#result + 1] = hotspot
        end
    end

    log("GetAlarmEnabledHotspots() -> " .. tostring(#result))
    return result
end

function Service.FindById(definition, hotspotId)
    if not hotspotId then
        return nil
    end

    for _, hotspot in ipairs((definition and definition.hotspots) or {}) do
        if tostring(hotspot.id) == tostring(hotspotId) then
            return hotspot
        end
    end

    return nil
end

-- Zone geometry (KIPN_WorldRegistry.lua) uses this same
-- {x1,y1,x2,y2,z1,z2} shape, so this helper serves both hotspots and
-- zones.
function Service.GetRandomPointInGeometry(geometry)
    if type(geometry) ~= "table" then
        return nil
    end

    local x1, y1, x2, y2 = tonumber(geometry.x1), tonumber(geometry.y1), tonumber(geometry.x2), tonumber(geometry.y2)

    if not x1 or not y1 or not x2 or not y2 then
        return nil
    end

    local minX, maxX = math.min(x1, x2), math.max(x1, x2)
    local minY, maxY = math.min(y1, y2), math.max(y1, y2)

    local point = {
        x = ZombRand(minX, maxX + 1),
        y = ZombRand(minY, maxY + 1),
        z = geometry.z1 or 0,
    }
    log("GetRandomPointInGeometry() -> " .. tostring(point.x) .. "," .. tostring(point.y) .. "," .. tostring(point.z))
    return point
end

function Service.GetRoundHotspot(definition, roundNumber)
    local hills = Service.GetHotspots(definition, KIPN.Shared.EventHotspotTypes.HILL_LOCATION)
    for _, hotspot in ipairs(hills) do
        if tonumber(hotspot.roundNumber) == tonumber(roundNumber) then
            log("GetRoundHotspot(" .. tostring(roundNumber) .. ") -> " .. tostring(hotspot.id))
            return hotspot
        end
    end

    local fallback = hills[tonumber(roundNumber) or 1]
    log("GetRoundHotspot(" .. tostring(roundNumber) .. ") -> " .. tostring(fallback and fallback.id))
    return fallback
end

-- Phase 6: general filtered lookup (type + optional round + optional
-- team) -- used by KIPN_EventCaptureService.lua for TEAM_BASE (type +
-- round + team), and FFA's CAPTURE_ITEM/DELIVERY_POINT (type + round,
-- no team). Deliberately a new function rather than widening
-- GetRoundHotspot() above, so that function's existing
-- HILL_LOCATION-only behavior/signature (already relied on by KOTH's
-- round-start flow) is untouched.
function Service.FindHotspot(definition, hotspotType, roundNumber, teamId)
    local candidates = Service.GetHotspots(definition, hotspotType)

    for _, hotspot in ipairs(candidates) do
        local roundMatches = roundNumber == nil or tonumber(hotspot.roundNumber) == tonumber(roundNumber)
        local teamMatches = teamId == nil or tostring(hotspot.teamId) == tostring(teamId)

        if roundMatches and teamMatches then
            log("FindHotspot(" .. tostring(hotspotType) .. ", round=" .. tostring(roundNumber)
                .. ", team=" .. tostring(teamId) .. ") -> " .. tostring(hotspot.id))
            return hotspot
        end
    end

    log("FindHotspot(" .. tostring(hotspotType) .. ", round=" .. tostring(roundNumber)
        .. ", team=" .. tostring(teamId) .. ") -> nil")
    return nil
end

function Service.GetZombieSpawnPoint(definition)
    local spawns = Service.GetHotspots(definition, KIPN.Shared.EventHotspotTypes.ZOMBIE_SPAWN)
    if #spawns > 0 then
        local selected = spawns[ZombRand(1, #spawns + 1)]
        log("GetZombieSpawnPoint() -> hotspot=" .. tostring(selected.id))
        return Service.GetCenter(selected), selected
    end

    log("GetZombieSpawnPoint() -> no hotspot")
    return nil
end

function Service.ValidateDefinition(definition)
    local failures = {}
    local counts = {}
    local activeCount = 0
    for _, hotspot in ipairs((definition and definition.hotspots) or {}) do
        if hotspot.active ~= false then
            activeCount = activeCount + 1
            counts[hotspot.type] = (counts[hotspot.type] or 0) + 1
        end
    end

    if definition and definition.scopeType == KIPN.Shared.EventScopeTypes.HOTSPOTS and activeCount < 1 then
        failures[#failures + 1] = "HOTSPOT_SCOPE_REQUIRES_HOTSPOT"
    end

    local objectives = {}
    for _, objectiveType in ipairs((definition and definition.objectiveTypes) or {}) do
        objectives[objectiveType] = true
    end

    if objectives.RETRIEVE
        and (counts[KIPN.Shared.EventHotspotTypes.CAPTURE_ITEM] or 0) < 1
        and (counts[KIPN.Shared.EventHotspotTypes.RESCUE_OBJECTIVE] or 0) < 1
        and (counts.BANDIT_VEHICLE or 0) < 1 and (counts.BANDIT_CAMP or 0) < 1
    then
        failures[#failures + 1] = "CAPTURE_OR_RESCUE_HOTSPOT_REQUIRED"
    end

    if objectives.DELIVER and (counts[KIPN.Shared.EventHotspotTypes.DELIVERY_POINT] or 0) < 1 then
        failures[#failures + 1] = "DELIVERY_HOTSPOT_REQUIRED"
    end

    local hillCount = counts[KIPN.Shared.EventHotspotTypes.HILL_LOCATION] or 0
    if objectives.HOLD_AREA and hillCount < 1 then
        failures[#failures + 1] = "HILL_HOTSPOT_REQUIRED"
    end

    local requiredRounds = math.max(1, math.min(MAX_HILL_HOTSPOTS, math.floor(tonumber(definition and definition.maxRounds) or 1)))
    if objectives.HOLD_AREA and hillCount >= 1 and hillCount < requiredRounds
    then
        failures[#failures + 1] = "HILL_HOTSPOTS_REQUIRED_FOR_EACH_ROUND"
    end

    if (counts[KIPN.Shared.EventHotspotTypes.HILL_LOCATION] or 0) > MAX_HILL_HOTSPOTS then
        failures[#failures + 1] = "TOO_MANY_HILL_HOTSPOTS"
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

local function respond(player, success, definition, reason)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_HOTSPOT_SAVED, {
        success = success,
        definition = success and definition or nil,
        reason = success and nil or reason,
    })
    log("respond() -> success=" .. tostring(success) .. " reason=" .. tostring(reason))
end

local function getEditableDefinition(player, args)
    if not requireAdmin(player) then return nil, "PERMISSION_DENIED" end
    local service = KIPN.Server.EventScenarioService
    local definition = service and service.GetDefinition and service.GetDefinition(args and args.id)
    if not definition then return nil, "DEFINITION_NOT_FOUND" end
    if definition.status ~= "DRAFT" and definition.status ~= "READY" then return nil, "NOT_EDITABLE" end
    return definition
end

local function handleUpsert(player, args)
    local definition, reason = getEditableDefinition(player, args)
    if not definition then respond(player, false, nil, reason) return true end

    local hotspot, normalizeReason = Service.NormalizeHotspot(args and args.hotspot, definition.id)
    if not hotspot then respond(player, false, nil, normalizeReason) return true end

    definition.hotspots = Service.NormalizeHotspots(definition.hotspots, definition.id)
    local replaced = false
    for index, current in ipairs(definition.hotspots) do
        if tostring(current.id) == tostring(hotspot.id) then
            definition.hotspots[index] = hotspot
            replaced = true
            break
        end
    end
    if not replaced then definition.hotspots[#definition.hotspots + 1] = hotspot end

    definition.updatedAtWorldDays = getWorldDays()
    KIPN.Server.Save()
    KIPN.Server.AdminService.WriteAudit(player, "EVENT_HOTSPOT_UPSERTED", "eventDefinition", definition.id, {
        hotspotId = hotspot.id,
        hotspotType = hotspot.type,
    })
    log("handleUpsert() -> definition=" .. tostring(definition.id) .. " hotspot=" .. hotspot.id)
    respond(player, true, definition)
    return true
end

local function handleDelete(player, args)
    local definition, reason = getEditableDefinition(player, args)
    if not definition then respond(player, false, nil, reason) return true end
    local hotspotId = args and tostring(args.hotspotId or "") or ""
    local removed = false
    for index = #(definition.hotspots or {}), 1, -1 do
        if tostring(definition.hotspots[index].id) == hotspotId then
            table.remove(definition.hotspots, index)
            removed = true
            break
        end
    end
    if not removed then respond(player, false, nil, "HOTSPOT_NOT_FOUND") return true end
    definition.updatedAtWorldDays = getWorldDays()
    KIPN.Server.Save()
    KIPN.Server.AdminService.WriteAudit(player, "EVENT_HOTSPOT_DELETED", "eventDefinition", definition.id, {
        hotspotId = hotspotId,
    })
    log("handleDelete() -> definition=" .. tostring(definition.id) .. " hotspot=" .. hotspotId)
    respond(player, true, definition)
    return true
end

function Service.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_UPSERT_HOTSPOT, handleUpsert)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_DELETE_HOTSPOT, handleDelete)
    log("Initialize() -> registered hotspot commands")
    return true
end

log("module loaded")
