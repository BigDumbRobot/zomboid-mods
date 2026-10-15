-- KIPN_EventScenarioService.lua
--
-- Event Definition CRUD, dynamic Event Zone creation, the
-- online-players query, participant roster management, and the
-- teleport-participants-into-zone action for the Event Scenarios
-- admin feature.
--
-- Reachable only through KIPN_AdminSettings.lua's "Event Scenarios"
-- section (see client/KIPN_EventScenarioAdminUI.lua). Every handler
-- re-checks SYSOP_CONFIGURATION server-side -- the client panel is
-- convenience UI only, exactly like every other KIPN admin surface.
--
-- EVENT DEFINITION SCHEMA:
--
--   {
--       id, name, status,               -- DRAFT|VALIDATING|READY|ANNOUNCED|
--                                        -- JOINING|ACTIVE|ENDING|COMPLETE|CLEANUP
--       eventType,                      -- e.g. "HORDE_SURVIVAL"; validated
--                                        -- against KIPN.Server.EventObjectiveRegistry
--       spawnRules,                     -- opaque config bag owned/interpreted
--                                        -- only by the registered eventType
--       zoneId,                         -- a WorldRegistry zone id (zoneType "event")
--       environment = { timeOfDay, weatherPreset },
--       participants = { [username] = true, ... },
--       duration = { enabled, durationSeconds, expiryBehavior },  -- event-
--                                        -- scoped timer; expiryBehavior is
--                                        -- KIPN.Shared.EventTimerExpiryBehaviors.*
--                                        -- (WIN|FAIL), defaults WIN
--       roundDuration = { enabled, durationSeconds },  -- round-scoped
--                                        -- timer, wholly separate from
--                                        -- duration above -- see
--                                        -- KIPN_EventTimerService.lua
--       objectives = { { id, name, triggers = {...} }, ... },  -- ordered
--                                        -- story stages + the proximity/
--                                        -- timed/manual trigger-and-action
--                                        -- framework; see
--                                        -- KIPN_EventTriggerService.lua's
--                                        -- header for the full shape.
--                                        -- Optional -- a definition with
--                                        -- no objectives simply has no
--                                        -- story/trigger content.
--       winConditions = { { conditionId, params }, ... },
--       failConditions = { { conditionId, params }, ... },
--       combatRules = { allowLeaveZone, pvpAllowedInZone },
--       rewards = { items = { { itemFullType, count }, ... } },
--       narrative = { briefing, winText, failText },
--       createdAtWorldDays, updatedAtWorldDays, metadata,
--
--       -- Schema v2 (Event Scenarios architecture rewrite, Phase 1) --
--       schemaVersion,                  -- KIPN.Shared.EventDefinitionSchemaVersion
--       mode,                           -- nullable; KIPN.Shared.EventModes.*
--       variant,                        -- nullable; only set when mode == EXTRACTION
--       modifiers = { [modifierId] = true, ... },  -- e.g. NAKED_AND_AFRAID
--       legacyPresetId,                 -- nullable; original scenarioPresetId, preserved for audit
--       migrationStatus,                -- KIPN.Shared.EventMigrationStatus.*
--                                        -- (NATIVE|MIGRATED|LEGACY_REVIEW_REQUIRED)
--       -- mode/variant/modifiers are metadata only as of Phase 1 -- see
--       -- KIPN_EventModeRegistry.lua's header for what still actually
--       -- drives gameplay (eventType/objectiveTypes, unchanged).
--   }
--
-- DYNAMIC EVENT ZONES:
--
-- Event Zones are ordinary WorldRegistry zones (zoneType "event"),
-- NOT a separate storage system -- they persist, broadcast to every
-- client's public world map, and deactivate exactly like any other
-- zone. This file owns the *dynamic* creation path
-- (EVENT_CREATE_ZONE_FROM_CORNERS): the admin draws corners once, in
-- the middle of building the Event Definition, and this handler
-- creates the WorldRegistry zone AND links it to the definition in
-- one server-side step -- no separate "draw it in the Zone Admin
-- tool, then come back and pick it from a list" round trip. The
-- classic manual flow (draw in Zone Admin, EVENT_SET_ZONE to link an
-- existing zone) still works as a fallback/relink path.
--
-- An in-progress Event Runtime is owned by KIPN_EventRuntimeService.lua,
-- not here. This file owns only the persisted Event Definition record
-- and its DRAFT/READY/RUNNING/ENDED status field; KIPN_EventRuntimeService.lua
-- calls SetDefinitionStatus() when it starts/stops an event.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_WorldRegistry"
require "KIPN_AdminService"
require "KIPN_EventAccessService"
require "KIPN_EventObjectiveRegistry"
require "KIPN_EventModeRegistry"
require "KIPN_EventTeamService"
require "KIPN_EventTriggerService"
require "KIPN_EventCaptureService"
require "KIPN_EventKOTHService"
require "KIPN_EventChaseService"
require "KIPN_EventExtractionService"
require "KIPN_EventSurvivorRunService"
require "KIPN_EventAdventureService"
require "KIPN_EventHotspotService"
require "KIPN_EventZombieThemeRegistry"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.EventScenarioService = KIPN.Server.EventScenarioService or {}

local EventScenarioService = KIPN.Server.EventScenarioService

local ZONE_ADMIN_MODULE_NAME = "KIPN_ZoneAdmin"

local ENVIRONMENT_TIME_OF_DAY_VALUES = { DAY = true, NIGHT = true, DUSK = true, DAWN = true }
local ENVIRONMENT_WEATHER_PRESET_VALUES = { CLEAR = true, RAIN = true, STORM = true, FOG = true }

local OBJECTIVES_MAX_ROWS = 5
local CONDITIONS_MAX_ROWS = 5

