-- KIPN_ZombieDirector.lua
--
-- The Horde Survival objective's concrete plug-in into
-- KIPN_EventObjectiveRegistry.lua. This is the ONLY file that knows
-- about Horde Survival -- KIPN_EventObjectiveRegistry.lua,
-- KIPN_EventRuntimeService.lua, and the client control panel never
-- branch on objective type; they only ever see whatever `controls`
-- array this file registers.
--
-- A future second objective type (e.g. an Arena PvP objective) ships
-- as one new file that calls
-- KIPN.Server.EventObjectiveRegistry.Register("ARENA_PVP", {...}) --
-- it never needs to open or modify this file.
--
-- ZOMBIE SPAWN PRIMITIVE:
--
-- addZombiesInOutfit(x, y, z, count, outfitClass, femaleChance)
-- is called with the correct Build 42 signature. Radius is implemented
-- by selecting individual nearby squares; the final argument is never
-- misused as a radius. Outfit names are resolved from the outfits actually
-- loaded on the server by KIPN_EventZombieThemeRegistry.lua.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_WorldRegistry"
require "KIPN_EventObjectiveRegistry"
require "KIPN_EventHotspotService"
require "KIPN_EventZombieThemeRegistry"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.ZombieDirector = KIPN.Server.ZombieDirector or {}

local ZombieDirector = KIPN.Server.ZombieDirector

local OBJECTIVE_TYPE = "HORDE_SURVIVAL"

-- Minimum real-world time between automatic passive escalations,
-- independent of how often the admin clicks a live control.
local PASSIVE_ESCALATION_INTERVAL_MS = 5 * 60 * 1000

local function log(message)
    print("[KIPN ZOMBIE DIRECTOR] " .. tostring(message))
end

local function logError(message)
    print("[KIPN ZOMBIE DIRECTOR] ERROR: " .. tostring(message))
end

------------------------------------------------------------
-- ZONE ENTRY POINT
------------------------------------------------------------
--
-- WorldRegistry zones store only a rectangle -- there is no stored
-- "entry point" field (see the Event Scenarios plan's Zone design
-- section). This computes the rectangle's center at its lower z as
-- a reasonable default spawn/reference origin.
------------------------------------------------------------

local function getZoneEntryPoint(zoneId)
    if not (KIPN.Server.WorldRegistry and KIPN.Server.WorldRegistry.GetZone) then
        return nil
    end

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

local function getSpawnOrigin(runtime, definition)
    local hotspotService = KIPN.Server.EventHotspotService

    if hotspotService and hotspotService.GetZombieSpawnPoint then
        local point, hotspot = hotspotService.GetZombieSpawnPoint(definition)
        if point then
            log("getSpawnOrigin() -> hotspot=" .. tostring(hotspot and hotspot.id))
            return point
        end
    end

    local point = getZoneEntryPoint(runtime.zoneId)
    if point then
        log("getSpawnOrigin() -> linked Event Zone")
        return point
    end

    logError("getSpawnOrigin() -> no ZOMBIE_SPAWN hotspot or linked Event Zone")
    return nil
end

------------------------------------------------------------
-- DIRECTOR STATE DEFAULTS
--
-- Slider values live in runtime.directorState, read with `or
-- DEFAULT` at every use site (same idiom as the pre-existing
-- escalationTier field) rather than pre-seeded -- an event that
-- never touches a slider behaves exactly as it did before these
-- were added.
------------------------------------------------------------

local SLIDER_DEFAULTS = {
    spawnRate = 50,   -- 0-100, scales passive-escalation cadence
    waveSize = 50,    -- 0-100, multiplier on spawn counts (50 = baseline 1x)
    maxZombies = 100, -- 0-300, hard cap on live zombies in the zone
    aggression = 50,  -- 0-100, best-effort proxy -- see aggressionRadiusMultiplier()
}

------------------------------------------------------------
-- ZOMBIE COUNTING
------------------------------------------------------------
--
-- Shared by the zoneCleared win condition and the maxZombies cap
-- check below. UNVERIFIED API: relies on getCell():getZombieList()
-- returning every zombie in the cell -- see the caveat on
-- zoneCleared() further down. Any failure here is treated as "count
-- unknown" (nil), and callers must decide how to fail safe.
------------------------------------------------------------

