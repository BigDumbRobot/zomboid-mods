-- KIPN_EventDirector.lua
--
-- The tiered command bus for live Event Scenarios control. Every
-- button in the floating KIPN_EventDirectorPanel.lua, and (later)
-- any scripted/scheduled event code, funnels through exactly one
-- entry point:
--
--     KIPN.Server.EventDirector.ExecuteCommand(player, eventId, command, parameters)
--
-- This file owns NOTHING about how an event actually starts/stops/
-- ticks/spawns -- that all still lives in KIPN_EventRuntimeService.lua
-- (orchestration/tick loop/PvP listener) and KIPN_ZombieDirector.lua
-- (Horde Survival's concrete spawn/difficulty/slider behavior via
-- KIPN_EventObjectiveRegistry.lua). This file is purely: look up a
-- command, authorize the caller's tier against it, resolve the
-- target runtime/definition, and delegate.
--
-- TIER AUTHORIZATION lives in KIPN_Permissions.lua
-- (Permissions.AuthorizeEventTier/GetEventTierCategories), not here
-- -- see that file's comment for why (KIPN_EventRuntimeService.lua's
-- own EVENT_START/EVENT_STOP/EVENT_GET_STATUS/EVENT_RUNTIME_CONTROL
-- handlers need the identical check, and putting it there avoids a
-- circular require between this file and that one).
--
-- TRANSPORT: registers exactly one new PZ command,
-- EVENT_DIRECTOR_EXECUTE, responding with EVENT_DIRECTOR_RESULT.
-- This is separate from the pre-existing EVENT_START/EVENT_STOP/
-- EVENT_GET_STATUS/EVENT_RUNTIME_CONTROL commands, which remain the
-- transport for the DRAFT-authoring KIPN_EventScenarioAdminUI.lua
-- panel (now also tier-authorized, but through its own existing
-- handlers, not through this file).

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_WorldRegistry"
require "KIPN_AdminService"
require "KIPN_Permissions"
require "KIPN_EventObjectiveRegistry"
require "KIPN_EventScenarioService"
require "KIPN_EventRuntimeService"
require "KIPN_EventHotspotService"
require "KIPN_ZombieDirector"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.EventDirector = KIPN.Server.EventDirector or {}

local EventDirector = KIPN.Server.EventDirector

