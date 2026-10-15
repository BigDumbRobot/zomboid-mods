-- KIPN_EventRuntimeService.lua
--
-- The in-memory Event Runtime: start/stop orchestration, the
-- Events.OnTick-driven loop (timer countdown, per-objective passive
-- escalation, leave-zone rule enforcement, win/fail condition
-- evaluation), the PvP-in-zone rule, live control dispatch,
-- environment application, narrative broadcast, and the outcome-aware
-- reward grant at event end.
--
-- Runtime state (KIPN.Server.EventRuntimeService.ActiveRuntimes) is
-- NEVER persisted -- a server restart resets it. The backing Event
-- Definition's `status` field is persisted (see
-- KIPN_EventScenarioService.lua), and that file resets any stale
-- in-progress definition (ANNOUNCED/JOINING/ACTIVE/ENDING) back to
-- READY at boot since there is no runtime left to back it up.
--
-- Tick pattern follows KIPN_AnnouncementService.lua's
-- lastPollMs/getTimestampMs()/POLL_INTERVAL_MS idiom -- real
-- wall-clock time, not game time, so behavior stays sane across
-- time-scale changes.
--
-- PvP enforcement follows KIPN_CombatZoneService.lua's approach
-- (Events.OnWeaponHitCharacter + victim:setAvoidDamage(true)).
-- setAvoidDamage(true) is idempotent, so this listener coexists
-- safely alongside CombatZoneService's independent listener.
--
-- OUTCOME MODEL:
--
-- Every stop has an outcome: "WIN", "FAIL", "MANUAL", or "LOST"
-- (zone/definition disappeared out from under a running event).
-- Rewards are granted on any outcome except "FAIL" -- a failed event
-- doesn't pay out. Narrative winText/failText is broadcast only for
-- "WIN"/"FAIL" outcomes respectively; a manual stop or lost
-- zone/definition broadcasts nothing (ambiguous which text would
-- apply). Surviving the full configured duration counts as a WIN.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_EventGameLoopService"
require "KIPN_Server"
require "KIPN_WorldRegistry"
require "KIPN_AdminService"
require "KIPN_Permissions"
require "KIPN_EventObjectiveRegistry"
require "KIPN_EventScenarioService"
require "KIPN_EventHotspotService"
require "KIPN_EventScenarioRuntimeRegistry"
require "KIPN_EventRewardService"
require "KIPN_EventParticipationService"
require "KIPN_EventTeamService"
require "KIPN_EventTriggerService"
require "KIPN_EventTimerService"
require "KIPN_EventCaptureService"
require "KIPN_EventKOTHService"
require "KIPN_EventChaseService"
require "KIPN_EventSurvivorRunService"
require "KIPN_EventAdventureService"
require "KIPN_EventExtractionService"
require "KIPN_EventOlympicsService"
require "KIPN_EventThreatService"
require "KIPN_EventLoadoutService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.EventRuntimeService = KIPN.Server.EventRuntimeService or {}

local EventRuntimeService = KIPN.Server.EventRuntimeService

EventRuntimeService.ActiveRuntimes = EventRuntimeService.ActiveRuntimes or {}

local RUNTIME_TICK_INTERVAL_MS = 5000
local LOG_CAP = 50

-- Rough hour-of-day approximations for the environment.timeOfDay
-- preset. High confidence: getGameTime():setTimeOfDay(hour) is a
-- well-established vanilla PZ Lua call.
local TIME_OF_DAY_HOURS = { DAY = 12, NIGHT = 0, DUSK = 19, DAWN = 6 }

local function log(message)
    print("[KIPN EVENT RUNTIME] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT RUNTIME] ERROR: " .. tostring(message))
end

-- Tiered authorization (see KIPN_Permissions.lua's
-- Permissions.AuthorizeEventTier for the full tier/category table
-- and why it lives there instead of here). Replaces the old
-- blanket-admin `requireAdmin` gate -- MODERATOR can now
-- start/stop/add-time, and any non-USER tier can view status,
-- without needing full ADMIN.
local function authorize(player, category)
    return KIPN.Server.Permissions.AuthorizeEventTier(player, category)
end

------------------------------------------------------------
-- ZONE ENTRY POINT
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

local function appendLog(runtime, message)
    runtime.log[#runtime.log + 1] = message

    while #runtime.log > LOG_CAP do
        table.remove(runtime.log, 1)
    end
end

------------------------------------------------------------
-- ENVIRONMENT APPLICATION
------------------------------------------------------------
--
-- Applied once, at event start. PZ has no per-zone time/weather
-- concept -- time of day and weather are server-global, so this
-- affects the whole world, not just the Event Zone. That's a real
-- gameplay caveat for a server with players outside the event too;
-- flagged here and in the Event Scenarios follow-up risk list.
--
-- timeOfDay: high-confidence vanilla API (getGameTime():setTimeOfDay).
--
-- weatherPreset: UNVERIFIED. ClimateManager's exact Lua method names
-- for this game build are not confirmed against source -- this is a
-- best-effort attempt, defensively pcall-wrapped, and should be
-- tested on a live server before being relied on. A failure here
-- never blocks the event from starting.
------------------------------------------------------------

local function applyEnvironment(environment)
    if not environment then
        return
    end

    if environment.timeOfDay and TIME_OF_DAY_HOURS[environment.timeOfDay] then
        local ok, err = pcall(function()
            getGameTime():setTimeOfDay(TIME_OF_DAY_HOURS[environment.timeOfDay])
        end)

        if not ok then
            logError("Failed to apply environment.timeOfDay: " .. tostring(err))
        end
    end

    if environment.weatherPreset and environment.weatherPreset ~= "CLEAR" then
        local ok, err = pcall(function()
            local climate = getClimateManager and getClimateManager()

            if not climate then
                return
            end

            if environment.weatherPreset == "STORM" and climate.triggerStorm then
                climate:triggerStorm(600, 1.0)
            elseif environment.weatherPreset == "RAIN" and climate.setRainIntensity then
                climate:setRainIntensity(0.6)
            elseif environment.weatherPreset == "FOG" and climate.setFogIntensity then
                climate:setFogIntensity(0.8)
            end
        end)

        if not ok then
            logError(
                "Failed to apply environment.weatherPreset (" .. tostring(environment.weatherPreset)
                .. ") -- ClimateManager API for this build is unverified: " .. tostring(err)
            )
        end
    end
end

local function captureEnvironmentSnapshot()
    local snapshot = {}
    local ok, timeOfDay = pcall(function() return getGameTime():getTimeOfDay() end)
    if ok then snapshot.timeOfDay = timeOfDay end
    log("Captured environment snapshot: timeOfDay=" .. tostring(snapshot.timeOfDay))
    return snapshot
end

local function restoreEnvironment(snapshot)
    if type(snapshot) ~= "table" then
        log("No environment snapshot available for restoration.")
        return true
    end
    local ok, err = pcall(function()
        if snapshot.timeOfDay ~= nil then getGameTime():setTimeOfDay(snapshot.timeOfDay) end
    end)
    if not ok then logError("Environment restoration failed: " .. tostring(err)) end
    log("Environment restoration complete: success=" .. tostring(ok))
    return ok
end

------------------------------------------------------------
-- NARRATIVE BROADCAST
------------------------------------------------------------
--
-- Pushed through KIPN's proven SendToPlayer transport rather than
-- calling any character-rendering API server-side directly -- the
-- CLIENT renders it locally (see KIPN_EventScenarioAdminUI.lua's
-- onServerResponse, which is loaded and listening for every player,
-- not only admins who open that panel).
------------------------------------------------------------

local function broadcastNarrative(runtime, text)
    if not text or text == "" then
        return
    end

    local online = getOnlinePlayers()

    if not online then
        return
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()

        if username and runtime.participants[username] then
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_NARRATIVE, { text = text })
        end
    end