local function log(message)
    print("[KIPN EVENT SCENARIO] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT SCENARIO] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- STATUS CONSTANTS
------------------------------------------------------------

-- Full lifecycle:
--   DRAFT -> VALIDATING -> READY -> ANNOUNCED -> JOINING -> ACTIVE
--         -> ENDING -> COMPLETE -> CLEANUP -> (back to DRAFT)
-- See KIPN_Shared.lua's EVENT_VALIDATE/EVENT_ANNOUNCE/
-- EVENT_OPEN_JOINING/EVENT_START/EVENT_STOP/EVENT_RESET command
-- comments for what drives each transition. VALIDATING/ENDING/
-- CLEANUP are momentary -- there is no async work behind them, so
-- they resolve to the next state within the same server call and
-- are never independently observed by the client mid-flight.
EventScenarioService.Status = {
    DRAFT = "DRAFT",
    VALIDATING = "VALIDATING",
    READY = "READY",
    ANNOUNCED = "ANNOUNCED",
    JOINING = "JOINING",
    ACTIVE = "ACTIVE",
    ENDING = "ENDING",
    COMPLETE = "COMPLETE",
    CLEANUP = "CLEANUP",
}

-- "Queued" for KIPN_EventDirectorTrigger.lua's right-click menu
-- gating: a Definition that's been validated and is somewhere on its
-- way through the live lifecycle, from the moment it leaves DRAFT
-- (READY) through the moment it finishes (COMPLETE). Deliberately the
-- same stages KIPN_EventDirector.lua's panel is actually useful for.
local QUEUED_STATUSES = {
    READY = true,
    ANNOUNCED = true,
    JOINING = true,
    ACTIVE = true,
    ENDING = true,
}

------------------------------------------------------------
-- PERMISSION GATE
------------------------------------------------------------

-- Admins, and staff levels the sandbox allows (KIPN_EventAccessService.lua).
local function requireAdmin(player)
    return KIPN.Server.EventAccessService.RequireStudio(player)
end

------------------------------------------------------------
-- PERSISTED COLLECTION
------------------------------------------------------------
--
-- Lazily created, matching the exact idiom
-- KIPN_WorldRegistry.lua's getZoneCollection() uses for
-- data.configuration.worldZones -- do not touch schema
-- initialization anywhere else for this.
------------------------------------------------------------

local function getDefinitionCollection()
    if not KIPN.Server.GetData then
        logError("KIPN.Server.GetData() is unavailable.")
        return nil
    end

    local data = KIPN.Server.GetData()

    if not data then
        logError("KIPN data unavailable.")
        return nil
    end

    if type(data.configuration) ~= "table" then
        data.configuration = {}
    end

    if type(data.configuration.eventDefinitions) ~= "table" then
        data.configuration.eventDefinitions = {}
    end

    return data.configuration.eventDefinitions
end

local function getWorldDays()
    local ok, result = pcall(function()
        return getGameTime():getWorldAgeHours() / 24
    end)

    if ok then
        return result
    end

    return 0
end

local function generateDefinitionId()
    local timestamp = (getTimestampMs and getTimestampMs()) or 0
    return "event_" .. tostring(timestamp) .. "_" .. tostring(ZombRand(100000))
end

------------------------------------------------------------
-- DEFINITION ACCESS (also used by KIPN_EventRuntimeService.lua)
------------------------------------------------------------

function EventScenarioService.GetDefinition(definitionId)
    local definitions = getDefinitionCollection()

    if not definitions or not definitionId then
        return nil
    end

    return definitions[tostring(definitionId)]
end

function EventScenarioService.ListDefinitions()
    local definitions = getDefinitionCollection()

    if not definitions then
        return {}
    end

    local result = {}

    for _, definition in pairs(definitions) do
        result[#result + 1] = definition
    end

    return result
end

function EventScenarioService.HasQueuedEvent()
    local definitions = getDefinitionCollection()

    if not definitions then
        return false
    end

    for _, definition in pairs(definitions) do
        if QUEUED_STATUSES[definition.status] then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- QUEUE STATE SYNC (KIPN_EventDirectorTrigger.lua's menu gate)
--
-- Same "recompute, diff against last-broadcast value, push only on
-- change" shape as KIPN_AnnouncementService.lua's
-- persistAndBroadcastIfChanged -- reimplemented locally rather than
-- shared since it's a two-line diff against a bool, not a merged
-- list. lastBroadcastQueueState starts nil so the very first
-- transition after boot always broadcasts, even if it happens to
-- resolve to `false`.
------------------------------------------------------------

local lastBroadcastQueueState = nil

local function syncQueueStateIfChanged()
    local hasQueuedEvent = EventScenarioService.HasQueuedEvent()

    if hasQueuedEvent == lastBroadcastQueueState then
        return
    end

    lastBroadcastQueueState = hasQueuedEvent

    if type(getOnlinePlayers) ~= "function" then
        return
    end

    -- getOnlinePlayers() throws (not returns nil) if an unexpected
    -- early or hot-reload caller reaches this path before the network
    -- engine is up. Initialize() deliberately does not call this
    -- function anymore, but retain the guard for nonstandard reloads.
    -- Same defensive shape as KIPN_AnnouncementService.lua's
    -- broadcastAnnouncements().
    local ok, online = pcall(getOnlinePlayers)

    if not ok or not online or type(online.size) ~= "function" then
        return
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)

        if p then
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_QUEUE_SYNC, { hasQueuedEvent = hasQueuedEvent })
        end
    end
end

function EventScenarioService.SetDefinitionStatus(definitionId, status)
    local definition = EventScenarioService.GetDefinition(definitionId)

    if not definition then
        return false, "DEFINITION_NOT_FOUND"
    end

    definition.status = status
    definition.updatedAtWorldDays = getWorldDays()

    KIPN.Server.Save()

    syncQueueStateIfChanged()

    return true
end

------------------------------------------------------------
-- BOOT-TIME RESET
------------------------------------------------------------
--
-- An Event Runtime never persists (see the Event Scenarios plan).
-- If the server crashed/restarted while a Definition's status was
-- one of the "live" lifecycle stages (ANNOUNCED/JOINING/ACTIVE/
-- ENDING), those flags would otherwise keep lying about live state
-- forever with no backing runtime -- ANNOUNCED/JOINING have no
-- runtime to lose, but there's no meaningful way to resume "this was
-- announced to players" after a restart either. Reset all of them
-- back to READY at boot. COMPLETE is a genuine terminal state and is
-- left untouched.
------------------------------------------------------------

local STALE_LIFECYCLE_STATUSES = {
    ANNOUNCED = true,
    JOINING = true,
    ACTIVE = true,
    ENDING = true,
}

local function resetStaleRunningDefinitions()
    local definitions = getDefinitionCollection()

    if not definitions then
        return
    end

    local resetCount = 0

    for _, definition in pairs(definitions) do
        if STALE_LIFECYCLE_STATUSES[definition.status] then
            definition.status = EventScenarioService.Status.READY
            definition.updatedAtWorldDays = getWorldDays()
            resetCount = resetCount + 1
        end
    end

    if resetCount > 0 then
        KIPN.Server.Save()
        log("Reset " .. tostring(resetCount) .. " stale in-progress event definition(s) to READY at boot.")
    end
end

------------------------------------------------------------
-- SCHEMA MIGRATION (v1 -> v2: Mode/Variant/Modifiers)
------------------------------------------------------------
--
-- Idempotent: a definition already at
-- KIPN.Shared.EventDefinitionSchemaVersion is left untouched. Presets
-- that map cleanly onto a Mode/Variant via
-- KIPN.Shared.EventPresetModeMap become MIGRATED; a recognized preset
-- that intentionally has no mapping (DODGEBALL, ENTER_THE_AREA,
-- FIRE_SALE, THE_TEST_SUBJECT, NAKED_AND_AFRAID, ADVENTURE) becomes
-- LEGACY_REVIEW_REQUIRED rather than guessed at, per the Event
-- Scenarios architecture audit's Phase 1 migration plan. A definition
-- that never used a Scenario Preset at all (a hand-built custom
-- event) is left as NATIVE and is NOT blocked -- only definitions
-- descended from a named-but-unmappable preset need admin review.
------------------------------------------------------------

local function migrateDefinitionToV2(definition)
    local presetId = definition.scenarioPresetId
    local mapping = presetId and KIPN.Shared.EventPresetModeMap[presetId]

    definition.legacyPresetId = presetId

    if mapping then
        definition.mode = mapping.mode
        definition.variant = mapping.variant
        definition.migrationStatus = KIPN.Shared.EventMigrationStatus.MIGRATED
    elseif presetId then
        definition.mode = nil
        definition.variant = nil
        definition.migrationStatus = KIPN.Shared.EventMigrationStatus.LEGACY_REVIEW_REQUIRED
    else
        definition.migrationStatus = KIPN.Shared.EventMigrationStatus.NATIVE
    end

    definition.modifiers = type(definition.modifiers) == "table" and definition.modifiers or {}
    definition.schemaVersion = KIPN.Shared.EventDefinitionSchemaVersion
end

local function migrateDefinitionSchema()
    local definitions = getDefinitionCollection()

    if not definitions then
        return
    end

    local migratedCount = 0
    local reviewCount = 0

    for _, definition in pairs(definitions) do
        local currentVersion = tonumber(definition.schemaVersion) or 1

        if currentVersion < KIPN.Shared.EventDefinitionSchemaVersion then
            migrateDefinitionToV2(definition)
            migratedCount = migratedCount + 1

            if definition.migrationStatus == KIPN.Shared.EventMigrationStatus.LEGACY_REVIEW_REQUIRED then
                reviewCount = reviewCount + 1
            end
        end
    end

    if migratedCount > 0 then
        KIPN.Server.Save()
        log(
            "Migrated " .. tostring(migratedCount) .. " event definition(s) to schema v" ..
            tostring(KIPN.Shared.EventDefinitionSchemaVersion) .. " (" .. tostring(reviewCount) ..
            " flagged LEGACY_REVIEW_REQUIRED)."
        )
    end
end

------------------------------------------------------------
-- VALIDATION / SANITIZATION
------------------------------------------------------------

local function isValidEventType(eventType)
    return KIPN.Server.EventObjectiveRegistry
        and KIPN.Server.EventObjectiveRegistry.Get(eventType) ~= nil
end

-- A Definition's configuration can only be edited while it's DRAFT
-- or READY -- once it's been Announced/opened for Joining/gone
-- Active/is Ending/Completed, its config is frozen until EVENT_RESET
-- brings it back to DRAFT.
local EDITABLE_STATUSES = {
    DRAFT = true,
    READY = true,
}

local function isEditableStatus(status)
    return EDITABLE_STATUSES[status] == true
end

local function sanitizeSpawnRules(rawSpawnRules)
    -- Opaque bag owned/interpreted only by the registered eventType
    -- (see KIPN_ZombieDirector.lua for Horde Survival's fields).
    return type(rawSpawnRules) == "table" and rawSpawnRules or {}
end

local function sanitizeEnvironment(rawEnvironment)
    rawEnvironment = type(rawEnvironment) == "table" and rawEnvironment or {}

    local timeOfDay = rawEnvironment.timeOfDay
    local weatherPreset = rawEnvironment.weatherPreset

    return {
        timeOfDay = ENVIRONMENT_TIME_OF_DAY_VALUES[timeOfDay] and timeOfDay or nil,
        weatherPreset = ENVIRONMENT_WEATHER_PRESET_VALUES[weatherPreset] and weatherPreset or nil,
    }
end

local function sanitizeCombatRules(rawRules)
    rawRules = type(rawRules) == "table" and rawRules or {}

    return {
        allowLeaveZone = rawRules.allowLeaveZone == true,
        pvpAllowedInZone = rawRules.pvpAllowedInZone == true,
    }
end

-- Phase 4: expiryBehavior defaults to WIN -- the exact behavior every
-- Event Definition has always had, since this field didn't exist
-- before this phase. See KIPN_EventTimerService.lua.
local function sanitizeDuration(rawDuration)
    rawDuration = type(rawDuration) == "table" and rawDuration or {}

    local durationSeconds = tonumber(rawDuration.durationSeconds)

    local expiryBehavior = (rawDuration.expiryBehavior == KIPN.Shared.EventTimerExpiryBehaviors.FAIL)
        and KIPN.Shared.EventTimerExpiryBehaviors.FAIL
        or KIPN.Shared.EventTimerExpiryBehaviors.WIN

    return {
        enabled = rawDuration.enabled == true and durationSeconds ~= nil and durationSeconds > 0,
        durationSeconds = durationSeconds,
        expiryBehavior = expiryBehavior,
    }
end

-- Phase 4: a Round Timer's duration, wholly separate from the
-- event-wide `duration` above -- a Round Timer definition (e.g. King
-- of the Hill's preset) measures one round, never the total event.
-- No expiryBehavior -- round timer expiry always means "complete the
-- current round" (see KIPN_EventRuntimeService.lua's
-- evaluateEndConditions), not an ambiguous choice.
local function sanitizeRoundDuration(rawDuration)
    rawDuration = type(rawDuration) == "table" and rawDuration or {}

    local durationSeconds = tonumber(rawDuration.durationSeconds)

    return {
        enabled = rawDuration.enabled == true and durationSeconds ~= nil and durationSeconds > 0,
        durationSeconds = durationSeconds,
    }
end

-- Phase 6: Capture mode config. flagItemFullType is deliberately
-- free-text, matching how reward items are already authored elsewhere
-- in this file (sanitizeRewardItems below) -- no vanilla item ID is
-- guessed/invented here; the admin supplies a real one, and
-- EVENT_VALIDATE (see handleValidate) rejects an empty value for a
-- CAPTURE-mode definition. autoReturnSeconds defaults to 90 -- an
-- explicit, data-driven, admin-editable rule (per the Capture mode
-- contract's "propose any auto-return timer as an explicit
-- data-driven rule rather than silently inventing it"), not a
-- silently hardcoded behavior.
local DEFAULT_CAPTURE_AUTO_RETURN_SECONDS = 90

local function sanitizeCaptureConfig(rawConfig)
    rawConfig = type(rawConfig) == "table" and rawConfig or {}

    local flagItemFullType = type(rawConfig.flagItemFullType) == "string"
        and rawConfig.flagItemFullType:match("^%s*(.-)%s*$")
        or ""

    local autoReturnSeconds = tonumber(rawConfig.autoReturnSeconds)
    if not autoReturnSeconds or autoReturnSeconds <= 0 then
        autoReturnSeconds = DEFAULT_CAPTURE_AUTO_RETURN_SECONDS
    end

    return {
        flagItemFullType = flagItemFullType,
        autoReturnSeconds = math.floor(autoReturnSeconds),
    }
end

local function sanitizeRewardItems(rawItems)
    local items = {}

    if type(rawItems) ~= "table" then
        return items
    end

    for _, row in ipairs(rawItems) do
        local itemFullType = type(row) == "table" and row.itemFullType

        if type(itemFullType) == "string" and itemFullType ~= "" then
            local count = tonumber(row.count) or 1

            items[#items + 1] = {
                itemFullType = itemFullType,
                count = math.max(1, math.floor(count)),
            }
        end
    end

    return items
end

-- Free-text goal checklist shown to participants (narrative-ish,
-- admin-authored). Distinct from objectiveTypes below, which is a
-- fixed mechanical enum selection.
local function sanitizeObjectiveNotes(rawNotes)
    local notes = {}

    if type(rawNotes) ~= "table" then
        return notes
    end

    for index, row in ipairs(rawNotes) do
        if index > OBJECTIVES_MAX_ROWS then
            break
        end

        local text = type(row) == "table" and row.text or (type(row) == "string" and row) or nil
        text = type(text) == "string" and text:match("^%s*(.-)%s*$") or ""

        if text ~= "" then
            notes[#notes + 1] = { id = "objective_" .. tostring(index), text = text }
        end
    end

    return notes
end

------------------------------------------------------------
-- COMPOSABLE COMPONENTS (KIPN.Shared.EventObjectiveTypes/
-- EventTimerTypes/EventOutcomeTypes)
--
-- Fixed shared enums, not a per-eventType registry lookup like
-- winConditions/failConditions above. See KIPN_Shared.lua's
-- "IMPLEMENTATION STATUS" comment on these tables -- selections are
-- validated and persisted here, but have no mechanical evaluator
-- yet. Horde Survival's actual gameplay logic remains driven by
-- spawnRules/winConditions/failConditions, unaffected by this.
------------------------------------------------------------

local function sanitizeEnumList(rawList, validValues, maxRows)
    local result = {}

    if type(rawList) ~= "table" then
        return result
    end

    local seen = {}

    for index, value in ipairs(rawList) do
        if index > maxRows then
            break
        end

        if type(value) == "string" and validValues[value] and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end

    return result
end

local function sanitizeObjectiveTypes(rawObjectiveTypes)
    return sanitizeEnumList(rawObjectiveTypes, KIPN.Shared.EventObjectiveTypes, 8)
end

local function sanitizeOutcomeTypes(rawOutcomeTypes)
    return sanitizeEnumList(rawOutcomeTypes, KIPN.Shared.EventOutcomeTypes, 7)
end

local function sanitizeTimerType(rawTimerType)
    if type(rawTimerType) == "string" and KIPN.Shared.EventTimerTypes[rawTimerType] then
        return rawTimerType
    end

    return KIPN.Shared.EventTimerTypes.NONE
end

local function sanitizeRuleType(rawRuleType)
    if type(rawRuleType) == "string" and KIPN.Shared.EventRuleTypes[rawRuleType] then
        return rawRuleType
    end

    return KIPN.Shared.EventRuleTypes.PVE
end

local function sanitizeDirectorType(rawDirectorType)
    if type(rawDirectorType) == "string" and KIPN.Shared.EventDirectorTypes[rawDirectorType] then
        return rawDirectorType
    end

    return KIPN.Shared.EventDirectorTypes.ZOMBIE_WAVES
end

local function sanitizeScopeType(rawScopeType)
    if type(rawScopeType) == "string" and KIPN.Shared.EventScopeTypes[rawScopeType] then
        log("sanitizeScopeType() -> " .. rawScopeType)
        return rawScopeType
    end
    log("sanitizeScopeType() -> ZONE")
    return KIPN.Shared.EventScopeTypes.ZONE
end

local function sanitizeMaxRounds(rawMaxRounds)
    local value = math.max(1, math.min(10, math.floor(tonumber(rawMaxRounds) or 1)))
    log("sanitizeMaxRounds() -> " .. tostring(value))
    return value
end

local function sanitizeZombieTheme(rawTheme)
    local registry = KIPN.Server.EventZombieThemeRegistry
    local result = registry and registry.NormalizeSelection
        and registry.NormalizeSelection(rawTheme)
        or { themeId = "RANDOM", categories = {} }
    log("sanitizeZombieTheme() -> " .. tostring(result.themeId))
    return result
end

local function sanitizeRewardDeliveryMethod(rawMethod)
    if type(rawMethod) == "string" and KIPN.Shared.EventRewardDeliveryMethods[rawMethod] then
        log("sanitizeRewardDeliveryMethod() -> " .. rawMethod)
        return rawMethod
    end
    log("sanitizeRewardDeliveryMethod() -> ADMIN_DELIVERY")
    return KIPN.Shared.EventRewardDeliveryMethods.ADMIN_DELIVERY
end

local function sanitizeScenarioPresetId(rawPresetId)
    if type(rawPresetId) == "string" and KIPN.Shared.EventScenarioPresets[rawPresetId] then
        log("sanitizeScenarioPresetId() -> " .. rawPresetId)
        return rawPresetId
    end
    log("sanitizeScenarioPresetId() -> nil")
    return nil
end

-- Schema v2 (Event Scenarios architecture rewrite, Phase 1). Accepts
-- an explicit (mode, variant) pair -- e.g. from a future Mode picker
-- UI -- falling back to nil/nil for anything unrecognized rather than
-- guessing. Non-Extraction modes always resolve variant to nil.
local function sanitizeModeAndVariant(rawMode, rawVariant)
    if type(rawMode) ~= "string" or not KIPN.Server.EventModeRegistry.IsValidMode(rawMode) then
        return nil, nil
    end

    -- Any mode with variants keeps a valid one (Extraction's four, and
    -- Capture's Team CTF / FFA). Keeping only Extraction's dropped every
    -- Capture variant on save, so Capture always failed validation with
    -- CAPTURE_VARIANT_REQUIRED.
    if type(rawVariant) == "string"
        and KIPN.Server.EventModeRegistry.IsValidVariant(rawMode, rawVariant)
    then
        return rawMode, rawVariant
    end

    return rawMode, nil
end

-- Schema v2. { [modifierId] = true, ... }, filtered against the known
-- modifier vocabulary -- unrecognized keys and non-true values are
-- silently dropped rather than persisted.
local function sanitizeModifiers(rawModifiers)
    local modifiers = {}

    if type(rawModifiers) ~= "table" then
        return modifiers
    end

    for modifierId, enabled in pairs(rawModifiers) do
        if enabled == true and KIPN.Shared.EventModifiers[modifierId] then
            modifiers[modifierId] = true
        end
    end

    return modifiers
end

------------------------------------------------------------
-- RULE TYPE -> COMBAT RULES DERIVATION
------------------------------------------------------------
--
-- ruleType is the single authoritative choice; combatRules.
-- pvpAllowedInZone is derived from it so there's one source of
-- truth, EXCEPT for CUSTOM, which leaves whatever the admin
-- explicitly submitted in combatRules alone. NO_COMBAT's real
-- enforcement (blocking ALL damage, not just PvP) lives in
-- KIPN_EventRuntimeService.lua's onWeaponHitCharacter -- this
-- function only derives the PvP flag, since NO_COMBAT's stronger
-- block doesn't need pvpAllowedInZone to be true or false to work.
------------------------------------------------------------

local RULE_TYPE_PVP_DEFAULT = {
    PVE = false,
    PVP = true,
    TEAM = true,
    FREE_FOR_ALL = true,
    NO_COMBAT = false,
}

local function applyRuleTypeToCombatRules(definition)
    if definition.ruleType == KIPN.Shared.EventRuleTypes.CUSTOM then
        return
    end

    local pvpDefault = RULE_TYPE_PVP_DEFAULT[definition.ruleType]

    if pvpDefault == nil then
        return
    end

    definition.combatRules = definition.combatRules or {}
    definition.combatRules.pvpAllowedInZone = pvpDefault
end

-- Shared by winConditions/failConditions -- keeps only entries whose
-- conditionId is actually registered for eventType, per isValid().
local function sanitizeConditions(rawConditions, eventType, isValid)
    local conditions = {}

    if type(rawConditions) ~= "table" or not eventType then
        return conditions
    end

    for index, row in ipairs(rawConditions) do
        if index > CONDITIONS_MAX_ROWS then
            break
        end

        local conditionId = type(row) == "table" and row.conditionId

        if type(conditionId) == "string" and isValid(eventType, conditionId) then
            conditions[#conditions + 1] = {
                conditionId = conditionId,
                params = (type(row.params) == "table") and row.params or {},
            }
        end
    end

    return conditions
end

local function sanitizeWinConditions(rawConditions, eventType)
    return sanitizeConditions(rawConditions, eventType, KIPN.Server.EventObjectiveRegistry.IsValidWinCondition)
end

local function sanitizeFailConditions(rawConditions, eventType)
    return sanitizeConditions(rawConditions, eventType, KIPN.Server.EventObjectiveRegistry.IsValidFailCondition)
end

local function sanitizeNarrative(rawNarrative)
    rawNarrative = type(rawNarrative) == "table" and rawNarrative or {}

    local function cleanText(value)
        if type(value) ~= "string" then
            return ""
        end

        return value:match("^%s*(.-)%s*$")
    end

    return {
        briefing = cleanText(rawNarrative.briefing),
        winText = cleanText(rawNarrative.winText),
        failText = cleanText(rawNarrative.failText),
    }
end

------------------------------------------------------------
-- COMMAND HANDLERS: DEFINITION CRUD
------------------------------------------------------------

local function handleListDefinitions(player, args)
    if not requireAdmin(player) then
        return false
    end

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITIONS_DATA, {
        definitions = EventScenarioService.ListDefinitions(),
    })

    return true
end

local function handleCreateDefinition(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local name = type(args.name) == "string" and args.name:match("^%s*(.-)%s*$") or ""

    if name == "" then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
            success = false,
            reason = "NAME_REQUIRED",
        })
        return true
    end

    local eventType = args.eventType

    if not isValidEventType(eventType) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
            success = false,
            reason = "INVALID_EVENT_TYPE",
        })
        return true
    end

    local definitions = getDefinitionCollection()

    if not definitions then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
            success = false,
            reason = "STORAGE_UNAVAILABLE",
        })
        return true
    end

    local id = generateDefinitionId()
    local now = getWorldDays()

    local definition = {
        id = id,
        name = name,
        status = EventScenarioService.Status.DRAFT,
        eventType = eventType,
        spawnRules = sanitizeSpawnRules(args.spawnRules),
        zoneId = nil,
        environment = sanitizeEnvironment(args.environment),
        combatRules = sanitizeCombatRules(args.combatRules),
        ruleType = sanitizeRuleType(args.ruleType),
        directorType = sanitizeDirectorType(args.directorType),
        scenarioPresetId = sanitizeScenarioPresetId(args.scenarioPresetId),
        scopeType = sanitizeScopeType(args.scopeType),
        maxRounds = sanitizeMaxRounds(args.maxRounds),
        hotspots = KIPN.Server.EventHotspotService.NormalizeHotspots(args.hotspots, id),
        zombieTheme = sanitizeZombieTheme(args.zombieTheme),
        rewardDeliveryMethod = sanitizeRewardDeliveryMethod(args.rewardDeliveryMethod),
        duration = sanitizeDuration(args.duration),
        roundDuration = sanitizeRoundDuration(args.roundDuration),
        captureConfig = sanitizeCaptureConfig(args.captureConfig),
        timerType = sanitizeTimerType(args.timerType),
        participants = {},
        objectiveNotes = sanitizeObjectiveNotes(args.objectiveNotes),
        objectives = KIPN.Server.EventTriggerService.SanitizeObjectives(args.objectives),
        objectiveTypes = sanitizeObjectiveTypes(args.objectiveTypes),
        outcomeTypes = sanitizeOutcomeTypes(args.outcomeTypes),
        winConditions = sanitizeWinConditions(args.winConditions, eventType),
        failConditions = sanitizeFailConditions(args.failConditions, eventType),
        rewards = { items = sanitizeRewardItems(args.rewardItems) },
        narrative = sanitizeNarrative(args.narrative),
        createdAtWorldDays = now,
        updatedAtWorldDays = now,
        metadata = { createdBy = player and player:getUsername() or "Unknown" },
    }

    applyRuleTypeToCombatRules(definition)

    -- Schema v2: derive mode/variant/migrationStatus from
    -- scenarioPresetId immediately, the same way boot-time migration
    -- would, so a brand new CAPTURE/KOTH/CHASE/Extraction-preset event
    -- isn't stuck at v1 until the next restart. An explicit
    -- args.mode/args.modifiers (e.g. from a future Mode picker UI)
    -- overrides the preset-derived guess.
    migrateDefinitionToV2(definition)

    if args.mode ~= nil then
        definition.mode, definition.variant = sanitizeModeAndVariant(args.mode, args.variant)
        definition.migrationStatus = KIPN.Shared.EventMigrationStatus.NATIVE
    end

    if args.modifiers ~= nil then
        definition.modifiers = sanitizeModifiers(args.modifiers)
    end

    definitions[id] = definition

    KIPN.Server.Save()

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_DEFINITION_CREATED", "eventDefinition", id, { name = name })

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
        success = true,
        definition = definition,
    })

    log("Definition created: id=" .. id .. " name=" .. name)

    return true
