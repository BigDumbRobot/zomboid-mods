-- KIPN_EventCaptureService.lua
--
-- Phase 6 of the Event Scenarios architecture rewrite: the first real
-- mode engine. Implements the CAPTURE mode's two rule variants --
-- Team CTF (per-team bases, one flag per team) and FFA Capture (one
-- neutral flag, one common delivery point) -- as a genuine tracked
-- physical-item system, per the mode contract's "the physical capture
-- system, not a manual Complete Objective button or global timer
-- expiry, determines normal round success."
--
-- INTEGRATION: called directly from KIPN_EventRuntimeService.lua's
-- startEvent/onTick/stopEvent, gated on definition.mode == "CAPTURE"
-- -- the exact same integration pattern already proven by
-- KIPN_EventTriggerService.lua (Phase 3) and
-- KIPN_EventScenarioRuntimeRegistry.lua, NOT through the
-- eventType/EventObjectiveRegistry win-condition system (which stays
-- HORDE_SURVIVAL-only, per the Phase 1 audit's note that the
-- mode/eventType duality is not yet unified). Round start/complete/
-- advance/restart continue to go through
-- KIPN_EventScenarioRuntimeRegistry.lua's existing scenario_* controls
-- (already reachable for Capture today, since its preset seeds
-- objectiveTypes = {"RETRIEVE","DELIVER"}, both registered there) --
-- this file only decides WHEN a round completes (a real delivery),
-- dispatching to that existing entry point rather than reimplementing
-- round bookkeeping.
--
-- ITEM IDENTITY: server-authoritative, never trusted from a client.
-- Every spawned flag is tagged via item:getModData() with a unique
-- id, the exact same idiom KIPN_ArtifactService.lua's
-- setItemArtifactId()/getItemArtifactId() already uses for artifact
-- items (modData survives AddWorldInventoryItem/pickup round trips,
-- per that file's design). There is no client "I captured it" command
-- at all -- delivery is detected purely by the server polling each
-- tracked item's real state (whose inventory it's actually in, and
-- whether that player is actually standing in the correct delivery
-- geometry), so there is nothing for a client to spoof.
--
-- AUTO-RETURN: if a tracked item can't be located anywhere (dropped
-- somewhere unreachable, participant disconnected mid-carry, etc.) it
-- is respawned fresh at its origin after definition.captureConfig.
-- autoReturnSeconds -- an explicit, data-driven, admin-configured
-- rule (default 90s), not a silently invented timer.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_EventHotspotService"
require "KIPN_EventTeamService"
require "KIPN_EventScenarioRuntimeRegistry"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventCaptureService = KIPN.Server.EventCaptureService or {}

local CaptureService = KIPN.Server.EventCaptureService

local MOD_DATA_KEY = "KIPN_CaptureItemId"