end

------------------------------------------------------------
-- REWARD GRANT
------------------------------------------------------------
--
-- Same pattern as KIPN_MarketplaceService.lua's handleCollectParcel:
-- KIPN.Server.CreateItem + inventory:AddItem, guarded per item,
-- quantity looped. Only grants to participants who are
-- still online at event end -- v1 has no offline delivery mechanism
-- for Event rewards. Not called at all for a "FAIL" outcome.
------------------------------------------------------------

local function grantRewards(definition)
    local items = (definition.rewards and definition.rewards.items) or {}

    if #items == 0 then
        return
    end

    local online = getOnlinePlayers()

    if not online then
        return
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()

        if username and definition.participants[username] then
            local inventory = p:getInventory()

            for _, rewardItem in ipairs(items) do
                for _ = 1, rewardItem.count do
                    local item = KIPN.Server.CreateItem(rewardItem.itemFullType)

                    if item then
                        inventory:AddItem(item)
                    else
                        logError(
                            "Reward grant failed for " .. username .. ": "
                            .. tostring(rewardItem.itemFullType)
                        )
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- START / STOP
------------------------------------------------------------

local function startEvent(player, definition)
    -- v1 guard: only one ACTIVE event globally at a time.
    for _, runtime in pairs(EventRuntimeService.ActiveRuntimes) do
        if runtime then
            return false, "ANOTHER_EVENT_ACTIVE"
        end
    end

    -- JOINING, not READY -- this is the lifecycle's ANNOUNCED ->
    -- JOINING -> [this call] -> ACTIVE transition. See
    -- KIPN_EventScenarioService.lua's handleAnnounce/handleOpenJoining.
    if definition.status ~= KIPN.Server.EventScenarioService.Status.JOINING then
        return false, "DEFINITION_NOT_JOINING"
    end

    local scopeType = definition.scopeType or KIPN.Shared.EventScopeTypes.ZONE
    local zone = definition.zoneId and KIPN.Server.WorldRegistry.GetZone(definition.zoneId) or nil

    if scopeType == KIPN.Shared.EventScopeTypes.ZONE and not definition.zoneId then
        return false, "NO_ZONE"
    end

    if scopeType == KIPN.Shared.EventScopeTypes.ZONE and (not zone or zone.active == false) then
        return false, "ZONE_INACTIVE"
    end

    if scopeType == KIPN.Shared.EventScopeTypes.ZONE
        and zone and zone.type ~= KIPN.Server.WorldRegistry.ZoneTypes.EVENT
    then
        return false, "NOT_AN_EVENT_ZONE"
    end

    if not (KIPN.Server.EventObjectiveRegistry.Get(definition.eventType)) then
        return false, "UNKNOWN_EVENT_TYPE"
    end

    local now = getTimestampMs and getTimestampMs() or 0

    local runtime = {
        eventDefinitionId = definition.id,
        instanceId = tostring(definition.id) .. ":" .. tostring(now) .. ":" .. tostring(ZombRand(1000000)),
        objectiveType = definition.eventType,
        startedAtMs = now,
        zoneId = definition.zoneId,
        scopeType = scopeType,
        participants = {},
        winners = {},
        directorState = {},
        spawnedEventZombies = {},
        environmentSnapshot = captureEnvironmentSnapshot(),
        log = {},
    }

    -- Phase 4: sets runtime.endsAtMs -- same field, same shape as
    -- before this phase, just routed through the scoped timer service
    -- rather than computed inline. See KIPN_EventTimerService.lua.
    KIPN.Server.EventTimerService.StartEventTimer(runtime, definition)

    for username in pairs(definition.participants) do
        runtime.participants[username] = {
            teleportedAtMs = nil,
            lastKnownInZone = true,
            steamId = nil,
        }
    end

    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if online then
        for index = 0, online:size() - 1 do
            local onlinePlayer = online:get(index)
            local username = onlinePlayer and onlinePlayer:getUsername()
            local participant = username and runtime.participants[username]
            if participant then
                local idOk, steamId = pcall(function()
                    return KIPN.Shared.GetPlayerId and KIPN.Shared.GetPlayerId(onlinePlayer)
                        or onlinePlayer:getSteamID()
                end)
                if idOk and steamId then participant.steamId = tostring(steamId) end
            end
        end
    end

    EventRuntimeService.ActiveRuntimes[definition.id] = runtime

    KIPN.Server.EventScenarioService.SetDefinitionStatus(definition.id, KIPN.Server.EventScenarioService.Status.ACTIVE)

    pcall(applyEnvironment, definition.environment)

    -- Phase 11: Adventure rolls a real mode/variant and generates
    -- everything it needs (hotspots/teams/objectiveTypes/timers)
    -- directly onto `definition`, BEFORE any other init below reads
    -- it -- see KIPN_EventAdventureService.lua's header for why this
    -- must run first and why mutating `definition` in place is safe.
    if definition.mode == KIPN.Shared.EventModes.ADVENTURE then
        local rollOk, rollReason = KIPN.Server.EventAdventureService.RollAndGenerate(runtime, definition)
        if not rollOk then
            EventRuntimeService.ActiveRuntimes[definition.id] = nil
            restoreEnvironment(runtime.environmentSnapshot)
            KIPN.Server.EventScenarioService.SetDefinitionStatus(definition.id, KIPN.Server.EventScenarioService.Status.JOINING)
            logError("Adventure roll failed: " .. tostring(rollReason))
            return false, "ADVENTURE_ROLL_FAILED"
        end
    end

    local scenarioOk, scenarioErr = pcall(
        KIPN.Server.EventScenarioRuntimeRegistry.InitializeRuntime,
        runtime,
        definition
    )
    if not scenarioOk then
        -- Undo the roll above (if any) before reverting to JOINING --
        -- otherwise the definition would be left holding a generated
        -- configuration despite the event never actually starting.
        pcall(KIPN.Server.EventAdventureService.RestoreOriginal, runtime, definition)
        EventRuntimeService.ActiveRuntimes[definition.id] = nil
        restoreEnvironment(runtime.environmentSnapshot)
        KIPN.Server.EventScenarioService.SetDefinitionStatus(definition.id, KIPN.Server.EventScenarioService.Status.JOINING)
        logError("Scenario runtime initialization failed: " .. tostring(scenarioErr))
        return false, "SCENARIO_RUNTIME_INIT_FAILED"
    end

    -- Phase 3: ordered story/trigger runtime state. Independent of
    -- the scenario registry above -- a definition with no
    -- objectives authored just gets an inert storyState/triggerState,
    -- same as HORDE_SURVIVAL definitions today.
    local triggerInitOk, triggerInitErr = pcall(
        KIPN.Server.EventTriggerService.InitializeRuntime,
        runtime,
        definition
    )
    if not triggerInitOk then
        logError("Trigger runtime initialization failed: " .. tostring(triggerInitErr))
    end

    -- Phase 6: the Capture mode engine. Gated on mode -- a no-op for
    -- every other definition, same pattern as every mode-specific
    -- hook added since.
    if definition.mode == "CAPTURE" then
        local captureInitOk, captureInitErr = pcall(
            KIPN.Server.EventCaptureService.InitializeRuntime,
            runtime,
            definition
        )
        if not captureInitOk then
            logError("Capture runtime initialization failed: " .. tostring(captureInitErr))
        end
    end

    -- Phase 7: the King of the Hill mode engine. Same gated no-op-
    -- for-other-modes pattern as Capture above.
    if definition.mode == "KING_OF_THE_HILL" then
        local kothInitOk, kothInitErr = pcall(
            KIPN.Server.EventKOTHService.InitializeRuntime,
            runtime,
            definition
        )
        if not kothInitOk then
            logError("KOTH runtime initialization failed: " .. tostring(kothInitErr))
        end
    end

    -- Phase 8: the Chase mode engine. Same gated no-op-for-other-
    -- modes pattern as Capture/KOTH above.
    if definition.mode == "CHASE" then
        local chaseInitOk, chaseInitErr = pcall(
            KIPN.Server.EventChaseService.InitializeRuntime,
            runtime,
            definition
        )
        if not chaseInitOk then
            logError("Chase runtime initialization failed: " .. tostring(chaseInitErr))
        end
    end

    -- Phase 10: the Survivor Run mode engine. Same gated no-op-for-
    -- other-modes pattern as Capture/KOTH/Chase above.
    if definition.mode == "SURVIVOR_RUN" then
        local survivorRunInitOk, survivorRunInitErr = pcall(
            KIPN.Server.EventSurvivorRunService.InitializeRuntime,
            runtime,
            definition
        )
        if not survivorRunInitOk then
            logError("Survivor Run runtime initialization failed: " .. tostring(survivorRunInitErr))
        end
    end

    -- Difficulty roll and the scenario's threats (sieges, fires,
    -- alarms, ambushes); before anyone is brought in so their loadout
    -- knows the difficulty.
    local threatOk, threatErr = pcall(KIPN.Server.EventThreatService.InitializeRuntime, runtime, definition)
    if not threatOk then logError("Threat initialization failed: " .. tostring(threatErr)) end

    -- Extraction's evac window and the Olympics' heats.
    if definition.mode == "EXTRACTION" then
        local ok, err = pcall(KIPN.Server.EventExtractionService.InitializeRuntime, runtime, definition)
        if not ok then logError("Extraction runtime initialization failed: " .. tostring(err)) end
    end
    if definition.mode == "OLYMPICS" then
        local ok, err = pcall(KIPN.Server.EventOlympicsService.InitializeRuntime, runtime, definition)
        if not ok then logError("Olympics runtime initialization failed: " .. tostring(err)) end
    end

    -- Everyone who signed up while joining was open is brought in now.
    local bringOk, bringErr = pcall(KIPN.Server.EventParticipationService.BringInRoster, runtime, definition)
    if not bringOk then logError("BringInRoster failed: " .. tostring(bringErr)) end

    appendLog(runtime, "Event started.")

    if definition.narrative then
        broadcastNarrative(runtime, definition.narrative.briefing)
    end

    local participationOk, participationErr = pcall(
        KIPN.Server.EventParticipationService.BroadcastEventStartInvite,
        runtime,
        definition
    )
    if not participationOk then
        logError("BroadcastEventStartInvite failed: " .. tostring(participationErr))
    end

    KIPN.Server.AdminService.WriteAudit(player, "EVENT_STARTED", "eventDefinition", definition.id, {})

    return true, runtime