end

local function handleUpdateDefinition(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    if not isEditableStatus(definition.status) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
            success = false,
            reason = "NOT_EDITABLE",
        })
        return true
    end

    if type(args.name) == "string" then
        local name = args.name:match("^%s*(.-)%s*$")

        if name ~= "" then
            definition.name = name
        end
    end

    if args.eventType then
        if not isValidEventType(args.eventType) then
            KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
                success = false,
                reason = "INVALID_EVENT_TYPE",
            })
            return true
        end

        definition.eventType = args.eventType
    end

    if type(args.spawnRules) == "table" then
        definition.spawnRules = sanitizeSpawnRules(args.spawnRules)
    end

    if args.environment then
        definition.environment = sanitizeEnvironment(args.environment)
    end

    if args.combatRules then
        definition.combatRules = sanitizeCombatRules(args.combatRules)
    end

    if args.ruleType then
        definition.ruleType = sanitizeRuleType(args.ruleType)
        applyRuleTypeToCombatRules(definition)
    end

    if args.directorType then
        definition.directorType = sanitizeDirectorType(args.directorType)
    end

    if args.scenarioPresetId ~= nil then
        definition.scenarioPresetId = sanitizeScenarioPresetId(args.scenarioPresetId)
        -- Re-derive mode/variant/migrationStatus to match the new
        -- preset, same as a fresh create -- see migrateDefinitionToV2.
        migrateDefinitionToV2(definition)
    end

    if args.mode ~= nil then
        definition.mode, definition.variant = sanitizeModeAndVariant(args.mode, args.variant)
        definition.migrationStatus = KIPN.Shared.EventMigrationStatus.NATIVE
    end

    if args.modifiers ~= nil then
        definition.modifiers = sanitizeModifiers(args.modifiers)
    end

    if args.scopeType then
        definition.scopeType = sanitizeScopeType(args.scopeType)
    end

    if args.maxRounds then
        definition.maxRounds = sanitizeMaxRounds(args.maxRounds)
    end

    if args.hotspots then
        definition.hotspots = KIPN.Server.EventHotspotService.NormalizeHotspots(args.hotspots, definition.id)
    end

    if args.zombieTheme then
        definition.zombieTheme = sanitizeZombieTheme(args.zombieTheme)
    end

    if args.rewardDeliveryMethod then
        definition.rewardDeliveryMethod = sanitizeRewardDeliveryMethod(args.rewardDeliveryMethod)
    end

    if args.duration then
        definition.duration = sanitizeDuration(args.duration)
    end

    if args.roundDuration then
        definition.roundDuration = sanitizeRoundDuration(args.roundDuration)
    end

    if args.captureConfig then
        definition.captureConfig = sanitizeCaptureConfig(args.captureConfig)
    end

    -- Classic-scenario pieces: starting loadout, difficulty, threats,
    -- Survivor Run's last-one-standing rule, and which template it came from.
    if args.loadout ~= nil then
        definition.loadout = (KIPN.Shared.EventLoadouts or {})[args.loadout] and args.loadout or "NONE"
    end
    if args.difficulty ~= nil then
        definition.difficulty = (KIPN.Shared.EventDifficulties or {})[args.difficulty] and args.difficulty or "NORMAL"
    end
    if type(args.threats) == "table" then
        definition.threats = {}
        for _, threat in ipairs(KIPN.Shared.EventThreatOrder or {}) do
            definition.threats[threat] = args.threats[threat] == true
        end
    end
    if type(args.survivorConfig) == "table" then
        definition.survivorConfig = { lastStanding = args.survivorConfig.lastStanding == true }
    end
    if args.classicScenario ~= nil then
        definition.classicScenario = (KIPN.Shared.EventClassicScenarios or {})[args.classicScenario] and args.classicScenario or nil
    end

    -- The Olympics: heat size (1-4 racing at once), how long a heat
    -- may run before an athlete is a DNF, and the course template.
    if type(args.olympicsConfig) == "table" then
        definition.olympicsConfig = {
            heatSize = math.max(1, math.min(4, math.floor(tonumber(args.olympicsConfig.heatSize) or 2))),
            heatLimitSeconds = math.max(60, math.min(3600, math.floor(tonumber(args.olympicsConfig.heatLimitSeconds) or 600))),
            discipline = type(args.olympicsConfig.discipline) == "string" and args.olympicsConfig.discipline:sub(1, 40) or nil,
        }
    end

    if args.timerType then
        definition.timerType = sanitizeTimerType(args.timerType)
    end

    if args.objectiveNotes then
        definition.objectiveNotes = sanitizeObjectiveNotes(args.objectiveNotes)
    end

    if args.objectives then
        definition.objectives = KIPN.Server.EventTriggerService.SanitizeObjectives(args.objectives)
    end

    if args.objectiveTypes then
        definition.objectiveTypes = sanitizeObjectiveTypes(args.objectiveTypes)
    end

    if args.outcomeTypes then
        definition.outcomeTypes = sanitizeOutcomeTypes(args.outcomeTypes)
    end

    if args.winConditions then
        definition.winConditions = sanitizeWinConditions(args.winConditions, definition.eventType)
    end

    if args.failConditions then
        definition.failConditions = sanitizeFailConditions(args.failConditions, definition.eventType)
    end

    if args.rewardItems then
        definition.rewards = { items = sanitizeRewardItems(args.rewardItems) }
    end

    if args.narrative then
        definition.narrative = sanitizeNarrative(args.narrative)
    end

    -- Status transitions are NOT automatic anymore -- reaching READY
    -- requires an explicit EVENT_VALIDATE call (see handleValidate
    -- below). Saving a DRAFT no longer silently promotes it.

    definition.updatedAtWorldDays = getWorldDays()

    KIPN.Server.Save()

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_SAVED, {
        success = true,
        definition = definition,
    })

    return true
