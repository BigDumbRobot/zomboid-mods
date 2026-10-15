-- KIPN_EventParticipationService.lua
--
-- Self-service player opt-in for Event Scenarios. Every other
-- roster/teleport action in the Event Scenarios system
-- (KIPN_EventScenarioService.lua's EVENT_SET_PARTICIPANTS/
-- EVENT_TELEPORT_PARTICIPANTS) is admin-driven; this file is the one
-- place a player can add themselves to a running event's roster and
-- get teleported in, triggered by an on-screen accept/deny prompt
-- broadcast at event start and at the start of every King of the
-- Hill round.
--
-- Deliberately does NOT require KIPN_EventRuntimeService.lua or
-- KIPN_EventScenarioRuntimeRegistry.lua -- both of those files
-- require this one (to fire the broadcast at event/round start), so
-- requiring them back would create a load cycle. Runtime state is
-- reached instead via a guarded lookup into
-- KIPN.Server.EventRuntimeService.ActiveRuntimes, the same pattern
-- KIPN_EventScenarioRuntimeRegistry.lua's Registry.OnPlayerDeath()
-- already uses.
--
-- Intentionally bypasses KIPN_EventScenarioService.lua's
-- ROSTER_LOCKED_WHILE_ACTIVE rule: that rule exists to stop an admin
-- from editing the roster out from under a live event, but
-- self-service accept is expected to work precisely while ACTIVE,
-- since that's when King of the Hill rounds happen. This is a
-- deliberate second write path into definition.participants, not an
-- oversight -- do not "fix" it by routing this through
-- handleSetParticipants's gate.
--
-- Declines are not persisted anywhere: a dismissed prompt is a
-- purely client-local UI action (see
-- client/KIPN_EventParticipationPrompt.lua). A player who declines
-- one round's invite is simply re-prompted at the next one.
--
-- No WriteAudit call here, matching the only other self-service
-- command in the mod (RELEASE_CLAIM, KIPN_ClaimService.lua) -- Admin
-- Service audit entries are for admin actions, and WriteAudit
-- hard-codes category = "ADMIN".

if isClient() then return end

require "KIPN_Shared"
require "KIPN_EventMoveService"
require "KIPN_Server"
require "KIPN_EventScenarioService"
require "KIPN_EventModeRegistry"
require "KIPN_EventHotspotService"
require "KIPN_WorldRegistry"
require "KIPN_EventTeamService"
require "KIPN_EventEscrowService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventParticipationService = KIPN.Server.EventParticipationService or {}

local ParticipationService = KIPN.Server.EventParticipationService