local function log(message)
    print("[KIPN EVENT DIRECTOR] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT DIRECTOR] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- ZONE ENTRY POINT
--
-- Same small helper duplicated in KIPN_EventRuntimeService.lua and
-- KIPN_ZombieDirector.lua -- WorldRegistry zones store only a
-- rectangle, so every file that needs a reference point computes it
-- the same way rather than sharing a cross-file dependency for six
-- lines of math.
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

local function getEventEntryPoint(runtime, definition)
    local hotspotService = KIPN.Server.EventHotspotService
    if hotspotService and definition then
        local hotspots = hotspotService.GetHotspots(definition)
        local preferredId = runtime and runtime.round and runtime.round.hotspotId

        if preferredId then
            for _, hotspot in ipairs(hotspots) do
                if tostring(hotspot.id) == tostring(preferredId) then
                    return hotspotService.GetCenter(hotspot)
                end
            end
        end

        if #hotspots > 0 then return hotspotService.GetCenter(hotspots[1]) end
    end

    return getZoneEntryPoint(runtime and runtime.zoneId)
end

------------------------------------------------------------
-- PARTICIPANT BROADCAST
--
-- Same transport as KIPN_EventRuntimeService.lua's private
-- broadcastNarrative -- reimplemented locally (not exported from
-- that file) since it's a short, self-contained loop.
------------------------------------------------------------

local function broadcastToParticipants(runtime, text)
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
-- COMMAND HANDLERS
--
-- Each handler: function(player, eventId, runtime, definition, params)
-- -> ok, resultOrReason. Called via pcall by ExecuteCommand below --
-- a broken handler must never crash the caller.
------------------------------------------------------------

local function handleGetStatus(player, eventId, runtime, definition, params)
    -- No-op: ExecuteCommand/handleExecute already attach a fresh
    -- status snapshot to every response, GET_STATUS included, the
    -- same way EVENT_CONTROL_RESULT already does for the pre-existing
    -- runtime-control command.
    return true
end

local function handleStartEvent(player, eventId, runtime, definition, params)
    if not definition then
        return false, "DEFINITION_NOT_FOUND"
    end

    return KIPN.Server.EventRuntimeService.StartEvent(player, definition)
end

local function handleStopEvent(player, eventId, runtime, definition, params)
    return KIPN.Server.EventRuntimeService.StopEvent(player, eventId, "MANUAL_STOP", "MANUAL")
end

local function handleStopEventAsWin(player, eventId, runtime, definition, params)
    local winnerUsername = params and params.winnerUsername
    if winnerUsername and runtime.participants[winnerUsername] then
        runtime.winners = runtime.winners or {}
        runtime.winners[winnerUsername] = runtime.participants[winnerUsername]
    end
    return KIPN.Server.EventRuntimeService.StopEvent(player, eventId, "DIRECTOR_WIN", "WIN")
end

local function handleAddTime(player, eventId, runtime, definition, params)
    if not runtime.endsAtMs then
        return false, "NO_TIMER"
    end

    local extraSeconds = tonumber(params.seconds) or 120

    runtime.endsAtMs = runtime.endsAtMs + (extraSeconds * 1000)

    log("Added " .. tostring(extraSeconds) .. "s to event " .. tostring(eventId))

    return true
end

local function handleAnnounceMessage(player, eventId, runtime, definition, params)
    local text = params.text

    if type(text) ~= "string" or text:match("^%s*$") then
        return false, "TEXT_REQUIRED"
    end

    broadcastToParticipants(runtime, text)

    return true
end

local function handleRevealHint(player, eventId, runtime, definition, params)
    local text = params.text

    if type(text) ~= "string" or text:match("^%s*$") then
        return false, "TEXT_REQUIRED"
    end

    broadcastToParticipants(runtime, "[HINT] " .. text)

    return true
end

-- Teleports the caller to the zone entry point and toggles
-- invisible/ghost mode, pcall-wrapped. BEST-EFFORT: setInvisible/
-- setGhostMode are common vanilla admin-tool calls but have no prior
-- precedent in this codebase, so this is flagged the same way other
-- less-common vanilla API usage is flagged elsewhere (e.g.
-- KIPN_EventRuntimeService.lua's environment.weatherPreset).
local function handleSpectateEnter(player, eventId, runtime, definition, params)
    local entryPoint = getEventEntryPoint(runtime, definition)

    if not entryPoint then
        return false, "EVENT_LOCATION_UNAVAILABLE"
    end

    local ok = pcall(function()
        KIPN.Server.EventMoveService.Player(player, entryPoint)

        if player.setInvisible then player:setInvisible(true) end
        if player.setGhostMode then player:setGhostMode(true) end
    end)

    if not ok then
        return false, "SPECTATE_FAILED"
    end

    return true
end

-- requiresRuntime = false (see registration below): a spectating
-- staff member must always be able to un-ghost themselves, even if
-- the event they were watching has since ended.
local function handleSpectateExit(player, eventId, runtime, definition, params)
    local ok = pcall(function()
        if player.setInvisible then player:setInvisible(false) end
        if player.setGhostMode then player:setGhostMode(false) end
    end)

    if not ok then
        return false, "SPECTATE_EXIT_FAILED"
    end

    return true
end

local function handleSetPvp(player, eventId, runtime, definition, params)
    if not definition then
        return false, "DEFINITION_NOT_FOUND"
    end

    definition.combatRules = definition.combatRules or {}
    definition.combatRules.pvpAllowedInZone = params.enabled == true

    KIPN.Server.Save()

    log("PvP set to " .. tostring(definition.combatRules.pvpAllowedInZone) .. " for event " .. tostring(eventId))

    return true
end

------------------------------------------------------------
-- TRIGGER ALARM (Phase 5: persistent, mode-independent Event
-- Director control -- previously "Trigger Alarm" was only reachable
-- as a Horde Survival objective-type control (KIPN_ZombieDirector.lua's
-- "alarm"), so it only ever appeared for events whose eventType
-- happened to be HORDE_SURVIVAL. Registering it here instead makes it
-- a genuine Director-tier command, available for every ACTIVE event
-- regardless of objective type/mode/zombie-director selection -- the
-- old Horde Survival control is untouched and still works too, so
-- nothing existing regresses.
--
-- params.mode: "ROUND_ZONE" (default) | "HOTSPOT" | "ALL_ALARM_ENABLED"
------------------------------------------------------------

local function handleTriggerAlarm(player, eventId, runtime, definition, params)
    if not definition then
        return false, "DEFINITION_NOT_FOUND"
    end

    local zombieDirector = KIPN.Server.ZombieDirector
    local hotspotService = KIPN.Server.EventHotspotService
    local mode = params.mode or "ROUND_ZONE"

    if mode == "HOTSPOT" then
        local hotspot = params.hotspotId and hotspotService.FindById(definition, params.hotspotId)

        if not hotspot then
            return false, "HOTSPOT_NOT_FOUND"
        end

        return zombieDirector.TriggerAlarm(runtime, definition, { origin = hotspotService.GetCenter(hotspot) })
    end

    if mode == "ALL_ALARM_ENABLED" then
        local hotspots = hotspotService.GetAlarmEnabledHotspots(definition)

        if #hotspots == 0 then
            return false, "NO_ALARM_ENABLED_HOTSPOTS"
        end

        local successCount = 0

        for _, hotspot in ipairs(hotspots) do
            local ok = zombieDirector.TriggerAlarm(runtime, definition, { origin = hotspotService.GetCenter(hotspot) })
            if ok then successCount = successCount + 1 end
        end

        if successCount == 0 then
            return false, "NO_VALID_ALARM_TARGETS"
        end

        log("Triggered " .. tostring(successCount) .. "/" .. tostring(#hotspots) .. " alarm-enabled hotspot(s) for event " .. tostring(eventId))

        return true
    end

    -- ROUND_ZONE (default): same resolution SPECTATE_ENTER already
    -- uses -- current round's hotspot, else any hotspot, else the
    -- linked Event Zone's entry point.
    return zombieDirector.TriggerAlarm(runtime, definition, { origin = getEventEntryPoint(runtime, definition) })
end

local function handleRuntimeControl(player, eventId, runtime, definition, params)
    return KIPN.Server.EventRuntimeService.RuntimeControl(player, eventId, params.controlId, params.params)
end

local function handleSetSlider(player, eventId, runtime, definition, params)
    return KIPN.Server.EventRuntimeService.SliderControl(player, eventId, params.sliderId, params.value)
end

------------------------------------------------------------
-- COMMAND REGISTRY
--
-- category: one of KIPN_Permissions.lua's EVENT_CATEGORY_TIERS keys
--           (VIEW/LIFECYCLE_BASIC/STAFF_TOOLS/GM_CONTROLS).
-- requiresRuntime: if true (the default), the command fails with
--           NOT_ACTIVE when there's no running event for eventId --
--           false for GET_STATUS (tolerates no active event at all),
--           START_EVENT (there is no runtime YET -- that's what this
--           call creates), and SPECTATE_EXIT (must always work).
------------------------------------------------------------

local COMMAND_REGISTRY = {
    GET_STATUS = { category = "VIEW", requiresRuntime = false, handler = handleGetStatus },
    START_EVENT = { category = "LIFECYCLE_BASIC", requiresRuntime = false, handler = handleStartEvent },
    STOP_EVENT = { category = "LIFECYCLE_BASIC", requiresRuntime = true, handler = handleStopEvent },
    END_EVENT = { category = "LIFECYCLE_BASIC", requiresRuntime = true, handler = handleStopEvent },
    END_EVENT_WIN = { category = "LIFECYCLE_BASIC", requiresRuntime = true, handler = handleStopEventAsWin },
    ADD_TIME = { category = "LIFECYCLE_BASIC", requiresRuntime = true, handler = handleAddTime },
    ANNOUNCE_MESSAGE = { category = "STAFF_TOOLS", requiresRuntime = true, handler = handleAnnounceMessage },
    REVEAL_HINT = { category = "STAFF_TOOLS", requiresRuntime = true, handler = handleRevealHint },
    SPECTATE_ENTER = { category = "STAFF_TOOLS", requiresRuntime = true, handler = handleSpectateEnter },
    SPECTATE_EXIT = { category = "STAFF_TOOLS", requiresRuntime = false, handler = handleSpectateExit },
    SET_PVP = { category = "GM_CONTROLS", requiresRuntime = true, handler = handleSetPvp },
    TRIGGER_ALARM = { category = "GM_CONTROLS", requiresRuntime = true, handler = handleTriggerAlarm },
    RUNTIME_CONTROL = { category = "GM_CONTROLS", requiresRuntime = true, handler = handleRuntimeControl },
    SET_SLIDER = { category = "GM_CONTROLS", requiresRuntime = true, handler = handleSetSlider },
}

------------------------------------------------------------
-- STATUS SNAPSHOT (Event Director flavor)
--
-- Wraps KIPN.Server.EventRuntimeService.GetStatusPayload with the
-- caller's resolved tier and allowedCategories, so the floating
-- panel can self-configure which sections to show. Handles the
-- "nothing is running" case explicitly rather than erroring.
------------------------------------------------------------

local function buildDirectorStatus(eventId, tier)
    local allowedCategories = KIPN.Server.Permissions.GetEventTierCategories(tier)

    if not eventId then
        return {
            status = "NO_ACTIVE_EVENT",
            tier = tier,
            allowedCategories = allowedCategories,
        }
    end

    local payload = KIPN.Server.EventRuntimeService.GetStatusPayload(eventId)

    payload.tier = tier
    payload.allowedCategories = allowedCategories

    return payload
end

------------------------------------------------------------
-- EXECUTE COMMAND
--
-- The one entry point. Zero dependency on the network layer -- it
-- can be called directly by scripted/scheduled event code later,
-- not only through the EVENT_DIRECTOR_EXECUTE network command below.
------------------------------------------------------------

function EventDirector.ExecuteCommand(player, eventId, command, parameters)
    parameters = parameters or {}

    local entry = COMMAND_REGISTRY[command]

    if not entry then
        return false, "UNKNOWN_COMMAND"
    end

    local authOk, tier = KIPN.Server.Permissions.AuthorizeEventTier(player, entry.category)

    if not authOk then
        KIPN.Server.AdminService.WriteAudit(
            player, "EVENT_DIRECTOR_DENIED", "eventDefinition", eventId,
            { command = command, tier = tier }
        )

        return false, "PERMISSION_DENIED"
    end

    local resolvedEventId = eventId

    if not resolvedEventId and command == "GET_STATUS" then
        resolvedEventId = KIPN.Server.EventRuntimeService.GetActiveDefinitionId()
    end

    if not resolvedEventId then
        if command == "GET_STATUS" then
            return true
        end

        return false, "EVENT_ID_REQUIRED"
    end

    local runtime = KIPN.Server.EventRuntimeService.ActiveRuntimes[resolvedEventId]
    local definition = KIPN.Server.EventScenarioService.GetDefinition(resolvedEventId)

    if entry.requiresRuntime and not runtime then
        return false, "NOT_ACTIVE"
    end

    local callOk, handlerOk, handlerResultOrReason = pcall(entry.handler, player, resolvedEventId, runtime, definition, parameters)

    if not callOk then
        logError("Command handler failed: command=" .. tostring(command) .. " error=" .. tostring(handlerOk))
        return false, "HANDLER_ERROR"
    end

    -- GET_STATUS is a read-only query, polled every few seconds by
    -- an open panel -- not audit-logged, matching the pre-existing
    -- EVENT_GET_STATUS handler in KIPN_EventRuntimeService.lua,
    -- which never called WriteAudit either. Every other command is
    -- a real mutating action and gets logged.
    if command ~= "GET_STATUS" then
        KIPN.Server.AdminService.WriteAudit(
            player, "EVENT_DIRECTOR_COMMAND", "eventDefinition", resolvedEventId,
            { command = command, tier = tier, success = handlerOk == true }
        )
    end

    return handlerOk, handlerResultOrReason
end

------------------------------------------------------------
-- NETWORK TRANSPORT
------------------------------------------------------------

local function handleExecute(player, args)
    args = args or {}

    local ok, resultOrReason = EventDirector.ExecuteCommand(player, args.eventId, args.command, args.parameters)

    -- Always snapshot the currently active runtime after the command. In
    -- particular, a successful END must return NO_ACTIVE_EVENT instead of a
    -- stale COMPLETE definition that still renders live buttons.
    local statusEventId = KIPN.Server.EventRuntimeService.GetActiveDefinitionId()
    local tier = KIPN.Server.Permissions.ResolveAccessLevel(player)

    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_DIRECTOR_RESULT, {
        success = ok,
        reason = (not ok) and resultOrReason or nil,
        status = buildDirectorStatus(statusEventId, tier),
    })

    return true
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

function EventDirector.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_DIRECTOR_EXECUTE, handleExecute)

    return true
end

print("[KIPN] Event Director loaded")