end

local function handleDeleteDefinition(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definitions = getDefinitionCollection()
    local definition = definitions and definitions[tostring(args.id)]

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_DELETED, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    if not isEditableStatus(definition.status) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_DELETED, {
            success = false,
            reason = "NOT_EDITABLE",
        })
        return true
    end

    definitions[tostring(args.id)] = nil

    KIPN.Server.Save()

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_DEFINITION_DELETED", "eventDefinition", tostring(args.id), {})

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DEFINITION_DELETED, {
        success = true,
        id = args.id,
    })

    return true
end

------------------------------------------------------------
-- COMMAND HANDLER: EVENT TYPE METADATA
------------------------------------------------------------
--
-- Lets the definition editor fetch the registered controls/win/fail
-- conditions for a given eventType so the admin can pick from the
-- real registered list rather than the client hardcoding anything
-- beyond the eventType names themselves.
------------------------------------------------------------

local function handleGetEventTypeMetadata(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local eventType = args.eventType

    if not isValidEventType(eventType) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_EVENTTYPE_METADATA_DATA, {
            success = false,
            reason = "INVALID_EVENT_TYPE",
        })
        return true
    end

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_EVENTTYPE_METADATA_DATA, {
        success = true,
        eventType = eventType,
        controls = KIPN.Server.EventObjectiveRegistry.GetControls(eventType),
        winConditions = KIPN.Server.EventObjectiveRegistry.GetWinConditions(eventType),
        failConditions = KIPN.Server.EventObjectiveRegistry.GetFailConditions(eventType),
    })

    return true