end

-- outcome: "WIN" | "FAIL" | "MANUAL" | "LOST"
--
-- ACTIVE -> ENDING -> COMPLETE. ENDING is set immediately before
-- COMPLETE within this same call (no async work happens between
-- them), matching the same momentary-transition pattern as
-- VALIDATING in KIPN_EventScenarioService.lua's handleValidate.
local function stopEvent(player, definitionId, reason, outcome)
    local runtime = EventRuntimeService.ActiveRuntimes[definitionId]

    if not runtime then
        return false, "NOT_ACTIVE"
    end

    local definition = KIPN.Server.EventScenarioService.GetDefinition(definitionId)

    if definition then
        KIPN.Server.EventScenarioService.SetDefinitionStatus(definitionId, KIPN.Server.EventScenarioService.Status.ENDING)

        if outcome == "WIN" then
            local rewardCallOk, rewardOk, rewardResult = pcall(
                KIPN.Server.EventRewardService.AwardEvent,
                definition,
                runtime,
                outcome
            )
            if not rewardCallOk or rewardOk ~= true then
                logError(
                    "Persistent reward fulfillment failed for " .. tostring(definitionId)
                    .. ": " .. tostring(rewardCallOk and rewardResult or rewardOk)
                )
            end
        else
            appendLog(runtime, "Rewards skipped for outcome " .. tostring(outcome))
        end

        if definition.narrative then
            if outcome == "WIN" then
                broadcastNarrative(runtime, definition.narrative.winText)
            elseif outcome == "FAIL" then
                broadcastNarrative(runtime, definition.narrative.failText)
            end
        end

        -- Tell every participant how it ended before they are released.
        local finishOk, finishErr = pcall(KIPN.Server.EventGameLoopService.Finish, runtime, definition, outcome)
        if not finishOk then logError("Game loop finish failed: " .. tostring(finishErr)) end

        KIPN.Server.EventScenarioService.SetDefinitionStatus(definitionId, KIPN.Server.EventScenarioService.Status.COMPLETE)
    end

    if runtime.olympicsState then
        local olympicsOk, olympicsErr = pcall(KIPN.Server.EventOlympicsService.CleanupRuntime, runtime)
        if not olympicsOk then logError("Olympics cleanup failed: " .. tostring(olympicsErr)) end
    end

    if runtime.banditState then
        local banditOk, banditErr = pcall(KIPN.Server.EventBanditService.CleanupRuntime, runtime)
        if not banditOk then logError("Bandit cleanup failed: " .. tostring(banditErr)) end
    end

    local zombieDirector = KIPN.Server.ZombieDirector
    if zombieDirector and type(zombieDirector.CleanupRuntime) == "function" then
        local cleanupOk, cleanupErr = pcall(zombieDirector.CleanupRuntime, runtime)
        if not cleanupOk then logError("Zombie cleanup failed: " .. tostring(cleanupErr)) end
    end

    -- Phase 3: clean up unclaimed temporary loot (claimed loot is
    -- retained automatically -- see KIPN_EventTriggerService.lua's
    -- CleanupRuntime() header).
    local triggerCleanupOk, triggerCleanupErr = pcall(KIPN.Server.EventTriggerService.CleanupRuntime, runtime)
    if not triggerCleanupOk then logError("Trigger/loot cleanup failed: " .. tostring(triggerCleanupErr)) end

    -- Phase 6: remove every tracked flag from wherever it currently
    -- is (inventory or world ground) -- event-created items, not
    -- player-owned, same "only touch what this system tracks"
    -- principle as the zombie/loot cleanup above.
    if definition and definition.mode == "CAPTURE" then
        local captureCleanupOk, captureCleanupErr = pcall(KIPN.Server.EventCaptureService.CleanupRuntime, runtime)
        if not captureCleanupOk then logError("Capture cleanup failed: " .. tostring(captureCleanupErr)) end
    end

    -- Phase 11: put an Adventure definition back to its clean,
    -- ungenerated state so the next play rolls fresh -- gated on
    -- runtime.adventureState, NOT definition.mode, since by now
    -- definition.mode is whatever got rolled (e.g. "CAPTURE"), not
    -- "ADVENTURE" -- see KIPN_EventAdventureService.lua's header.
    -- Runs after rewards/narrative above so both still saw the rolled
    -- configuration while they needed it.
    if definition and runtime.adventureState then
        local restoreOk, restoreErr = pcall(KIPN.Server.EventAdventureService.RestoreOriginal, runtime, definition)
        if not restoreOk then
            logError("Adventure restore failed: " .. tostring(restoreErr))
        else
            -- SetDefinitionStatus(COMPLETE) above already persisted
            -- the rolled fields; save again now that they're reverted
            -- so the on-disk copy matches what a fresh play should
            -- see, not the just-finished roll.
            KIPN.Server.Save()
        end
    end

    -- Phase 2: restore every online participant's pre-event position
    -- and, if Naked and Afraid was active, their escrowed inventory.
    -- Offline participants are left as a pending record, picked up by
    -- KIPN_EventParticipationService.lua's onCreatePlayer() the next
    -- time they connect. Covers every outcome (WIN/FAIL/MANUAL/LOST)
    -- since they all funnel through this one stopEvent() call.
    local releaseOk, releaseErr = pcall(KIPN.Server.EventParticipationService.ReleaseParticipants, runtime)
    if not releaseOk then logError("ReleaseParticipants failed: " .. tostring(releaseErr)) end

    restoreEnvironment(runtime.environmentSnapshot)

    EventRuntimeService.ActiveRuntimes[definitionId] = nil

    if player then
        KIPN.Server.AdminService.WriteAudit(player, "EVENT_STOPPED", "eventDefinition", definitionId, { reason = reason, outcome = outcome })
    end

    log("Event stopped: id=" .. tostring(definitionId) .. " reason=" .. tostring(reason) .. " outcome=" .. tostring(outcome))

    return true