local function countZombiesInZone(runtime)
    local zone = KIPN.Server.WorldRegistry.GetZone(runtime.zoneId)

    if not zone then
        return nil
    end

    local ok, count = pcall(function()
        local cell = getCell()

        if not cell then
            return nil
        end

        local zombies = cell:getZombieList()

        if not zombies then
            return nil
        end

        local total = 0

        for i = 0, zombies:size() - 1 do
            local zombie = zombies:get(i)

            if zombie and not zombie:isDead() then
                local ok2, square = pcall(function() return zombie:getSquare() end)

                if ok2 and square
                    and KIPN.Server.WorldRegistry.IsPositionInZone(square:getX(), square:getY(), square:getZ(), zone)
                then
                    total = total + 1
                end
            end
        end

        return total
    end)

    if not ok then
        return nil
    end

    return count
end

local function pruneAndCountTrackedZombies(runtime)
    local retained = {}
    local count = 0

    for _, zombie in ipairs(runtime.spawnedEventZombies or {}) do
        local alive = false
        local ok = pcall(function()
            alive = zombie ~= nil and zombie:isDead() ~= true and zombie:getSquare() ~= nil
        end)

        if ok and alive then
            retained[#retained + 1] = zombie
            count = count + 1
        end
    end

    runtime.spawnedEventZombies = retained
    log("pruneAndCountTrackedZombies() -> " .. tostring(count))
    return count
end

local function countLiveZombies(runtime)
    if runtime.scopeType == KIPN.Shared.EventScopeTypes.ZONE and runtime.zoneId then
        local zoneCount = countZombiesInZone(runtime)
        if zoneCount ~= nil then return zoneCount end
    end

    return pruneAndCountTrackedZombies(runtime)
        + math.max(0, tonumber(runtime.directorState.untrackedSpawnEstimate) or 0)
end

local function appendSpawnedZombies(runtime, spawned, target, shouldWalk)
    if not spawned then return 0 end

    runtime.spawnedEventZombies = runtime.spawnedEventZombies or {}
    local added = 0

    local function append(zombie)
        if not zombie then return end
        runtime.spawnedEventZombies[#runtime.spawnedEventZombies + 1] = zombie
        added = added + 1

        if shouldWalk and target then
            pcall(function()
                if zombie.pathToLocationF then
                    zombie:pathToLocationF(target.x, target.y, target.z)
                end
            end)
        end
    end

    local ok = pcall(function()
        if spawned.size and spawned.get then
            for index = 0, spawned:size() - 1 do append(spawned:get(index)) end
        else
            append(spawned)
        end
    end)

    if not ok then
        logError("appendSpawnedZombies() could not enumerate spawn result")
    end

    return added
end

local function spawnThemedZombies(runtime, definition, origin, requestedCount, radiusTiles, walkTarget)
    local currentCount = countLiveZombies(runtime)
    local maximum = math.max(0, math.floor(tonumber(runtime.directorState.maxZombies) or SLIDER_DEFAULTS.maxZombies))
    local available = math.max(0, maximum - currentCount)
    local count = math.min(math.max(0, math.floor(tonumber(requestedCount) or 0)), available)

    if count <= 0 then return 0, "MAX_ZOMBIES_REACHED" end

    local radius = math.max(0, math.floor(tonumber(radiusTiles) or 0))
    local registry = KIPN.Server.EventZombieThemeRegistry
    local totalSpawned = 0

    for _ = 1, count do
        local x = origin.x + (radius > 0 and (ZombRand(radius * 2 + 1) - radius) or 0)
        local y = origin.y + (radius > 0 and (ZombRand(radius * 2 + 1) - radius) or 0)
        local z = origin.z or 0
        local cell = getCell and getCell() or nil
        local square = cell and cell:getGridSquare(x, y, z) or nil

        if square then
            local outfit, femaleChance, category = nil, 50, "RANDOM"
            if registry and registry.ResolveOutfit then
                outfit, femaleChance, category = registry.ResolveOutfit(definition.zombieTheme)
            end

            local ok, spawnedOrError = pcall(function()
                return addZombiesInOutfit(x, y, z, 1, outfit, math.floor(tonumber(femaleChance) or 50))
            end)

            if ok then
                local added = appendSpawnedZombies(runtime, spawnedOrError, walkTarget, walkTarget ~= nil)
                -- Some builds do not expose the returned Java list to Lua even
                -- though the spawn succeeds. Keep a conservative estimate so
                -- OPEN_MAP/HOTSPOTS events still enforce their hard cap.
                if added == 0 then
                    runtime.directorState.untrackedSpawnEstimate =
                        (runtime.directorState.untrackedSpawnEstimate or 0) + 1
                end
                totalSpawned = totalSpawned + math.max(1, added)
                log("spawnThemedZombies() -> category=" .. tostring(category)
                    .. " outfit=" .. tostring(outfit) .. " square=" .. tostring(x) .. "," .. tostring(y))
            else
                logError("spawnThemedZombies() spawn failed at " .. tostring(x) .. "," .. tostring(y)
                    .. ": " .. tostring(spawnedOrError))
            end
        else
            log("spawnThemedZombies() skipped unloaded/invalid square " .. tostring(x) .. "," .. tostring(y))
        end
    end

    if totalSpawned <= 0 then return 0, "NO_VALID_SPAWN_SQUARES" end
    return totalSpawned
end

------------------------------------------------------------
-- AGGRESSION PROXY
------------------------------------------------------------
--
-- BEST-EFFORT APPROXIMATION, NOT REAL ZOMBIE AI AGGRESSION: there is
-- no verified per-zombie Lua hook for actual aggression/sight
-- radius in this game build (same caveat class as
-- environment.weatherPreset in KIPN_EventRuntimeService.lua). As a
-- stand-in, higher aggression tightens the spawn radius/distance so
-- zombies appear closer to participants -- at aggression=0 the
-- multiplier is 1.0 (unchanged), at aggression=100 it's 0.5 (half
-- distance).
------------------------------------------------------------

local function aggressionRadiusMultiplier(runtime)
    local aggression = runtime.directorState.aggression or SLIDER_DEFAULTS.aggression
    return 1 - (aggression / 200)
end

local function waveSizeMultiplier(runtime)
    local waveSize = runtime.directorState.waveSize or SLIDER_DEFAULTS.waveSize
    return waveSize / 50
end

------------------------------------------------------------
-- SPAWN RATE / EFFECTIVE INTERVAL
------------------------------------------------------------
--
-- Applied uniformly to whichever directorType's passive interval is
-- active (escalation cadence, perimeter re-check, random spawn
-- bounds) so the Spawn Rate slider means the same thing regardless
-- of which automation mode a definition is configured with. A
-- spawnRate of 0 fully throttles passive automation (returns nil --
-- callers must skip their tick entirely rather than divide by zero).
-- Manual control-panel clicks are never affected by this -- only
-- the automatic tick cadence.
------------------------------------------------------------

local function effectiveIntervalMs(runtime, baseIntervalMs)
    local rate = runtime.directorState.spawnRate or SLIDER_DEFAULTS.spawnRate

    if rate <= 0 then
        return nil
    end

    return math.floor(baseIntervalMs * (100 / rate))
end

------------------------------------------------------------
-- CONTROL HANDLERS
------------------------------------------------------------

local function spawnBurst(runtime, definition, params)
    if runtime.directorState.spawningPaused then
        return false, "SPAWNING_PAUSED"
    end

    local entryPoint = getSpawnOrigin(runtime, definition)

    if not entryPoint then
        return false, "SPAWN_LOCATION_UNAVAILABLE"
    end

    local count = math.floor((tonumber(params.count) or 20) * waveSizeMultiplier(runtime))
    local radiusTiles = math.floor((tonumber(params.radiusTiles) or 15) * aggressionRadiusMultiplier(runtime))

    local actualCount, reason = spawnThemedZombies(runtime, definition, entryPoint, count, radiusTiles)
    if actualCount <= 0 then return false, reason end

    runtime.directorState.totalSpawned = (runtime.directorState.totalSpawned or 0) + actualCount
    runtime.directorState.lastSpawnMs = getTimestampMs and getTimestampMs() or 0

    log("Spawned themed burst: requested=" .. tostring(count) .. " actual=" .. tostring(actualCount)
        .. " at (" .. tostring(entryPoint.x) .. "," .. tostring(entryPoint.y) .. ")")

    return true, { spawned = actualCount }
end

local function spawnWalkIn(runtime, definition, params)
    if runtime.directorState.spawningPaused then
        return false, "SPAWNING_PAUSED"
    end

    local entryPoint = getSpawnOrigin(runtime, definition)

    if not entryPoint then
        return false, "SPAWN_LOCATION_UNAVAILABLE"
    end

    local count = math.floor((tonumber(params.count) or 30) * waveSizeMultiplier(runtime))
    local fromDistanceTiles = math.floor((tonumber(params.fromDistanceTiles) or 60) * aggressionRadiusMultiplier(runtime))

    local fromX = entryPoint.x + fromDistanceTiles
    local fromY = entryPoint.y

    local actualCount, reason = spawnThemedZombies(
        runtime,
        definition,
        { x = fromX, y = fromY, z = entryPoint.z },
        count,
        8,
        entryPoint
    )
    if actualCount <= 0 then return false, reason end

    runtime.directorState.totalSpawned = (runtime.directorState.totalSpawned or 0) + actualCount
    runtime.directorState.lastSpawnMs = getTimestampMs and getTimestampMs() or 0

    log("Sent themed horde walking in: requested=" .. tostring(count) .. " actual=" .. tostring(actualCount))

    return true, { spawned = actualCount }
end

local function increaseRate(runtime, definition, params)
    runtime.directorState.escalationTier = (runtime.directorState.escalationTier or 1) + 1

    log("Escalation tier increased to " .. tostring(runtime.directorState.escalationTier))

    return true
end

local function decreaseRate(runtime, definition, params)
    local tier = runtime.directorState.escalationTier or 1

    runtime.directorState.escalationTier = math.max(1, tier - 1)

    log("Escalation tier reduced to " .. tostring(runtime.directorState.escalationTier))

    return true
end

local function stopSpawning(runtime, definition, params)
    runtime.directorState.spawningPaused = true

    log("Passive spawning paused.")

    return true
end

local function resumeSpawning(runtime, definition, params)
    runtime.directorState.spawningPaused = false

    log("Passive spawning resumed.")

    return true
end

------------------------------------------------------------
-- SLIDER HANDLERS
------------------------------------------------------------
--
-- Each stores a clamped value under runtime.directorState. Reused
-- by spawnBurst/spawnWalkIn/onTick above via the SLIDER_DEFAULTS
-- fallback idiom -- setting a slider takes effect on the very next
-- spawn action, no restart of the event required.
------------------------------------------------------------

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function setSpawnRate(runtime, definition, params)
    runtime.directorState.spawnRate = clamp(tonumber(params.value) or SLIDER_DEFAULTS.spawnRate, 0, 100)
    return true
end

local function setWaveSize(runtime, definition, params)
    runtime.directorState.waveSize = clamp(tonumber(params.value) or SLIDER_DEFAULTS.waveSize, 0, 100)
    return true
end

local function setMaxZombies(runtime, definition, params)
    runtime.directorState.maxZombies = clamp(tonumber(params.value) or SLIDER_DEFAULTS.maxZombies, 0, 300)
    return true
end

local function setAggression(runtime, definition, params)
    runtime.directorState.aggression = clamp(tonumber(params.value) or SLIDER_DEFAULTS.aggression, 0, 100)
    return true
end

-- params.origin (Phase 5, optional): an explicit {x,y,z} override for
-- the Event Director's alarm target selector (round zone / a specific
-- selected hotspot / every alarm-enabled hotspot -- see
-- KIPN_EventDirector.lua's handleTriggerAlarm()). Falls back to the
-- original getSpawnOrigin() resolution when omitted, so every existing
-- caller (KIPN_EventTriggerService.lua's ALARM action, Horde
-- Survival's own "alarm" control) is completely unaffected.
local function triggerAlarm(runtime, definition, params)
    local entryPoint = (params and params.origin) or getSpawnOrigin(runtime, definition)

    if not entryPoint then
        return false, "SPAWN_LOCATION_UNAVAILABLE"
    end

    local square = getCell() and getCell():getGridSquare(entryPoint.x, entryPoint.y, entryPoint.z)
    local building = square and square:getBuilding()

    if not building then
        return false, "NO_BUILDING_AT_ENTRY_POINT"
    end

    local def = building:getDef()

    if not def then
        return false, "NO_BUILDING_DEF"
    end

    def:setAlarmed(true)

    log("Triggered alarm at " .. tostring(entryPoint.x) .. "," .. tostring(entryPoint.y))

    return true
end

------------------------------------------------------------
-- PASSIVE AUTOMATION (directorType-driven)
------------------------------------------------------------
--
-- Called every runtime tick (KIPN_EventRuntimeService.lua). Only
-- acts if the definition opted into passive automation
-- (spawnRules.escalationEnabled) -- what KIND of automation applies
-- is chosen by definition.directorType (KIPN.Shared.EventDirectorTypes):
--
--   ZOMBIE_WAVES:      no passive automation at all, regardless of
--                       escalationEnabled -- the admin fires waves
--                       manually via the live control panel.
--   ZOMBIE_ESCALATION: periodic tier-scaled bursts (the original
--                       behavior this function had before directorType
--                       existed).
--   ZOMBIE_PERIMETER:  periodically re-triggers the zone's building
--                       alarm instead of spawning directly. Not every
--                       zone has a building at its entry point --
--                       a miss here is expected, not an error.
--   ZOMBIE_RANDOM:     fires a random control (burst/walk-in/alarm)
--                       at a randomized interval.
------------------------------------------------------------

local PERIMETER_CHECK_INTERVAL_MS = 5 * 60 * 1000
local RANDOM_MIN_INTERVAL_MS = 3 * 60 * 1000
local RANDOM_MAX_INTERVAL_MS = 8 * 60 * 1000

local function onTickEscalation(runtime, definition, config, now)
    local interval = effectiveIntervalMs(runtime, PASSIVE_ESCALATION_INTERVAL_MS)

    if not interval then
        return
    end

    local last = runtime.directorState.lastPassiveEscalationMs or runtime.startedAtMs or now

    if now - last < interval then
        return
    end

    runtime.directorState.lastPassiveEscalationMs = now

    local tier = runtime.directorState.escalationTier or 1
    local baseCount = tonumber(config.baseSpawnCount) or 10

    local ok, err = spawnBurst(runtime, definition, {
        count = baseCount * tier,
        radiusTiles = tonumber(config.baseSpawnRadius) or 40,
    })

    if not ok then
        logError("Escalation spawn failed: " .. tostring(err))
    end
end

local function onTickPerimeter(runtime, definition, now)
    local interval = effectiveIntervalMs(runtime, PERIMETER_CHECK_INTERVAL_MS)

    if not interval then
        return
    end

    local last = runtime.directorState.lastPerimeterCheckMs or runtime.startedAtMs or now

    if now - last < interval then
        return
    end

    runtime.directorState.lastPerimeterCheckMs = now

    triggerAlarm(runtime, definition, {})
end

local function onTickRandom(runtime, definition, config, now)
    local minInterval = effectiveIntervalMs(runtime, RANDOM_MIN_INTERVAL_MS)
    local maxInterval = effectiveIntervalMs(runtime, RANDOM_MAX_INTERVAL_MS)

    if not minInterval or not maxInterval then
        return
    end

    local nextAt = runtime.directorState.nextRandomSpawnMs

    if not nextAt then
        nextAt = now + ZombRand(minInterval, maxInterval + 1)
        runtime.directorState.nextRandomSpawnMs = nextAt
    end

    if now < nextAt then
        return
    end

    runtime.directorState.nextRandomSpawnMs = now + ZombRand(minInterval, maxInterval + 1)

    local roll = ZombRand(1, 4)

    if roll == 1 then
        spawnBurst(runtime, definition, {
            count = ZombRand(10, 31),
            radiusTiles = tonumber(config.baseSpawnRadius) or 40,
        })
    elseif roll == 2 then
        spawnWalkIn(runtime, definition, { count = ZombRand(15, 41), fromDistanceTiles = 60 })
    else
        triggerAlarm(runtime, definition, {})
    end
end

local function onTick(runtime, definition)
    local config = definition.spawnRules or {}

    if config.escalationEnabled ~= true then
        return
    end

    if not getTimestampMs then
        return
    end

    local directorType = definition.directorType or "ZOMBIE_WAVES"

    if directorType == "ZOMBIE_WAVES" then
        return
    end

    local now = getTimestampMs()

    if directorType == "ZOMBIE_ESCALATION" then
        onTickEscalation(runtime, definition, config, now)
    elseif directorType == "ZOMBIE_PERIMETER" then
        onTickPerimeter(runtime, definition, now)
    elseif directorType == "ZOMBIE_RANDOM" then
        onTickRandom(runtime, definition, config, now)
    end
end

------------------------------------------------------------
-- WIN CONDITION: ZONE CLEARED
------------------------------------------------------------
--
-- True once at least one spawn action has happened (so this can
-- never trivially win at t=0 before any horde exists) AND no live
-- zombies currently remain inside the zone. UNVERIFIED API: this
-- relies on getCell():getZombieList() returning every zombie in the
-- cell -- like the spawn primitives above, this has no prior
-- precedent in KIPN and should be confirmed on a real dedicated
-- server. Any failure here is treated conservatively (condition not
-- met) rather than risking a false win.
------------------------------------------------------------

local function zoneCleared(runtime, definition, params)
    if (runtime.directorState.totalSpawned or 0) <= 0 then
        return false
    end

    local remaining = countLiveZombies(runtime)

    if remaining == nil then
        return false
    end

    local maximumRemaining = math.max(0, math.floor(tonumber(params and params.maximumRemaining) or 0))

    return remaining <= maximumRemaining
end

------------------------------------------------------------
-- PUBLIC EXPORTS (for KIPN_EventTriggerService.lua's SPAWN_ZOMBIES/
-- ALARM trigger actions -- Phase 3 of the Event Scenarios rewrite)
--
-- Thin wrappers, no behavior change, same pattern as
-- KIPN_EventRuntimeService.lua's "PUBLIC EXPORTS" section.
------------------------------------------------------------

function ZombieDirector.SpawnThemedZombies(runtime, definition, origin, requestedCount, radiusTiles, walkTarget)
    return spawnThemedZombies(runtime, definition, origin, requestedCount, radiusTiles, walkTarget)
end

-- Fallback origin (ZOMBIE_SPAWN hotspot, else the linked Event Zone's
-- entry point) for a trigger with no geometry of its own.
function ZombieDirector.GetSpawnOrigin(runtime, definition)
    return getSpawnOrigin(runtime, definition)
end

function ZombieDirector.TriggerAlarm(runtime, definition, params)
    return triggerAlarm(runtime, definition, params)
end

function ZombieDirector.CleanupRuntime(runtime)
    local removed = 0
    for _, zombie in ipairs((runtime and runtime.spawnedEventZombies) or {}) do
        local ok = pcall(function()
            if zombie and zombie:isDead() ~= true then
                zombie:removeFromWorld()
                zombie:removeFromSquare()
                removed = removed + 1
            end
        end)
        if not ok then logError("CleanupRuntime() failed to remove one event zombie") end
    end

    if runtime then
        runtime.spawnedEventZombies = {}
        runtime.directorState = runtime.directorState or {}
        runtime.directorState.untrackedSpawnEstimate = 0
    end
    log("CleanupRuntime() -> removed=" .. tostring(removed))
    return true, removed
end

------------------------------------------------------------
-- FAIL CONDITION: ALL PARTICIPANTS DOWN
------------------------------------------------------------
--
-- True only once at least one tracked participant is currently
-- online AND every online tracked participant is dead. A
-- participant who has disconnected is not counted either way --
-- this only ever fails an event based on participants actually
-- present to be checked.
------------------------------------------------------------

local function allParticipantsDown(runtime, definition, params)
    local online = getOnlinePlayers()

    if not online then
        return false
    end

    local trackedOnlineCount = 0
    local downCount = 0

    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local username = p and p:getUsername()

        if username and runtime.participants[username] then
            trackedOnlineCount = trackedOnlineCount + 1

            local ok, dead = pcall(function() return p:isDead() end)

            if ok and dead then
                downCount = downCount + 1
            end
        end
    end

    local minimumOnlineParticipants = math.max(
        1,
        math.floor(tonumber(params and params.minimumOnlineParticipants) or 1)
    )

    return trackedOnlineCount >= minimumOnlineParticipants
        and downCount == trackedOnlineCount
end

------------------------------------------------------------
-- REGISTRATION
------------------------------------------------------------

function ZombieDirector.Initialize()
    if not (KIPN.Server.EventObjectiveRegistry and KIPN.Server.EventObjectiveRegistry.Register) then
        logError("KIPN.Server.EventObjectiveRegistry is not ready; Horde Survival not registered.")
        return false
    end

    KIPN.Server.EventObjectiveRegistry.Register(OBJECTIVE_TYPE, {
        displayName = "Horde Survival",

        controls = {
            {
                id = "spawn_burst",
                label = "+50 Zombies",
                defaultParams = { count = 50, radiusTiles = 15 },
                group = "ZOMBIES",
            },
            {
                id = "spawn_walkin",
                label = "Spawn Wave",
                defaultParams = { count = 30, fromDistanceTiles = 60 },
                group = "ZOMBIES",
            },
            {
                id = "stop_spawning",
                label = "Stop Spawning",
                defaultParams = {},
                group = "ZOMBIES",
            },
            {
                id = "resume_spawning",
                label = "Resume Spawning",
                defaultParams = {},
                group = "ZOMBIES",
            },
            {
                id = "alarm",
                label = "Trigger Alarm At Zone",
                defaultParams = {},
                group = "ZOMBIES",
            },
            {
                id = "increase_rate",
                label = "Escalate",
                defaultParams = {},
                group = "DIFFICULTY",
            },
            {
                id = "decrease_rate",
                label = "Reduce",
                defaultParams = {},
                group = "DIFFICULTY",
            },
        },

        handlers = {
            spawn_burst = spawnBurst,
            spawn_walkin = spawnWalkIn,
            increase_rate = increaseRate,
            decrease_rate = decreaseRate,
            stop_spawning = stopSpawning,
            resume_spawning = resumeSpawning,
            alarm = triggerAlarm,
        },

        sliders = {
            {
                id = "spawn_rate",
                label = "Spawn Rate",
                min = 0,
                max = 100,
                step = 1,
                defaultValue = SLIDER_DEFAULTS.spawnRate,
                group = "ZOMBIES",
            },
            {
                id = "wave_size",
                label = "Wave Size",
                min = 0,
                max = 100,
                step = 1,
                defaultValue = SLIDER_DEFAULTS.waveSize,
                group = "ZOMBIES",
            },
            {
                id = "max_zombies",
                label = "Maximum Zombies",
                min = 0,
                max = 300,
                step = 5,
                defaultValue = SLIDER_DEFAULTS.maxZombies,
                group = "ZOMBIES",
            },
            {
                id = "aggression",
                label = "Aggression",
                min = 0,
                max = 100,
                step = 1,
                defaultValue = SLIDER_DEFAULTS.aggression,
                group = "ZOMBIES",
            },
        },

        sliderHandlers = {
            spawn_rate = setSpawnRate,
            wave_size = setWaveSize,
            max_zombies = setMaxZombies,
            aggression = setAggression,
        },

        winConditions = {
            {
                id = "zone_cleared",
                label = "Zone cleared of zombies",
                defaultParams = { maximumRemaining = 0 },
                paramFields = {
                    {
                        key = "maximumRemaining",
                        label = "Maximum zombies remaining",
                        type = "integer",
                        min = 0,
                    },
                },
                objectiveTypes = { "SURVIVE", "HOLD_AREA" },
            },
        },

        failConditions = {
            {
                id = "all_participants_down",
                label = "All participants down",
                defaultParams = { minimumOnlineParticipants = 1 },
                paramFields = {
                    {
                        key = "minimumOnlineParticipants",
                        label = "Minimum online participants",
                        type = "integer",
                        min = 1,
                    },
                },
                objectiveTypes = {
                    "RETRIEVE", "DELIVER", "HOLD_AREA", "SURVIVE",
                    "LOCATE", "INTERACT", "ESCORT",
                },
            },
        },

        winConditionHandlers = {
            zone_cleared = zoneCleared,
        },

        failConditionHandlers = {
            all_participants_down = allParticipantsDown,
        },

        onTick = onTick,
    })

    return true
end

print("[KIPN] Zombie Director loaded")
