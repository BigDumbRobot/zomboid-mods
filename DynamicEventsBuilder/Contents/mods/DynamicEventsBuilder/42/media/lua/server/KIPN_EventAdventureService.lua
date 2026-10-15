-- KIPN_EventAdventureService.lua
--
-- Phase 11 of the Event Scenarios rewrite: the Adventure mode engine.
-- Adventure had the least surviving spec of any mode -- no legacy
-- preset ever mapped to it, and the only concrete clue left in this
-- codebase was KIPN_EventModeRegistry.lua's Naked and Afraid
-- compatibility matrix, which already said Adventure is
-- "conservatively incompatible... until it has actually rolled an
-- underlying mode/variant" and that a later phase "must re-check the
-- rolled mode/variant directly." The project owner confirmed the
-- actual mechanic directly: Adventure rolls a real mode/variant at
-- event start AND auto-generates everything that mode needs to
-- actually be playable (hotspots, teams, objective types, timers) --
-- full procedural generation, not just a label swap.
--
-- HOW THE ROLL WORKS: KIPN_EventRuntimeService.lua's startEvent()
-- calls RollAndGenerate() once, before any other mode's
-- InitializeRuntime hook runs. RollAndGenerate() snapshots the
-- Adventure definition's original (mostly-empty) fields, then
-- MUTATES definition.mode/variant/hotspots/teams/objectiveTypes/
-- maxRounds/roundDuration/duration IN PLACE to a fully valid rolled
-- configuration -- definitions are plain references into
-- KIPN_EventScenarioService.lua's persisted collection (see
-- GetDefinition()/SetDefinitionStatus() for the established
-- "mutate the returned table directly" pattern), so every existing
-- mode-gated hook everywhere else in the codebase (definition.mode ==
-- "CAPTURE", etc.) sees the rolled mode automatically -- ZERO other
-- call site needed to change. The admin's Live Status view and the
-- world map show the real rolled hotspots for the same reason: they
-- already read straight off definition.hotspots. This is also
-- exactly what EventModeMetadata.ADVENTURE.isGenerated (Phase 1) was
-- foreshadowing -- Adventure's content is meant to be (re)generated,
-- not authored once and reused. KIPN_EventRuntimeService.lua's
-- stopEvent() calls RestoreOriginal() to put the definition back to
-- its clean, ungenerated Adventure state once the event ends, so the
-- next play rolls fresh -- gated on runtime.adventureState, NOT on
-- definition.mode, since by then definition.mode is whatever got
-- rolled, not "ADVENTURE" anymore.
--
-- WHAT CAN BE ROLLED, AND WHY NOT EVERYTHING: only candidates whose
-- entire mechanic is already fully understood AND buildable from
-- already-proven primitives are eligible --
--   KING_OF_THE_HILL, CHASE, SURVIVOR_RUN, EXTRACTION/LAST_DITCH --
--     hotspots via KIPN_EventHotspotService.lua's
--     GetRandomPointInGeometry()/NormalizeHotspot() (already-proven,
--     Phase 3/5/6), teams via KIPN_EventTeamService.lua's
--     CreateTeams()/AssignParticipantsDeterministically() (already-
--     proven, pre-Phase-11 functions), timers via the plain
--     duration/roundDuration data shape every mode already uses.
--   CAPTURE (FFA and TEAM_CTF) -- only eligible when the Adventure
--     definition already has captureConfig.flagItemFullType set.
--     KIPN_EventScenarioService.lua's sanitizeCaptureConfig() is
--     explicit that "no vanilla item ID is guessed/invented" for
--     Capture -- that rule applies here too, so Adventure never
--     invents a flag item; it only rolls Capture when the admin
--     already supplied one.
-- EXTRACTION's ABANDONED_SOLDIER/HOSPITAL_WARD (their actual SURVIVE
-- win/fail wiring was never fully traced in this investigation -- see
-- the Phase 11 report's "known limitations") and PRISON_BREAK
-- (correctly auto-generating its two-stage ordered-objective/
-- proximity-trigger wiring is a distinct, higher-risk undertaking) are
-- deliberately NOT in the roll pool. Both are flagged as follow-up
-- work rather than guessed at.
--
-- NAKED_AND_AFRAID: the "re-check the rolled mode directly" the audit
-- envisioned is NOT implemented this phase. Escrow-stripping already
-- happens at JOIN time (KIPN_EventParticipationService.lua's
-- handleAcceptParticipation()), before any roll exists to re-check
-- against, and reordering that would mean reworking an already-
-- approved, working Phase 2 flow. KIPN_EventModeRegistry.lua's
-- existing conservative block (bare ADVENTURE is always
-- Naked-and-Afraid-incompatible) is left exactly as-is -- safe, just
-- not the more permissive behavior that comment envisioned.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_EventHotspotService"
require "KIPN_EventTeamService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventAdventureService = KIPN.Server.EventAdventureService or {}