end

------------------------------------------------------------
-- STATUS SNAPSHOT (sent to client)
------------------------------------------------------------

local function buildStatusPayload(definitionId)
    local definition = KIPN.Server.EventScenarioService.GetDefinition(definitionId)

    if not definition then
        return { status = "NOT_FOUND" }
    end

    local runtime = EventRuntimeService.ActiveRuntimes[definitionId]

    if not runtime then
        return {
            status = definition.status,
            eventDefinitionId = definition.id,
            eventName = definition.name,
            scopeType = definition.scopeType,
            combatRules = definition.combatRules,
        }
    end

    local controls = {}
    for _, control in ipairs(KIPN.Server.EventObjectiveRegistry.GetControls(runtime.objectiveType) or {}) do
        controls[#controls + 1] = control
    end
    for _, control in ipairs(KIPN.Server.EventScenarioRuntimeRegistry.GetControls(definition) or {}) do
        controls[#controls + 1] = control
    end

    local participantUsernames = {}
    for username in pairs(runtime.participants or {}) do participantUsernames[#participantUsernames + 1] = username end
    table.sort(participantUsernames)

    -- Phase 5: a lightweight hotspot summary for
    -- KIPN_EventDirectorPanel.lua's alarm target selector ("selected
    -- hotspot/trigger location") -- deliberately not the full hotspot
    -- record (geometry etc. isn't needed client-side for a picker).
    local hotspots = {}
    for _, hotspot in ipairs(definition.hotspots or {}) do
        if hotspot.active ~= false then
            hotspots[#hotspots + 1] = {
                id = hotspot.id,
                type = hotspot.type,
                label = hotspot.label,
                alarmEnabled = hotspot.alarmEnabled == true,
            }
        end
    end

    return {
        status = definition.status,
        eventDefinitionId = definition.id,
        eventName = definition.name,
        startedAtMs = runtime.startedAtMs,
        endsAtMs = runtime.endsAtMs,
        directorState = runtime.directorState,
        scopeType = runtime.scopeType,
        round = runtime.round,
        objectiveState = runtime.objectiveState,
        participantUsernames = participantUsernames,
        log = runtime.log,
        controls = controls,
        sliders = KIPN.Server.EventObjectiveRegistry.GetSliders(runtime.objectiveType),
        combatRules = definition.combatRules,
        hotspots = hotspots,
    }
end

------------------------------------------------------------
-- PUBLIC EXPORTS (for KIPN_EventDirector.lua)
------------------------------------------------------------
--
-- Thin wrappers around the private functions above -- no behavior
-- change, just a stable entry point so the Event Director command
-- bus (and, later, scripted/scheduled events) can drive start/stop/
-- status/control without duplicating this file's tick loop, PvP
-- listener, or leave-zone enforcement.
------------------------------------------------------------

function EventRuntimeService.StartEvent(player, definition)
    return startEvent(player, definition)
end

function EventRuntimeService.StopEvent(player, definitionId, reason, outcome)
    return stopEvent(player, definitionId, reason, outcome)
end

function EventRuntimeService.GetStatusPayload(definitionId)
    return buildStatusPayload(definitionId)
end

-- For KIPN_EventTriggerService.lua's NARRATIVE_MESSAGE trigger action
-- (Phase 3) -- exact same participant-only broadcast used for
-- briefing/win/fail text.
function EventRuntimeService.BroadcastNarrative(runtime, text)
    return broadcastNarrative(runtime, text)
end

-- Resolves the single globally-active event's definition id, or nil
-- if none is running -- v1 only ever allows one ACTIVE event at a
-- time (see startEvent()'s ANOTHER_EVENT_ACTIVE guard), so this is
-- an unambiguous lookup, not a "pick one of many" heuristic.
function EventRuntimeService.GetActiveDefinitionId()
    for definitionId, runtime in pairs(EventRuntimeService.ActiveRuntimes) do
        if runtime then
            return definitionId
        end
    end

    return nil
end

function EventRuntimeService.RuntimeControl(player, definitionId, controlId, params)
    local runtime = EventRuntimeService.ActiveRuntimes[definitionId]

    if not runtime then
        return false, "NOT_ACTIVE"
    end

    local definition = KIPN.Server.EventScenarioService.GetDefinition(definitionId)

    -- Phase 3: manual trigger activation (Event Director). "fire_trigger"
    -- is a uniquely namespaced controlId that can never collide with any
    -- objective-type's own controls (e.g. "scenario_start_round",
    -- "spawn_burst"), so it's checked first rather than folded into the
    -- two-tier fallback below.
    if controlId == "fire_trigger" then
        local ok, resultOrReason = KIPN.Server.EventTriggerService.Dispatch(controlId, runtime, definition, params)
        if ok then appendLog(runtime, "Control fired: " .. tostring(controlId)) end
        return ok, resultOrReason
    end

    local ok, resultOrReason = KIPN.Server.EventScenarioRuntimeRegistry.Dispatch(
        controlId,
        runtime,
        definition,
        params
    )

    if not ok and resultOrReason == "UNKNOWN_SCENARIO_CONTROL" then
        ok, resultOrReason = KIPN.Server.EventObjectiveRegistry.Dispatch(
            runtime.objectiveType,
            controlId,
            runtime,
            definition,
            params
        )
    end

    if ok then
        appendLog(runtime, "Control fired: " .. tostring(controlId))
    end

    return ok, resultOrReason
end

function EventRuntimeService.SliderControl(player, definitionId, sliderId, value)
    local runtime = EventRuntimeService.ActiveRuntimes[definitionId]

    if not runtime then
        return false, "NOT_ACTIVE"
    end

    local definition = KIPN.Server.EventScenarioService.GetDefinition(definitionId)

    local ok, resultOrReason = KIPN.Server.EventObjectiveRegistry.DispatchSlider(
        runtime.objectiveType,
        sliderId,
        runtime,
        definition,
        { value = value }
    )

    if ok then
        appendLog(runtime, "Slider set: " .. tostring(sliderId) .. "=" .. tostring(value))
    end

    return ok, resultOrReason
end

------------------------------------------------------------
-- COMMAND HANDLERS
------------------------------------------------------------

local function handleStart(player, args)
    if not authorize(player, "LIFECYCLE_BASIC") then
        return false
    end

    args = args or {}

    local definition = KIPN.Server.EventScenarioService.GetDefinition(args.id)

    if not definition then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_STARTED, {
            success = false,
            reason = "DEFINITION_NOT_FOUND",
        })
        return true
    end

    local ok, resultOrReason = startEvent(player, definition)

    if not ok then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_STARTED, {
            success = false,
            reason = resultOrReason,
        })
        return true
    end

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_STARTED, {
        success = true,
        status = buildStatusPayload(definition.id),
    })

    return true
end

-- ACTIVE events go through stopEvent() (rewards/narrative/ENDING->
-- COMPLETE). An event cancelled while merely ANNOUNCED/JOINING never
-- had a runtime spun up (see startEvent()'s JOINING gate) -- there's
-- nothing to tear down, so it's just a direct status transition back
-- to COMPLETE with a "MANUAL" outcome, skipping rewards/narrative
-- (nothing was ever really running).
local CANCELLABLE_PRE_ACTIVE_STATUSES = {
    ANNOUNCED = true,
    JOINING = true,
}

local function handleStop(player, args)
    if not authorize(player, "LIFECYCLE_BASIC") then
        return false
    end

    args = args or {}

    local ok, reason = stopEvent(player, args.id, "MANUAL_STOP", "MANUAL")

    if not ok and reason == "NOT_ACTIVE" then
        local definition = KIPN.Server.EventScenarioService.GetDefinition(args.id)

        if definition and CANCELLABLE_PRE_ACTIVE_STATUSES[definition.status] then
            KIPN.Server.EventScenarioService.SetDefinitionStatus(args.id, KIPN.Server.EventScenarioService.Status.COMPLETE)

            KIPN.Server.AdminService.WriteAudit(player, "EVENT_CANCELLED", "eventDefinition", args.id, {})

            ok = true
            reason = nil
        end
    end

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_STOPPED, {
        success = ok,
        reason = (not ok) and reason or nil,
    })

    return true
end

local function handleGetStatus(player, args)
    if not authorize(player, "VIEW") then
        return false
    end

    args = args or {}

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_STATUS_DATA, buildStatusPayload(args.id))

    return true
