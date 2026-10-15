-- KIPN_EventBanditService.lua
--
-- Bandits: raider crews that disrupt a story or are the story. Built the
-- way the careers threats are (KIPNCareers_Threats.lua in Careers
-- Framework): each bandit is a server-spawned zombie in a raider outfit,
-- kept calm (useless) until provoked, that talks, carries loot and drops
-- it where it falls. Nothing else is needed on the client except the
-- speech line (client/KIPN_EventBanditClient.lua).
--
--   BANDIT_CAMP     a crew waits here. Calm until a participant comes
--                   within PROVOKE_RADIUS or hits one of them; then the
--                   whole crew fights.
--   BANDIT_VEHICLE  the getaway car, parked here, guarded by a crew. In
--                   The Heist its trunk holds the gold and the leader
--                   carries the key.
--   BANDITS threat  a raiding crew arrives every few minutes (sooner on
--                   Dire and Brutal) and hunts the players. The leader
--                   carries supplies worth taking.
--   SPAWN_BANDITS   story action: a crew arrives at the trigger's spot.
--
-- Camps and the car appear the first time their square is loaded (a
-- player within a few chunks), so a far-off hideout still works. Bodies
-- still standing, the car and any gold are removed when the event ends.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"
require "KIPN_EventHotspotService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventBanditService = KIPN.Server.EventBanditService or {}

local Bandits = KIPN.Server.EventBanditService

Bandits.TAG = "DE_Bandit"
Bandits.GOLD_TAG = "DE_HeistGold"
Bandits.PROVOKE_RADIUS = 10
Bandits.HUNT_RADIUS = 45
Bandits.SAY_RADIUS = 40
Bandits.THINK_MS = 1000
Bandits.FIRST_RAID_MS = 2 * 60000
Bandits.RAID_EVERY_MS = { NORMAL = 7 * 60000, DIRE = 5 * 60000, BRUTAL = 7 * 30000 }
Bandits.RAID_DISTANCE = { 22, 32 }
Bandits.HEALTH = { NORMAL = 1.0, DIRE = 1.3, BRUTAL = 1.6 }

-- Vanilla B42 outfits: rougher and better armed as difficulty rises.
Bandits.OUTFITS = {
    NORMAL = { "Punk", "Thug", "Redneck", "Biker", "Bandit_Early" },
    DIRE = { "Biker", "Bandit_Mid", "Raider", "Thug", "HockeyPsycho" },
    BRUTAL = { "Bandit_Late", "Raider", "PrivateMilitia", "Survivalist_Late" },
}

Bandits.LINES = {
    calm = { "Keep it down.", "Nobody followed us.", "Split it when we're clear.", "Quiet night." },
    provoked = { "We've got company!", "Waste 'em!", "Nobody takes our score!", "Get 'em!" },
    raid = { "Everything you've got!", "There they are!", "Take what they're carrying!", "Nobody walks away!" },
    heist = { "That gold is ours!", "Protect the car!", "They followed us!" },
    down = { "Man down!", "They got Eddie!", "Keep shooting!" },
}

-- What a raiding leader carries: worth taking.
Bandits.SUPPLIES = { "Base.Bandage", "Base.Pills", "Base.TinnedBeans", "Base.CannedChili", "Base.WaterBottle",
    "Base.Bullets9mmBox", "Base.ShotgunShellsBox", "Base.Lighter", "Base.Cigarettes", "Base.Money" }

local RED = { 1.0, 0.42, 0.42 }
local ORANGE = { 1.0, 0.6, 0.25 }

local function log(message)
    print("[DYNAMIC EVENTS BANDITS] " .. tostring(message))
end

local function now()
    return (type(getTimestampMs) == "function" and getTimestampMs()) or 0
end

local function loop() return KIPN.Server.EventGameLoopService end

local function difficulty(runtime)
    local key = runtime.difficulty or "NORMAL"
    return Bandits.OUTFITS[key] and key or "NORMAL"
