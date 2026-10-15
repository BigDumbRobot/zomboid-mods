-- KIPN_EventSurvivorRunService.lua
--
-- Phase 10 of the Event Scenarios rewrite: the Survivor Run mode
-- engine. Unlike every mode built so far, Survivor Run has zero
-- legacy or partial-legacy backing to build on (no Scenario Preset
-- ever mapped to it -- see shared/KIPN_Shared.lua's
-- EventPresetModeMap) and its mode contract did not survive into this
-- phase's context, so its mechanic was confirmed directly with the
-- project owner before writing any code: a single continuous PVE
-- session (usesRounds=false, usesTeams=false, hasVariants=false) that
-- credits, when the event's own duration expires, only the
-- participants who are still alive -- not everyone who ever joined,
-- which is what KIPN_EventRuntimeService.lua's existing generic
-- creditAllParticipantsAsWinners() would otherwise credit for that
-- same TIMER_EXPIRED path.
--
-- This is deliberately the smallest possible new mechanic, per that
-- confirmation: no polling Tick, no world-object spawning, no rounds,
-- no ranking/leaderboard math. It reuses the event's own existing
-- generic duration/timer (definition.duration / KIPN_EventTimerService.lua,
-- already fully-generic infrastructure -- "Surviving The Duration
-- Wins" is literally its existing WIN-expiry-behavior label) and
-- Events.OnPlayerDeath, which already fires through
-- KIPN_EventRuntimeService.lua's existing onPlayerDeath handler --
-- extended here with one more mode-gated branch, the same pattern
-- KIPN_EventScenarioRuntimeRegistry.lua's Chase target-death hook
-- already established.
--
-- Server-authoritative by construction: a death is a real server-side
-- event: no client ever claims "I'm still alive."

if isClient() then return end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventSurvivorRunService = KIPN.Server.EventSurvivorRunService or {}

local SurvivorRunService = KIPN.Server.EventSurvivorRunService

local function log(message)
    print("[KIPN EVENT SURVIVOR RUN] " .. tostring(message))
end

local function now()
    return type(getTimestampMs) == "function" and getTimestampMs() or 0
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------

-- Survivor Run's only win path is the event's own duration expiring
-- (see this file's header) -- without it enabled, the event could
-- never reach a WIN at all.
function SurvivorRunService.ValidateDefinition(definition)
    local failures = {}

    if not (definition and definition.duration and definition.duration.enabled == true) then
        failures[#failures + 1] = "SURVIVOR_RUN_REQUIRES_DURATION"
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- RUNTIME LIFECYCLE
------------------------------------------------------------

function SurvivorRunService.InitializeRuntime(runtime, _definition)
    runtime.survivorRunState = {
        deaths = {},
    }
    log("InitializeRuntime() -> " .. tostring(runtime.eventDefinitionId))
end

-- Called from KIPN_EventRuntimeService.lua's existing
-- Events.OnPlayerDeath handler for every participant death in an
-- active Survivor Run event.
function SurvivorRunService.OnParticipantDeath(runtime, _definition, username)
    if not username or not runtime.participants[username] then
        return
    end

    runtime.survivorRunState = runtime.survivorRunState or { deaths = {} }

    if runtime.survivorRunState.deaths[username] then
        -- Already recorded -- idempotent against a duplicate event
        -- delivery, keeps the first recorded death.
        return
    end

    runtime.survivorRunState.deaths[username] = { atMs = now() }
    log("OnParticipantDeath() -> " .. tostring(username))
end

-- Called from KIPN_EventRuntimeService.lua's evaluateEndConditions()
-- when the event's own duration expires with the WIN expiry behavior
-- -- credits only participants never recorded as dead, instead of the
-- generic "everyone who ever joined wins" fallback every other
-- mode/definition still uses for that same path.
function SurvivorRunService.ResolveSurvivors(runtime, _definition)
    runtime.winners = {}

    local deaths = (runtime.survivorRunState and runtime.survivorRunState.deaths) or {}
    local survivorCount = 0

    for username, participant in pairs(runtime.participants or {}) do
        if not deaths[username] then
            runtime.winners[username] = participant or true
            survivorCount = survivorCount + 1
        end
    end

    log("ResolveSurvivors() -> " .. tostring(survivorCount) .. " survivor(s)")
end

-- True once every participant who took part has fallen (or left):
-- nobody is left to survive, so the run is lost now rather than when
-- the clock finally runs out. Needs at least one recorded death so an
-- event nobody has reached yet does not end at once.
function SurvivorRunService.AllDown(runtime)
    local deaths = runtime.deaths or {}
    local anyDeath = false
    for _ in pairs(deaths) do anyDeath = true end
    if not anyDeath then return false end
    local online = {}
    local players = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then online[p:getUsername()] = true end
        end
    end
    for username in pairs(runtime.participants or {}) do
        if online[username] and not deaths[username] then return false end
    end
    return true
end

-- Dodgeball of the Dead: with two or more who took part, the one
-- still standing when everyone else is down wins at once. Returns
-- their username, or nil.
function SurvivorRunService.LastStanding(runtime)
    local deaths = runtime.deaths or {}
    local online = {}
    local players = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then online[p:getUsername()] = true end
        end
    end
    local total, standing = 0, {}
    for username in pairs(runtime.participants or {}) do
        total = total + 1
        if online[username] and not deaths[username] then standing[#standing + 1] = username end
    end
    if total >= 2 and #standing == 1 then return standing[1] end
    return nil
end

function SurvivorRunService.Initialize()
    log("Initialize()")
    return true
end

return true
