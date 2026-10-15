-- KIPN_EventThreatService.lua
--
-- The set-pieces that make Pillow's scenarios tense, for any event:
--
--   DIFFICULTY  Normal / Dire / Brutal, fixed or rolled at start the
--               way Pillow does (1 in 2 Dire, 1 in 4 of those Brutal).
--               Announced with Pillow's thunder or death sting. Scales
--               the zombie director, sieges, ambushes and injuries.
--   SIEGE       Hordes gather on four sides of the players and walk in
--               (Abandoned Soldier, Last Ditch Security), again every
--               few minutes -- sooner on harder difficulties.
--   FIRES       Fires break out near players (Fire Sale). Real fire.
--   ALARM       The building a player is in starts wailing (Fire Sale,
--               Prison, Hospital, Naked and Afraid).
--   AMBUSH      ZOMBIE_AMBUSH hotspots: a room of zombies that wakes the
--               first time a participant comes near (The Test Subject's
--               caves and labs, the Prison's dining hall).
--
-- Called from KIPN_EventRuntimeService.lua: InitializeRuntime at start,
-- Tick every runtime tick. Zombies come from the Zombie Director
-- (themed, counted against its cap, cleaned up at the end).

if isClient() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventHotspotService"
require "KIPN_EventBanditService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventThreatService = KIPN.Server.EventThreatService or {}

local Threats = KIPN.Server.EventThreatService

Threats.FIRST_SIEGE_MS = 30000
Threats.SIEGE_EVERY_MS = { NORMAL = 8 * 60000, DIRE = 5 * 60000, BRUTAL = 3 * 60000 }
Threats.SIEGE_DISTANCE = 35
Threats.SIEGE_PER_SIDE = 10
Threats.FIRE_EVERY_MS = { NORMAL = 4 * 60000, DIRE = 3 * 60000, BRUTAL = 2 * 60000 }
Threats.ALARM_AFTER_MS = { NORMAL = 3 * 60000, DIRE = 90000, BRUTAL = 20000 }
Threats.AMBUSH_RADIUS = 8

local RED = { 1.0, 0.42, 0.42 }
local ORANGE = { 1.0, 0.6, 0.25 }

-- Pillow's lines when a fire starts nearby.
Threats.FIRE_LINES = { "What's that smell?", "It's a little warm in here...", "Smells like something is burning...",
    "That was weird.", "What the heck?", "Strange..." }

local function log(message)
    print("[DYNAMIC EVENTS THREATS] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

local function loop() return KIPN.Server.EventGameLoopService end

function Threats.Multiplier(runtime)
    local difficulty = (KIPN.Shared.EventDifficulties or {})[runtime.difficulty or "NORMAL"]
    return difficulty and difficulty.multiplier or 1
end

-- Pillow's roll.
function Threats.Roll(choice)
    if choice == "NORMAL" or choice == "DIRE" or choice == "BRUTAL" then return choice end
    if choice ~= "RANDOM" then return "NORMAL" end
    if ZombRand(2) == 0 then
        return ZombRand(4) == 0 and "BRUTAL" or "DIRE"
    end
    return "NORMAL"
end

function Threats.InitializeRuntime(runtime, definition)
    runtime.difficulty = Threats.Roll(definition.difficulty)
    local multiplier = Threats.Multiplier(runtime)
    runtime.directorState = runtime.directorState or {}
    if multiplier > 1 then
        -- 50 = the director's baseline wave size; maxZombies caps at 300.
        runtime.directorState.waveSize = math.min(100, 50 * multiplier)
        runtime.directorState.maxZombies = math.min(300, 100 * multiplier)
    end
    runtime.threatState = { startedAtMs = now(), ambushed = {}, sieges = 0 }
    -- Bandit camps, the getaway car and raids (KIPN_EventBanditService.lua).
    if KIPN.Server.EventBanditService.Uses(definition) then KIPN.Server.EventBanditService.InitializeRuntime(runtime, definition) end
    log("InitializeRuntime() -> difficulty " .. runtime.difficulty)
end

local function alive(runtime)
    local out = {}
    for _, entry in ipairs(loop().OnlineParticipants(runtime)) do
        if not entry.dead and not (runtime.participants[entry.username] or {}).extracted then out[#out + 1] = entry end
    end
    return out
end

local function centroid(entries)
    local x, y, z = 0, 0, 0
    for _, entry in ipairs(entries) do
        x, y, z = x + entry.player:getX(), y + entry.player:getY(), entry.player:getZ()
    end
    return { x = math.floor(x / #entries), y = math.floor(y / #entries), z = math.floor(z) }
end

local function spawn(runtime, definition, origin, count, radius, walkTarget)
    local director = KIPN.Server.ZombieDirector
    if not (director and director.SpawnThemedZombies) then return 0 end
    local ok, spawned = pcall(director.SpawnThemedZombies, runtime, definition, origin, count, radius, walkTarget)
    return ok and tonumber(spawned) or 0
end

function Threats.Siege(runtime, definition)
    local players = alive(runtime)
    if #players == 0 then return 0 end
    local target = centroid(players)
    local per = Threats.SIEGE_PER_SIDE * Threats.Multiplier(runtime)
    local d = Threats.SIEGE_DISTANCE
    local total = 0
    for _, side in ipairs({ { 0, -d }, { 0, d }, { d, 0 }, { -d, 0 } }) do
        total = total + spawn(runtime, definition, { x = target.x + side[1], y = target.y + side[2], z = target.z }, per, 4, target)
    end
    runtime.threatState.sieges = runtime.threatState.sieges + 1
    loop().Announce(runtime, runtime.threatState.sieges == 1 and "They're coming from every side!" or "Another horde is closing in!", RED)
    return total
end

function Threats.Fire(runtime)
    local players = alive(runtime)
    if #players == 0 then return false end
    local victim = players[ZombRand(1, #players + 1)]
    local px, py, pz = math.floor(victim.player:getX()), math.floor(victim.player:getY()), math.floor(victim.player:getZ())
    for _ = 1, 6 do
        local dx, dy = ZombRand(-12, 13), ZombRand(-12, 13)
        if math.abs(dx) + math.abs(dy) >= 5 then
            local ok = pcall(function()
                local square = getCell():getGridSquare(px + dx, py + dy, pz)
                if not square then error("no square") end
                IsoFireManager.StartFire(getCell(), square, true, 100, 500)
            end)
            if ok then
                loop().AnnounceTo(runtime, victim.username, Threats.FIRE_LINES[ZombRand(1, #Threats.FIRE_LINES + 1)], ORANGE)
                return true
            end
        end
    end
    return false
end

function Threats.Alarm(runtime, definition)
    local director = KIPN.Server.ZombieDirector
    for _, entry in ipairs(alive(runtime)) do
        local origin = { x = math.floor(entry.player:getX()), y = math.floor(entry.player:getY()), z = math.floor(entry.player:getZ()) }
        local ok, fired = pcall(director.TriggerAlarm, runtime, definition, { origin = origin })
        if ok and fired then
            loop().Announce(runtime, "What is that?! An alarm is going off!", RED)
            return true
        end
    end
    return false
end

-- Wakes each ambush the first time a living participant comes near.
function Threats.Ambushes(runtime, definition)
    local hotspots = KIPN.Server.EventHotspotService.GetHotspots(definition, "ZOMBIE_AMBUSH")
    if #hotspots == 0 then return end
    local players = alive(runtime)
    for _, hotspot in ipairs(hotspots) do
        if not runtime.threatState.ambushed[hotspot.id] then
            local c = KIPN.Server.EventHotspotService.GetCenter(hotspot)
            for _, entry in ipairs(players) do
                local dx, dy = entry.player:getX() - c.x, entry.player:getY() - c.y
                if math.floor(entry.player:getZ()) == (c.z or 0) and dx * dx + dy * dy <= Threats.AMBUSH_RADIUS * Threats.AMBUSH_RADIUS then
                    runtime.threatState.ambushed[hotspot.id] = true
                    local g = hotspot.geometry
                    local radius = math.max(1, math.floor(math.min(math.abs(g.x2 - g.x1), math.abs(g.y2 - g.y1)) / 2))
                    local count = math.floor((tonumber(hotspot.metadata and hotspot.metadata.count) or 6) * Threats.Multiplier(runtime))
                    spawn(runtime, definition, c, count, radius, nil)
                    log("ambush " .. tostring(hotspot.id) .. " woke: " .. count)
                    break
                end
            end
        end
    end
end

function Threats.Tick(runtime, definition)
    local state = runtime.threatState
    if not state then return end
    local t = now()
    local threats = definition.threats or {}
    local difficulty = runtime.difficulty or "NORMAL"

    if not state.announced then
        state.announced = true
        if definition.difficulty and definition.difficulty ~= "NORMAL" then
            local info = KIPN.Shared.EventDifficulties[difficulty]
            loop().Announce(runtime, "Difficulty: " .. string.upper(info.label) .. (difficulty == "NORMAL" and ". You got lucky." or "."),
                difficulty == "NORMAL" and { 0.45, 0.9, 0.45 } or RED, nil, info.sound)
        end
    end

    if threats.SIEGE and t - state.startedAtMs >= Threats.FIRST_SIEGE_MS
        and (not state.lastSiegeMs or t - state.lastSiegeMs >= Threats.SIEGE_EVERY_MS[difficulty]) then
        state.lastSiegeMs = t
        Threats.Siege(runtime, definition)
    end
    if threats.FIRES and t - state.startedAtMs >= 60000
        and (not state.lastFireMs or t - state.lastFireMs >= Threats.FIRE_EVERY_MS[difficulty]) then
        state.lastFireMs = t
        Threats.Fire(runtime)
    end
    if threats.ALARM and not state.alarmed and t - state.startedAtMs >= Threats.ALARM_AFTER_MS[difficulty] then
        -- Keeps trying until a player is inside a building.
        state.alarmed = Threats.Alarm(runtime, definition)
    end
    Threats.Ambushes(runtime, definition)
end

function Threats.Initialize()
    log("Initialize()")
    return true
end

log("module loaded")