end

------------------------------------------------------------
-- ZONE SYNC BROADCAST
------------------------------------------------------------
--
-- Mirrors KIPN_ZoneAdminServer.lua's buildZoneSyncPayload()/
-- broadcastZoneSync() exactly (both private `local function`s there,
-- so duplicated here rather than reaching into that file -- same
-- precedent already established for WorldRegistry's rectangle math).
-- Needed so a dynamically-created Event Zone shows up on every
-- client's public world map immediately, same as one drawn through
-- the classic Zone Admin tool.
------------------------------------------------------------

local function buildZoneSyncPayload()
    local zones = KIPN.Server.WorldRegistry.GetZones()
    local list = {}

    for zoneId, zone in pairs(zones) do
        if zone.active ~= false then
            list[#list + 1] = {
                id = zoneId,
                type = zone.type,
                geometry = zone.geometry,
                label = zone.metadata and zone.metadata.label or nil,
                combatPolicy = zone.combatPolicy,
            }
        end
    end

    return list
end

local function broadcastZoneSync()
    local online = getOnlinePlayers()

    if not online then
        return
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)

        if p then
            sendServerCommand(p, ZONE_ADMIN_MODULE_NAME, "ZoneSync", { zones = buildZoneSyncPayload() })
        end
    end
end

------------------------------------------------------------
-- COMMAND HANDLER: DYNAMIC ZONE CREATION
------------------------------------------------------------
--
-- The primary Event Zone path: the admin draws two corners on the
-- map from the Event Definition editor itself, and this handler
-- creates the WorldRegistry zone (zoneType "event") AND links it to
-- the definition in one step. See the file header for why this
-- replaces a separate "draw, then pick from a list" flow.
------------------------------------------------------------