end

local function pick(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end

local function square(x, y, z)
    local ok, sq = pcall(function() return getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0)) end)
    return ok and sq or nil
end

local function standable(sq)
    if not sq then return false end
    local ok, free = pcall(function() return sq:isFree(false) end)
    return ok and free == true
end

local function state(runtime)
    runtime.banditState = runtime.banditState or { crews = {}, sequence = 0, placed = {}, thinkAt = 0 }
    return runtime.banditState
end

-- Living participants: { username, player }.
local function hunters(runtime)
    local out = {}
    local list = loop() and loop().OnlineParticipants(runtime) or {}
    for _, entry in ipairs(list) do
        if not entry.dead and not (runtime.participants[entry.username] or {}).extracted then out[#out + 1] = entry end
    end
    return out
end

------------------------------------------------------------
-- SPEECH (display only)
------------------------------------------------------------

function Bandits.Say(member, text)
    if not member or not member.zombie or not text or text == "" then return end
    if not isServer() then
        pcall(function() member.zombie:addLineChatElement(text, 1.0, 0.45, 0.4) end)
        return
    end
    local ok, onlineId = pcall(function() return member.zombie:getOnlineID() end)
    local online = type(getOnlinePlayers) == "function" and getOnlinePlayers() or nil
    if not ok or not online then return end
    for i = 0, online:size() - 1 do
        local p = online:get(i)
        local dx, dy = p:getX() - member.x, p:getY() - member.y
        if dx * dx + dy * dy <= Bandits.SAY_RADIUS * Bandits.SAY_RADIUS then
            KIPN.Server.SendToPlayer(p, KIPN.Shared.ResponseEvents.EVENT_BANDIT_SAY, { id = onlineId, text = tostring(text) })
        end
    end
end

local function living(crew)
    local out = {}
    for _, member in ipairs(crew.members) do
        if not member.state then out[#out + 1] = member end
    end
    return out
end

function Bandits.SayRandom(crew, lines)
    local member = pick(living(crew))
    if member then Bandits.Say(member, pick(lines)) end
end

------------------------------------------------------------
-- CREWS
------------------------------------------------------------

-- A free square in a ring around `center`, or nil.
function Bandits.FindSpot(center, minDistance, maxDistance)
    for _ = 1, 30 do
        local angle = ZombRand(3600) / 3600 * math.pi * 2
        local reach = minDistance + ZombRand(math.max(1, maxDistance - minDistance + 1))
        local x = math.floor(center.x + math.cos(angle) * reach)
        local y = math.floor(center.y + math.sin(angle) * reach)
        if standable(square(x, y, center.z or 0)) then return { x = x, y = y, z = center.z or 0 } end
    end
    return nil
end

local function pathTo(member, point)
    if not point then return end
    pcall(function() member.zombie:pathToLocationF(point.x + 0.5, point.y + 0.5, point.z or 0) end)
end

local function spawnMember(runtime, crew, point)
    local x, y = point.x + ZombRand(3) - 1, point.y + ZombRand(3) - 1
    if not standable(square(x, y, point.z)) then x, y = point.x, point.y end
    local outfit = pick(Bandits.OUTFITS[difficulty(runtime)]) or "Thug"
    local ok, list = pcall(addZombiesInOutfit, x, y, point.z or 0, 1, outfit, 25)
    local zombie = ok and list and list:size() > 0 and list:get(0) or nil
    if not zombie then
        log("spawn failed " .. tostring(outfit) .. ": " .. tostring(not ok and list or "empty"))
        return nil
    end
    pcall(function()
        zombie:getModData()[Bandits.TAG] = runtime.instanceId or runtime.eventDefinitionId or "sim"
        if crew.calm then zombie:setUseless(true) end
        local scale = Bandits.HEALTH[difficulty(runtime)] or 1
        if scale ~= 1 then zombie:setHealth(zombie:getHealth() * scale) end
    end)
    local member = { zombie = zombie, carrying = {}, x = x, y = y, z = point.z or 0 }
    crew.members[#crew.members + 1] = member
    return member
end

-- Spawns a crew. opts: { center, count, calm, kind, label, target, carry = { fullTypes }, gold }
-- Returns the crew, or nil if nobody could be placed.
function Bandits.SpawnCrew(runtime, definition, opts)
    local s = state(runtime)
    s.sequence = s.sequence + 1
    local crew = { id = "crew" .. s.sequence, kind = opts.kind or "raid", label = opts.label or "Bandits", calm = opts.calm == true,
        center = opts.center, target = opts.target, members = {}, hotspotId = opts.hotspotId }
    local count = math.max(1, math.min(12, math.floor(tonumber(opts.count) or 3)))
    for _ = 1, count do spawnMember(runtime, crew, opts.center) end
    if #crew.members == 0 then return nil end
    -- The first bandit leads: loot, key and gold travel with them.
    crew.leader = crew.members[1]
    for _, fullType in ipairs(opts.carry or {}) do
        local ok, item = pcall(function() return instanceItem(fullType) end)
        if ok and item then
            if opts.gold then pcall(function() item:getModData()[Bandits.GOLD_TAG] = true end) end
            crew.leader.carrying[#crew.leader.carrying + 1] = item
        end
    end
    if crew.target then
        for _, member in ipairs(crew.members) do pathTo(member, crew.target) end
    end
    s.crews[#s.crews + 1] = crew
    log(crew.kind .. " crew " .. crew.id .. " x" .. #crew.members .. " at " .. opts.center.x .. "," .. opts.center.y)
    return crew
end

-- A hostile crew arrives near `origin` and heads for it (story action).
function Bandits.Arrive(runtime, definition, origin, count)
    local spot = Bandits.FindSpot(origin, 12, 20) or (standable(square(origin.x, origin.y, origin.z)) and origin)
    if not spot then return nil end
    local crew = Bandits.SpawnCrew(runtime, definition, { center = spot, count = count, kind = "story", target = origin,
        carry = { pick(Bandits.SUPPLIES) } })
    if crew then
        Bandits.SayRandom(crew, Bandits.LINES.raid)
        if loop() then loop().Announce(runtime, "Bandits! A crew is heading your way.", RED) end
    end
    return crew
end

function Bandits.Provoke(runtime, crew, prey)
    if not crew.calm then return end
    crew.calm = false
    for _, member in ipairs(living(crew)) do
        pcall(function() member.zombie:setUseless(false) end)
        if prey then pcall(function() member.zombie:setTarget(prey) end) end
    end
    Bandits.SayRandom(crew, crew.kind == "heist" and Bandits.LINES.heist or Bandits.LINES.provoked)
    if loop() then loop().Announce(runtime, crew.label .. " spotted you!", RED) end
end

local function dropCarried(member)
    if #member.carrying == 0 then return end
    local sq = square(member.x, member.y, member.z)
    if not sq then return end
    for _, item in ipairs(member.carrying) do
        pcall(function() sq:AddWorldInventoryItem(item, 0.3 + ZombRand(5) / 10, 0.3 + ZombRand(5) / 10, 0) end)
    end
    member.carrying = {}
end

local function memberStatus(member)
    local ok, dead, sq = pcall(function() return member.zombie:isDead(), member.zombie:getCurrentSquare() end)
    if not ok or dead then return "dead" end
    if not sq then return "gone" end
    member.x, member.y, member.z = sq:getX(), sq:getY(), sq:getZ()
    return "alive"
end

local function nearest(entries, x, y, radius)
    local best, bestDistance
    for _, entry in ipairs(entries) do
        local dx, dy = entry.player:getX() - x, entry.player:getY() - y
        local distance = dx * dx + dy * dy
        if distance <= radius * radius and (not bestDistance or distance < bestDistance) then best, bestDistance = entry, distance end
    end
    return best
end

local function thinkCrew(runtime, crew, players)
    for _, member in ipairs(crew.members) do
        if not member.state then
            local status = memberStatus(member)
            if status == "dead" then
                member.state = "dead"
                dropCarried(member)
                if member == crew.leader and crew.kind == "heist" and loop() then
                    loop().Announce(runtime, "The leader is down. They had the car key on them.", ORANGE)
                end
                Bandits.SayRandom(crew, Bandits.LINES.down)
            elseif status == "gone" then
                member.state = "gone"
            elseif crew.calm then
                local okA, attacker = pcall(function() return member.zombie:getAttackedBy() end)
                local close = nearest(players, member.x, member.y, Bandits.PROVOKE_RADIUS)
                if okA and attacker and instanceof(attacker, "IsoPlayer") then
                    Bandits.Provoke(runtime, crew, attacker)
                elseif close then
                    Bandits.Provoke(runtime, crew, close.player)
                end
            else
                local prey = nearest(players, member.x, member.y, Bandits.HUNT_RADIUS)
                local okT, target = pcall(function() return member.zombie:getTarget() end)
                if prey and (not okT or target == nil) then
                    pcall(function() member.zombie:setTarget(prey.player) end)
                    pathTo(member, { x = math.floor(prey.player:getX()), y = math.floor(prey.player:getY()), z = math.floor(prey.player:getZ()) })
                end
            end
        end
    end
    if not crew.defeated and #living(crew) == 0 then
        crew.defeated = true
        local killed = 0
        for _, member in ipairs(crew.members) do if member.state == "dead" then killed = killed + 1 end end
        if killed > 0 and loop() then
            loop().Announce(runtime, crew.label .. " wiped out." .. (crew.kind == "raid" and " Check the leader for supplies." or ""), { 0.45, 0.9, 0.45 })
        end
    end
end

------------------------------------------------------------
-- HOTSPOTS: camps and the getaway car
------------------------------------------------------------

local function heist(definition)
    return definition.mode == "EXTRACTION" and definition.variant == "HEIST"
end

local function placeGold(container, count, runtime)
    local added = 0
    for _ = 1, count do
        local ok = pcall(function()
            local item = container:AddItem(KIPN.Shared.EventHeist.item)
            item:getModData()[Bandits.GOLD_TAG] = true
            if isServer() and type(sendAddItemToContainer) == "function" then sendAddItemToContainer(container, item) end
        end)
        if ok then added = added + 1 end
    end
    state(runtime).goldPlaced = (state(runtime).goldPlaced or 0) + added
    return added
end

-- Parks the getaway car, gold in the trunk; the key goes to the leader.
function Bandits.PlaceVehicle(runtime, definition, hotspot)
    local c = KIPN.Server.EventHotspotService.GetCenter(hotspot)
    local sq = square(c.x, c.y, c.z)
    if not sq then return nil end
    local ok, vehicle = pcall(function()
        return addVehicleDebug(KIPN.Shared.EventHeist.vehicle, IsoDirections.S, nil, sq)
    end)
    if not ok or not vehicle then
        log("vehicle spawn failed: " .. tostring(vehicle))
        return nil
    end
    local s = state(runtime)
    s.vehicles = s.vehicles or {}
    s.vehicles[#s.vehicles + 1] = vehicle
    pcall(function() vehicle:repair() end)
    local key
    pcall(function() key = vehicle:createVehicleKey() end)
    if heist(definition) then
        local trunk
        pcall(function() trunk = vehicle:getPartById("TruckBed"):getItemContainer() end)
        if trunk then
            placeGold(trunk, KIPN.Shared.EventHeist.count, runtime)
        else
            s.goldOnLeader = true
        end
    end
    return vehicle, key, c
end

-- Places each camp and the car the first time its square is loaded.
function Bandits.PlaceHotspots(runtime, definition)
    local s = state(runtime)
    for _, hotspotType in ipairs({ "BANDIT_VEHICLE", "BANDIT_CAMP" }) do
        for _, hotspot in ipairs(KIPN.Server.EventHotspotService.GetHotspots(definition, hotspotType)) do
            if not s.placed[hotspot.id] then
                local c = KIPN.Server.EventHotspotService.GetCenter(hotspot)
                if square(c.x, c.y, c.z) then
                    s.placed[hotspot.id] = true
                    local carry, key = {}, nil
                    local count = tonumber(hotspot.metadata and hotspot.metadata.count) or 4
                    local label = "The bandits"
                    if hotspotType == "BANDIT_VEHICLE" then
                        local _, vehicleKey = Bandits.PlaceVehicle(runtime, definition, hotspot)
                        key = vehicleKey
                        label = "The getaway crew"
                    end
                    if heist(definition) and (s.goldOnLeader or (hotspotType == "BANDIT_CAMP" and not s.goldPlaced and #KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_VEHICLE") == 0)) then
                        for _ = 1, KIPN.Shared.EventHeist.count do carry[#carry + 1] = KIPN.Shared.EventHeist.item end
                        s.goldOnLeader = false
                        s.goldPlaced = (s.goldPlaced or 0) + KIPN.Shared.EventHeist.count
                    end
                    local spot = Bandits.FindSpot(c, 2, 4) or c
                    local crew = Bandits.SpawnCrew(runtime, definition, { center = spot, count = count, calm = true,
                        kind = heist(definition) and "heist" or "camp", label = label, carry = carry, gold = #carry > 0, hotspotId = hotspot.id })
                    if crew and key then crew.leader.carrying[#crew.leader.carrying + 1] = key end
                    if crew then Bandits.SayRandom(crew, Bandits.LINES.calm) end
                end
            end
        end
    end
end

------------------------------------------------------------
-- RAIDS (the BANDITS threat)
------------------------------------------------------------

function Bandits.Raid(runtime, definition)
    local players = hunters(runtime)
    if #players == 0 then return nil end
    local victim = players[ZombRand(#players) + 1]
    local at = { x = math.floor(victim.player:getX()), y = math.floor(victim.player:getY()), z = math.floor(victim.player:getZ()) }
    local spot = Bandits.FindSpot(at, Bandits.RAID_DISTANCE[1], Bandits.RAID_DISTANCE[2])
    if not spot then return nil end
    local multiplier = KIPN.Server.EventThreatService and KIPN.Server.EventThreatService.Multiplier(runtime) or 1
    local crew = Bandits.SpawnCrew(runtime, definition, { center = spot, count = 1 + multiplier + ZombRand(2), kind = "raid",
        label = "The raiders", target = at, carry = { pick(Bandits.SUPPLIES), pick(Bandits.SUPPLIES) } })
    if crew then
        Bandits.SayRandom(crew, Bandits.LINES.raid)
        loop().Announce(runtime, "Bandits! A raiding crew is coming for " .. victim.username .. ".", RED)
    end
    return crew
end

------------------------------------------------------------
-- LIFECYCLE (called from KIPN_EventThreatService.lua)
------------------------------------------------------------

function Bandits.InitializeRuntime(runtime, definition)
    local s = state(runtime)
    s.startedAtMs = now()
    if heist(definition) then s.heist = true end
end

function Bandits.Uses(definition)
    if (definition.threats or {}).BANDITS then return true end
    if heist(definition) then return true end
    return #KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_CAMP") > 0
        or #KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_VEHICLE") > 0
end

function Bandits.Tick(runtime, definition)
    local s = runtime.banditState
    if not s then return end
    local t = now()
    if t < s.thinkAt then return end
    s.thinkAt = t + Bandits.THINK_MS
    Bandits.PlaceHotspots(runtime, definition)
    if (definition.threats or {}).BANDITS and t - (s.startedAtMs or t) >= Bandits.FIRST_RAID_MS
        and (not s.lastRaidMs or t - s.lastRaidMs >= Bandits.RAID_EVERY_MS[difficulty(runtime)]) then
        s.lastRaidMs = t
        Bandits.Raid(runtime, definition)
    end
    local players = hunters(runtime)
    for _, crew in ipairs(s.crews) do
        if not crew.defeated then thinkCrew(runtime, crew, players) end
    end
end

-- Living bandits, for HUDs and simulations: { x, y, z, crewId, calm }.
function Bandits.Positions(runtime)
    local out = {}
    for _, crew in ipairs((runtime.banditState or {}).crews or {}) do
        for _, member in ipairs(living(crew)) do
            local ok, id = pcall(function() return member.zombie:getOnlineID() end)
            out[#out + 1] = { x = member.x, y = member.y, z = member.z, id = ok and id or nil, calm = crew.calm }
        end
    end
    return out
end

------------------------------------------------------------
-- THE HEIST: gold
------------------------------------------------------------

local function eachItem(inventory, visit)
    local ok, items = pcall(function() return inventory:getItems() end)
    if not ok or not items then return end
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if item then
            visit(item, inventory)
            local okInner, inner = pcall(function() return item:getInventory() end)
            if okInner and inner then eachItem(inner, visit) end
        end
    end
end

local function isGold(item)
    local ok, tagged = pcall(function() return item:getModData()[Bandits.GOLD_TAG] == true end)
    return ok and tagged
end

function Bandits.GoldCarried(player)
    local count = 0
    eachItem(player:getInventory(), function(item) if isGold(item) then count = count + 1 end end)
    return count
end

-- Takes the gold off a player (it has been delivered). Returns how much.
function Bandits.TakeGold(player)
    local taken = 0
    eachItem(player:getInventory(), function(item, container)
        if isGold(item) then
            pcall(function()
                container:Remove(item)
                if isServer() and type(sendRemoveItemFromContainer) == "function" then sendRemoveItemFromContainer(container, item) end
            end)
            taken = taken + 1
        end
    end)
    return taken
end

-- Where the car was parked, for the "witness" hint.
function Bandits.GetawaySpot(definition)
    local spots = KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_VEHICLE")
    if #spots == 0 then spots = KIPN.Server.EventHotspotService.GetHotspots(definition, "BANDIT_CAMP") end
    return spots[1] and KIPN.Server.EventHotspotService.GetCenter(spots[1]) or nil
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

function Bandits.CleanupRuntime(runtime)
    local s = runtime.banditState
    if not s then return 0 end
    local removed = 0
    for _, crew in ipairs(s.crews) do
        for _, member in ipairs(crew.members) do
            if not member.state then
                pcall(function()
                    member.zombie:removeFromWorld()
                    member.zombie:removeFromSquare()
                end)
                removed = removed + 1
            end
            member.state = member.state or "removed"
        end
    end
    for _, vehicle in ipairs(s.vehicles or {}) do
        pcall(function() vehicle:permanentlyRemove() end)
    end
    -- Gold still on participants goes back to the bank.
    for _, entry in ipairs(loop() and loop().OnlineParticipants(runtime) or {}) do
        pcall(Bandits.TakeGold, entry.player)
    end
    runtime.banditState = nil
    log("CleanupRuntime() -> removed " .. removed .. " bandits")
    return removed
end

-- Bandits think every THINK_MS, faster than the runtime's own tick,
-- so a fight reacts in about a second.
local function onTick()
    local runtimes = KIPN.Server.EventRuntimeService and KIPN.Server.EventRuntimeService.ActiveRuntimes or {}
    for id, runtime in pairs(runtimes) do
        if runtime.banditState then
            local definition = KIPN.Server.EventScenarioService.GetDefinition(id)
            if definition then
                local ok, err = pcall(Bandits.Tick, runtime, definition)
                if not ok then log("tick failed: " .. tostring(err)) end
            end
        end
    end
end

function Bandits.Initialize()
    if Events.OnTick then Events.OnTick.Add(onTick) end
    log("Initialize()")
    return true
end

log("module loaded")

return Bandits
