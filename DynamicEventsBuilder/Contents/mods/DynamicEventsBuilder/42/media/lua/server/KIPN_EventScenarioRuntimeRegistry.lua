-- KIPN_EventScenarioRuntimeRegistry.lua
--
-- Data-driven mechanical handlers for composable objective types. This layer
-- supplies scenario-specific Director controls and first-class round state
-- without putting a growing objective if/elseif chain in the client UI.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_EventHotspotService"
require "KIPN_EventParticipationService"
require "KIPN_EventTimerService"
require "KIPN_EventChaseService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventScenarioRuntimeRegistry = KIPN.Server.EventScenarioRuntimeRegistry or {}

local Registry = KIPN.Server.EventScenarioRuntimeRegistry
Registry.Components = Registry.Components or {}

local function log(message)
    print("[KIPN EVENT SCENARIO RUNTIME] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT SCENARIO RUNTIME] ERROR: " .. tostring(message))
end

local function appendRuntimeLog(runtime, message)
    runtime.log = runtime.log or {}
    runtime.log[#runtime.log + 1] = tostring(message)
    while #runtime.log > 50 do table.remove(runtime.log, 1) end
    log("appendRuntimeLog() -> " .. tostring(message))
end

local function hasObjective(definition, objectiveType)
    for _, current in ipairs((definition and definition.objectiveTypes) or {}) do
        if current == objectiveType then return true end
    end
    return false
end

function Registry.Register(objectiveType, component)
    if type(objectiveType) ~= "string" or type(component) ~= "table" then
        logError("Register() rejected invalid component")
        return false
    end
    Registry.Components[objectiveType] = component
    log("Register() -> " .. objectiveType)
    return true
end

function Registry.InitializeRuntime(runtime, definition)
    runtime.objectiveState = runtime.objectiveState or {}
    local hillCount = #KIPN.Server.EventHotspotService.GetHotspots(
        definition,
        KIPN.Shared.EventHotspotTypes.HILL_LOCATION
    )
    local configuredRounds = math.floor(tonumber(definition.maxRounds) or 1)
    if hasObjective(definition, "HOLD_AREA") and hillCount > 0 then
        configuredRounds = math.min(configuredRounds, hillCount)
    end
    runtime.round = {
        current = 0,
        maximum = math.max(1, math.min(10, configuredRounds)),
        state = "READY",
        winner = nil,
        hotspotId = nil,
        startedAtMs = nil,
        completedAtMs = nil,
    }
    runtime.winners = runtime.winners or {}

    for objectiveType, component in pairs(Registry.Components) do
        if hasObjective(definition, objectiveType) and type(component.onRuntimeStart) == "function" then
            local ok, err = pcall(component.onRuntimeStart, runtime, definition)
            if not ok then logError("InitializeRuntime() " .. objectiveType .. " failed: " .. tostring(err)) end
        end
    end
    appendRuntimeLog(runtime, "Scenario runtime initialized; max rounds=" .. tostring(runtime.round.maximum))
    log("InitializeRuntime() -> " .. tostring(runtime.eventDefinitionId))
    return true
end

-- Modes whose engine plays in rounds (Capture, King of the Hill,
-- Chase) get the round controls whatever objective types are ticked.
-- Capture's own objective types (Retrieve/Deliver) register none, so
-- before this its rounds could never start and a delivery could never
-- complete one -- the flag never spawned.
local ROUND_HANDLERS
local ROUND_CONTROL_LIST

function Registry.UsesRounds(definition)
    if not definition then return false end
    local metadata = definition.mode and KIPN.Shared.EventModeMetadata and KIPN.Shared.EventModeMetadata[definition.mode]
    if metadata and metadata.usesRounds then return true end
    return hasObjective(definition, "HOLD_AREA") or hasObjective(definition, "CHASE_TARGET")
end