local function validatePoint(point)
    if type(point) ~= "table" then
        return false
    end

    return tonumber(point.x) ~= nil and tonumber(point.y) ~= nil
end

local function handleCreateZoneFromCorners(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    if not isEditableStatus(definition.status) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "NOT_EDITABLE",
        })
        return true
    end

    if not validatePoint(args.cornerA) or not validatePoint(args.cornerB) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "CORNERS_REQUIRED",
        })
        return true
    end

    local zone, reason = KIPN.Server.WorldRegistry.CreateZoneFromCorners(
        KIPN.Server.WorldRegistry.ZoneTypes.EVENT,
        args.cornerA,
        args.cornerB,
        {
            label = definition.name .. " Zone",
            createdBy = player and player:getUsername() or "Unknown",
            eventDefinitionId = definition.id,
        }
    )

    if not zone then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = reason or "ZONE_CREATE_FAILED",
        })
        return true
    end

    definition.zoneId = zone.id
    definition.updatedAtWorldDays = getWorldDays()

    KIPN.Server.Save()

    broadcastZoneSync()

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_ZONE_CREATED", "eventDefinition", definition.id, { zoneId = zone.id })

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
        success = true,
        definition = definition,
        zone = zone,
    })

    log("Dynamic event zone created and linked: definitionId=" .. definition.id .. " zoneId=" .. tostring(zone.id))

    return true
end

------------------------------------------------------------
-- COMMAND HANDLER: SET ZONE (manual relink fallback)
------------------------------------------------------------
--
-- Links an EXISTING WorldRegistry zone (zoneType "event") to a
-- Definition -- e.g. one drawn through the classic Zone Admin tool,
-- or to relink after the original zone was deactivated. The primary
-- path is EVENT_CREATE_ZONE_FROM_CORNERS above.
------------------------------------------------------------

local function handleSetZone(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    if not isEditableStatus(definition.status) then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "NOT_EDITABLE",
        })
        return true
    end

    local zone = KIPN.Server.WorldRegistry.GetZone(args.zoneId)

    if not zone or zone.active == false then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "ZONE_NOT_FOUND_OR_INACTIVE",
        })
        return true
    end

    if zone.type ~= KIPN.Server.WorldRegistry.ZoneTypes.EVENT then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
            success = false,
            reason = "NOT_AN_EVENT_ZONE",
        })
        return true
    end

    definition.zoneId = zone.id
    definition.updatedAtWorldDays = getWorldDays()

    KIPN.Server.Save()

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ZONE_SAVED, {
        success = true,
        definition = definition,
    })

    return true
end

------------------------------------------------------------
-- LIFECYCLE STAGE TRANSITIONS
--
-- DRAFT -> [Validate] -> READY -> [Announce] -> ANNOUNCED
--       -> [Open Joining] -> JOINING -> [Start] -> ACTIVE
--       -> [Stop / win / fail / timer] -> ENDING -> COMPLETE
--       -> [Reset] -> CLEANUP -> DRAFT
--
-- EVENT_START/EVENT_STOP (JOINING->ACTIVE, and any live stage->
-- ENDING->COMPLETE) are owned by KIPN_EventRuntimeService.lua, not
-- here -- this section owns only the stages that never touch the
-- Event Runtime.
------------------------------------------------------------

local function broadcastToAllOnline(text)
    if not text or text == "" then
        return
    end

    local online = getOnlinePlayers()

    if not online then
        return
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)

        if p then
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_NARRATIVE, { text = text })
        end
    end
end

local function respondStatusChanged(player, success, definition, reason)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_STATUS_CHANGED, {
        success = success,
        definition = success and definition or nil,
        reason = (not success) and reason or nil,
    })
end

