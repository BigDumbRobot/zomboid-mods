-- KIPN_EventTimerService.lua
--
-- Phase 4 of the Event Scenarios architecture rewrite: scoped timers.
-- Replaces the old shortcut where a single event-wide
-- runtime.endsAtMs, whenever enabled, always meant "expiry = WIN" for
-- every mode, and where a "Round Timer" definition had no distinct
-- timer of its own and silently reused the event-wide duration.
--
-- Two scopes, both authoritative-timestamp based (getTimestampMs(),
-- never a raw client/Lua timer):
--
--   EVENT: runtime.endsAtMs -- unchanged field name/shape from before
--          this phase, so every other reader of it (buildStatusPayload,
--          KIPN_EventDirector.lua's ADD_TIME control) keeps working
--          unmodified. Expiry behavior is now explicit
--          (KIPN.Shared.EventTimerExpiryBehaviors.WIN/FAIL, read from
--          definition.duration.expiryBehavior) instead of hardcoded --
--          WIN remains the default, so an existing definition (which
--          has never set this field) behaves exactly as before.
--   ROUND:  runtime.round.timerEndsAtMs -- new. Sourced from
--          definition.roundDuration, a field wholly separate from
--          definition.duration, so a Round Timer definition (e.g. King
--          of the Hill's preset) is no longer measuring the total
--          event -- it now needs its own explicit roundDuration.
--          Expiry always means "complete the current round" (see
--          KIPN_EventRuntimeService.lua's evaluateEndConditions,
--          which dispatches KIPN_EventScenarioRuntimeRegistry.lua's
--          existing scenario_complete_round control) -- it does not
--          end the whole event by itself, and it does not invent
--          mode-specific winner attribution (e.g. Chase's "Target
--          survives the round = Target wins" is that mode's own
--          concern, not this generic service's).

if isClient() then return end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventTimerService = KIPN.Server.EventTimerService or {}

local TimerService = KIPN.Server.EventTimerService

local function log(message)
    print("[KIPN EVENT TIMER] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

------------------------------------------------------------
-- EVENT-SCOPED TIMER
------------------------------------------------------------

function TimerService.StartEventTimer(runtime, definition)
    local duration = definition and definition.duration

    runtime.endsAtMs = (duration and duration.enabled and duration.durationSeconds)
        and (now() + duration.durationSeconds * 1000)
        or nil
end

function TimerService.HasEventTimerExpired(runtime)
    return runtime.endsAtMs ~= nil and now() >= runtime.endsAtMs
end

function TimerService.GetRemainingEventMs(runtime)
    if not runtime.endsAtMs then return nil end
    return math.max(0, runtime.endsAtMs - now())
end

-- Defaults to WIN -- the exact behavior every Event Definition has
-- always had, since expiryBehavior did not exist before this phase.
function TimerService.GetEventExpiryBehavior(definition)
    local behavior = definition and definition.duration and definition.duration.expiryBehavior

    if behavior == KIPN.Shared.EventTimerExpiryBehaviors.FAIL then
        return KIPN.Shared.EventTimerExpiryBehaviors.FAIL
    end

    return KIPN.Shared.EventTimerExpiryBehaviors.WIN
end

------------------------------------------------------------
-- ROUND-SCOPED TIMER
------------------------------------------------------------

function TimerService.StartRoundTimer(runtime, definition)
    local duration = definition and definition.roundDuration

    runtime.round.timerEndsAtMs = (duration and duration.enabled and duration.durationSeconds)
        and (now() + duration.durationSeconds * 1000)
        or nil
end

-- False once the round is no longer ACTIVE (already completed,
-- restarted with a fresh timer, or never started) -- callers do not
-- need to separately guard against re-triggering an already-completed
-- round every tick.
function TimerService.HasRoundTimerExpired(runtime)
    if not runtime.round or runtime.round.state ~= "ACTIVE" then return false end
    if not runtime.round.timerEndsAtMs then return false end
    return now() >= runtime.round.timerEndsAtMs
end

function TimerService.GetRemainingRoundMs(runtime)
    if not runtime.round or not runtime.round.timerEndsAtMs then return nil end
    return math.max(0, runtime.round.timerEndsAtMs - now())
end

function TimerService.Initialize()
    log("Initialize() -> module ready")
    return true
end

log("module loaded")
