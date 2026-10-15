-- KIPN_EventKOTHService.lua
--
-- Phase 7 of the Event Scenarios rewrite: the King of the Hill mode
-- engine. Same integration pattern as KIPN_EventCaptureService.lua
-- (Phase 6) and KIPN_EventTriggerService.lua (Phase 3) -- hooks
-- directly into KIPN_EventRuntimeService.lua's lifecycle, gated on
-- definition.mode == "KING_OF_THE_HILL", and never touches the
-- legacy eventType/EventObjectiveRegistry system.
--
-- KOTH deliberately reuses the *existing* round machinery as-is:
-- round start/complete/advance/restart, per-round HILL_LOCATION
-- hotspot selection, and the round timer are all already provided by
-- KIPN_EventScenarioRuntimeRegistry.lua's HOLD_AREA component (see
-- its startRound()/completeRound()) and were already relied on by
-- legacy KING_OF_THE_HILL-preset definitions. That machinery is
-- admin-driven and intentionally does not decide *who* wins a round.
-- This file adds the one thing missing: automatic, server-side
-- detection of which team is actually standing in (and has held) the
-- round's hill, so a round timer expiring credits a real winner
-- instead of nobody.
--
-- Server-authoritative by construction: every tick independently
-- reads each eligible player's live position and the hill hotspot's
-- own geometry -- no client ever reports "I'm holding the hill."
--
-- SCOPE NOTE: KOTH mode requires HOLD_AREA to be selected as an
-- objectiveType (see ValidateDefinition() below) purely because that
-- is the existing, shared round-control-dispatch component -- the
-- same coupling KIPN_EventCaptureService.lua's creditDelivery()
-- already relies on for its own self-dispatched round completions.
-- This is pre-existing infrastructure, not something invented here.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_EventHotspotService"
require "KIPN_EventTeamService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventKOTHService = KIPN.Server.EventKOTHService or {}

local KOTHService = KIPN.Server.EventKOTHService

local function log(message)
    print("[KIPN EVENT KOTH] " .. tostring(message))
end

local function now()
    return type(getTimestampMs) == "function" and getTimestampMs() or 0
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------