local function log(message)
    print("[KIPN EVENT PARTICIPATION] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT PARTICIPATION] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- INVITE BROADCAST
------------------------------------------------------------

local function getEligibleOnlinePlayers(definition)
    local eligible = {}
    local online = getOnlinePlayers()

    if not online then
        return eligible
    end

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()

        if username and not definition.participants[username] then
            eligible[#eligible + 1] = p
        end
    end

    return eligible
end

local function broadcastInvite(definition, kind, roundNumber, promptText)
    local players = getEligibleOnlinePlayers(definition)

    for _, p in ipairs(players) do
        KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_PARTICIPATION_INVITE, {
            definitionId = definition.id,
            eventName = definition.name,
            mode = definition.mode,
            countries = definition.mode == "OLYMPICS" and ParticipationService.OLYMPIC_COUNTRIES or nil,
            kind = kind,
            roundNumber = roundNumber,
            promptText = promptText,
        })
    end

    log("broadcastInvite(" .. tostring(kind) .. ") -> " .. tostring(#players) .. " eligible player(s)")
end

-- Called from KIPN_EventRuntimeService.lua's startEvent(), right
-- after the existing narrative broadcast.
function ParticipationService.BroadcastEventStartInvite(runtime, definition)
    if not definition then return end

    local promptText = (definition.narrative and definition.narrative.briefing ~= "" and definition.narrative.briefing)
        or ("An event has started: " .. tostring(definition.name) .. ". Join now?")

    broadcastInvite(definition, "EVENT_START", nil, promptText)
end

-- Called from KIPN_EventScenarioRuntimeRegistry.lua's startRound(),
-- gated to HOLD_AREA (King of the Hill) definitions only.
function ParticipationService.BroadcastRoundInvite(runtime, definition, roundNumber)
    if not definition then return end

    local promptText = "Round " .. tostring(roundNumber) .. " of " .. tostring(definition.name) .. " has started. Join now?"

    broadcastInvite(definition, "ROUND_START", roundNumber, promptText)
end

------------------------------------------------------------
-- ENTRY POINT RESOLUTION
--
-- 1. Designated start hotspot (PLAYER_SPAWN, falling back to
--    TEAM_SPAWN) -- fixed center point, same as the admin
--    teleport-participants button's preference order.
-- 2. No start hotspot: the current King of the Hill round's hill,
--    randomized -- distinct players landing on different tiles
--    instead of stacked on one point.
-- 3. No active round: the event's zone, randomized.
-- 4. No zone either: any other active hotspot, randomized -- last
--    resort for HOTSPOTS-scope definitions with no spawn/round
--    hotspot.
-- 5. Nothing resolves: nil (caller responds
--    EVENT_DESTINATION_UNAVAILABLE).
------------------------------------------------------------

local function resolveEntryPoint(definition, runtime)
    local hotspotService = KIPN.Server.EventHotspotService

    local startHotspots = hotspotService.GetHotspots(definition, KIPN.Shared.EventHotspotTypes.PLAYER_SPAWN)
    if #startHotspots == 0 then
        startHotspots = hotspotService.GetHotspots(definition, KIPN.Shared.EventHotspotTypes.TEAM_SPAWN)
    end
    -- The Olympics: athletes gather at the start line.
    if #startHotspots == 0 and definition.mode == "OLYMPICS" then
        startHotspots = hotspotService.GetHotspots(definition, "OLYMPIC_START")
    end
    if #startHotspots > 0 then
        return hotspotService.GetCenter(startHotspots[1])
    end

    if definition.zoneId then
        local zone = KIPN.Server.WorldRegistry.GetZone(definition.zoneId)
        if zone and zone.active ~= false and zone.geometry then
            local point = hotspotService.GetRandomPointInGeometry(zone.geometry)
            if point then return point end
        end
    end

    -- No spawn point and no zone: the middle of the event's hotspots,
    -- stepped outward until it is clear of every one of them. Landing
    -- a joiner on a delivery point, hill or extraction point would
    -- hand them the objective for free.
    local anyHotspots = hotspotService.GetHotspots(definition)
    if #anyHotspots > 0 then
        local sumX, sumY, count = 0, 0, 0
        for _, hotspot in ipairs(anyHotspots) do
            local c = hotspotService.GetCenter(hotspot)
            if c then sumX, sumY, count = sumX + c.x, sumY + c.y, count + 1 end
        end
        if count > 0 then
            local base = { x = math.floor(sumX / count), y = math.floor(sumY / count), z = anyHotspots[1].geometry and anyHotspots[1].geometry.z1 or 0 }
            -- Clear of every hotspot, and far enough from a Zombie Ambush
            -- that arriving does not wake it (it wakes within 8 tiles).
            local function clear(point)
                for _, hotspot in ipairs(anyHotspots) do
                    if hotspotService.IsPositionInHotspot(point.x, point.y, point.z, hotspot) then return false end
                    if hotspot.type == "ZOMBIE_AMBUSH" then
                        local c = hotspotService.GetCenter(hotspot)
                        if c and (c.x - point.x) ^ 2 + (c.y - point.y) ^ 2 < 100 then return false end
                    end
                end
                return true
            end
            for step = 0, 6 do
                for _, direction in ipairs({ { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } }) do
                    local point = { x = base.x + direction[1] * step * 8, y = base.y + direction[2] * step * 8, z = base.z }
                    if clear(point) then return point end
                end
            end
            return base
        end
    end

    return nil
end

------------------------------------------------------------
-- TELEPORT
--
-- Same pcall + vehicle-detach + setX/Y/Z + setLx/Ly/Lz idiom as
-- KIPN_EventScenarioService.lua's handleTeleportParticipants.
------------------------------------------------------------

-- The client moves itself in multiplayer; see KIPN_EventMoveService.lua.
local function teleportPlayer(p, point)
    return pcall(KIPN.Server.EventMoveService.Player, p, point)
end

------------------------------------------------------------
-- RETURN-TO-SAFE-POSITION (Phase 2 of the Event Scenarios
-- architecture rewrite)
--
-- Persisted independently of the Event Definition -- same rationale
-- as KIPN_EventEscrowService.lua's escrow records -- so a definition
-- delete/reset can never strand a player away from where they were
-- before joining. Captured exactly once per event (a second
-- King of the Hill round invite accepted mid-event must NOT overwrite
-- the original pre-event position with an in-zone one), restored at
-- normal event end/cancellation or at the participant's next safe
-- (alive, and the owning event instance is no longer active)
-- lifecycle point.
------------------------------------------------------------

local function getReturnPositionCollection()
    if not KIPN.Server.GetData then
        logError("KIPN.Server.GetData() is unavailable.")
        return nil
    end

    local data = KIPN.Server.GetData()

    if not data then
        logError("KIPN data unavailable.")
        return nil
    end

    if type(data.eventReturnPositions) ~= "table" then
        data.eventReturnPositions = {}
    end

    return data.eventReturnPositions
end

local function capturePreEventPosition(player)
    local username = player and player:getUsername()
    local collection = getReturnPositionCollection()

    if not username or not collection or collection[username] then
        -- Already have one pending for this player (an earlier round
        -- of the same event, or an unresolved one from a previous
        -- event) -- never overwrite; see header.
        return
    end

    local ok, x, y, z = pcall(function() return player:getX(), player:getY(), player:getZ() end)

    if not ok or not x then
        logError("capturePreEventPosition() failed for " .. tostring(username))
        return
    end

    collection[username] = { x = x, y = y, z = z }
end

-- Idempotent: no pending record -> true (nothing to restore). Never
-- teleports a dead character -- defers instead, matching
-- KIPN_EventEscrowService.lua's RestoreEscrow() behavior exactly.
function ParticipationService.RestorePosition(player)
    local username = player and player:getUsername()

    if not username then
        return false, "NO_PLAYER"
    end

    local collection = getReturnPositionCollection()
    local point = collection and collection[username]

    if not point then
        return true
    end

    local isDeadOk, isDead = pcall(function() return player:isDead() end)

    if isDeadOk and isDead then
        log("RestorePosition() deferred for " .. username .. ": character is dead. Will retry at the next lifecycle point.")
        return false, "PLAYER_DEAD"
    end

    local ok, err = teleportPlayer(player, point)

    if not ok then
        logError("RestorePosition() teleport failed for " .. username .. ": " .. tostring(err))
        return false, "TELEPORT_FAILED"
    end

    collection[username] = nil
    KIPN.Server.Save()

    log("RestorePosition() -> restored " .. username .. " to pre-event position")

    return true
end

------------------------------------------------------------
-- PARTICIPANT RELEASE (called from KIPN_EventRuntimeService.lua's
-- stopEvent() for every outcome -- WIN, FAIL, MANUAL, LOST -- so
-- normal completion and cancellation are covered by this single
-- call site)
------------------------------------------------------------

function ParticipationService.ReleaseParticipants(runtime)
    if not runtime or not runtime.participants then
        return
    end

    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    local onlineByUsername = {}

    if online then
        for i = 0, online:size() - 1 do
            local p = online:get(i)
            local username = p and p:getUsername()
            if username then onlineByUsername[username] = p end
        end
    end

    for username in pairs(runtime.participants) do
        local p = onlineByUsername[username]

        if p then
            -- Loadout items go back before the player's own gear returns.
            if KIPN.Server.EventLoadoutService then pcall(KIPN.Server.EventLoadoutService.Remove, p, runtime) end
            ParticipationService.RestorePosition(p)
            KIPN.Server.EventEscrowService.RestoreEscrow(p)
        end
        -- Not online: both records stay pending, persisted
        -- independently of this runtime, and are picked up by
        -- onCreatePlayer() below the next time this player connects.
    end
end

------------------------------------------------------------
-- RECONNECT / RESTART RECOVERY
--
-- Events.OnCreatePlayer is a well-established vanilla PZ hook (fires
-- on initial spawn AND every reconnect/respawn) but is not otherwise
-- used anywhere else in KIPN yet -- flagged for a dedicated
-- multiplayer smoke test rather than assumed correct, matching the
-- guarded-registration style already used for
-- Events.OnPlayerDeath/Events.LoadGridsquare elsewhere in the mod.
--
-- Deliberately does NOT restore just because the player reconnected
-- while their owning event instance is still ACTIVE -- reconnecting
-- recovers a participant's escrow/return-position STATE (they stay
-- escrowed/away from home mid-event), it does not end the event for
-- them early. Only once the owning instance is no longer the active
-- one (normal end, cancellation, or -- since Event Runtime state
-- never survives a restart, per KIPN_EventRuntimeService.lua's header
-- -- any restart) does this restore.
------------------------------------------------------------

local function isOwningInstanceStillActive(definitionId, instanceId)
    local runtimeService = KIPN.Server.EventRuntimeService
    local runtime = runtimeService and runtimeService.ActiveRuntimes and runtimeService.ActiveRuntimes[definitionId]
    return runtime ~= nil and runtime.instanceId == instanceId
end

local function onCreatePlayer(_, player)
    local username = player and player:getUsername()

    if not username then
        return
    end

    local positionCollection = getReturnPositionCollection()
    local positionRecord = positionCollection and positionCollection[username]
    local escrowRecord = KIPN.Server.EventEscrowService.GetPendingEscrow(username)

    -- Return-position records don't carry a definitionId/instanceId
    -- (unlike escrow) since a pending one only ever exists once an
    -- event has ended for this player -- ReleaseParticipants() only
    -- leaves a record behind for participants who were offline at
    -- stop time, and a brand new event can't start with this player
    -- still on an old roster (see the pending-state join guards
    -- below). So restoring it opportunistically on every connect is
    -- always safe.
    if positionRecord then
        ParticipationService.RestorePosition(player)
    end

    if escrowRecord and not isOwningInstanceStillActive(escrowRecord.definitionId, escrowRecord.instanceId) then
        KIPN.Server.EventEscrowService.RestoreEscrow(player)
    end
end

------------------------------------------------------------
-- COMMAND HANDLER: ACCEPT PARTICIPATION
------------------------------------------------------------

local function respond(player, success, definitionId, reason)
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_PARTICIPATION_RESULT, {
        success = success,
        definitionId = definitionId,
        reason = reason,
    })
end

-- Countries for The Olympics: towns of Knox County and its
-- neighbours. A sign-up must name one of these.
ParticipationService.OLYMPIC_COUNTRIES = KIPN.Shared.EventOlympicCountries or {}

local function isCountry(name)
    for _, country in ipairs(ParticipationService.OLYMPIC_COUNTRIES) do
        if country == name then return true end
    end
    return false
end

-- Brings one signed-up player into a running event: teleport to the
-- start, remember where they came from, put them on a team if the
-- mode has teams, and escrow their gear for Naked and Afraid. Returns
-- ok, reason.
function ParticipationService.BringIn(player, definition, runtime)
    local username = player:getUsername()

    -- A participant with unresolved state from a PAST event (a return
    -- position or escrow not yet restored) must resolve it first, or
    -- capturing a new pre-event position would clobber the old one.
    local pendingPositions = getReturnPositionCollection()
    if pendingPositions and pendingPositions[username] then return false, "PENDING_RETURN_UNRESOLVED" end
    if KIPN.Server.EventEscrowService.HasPendingEscrow(username) then return false, "ESCROW_PENDING" end

    definition.participants[username] = true
    runtime.participants[username] = runtime.participants[username] or {
        teleportedAtMs = nil,
        lastKnownInZone = true,
        steamId = nil,
    }

    -- Nowhere to send them (an open-map event with no spawn, zone or
    -- hotspots): they join where they stand.
    local entryPoint = resolveEntryPoint(definition, runtime)
    if entryPoint then
        local ok, err = teleportPlayer(player, entryPoint)
        if not ok then
            logError("Teleport failed for " .. tostring(username) .. ": " .. tostring(err))
            return false, "TELEPORT_FAILED"
        end
    end

    runtime.participants[username].teleportedAtMs = (type(getTimestampMs) == "function" and getTimestampMs()) or 0
    runtime.participants[username].lastKnownInZone = true

    -- Best-effort additions to an already-successful join; none of them
    -- undo the roster add or teleport on failure.
    capturePreEventPosition(player)

    local modeMetadata = definition.mode and KIPN.Server.EventModeRegistry.GetModeMetadata(definition.mode)
    if modeMetadata and modeMetadata.usesTeams then
        KIPN.Server.EventTeamService.AssignParticipantsDeterministically(definition)
    end

    -- A starting loadout (or Naked and Afraid) holds the player's own
    -- gear in escrow, then hands out the loadout.
    local Loadout = KIPN.Server.EventLoadoutService
    if Loadout and Loadout.StripsGear(definition) then
        local escrowOk, escrowReason = KIPN.Server.EventEscrowService.CreateEscrow(player, definition.id, runtime.instanceId)
        if not escrowOk then
            logError("Escrow failed for " .. tostring(username) .. ": " .. tostring(escrowReason))
        end
    end
    if Loadout then
        local loadoutOk, loadoutErr = pcall(Loadout.Apply, player, definition, runtime)
        if not loadoutOk then logError("Loadout failed for " .. tostring(username) .. ": " .. tostring(loadoutErr)) end
    end

    if KIPN.Server.EventOlympicsService and definition.mode == "OLYMPICS" then
        pcall(KIPN.Server.EventOlympicsService.AddRacer, runtime, definition, username)
    end
    return true
end

-- Called from startEvent: everyone who signed up while joining was
-- open and is online now is brought in. Offline sign-ups stay on the
-- roster and can still join from the invite later.
function ParticipationService.BringInRoster(runtime, definition)
    local online = getOnlinePlayers()
    if not online then return end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()
        if username and definition.participants[username] then
            local ok, reason = ParticipationService.BringIn(p, definition, runtime)
            if not ok then
                respond(p, false, definition.id, reason)
                log("BringInRoster() -> " .. username .. " not brought in: " .. tostring(reason))
            end
        end
    end
    KIPN.Server.Save()
end

-- Accepting an invite. While joining is open this signs the player up
-- (they are brought in when the event begins); once it is running it
-- brings them straight in.
local function handleAcceptParticipation(player, args)
    args = args or {}

    local definition = KIPN.Server.EventScenarioService.GetDefinition(args.id)
    if not definition then
        respond(player, false, args.id, "DEFINITION_NOT_FOUND")
        return true
    end

    local username = player:getUsername()
    local Status = KIPN.Server.EventScenarioService.Status

    if definition.mode == "OLYMPICS" then
        if not isCountry(args.country) then
            respond(player, false, definition.id, "COUNTRY_REQUIRED")
            return true
        end
        definition.olympicsCountries = definition.olympicsCountries or {}
        definition.olympicsCountries[username] = args.country
    end

    if definition.status == Status.JOINING then
        definition.participants[username] = true
        KIPN.Server.Save()
        log("handleAcceptParticipation() -> " .. tostring(username) .. " signed up for " .. tostring(definition.id))
        respond(player, true, definition.id, "SIGNED_UP")
        return true
    end

    local runtime = KIPN.Server.EventRuntimeService
        and KIPN.Server.EventRuntimeService.ActiveRuntimes[definition.id]

    if definition.status ~= Status.ACTIVE or not runtime then
        respond(player, false, definition.id, "EVENT_NO_LONGER_ACTIVE")
        return true
    end

    local ok, reason = ParticipationService.BringIn(player, definition, runtime)
    if not ok then
        respond(player, false, definition.id, reason)
        return true
    end

    KIPN.Server.Save()
    log("handleAcceptParticipation() -> " .. tostring(username) .. " joined " .. tostring(definition.id))
    respond(player, true, definition.id, nil)
    return true
end

-- Called from KIPN_EventScenarioService.lua's handleOpenJoining: every
-- online player is asked to sign up.
function ParticipationService.BroadcastSignUpInvite(definition)
    if not definition then return end
    local promptText = "Sign up for " .. tostring(definition.name) .. "? You will be brought in when it begins."
    broadcastInvite(definition, "SIGN_UP", nil, promptText)
end

function ParticipationService.Initialize()
    KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.EVENT_ACCEPT_PARTICIPATION, handleAcceptParticipation)

    if Events.OnCreatePlayer then
        Events.OnCreatePlayer.Add(onCreatePlayer)
    end

    log("Initialize() -> registered command handlers")
    return true
end

log("module loaded")
