-- KIPN_EventExtractionService.lua
--
-- Extraction mode: hold out, then get out. Every variant shares one
-- climax so players always know how to win:
--
--   1. HOLD OUT. The event's own duration is running and zombies
--      come (the variant sets the flavour: Abandoned Soldier's
--      alarms, Hospital Ward's random attacks, Last Ditch's pressure
--      on a position you are told to defend).
--   2. THE EVAC ARRIVES for the last EVAC_WINDOW_MS of the duration
--      (or its last third, if the event is short). Everyone is told.
--   3. GET OUT. A living participant who reaches an EXTRACTION_POINT
--      hotspot while the evac is there is extracted: they win, are
--      flown back to where they were before the event, and are safe.
--      When the duration ends, whoever was extracted wins; nobody out
--      means the event is lost.
--
-- Prison Break is the variant with no waiting: the way out is open
-- from the start but locked for each prisoner until they search the
-- marked spot (a CAPTURE_ITEM or RESCUE_OBJECTIVE hotspot), then race
-- to the Extraction Point before time runs out.
--
-- The Heist is an escape too: bandits stole the gold. Players follow
-- the clues to the getaway car (or camp), fight the crew, take the
-- gold (in the trunk, or on the leader) and carry it to the extraction
-- point. Only a player carrying gold may leave; the gold is banked as
-- they do. Halfway through, a witness points the way to the car.
--
-- Earlier phases left three variants with no ending at all (no timer,
-- nothing to reach) and Last Ditch's rounds without a winner; the
-- evac window replaces both.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_EventModeRegistry"
require "KIPN_EventHotspotService"
require "KIPN_EventTimerService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventExtractionService = KIPN.Server.EventExtractionService or {}

local ExtractionService = KIPN.Server.EventExtractionService

local function log(message)
    print("[KIPN EVENT EXTRACTION] " .. tostring(message))
end

-- Which legacy objectiveType each variant's real mechanic depends on
-- -- see this file's header for what already drives each one.
local REQUIRED_OBJECTIVE_TYPE_BY_VARIANT = {
    ABANDONED_SOLDIER = "SURVIVE",
    HOSPITAL_WARD = "SURVIVE",
    LAST_DITCH = "SURVIVE",
    FIRE_SALE = "SURVIVE",
    TEST_SUBJECT = "SURVIVE",
    LAST_FLIGHT = "SURVIVE",
    ROAD_TRIP = "SURVIVE",
    PRISON_BREAK = "RETRIEVE",
    HEIST = "RETRIEVE",
}

local function hasObjectiveType(definition, objectiveType)
    for _, current in ipairs((definition and definition.objectiveTypes) or {}) do
        if current == objectiveType then return true end
    end
    return false
end