function KOTHService.ValidateDefinition(definition)
    local failures = {}

    local hasHoldArea = false
    for _, objectiveType in ipairs((definition and definition.objectiveTypes) or {}) do
        if objectiveType == "HOLD_AREA" then hasHoldArea = true end
    end

    if not hasHoldArea then
        failures[#failures + 1] = "KOTH_REQUIRES_HOLD_AREA_OBJECTIVE"
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- PARTICIPANT / HILL LOOKUP
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

local function getHillHotspot(runtime, definition)
    if not runtime.round or not runtime.round.hotspotId then return nil end
    return KIPN.Server.EventHotspotService.FindById(definition, runtime.round.hotspotId)
end

------------------------------------------------------------
-- RUNTIME LIFECYCLE
------------------------------------------------------------

function KOTHService.InitializeRuntime(runtime, _definition)
    runtime.kothState = {
        teamRoundWins = {},
        roundControlSeconds = {},
        lastSeenRoundStartedAtMs = nil,
        lastTickAtMs = nil,
        currentControllerTeamId = nil,
    }
    log("InitializeRuntime() -> " .. tostring(runtime.eventDefinitionId))
end

function KOTHService.Tick(runtime, definition)
    if not runtime.round or runtime.round.state ~= "ACTIVE" then return end

    runtime.kothState = runtime.kothState or {
        teamRoundWins = {},
        roundControlSeconds = {},
    }
    local state = runtime.kothState
    local nowMs = now()

    -- Round-transition detection (same "watch startedAtMs change"
    -- technique as KIPN_EventCaptureService.lua's Tick()) -- catches
    -- both a fresh round and a restarted one, so per-round control
    -- time never bleeds across rounds.
    if state.lastSeenRoundStartedAtMs ~= runtime.round.startedAtMs then
        state.lastSeenRoundStartedAtMs = runtime.round.startedAtMs
        state.roundControlSeconds = {}
        state.currentControllerTeamId = nil
        state.lastTickAtMs = nowMs
        log("Tick() -> round control reset for round " .. tostring(runtime.round.current))
    end

    local elapsedSeconds = state.lastTickAtMs and math.max(0, (nowMs - state.lastTickAtMs) / 1000) or 0
    state.lastTickAtMs = nowMs

    local hill = getHillHotspot(runtime, definition)
    if not hill then
        state.currentControllerTeamId = nil
        return
    end

    -- Exclusive presence only: exactly one team inside the hill
    -- geometry accrues control time. Zero teams present, or more than
    -- one (contested), accrues nothing this tick.
    local presentTeams = {}
    for _, entry in ipairs(getEligibleParticipants(runtime)) do
        local x, y, z = entry.player:getX(), entry.player:getY(), entry.player:getZ()
        if KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, hill) then
            local teamId = KIPN.Server.EventTeamService.GetPlayerTeam(definition, entry.username)
            if teamId then presentTeams[teamId] = true end
        end
    end

    local controllingTeamId, presentCount = nil, 0
    for teamId in pairs(presentTeams) do
        controllingTeamId = teamId
        presentCount = presentCount + 1
    end

    if presentCount == 1 then
        state.roundControlSeconds[controllingTeamId] =
            (state.roundControlSeconds[controllingTeamId] or 0) + elapsedSeconds
        state.currentControllerTeamId = controllingTeamId
    else
        state.currentControllerTeamId = presentCount > 1 and "CONTESTED" or nil
    end
end

------------------------------------------------------------
-- ROUND / OVERALL WINNER RESOLUTION
------------------------------------------------------------

-- Called from KIPN_EventRuntimeService.lua's evaluateEndConditions()
-- right before it dispatches "scenario_complete_round" on round timer
-- expiry, so the dispatch's params can carry a real winnerTeamId
-- instead of none. A tie (two or more teams with equal, nonzero
-- control seconds) is an explicit no-winner result for that round --
-- not an arbitrary pick -- matching KIPN_EventCaptureService.lua's
-- tie philosophy.
function KOTHService.DetermineRoundWinner(runtime, _definition)
    local state = runtime.kothState
    if not state then return nil end

    local bestTeamId, bestSeconds, tied = nil, 0, false
    for teamId, seconds in pairs(state.roundControlSeconds or {}) do
        if seconds > bestSeconds then
            bestTeamId, bestSeconds, tied = teamId, seconds, false
        elseif seconds == bestSeconds and seconds > 0 then
            tied = true
        end
    end

    if not bestTeamId or bestSeconds <= 0 or tied then
        log("DetermineRoundWinner() -> no winner (tied=" .. tostring(tied) .. ")")
        return nil
    end

    state.teamRoundWins[bestTeamId] = (state.teamRoundWins[bestTeamId] or 0) + 1
    log("DetermineRoundWinner() -> " .. tostring(bestTeamId) .. " (" .. tostring(bestSeconds) .. "s)")
    return bestTeamId
end

-- Called from evaluateEndConditions()'s final-round-complete branch,
-- same call site as KIPN_EventCaptureService.lua's ResolveOverallWinner --
-- tallies cumulative round wins per team and sets runtime.winners to
-- every member of the highest-scoring team, with explicit co-winners
-- on an overall tie (never an arbitrary table-order pick) and no
-- winners at all if nobody ever won a round.
function KOTHService.ResolveOverallWinner(runtime, definition)
    local state = runtime.kothState
    if not state then return end

    runtime.winners = {}

    local bestWins = 0
    for _, wins in pairs(state.teamRoundWins or {}) do
        if wins > bestWins then bestWins = wins end
    end

    if bestWins <= 0 then
        log("ResolveOverallWinner() -> no round wins recorded; leaving winners empty")
        return
    end

    for _, team in ipairs((definition and definition.teams) or {}) do
        if (state.teamRoundWins[team.id] or 0) == bestWins then
            for username in pairs(team.members or {}) do
                if runtime.participants[username] then
                    runtime.winners[username] = true
                end
            end
        end
    end

    log("ResolveOverallWinner() -> bestWins=" .. tostring(bestWins))
end

function KOTHService.Initialize()
    log("Initialize()")
    return true
end

return true