function Registry.GetControls(definition)
    local controls = {}
    local seen = {}
    if Registry.UsesRounds(definition) then
        for _, control in ipairs(ROUND_CONTROL_LIST or {}) do
            seen[control.id] = true
            controls[#controls + 1] = control
        end
    end
    for _, objectiveType in ipairs((definition and definition.objectiveTypes) or {}) do
        local component = Registry.Components[objectiveType]
        for _, control in ipairs(component and component.controls or {}) do
            if not seen[control.id] then
                seen[control.id] = true
                controls[#controls + 1] = control
            end
        end
    end
    log("GetControls() -> " .. tostring(#controls))
    return controls
end

function Registry.Dispatch(controlId, runtime, definition, params)
    for _, objectiveType in ipairs((definition and definition.objectiveTypes) or {}) do
        local component = Registry.Components[objectiveType]
        local handler = component and component.handlers and component.handlers[controlId]
        if type(handler) == "function" then
            local ok, result, reason = pcall(handler, runtime, definition, params or {})
            if not ok then
                logError("Dispatch(" .. tostring(controlId) .. ") failed: " .. tostring(result))
                return false, "SCENARIO_HANDLER_ERROR"
            end
            log("Dispatch(" .. tostring(controlId) .. ") -> " .. tostring(result))
            return result == true, result == true and reason or (reason or "SCENARIO_CONTROL_REJECTED")
        end
    end
    local roundHandler = ROUND_HANDLERS and ROUND_HANDLERS[controlId]
    if roundHandler and Registry.UsesRounds(definition) then
        local ok, result, reason = pcall(roundHandler, runtime, definition, params or {})
        if not ok then
            logError("Dispatch(" .. tostring(controlId) .. ") failed: " .. tostring(result))
            return false, "SCENARIO_HANDLER_ERROR"
        end
        return result == true, result == true and reason or (reason or "SCENARIO_CONTROL_REJECTED")
    end
    log("Dispatch(" .. tostring(controlId) .. ") -> UNKNOWN_SCENARIO_CONTROL")
    return false, "UNKNOWN_SCENARIO_CONTROL"
end

local chooseChaseTarget

local function isChase(definition)
    return definition and (definition.mode == "CHASE" or hasObjective(definition, "CHASE_TARGET"))
end

local function startRound(runtime, definition, params)
    if runtime.round.state == "ACTIVE" then return false, "ROUND_ALREADY_ACTIVE" end
    local requested = tonumber(params.roundNumber)
    local nextRound = requested and math.max(1, math.floor(requested)) or math.max(1, runtime.round.current + 1)
    if nextRound > runtime.round.maximum then return false, "NO_MORE_ROUNDS" end
    runtime.round.current = nextRound
    runtime.round.state = "ACTIVE"
    runtime.round.startedAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0
    runtime.round.completedAtMs = nil
    runtime.round.winner = nil
    runtime.round.winnerTeamId = nil
    -- Phase 4: round-scoped timer, wholly separate from the event-wide
    -- one -- see KIPN_EventTimerService.lua's header.
    KIPN.Server.EventTimerService.StartRoundTimer(runtime, definition)
    local hotspot = KIPN.Server.EventHotspotService.GetRoundHotspot(definition, nextRound)
    runtime.round.hotspotId = hotspot and hotspot.id or nil
    appendRuntimeLog(runtime, "Round " .. tostring(nextRound) .. " started at hotspot " .. tostring(runtime.round.hotspotId))

    -- Chase: a new target every round, chosen automatically unless
    -- the Director already picked one for this round.
    if isChase(definition) then
        runtime.objectiveState.chaseTargetKilled = nil
        if not runtime.objectiveState.chaseTargetPickedForRound
            or runtime.objectiveState.chaseTargetPickedForRound ~= nextRound then
            chooseChaseTarget(runtime, definition, {})
        end
        runtime.objectiveState.chaseTargetPickedForRound = nil
    end

    if Registry.UsesRounds(definition) then
        local ok, err = pcall(
            KIPN.Server.EventParticipationService.BroadcastRoundInvite,
            runtime,
            definition,
            nextRound
        )
        if not ok then
            logError("BroadcastRoundInvite failed: " .. tostring(err))
        end
    end

    return true, runtime.round
end

local function completeRound(runtime, definition, params)
    if runtime.round.state ~= "ACTIVE" then return false, "ROUND_NOT_ACTIVE" end
    runtime.round.state = "COMPLETE"
    runtime.round.completedAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0
    runtime.round.winner = params and params.winnerUsername or runtime.round.winner
    -- Phase 6: team-scoped round winner, alongside the existing
    -- individual winner above -- set by KIPN_EventCaptureService.lua's
    -- Team CTF delivery credit; nil/unused for every other mode.
    runtime.round.winnerTeamId = params and params.winnerTeamId or runtime.round.winnerTeamId
    if runtime.round.winner then runtime.winners[runtime.round.winner] = runtime.participants[runtime.round.winner] or true end
    appendRuntimeLog(runtime, "Round " .. tostring(runtime.round.current) .. " completed")
    return true, runtime.round
end

local function advanceRound(runtime, definition, params)
    if runtime.round.state == "ACTIVE" then
        local ok, reason = completeRound(runtime, definition, params)
        if not ok then return false, reason end
    end
    if runtime.round.current >= runtime.round.maximum then
        appendRuntimeLog(runtime, "Final round completed")
        return true, runtime.round
    end
    return startRound(runtime, definition, { roundNumber = runtime.round.current + 1 })
end

local function restartRound(runtime, definition, params)
    if runtime.round.current < 1 then return false, "ROUND_NOT_STARTED" end
    runtime.round.state = "READY"
    return startRound(runtime, definition, { roundNumber = runtime.round.current })
end

local function completeObjective(runtime, definition, params)
    runtime.objectiveState.complete = true
    runtime.objectiveState.completedAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0
    runtime.objectiveState.completedBy = params and params.username or nil
    if runtime.objectiveState.completedBy then
        runtime.winners[runtime.objectiveState.completedBy] = runtime.participants[runtime.objectiveState.completedBy] or true
    end
    appendRuntimeLog(runtime, "Scenario objective manually completed")
    return true
end

local function resetObjective(runtime, definition, params)
    runtime.objectiveState = { resetAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0 }
    appendRuntimeLog(runtime, "Scenario objective reset")
    return true
end

local function onlineAliveParticipants(runtime)
    local alive = {}
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if not online then return alive end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()
        local deadOk, dead = pcall(function() return p:isDead() end)
        if username and runtime.participants[username] and deadOk and not dead then alive[#alive + 1] = username end
    end
    return alive
end

-- Picks the Director's choice, otherwise whoever online has been the
-- target the fewest times, so everyone gets a turn at being hunted.
chooseChaseTarget = function(runtime, definition, params)
    local candidates = onlineAliveParticipants(runtime)
    if #candidates < 1 then
        for username in pairs(runtime.participants or {}) do candidates[#candidates + 1] = username end
    end
    if #candidates < 1 then return false, "NO_PARTICIPANTS" end
    runtime.chaseState = runtime.chaseState or { playerRoundWins = {}, lastAttacker = {} }
    local timesTargeted = runtime.chaseState.timesTargeted or {}
    runtime.chaseState.timesTargeted = timesTargeted
    local username = params and params.username
    if not username or not runtime.participants[username] then
        local fewest = math.huge
        local pool = {}
        for _, candidate in ipairs(candidates) do
            local times = timesTargeted[candidate] or 0
            if times < fewest then fewest, pool = times, { candidate }
            elseif times == fewest then pool[#pool + 1] = candidate end
        end
        username = pool[ZombRand(1, #pool + 1)]
    end
    timesTargeted[username] = (timesTargeted[username] or 0) + 1
    runtime.chaseState.targetPing = nil
    -- A pick made between rounds is kept for the next round.
    if runtime.round and runtime.round.state ~= "ACTIVE" then
        runtime.objectiveState.chaseTargetPickedForRound = (runtime.round.current or 0) + 1
    end
    runtime.objectiveState.chaseTarget = username
    runtime.objectiveState.chaseTargetSelectedAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0
    appendRuntimeLog(runtime, "Chase target selected: " .. username)
    return true, username
end

function Registry.OnPlayerDeath(username)
    for _, runtime in pairs(KIPN.Server.EventRuntimeService and KIPN.Server.EventRuntimeService.ActiveRuntimes or {}) do
        if runtime.objectiveState and runtime.objectiveState.chaseTarget == username then
            runtime.objectiveState.chaseTargetKilled = true
            if runtime.round and runtime.round.state == "ACTIVE" then
                local completionParams = {}

                -- Phase 8: the Chase mode engine credits every
                -- current hunter with a round win (its own
                -- chaseState.playerRoundWins, not this single-slot
                -- params.winnerUsername) and, when a recent-enough
                -- attacker is on file, surfaces them here too for
                -- display/log purposes only -- see
                -- KIPN_EventChaseService.lua's OnTargetKilled().
                local scenarioService = KIPN.Server.EventScenarioService
                local definition = scenarioService and scenarioService.GetDefinition
                    and scenarioService.GetDefinition(runtime.eventDefinitionId)

                if definition and definition.mode == "CHASE" then
                    local ok, killerUsername = pcall(
                        KIPN.Server.EventChaseService.OnTargetKilled, runtime, definition, username
                    )
                    if ok then
                        completionParams.winnerUsername = killerUsername
                    else
                        logError("Chase target-killed handling failed: " .. tostring(killerUsername))
                    end
                end

                completeRound(runtime, nil, completionParams)
            end
            appendRuntimeLog(runtime, "Chase target killed: " .. tostring(username))
        end
    end
    log("OnPlayerDeath() -> " .. tostring(username))
end

local ROUND_CONTROLS = {
    { id = "scenario_start_round", label = "Start Round", defaultParams = {}, group = "EVENT" },
    { id = "scenario_complete_round", label = "Complete Round", defaultParams = {}, group = "EVENT" },
    { id = "scenario_advance_round", label = "Next Round / Hill", defaultParams = {}, group = "EVENT" },
    { id = "scenario_restart_round", label = "Restart Round", defaultParams = {}, group = "EVENT" },
}

local OBJECTIVE_CONTROLS = {
    { id = "scenario_complete_objective", label = "Complete Objective", defaultParams = {}, group = "EVENT" },
    { id = "scenario_reset_objective", label = "Reset Objective", defaultParams = {}, group = "EVENT" },
}

ROUND_CONTROL_LIST = ROUND_CONTROLS
ROUND_HANDLERS = {
    scenario_start_round = startRound,
    scenario_complete_round = completeRound,
    scenario_advance_round = advanceRound,
    scenario_restart_round = restartRound,
}

-- Used by KIPN_EventGameLoopService.lua to run rounds on their own.
function Registry.StartNextRound(runtime, definition)
    return startRound(runtime, definition, {})
end

function Registry.Initialize()
    Registry.Register("HOLD_AREA", {
        controls = ROUND_CONTROLS,
        handlers = {
            scenario_start_round = startRound,
            scenario_complete_round = completeRound,
            scenario_advance_round = advanceRound,
            scenario_restart_round = restartRound,
        },
    })
    Registry.Register("RETRIEVE", {
        controls = OBJECTIVE_CONTROLS,
        handlers = {
            scenario_complete_objective = completeObjective,
            scenario_reset_objective = resetObjective,
        },
    })
    Registry.Register("DELIVER", {
        controls = OBJECTIVE_CONTROLS,
        handlers = {
            scenario_complete_objective = completeObjective,
            scenario_reset_objective = resetObjective,
        },
    })
    Registry.Register("CHASE_TARGET", {
        controls = {
            { id = "scenario_select_chase_target", label = "Select Chase Target", defaultParams = {}, group = "EVENT" },
            ROUND_CONTROLS[1], ROUND_CONTROLS[2], ROUND_CONTROLS[3], ROUND_CONTROLS[4],
        },
        handlers = {
            scenario_select_chase_target = chooseChaseTarget,
            scenario_start_round = startRound,
            scenario_complete_round = completeRound,
            scenario_advance_round = advanceRound,
            scenario_restart_round = restartRound,
        },
    })
    log("Initialize() -> components registered")
    return true
end

log("module loaded")