end

local function handleRuntimeControl(player, args)
    if not authorize(player, "GM_CONTROLS") then
        return false
    end

    args = args or {}

    local ok, resultOrReason = EventRuntimeService.RuntimeControl(player, args.id, args.controlId, args.params)

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_CONTROL_RESULT, {
        success = ok,
        reason = (not ok) and resultOrReason or nil,
        status = buildStatusPayload(args.id),
    })

    return true
end

------------------------------------------------------------
-- PVP-IN-ZONE / NO-COMBAT-IN-ZONE RULES
------------------------------------------------------------
--
-- Two independent things can block a hit inside an active Event
-- Zone:
--   1. combatRules.pvpAllowedInZone == false blocks PLAYER-vs-PLAYER
--      hits only (the original rule, still in effect for PVE/PVP/
--      FREE_FOR_ALL/TEAM/CUSTOM ruleTypes).
--   2. ruleType == "NO_COMBAT" blocks EVERY hit inside the zone,
--      any attacker, any victim (player or zombie) -- a true
--      pacifism zone, not just no-PvP. This relies on
--      victim:setAvoidDamage(true) working uniformly for any
--      IsoGameCharacter (IsoZombie included, per IsoGameCharacter:Hit()'s
--      generic avoidDamage check -- see KIPN_CombatZoneService.lua's
--      header comment for the underlying mechanism). The
--      player-victim case is the one already proven in this
--      codebase; the zombie-victim case is the same call but hasn't
--      been separately verified on a live server.
------------------------------------------------------------

local function getCharacterSquarePosition(character)
    if not character then
        return nil
    end

    local ok, square = pcall(function() return character:getSquare() end)

    if not ok or not square then
        return nil
    end

    return square:getX(), square:getY(), square:getZ()
end

local function getParticipantUsername(character, runtime)
    if not character or not instanceof(character, "IsoPlayer") then return nil end
    local ok, username = pcall(function() return character:getUsername() end)
    if ok and username and runtime.participants[username] then return username end
    return nil
end

local function isPositionInsideHotspotScope(definition, runtime, x, y, z)
    local hotspotService = KIPN.Server.EventHotspotService
    if not hotspotService then return false end

    local hotspots = hotspotService.GetHotspots(definition)
    local activeRoundHotspotId = runtime.round and runtime.round.state == "ACTIVE"
        and runtime.round.hotspotId or nil

    for _, hotspot in ipairs(hotspots) do
        local eligible = not activeRoundHotspotId
            or tostring(hotspot.id) == tostring(activeRoundHotspotId)
        if eligible and hotspotService.IsPositionInHotspot(x, y, z, hotspot) then return true end
    end
    return false
end

