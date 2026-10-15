-- KIPN_EventTriggerService.lua
--
-- Phase 3 of the Event Scenarios architecture rewrite: one reusable
-- ordered-objective/story engine plus a single proximity/timed/manual
-- trigger-and-action framework, shared by every use case (zombie
-- spawns, loot, hints, narrative, alarms, objective progression) --
-- not separate incompatible systems per hotspot type.
--
-- SCHEMA (definition.objectives, additive on top of the existing
-- Event Definition -- see KIPN_EventScenarioService.lua's header):
--
--   definition.objectives = {
--       {
--           id, name,
--           triggers = {
--               {
--                   id,
--                   activationMode,      -- KIPN.Shared.EventTriggerActivationModes.*
--                   hotspotId,           -- required for PROXIMITY
--                   delaySeconds,        -- required for TIME_SINCE_*
--                   actions = { { type = KIPN.Shared.EventTriggerActionTypes.*, params = {...} }, ... },
--                   scope,               -- GLOBAL | PER_PLAYER
--                   targetFilter,        -- nil/"ANY" | "TEAM:<id>" | "ROLE:TARGET"/"ROLE:HUNTER" | "PARTICIPANT:<username>"
--                   repeatable, cooldownSeconds, maxActivations, probability,
--                   roundNumber,         -- nil = any round
--                   background,          -- true = evaluated even when not the active objective
--               },
--           },
--       },
--   }
--
-- Only the objective at runtime.storyState.activeObjectiveId's
-- triggers evaluate each tick, plus any trigger anywhere with
-- background=true. Runtime state (runtime.storyState,
-- runtime.triggerState, runtime.spawnedEventLoot) is authoritative-
-- timestamp-based (getTimestampMs(), never a raw client/Lua timer)
-- and idempotent within a server session -- see IMPLEMENTATION
-- STATUS below for what "within a server session" does and does not
-- cover.
--
-- IMPLEMENTATION STATUS: KIPN_EventRuntimeService.lua's entire Event
-- Runtime is still never persisted across a server restart (see that
-- file's header) -- this phase does not change that. Trigger/story
-- state therefore survives reconnects and duplicate network packets
-- correctly (the actual gap this phase closes), but a full process
-- restart still loses it exactly like every other in-memory runtime
-- field, pending the dedicated runtime-persistence work flagged in
-- the Phase 1 architecture audit. Not a regression introduced here.
--
-- Zombie spawning and alarms reuse KIPN_ZombieDirector.lua's already-
-- proven spawnThemedZombies/triggerAlarm/getSpawnOrigin (exported for
-- this file, Phase 3) rather than reimplementing spawn logic --
-- meaning every trigger-driven zombie spawn is still bounded by that
-- file's existing maxZombies cap. Loot spawn/cleanup reuses the exact
-- KIPN.Server.CreateItem + square:AddWorldInventoryItem +
-- square:transmitRemoveItemFromSquare idiom already proven in
-- KIPN_ArtifactService.lua -- this is genuinely new capability (no
-- event loot system existed before this phase), built from already-
-- proven primitives, not an invented API.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_EventHotspotService"
require "KIPN_EventTeamService"
require "KIPN_ZombieDirector"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventTriggerService = KIPN.Server.EventTriggerService or {}

local TriggerService = KIPN.Server.EventTriggerService

local MAX_OBJECTIVES = 20
local MAX_TRIGGERS_PER_OBJECTIVE = 20
local MAX_ACTIONS_PER_TRIGGER = 10
local MAX_LOOT_ITEMS_PER_ACTION = 10

local function log(message)
    print("[KIPN EVENT TRIGGER] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT TRIGGER] ERROR: " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

------------------------------------------------------------
-- MODE-SPECIFIC ACTION EXTENSION POINT
--
-- Empty in Phase 3 by design -- no mode engine exists yet (see
-- KIPN_EventModeRegistry.lua's header, Phase 1). Later mode phases
-- register their own MODE_ACTION handlers here (e.g. Capture's flag
-- reset, Chase's forced target reselection) instead of this file
-- growing a per-mode if/elseif chain.
------------------------------------------------------------

local modeActions = {}

function TriggerService.RegisterModeAction(actionId, handler)
    if type(actionId) ~= "string" or type(handler) ~= "function" then
        logError("RegisterModeAction() rejected invalid registration for " .. tostring(actionId))
        return false
    end
    modeActions[actionId] = handler
    log("RegisterModeAction() -> " .. actionId)
    return true
end

------------------------------------------------------------
-- SANITIZATION (called from KIPN_EventScenarioService.lua's
-- create/update handlers, same pattern as
-- KIPN_EventHotspotService.NormalizeHotspots)
------------------------------------------------------------

local function sanitizeText(value, maxLength)
    if type(value) ~= "string" then return "" end
    local trimmed = value:match("^%s*(.-)%s*$")
    if maxLength and #trimmed > maxLength then trimmed = trimmed:sub(1, maxLength) end
    return trimmed
end

local function sanitizeAction(raw)
    if type(raw) ~= "table" then return nil end
    if type(raw.type) ~= "string" or not KIPN.Shared.EventTriggerActionTypes[raw.type] then return nil end

    return {
        type = raw.type,
        params = type(raw.params) == "table" and raw.params or {},
    }
end

local DEFAULT_GLOBAL_ACTION_TYPES = {
    SPAWN_ZOMBIES = true,
    SPAWN_LOOT = true,
    ALARM = true,
    SPAWN_BANDITS = true,
}

local function defaultScopeForActions(actions)
    for _, action in ipairs(actions) do
        if not DEFAULT_GLOBAL_ACTION_TYPES[action.type] then
            -- Any hint/narrative/announcement/objective/mode action
            -- present defaults the whole trigger to PER_PLAYER --
            -- "private hints and messages fire once per participant
            -- by default." A trigger mixing a global-flavored action
            -- (e.g. SPAWN_ZOMBIES) with a hint still defaults to
            -- PER_PLAYER once any non-global action is present; an
            -- admin who wants the zombie spawn to be GLOBAL while the
            -- hint is PER_PLAYER should use two separate triggers.
            return KIPN.Shared.EventTriggerScopes.PER_PLAYER
        end
    end
    return KIPN.Shared.EventTriggerScopes.GLOBAL
end

local function sanitizeTrigger(raw, index)
    if type(raw) ~= "table" then return nil end

    local activationMode = type(raw.activationMode) == "string"
        and KIPN.Shared.EventTriggerActivationModes[raw.activationMode]
        and raw.activationMode
        or nil

    if not activationMode then return nil end

    if activationMode == KIPN.Shared.EventTriggerActivationModes.PROXIMITY
        and (type(raw.hotspotId) ~= "string" or raw.hotspotId == "")
    then
        return nil
    end

    local actions = {}
    if type(raw.actions) == "table" then
        for actionIndex, rawAction in ipairs(raw.actions) do
            if actionIndex > MAX_ACTIONS_PER_TRIGGER then break end
            local action = sanitizeAction(rawAction)
            if action then actions[#actions + 1] = action end
        end
    end

    if #actions == 0 then return nil end

    local repeatable = raw.repeatable == true
    local maxActivations = math.max(1, math.floor(tonumber(raw.maxActivations) or 1))
    if not repeatable then maxActivations = 1 end

    local scope = (raw.scope == KIPN.Shared.EventTriggerScopes.GLOBAL
        or raw.scope == KIPN.Shared.EventTriggerScopes.PER_PLAYER)
        and raw.scope
        or defaultScopeForActions(actions)

    local probability = tonumber(raw.probability)
    if not probability or probability < 0 or probability > 1 then probability = 1.0 end

    return {
        id = sanitizeText(raw.id, 64) ~= "" and sanitizeText(raw.id, 64) or ("trigger_" .. tostring(index)),
        activationMode = activationMode,
        hotspotId = type(raw.hotspotId) == "string" and raw.hotspotId ~= "" and raw.hotspotId or nil,
        delaySeconds = math.max(0, math.floor(tonumber(raw.delaySeconds) or 0)),
        actions = actions,
        scope = scope,
        targetFilter = type(raw.targetFilter) == "string" and raw.targetFilter ~= "" and raw.targetFilter or nil,
        repeatable = repeatable,
        cooldownSeconds = math.max(0, math.floor(tonumber(raw.cooldownSeconds) or 0)),
        maxActivations = maxActivations,
        probability = probability,
        roundNumber = tonumber(raw.roundNumber) and math.floor(tonumber(raw.roundNumber)) or nil,
        background = raw.background == true,
    }
end

local function sanitizeObjective(raw, index)
    if type(raw) ~= "table" then return nil end

    local triggers = {}
    if type(raw.triggers) == "table" then
        for triggerIndex, rawTrigger in ipairs(raw.triggers) do
            if triggerIndex > MAX_TRIGGERS_PER_OBJECTIVE then break end
            local trigger = sanitizeTrigger(rawTrigger, triggerIndex)
            if trigger then triggers[#triggers + 1] = trigger end
        end
    end

    return {
        id = sanitizeText(raw.id, 64) ~= "" and sanitizeText(raw.id, 64) or ("objective_" .. tostring(index)),
        name = sanitizeText(raw.name, 200),
        triggers = triggers,
    }
end

function TriggerService.SanitizeObjectives(rawObjectives)
    local objectives = {}

    if type(rawObjectives) ~= "table" then
        return objectives
    end

    for index, raw in ipairs(rawObjectives) do
        if index > MAX_OBJECTIVES then break end
        local objective = sanitizeObjective(raw, index)
        if objective then objectives[#objectives + 1] = objective end
    end

    return objectives
end

------------------------------------------------------------
-- VALIDATION (called from KIPN_EventScenarioService.lua's
-- handleValidate, only when definition.objectives is non-empty --
-- definitions not using the story system are unaffected)
------------------------------------------------------------

function TriggerService.ValidateDefinition(definition)
    local failures = {}
    local objectives = (definition and definition.objectives) or {}

    if #objectives == 0 then
        return true, failures
    end

    local seenObjectiveIds = {}
    for _, objective in ipairs(objectives) do
        if seenObjectiveIds[objective.id] then
            failures[#failures + 1] = "DUPLICATE_OBJECTIVE_ID"
        end
        seenObjectiveIds[objective.id] = true
    end

    for _, objective in ipairs(objectives) do
        if #objective.triggers == 0 then
            failures[#failures + 1] = "OBJECTIVE_HAS_NO_TRIGGERS"
        end

        for _, trigger in ipairs(objective.triggers) do
            if trigger.activationMode == KIPN.Shared.EventTriggerActivationModes.PROXIMITY then
                local hotspot = trigger.hotspotId
                    and KIPN.Server.EventHotspotService.FindById(definition, trigger.hotspotId)
                if not hotspot then
                    failures[#failures + 1] = "TRIGGER_HOTSPOT_NOT_FOUND"
                end
            end

            for _, action in ipairs(trigger.actions) do
                if action.type == KIPN.Shared.EventTriggerActionTypes.ACTIVATE_OBJECTIVE then
                    local targetId = action.params and action.params.objectiveId
                    if not targetId or not seenObjectiveIds[targetId] then
                        failures[#failures + 1] = "TRIGGER_ACTIVATES_UNKNOWN_OBJECTIVE"
                    end
                elseif action.type == KIPN.Shared.EventTriggerActionTypes.MODE_ACTION then
                    local actionId = action.params and action.params.actionId
                    if type(actionId) ~= "string" or not modeActions[actionId] then
                        failures[#failures + 1] = "TRIGGER_MODE_ACTION_NOT_REGISTERED"
                    end
                elseif action.type == KIPN.Shared.EventTriggerActionTypes.SPAWN_LOOT then
                    local items = (action.params and action.params.items) or {}
                    if type(items) ~= "table" or #items == 0 then
                        failures[#failures + 1] = "SPAWN_LOOT_ACTION_HAS_NO_ITEMS"
                    end
                end
            end
        end
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- RUNTIME INITIALIZATION
------------------------------------------------------------

function TriggerService.InitializeRuntime(runtime, definition)
    runtime.storyState = {
        activeObjectiveId = definition.objectives and definition.objectives[1] and definition.objectives[1].id or nil,
        activatedAtMs = now(),
        completedObjectiveIds = {},
    }
    runtime.triggerState = {}
    runtime.spawnedEventLoot = runtime.spawnedEventLoot or {}
    return true
end

------------------------------------------------------------
-- LOOKUPS
------------------------------------------------------------

local function findObjective(definition, objectiveId)
    for _, objective in ipairs((definition and definition.objectives) or {}) do
        if objective.id == objectiveId then return objective end
    end
    return nil
end

local function findTrigger(definition, triggerId)
    for _, objective in ipairs((definition and definition.objectives) or {}) do
        for _, trigger in ipairs(objective.triggers) do
            if trigger.id == triggerId then return objective, trigger end
        end
    end
    return nil, nil
end

local function getTriggerState(runtime, triggerId)
    runtime.triggerState[triggerId] = runtime.triggerState[triggerId] or {
        activationCount = 0,
        lastActivatedAtMs = nil,
        activatedByUsername = {},
    }
    return runtime.triggerState[triggerId]
end

------------------------------------------------------------
-- ELIGIBILITY (Only living, joined participants can activate
-- proximity triggers)
------------------------------------------------------------

local function getEligibleParticipants(runtime)
    local eligible = {}
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil

    if not online then return eligible end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()

        if username and runtime.participants[username] then
            local isDeadOk, isDead = pcall(function() return p:isDead() end)
            if isDeadOk and not isDead then
                eligible[#eligible + 1] = { username = username, player = p }
            end
        end
    end

    return eligible
end

local function matchesTargetFilter(runtime, definition, username, targetFilter)
    if not targetFilter or targetFilter == "ANY" then return true end

    if targetFilter:sub(1, 5) == "TEAM:" then
        local teamId = targetFilter:sub(6)
        return KIPN.Server.EventTeamService.GetPlayerTeam(definition, username) == teamId
    end

    if targetFilter:sub(1, 12) == "PARTICIPANT:" then
        return username == targetFilter:sub(13)
    end

    if targetFilter == "ROLE:TARGET" then
        -- Provisional bridge to the existing Chase implementation's
        -- single objectiveState.chaseTarget field (KIPN_EventScenarioRuntimeRegistry.lua)
        -- until Chase gets its own dedicated Phase 8 rework with real
        -- Target/Hunter role infrastructure.
        return runtime.objectiveState ~= nil and runtime.objectiveState.chaseTarget == username
    end

    if targetFilter == "ROLE:HUNTER" then
        return runtime.objectiveState == nil or runtime.objectiveState.chaseTarget ~= username
    end

    return false
end

------------------------------------------------------------
-- GEOMETRY
------------------------------------------------------------

local function resolveTriggerOrigin(definition, trigger)
    if trigger.hotspotId then
        local hotspot = KIPN.Server.EventHotspotService.FindById(definition, trigger.hotspotId)
        if hotspot then
            return KIPN.Server.EventHotspotService.GetCenter(hotspot)
        end
    end
    return nil
end

local function isPlayerInTriggerGeometry(definition, trigger, player)
    local hotspot = trigger.hotspotId and KIPN.Server.EventHotspotService.FindById(definition, trigger.hotspotId)
    if not hotspot then return false end

    local ok, x, y, z = pcall(function() return player:getX(), player:getY(), player:getZ() end)
    if not ok or not x then return false end

    return KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, hotspot)
end

------------------------------------------------------------
-- ACTION HANDLERS
--
-- Every handler takes (runtime, definition, action, context) where
-- context = { activatingUsername (may be nil for a GLOBAL time-based
-- trigger), objective, trigger }. Returns (ok, reason).
------------------------------------------------------------

local function actionSpawnZombies(runtime, definition, action, context)
    local params = action.params or {}
    local origin = resolveTriggerOrigin(definition, context.trigger)
        or KIPN.Server.ZombieDirector.GetSpawnOrigin(runtime, definition)

    if not origin then return false, "NO_SPAWN_ORIGIN" end

    local count = math.max(1, math.floor(tonumber(params.count) or 5))
    local radiusTiles = math.max(0, math.floor(tonumber(params.radiusTiles) or 3))

    local spawned, reason = KIPN.Server.ZombieDirector.SpawnThemedZombies(runtime, definition, origin, count, radiusTiles, origin)

    return (spawned or 0) > 0, reason
end

-- A bandit crew arrives at the trigger's hotspot and fights.
local function actionSpawnBandits(runtime, definition, action, context)
    local params = action.params or {}
    local origin = resolveTriggerOrigin(definition, context.trigger)
        or KIPN.Server.ZombieDirector.GetSpawnOrigin(runtime, definition)
    if not origin then return false, "NO_SPAWN_ORIGIN" end
    local bandits = KIPN.Server.EventBanditService
    if not bandits then return false, "BANDITS_UNAVAILABLE" end
    local crew = bandits.Arrive(runtime, definition, origin, math.max(1, math.min(12, math.floor(tonumber(params.count) or 3))))
    return crew ~= nil, crew == nil and "NO_SPAWN_SQUARE" or nil
end

local function actionSpawnLoot(runtime, definition, action, context)
    local params = action.params or {}
    local origin = resolveTriggerOrigin(definition, context.trigger)
        or KIPN.Server.ZombieDirector.GetSpawnOrigin(runtime, definition)

    if not origin then return false, "NO_SPAWN_ORIGIN" end

    local cellOk, cell = pcall(getCell)
    local square = cellOk and cell and cell:getGridSquare(origin.x, origin.y, origin.z or 0)

    if not square then return false, "NO_VALID_SQUARE" end

    local items = params.items or {}
    local spawnedCount = 0

    runtime.spawnedEventLoot = runtime.spawnedEventLoot or {}

    for itemIndex, entry in ipairs(items) do
        if itemIndex > MAX_LOOT_ITEMS_PER_ACTION then break end

        local fullType = type(entry) == "table" and entry.itemFullType
        local copies = math.max(1, math.floor(tonumber(type(entry) == "table" and entry.count) or 1))

        if type(fullType) == "string" and fullType ~= "" then
            for _ = 1, copies do
                local item = KIPN.Server.CreateItem(fullType)

                if item then
                    local droppedOk = pcall(function() square:AddWorldInventoryItem(item, 0, 0, 0) end)

                    if droppedOk then
                        runtime.spawnedEventLoot[#runtime.spawnedEventLoot + 1] = { item = item, square = square }
                        spawnedCount = spawnedCount + 1
                    end
                end
            end
        end
    end

    if spawnedCount == 0 then return false, "NO_ITEMS_SPAWNED" end
    return true
end

local function actionPrivateHint(runtime, _definition, action, context)
    local text = sanitizeText(action.params and action.params.text, 500)
    if text == "" then return false, "EMPTY_HINT_TEXT" end

    local runtimeService = KIPN.Server.EventRuntimeService

    if context.activatingUsername then
        local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
        if online then
            for i = 0, online:size() - 1 do
                local p = online:get(i)
                if p and p:getUsername() == context.activatingUsername then
                    -- A hint is a clue: shown big, and replayable from its HUD button.
                    local loop = KIPN.Server.EventGameLoopService
                    if loop and loop.ShowClue then
                        loop.ShowClue(runtime, { [context.activatingUsername] = true }, "hint:" .. text, "Hint", text, true)
                    else
                        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_NARRATIVE, { text = "[HINT] " .. text })
                    end
                    return true
                end
            end
        end
        return false, "PLAYER_NOT_ONLINE"
    end

    -- No specific activating player (e.g. a GLOBAL time-based
    -- trigger) -- fall back to broadcasting the hint to every current
    -- participant, matching NARRATIVE_MESSAGE's scope.
    local loop = KIPN.Server.EventGameLoopService
    if loop and loop.ShowClue then
        loop.ShowClue(runtime, nil, "hint:" .. text, "Hint", text, true)
        return true
    end
    if runtimeService and runtimeService.BroadcastNarrative then
        runtimeService.BroadcastNarrative(runtime, "[HINT] " .. text)
        return true
    end

    return false, "RUNTIME_SERVICE_UNAVAILABLE"
end

local function actionNarrativeMessage(runtime, _definition, action, _context)
    local text = sanitizeText(action.params and action.params.text, 500)
    if text == "" then return false, "EMPTY_MESSAGE_TEXT" end

    local runtimeService = KIPN.Server.EventRuntimeService
    if not (runtimeService and runtimeService.BroadcastNarrative) then
        return false, "RUNTIME_SERVICE_UNAVAILABLE"
    end

    runtimeService.BroadcastNarrative(runtime, text)
    return true
end

local function actionAnnouncement(runtime, _definition, action, _context)
    local text = sanitizeText(action.params and action.params.text, 500)
    if text == "" then return false, "EMPTY_ANNOUNCEMENT_TEXT" end

    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if not online then return false, "NO_ONLINE_PLAYERS" end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        if p then
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_NARRATIVE, { text = text })
        end
    end

    return true
end

local function actionAlarm(runtime, definition, _action, _context)
    return KIPN.Server.ZombieDirector.TriggerAlarm(runtime, definition, {})
end

function TriggerService.ActivateObjective(runtime, definition, objectiveId)
    local objective = findObjective(definition, objectiveId)
    if not objective then return false, "OBJECTIVE_NOT_FOUND" end

    runtime.storyState.activeObjectiveId = objectiveId
    runtime.storyState.activatedAtMs = now()

    log("ActivateObjective() -> " .. objectiveId)
    return true
end

function TriggerService.CompleteObjective(runtime, definition)
    local currentId = runtime.storyState.activeObjectiveId
    if not currentId then return false, "NO_ACTIVE_OBJECTIVE" end

    runtime.storyState.completedObjectiveIds[currentId] = true

    local objectives = definition.objectives or {}
    local nextObjective = nil
    local foundCurrent = false

    for _, objective in ipairs(objectives) do
        if foundCurrent then
            nextObjective = objective
            break
        end
        if objective.id == currentId then foundCurrent = true end
    end

    if nextObjective then
        runtime.storyState.activeObjectiveId = nextObjective.id
        runtime.storyState.activatedAtMs = now()
        log("CompleteObjective() -> " .. currentId .. " complete, advanced to " .. nextObjective.id)
    else
        runtime.storyState.activeObjectiveId = nil
        log("CompleteObjective() -> " .. currentId .. " complete; no further objectives (story finished)")
    end

    return true
end

local function actionActivateObjective(runtime, definition, action, _context)
    local targetId = action.params and action.params.objectiveId
    if not targetId then return false, "NO_OBJECTIVE_ID" end
    return TriggerService.ActivateObjective(runtime, definition, targetId)
end

local function actionCompleteObjective(runtime, definition, _action, _context)
    return TriggerService.CompleteObjective(runtime, definition)
end

local function actionModeAction(runtime, definition, action, context)
    local actionId = action.params and action.params.actionId
    local handler = actionId and modeActions[actionId]

    if not handler then return false, "MODE_ACTION_NOT_REGISTERED" end

    local ok, result = pcall(handler, runtime, definition, action.params or {}, context.activatingUsername)
    if not ok then
        logError("MODE_ACTION " .. tostring(actionId) .. " failed: " .. tostring(result))
        return false, "MODE_ACTION_ERROR"
    end

    return result ~= false
end

local ACTION_HANDLERS = {
    SPAWN_ZOMBIES = actionSpawnZombies,
    SPAWN_BANDITS = actionSpawnBandits,
    SPAWN_LOOT = actionSpawnLoot,
    PRIVATE_HINT = actionPrivateHint,
    NARRATIVE_MESSAGE = actionNarrativeMessage,
    ANNOUNCEMENT = actionAnnouncement,
    ALARM = actionAlarm,
    ACTIVATE_OBJECTIVE = actionActivateObjective,
    COMPLETE_OBJECTIVE = actionCompleteObjective,
    MODE_ACTION = actionModeAction,
}

------------------------------------------------------------
-- FIRING
------------------------------------------------------------

local function runActions(runtime, definition, objective, trigger, activatingUsername)
    local context = { activatingUsername = activatingUsername, objective = objective, trigger = trigger }

    for _, action in ipairs(trigger.actions) do
        local handler = ACTION_HANDLERS[action.type]

        if handler then
            local ok, err = pcall(handler, runtime, definition, action, context)
            if not ok then
                logError("Action " .. tostring(action.type) .. " on trigger " .. tostring(trigger.id) .. " errored: " .. tostring(err))
            end
        end
    end
end

-- Records the activation and returns true if this call is allowed to
-- proceed (respects maxActivations/cooldown); false means "already
-- exhausted/on cooldown, do not fire again" -- the idempotency
-- backbone that keeps a reconnect or a duplicate tick from replaying
-- a one-shot action.
local function tryRecordActivation(triggerState, trigger, username)
    local nowMs = now()

    if username then
        local perPlayer = triggerState.activatedByUsername[username]
            or { count = 0, lastActivatedAtMs = nil }

        if perPlayer.count >= trigger.maxActivations then return false end
        if perPlayer.lastActivatedAtMs and trigger.cooldownSeconds > 0
            and (nowMs - perPlayer.lastActivatedAtMs) < trigger.cooldownSeconds * 1000
        then
            return false
        end

        perPlayer.count = perPlayer.count + 1
        perPlayer.lastActivatedAtMs = nowMs
        triggerState.activatedByUsername[username] = perPlayer
        return true
    end

    if triggerState.activationCount >= trigger.maxActivations then return false end
    if triggerState.lastActivatedAtMs and trigger.cooldownSeconds > 0
        and (nowMs - triggerState.lastActivatedAtMs) < trigger.cooldownSeconds * 1000
    then
        return false
    end

    triggerState.activationCount = triggerState.activationCount + 1
    triggerState.lastActivatedAtMs = nowMs
    return true
end

local function rollProbability(probability)
    if probability >= 1 then return true end
    if probability <= 0 then return false end
    return ZombRand(100) < math.floor(probability * 100)
end

------------------------------------------------------------
-- ROUND-BOUNDARY RESET ("fire once globally per round by default")
------------------------------------------------------------

local function resetTriggerStateForNewRound(runtime, roundNumber)
    runtime.triggerState = {}
    runtime.storyState.lastSeenRoundNumber = roundNumber
    log("resetTriggerStateForNewRound() -> round " .. tostring(roundNumber))
end

------------------------------------------------------------
-- TICK (called from KIPN_EventRuntimeService.lua's existing 5-second
-- onTick loop -- not a second competing tick loop)
------------------------------------------------------------

function TriggerService.Tick(runtime, definition)
    if not runtime.storyState then
        return
    end

    local currentRound = runtime.round and runtime.round.current or 0
    if runtime.storyState.lastSeenRoundNumber ~= currentRound then
        resetTriggerStateForNewRound(runtime, currentRound)
    end

    local eligible = getEligibleParticipants(runtime)
    local nowMs = now()

    for _, objective in ipairs(definition.objectives or {}) do
        local isActiveObjective = objective.id == runtime.storyState.activeObjectiveId

        for _, trigger in ipairs(objective.triggers) do
            if (isActiveObjective or trigger.background)
                and trigger.activationMode ~= KIPN.Shared.EventTriggerActivationModes.MANUAL
                and (not trigger.roundNumber or trigger.roundNumber == currentRound)
            then
                local triggerState = getTriggerState(runtime, trigger.id)

                if trigger.activationMode == KIPN.Shared.EventTriggerActivationModes.PROXIMITY then
                    for _, entry in ipairs(eligible) do
                        if matchesTargetFilter(runtime, definition, entry.username, trigger.targetFilter)
                            and isPlayerInTriggerGeometry(definition, trigger, entry.player)
                        then
                            local perPlayerUsername = (trigger.scope == KIPN.Shared.EventTriggerScopes.PER_PLAYER) and entry.username or nil

                            if tryRecordActivation(triggerState, trigger, perPlayerUsername) and rollProbability(trigger.probability) then
                                runActions(runtime, definition, objective, trigger, entry.username)
                            end

                            if trigger.scope == KIPN.Shared.EventTriggerScopes.GLOBAL then break end
                        end
                    end
                else
                    -- TIME_SINCE_EVENT / TIME_SINCE_ROUND / TIME_SINCE_OBJECTIVE
                    local referenceMs = nil

                    if trigger.activationMode == KIPN.Shared.EventTriggerActivationModes.TIME_SINCE_EVENT then
                        referenceMs = runtime.startedAtMs
                    elseif trigger.activationMode == KIPN.Shared.EventTriggerActivationModes.TIME_SINCE_ROUND then
                        referenceMs = runtime.round and runtime.round.startedAtMs
                    elseif trigger.activationMode == KIPN.Shared.EventTriggerActivationModes.TIME_SINCE_OBJECTIVE then
                        referenceMs = runtime.storyState.activatedAtMs
                    end

                    if referenceMs and (nowMs - referenceMs) >= trigger.delaySeconds * 1000 then
                        if trigger.scope == KIPN.Shared.EventTriggerScopes.PER_PLAYER then
                            for _, entry in ipairs(eligible) do
                                if matchesTargetFilter(runtime, definition, entry.username, trigger.targetFilter)
                                    and tryRecordActivation(triggerState, trigger, entry.username)
                                    and rollProbability(trigger.probability)
                                then
                                    runActions(runtime, definition, objective, trigger, entry.username)
                                end
                            end
                        else
                            if tryRecordActivation(triggerState, trigger, nil) and rollProbability(trigger.probability) then
                                runActions(runtime, definition, objective, trigger, nil)
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- MANUAL ACTIVATION (Event Director) -- reached through
-- KIPN_EventRuntimeService.RuntimeControl's "fire_trigger" controlId,
-- a name namespaced enough to never collide with any objective-type's
-- own controls (e.g. "scenario_start_round", "spawn_burst").
------------------------------------------------------------

function TriggerService.Dispatch(controlId, runtime, definition, params)
    if controlId ~= "fire_trigger" then
        return false, "UNKNOWN_TRIGGER_CONTROL"
    end

    local triggerId = params and params.triggerId
    if not triggerId then return false, "NO_TRIGGER_ID" end

    local objective, trigger = findTrigger(definition, triggerId)
    if not trigger then return false, "TRIGGER_NOT_FOUND" end

    if trigger.activationMode ~= KIPN.Shared.EventTriggerActivationModes.MANUAL then
        return false, "NOT_MANUAL"
    end

    local triggerState = getTriggerState(runtime, trigger.id)
    local activatingUsername = params and params.username

    if not tryRecordActivation(triggerState, trigger, trigger.scope == KIPN.Shared.EventTriggerScopes.PER_PLAYER and activatingUsername or nil) then
        return false, "TRIGGER_EXHAUSTED_OR_ON_COOLDOWN"
    end

    runActions(runtime, definition, objective, trigger, activatingUsername)

    return true
end

------------------------------------------------------------
-- CLEANUP (temporary loot -- zombie cleanup is
-- KIPN_ZombieDirector.CleanupRuntime, called separately by
-- KIPN_EventRuntimeService.lua's stopEvent())
--
-- Only removes loot still findable on the square it was spawned on --
-- an item a participant already picked up is no longer a world object
-- there, so it is never touched here. This is the Phase 3 default
-- "claimed loot is retained" policy; a per-action policy that forcibly
-- reclaims already-claimed loot is explicitly out of scope for this
-- foundation phase (see the Phase 3 report).
------------------------------------------------------------

function TriggerService.CleanupRuntime(runtime)
    local removed = 0

    for _, entry in ipairs((runtime and runtime.spawnedEventLoot) or {}) do
        local ok = pcall(function()
            local worldObjects = entry.square and entry.square:getWorldObjects()
            if not worldObjects then return end

            for i = 0, worldObjects:size() - 1 do
                local worldObj = worldObjects:get(i)
                if worldObj and worldObj:getItem() == entry.item then
                    if type(entry.square.transmitRemoveItemFromSquare) == "function" then
                        entry.square:transmitRemoveItemFromSquare(worldObj)
                    end
                    worldObj:removeFromWorld()
                    worldObj:removeFromSquare()
                    removed = removed + 1
                    break
                end
            end
        end)

        if not ok then logError("CleanupRuntime() failed to remove one loot item") end
    end

    if runtime then runtime.spawnedEventLoot = {} end

    log("CleanupRuntime() -> removed=" .. tostring(removed))
    return true, removed
end

------------------------------------------------------------
-- NARRATIVE_LOCATION HOTSPOTS
--
-- Proximity-triggered flavor text, evaluated independently of the
-- ordered-objectives/trigger system above so it fires regardless of
-- story progress -- authoring one doesn't require an Objective to
-- exist first. Text/scope live on the hotspot's own metadata (see
-- KIPN_EventHotspotService.lua's NormalizeHotspot() sanitizing
-- metadata.narrativeText/metadata.narrativeScope). GLOBAL broadcasts
-- to every current participant once for the whole event, the same
-- way actionNarrativeMessage above does; LOCAL sends a private
-- message to each player individually, once per player, the same way
-- actionPrivateHint above does. Called from
-- KIPN_EventRuntimeService.lua's tick loop alongside TriggerService.Tick.
------------------------------------------------------------

function TriggerService.TickNarrativeHotspots(runtime, definition)
    local hotspots = KIPN.Server.EventHotspotService.GetHotspots(
        definition, KIPN.Shared.EventHotspotTypes.NARRATIVE_LOCATION
    )
    if #hotspots == 0 then return end

    runtime.narrativeAnnounced = runtime.narrativeAnnounced or {}

    local eligible = getEligibleParticipants(runtime)
    if #eligible == 0 then return end

    local runtimeService = KIPN.Server.EventRuntimeService
    local loop = KIPN.Server.EventGameLoopService

    -- Shows a narrative hotspot's text as a banner and, unless the
    -- admin turned it off, keeps it as a replayable clue.
    local function show(hotspot, usernames, text)
        if loop and loop.ShowClue then
            loop.ShowClue(runtime, usernames, "place:" .. tostring(hotspot.id), hotspot.metadata.clueTitle, text,
                hotspot.metadata.replayable ~= false)
            return
        end
        if usernames then
            for _, entry in ipairs(eligible) do
                if usernames[entry.username] then
                    KIPN.Server.SendToPlayer(entry.player, KIPN.Shared.ResponseEvents.EVENT_NARRATIVE, { text = text })
                end
            end
        elseif runtimeService and runtimeService.BroadcastNarrative then
            runtimeService.BroadcastNarrative(runtime, text)
        end
    end

    for _, hotspot in ipairs(hotspots) do
        local text = hotspot.metadata and hotspot.metadata.narrativeText

        if type(text) == "string" and text ~= "" then
            local isGlobal = hotspot.metadata.narrativeScope == "GLOBAL"

            if isGlobal then
                if runtime.narrativeAnnounced[hotspot.id] ~= true then
                    for _, entry in ipairs(eligible) do
                        local ok, x, y, z = pcall(function()
                            return entry.player:getX(), entry.player:getY(), entry.player:getZ()
                        end)

                        if ok and x and KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, hotspot) then
                            runtime.narrativeAnnounced[hotspot.id] = true
                            show(hotspot, nil, text)
                            break
                        end
                    end
                end
            else
                local announcedTo = runtime.narrativeAnnounced[hotspot.id]
                if type(announcedTo) ~= "table" then
                    announcedTo = {}
                    runtime.narrativeAnnounced[hotspot.id] = announcedTo
                end

                for _, entry in ipairs(eligible) do
                    if not announcedTo[entry.username] then
                        local ok, x, y, z = pcall(function()
                            return entry.player:getX(), entry.player:getY(), entry.player:getZ()
                        end)

                        if ok and x and KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, hotspot) then
                            announcedTo[entry.username] = true
                            show(hotspot, { [entry.username] = true }, text)
                        end
                    end
                end
            end
        end
    end
end

function TriggerService.Initialize()
    log("Initialize() -> module ready")
    return true
end

log("module loaded")