local AdventureService = KIPN.Server.EventAdventureService

local HOTSPOT_RADIUS = 3
local KOTH_MAX_ROUNDS = 3
local CHASE_MAX_ROUNDS = 3
local ROUND_DURATION_SECONDS = 300
local SURVIVOR_RUN_DURATION_SECONDS = 1800

local function log(message)
    print("[KIPN EVENT ADVENTURE] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT ADVENTURE] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------

-- Every generator below needs bounded geometry to place hotspots in
-- -- an OPEN_MAP-scoped Adventure definition would have nowhere safe
-- to roll a hotspot into, so a Zone is required.
function AdventureService.ValidateDefinition(definition)
    local failures = {}

    if definition.scopeType ~= KIPN.Shared.EventScopeTypes.ZONE or not definition.zoneId then
        failures[#failures + 1] = "ADVENTURE_REQUIRES_ZONE"
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- GEOMETRY GENERATION
------------------------------------------------------------

local function boxGeometryAround(zoneGeometry, center, radius)
    local minX = math.min(zoneGeometry.x1, zoneGeometry.x2)
    local maxX = math.max(zoneGeometry.x1, zoneGeometry.x2)
    local minY = math.min(zoneGeometry.y1, zoneGeometry.y2)
    local maxY = math.max(zoneGeometry.y1, zoneGeometry.y2)

    return {
        x1 = math.max(minX, center.x - radius),
        x2 = math.min(maxX, center.x + radius),
        y1 = math.max(minY, center.y - radius),
        y2 = math.min(maxY, center.y + radius),
        z1 = zoneGeometry.z1 or 0,
        z2 = zoneGeometry.z1 or 0,
    }
end

local function generatedHotspot(definition, zone, hotspotType, roundNumber, teamId)
    local center = KIPN.Server.EventHotspotService.GetRandomPointInGeometry(zone.geometry)
    if not center then return nil end

    local hotspot, reason = KIPN.Server.EventHotspotService.NormalizeHotspot({
        type = hotspotType,
        geometry = boxGeometryAround(zone.geometry, center, HOTSPOT_RADIUS),
        roundNumber = roundNumber,
        teamId = teamId,
    }, definition.id)

    if not hotspot then
        logError("generatedHotspot(" .. tostring(hotspotType) .. ") -> " .. tostring(reason))
    end

    return hotspot
end

------------------------------------------------------------
-- PER-CANDIDATE GENERATORS -- each mutates `definition` in place
-- to a fully valid, playable configuration for that mode.
------------------------------------------------------------

local function generateKOTH(definition, zone)
    definition.mode = KIPN.Shared.EventModes.KING_OF_THE_HILL
    definition.variant = nil
    definition.objectiveTypes = { "HOLD_AREA" }
    definition.maxRounds = KOTH_MAX_ROUNDS
    definition.roundDuration = { enabled = true, durationSeconds = ROUND_DURATION_SECONDS }

    KIPN.Server.EventTeamService.CreateTeams(definition, 2)
    KIPN.Server.EventTeamService.AssignParticipantsDeterministically(definition)

    local hotspots = {}
    for round = 1, KOTH_MAX_ROUNDS do
        local hotspot = generatedHotspot(definition, zone, "HILL_LOCATION", round, nil)
        if hotspot then hotspots[#hotspots + 1] = hotspot end
    end
    definition.hotspots = hotspots
end

local function generateChase(definition, _zone)
    definition.mode = KIPN.Shared.EventModes.CHASE
    definition.variant = nil
    definition.objectiveTypes = { "CHASE_TARGET" }
    definition.teams = {}
    definition.hotspots = {}
    definition.maxRounds = CHASE_MAX_ROUNDS
    definition.roundDuration = { enabled = true, durationSeconds = ROUND_DURATION_SECONDS }
end

local function generateSurvivorRun(definition, _zone)
    definition.mode = KIPN.Shared.EventModes.SURVIVOR_RUN
    definition.variant = nil
    definition.objectiveTypes = {}
    definition.teams = {}
    definition.hotspots = {}
    definition.duration = {
        enabled = true,
        durationSeconds = SURVIVOR_RUN_DURATION_SECONDS,
        expiryBehavior = KIPN.Shared.EventTimerExpiryBehaviors.WIN,
    }
end

local function generateExtractionLastDitch(definition, zone)
    definition.mode = KIPN.Shared.EventModes.EXTRACTION
    definition.variant = KIPN.Shared.EventExtractionVariants.LAST_DITCH
    -- Hold out until the evac arrives, then reach the extraction point
    -- (see KIPN_EventExtractionService.lua).
    definition.objectiveTypes = { "SURVIVE" }
    definition.teams = {}
    definition.maxRounds = 1
    definition.duration = {
        enabled = true,
        durationSeconds = SURVIVOR_RUN_DURATION_SECONDS,
        expiryBehavior = KIPN.Shared.EventTimerExpiryBehaviors.WIN,
    }

    local hotspot = generatedHotspot(definition, zone, "EXTRACTION_POINT", nil, nil)
    definition.hotspots = hotspot and { hotspot } or {}
end

local function generateCaptureFFA(definition, zone)
    definition.mode = KIPN.Shared.EventModes.CAPTURE
    definition.variant = KIPN.Shared.EventCaptureVariants.FFA
    definition.objectiveTypes = {}
    definition.teams = {}
    definition.maxRounds = 1
    -- A round clock, so a flag nobody delivers still ends the game.
    definition.roundDuration = { enabled = true, durationSeconds = ROUND_DURATION_SECONDS }

    local hotspots = {}
    local spawnHotspot = generatedHotspot(definition, zone, "CAPTURE_ITEM", 1, nil)
    if spawnHotspot then hotspots[#hotspots + 1] = spawnHotspot end
    local deliveryHotspot = generatedHotspot(definition, zone, "DELIVERY_POINT", 1, nil)
    if deliveryHotspot then hotspots[#hotspots + 1] = deliveryHotspot end
    definition.hotspots = hotspots
end

local function generateCaptureTeamCTF(definition, zone)
    definition.mode = KIPN.Shared.EventModes.CAPTURE
    definition.variant = KIPN.Shared.EventCaptureVariants.TEAM_CTF
    definition.objectiveTypes = {}
    definition.maxRounds = 1
    definition.roundDuration = { enabled = true, durationSeconds = ROUND_DURATION_SECONDS }

    KIPN.Server.EventTeamService.CreateTeams(definition, 2)
    KIPN.Server.EventTeamService.AssignParticipantsDeterministically(definition)

    local hotspots = {}
    for _, team in ipairs(definition.teams) do
        local hotspot = generatedHotspot(definition, zone, "TEAM_BASE", 1, team.id)
        if hotspot then hotspots[#hotspots + 1] = hotspot end
    end
    definition.hotspots = hotspots
end

local function hasFlagItemConfigured(definition)
    local flagItemFullType = definition.captureConfig and definition.captureConfig.flagItemFullType
    return type(flagItemFullType) == "string" and flagItemFullType ~= ""
end

local function alwaysEligible(_definition)
    return true
end

-- Order matters only for readability -- selection below is uniform
-- random over whichever of these pass their eligible() check.
local ROLL_POOL = {
    { id = "KING_OF_THE_HILL", generate = generateKOTH, eligible = alwaysEligible },
    { id = "CHASE", generate = generateChase, eligible = alwaysEligible },
    { id = "SURVIVOR_RUN", generate = generateSurvivorRun, eligible = alwaysEligible },
    { id = "EXTRACTION_LAST_DITCH", generate = generateExtractionLastDitch, eligible = alwaysEligible },
    { id = "CAPTURE_FFA", generate = generateCaptureFFA, eligible = hasFlagItemConfigured },
    { id = "CAPTURE_TEAM_CTF", generate = generateCaptureTeamCTF, eligible = hasFlagItemConfigured },
}

------------------------------------------------------------
-- SNAPSHOT / ROLL / RESTORE
------------------------------------------------------------

local function shallowCopyArray(source)
    if type(source) ~= "table" then return source end
    local copy = {}
    for index, value in ipairs(source) do copy[index] = value end
    return copy
end

local function snapshotDefinition(definition)
    return {
        mode = definition.mode,
        variant = definition.variant,
        objectiveTypes = shallowCopyArray(definition.objectiveTypes),
        teams = definition.teams,
        hotspots = definition.hotspots,
        maxRounds = definition.maxRounds,
        roundDuration = definition.roundDuration,
        duration = definition.duration,
    }
end

-- Called from KIPN_EventRuntimeService.lua's startEvent(), before any
-- other mode's InitializeRuntime hook runs -- see this file's header
-- for why mutating `definition` in place is what makes every other
-- mode-gated hook in the codebase work unchanged.
function AdventureService.RollAndGenerate(runtime, definition)
    local zone = definition.zoneId and KIPN.Server.WorldRegistry.GetZone(definition.zoneId)
    if not zone or type(zone.geometry) ~= "table" then
        logError("RollAndGenerate() -> no zone geometry available for " .. tostring(definition.id))
        return false, "NO_ZONE_GEOMETRY"
    end

    local eligible = {}
    for _, candidate in ipairs(ROLL_POOL) do
        if candidate.eligible(definition) then eligible[#eligible + 1] = candidate end
    end

    if #eligible < 1 then
        logError("RollAndGenerate() -> no eligible candidates for " .. tostring(definition.id))
        return false, "NO_ELIGIBLE_CANDIDATES"
    end

    runtime.adventureState = { originalSnapshot = snapshotDefinition(definition) }

    local chosen = eligible[ZombRand(1, #eligible + 1)]
    runtime.adventureState.rolledId = chosen.id

    local ok, err = pcall(chosen.generate, definition, zone)
    if not ok then
        logError("RollAndGenerate() -> generator for " .. chosen.id .. " failed: " .. tostring(err))
        return false, "GENERATOR_FAILED"
    end

    log("RollAndGenerate() -> rolled " .. chosen.id .. " for " .. tostring(definition.id)
        .. " (mode=" .. tostring(definition.mode) .. " variant=" .. tostring(definition.variant) .. ")")
    return true
end

-- Called from KIPN_EventRuntimeService.lua's stopEvent() (and from
-- startEvent()'s own abort path if a later init step fails after the
-- roll already happened) -- gated on runtime.adventureState, NOT on
-- definition.mode, since by the time this runs definition.mode is
-- whatever got rolled, not "ADVENTURE" -- see this file's header.
function AdventureService.RestoreOriginal(runtime, definition)
    local snapshot = runtime.adventureState and runtime.adventureState.originalSnapshot
    if not snapshot then return end

    definition.mode = snapshot.mode
    definition.variant = snapshot.variant
    definition.objectiveTypes = snapshot.objectiveTypes
    definition.teams = snapshot.teams
    definition.hotspots = snapshot.hotspots
    definition.maxRounds = snapshot.maxRounds
    definition.roundDuration = snapshot.roundDuration
    definition.duration = snapshot.duration

    log("RestoreOriginal() -> " .. tostring(definition.id))
end

function AdventureService.Initialize()
    log("Initialize()")
    return true
end

return true
