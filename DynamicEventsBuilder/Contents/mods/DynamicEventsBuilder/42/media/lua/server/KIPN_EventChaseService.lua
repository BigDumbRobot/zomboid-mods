-- KIPN_EventChaseService.lua
--
-- Phase 8 of the Event Scenarios rewrite: the Chase mode engine. Same
-- integration pattern as KIPN_EventCaptureService.lua (Phase 6) and
-- KIPN_EventKOTHService.lua (Phase 7) -- hooks directly into
-- KIPN_EventRuntimeService.lua's lifecycle and
-- KIPN_EventScenarioRuntimeRegistry.lua's existing player-death path,
-- gated on definition.mode == "CHASE", and never touches the legacy
-- eventType/EventObjectiveRegistry system.
--
-- Chase deliberately reuses the *existing* CHASE_TARGET machinery as-
-- is: target selection (admin-triggered, with a random fallback -- see
-- KIPN_EventScenarioRuntimeRegistry.lua's chooseChaseTarget()), round
-- start/complete/advance/restart, the round timer, and target-death
-- detection via Events.OnPlayerDeath (see that same file's
-- OnPlayerDeath(), already wired to complete the round the instant
-- the chase target dies) were all already working before this phase.
-- What was missing is a real WINNER: OnPlayerDeath completed the
-- round with no credited winner, and round-timer expiry (target
-- survives) never credited the target either. This file adds both,
-- plus one new thing neither the round machinery nor
-- EventObjectiveRegistry could ever have provided -- kill
-- attribution.
--
-- KILL ATTRIBUTION: vanilla Project Zomboid has no "on kill" event.
-- Attribution here uses the exact technique already proven by
-- KIPN_LeaderboardService.lua's PvP kill tracking -- record the most
-- recent player-vs-player hit on the victim (via
-- Events.OnWeaponHitCharacter, which already fires once per landed
-- hit through KIPN_EventRuntimeService.lua's existing PVP-rule
-- handler -- see this file's RecordHit()) and, if a recent-enough hit
-- is on file when the target dies, credit that attacker. This is a
-- last-hit heuristic, not a verified damage-source query (PZ exposes
-- none), and is used here only for display/log purposes -- see
-- OnTargetKilled()'s header for why round-winner credit does not
-- depend on it.
--
-- Server-authoritative by construction: every credited hit and every
-- death is a real server-side event; no client ever reports "I got
-- the kill."

if isClient() then return end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventChaseService = KIPN.Server.EventChaseService or {}

local ChaseService = KIPN.Server.EventChaseService

-- Same window as KIPN_LeaderboardService.lua's ATTRIBUTION_WINDOW_MS
-- -- a hit older than this when the victim dies is too stale to
-- credit as "the kill."
local ATTRIBUTION_WINDOW_MS = 20000

local function log(message)
    print("[KIPN EVENT CHASE] " .. tostring(message))
end

local function now()
    return type(getTimestampMs) == "function" and getTimestampMs() or 0
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------

function ChaseService.ValidateDefinition(definition)
    local failures = {}

    local hasChaseTarget = false
    for _, objectiveType in ipairs((definition and definition.objectiveTypes) or {}) do
        if objectiveType == "CHASE_TARGET" then hasChaseTarget = true end
    end

    if not hasChaseTarget then
        failures[#failures + 1] = "CHASE_REQUIRES_CHASE_TARGET_OBJECTIVE"
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- PARTICIPANT LOOKUP
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

------------------------------------------------------------
-- RUNTIME LIFECYCLE
------------------------------------------------------------

function ChaseService.InitializeRuntime(runtime, _definition)
    runtime.chaseState = {
        playerRoundWins = {},
        lastAttacker = {},
        lastRoundKillerUsername = nil,
    }
    log("InitializeRuntime() -> " .. tostring(runtime.eventDefinitionId))
end

-- Called from KIPN_EventRuntimeService.lua's existing
-- Events.OnWeaponHitCharacter handler for every landed (non-blocked)
-- hit inside an active CHASE-mode event -- see this file's header.
function ChaseService.RecordHit(runtime, attackerUsername, victimUsername)
    if not attackerUsername or not victimUsername or attackerUsername == victimUsername then
        return
    end

    runtime.chaseState = runtime.chaseState or { playerRoundWins = {}, lastAttacker = {} }
    runtime.chaseState.lastAttacker[victimUsername] = {
        username = attackerUsername,
        atMs = now(),
    }
end

------------------------------------------------------------
-- ROUND WINNER RESOLUTION
------------------------------------------------------------

-- Called from KIPN_EventScenarioRuntimeRegistry.lua's
-- OnPlayerDeath() the instant the chase target dies. Every current
-- hunter (every eligible participant other than the target) is
-- credited a round win -- not just an attributed killer -- because
-- the target may die to a zombie, environmental damage, or an
-- unattributed hit, and the honest model for a manhunt mode is "the
-- hunters, collectively, caught the target" rather than requiring a
-- single verified killer. The attacker on file (if any, and recent
-- enough) is still returned for display/log purposes only.
function ChaseService.OnTargetKilled(runtime, _definition, targetUsername)
    runtime.chaseState = runtime.chaseState or { playerRoundWins = {}, lastAttacker = {} }
    local state = runtime.chaseState

    for _, entry in ipairs(getEligibleParticipants(runtime)) do
        if entry.username ~= targetUsername then
            state.playerRoundWins[entry.username] = (state.playerRoundWins[entry.username] or 0) + 1
        end
    end

    local killerUsername = nil
    local attribution = state.lastAttacker[targetUsername]
    if attribution and (now() - (attribution.atMs or 0)) <= ATTRIBUTION_WINDOW_MS then
        killerUsername = attribution.username
    end
    state.lastAttacker[targetUsername] = nil
    state.lastRoundKillerUsername = killerUsername

    log("OnTargetKilled() -> target=" .. tostring(targetUsername) .. " killer=" .. tostring(killerUsername))
    return killerUsername
end

-- Called from KIPN_EventRuntimeService.lua's evaluateEndConditions()
-- when the round timer expires while the round is still ACTIVE --
-- which, for Chase, can only mean the target was never killed this
-- round (OnTargetKilled() above always completes the round itself,
-- so that path and this one can never both fire for the same round).
function ChaseService.OnTargetSurvived(runtime, _definition)
    runtime.chaseState = runtime.chaseState or { playerRoundWins = {}, lastAttacker = {} }
    local state = runtime.chaseState
    local targetUsername = runtime.objectiveState and runtime.objectiveState.chaseTarget

    if not targetUsername then
        log("OnTargetSurvived() -> no chase target set; no winner")
        return nil
    end

    state.playerRoundWins[targetUsername] = (state.playerRoundWins[targetUsername] or 0) + 1
    log("OnTargetSurvived() -> " .. tostring(targetUsername))
    return targetUsername
end

-- Called from evaluateEndConditions()'s final-round-complete branch,
-- same call site as Capture/KOTH's ResolveOverallWinner -- tallies
-- cumulative individual round wins (hunter credits and target-
-- survival credits are the same currency) and sets runtime.winners to
-- every player tied at the highest total, with explicit co-winners on
-- a tie and no winners at all if nobody ever won a round.
function ChaseService.ResolveOverallWinner(runtime, _definition)
    local state = runtime.chaseState
    if not state then return end

    runtime.winners = {}

    local bestWins = 0
    for _, wins in pairs(state.playerRoundWins or {}) do
        if wins > bestWins then bestWins = wins end
    end

    if bestWins <= 0 then
        log("ResolveOverallWinner() -> no round wins recorded; leaving winners empty")
        return
    end

    for username, wins in pairs(state.playerRoundWins or {}) do
        if wins == bestWins and runtime.participants[username] then
            runtime.winners[username] = true
        end
    end

    log("ResolveOverallWinner() -> bestWins=" .. tostring(bestWins))
end

function ChaseService.Initialize()
    log("Initialize()")
    return true
end

return true