function ExtractionService.ValidateDefinition(definition)
    local failures = {}
    local variant = definition and definition.variant

    if not KIPN.Server.EventModeRegistry.IsValidVariant(KIPN.Shared.EventModes.EXTRACTION, variant) then
        failures[#failures + 1] = "EXTRACTION_VARIANT_REQUIRED"
        local ok = #failures == 0
        log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
        return ok, failures
    end

    local requiredObjectiveType = REQUIRED_OBJECTIVE_TYPE_BY_VARIANT[variant]
    if requiredObjectiveType and not hasObjectiveType(definition, requiredObjectiveType) then
        failures[#failures + 1] = "EXTRACTION_REQUIRES_" .. requiredObjectiveType .. "_OBJECTIVE"
    end

    if variant == "HEIST" and #KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_VEHICLE") < 1
        and #KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_CAMP") < 1 then
        failures[#failures + 1] = "HEIST_REQUIRES_BANDITS"
    end

    local extractionPoints = KIPN.Server.EventHotspotService.GetHotspots(
        definition, KIPN.Shared.EventHotspotTypes.EXTRACTION_POINT
    )
    if #extractionPoints < 1 then
        failures[#failures + 1] = "EXTRACTION_REQUIRES_EXTRACTION_POINT_HOTSPOT"
    end

    -- The evac arrives near the end of the duration, so there must be one.
    if not (definition.duration and definition.duration.enabled == true
        and (tonumber(definition.duration.durationSeconds) or 0) > 0) then
        failures[#failures + 1] = "EXTRACTION_REQUIRES_DURATION"
    end

    local ok = #failures == 0
    log("ValidateDefinition() -> " .. tostring(ok) .. " failures=" .. table.concat(failures, ","))
    return ok, failures
end

------------------------------------------------------------
-- RUNTIME
------------------------------------------------------------

ExtractionService.EVAC_WINDOW_MS = 3 * 60 * 1000

local function announce(runtime, text, color, username)
    local loop = KIPN.Server.EventGameLoopService
    if not loop then return end
    if username then loop.AnnounceTo(runtime, username, text, color) else loop.Announce(runtime, text, color) end
end

local function isPrisonBreak(definition)
    return definition.variant == KIPN.Shared.EventExtractionVariants.PRISON_BREAK
end

local function isHeist(definition)
    return definition.variant == "HEIST"
end

-- Escape variants (Prison Break, Fire Sale, The Test Subject, Road
-- Trip): the way out is open from the start.
local function isEscape(definition)
    return (KIPN.Shared.EventEscapeVariants or {})[definition.variant] == true
end

-- Fire Sale's twist, for any event with two or more exits: one, chosen
-- at random, is clear; a horde waits at each of the others. Players
-- are not told which.
local function swarmExits(runtime, definition)
    local state = runtime.extractionState
    local exits = KIPN.Server.EventHotspotService.GetHotspots(definition, "EXTRACTION_POINT")
    if #exits < 2 or state.exitsSwarmed then return end
    state.exitsSwarmed = true
    local safe = exits[ZombRand(1, #exits + 1)]
    state.safeExitId = safe.id
    local director = KIPN.Server.ZombieDirector
    local multiplier = KIPN.Server.EventThreatService and KIPN.Server.EventThreatService.Multiplier(runtime) or 1
    for _, exit in ipairs(exits) do
        if exit ~= safe and director and director.SpawnThemedZombies then
            pcall(director.SpawnThemedZombies, runtime, definition, KIPN.Server.EventHotspotService.GetCenter(exit), 12 * multiplier, 4, nil)
        end
    end
    announce(runtime, "One way out is clear. The others are swarmed. Choose carefully.", { 1.0, 0.6, 0.25 })
end

-- How long the evac stays: three minutes, or the last third of a
-- shorter event.
function ExtractionService.EvacWindowMs(definition)
    local durationMs = (tonumber(definition.duration and definition.duration.durationSeconds) or 0) * 1000
    return math.min(ExtractionService.EVAC_WINDOW_MS, math.floor(durationMs / 3))
end

local function inAnyHotspot(definition, hotspotType, x, y, z)
    for _, hotspot in ipairs(KIPN.Server.EventHotspotService.GetHotspots(definition, hotspotType)) do
        if KIPN.Server.EventHotspotService.IsPositionInHotspot(x, y, z, hotspot) then return true end
    end
    return false
end

local function nearest(definition, hotspotTypes, x, y)
    local best, bestDistance
    for _, hotspotType in ipairs(hotspotTypes) do
        for _, hotspot in ipairs(KIPN.Server.EventHotspotService.GetHotspots(definition, hotspotType)) do
            local c = KIPN.Server.EventHotspotService.GetCenter(hotspot)
            local distance = c and ((c.x - x) ^ 2 + (c.y - y) ^ 2)
            if distance and (not bestDistance or distance < bestDistance) then best, bestDistance = c, distance end
        end
    end
    return best
end

function ExtractionService.InitializeRuntime(runtime, definition)
    runtime.extractionState = {
        extracted = {},
        unlocked = {},
        evacOpen = isEscape(definition),
        gold = 0,
    }
    if runtime.extractionState.evacOpen then swarmExits(runtime, definition) end
    log("InitializeRuntime() -> " .. tostring(runtime.eventDefinitionId))
end

function ExtractionService.Tick(runtime, definition)
    local state = runtime.extractionState
    if not state then return end
    local remaining = KIPN.Server.EventTimerService.GetRemainingEventMs(runtime)

    if not state.evacOpen and remaining and remaining <= ExtractionService.EvacWindowMs(definition) then
        state.evacOpen = true
        announce(runtime, definition.variant == "LAST_FLIGHT" and "Rescue is here! Get to the pickup before it leaves."
            or "The evac has arrived! Reach the extraction point before it leaves.", { 0.45, 0.9, 0.45 })
        swarmExits(runtime, definition)
    end

    local players = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if not players then return end
    for i = 0, players:size() - 1 do
        local p = players:get(i)
        local username = p and p:getUsername()
        local participant = username and runtime.participants[username]
        local deadOk, dead = pcall(function() return p:isDead() end)
        if participant and not state.extracted[username] and deadOk and not dead
            and not (runtime.deaths and runtime.deaths[username]) then
            local x, y, z = p:getX(), p:getY(), p:getZ()
            if isPrisonBreak(definition) and not state.unlocked[username]
                and (inAnyHotspot(definition, "CAPTURE_ITEM", x, y, z) or inAnyHotspot(definition, "RESCUE_OBJECTIVE", x, y, z)) then
                state.unlocked[username] = true
                announce(runtime, "You found the way out! Now reach the extraction point.", { 0.45, 0.9, 0.45 }, username)
            end
            local mayLeave = state.evacOpen and (not isPrisonBreak(definition) or state.unlocked[username])
            local bandits = KIPN.Server.EventBanditService
            if isHeist(definition) and mayLeave then
                local carried = bandits and bandits.GoldCarried(p) or 0
                mayLeave = carried > 0
                if carried > 0 and not state.hasGold then
                    state.hasGold = true
                    announce(runtime, username .. " has the gold! Get it to the pickup.", { 1.0, 0.82, 0.3 })
                end
            end
            if mayLeave and inAnyHotspot(definition, "EXTRACTION_POINT", x, y, z) then
                if isHeist(definition) and bandits then state.gold = state.gold + bandits.TakeGold(p) end
                state.extracted[username] = true
                participant.extracted = true
                runtime.winners = runtime.winners or {}
                runtime.winners[username] = participant
                announce(runtime, username .. " made it out!", { 1.0, 0.82, 0.3 })
                -- Flown out: back to where they were before the event.
                pcall(KIPN.Server.EventParticipationService.RestorePosition, p)
            end
        end
    end
end

-- "WIN" once everyone still in the event is out or down (with at
-- least one out), "FAIL" if everyone is down with nobody out, else nil.
function ExtractionService.CheckEnd(runtime, _definition)
    local state = runtime.extractionState
    if not state then return nil end
    local online = {}
    local players = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if players then
        for i = 0, players:size() - 1 do
            local p = players:get(i)
            if p then online[p:getUsername()] = true end
        end
    end
    local anyOut, anyAccounted, anyLeft = false, false, false
    for username in pairs(runtime.participants or {}) do
        if state.extracted[username] then
            anyOut, anyAccounted = true, true
        elseif runtime.deaths and runtime.deaths[username] then
            anyAccounted = true
        elseif online[username] then
            anyLeft = true
        end
    end
    if anyLeft or not anyAccounted then return nil end
    return anyOut and "WIN" or "FAIL"
end

-- The clock ran out: the extracted win; nobody out is a loss.
function ExtractionService.ResolveOnTimer(runtime, _definition)
    local state = runtime.extractionState or { extracted = {} }
    runtime.winners = {}
    local any = false
    for username in pairs(state.extracted) do
        runtime.winners[username] = runtime.participants[username] or true
        any = true
    end
    return any and "WIN" or "FAIL"
end

-- Fills the player HUD (see KIPN_EventGameLoopService.BuildHud).
function ExtractionService.BuildHud(runtime, definition, username, hud)
    local state = runtime.extractionState or { extracted = {}, unlocked = {} }
    local line = function(text) hud.lines[#hud.lines + 1] = text end
    local out = 0
    for _ in pairs(state.extracted) do out = out + 1 end
    local position
    for _, entry in ipairs(KIPN.Server.EventGameLoopService.OnlineParticipants(runtime)) do
        if entry.username == username then position = { x = entry.player:getX(), y = entry.player:getY() } end
    end

    if state.extracted[username] then
        hud.goal = "You made it out! You win when the event ends."
    elseif isHeist(definition) then
        local bandits = KIPN.Server.EventBanditService
        local mine = 0
        for _, entry in ipairs(KIPN.Server.EventGameLoopService.OnlineParticipants(runtime)) do
            if entry.username == username and bandits then mine = bandits.GoldCarried(entry.player) end
        end
        if mine > 0 then
            hud.goal = "You have " .. mine .. " gold bar" .. (mine == 1 and "" or "s") .. ". Get to the pickup!"
            local exit = position and nearest(definition, { "EXTRACTION_POINT" }, position.x, position.y)
            if exit then hud.target = { x = exit.x, y = exit.y, label = "Pickup" } end
        else
            hud.goal = "Bandits stole the gold. Find their getaway car, stop them and take it back."
            local total = (tonumber(definition.duration and definition.duration.durationSeconds) or 0) * 1000
            local remaining = KIPN.Server.EventTimerService.GetRemainingEventMs(runtime) or 0
            local car = bandits and bandits.GetawaySpot(definition)
            if car and total > 0 and remaining <= total / 2 then
                hud.target = { x = car.x, y = car.y, label = "Witness: car went this way" }
            end
        end
        line(state.gold .. " gold bar" .. (state.gold == 1 and "" or "s") .. " recovered")
    elseif isPrisonBreak(definition) and not state.unlocked[username] then
        hud.goal = "Break out: search the marked spot to find the way out."
        local spot = position and nearest(definition, { "CAPTURE_ITEM", "RESCUE_OBJECTIVE" }, position.x, position.y)
        if spot then hud.target = { x = spot.x, y = spot.y, label = "Way out" } end
    elseif state.evacOpen and isEscape(definition) then
        local goals = {
            FIRE_SALE = "Get out of the mall! One exit is clear; the others are swarmed.",
            TEST_SUBJECT = "Find your way up and out of the base.",
            ROAD_TRIP = "Make it to safety. Find a car if you can.",
            PRISON_BREAK = "You found the way out. Run for the exit!",
        }
        hud.goal = goals[definition.variant] or "Get out!"
        local exit = position and nearest(definition, { "EXTRACTION_POINT" }, position.x, position.y)
        if exit then hud.target = { x = exit.x, y = exit.y, label = "Way out" } end
    elseif state.evacOpen then
        hud.goal = "The evac is here! Reach the extraction point before it leaves."
        local exit = position and nearest(definition, { "EXTRACTION_POINT" }, position.x, position.y)
        if exit then hud.target = { x = exit.x, y = exit.y, label = "Extraction" } end
    else
        local remaining = KIPN.Server.EventTimerService.GetRemainingEventMs(runtime) or 0
        hud.phase = "Evac arrives in"
        hud.phaseLeftMs = math.max(0, remaining - ExtractionService.EvacWindowMs(definition))
        local waits = {
            LAST_DITCH = "Barricade and hold this position until the evac arrives.",
            LAST_FLIGHT = "Patch yourself up, find your pack, and hold out for the rescue.",
            HOSPITAL_WARD = "Stay alive until help arrives.",
        }
        hud.goal = waits[definition.variant] or "Stay alive until the evac arrives."
    end
    line(out .. " made it out so far")
end

function ExtractionService.Initialize()
    log("Initialize()")
    return true
end

return true