-- DRAFT -> READY. There is no async validation work, so VALIDATING
-- is set and immediately resolved within this single call -- it is
-- never observed as a persisted status by the client.
local function handleValidate(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        respondStatusChanged(player, false, nil, "DEFINITION_NOT_FOUND")
        return true
    end

    if definition.status ~= EventScenarioService.Status.DRAFT then
        respondStatusChanged(player, false, nil, "NOT_DRAFT")
        return true
    end

    definition.status = EventScenarioService.Status.VALIDATING

    local failures = {}

    if not isValidEventType(definition.eventType) then
        failures[#failures + 1] = "INVALID_EVENT_TYPE"
    end

    local name = type(definition.name) == "string"
        and definition.name:match("^%s*(.-)%s*$")
        or ""

    if name == "" then
        failures[#failures + 1] = "NAME_REQUIRED"
    end

    if type(definition.objectiveTypes) ~= "table" or #definition.objectiveTypes == 0 then
        failures[#failures + 1] = "NO_OBJECTIVE_TYPE"
    end

    if type(definition.outcomeTypes) ~= "table" or #definition.outcomeTypes == 0 then
        failures[#failures + 1] = "NO_OUTCOME_TYPE"
    end

    -- Phase 4: a Round Timer definition is validated against its own
    -- roundDuration, not the event-wide duration -- see
    -- KIPN_EventTimerService.lua's header for why these are two
    -- separate fields now. Every other non-NONE timerType still
    -- validates the event-wide duration exactly as before.
    local isRoundTimer = definition.timerType == KIPN.Shared.EventTimerTypes.ROUND_TIMER
    local timerEnabled = definition.timerType
        and definition.timerType ~= KIPN.Shared.EventTimerTypes.NONE

    if isRoundTimer then
        local roundDurationEnabled = definition.roundDuration
            and definition.roundDuration.enabled == true
        local roundDurationSeconds = tonumber(
            definition.roundDuration and definition.roundDuration.durationSeconds
        ) or 0

        if not roundDurationEnabled then
            failures[#failures + 1] = "ROUND_TIMER_DURATION_REQUIRED"
        elseif roundDurationSeconds <= 0 then
            failures[#failures + 1] = "INVALID_ROUND_DURATION"
        end
    elseif timerEnabled then
        local durationEnabled = definition.duration
            and definition.duration.enabled == true
        local durationSeconds = tonumber(
            definition.duration and definition.duration.durationSeconds
        ) or 0

        if not durationEnabled then
            failures[#failures + 1] = "TIMER_DURATION_REQUIRED"
        elseif durationSeconds <= 0 then
            failures[#failures + 1] = "INVALID_DURATION"
        end
    end

    local scopeType = sanitizeScopeType(definition.scopeType)

    if scopeType == KIPN.Shared.EventScopeTypes.ZONE then
        if not definition.zoneId then
            failures[#failures + 1] = "NO_ZONE"
        else
            local zone = KIPN.Server.WorldRegistry.GetZone(definition.zoneId)
            if not zone or zone.active == false then failures[#failures + 1] = "ZONE_INACTIVE" end
        end
    end

    local hotspotsOk, hotspotFailures = KIPN.Server.EventHotspotService.ValidateDefinition(definition)
    if not hotspotsOk then
        for _, failure in ipairs(hotspotFailures) do
            failures[#failures + 1] = failure
        end
    end

    -- Schema v2: a definition descended from a legacy Scenario Preset
    -- that could not be safely mapped onto a Mode/Variant must not
    -- reach READY until an admin reviews and reassigns it -- see
    -- migrateDefinitionToV2(). NATIVE (never had a preset) and
    -- MIGRATED definitions are unaffected.
    if definition.migrationStatus == KIPN.Shared.EventMigrationStatus.LEGACY_REVIEW_REQUIRED then
        failures[#failures + 1] = "LEGACY_DEFINITION_REQUIRES_REVIEW"
    end

    -- Schema v2: Naked and Afraid compatibility is checked against
    -- the explicit matrix in KIPN_EventModeRegistry.lua rather than
    -- guessed from labels. A definition with no known mode (nil, or
    -- LEGACY_REVIEW_REQUIRED above) can't be verified compatible, so
    -- IsModifierCompatible correctly reports UNKNOWN_MODE for it.
    if definition.modifiers and definition.modifiers[KIPN.Shared.EventModifiers.NAKED_AND_AFRAID] then
        local modifierOk, modifierReason = KIPN.Server.EventModeRegistry.IsModifierCompatible(
            KIPN.Shared.EventModifiers.NAKED_AND_AFRAID,
            definition.mode,
            definition.variant
        )

        if not modifierOk then
            failures[#failures + 1] = modifierReason or "MODIFIER_INCOMPATIBLE"
        end
    end

    -- Phase 2/6: a resolved Mode+Variant that actually uses teams
    -- (team KOTH, Team CTF Capture -- see
    -- KIPN_EventModeRegistry.lua's ModeUsesTeams(), which is
    -- variant-aware because FFA Capture explicitly does not use
    -- teams) must have at least two valid teams before it can go
    -- READY. Unresolved-mode definitions (nil mode) skip this --
    -- they're already blocked above by
    -- LEGACY_DEFINITION_REQUIRES_REVIEW if that's why mode is nil, or
    -- simply don't need teams if it's a NATIVE custom definition with
    -- no mode assigned yet.
    if definition.mode then
        if KIPN.Server.EventModeRegistry.ModeUsesTeams(definition.mode, definition.variant) then
            local teamsOk, teamFailures = KIPN.Server.EventTeamService.ValidateTeams(definition)

            if not teamsOk then
                for _, failure in ipairs(teamFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        -- Phase 6: Capture's own mode-specific requirements (flag
        -- item configured, variant chosen, per-round/per-team
        -- geometry present) -- see KIPN_EventCaptureService.lua's
        -- ValidateDefinition().
        if definition.mode == "CAPTURE" then
            local captureOk, captureFailures = KIPN.Server.EventCaptureService.ValidateDefinition(definition)

            if not captureOk then
                for _, failure in ipairs(captureFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        -- Phase 7: King of the Hill's own mode-specific requirement
        -- (HOLD_AREA objectiveType selected, so the existing shared
        -- round-control-dispatch component is actually reachable) --
        -- see KIPN_EventKOTHService.lua's ValidateDefinition(). Teams
        -- and per-round HILL_LOCATION hotspots are already enforced
        -- above (ModeUsesTeams) and by
        -- KIPN_EventHotspotService.ValidateDefinition()'s
        -- HOLD_AREA-gated hill checks once HOLD_AREA is selected.
        if definition.mode == "KING_OF_THE_HILL" then
            local kothOk, kothFailures = KIPN.Server.EventKOTHService.ValidateDefinition(definition)

            if not kothOk then
                for _, failure in ipairs(kothFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        -- Phase 8: Chase's own mode-specific requirement (CHASE_TARGET
        -- objectiveType selected, so the existing shared round-
        -- control-dispatch component and target-selection control are
        -- actually reachable) -- see KIPN_EventChaseService.lua's
        -- ValidateDefinition(). Chase has no teams (ModeUsesTeams is
        -- false for it) and no variant, so nothing else to check here.
        if definition.mode == "CHASE" then
            local chaseOk, chaseFailures = KIPN.Server.EventChaseService.ValidateDefinition(definition)

            if not chaseOk then
                for _, failure in ipairs(chaseFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        -- Phase 9: Extraction's own mode-specific requirements
        -- (a valid variant, that variant's required underlying
        -- objectiveType ticked, and Prison Break's extra
        -- EXTRACTION_POINT hotspot) -- see
        -- KIPN_EventExtractionService.lua's ValidateDefinition().
        if definition.mode == "EXTRACTION" then
            local extractionOk, extractionFailures = KIPN.Server.EventExtractionService.ValidateDefinition(definition)

            if not extractionOk then
                for _, failure in ipairs(extractionFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        -- Phase 10: Survivor Run's own mode-specific requirement (an
        -- enabled event duration, its only win path) -- see
        -- KIPN_EventSurvivorRunService.lua's ValidateDefinition().
        if definition.mode == "SURVIVOR_RUN" then
            local survivorRunOk, survivorRunFailures = KIPN.Server.EventSurvivorRunService.ValidateDefinition(definition)

            if not survivorRunOk then
                for _, failure in ipairs(survivorRunFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        -- Phase 11: Adventure's own mode-specific requirement (a Zone
        -- for its generated hotspots to be placed in) -- see
        -- KIPN_EventAdventureService.lua's ValidateDefinition(). Its
        -- other fields (hotspots/teams/objectiveTypes/timers) are
        -- generated fresh at event start, so nothing else is checked
        -- here.
        -- The Olympics: a start line, a finish line, and every
        -- station's drop zone / target range and item.
        if definition.mode == "OLYMPICS" then
            local olympicsOk, olympicsFailures = KIPN.Server.EventOlympicsService.ValidateDefinition(definition)

            if not olympicsOk then
                for _, failure in ipairs(olympicsFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end

        if definition.mode == "ADVENTURE" then
            local adventureOk, adventureFailures = KIPN.Server.EventAdventureService.ValidateDefinition(definition)

            if not adventureOk then
                for _, failure in ipairs(adventureFailures) do
                    failures[#failures + 1] = failure
                end
            end
        end
    end

    -- Phase 3: every referenced hotspot/objective/mode-action on the
    -- ordered story/trigger system must exist. No-op for definitions
    -- that don't use it (empty definition.objectives).
    local triggersOk, triggerFailures = KIPN.Server.EventTriggerService.ValidateDefinition(definition)
    if not triggersOk then
        for _, failure in ipairs(triggerFailures) do
            failures[#failures + 1] = failure
        end
    end

    if #failures > 0 then
        definition.status = EventScenarioService.Status.DRAFT
        KIPN.Server.Save()
        respondStatusChanged(player, false, nil, table.concat(failures, ","))
        return true
    end

    EventScenarioService.SetDefinitionStatus(definition.id, EventScenarioService.Status.READY)

    respondStatusChanged(player, true, definition)

    return true
end

-- READY -> ANNOUNCED. Broadcasts to EVERY online player (not just
-- the roster) since the point of announcing is to recruit.
local function handleAnnounce(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        respondStatusChanged(player, false, nil, "DEFINITION_NOT_FOUND")
        return true
    end

    if definition.status ~= EventScenarioService.Status.READY then
        respondStatusChanged(player, false, nil, "NOT_READY")
        return true
    end

    EventScenarioService.SetDefinitionStatus(definition.id, EventScenarioService.Status.ANNOUNCED)

    local announceText = (definition.narrative and definition.narrative.briefing ~= "" and definition.narrative.briefing)
        or ("An event is forming: " .. definition.name .. ". Sign-ups open soon.")

    broadcastToAllOnline(announceText)

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_ANNOUNCED", "eventDefinition", definition.id, {})

    respondStatusChanged(player, true, definition)

    return true
end

-- ANNOUNCED -> JOINING. Roster/teleport actions are meaningful from
-- this point on.
local function handleOpenJoining(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        respondStatusChanged(player, false, nil, "DEFINITION_NOT_FOUND")
        return true
    end

    if definition.status ~= EventScenarioService.Status.ANNOUNCED then
        respondStatusChanged(player, false, nil, "NOT_ANNOUNCED")
        return true
    end

    EventScenarioService.SetDefinitionStatus(definition.id, EventScenarioService.Status.JOINING)

    -- Every online player is asked to sign up; those who accept are
    -- brought in when the event begins.
    local inviteOk, inviteErr = pcall(KIPN.Server.EventParticipationService.BroadcastSignUpInvite, definition)
    if not inviteOk then log("BroadcastSignUpInvite failed: " .. tostring(inviteErr)) end

    respondStatusChanged(player, true, definition)

    return true
end

-- COMPLETE -> CLEANUP -> DRAFT. Keeps the definition's configuration
-- (including its linked zone) so it can be validated and run again
-- without rebuilding it from scratch. Participant roster is cleared
-- since the prior run's roster is stale.
local function handleReset(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        respondStatusChanged(player, false, nil, "DEFINITION_NOT_FOUND")
        return true
    end

    if definition.status ~= EventScenarioService.Status.COMPLETE then
        respondStatusChanged(player, false, nil, "NOT_COMPLETE")
        return true
    end

    definition.status = EventScenarioService.Status.CLEANUP
    definition.participants = {}
    definition.olympicsCountries = {}

    EventScenarioService.SetDefinitionStatus(definition.id, EventScenarioService.Status.DRAFT)

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_RESET", "eventDefinition", definition.id, {})

    respondStatusChanged(player, true, definition)

    return true
end

------------------------------------------------------------
-- COMMAND HANDLER: ONLINE PLAYERS
------------------------------------------------------------

local function handleListOnlinePlayers(player, args)
    if not requireAdmin(player) then
        return false
    end

    local players = {}
    local online = getOnlinePlayers()

    if online then
        for i = 0, online:size() - 1 do
            local p = online:get(i)

            if p then
                players[#players + 1] = {
                    username = p:getUsername(),
                }
            end
        end
    end

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_ONLINE_PLAYERS_DATA, {
        players = players,
    })

    return true
end

------------------------------------------------------------
-- COMMAND HANDLER: SET PARTICIPANTS
------------------------------------------------------------

local function handleSetParticipants(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_PARTICIPANTS_SAVED, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    local rosterEditable = definition.status == EventScenarioService.Status.DRAFT
        or definition.status == EventScenarioService.Status.READY
        or definition.status == EventScenarioService.Status.ANNOUNCED
        or definition.status == EventScenarioService.Status.JOINING

    if not rosterEditable then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_PARTICIPANTS_SAVED, {
            success = false,
            reason = "ROSTER_LOCKED_WHILE_ACTIVE",
        })
        log("handleSetParticipants() rejected status=" .. tostring(definition.status))
        return true
    end

    local participants = {}

    if type(args.usernames) == "table" then
        for _, username in ipairs(args.usernames) do
            if type(username) == "string" and username ~= "" then
                participants[username] = true
            end
        end
    end

    definition.participants = participants
    definition.updatedAtWorldDays = getWorldDays()

    KIPN.Server.Save()

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_PARTICIPANTS_SAVED, {
        success = true,
        definition = definition,
    })

    return true
end

------------------------------------------------------------
-- COMMAND HANDLER: TELEPORT PARTICIPANTS
------------------------------------------------------------
--
-- Teleport-in only -- no recall/return-teleport in v1 (explicitly
-- descoped). Always re-resolves live IsoPlayer references fresh via
-- getOnlinePlayers(), never trusting an earlier player-list
-- snapshot, since a participant may have reconnected since.
------------------------------------------------------------

local function getZoneEntryPoint(zoneId)
    local zone = KIPN.Server.WorldRegistry.GetZone(zoneId)

    if not zone or zone.active == false or type(zone.geometry) ~= "table" then
        return nil
    end

    local geometry = zone.geometry

    return {
        x = math.floor((geometry.x1 + geometry.x2) / 2),
        y = math.floor((geometry.y1 + geometry.y2) / 2),
        z = geometry.z1 or 0,
    }
end

local function getHotspotEntryPoint(definition)
    local hotspotService = KIPN.Server.EventHotspotService
    if not hotspotService then return nil end

    local preferredTypes = {
        KIPN.Shared.EventHotspotTypes.PLAYER_SPAWN,
        KIPN.Shared.EventHotspotTypes.TEAM_SPAWN,
        KIPN.Shared.EventHotspotTypes.HILL_LOCATION,
        KIPN.Shared.EventHotspotTypes.OBJECTIVE_LOCATION,
    }

    for _, hotspotType in ipairs(preferredTypes) do
        local hotspots = hotspotService.GetHotspots(definition, hotspotType)
        if #hotspots > 0 then return hotspotService.GetCenter(hotspots[1]) end
    end

    local anyHotspots = hotspotService.GetHotspots(definition)
    return #anyHotspots > 0 and hotspotService.GetCenter(anyHotspots[1]) or nil
end

local function handleTeleportParticipants(player, args)
    if not requireAdmin(player) then
        return false
    end

    args = args or {}

    local definition = EventScenarioService.GetDefinition(args.id)

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_TELEPORT_RESULT, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    local scopeType = sanitizeScopeType(definition.scopeType)
    local entryPoint = scopeType == KIPN.Shared.EventScopeTypes.ZONE
        and getZoneEntryPoint(definition.zoneId)
        or getHotspotEntryPoint(definition)

    if not entryPoint then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_TELEPORT_RESULT, {
            success = false,
            reason = "EVENT_DESTINATION_UNAVAILABLE",
        })
        return true
    end

    local results = {}
    local online = getOnlinePlayers()

    if online then
        for i = 0, online:size() - 1 do
            local p = online:get(i)
            local username = p and p:getUsername()

            if username and definition.participants[username] then
                local ok, err = pcall(KIPN.Server.EventMoveService.Player, p, entryPoint)

                results[#results + 1] = {
                    username = username,
                    ok = ok,
                    reason = (not ok) and tostring(err) or nil,
                }

                if not ok then
                    logError("Teleport failed for " .. username .. ": " .. tostring(err))
                end
            end
        end
    end

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_TELEPORT_PARTICIPANTS", "eventDefinition", definition.id, {
        count = #results,
    })

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_TELEPORT_RESULT, {
        success = true,
        results = results,
    })

    return true
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function EventScenarioService.Initialize()
    resetStaleRunningDefinitions()
    migrateDefinitionSchema()

    -- Initialize() runs from OnInitGlobalModData, before
    -- GameServer.udpEngine exists. Establish the comparison baseline
    -- directly instead of calling syncQueueStateIfChanged(), whose
    -- job includes broadcasting to online players. The first real
    -- status transition still calls that function and broadcasts
    -- normally after server startup.
    lastBroadcastQueueState = EventScenarioService.HasQueuedEvent()

    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_LIST_DEFINITIONS, handleListDefinitions)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_CREATE_DEFINITION, handleCreateDefinition)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_UPDATE_DEFINITION, handleUpdateDefinition)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_DELETE_DEFINITION, handleDeleteDefinition)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_GET_EVENTTYPE_METADATA, handleGetEventTypeMetadata)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_CREATE_ZONE_FROM_CORNERS, handleCreateZoneFromCorners)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SET_ZONE, handleSetZone)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_VALIDATE, handleValidate)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_ANNOUNCE, handleAnnounce)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_OPEN_JOINING, handleOpenJoining)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_RESET, handleReset)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_LIST_ONLINE_PLAYERS, handleListOnlinePlayers)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_SET_PARTICIPANTS, handleSetParticipants)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_TELEPORT_PARTICIPANTS, handleTeleportParticipants)

    return true
end

print("[KIPN] Event Scenario Service loaded")