local function onWeaponHitCharacter(attacker, victim, weapon, _damage)
    if not victim then
        return
    end

    local x, y, z = getCharacterSquarePosition(victim)

    if not x then
        return
    end

    for _, runtime in pairs(EventRuntimeService.ActiveRuntimes) do
        local definition = KIPN.Server.EventScenarioService.GetDefinition(runtime.eventDefinitionId)
        local zone = definition and runtime.zoneId and KIPN.Server.WorldRegistry.GetZone(runtime.zoneId) or nil
        local attackerParticipant = getParticipantUsername(attacker, runtime)
        local victimParticipant = getParticipantUsername(victim, runtime)
        local participantInvolved = attackerParticipant ~= nil or victimParticipant ~= nil
        local insideScope = runtime.scopeType == KIPN.Shared.EventScopeTypes.OPEN_MAP
            or (runtime.scopeType == KIPN.Shared.EventScopeTypes.ZONE
                and zone and KIPN.Server.WorldRegistry.IsPositionInZone(x, y, z, zone))
            or (runtime.scopeType == KIPN.Shared.EventScopeTypes.HOTSPOTS
                and isPositionInsideHotspotScope(definition, runtime, x, y, z))

        if definition and participantInvolved and insideScope then
            local blocked = false

            if definition.ruleType == "NO_COMBAT" then
                blocked = true
            elseif instanceof(victim, "IsoPlayer") and attacker and instanceof(attacker, "IsoPlayer") then
                if definition.combatRules and definition.combatRules.pvpAllowedInZone == false then
                    blocked = true
                elseif definition.combatRules and definition.combatRules.friendlyFireEnabled ~= true
                    and attackerParticipant and victimParticipant and attackerParticipant ~= victimParticipant
                then
                    -- Phase 2 team infrastructure: friendly fire is
                    -- disabled by default in team modes. No-op (both
                    -- GetPlayerTeam calls return nil) for any
                    -- definition without teams, so this never affects
                    -- FFA/non-team events.
                    local teamService = KIPN.Server.EventTeamService
                    local attackerTeam = teamService and teamService.GetPlayerTeam(definition, attackerParticipant)
                    local victimTeam = teamService and teamService.GetPlayerTeam(definition, victimParticipant)

                    if attackerTeam and victimTeam and attackerTeam == victimTeam then
                        blocked = true
                    end
                end
            end

            if blocked then
                local ok = pcall(function() victim:setAvoidDamage(true) end)

                if not ok then
                    logError("Failed to block in-zone hit.")
                end
            elseif definition.mode == "CHASE" then
                -- Phase 8: last-hit kill attribution for the Chase
                -- mode engine, using the same proven technique as
                -- KIPN_LeaderboardService.lua's PvP kill tracking
                -- (Events.OnWeaponHitCharacter has no PZ "on kill"
                -- counterpart) -- see KIPN_EventChaseService.lua's
                -- header. Only recorded for hits that actually landed
                -- (not blocked above).
                local recordOk, recordErr = pcall(
                    KIPN.Server.EventChaseService.RecordHit, runtime, attackerParticipant, victimParticipant
                )
                if not recordOk then
                    logError("Chase hit recording failed: " .. tostring(recordErr))
                end
            end
        end
    end
end

------------------------------------------------------------
-- LEAVE-ZONE RULE ENFORCEMENT
------------------------------------------------------------

local function enforceLeaveZoneRule(runtime, definition, zone)
    if runtime.scopeType ~= KIPN.Shared.EventScopeTypes.ZONE or not zone then
        return
    end

    if definition.combatRules.allowLeaveZone then
        return
    end

    local entryPoint = getZoneEntryPoint(runtime.zoneId)

    if not entryPoint then
        return
    end

    local online = getOnlinePlayers()

    if not online then
        return
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()

        local participant = username and runtime.participants[username]
        if participant and not participant.extracted then
            local x, y, z = getCharacterSquarePosition(p)

            if x then
                local inZone = KIPN.Server.WorldRegistry.IsPositionInZone(x, y, z, zone)

                if not inZone then
                    local ok = pcall(KIPN.Server.EventMoveService.Player, p, entryPoint)

                    if ok then
                        appendLog(runtime, username .. " tried to leave the zone and was returned.")
                    end
                end

                runtime.participants[username].lastKnownInZone = inZone
            end
        end
    end
end

------------------------------------------------------------
-- TICK LOOP
------------------------------------------------------------

local lastTickMs = 0