local function log(message)
    print("[KIPN EVENT CAPTURE] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT CAPTURE] ERROR: " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

------------------------------------------------------------
-- ITEM TAGGING (same modData idiom as
-- KIPN_ArtifactService.lua's setItemArtifactId/getItemArtifactId)
------------------------------------------------------------

local function getItemModData(item)
    if not item or type(item.getModData) ~= "function" then return nil end
    local ok, modData = pcall(function() return item:getModData() end)
    return ok and modData or nil
end

local function tagItem(item, itemId)
    local modData = getItemModData(item)
    if not modData then return false end
    modData[MOD_DATA_KEY] = tostring(itemId)
    return true
end

local function getItemTag(item)
    local modData = getItemModData(item)
    if not modData then return nil end
    return modData[MOD_DATA_KEY]
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------

function CaptureService.ValidateDefinition(definition)
    local failures = {}
    local variant = definition.variant
    local maxRounds = math.max(1, math.floor(tonumber(definition.maxRounds) or 1))

    if variant ~= "TEAM_CTF" and variant ~= "FFA" then
        failures[#failures + 1] = "CAPTURE_VARIANT_REQUIRED"
        log("ValidateDefinition() -> false failures=CAPTURE_VARIANT_REQUIRED")
        return false, failures
    end

    local flagItemFullType = definition.captureConfig and definition.captureConfig.flagItemFullType

    if type(flagItemFullType) ~= "string" or flagItemFullType == "" then
        failures[#failures + 1] = "CAPTURE_FLAG_ITEM_REQUIRED"
    end

    if variant == "TEAM_CTF" then
        local teams = definition.teams or {}

        if #teams < 2 then
            failures[#failures + 1] = "CAPTURE_TEAM_CTF_REQUIRES_TEAMS"
        else
            for _, team in ipairs(teams) do
                for round = 1, maxRounds do
                    if not KIPN.Server.EventHotspotService.FindHotspot(definition, "TEAM_BASE", round, team.id) then
                        failures[#failures + 1] = "CAPTURE_TEAM_BASE_MISSING"
                        break
                    end
                end
            end
        end
    else
        for round = 1, maxRounds do
            if not KIPN.Server.EventHotspotService.FindHotspot(definition, "CAPTURE_ITEM", round, nil) then
                failures[#failures + 1] = "CAPTURE_FFA_FLAG_SPAWN_MISSING"
                break
            end
        end

        for round = 1, maxRounds do
            if not KIPN.Server.EventHotspotService.FindHotspot(definition, "DELIVERY_POINT", round, nil) then
                failures[#failures + 1] = "CAPTURE_FFA_DELIVERY_POINT_MISSING"
                break
            end
        end
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- GEOMETRY / SPAWNING
------------------------------------------------------------

local function resolveSpawnSquare(geometry)
    local hotspotService = KIPN.Server.EventHotspotService

    for _ = 1, 5 do
        local point = hotspotService.GetRandomPointInGeometry(geometry)
        if point then
            local cellOk, cell = pcall(getCell)
            local square = cellOk and cell and cell:getGridSquare(point.x, point.y, point.z or 0)
            if square then return square, point end
        end
    end

    local center = { x = math.floor((geometry.x1 + geometry.x2) / 2), y = math.floor((geometry.y1 + geometry.y2) / 2), z = geometry.z1 or 0 }
    local cellOk, cell = pcall(getCell)
    local square = cellOk and cell and cell:getGridSquare(center.x, center.y, center.z)
    return square, square and center or nil
end

local function spawnFlagAt(runtime, definition, hotspot, itemId, teamId, roundNumber)
    local square, point = resolveSpawnSquare(hotspot.geometry)

    if not square then
        logError("spawnFlagAt() -> no valid square in hotspot " .. tostring(hotspot.id))
        return false
    end

    local flagItemFullType = definition.captureConfig.flagItemFullType
    local item = KIPN.Server.CreateItem(flagItemFullType)

    if not item then
        logError("spawnFlagAt() -> failed to create " .. tostring(flagItemFullType))
        return false
    end

    local droppedOk = pcall(function() square:AddWorldInventoryItem(item, 0, 0, 0) end)

    if not droppedOk then
        logError("spawnFlagAt() -> failed to place item on the ground")
        return false
    end

    tagItem(item, itemId)

    runtime.captureState.items[itemId] = {
        itemId = itemId,
        teamId = teamId,
        roundNumber = roundNumber,
        state = "AT_BASE",
        carrierUsername = nil,
        liveItemRef = item,
        lastKnownPosition = point,
        spawnHotspotId = hotspot.id,
        lostAtMs = nil,
    }

    log("spawnFlagAt() -> itemId=" .. tostring(itemId) .. " team=" .. tostring(teamId) .. " round=" .. tostring(roundNumber))
    return true
end

local function spawnFlagsForRound(runtime, definition, roundNumber)
    local hotspotService = KIPN.Server.EventHotspotService

    if runtime.captureState.variant == "TEAM_CTF" then
        for _, team in ipairs(definition.teams or {}) do
            local base = hotspotService.FindHotspot(definition, "TEAM_BASE", roundNumber, team.id)
            if base then
                local itemId = "capture_" .. tostring(runtime.instanceId) .. "_r" .. tostring(roundNumber) .. "_" .. tostring(team.id)
                spawnFlagAt(runtime, definition, base, itemId, team.id, roundNumber)
            else
                logError("spawnFlagsForRound() -> no TEAM_BASE for team " .. tostring(team.id) .. " round " .. tostring(roundNumber))
            end
        end
    else
        local spawnHotspot = hotspotService.FindHotspot(definition, "CAPTURE_ITEM", roundNumber, nil)
        if spawnHotspot then
            local itemId = "capture_" .. tostring(runtime.instanceId) .. "_r" .. tostring(roundNumber) .. "_neutral"
            spawnFlagAt(runtime, definition, spawnHotspot, itemId, nil, roundNumber)
        else
            logError("spawnFlagsForRound() -> no CAPTURE_ITEM hotspot for round " .. tostring(roundNumber))
        end
    end
end

------------------------------------------------------------
-- CLEANUP (one item -- removes it from wherever it currently is,
-- inventory or world ground)
------------------------------------------------------------

local function removeItemWherever(entry)
    local item = entry.liveItemRef

    if not item then return end

    if entry.state == "CARRIED" and entry.carrierUsername then
        local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
        if online then
            for i = 0, online:size() - 1 do
                local p = online:get(i)
                if p and p:getUsername() == entry.carrierUsername then
                    pcall(function()
                        if type(p.removeFromHands) == "function" then p:removeFromHands(item) end
                        local inventory = p:getInventory()
                        inventory:Remove(item)
                        if type(sendRemoveItemFromContainer) == "function" then
                            sendRemoveItemFromContainer(inventory, item)
                        end
                    end)
                    return
                end
            end
        end
        return
    end

    -- AT_BASE / DROPPED / LOST -- a world object, same
    -- scan-by-identity removal idiom as
    -- KIPN_EventTriggerService.lua's loot CleanupRuntime().
    local cellOk, cell = pcall(getCell)
    if not cellOk or not cell then return end

    local point = entry.lastKnownPosition
    if not point then return end

    local squareOk, square = pcall(function() return cell:getGridSquare(point.x, point.y, point.z or 0) end)
    if not squareOk or not square then return end

    pcall(function()
        local worldObjects = square:getWorldObjects()
        if not worldObjects then return end

        for i = 0, worldObjects:size() - 1 do
            local worldObj = worldObjects:get(i)
            if worldObj and worldObj:getItem() == item then
                if type(square.transmitRemoveItemFromSquare) == "function" then
                    square:transmitRemoveItemFromSquare(worldObj)
                end
                worldObj:removeFromWorld()
                worldObj:removeFromSquare()
                break
            end
        end
    end)
end

------------------------------------------------------------
-- LOCATING A TRACKED ITEM (pickup / carrier-verification detection)
--
-- Bounded, non-recursive: checks each eligible online participant's
-- root inventory plus one level of nested containers (bags). A flag
-- buried deeper than that is a known, documented scope limit for this
-- first pass -- see the Phase 6 report.
------------------------------------------------------------

local function findTaggedItemInInventory(inventory, itemId)
    local itemsOk, items = pcall(function() return inventory:getItems() end)
    if not itemsOk or not items then return nil end

    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and getItemTag(item) == itemId then
            return item
        end

        local nestedOk, nestedInventory = pcall(function() return item and item:getInventory() end)
        if nestedOk and nestedInventory then
            local nestedItemsOk, nestedItems = pcall(function() return nestedInventory:getItems() end)
            if nestedItemsOk and nestedItems then
                for j = 0, nestedItems:size() - 1 do
                    local nestedItem = nestedItems:get(j)
                    if nestedItem and getItemTag(nestedItem) == itemId then
                        return nestedItem
                    end
                end
            end
        end
    end

    return nil
end

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
-- ROUND WIN CREDIT (dispatches to the existing
-- KIPN_EventScenarioRuntimeRegistry.lua round-completion entry point
-- -- reused verbatim, not reimplemented)
------------------------------------------------------------

local function creditDelivery(runtime, definition, entry, carrierUsername)
    entry.state = "DELIVERED"

    runtime.captureState.playerRoundWins[carrierUsername] = (runtime.captureState.playerRoundWins[carrierUsername] or 0) + 1

    local winningTeamId = nil
    if runtime.captureState.variant == "TEAM_CTF" then
        winningTeamId = KIPN.Server.EventTeamService.GetPlayerTeam(definition, carrierUsername)
        if winningTeamId then
            runtime.captureState.teamRoundWins[winningTeamId] = (runtime.captureState.teamRoundWins[winningTeamId] or 0) + 1
        end
    end

    local dispatchOk, dispatchResult = KIPN.Server.EventScenarioRuntimeRegistry.Dispatch(
        "scenario_complete_round", runtime, definition,
        { winnerUsername = carrierUsername, winnerTeamId = winningTeamId }
    )

    if not dispatchOk then
        logError("creditDelivery() round-complete dispatch failed: " .. tostring(dispatchResult))
    end

    log("creditDelivery() -> " .. tostring(carrierUsername) .. " team=" .. tostring(winningTeamId))
end

------------------------------------------------------------
-- PER-ITEM TICK PROCESSING
------------------------------------------------------------

local function processCarriedItem(runtime, definition, entry)
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    local carrierPlayer = nil

    if online then
        for i = 0, online:size() - 1 do
            local p = online:get(i)
            if p and p:getUsername() == entry.carrierUsername then carrierPlayer = p end
        end
    end

    if not carrierPlayer then
        -- Disconnected while carrying -- can't verify possession or
        -- position; treat as lost so auto-return can eventually
        -- recover the round rather than stalling it forever.
        entry.state = "LOST"
        entry.lostAtMs = now()
        entry.carrierUsername = nil
        return
    end

    local isDeadOk, isDead = pcall(function() return carrierPlayer:isDead() end)
    if isDeadOk and isDead then
        entry.state = "LOST"
        entry.lostAtMs = now()
        entry.carrierUsername = nil
        return
    end

    local stillHeld = findTaggedItemInInventory(carrierPlayer:getInventory(), entry.itemId)

    if not stillHeld then
        -- Dropped (or given away) -- try to find it on the carrier's
        -- current square; otherwise mark lost for auto-return.
        local squareOk, square = pcall(function() return carrierPlayer:getSquare() end)
        local found = false

        if squareOk and square then
            local worldObjectsOk, worldObjects = pcall(function() return square:getWorldObjects() end)
            if worldObjectsOk and worldObjects then
                for i = 0, worldObjects:size() - 1 do
                    local worldObj = worldObjects:get(i)
                    local candidateItem = worldObj and worldObj:getItem()
                    if candidateItem and getItemTag(candidateItem) == entry.itemId then
                        entry.state = "DROPPED"
                        entry.liveItemRef = candidateItem
                        entry.lastKnownPosition = { x = square:getX(), y = square:getY(), z = square:getZ() }
                        entry.carrierUsername = nil
                        found = true
                        break
                    end
                end
            end
        end

        if not found then
            entry.state = "LOST"
            entry.lostAtMs = now()
            entry.carrierUsername = nil
        end

        return
    end

    -- Still carried -- check delivery geometry.
    local posOk, x, y, z = pcall(function() return carrierPlayer:getX(), carrierPlayer:getY(), carrierPlayer:getZ() end)
    if not posOk or not x then return end

    if runtime.captureState.variant == "TEAM_CTF" then
        if not entry.teamId then return end

        local carrierTeamId = KIPN.Server.EventTeamService.GetPlayerTeam(definition, entry.carrierUsername)

        -- "A team's own flag must never count as an enemy capture" --
        -- only an enemy team's flag, delivered to the carrier's OWN
        -- base, scores.
        if not carrierTeamId or carrierTeamId == entry.teamId then return end

        local ownBase = KIPN.Server.EventHotspotService.FindHotspot(definition, "TEAM_BASE", entry.roundNumber, carrierTeamId)
        if ownBase and KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, ownBase) then
            creditDelivery(runtime, definition, entry, entry.carrierUsername)
        end
    else
        local deliveryHotspot = KIPN.Server.EventHotspotService.FindHotspot(definition, "DELIVERY_POINT", entry.roundNumber, nil)
        if deliveryHotspot and KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, deliveryHotspot) then
            creditDelivery(runtime, definition, entry, entry.carrierUsername)
        end
    end
end

local function processUnclaimedItem(runtime, definition, entry, eligible)
    for _, candidate in ipairs(eligible) do
        local found = findTaggedItemInInventory(candidate.player:getInventory(), entry.itemId)

        if found then
            entry.state = "CARRIED"
            entry.carrierUsername = candidate.username
            entry.liveItemRef = found
            entry.lostAtMs = nil
            return
        end
    end

    -- Not currently held by anyone eligible. If it's been
    -- unreachable/lost long enough, respawn a fresh replacement at
    -- its origin hotspot -- an explicit, admin-configured rule
    -- (captureConfig.autoReturnSeconds), never a silent one.
    if entry.state == "LOST" and entry.lostAtMs then
        local autoReturnSeconds = (definition.captureConfig and definition.captureConfig.autoReturnSeconds) or 90

        if (now() - entry.lostAtMs) >= autoReturnSeconds * 1000 then
            local hotspot = KIPN.Server.EventHotspotService.FindById(definition, entry.spawnHotspotId)

            if hotspot then
                log("processUnclaimedItem() -> auto-returning " .. tostring(entry.itemId))
                spawnFlagAt(runtime, definition, hotspot, entry.itemId, entry.teamId, entry.roundNumber)
            end
        end
    end
end

------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------

function CaptureService.InitializeRuntime(runtime, definition)
    runtime.captureState = {
        variant = definition.variant,
        items = {},
        teamRoundWins = {},
        playerRoundWins = {},
        lastSeenRoundStartedAtMs = nil,
    }
    return true
end

function CaptureService.Tick(runtime, definition)
    if not runtime.captureState then return end

    local roundStartedAtMs = runtime.round and runtime.round.startedAtMs

    if roundStartedAtMs and roundStartedAtMs ~= runtime.captureState.lastSeenRoundStartedAtMs then
        -- Genuine new round (or a restart of the current one) --
        -- clean up whatever survived the previous round, then spawn
        -- this round's flag(s). See file header for why this is
        -- detected here rather than hooked into
        -- KIPN_EventScenarioRuntimeRegistry.lua's startRound()
        -- directly.
        for _, entry in pairs(runtime.captureState.items) do
            removeItemWherever(entry)
        end
        runtime.captureState.items = {}

        spawnFlagsForRound(runtime, definition, runtime.round.current)
        runtime.captureState.lastSeenRoundStartedAtMs = roundStartedAtMs
    end

    if not (runtime.round and runtime.round.state == "ACTIVE") then
        return
    end

    local eligible = getEligibleParticipants(runtime)

    for _, entry in pairs(runtime.captureState.items) do
        if entry.state == "CARRIED" then
            processCarriedItem(runtime, definition, entry)
        elseif entry.state ~= "DELIVERED" then
            processUnclaimedItem(runtime, definition, entry, eligible)
        end
    end
end

function CaptureService.CleanupRuntime(runtime)
    if not runtime or not runtime.captureState then return true, 0 end

    local removed = 0

    for _, entry in pairs(runtime.captureState.items) do
        local ok = pcall(removeItemWherever, entry)
        if ok then removed = removed + 1 end
    end

    runtime.captureState.items = {}

    log("CleanupRuntime() -> removed=" .. tostring(removed))
    return true, removed
end

-- Called from KIPN_EventRuntimeService.lua's evaluateEndConditions()
-- right before it declares the event WIN on final-round-complete, but
-- only for mode == CAPTURE. Overall winner is whoever (team, for Team
-- CTF; player, for FFA) accumulated the most round wins -- ties are
-- resolved as explicit co-winners, per the mode contract's "explicit
-- tie resolution... rather than an arbitrary table-order winner."
function CaptureService.ResolveOverallWinner(runtime, definition)
    runtime.winners = {}

    if runtime.captureState.variant == "TEAM_CTF" then
        local bestCount = -1
        local winningTeamIds = {}

        for teamId, count in pairs(runtime.captureState.teamRoundWins) do
            if count > bestCount then
                bestCount = count
                winningTeamIds = { teamId }
            elseif count == bestCount then
                winningTeamIds[#winningTeamIds + 1] = teamId
            end
        end

        local winningTeamSet = {}
        for _, teamId in ipairs(winningTeamIds) do winningTeamSet[teamId] = true end

        for _, team in ipairs(definition.teams or {}) do
            if winningTeamSet[team.id] then
                for username in pairs(team.members or {}) do
                    runtime.winners[username] = runtime.participants[username] or true
                end
            end
        end

        log("ResolveOverallWinner() -> team(s) " .. table.concat(winningTeamIds, ",") .. " (" .. tostring(bestCount) .. " round win(s))")
    else
        local bestCount = -1
        local winningUsernames = {}

        for username, count in pairs(runtime.captureState.playerRoundWins) do
            if count > bestCount then
                bestCount = count
                winningUsernames = { username }
            elseif count == bestCount then
                winningUsernames[#winningUsernames + 1] = username
            end
        end

        for _, username in ipairs(winningUsernames) do
            runtime.winners[username] = runtime.participants[username] or true
        end

        log("ResolveOverallWinner() -> player(s) " .. table.concat(winningUsernames, ",") .. " (" .. tostring(bestCount) .. " round win(s))")
    end
end

function CaptureService.Initialize()
    log("Initialize() -> module ready")
    return true
end

log("module loaded")