-- Phase 4: explicitly credits every current participant as a winner
-- for the two "legacy" WIN paths that have never distinguished
-- individual winners (a plain survive-the-duration timer, and
-- HORDE_SURVIVAL's co-op win conditions) -- both are genuinely
-- whole-roster-wins-together outcomes, so this is the correct,
-- intentional call, made visibly here rather than left to
-- KIPN_EventRewardService.lua's old implicit "winners empty ->
-- reward everyone" fallback (removed this phase). Round-based
-- completion is NOT included here -- KIPN_EventScenarioRuntimeRegistry.lua's
-- completeRound()/completeObjective() already populate runtime.winners
-- explicitly when a specific username is credited, and an
-- uncredited round/objective completion is correctly left with no
-- winners (an intentional no-winner result) rather than guessed at.
local function creditAllParticipantsAsWinners(runtime)
    runtime.winners = runtime.winners or {}
    for username, participant in pairs(runtime.participants or {}) do
        runtime.winners[username] = participant or true
    end
end

-- Equivalent to `next(t) ~= nil`, but avoids calling the raw `next`
-- builtin directly -- on this Kahlua build, calling `next()` reliably
-- throws "Object tried to call nil" (see KIPN_WorldRegistry.lua's
-- tableHasEntries() for the same workaround, originally found
-- blocking zone drawing; this was the same crash hitting
-- evaluateEndConditions() below for any event whose story completed
-- at least one objective). `pairs()` iteration is unaffected.
local function tableHasEntries(t)
    for _ in pairs(t) do
        return true
    end

    return false
end

local function evaluateEndConditions(definitionId, runtime, definition)
    local timerService = KIPN.Server.EventTimerService

    if timerService.HasRoundTimerExpired(runtime) then
        -- Round timer expiry always means "complete the current
        -- round" -- it does not end the event by itself (the final-
        -- round check below still applies this same tick if this was
        -- the last round) and it does not invent a winner (that's a
        -- mode-specific concern, not this generic evaluator's) except
        -- for the one small mode-gated call below.
        local completionParams = {}

        -- Phase 7: KOTH determines its round winner from accumulated
        -- hill-control time (see KIPN_EventKOTHService.lua's
        -- DetermineRoundWinner()) so a timer-driven round completion
        -- credits a real team instead of leaving winnerTeamId nil.
        if definition.mode == "KING_OF_THE_HILL" then
            local resolveOk, winnerTeamId = pcall(
                KIPN.Server.EventKOTHService.DetermineRoundWinner, runtime, definition
            )
            if resolveOk then
                completionParams.winnerTeamId = winnerTeamId
            else
                logError("KOTH round-winner resolution failed for " .. tostring(definitionId) .. ": " .. tostring(winnerTeamId))
            end
        end

        -- Phase 8: reaching this point means the round timer expired
        -- while the round was still ACTIVE (HasRoundTimerExpired()
        -- requires that), which for Chase can only mean the target
        -- was never killed this round -- see
        -- KIPN_EventChaseService.lua's OnTargetSurvived(). The
        -- "target was killed" path is handled separately by
        -- KIPN_EventScenarioRuntimeRegistry.lua's OnPlayerDeath(),
        -- which completes the round itself (making it no longer
        -- ACTIVE, so this branch and that one can never both fire for
        -- the same round).
        if definition.mode == "CHASE" then
            local resolveOk, winnerUsername = pcall(
                KIPN.Server.EventChaseService.OnTargetSurvived, runtime, definition
            )
            if resolveOk then
                completionParams.winnerUsername = winnerUsername
            else
                logError("Chase target-survived handling failed for " .. tostring(definitionId) .. ": " .. tostring(winnerUsername))
            end
        end

        local dispatchOk, dispatchResult = KIPN.Server.EventScenarioRuntimeRegistry.Dispatch(
            "scenario_complete_round", runtime, definition, completionParams
        )

        if not dispatchOk then
            logError("Round timer expiry dispatch failed for " .. tostring(definitionId) .. ": " .. tostring(dispatchResult))
        end
    end

    if timerService.HasEventTimerExpired(runtime) then
        if timerService.GetEventExpiryBehavior(definition) == KIPN.Shared.EventTimerExpiryBehaviors.FAIL then
            stopEvent(nil, definitionId, "TIMER_EXPIRED", "FAIL")
        else
            -- Phase 10: Survivor Run credits only participants
            -- confirmed still alive when its duration expires, not
            -- everyone who ever joined -- see
            -- KIPN_EventSurvivorRunService.lua's ResolveSurvivors().
            -- Every other mode/definition keeps the existing
            -- "everyone wins" convention for this path.
            local outcome = "WIN"
            if definition.mode == "SURVIVOR_RUN" then
                local resolveOk, resolveErr = pcall(
                    KIPN.Server.EventSurvivorRunService.ResolveSurvivors, runtime, definition
                )
                if not resolveOk then
                    logError("Survivor Run survivor resolution failed for " .. tostring(definitionId) .. ": " .. tostring(resolveErr))
                    creditAllParticipantsAsWinners(runtime)
                end
            elseif definition.mode == "EXTRACTION" then
                -- Only those who reached the evac win; nobody out is a loss.
                local resolveOk, resolved = pcall(KIPN.Server.EventExtractionService.ResolveOnTimer, runtime, definition)
                outcome = resolveOk and resolved or "FAIL"
            elseif definition.mode == "CAPTURE" or definition.mode == "KING_OF_THE_HILL" or definition.mode == "CHASE" then
                -- A round mode that runs out of event time is decided by
                -- its score so far, never by "everyone who joined".
                local services = {
                    CAPTURE = KIPN.Server.EventCaptureService,
                    KING_OF_THE_HILL = KIPN.Server.EventKOTHService,
                    CHASE = KIPN.Server.EventChaseService,
                }
                local resolveOk, resolveErr = pcall(services[definition.mode].ResolveOverallWinner, runtime, definition)
                if not resolveOk then logError("Overall-winner resolution failed: " .. tostring(resolveErr)) end
            else
                creditAllParticipantsAsWinners(runtime)
            end
            stopEvent(nil, definitionId, "TIMER_EXPIRED", outcome)
        end

        return true
    end

    -- Mode-specific endings that do not wait for the clock: everyone
    -- extracted or down, every Survivor Run participant fallen, every
    -- Olympic heat run.
    if definition.mode == "EXTRACTION" then
        local checkOk, ending = pcall(KIPN.Server.EventExtractionService.CheckEnd, runtime, definition)
        if checkOk and ending then
            stopEvent(nil, definitionId, "EXTRACTION_RESOLVED", ending)
            return true
        end
    end
    if definition.mode == "SURVIVOR_RUN" and definition.survivorConfig and definition.survivorConfig.lastStanding then
        local checkOk, lastOne = pcall(KIPN.Server.EventSurvivorRunService.LastStanding, runtime)
        if checkOk and lastOne then
            runtime.winners = { [lastOne] = runtime.participants[lastOne] or true }
            stopEvent(nil, definitionId, "LAST_STANDING", "WIN")
            return true
        end
    end
    if definition.mode == "SURVIVOR_RUN" then
        local checkOk, allDown = pcall(KIPN.Server.EventSurvivorRunService.AllDown, runtime)
        if checkOk and allDown then
            stopEvent(nil, definitionId, "ALL_SURVIVORS_DOWN", "FAIL")
            return true
        end
    end
    if definition.mode == "OLYMPICS" then
        local checkOk, finished = pcall(KIPN.Server.EventOlympicsService.CheckEnd, runtime, definition)
        if checkOk and finished then
            stopEvent(nil, definitionId, "ALL_HEATS_RUN", "WIN")
            return true
        end
    end

    if runtime.objectiveState and runtime.objectiveState.complete == true then
        stopEvent(nil, definitionId, "SCENARIO_OBJECTIVE_COMPLETE", "WIN")
        return true
    end

    -- Phase 9: the Phase 3 ordered objectives/trigger framework (see
    -- KIPN_EventTriggerService.lua) can fully define a scenario's win
    -- path on its own -- e.g. Extraction/Prison Break, where a
    -- PROXIMITY trigger at the retrieve hotspot completes the first
    -- objective and a second PROXIMITY trigger at an EXTRACTION_POINT
    -- hotspot completes the last one -- but completing every authored
    -- objective previously only ever reached
    -- KIPN_EventTriggerService.lua's CompleteObjective() "no further
    -- objectives (story finished)" branch, which sets
    -- activeObjectiveId to nil and does nothing else. Nothing ended
    -- the event. This closes that gap generically, for any definition
    -- that authors objectives (not just Extraction-mode ones) --
    -- matching the same "everyone wins" convention already used by
    -- the TIMER_EXPIRED/WIN_CONDITION branches below, since ordered
    -- objectives have no per-participant/per-team credit of their
    -- own to draw on the way Capture/KOTH/Chase's own round tallies
    -- do. activeObjectiveId's initial value is also nil (before
    -- anything has ever completed) -- checking completedObjectiveIds
    -- is non-empty is what distinguishes "story finished" from
    -- "definition has no authored objectives at all" or "story never
    -- started."
    if runtime.storyState
        and runtime.storyState.activeObjectiveId == nil
        and tableHasEntries(runtime.storyState.completedObjectiveIds or {})
    then
        creditAllParticipantsAsWinners(runtime)
        stopEvent(nil, definitionId, "ALL_OBJECTIVES_COMPLETE", "WIN")
        return true
    end

    if runtime.round
        and runtime.round.state == "COMPLETE"
        and runtime.round.current >= runtime.round.maximum
    then
        -- Phase 6: Capture determines its OVERALL winner from
        -- cumulative round wins (team or individual), which may
        -- differ from whoever won any single round -- this replaces
        -- whatever runtime.winners accumulated round-by-round with
        -- the actual tallied result before the WIN is declared and
        -- KIPN_EventRewardService.lua reads it.
        if definition.mode == "CAPTURE" then
            local resolveOk, resolveErr = pcall(KIPN.Server.EventCaptureService.ResolveOverallWinner, runtime, definition)
            if not resolveOk then
                logError("Capture overall-winner resolution failed for " .. tostring(definitionId) .. ": " .. tostring(resolveErr))
            end
        end

        -- Phase 7: KOTH's OVERALL winner is the team with the most
        -- individual round wins (tallied by
        -- KIPN_EventKOTHService.lua's DetermineRoundWinner() above,
        -- resolved here the same way Capture resolves its own).
        if definition.mode == "KING_OF_THE_HILL" then
            local resolveOk, resolveErr = pcall(KIPN.Server.EventKOTHService.ResolveOverallWinner, runtime, definition)
            if not resolveOk then
                logError("KOTH overall-winner resolution failed for " .. tostring(definitionId) .. ": " .. tostring(resolveErr))
            end
        end

        -- Phase 8: Chase's OVERALL winner is whoever (target or
        -- hunter) has the most individual round wins, tallied by
        -- KIPN_EventChaseService.lua's OnTargetKilled()/
        -- OnTargetSurvived() above.
        if definition.mode == "CHASE" then
            local resolveOk, resolveErr = pcall(KIPN.Server.EventChaseService.ResolveOverallWinner, runtime, definition)
            if not resolveOk then
                logError("Chase overall-winner resolution failed for " .. tostring(definitionId) .. ": " .. tostring(resolveErr))
            end
        end

        stopEvent(nil, definitionId, "FINAL_ROUND_COMPLETE", "WIN")
        return true
    end

    local wonOk, wonId = KIPN.Server.EventObjectiveRegistry.EvaluateWinConditions(
        runtime.objectiveType, definition.winConditions, runtime, definition
    )

    if wonOk then
        creditAllParticipantsAsWinners(runtime)
        stopEvent(nil, definitionId, "WIN_CONDITION:" .. tostring(wonId), "WIN")
        return true
    end

    local failedOk, failedId = KIPN.Server.EventObjectiveRegistry.EvaluateFailConditions(
        runtime.objectiveType, definition.failConditions, runtime, definition
    )

    if failedOk then
        stopEvent(nil, definitionId, "FAIL_CONDITION:" .. tostring(failedId), "FAIL")
        return true
    end

    return false
end

local function onTick()
    if not getTimestampMs then
        return
    end

    local now = getTimestampMs()

    if now - lastTickMs < RUNTIME_TICK_INTERVAL_MS then
        return
    end

    lastTickMs = now

    for definitionId, runtime in pairs(EventRuntimeService.ActiveRuntimes) do
        local definition = KIPN.Server.EventScenarioService.GetDefinition(definitionId)
        local zone = definition and runtime.zoneId and KIPN.Server.WorldRegistry.GetZone(runtime.zoneId) or nil
        local zoneRequired = runtime.scopeType == KIPN.Shared.EventScopeTypes.ZONE
        local zoneLost = zoneRequired and (not zone or zone.active == false)

        if not definition or zoneLost then
            stopEvent(nil, definitionId, "ZONE_OR_DEFINITION_LOST", "LOST")
        else
            local ok, ended = pcall(evaluateEndConditions, definitionId, runtime, definition)

            if not ok then
                logError("End condition evaluation failed for " .. tostring(definitionId) .. ": " .. tostring(ended))
            elseif not ended then
                pcall(enforceLeaveZoneRule, runtime, definition, zone)

                local objectiveEntry = KIPN.Server.EventObjectiveRegistry.Get(runtime.objectiveType)

                if objectiveEntry and type(objectiveEntry.onTick) == "function" then
                    local tickOk, tickErr = pcall(objectiveEntry.onTick, runtime, definition)

                    if not tickOk then
                        logError("Objective onTick failed for " .. tostring(definitionId) .. ": " .. tostring(tickErr))
                    end
                end

                -- Phase 3: proximity/timed trigger evaluation. Reuses
                -- this same 5-second cadence rather than a second
                -- competing tick loop.
                local triggerTickOk, triggerTickErr = pcall(KIPN.Server.EventTriggerService.Tick, runtime, definition)

                if not triggerTickOk then
                    logError("Trigger tick failed for " .. tostring(definitionId) .. ": " .. tostring(triggerTickErr))
                end

                local narrativeTickOk, narrativeTickErr = pcall(KIPN.Server.EventTriggerService.TickNarrativeHotspots, runtime, definition)

                if not narrativeTickOk then
                    logError("Narrative hotspot tick failed for " .. tostring(definitionId) .. ": " .. tostring(narrativeTickErr))
                end

                if definition.mode == "CAPTURE" then
                    local captureTickOk, captureTickErr = pcall(KIPN.Server.EventCaptureService.Tick, runtime, definition)

                    if not captureTickOk then
                        logError("Capture tick failed for " .. tostring(definitionId) .. ": " .. tostring(captureTickErr))
                    end
                end

                if definition.mode == "KING_OF_THE_HILL" then
                    local kothTickOk, kothTickErr = pcall(KIPN.Server.EventKOTHService.Tick, runtime, definition)

                    if not kothTickOk then
                        logError("KOTH tick failed for " .. tostring(definitionId) .. ": " .. tostring(kothTickErr))
                    end
                end

                if definition.mode == "EXTRACTION" then
                    local extractionTickOk, extractionTickErr = pcall(KIPN.Server.EventExtractionService.Tick, runtime, definition)

                    if not extractionTickOk then
                        logError("Extraction tick failed for " .. tostring(definitionId) .. ": " .. tostring(extractionTickErr))
                    end
                end

                local threatTickOk, threatTickErr = pcall(KIPN.Server.EventThreatService.Tick, runtime, definition)

                if not threatTickOk then
                    logError("Threat tick failed for " .. tostring(definitionId) .. ": " .. tostring(threatTickErr))
                end

                -- Automatic rounds, announcements and every
                -- participant's HUD (KIPN_EventGameLoopService.lua).
                local loopOk, loopErr = pcall(KIPN.Server.EventGameLoopService.Tick, runtime, definition)

                if not loopOk then
                    logError("Game loop tick failed for " .. tostring(definitionId) .. ": " .. tostring(loopErr))
                end
            end
        end
    end
end

local function onPlayerDeath(player)
    local ok, username = pcall(function() return player and player:getUsername() end)
    if ok and username then
        KIPN.Server.EventScenarioRuntimeRegistry.OnPlayerDeath(username)

        -- Phase 10: Survivor Run records every participant death so
        -- KIPN_EventSurvivorRunService.lua's ResolveSurvivors() can
        -- credit only whoever is still alive when the event's
        -- duration expires -- same per-runtime loop shape as
        -- KIPN_EventScenarioRuntimeRegistry.lua's own OnPlayerDeath()
        -- above, just gated on mode instead of an objectiveState
        -- field.
        for _, runtime in pairs(EventRuntimeService.ActiveRuntimes) do
            local definition = KIPN.Server.EventScenarioService.GetDefinition(runtime.eventDefinitionId)

            -- Every mode: a participant who dies is out of this event
            -- (their respawned character has the same username, so
            -- "alive now" alone cannot tell).
            if runtime.participants and runtime.participants[username] and not (runtime.deaths and runtime.deaths[username]) then
                runtime.deaths = runtime.deaths or {}
                runtime.deaths[username] = true
                if definition then
                    local remaining = 0
                    for name in pairs(runtime.participants) do
                        if not runtime.deaths[name] then remaining = remaining + 1 end
                    end
                    pcall(KIPN.Server.EventGameLoopService.Announce, runtime,
                        username .. " has fallen." .. (definition.mode == "SURVIVOR_RUN" and (" " .. remaining .. " left standing.") or ""),
                        { 1.0, 0.42, 0.42 })
                end
            end

            if definition and definition.mode == "SURVIVOR_RUN" then
                local survivorOk, survivorErr = pcall(
                    KIPN.Server.EventSurvivorRunService.OnParticipantDeath, runtime, definition, username
                )
                if not survivorOk then
                    logError("Survivor Run death recording failed: " .. tostring(survivorErr))
                end
            end
        end

        log("Processed participant death: " .. tostring(username))
    end
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function EventRuntimeService.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_START, handleStart)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_STOP, handleStop)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_GET_STATUS, handleGetStatus)
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_RUNTIME_CONTROL, handleRuntimeControl)

    Events.OnWeaponHitCharacter.Add(onWeaponHitCharacter)

    lastTickMs = getTimestampMs and getTimestampMs() or 0

    Events.OnTick.Add(onTick)

    if Events.OnPlayerDeath then
        Events.OnPlayerDeath.Add(onPlayerDeath)
    end

    return true
end

print("[KIPN] Event Runtime Service loaded")
