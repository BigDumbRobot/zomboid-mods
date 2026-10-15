-- KIPNCareers_Threats.lua  (framework core)
--
-- Server-authoritative threats for every career: thieves, raiders, rival
-- crews and ambushes. The server decides everything -- whether an incident
-- happens, who shows up, what is stolen or damaged, what is recovered -- and
-- the bodies are server-spawned zombies dressed as people (kept passive while
-- thieves sneak in). No other NPC mod is involved. Customers are never bodies:
-- they are the server-created work orders on a business's KIPN page, and
-- RollTemperament decides how they behave when their order is completed.
-- The only client code is KIPNCareers_ThreatsClient.lua, which draws the
-- speech lines this file sends and decides nothing.
--
-- Pacing, so incidents stay unpredictable without piling up:
--   * a new business has a grace period (ThreatNewBusinessGraceHours);
--   * after an incident a business stays calm for a random window between
--     ThreatMinCalmHours and ThreatMaxCalmHours (shorter at higher tiers);
--   * after that, every 10-minute check has a small tier-scaled chance, and
--     only while the owner is online and near the business;
--   * losses are capped (ThreatMaxLossPercent), and stolen goods drop where a
--     thief dies, so a fast response gets everything back.
--
-- Tier comes from the career's own reputation (0-100): 1 below 25, 2 below
-- 50, 3 below 75, 4 above. Higher tiers bring bigger, tougher, better-equipped
-- crews and bolder thefts.
--
-- A career opts in by registering (see README "Threats"):
--
--   KIPNCareers.Threats.Register("mechanic", {
--       businesses = function() return state().shops end, -- { [id] = { id, ownerKey, bounds, anchor, active, createdAt } }
--       reputation = function(ownerKey) return reputationFor(ownerKey) end,
--       notify     = function(ownerKey, title, body) notify(ownerKey, title, body) end,
--       events     = { { id = "thieves", weight = 1, minTier = 1, run = function(ctx) return Threats.Presets.Thieves(ctx, {}) end } },
--   })
--
-- The scheduler then rolls `events` on its own. For moments a career owns (a
-- completed work order, a drug drop) it calls Threats.RollMoment / Threats.Context
-- and starts an incident itself with a preset or Threats.StartIncident.
--
-- Incidents live in memory: a server restart ends them (their bodies stay in
-- the world as ordinary zombies). Only pacing is persisted, in
-- KIPN.Server.GetData().careers.threats.

if isClient() and not isServer() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_Economy"

local Shared = KIPNCareers.Shared
local Economy = KIPNCareers.Economy
local Threats = KIPNCareers.Threats or {}
KIPNCareers.Threats = Threats
Threats._careers = Threats._careers or {}
Threats._incidents = Threats._incidents or {}
Threats.Presets = Threats.Presets or {}

local ARRIVE_DISTANCE = 3
local ESCAPE_DISTANCE = 45
local SAY_RADIUS = 40
local REPATH_MINUTES = 3
local HARD_LIFETIME_MINUTES = 300
local sequence = 0

-- Per-tier profile. rollPercent is the chance per 10-minute check once a
-- business is out of its calm window and the owner is nearby.
Threats.Tiers = {
    { rollPercent = 3, group = { 1, 2 }, health = 1.0, loot = { 1, 3 }, damage = { 1, 2 }, calmScale = 1.25 },
    { rollPercent = 4, group = { 1, 3 }, health = 1.2, loot = { 2, 4 }, damage = { 1, 3 }, calmScale = 1.0 },
    { rollPercent = 5, group = { 2, 4 }, health = 1.4, loot = { 2, 6 }, damage = { 2, 4 }, calmScale = 0.85 },
    { rollPercent = 6, group = { 3, 5 }, health = 1.7, loot = { 3, 8 }, damage = { 2, 5 }, calmScale = 0.7 },
}

-- Vanilla B42 outfits. Crews look rougher and better equipped as tiers rise.
Threats.Outfits = {
    raiders = {
        { "Punk", "Thug", "Hobbo", "Redneck", "InmateEscaped" },
        { "Thug", "Biker", "Redneck", "Bandit_Early", "Mob" },
        { "Biker", "Bandit_Mid", "Raider", "MobCasual", "HockeyPsycho" },
        { "Bandit_Late", "Raider", "PrivateMilitia", "Survivalist_Late", "Survivalist03_Late" },
    },
    thieves = { "Punk", "Thug", "Hobbo", "BankRobber", "Grunge", "Student", "InmateEscaped" },
    enforcers = { "Mob", "MobCasual", "BankRobberSuit", "Classy", "Thug" },
}

local PASSIVE_COLOR = { r = 0.9, g = 0.9, b = 0.8 }
local HOSTILE_COLOR = { r = 1.0, g = 0.45, b = 0.4 }

local function log(level, message)
    Shared.Log("Threats", level, message)
end

------------------------------------------------------------
-- SMALL HELPERS
------------------------------------------------------------

local function nowHours()
    if type(getGameTime) == "function" and getGameTime() then
        return tonumber(getGameTime():getWorldAgeHours()) or 0
    end
    return 0
end

local function randomInteger(minimum, maximum)
    minimum = math.floor(tonumber(minimum) or 0)
    maximum = math.floor(tonumber(maximum) or minimum)
    if maximum < minimum then minimum, maximum = maximum, minimum end
    return ZombRand(minimum, maximum + 1)
end

local function randomFloat(minimum, maximum)
    return minimum + (maximum - minimum) * (ZombRand(10001) / 10000)
end

local function chance(percent)
    return ZombRand(10000) < math.floor((tonumber(percent) or 0) * 100)
end

local function choice(list)
    if type(list) ~= "table" or #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end

local function distance(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function inBounds(bounds, x, y)
    return type(bounds) == "table" and x >= bounds.x1 and x <= bounds.x2 and y >= bounds.y1 and y <= bounds.y2
end

local function loadedSquare(x, y, z)
    local cell = type(getCell) == "function" and getCell() or nil
    if not cell or not x or not y then return nil end
    return cell:getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
end

-- Same owner key every career uses (the server account; see Host.Identity).
local function identity(player)
    return KIPNCareers.Host.Identity(player)
end

local function eachPlayer(visit)
    if isServer() and type(getOnlinePlayers) == "function" then
        local players = getOnlinePlayers()
        for index = 0, (players and players:size() or 0) - 1 do
            if visit(players:get(index)) then return end
        end
    elseif type(getNumActivePlayers) == "function" then
        for index = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(index)
            if player and visit(player) then return end
        end
    end
end

local function livingPlayer(player)
    local ok, dead = pcall(player.isDead, player)
    return ok and not dead
end

local function playerNear(x, y, radius)
    local found
    eachPlayer(function(player)
        if livingPlayer(player) and distance(player:getX(), player:getY(), x, y) <= radius then
            found = player
            return true
        end
    end)
    return found
end

------------------------------------------------------------
-- SETTINGS / TIERS
------------------------------------------------------------

function Threats.Settings()
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    local d = Shared.Defaults
    local minCalm = math.max(1, tonumber(raw.ThreatMinCalmHours) or d.THREAT_MIN_CALM_HOURS)
    return {
        Enabled = raw.ThreatsEnabled ~= false,
        FrequencyPercent = Shared.Clamp(raw.ThreatFrequencyPercent or d.THREAT_FREQUENCY_PERCENT, 0, 300),
        MinCalmHours = minCalm,
        MaxCalmHours = math.max(minCalm, tonumber(raw.ThreatMaxCalmHours) or d.THREAT_MAX_CALM_HOURS),
        GraceHours = math.max(0, tonumber(raw.ThreatNewBusinessGraceHours) or d.THREAT_GRACE_HOURS),
        MaxLossPercent = Shared.Clamp(raw.ThreatMaxLossPercent or d.THREAT_MAX_LOSS_PERCENT, 0, 100),
        OwnerRadius = math.max(10, tonumber(raw.ThreatOwnerRadius) or d.THREAT_OWNER_RADIUS),
    }
end

function Threats.Tier(reputation)
    reputation = tonumber(reputation) or 0
    if reputation >= 75 then return 4 end
    if reputation >= 50 then return 3 end
    if reputation >= 25 then return 2 end
    return 1
end

------------------------------------------------------------
-- PERSISTED PACING  (careers.threats.businesses[careerId:businessId])
------------------------------------------------------------

local function threatData()
    if not KIPN or not KIPN.Server or type(KIPN.Server.GetData) ~= "function" then return nil end
    local root = KIPN.Server.GetData()
    if type(root) ~= "table" then return nil end
    root.careers = type(root.careers) == "table" and root.careers or {}
    local data = type(root.careers.threats) == "table" and root.careers.threats or {}
    root.careers.threats = data
    data.businesses = type(data.businesses) == "table" and data.businesses or {}
    return data
end

local function save()
    if KIPN and KIPN.Server and type(KIPN.Server.Save) == "function" then
        local ok, res = pcall(KIPN.Server.Save)
        if ok and res == true then return true end
        log("Error", "KIPN.Server.Save failed result=" .. tostring(res))
    end
    return false
end

local function pacing(key, business)
    local data = threatData()
    if not data then return nil end
    local record = data.businesses[key]
    if type(record) ~= "table" then
        local opened = tonumber(business and business.createdAt) or nowHours()
        record = { graceUntil = opened + Threats.Settings().GraceHours, calmUntil = 0, momentCalmUntil = 0, heat = 0, heatAt = nowHours(), incidents = 0 }
        data.businesses[key] = record
    end
    return record
end

local function currentHeat(record)
    local elapsed = math.max(0, nowHours() - (tonumber(record.heatAt) or nowHours()))
    return (tonumber(record.heat) or 0) * (0.5 ^ (elapsed / 24)) -- halves every in-game day
end

local function keyFor(careerId, business)
    return tostring(careerId) .. ":" .. tostring(business and business.id)
end

-- Business activity (a completed order, a delivery) makes a business a
-- likelier target for a while. Heat halves every in-game day.
function Threats.AddHeat(careerId, business, amount)
    local record = pacing(keyFor(careerId, business), business)
    if not record then return end
    record.heat = currentHeat(record) + (tonumber(amount) or 1)
    record.heatAt = nowHours()
end

function Threats.IsBusy(key)
    for _, incident in pairs(Threats._incidents) do
        if incident.key == key then return true end
    end
    return false
end

------------------------------------------------------------
-- REGISTRY / CONTEXT
------------------------------------------------------------

function Threats.Register(careerId, definition)
    if type(careerId) ~= "string" or careerId == "" or type(definition) ~= "table"
        or type(definition.businesses) ~= "function" or type(definition.reputation) ~= "function"
        or type(definition.notify) ~= "function"
    then
        log("Error", "Register ignored: careerId, businesses, reputation and notify are required")
        return false
    end
    definition.events = type(definition.events) == "table" and definition.events or {}
    Threats._careers[careerId] = definition
    log("Info", "Registered threats career=" .. careerId .. " events=" .. tostring(#definition.events))
    return true
end

-- The owner if they are online, alive and within `radius` tiles of the business.
function Threats.OwnerNear(business, radius)
    local found
    local anchor = business and business.anchor
    if type(anchor) ~= "table" then return nil end
    radius = radius or Threats.Settings().OwnerRadius
    eachPlayer(function(player)
        if identity(player) == business.ownerKey and livingPlayer(player)
            and distance(player:getX(), player:getY(), anchor.x, anchor.y) <= radius
        then
            found = player
            return true
        end
    end)
    return found
end

-- Everything an incident needs about one business. `player` overrides the
-- owner lookup (a dealer at a drop point far from the storefront).
function Threats.Context(careerId, business, player)
    local career = Threats._careers[careerId]
    if not career or type(business) ~= "table" or type(business.anchor) ~= "table" then return nil end
    local ok, reputation = pcall(career.reputation, business.ownerKey)
    reputation = ok and tonumber(reputation) or 0
    local tier = Threats.Tier(reputation)
    return {
        careerId = careerId, career = career, business = business,
        key = keyFor(careerId, business), tier = tier, profile = Threats.Tiers[tier],
        reputation = reputation, settings = Threats.Settings(),
        owner = player or Threats.OwnerNear(business),
    }
end

function Threats.Notify(ctx, title, body)
    local ok, err = pcall(ctx.career.notify, ctx.business.ownerKey, title, body)
    if not ok then log("Error", "notify failed career=" .. tostring(ctx.careerId) .. " error=" .. tostring(err)) end
end

-- True when the business may take an unscripted hit right now: out of its
-- grace period and not straight after another incident.
function Threats.CanEscalate(ctx)
    local config = ctx and ctx.settings or Threats.Settings()
    if not ctx or not config.Enabled then return false end
    local record = pacing(ctx.key, ctx.business)
    if not record then return false end
    local now = nowHours()
    return now >= (tonumber(record.graceUntil) or 0)
        and now >= (tonumber(record.momentCalmUntil) or 0)
        and now >= (tonumber(record.lastIncidentAt) or -1000) + config.MinCalmHours / 2
        and not Threats.IsBusy(ctx.key)
end

-- A moment a career owns (pickup, drop) rolls `percent` scaled by tier and
-- ThreatFrequencyPercent. Returns a context on success, nil otherwise.
function Threats.RollMoment(careerId, business, percent, player)
    local config = Threats.Settings()
    if not config.Enabled or config.FrequencyPercent <= 0 then return nil end
    local ctx = Threats.Context(careerId, business, player)
    if not ctx or not ctx.owner or not Threats.CanEscalate(ctx) then return nil end
    local scaled = (tonumber(percent) or 0) * (0.6 + 0.2 * ctx.tier) * (config.FrequencyPercent / 100)
    if not chance(scaled) then return nil end
    local record = pacing(ctx.key, business)
    record.momentCalmUntil = nowHours() + randomFloat(4, 12)
    save()
    log("Info", "RollMoment hit key=" .. ctx.key .. " tier=" .. tostring(ctx.tier) .. " percent=" .. string.format("%.1f", scaled))
    return ctx
end

-- Called by a career after it started an incident on its own (moments), so
-- the scheduler honours the calm window afterwards.
function Threats.MarkIncident(ctx)
    local record = pacing(ctx.key, ctx.business)
    if not record then return end
    local config = ctx.settings
    local now = nowHours()
    record.lastIncidentAt = now
    record.calmUntil = math.max(tonumber(record.calmUntil) or 0,
        now + randomFloat(config.MinCalmHours, config.MaxCalmHours) * ctx.profile.calmScale)
    record.incidents = (tonumber(record.incidents) or 0) + 1
    record.heat = currentHeat(record) * 0.5
    record.heatAt = now
    save()
end

------------------------------------------------------------
-- BODIES
------------------------------------------------------------

local function standable(square, requireOutside)
    if not square then return false end
    local okFree, free = pcall(square.isFree, square, false)
    if not okFree or not free then return false end
    if not requireOutside then return true end
    local okOut, outside = pcall(square.isOutside, square)
    return okOut and outside == true
end

-- A random loaded, walkable square in a ring around `center`, outside `bounds`.
function Threats.FindSpawnPoint(center, bounds, minDistance, maxDistance)
    for pass = 1, 2 do
        for _ = 1, 30 do
            local angle = randomFloat(0, math.pi * 2)
            local reach = randomFloat(minDistance, maxDistance)
            local x = math.floor(center.x + math.cos(angle) * reach)
            local y = math.floor(center.y + math.sin(angle) * reach)
            if not inBounds(bounds, x, y) and standable(loadedSquare(x, y, 0), pass == 1) then
                return { x = x, y = y, z = 0 }
            end
        end
    end
    return nil
end

local function pathTo(zombie, point)
    if not zombie or not point then return end
    pcall(zombie.pathToLocationF, zombie, point.x + 0.5, point.y + 0.5, point.z or 0)
end

local function removeBody(member)
    pcall(function()
        if member.zombie and member.zombie:isDead() ~= true then
            member.zombie:removeFromWorld()
            member.zombie:removeFromSquare()
        end
    end)
end

local function prepareBody(zombie, incident, passive, healthScale)
    pcall(function()
        zombie:getModData().kipnCareersThreat = incident.id
        if passive then zombie:setUseless(true) end
        if healthScale and healthScale ~= 1 then zombie:setHealth(zombie:getHealth() * healthScale) end
    end)
end

local function spawnMember(incident, point, outfit, passive, healthScale, femaleChance)
    local x = point.x + ZombRand(3) - 1
    local y = point.y + ZombRand(3) - 1
    if not standable(loadedSquare(x, y, point.z), false) then x, y = point.x, point.y end
    local ok, list = pcall(addZombiesInOutfit, x, y, point.z or 0, 1, outfit, femaleChance or 30)
    local zombie = ok and list and type(list.size) == "function" and list:size() > 0 and list:get(0) or nil
    if not zombie then
        log("Warn", "spawn failed incident=" .. incident.id .. " outfit=" .. tostring(outfit) .. " error=" .. tostring(not ok and list or "empty"))
        return nil
    end
    prepareBody(zombie, incident, passive, healthScale)
    local member = { zombie = zombie, passive = passive == true, carrying = {}, wallet = 0, x = x, y = y, z = point.z or 0 }
    incident.members[#incident.members + 1] = member
    pathTo(zombie, incident.target)
    return member
end

-- spec:
--   kind            label for logs ("thieves", "customer", ...)
--   count           bodies to spawn
--   outfits         outfit list to draw from
--   passive         spawn as passive (useless) bodies
--   health          health multiplier (defaults to the tier profile)
--   center, minDistance, maxDistance   where to spawn around (defaults to the business anchor, 14-24 tiles)
--   target          where they walk (defaults to the business anchor)
--   arriveMinutes   how long they have to reach the target
--   arriveOnTimeout true = treat reaching the timeout as arriving; false = give up and leave
--   lifetimeMinutes when they leave on their own
--   onArrive(incident), onTick(incident), onMemberDied(incident, member), onResolve(incident, outcome)
function Threats.StartIncident(ctx, spec)
    if not ctx or type(spec) ~= "table" then return nil end
    local center = spec.center or ctx.business.anchor
    local avoid = spec.center == nil and ctx.business.bounds or nil
    local origin = Threats.FindSpawnPoint(center, avoid, spec.minDistance or 14, spec.maxDistance or 24)
    if not origin then
        log("Warn", "no spawn point key=" .. ctx.key .. " kind=" .. tostring(spec.kind))
        return nil
    end
    sequence = sequence + 1
    local incident = {
        id = ctx.key .. ":" .. tostring(spec.kind) .. ":" .. tostring(sequence),
        key = ctx.key, ctx = ctx, kind = spec.kind, spec = spec, members = {},
        origin = origin, target = spec.target or ctx.business.anchor,
        age = 0, arrived = false, leaving = false, timers = {}, stolen = {}, recovered = {},
    }
    local count = math.max(1, math.floor(tonumber(spec.count) or 1))
    for _ = 1, count do
        spawnMember(incident, origin, choice(spec.outfits) or "Generic01", spec.passive, spec.health or ctx.profile.health, spec.femaleChance)
    end
    if #incident.members == 0 then return nil end
    Threats._incidents[incident.id] = incident
    log("Info", "incident started id=" .. incident.id .. " members=" .. tostring(#incident.members)
        .. " tier=" .. tostring(ctx.tier) .. " at " .. tostring(origin.x) .. "," .. tostring(origin.y))
    return incident
end

-- Extra bodies joining a running incident.
function Threats.Reinforce(incident, count, outfits, passive)
    local added = 0
    for _ = 1, math.max(0, math.floor(tonumber(count) or 0)) do
        if spawnMember(incident, incident.origin, choice(outfits) or "Thug", passive, incident.ctx.profile.health, 20) then added = added + 1 end
    end
    return added
end

function Threats.After(incident, minutes, callback)
    incident.timers[#incident.timers + 1] = { at = incident.age + math.max(0, math.floor(tonumber(minutes) or 0)), callback = callback }
end

function Threats.Living(incident)
    local living = {}
    for _, member in ipairs(incident.members) do
        if member.state == nil then living[#living + 1] = member end
    end
    return living
end

-- Passive bodies turn hostile and go after `prey` (default: the owner, else
-- whoever is closest).
function Threats.Provoke(incident, prey)
    for _, member in ipairs(Threats.Living(incident)) do
        if member.passive then
            member.passive = false
            member.provoked = true
            pcall(member.zombie.setUseless, member.zombie, false)
        end
    end
    incident.prey = prey or incident.ctx.owner
    incident.hostile = true
end

-- Everyone heads out, away from where they came in.
function Threats.Leave(incident)
    if incident.leaving then return end
    incident.leaving = true
    incident.leftAt = incident.age
    local fromX, fromY = incident.target.x, incident.target.y
    local dx, dy = incident.origin.x - fromX, incident.origin.y - fromY
    local length = math.max(1, math.sqrt(dx * dx + dy * dy))
    incident.exit = {
        x = math.floor(incident.origin.x + dx / length * (ESCAPE_DISTANCE + 10)),
        y = math.floor(incident.origin.y + dy / length * (ESCAPE_DISTANCE + 10)),
        z = 0,
    }
    for _, member in ipairs(Threats.Living(incident)) do pathTo(member.zombie, incident.exit) end
end

------------------------------------------------------------
-- SPEECH  (display only; the client just draws the line)
------------------------------------------------------------

function Threats.Say(member, text)
    if not member or not member.zombie or not text or text == "" then return end
    local color = member.passive and PASSIVE_COLOR or HOSTILE_COLOR
    if not isServer() then
        pcall(member.zombie.addLineChatElement, member.zombie, text, color.r, color.g, color.b)
        return
    end
    local ok, onlineId = pcall(member.zombie.getOnlineID, member.zombie)
    if not ok or not KIPN or not KIPN.Server or type(KIPN.Server.SendToPlayer) ~= "function" then return end
    local payload = { id = onlineId, text = tostring(text), r = color.r, g = color.g, b = color.b }
    eachPlayer(function(player)
        if distance(player:getX(), player:getY(), member.x, member.y) <= SAY_RADIUS then
            pcall(KIPN.Server.SendToPlayer, player, Shared.ThreatEvents.SAY, payload)
        end
    end)
end

-- A random living member says a random line from `lines`.
function Threats.SayRandom(incident, lines)
    local member = choice(Threats.Living(incident))
    if member then Threats.Say(member, choice(lines)) end
    return member
end

------------------------------------------------------------
-- WORLD EFFECTS  (theft, damage, drops)
------------------------------------------------------------

local function eachSquare(bounds, visit)
    local cell = type(getCell) == "function" and getCell() or nil
    if not cell or type(bounds) ~= "table" then return end
    local z1 = math.floor(bounds.z1 or 0)
    local z2 = math.min(math.floor(bounds.z2 or z1), z1 + 3)
    for z = z1, z2 do
        for x = math.floor(bounds.x1), math.floor(bounds.x2) do
            for y = math.floor(bounds.y1), math.floor(bounds.y2) do
                local square = cell:getGridSquare(x, y, z)
                if square then visit(square) end
            end
        end
    end
end

-- Every loaded container inside `bounds`: { { object, container, x, y, z } }.
function Threats.ContainersIn(bounds)
    local list = {}
    eachSquare(bounds, function(square)
        local objects = square:getObjects()
        for index = 0, objects:size() - 1 do
            local object = objects:get(index)
            local container = object and type(object.getContainer) == "function" and object:getContainer() or nil
            if container then
                list[#list + 1] = { object = object, container = container, x = square:getX(), y = square:getY(), z = square:getZ() }
            end
        end
    end)
    return list
end

-- Career paperwork (licenses, server forms, parcels -- anything carrying a
-- kipn* ModData token) and currency are never stolen by default.
function Threats.DefaultStealFilter(item)
    local fullType = item:getFullType()
    if fullType == Economy.ItemType() or fullType == "Base.Money" or fullType == "Base.MoneyBundle" then return false end
    local ok, modData = pcall(item.getModData, item)
    if ok and type(modData) == "table" then
        for key in pairs(modData) do
            if type(key) == "string" and key:sub(1, 4) == "kipn" then return false end
        end
    end
    return true
end

-- Take up to `opts.max` random top-level items (never more than the loss cap)
-- from `containers` and hand them to living members, who drop them where they
-- die. opts: { min, max, filter, ignoreCap }
function Threats.Steal(incident, containers, opts)
    opts = opts or {}
    local filter = opts.filter or Threats.DefaultStealFilter
    local carriers = Threats.Living(incident)
    if #carriers == 0 then return {} end
    local candidates = {}
    for _, entry in ipairs(containers or {}) do
        local items = entry.container:getItems()
        for index = 0, (items and items:size() or 0) - 1 do
            local item = items:get(index)
            local ok, allowed = pcall(filter, item)
            if item and ok and allowed then candidates[#candidates + 1] = { item = item, container = entry.container } end
        end
    end
    local total = #candidates
    local cap = opts.ignoreCap and total or math.floor(total * incident.ctx.settings.MaxLossPercent / 100)
    if total > 0 and cap == 0 and incident.ctx.settings.MaxLossPercent > 0 then cap = 1 end
    local wanted = math.min(randomInteger(opts.min or incident.ctx.profile.loot[1], opts.max or incident.ctx.profile.loot[2]), cap, total)
    local taken = {}
    for index = 1, wanted do
        local entry = table.remove(candidates, randomInteger(1, #candidates))
        local ok = pcall(function()
            entry.container:Remove(entry.item)
            if isServer() and type(sendRemoveItemFromContainer) == "function" then sendRemoveItemFromContainer(entry.container, entry.item) end
        end)
        if ok then
            local carrier = carriers[(index - 1) % #carriers + 1]
            carrier.carrying[#carrier.carrying + 1] = entry.item
            taken[#taken + 1] = entry.item
            incident.stolen[#incident.stolen + 1] = entry.item
        end
    end
    if #taken > 0 then log("Info", "stole items=" .. tostring(#taken) .. " of " .. tostring(total) .. " incident=" .. incident.id) end
    return taken
end

-- Knock condition off up to `count` random items that have condition.
-- Never breaks an item outright (condition floor 1).
function Threats.DamageItems(containers, count, opts)
    opts = opts or {}
    local candidates = {}
    for _, entry in ipairs(containers or {}) do
        local items = entry.container:getItems()
        for index = 0, (items and items:size() or 0) - 1 do
            local item = items:get(index)
            local ok, max = pcall(function() return item:getConditionMax() end)
            if ok and (tonumber(max) or 0) > 0 and (not opts.filter or opts.filter(item)) then candidates[#candidates + 1] = item end
        end
    end
    local damaged = {}
    for _ = 1, math.min(count or 0, #candidates) do
        local item = table.remove(candidates, randomInteger(1, #candidates))
        local ok = pcall(function()
            local max = item:getConditionMax()
            local loss = math.max(1, math.floor(max * randomInteger(opts.minPercent or 10, opts.maxPercent or 30) / 100))
            item:setCondition(math.max(1, item:getCondition() - loss))
            if isServer() and type(sendItemStats) == "function" then sendItemStats(item) end
        end)
        if ok then damaged[#damaged + 1] = item end
    end
    return damaged
end

-- Damage up to `count` random player-built structures (IsoThumpable: walls,
-- doors, furniture, workstations) inside `bounds`. Never below 25% health,
-- never destroyed.
function Threats.DamageStructures(bounds, count, opts)
    opts = opts or {}
    local candidates = {}
    eachSquare(bounds, function(square)
        local objects = square:getObjects()
        for index = 0, objects:size() - 1 do
            local object = objects:get(index)
            if object and instanceof(object, "IsoThumpable") then
                local ok, max = pcall(object.getMaxHealth, object)
                if ok and (tonumber(max) or 0) > 0 then candidates[#candidates + 1] = object end
            end
        end
    end)
    local damaged = 0
    for _ = 1, math.min(count or 0, #candidates) do
        local object = table.remove(candidates, randomInteger(1, #candidates))
        local ok = pcall(function()
            local max = object:getMaxHealth()
            local floor = math.floor(max * 0.25)
            local loss = math.floor(max * randomInteger(opts.minPercent or 10, opts.maxPercent or 35) / 100)
            local health = math.max(floor, object:getHealth() - loss)
            if health < object:getHealth() then
                object:setHealth(health)
                if type(object.syncIsoThumpable) == "function" then object:syncIsoThumpable() else object:sync() end
                damaged = damaged + 1
            end
        end)
        if not ok then log("Warn", "structure damage failed") end
    end
    return damaged
end

local function dropCarried(incident, member)
    if #member.carrying == 0 and (member.wallet or 0) <= 0 then return end
    local square = loadedSquare(member.x, member.y, member.z)
    if not square then
        log("Warn", "carried goods lost (square unloaded) incident=" .. incident.id)
        return
    end
    for _, item in ipairs(member.carrying) do
        local ok = pcall(square.AddWorldInventoryItem, square, item, randomFloat(0.2, 0.8), randomFloat(0.2, 0.8), 0)
        if ok then incident.recovered[#incident.recovered + 1] = item end
    end
    member.carrying = {}
    if (member.wallet or 0) > 0 then
        Economy.DropAt(square, member.wallet)
        incident.walletDropped = (incident.walletDropped or 0) + member.wallet
        member.wallet = 0
    end
end

-- "2 x Wrench, Spark Plug" for notifications.
function Threats.Describe(items)
    local counts, order = {}, {}
    for _, item in ipairs(items or {}) do
        local ok, name = pcall(item.getDisplayName, item)
        name = ok and tostring(name) or "item"
        if not counts[name] then order[#order + 1] = name end
        counts[name] = (counts[name] or 0) + 1
    end
    local parts = {}
    for _, name in ipairs(order) do parts[#parts + 1] = counts[name] > 1 and (tostring(counts[name]) .. " x " .. name) or name end
    return #parts > 0 and table.concat(parts, ", ") or "nothing"
end

------------------------------------------------------------
-- INCIDENT TICK  (every in-game minute)
------------------------------------------------------------

local function memberStatus(member)
    local ok, dead, square, exists = pcall(function()
        local zombie = member.zombie
        return zombie:isDead(), zombie:getCurrentSquare(), zombie:isExistInTheWorld()
    end)
    if not ok or dead then return "dead" end
    if not square or exists == false then return "gone" end
    member.x, member.y, member.z = square:getX(), square:getY(), square:getZ()
    return "alive"
end

local function nearTarget(incident, member)
    return distance(member.x, member.y, incident.target.x, incident.target.y) <= ARRIVE_DISTANCE
        or (incident.spec.center == nil and inBounds(incident.ctx.business.bounds, member.x, member.y))
end

local function preyFor(incident, member)
    local prey = incident.prey
    if prey and livingPlayer(prey) and distance(prey:getX(), prey:getY(), member.x, member.y) <= ESCAPE_DISTANCE then return prey end
    return playerNear(member.x, member.y, 25)
end

local function call(incident, name, ...)
    local handler = incident.spec[name]
    if type(handler) ~= "function" then return end
    local ok, err = pcall(handler, incident, ...)
    if not ok then log("Error", name .. " failed incident=" .. incident.id .. " error=" .. tostring(err)) end
end

local function resolve(incident)
    local killed, escaped = 0, 0
    for _, member in ipairs(incident.members) do
        if member.state == "dead" then killed = killed + 1 else escaped = escaped + 1 end
    end
    incident.killed, incident.escaped = killed, escaped
    incident.lost = {}
    for _, member in ipairs(incident.members) do
        for _, item in ipairs(member.carrying) do incident.lost[#incident.lost + 1] = item end
    end
    Threats._incidents[incident.id] = nil
    local outcome = escaped == 0 and "defeated" or "escaped"
    log("Info", "incident resolved id=" .. incident.id .. " outcome=" .. outcome .. " killed=" .. tostring(killed) .. " escaped=" .. tostring(escaped))
    call(incident, "onResolve", outcome)
end

local function tickIncident(incident)
    incident.age = incident.age + 1
    local anchor = incident.ctx.business.anchor
    local anyNear = false

    for _, member in ipairs(incident.members) do
        if member.state == nil then
            local status = memberStatus(member)
            if status == "dead" then
                member.state = "dead"
                dropCarried(incident, member)
                call(incident, "onMemberDied", member)
            elseif status == "gone" then
                member.state = "escaped"
            else
                -- A passive body that gets hit fights back (and so does its crew).
                if member.passive and not incident.hostile then
                    local okA, attacker = pcall(member.zombie.getAttackedBy, member.zombie)
                    if okA and attacker and instanceof(attacker, "IsoPlayer") then
                        Threats.Provoke(incident, attacker)
                        call(incident, "onProvoked", member, attacker)
                    end
                end
                if incident.leaving then
                    local far = distance(member.x, member.y, anchor.x, anchor.y) >= ESCAPE_DISTANCE
                    local stale = incident.age - (incident.leftAt or incident.age) >= 60 and not playerNear(member.x, member.y, 20)
                    if far or stale then
                        removeBody(member)
                        member.state = "escaped"
                    elseif incident.age % REPATH_MINUTES == 0 then
                        pathTo(member.zombie, incident.exit)
                    end
                elseif incident.hostile then
                    local prey = preyFor(incident, member)
                    local okT, target = pcall(member.zombie.getTarget, member.zombie)
                    if prey and (not okT or target == nil) and incident.age % 2 == 0 then
                        pcall(member.zombie.setTarget, member.zombie, prey)
                        pathTo(member.zombie, { x = math.floor(prey:getX()), y = math.floor(prey:getY()), z = math.floor(prey:getZ()) })
                    elseif not prey and incident.age % REPATH_MINUTES == 0 then
                        pathTo(member.zombie, incident.target)
                    end
                    if nearTarget(incident, member) then anyNear = true end
                else
                    if nearTarget(incident, member) then
                        anyNear = true
                    elseif incident.age % REPATH_MINUTES == 0 then
                        pathTo(member.zombie, incident.target)
                    end
                end
            end
        end
    end

    if not incident.arrived and not incident.leaving and #Threats.Living(incident) > 0 then
        local timeout = incident.age >= (incident.spec.arriveMinutes or 45)
        if anyNear or (timeout and incident.spec.arriveOnTimeout) then
            incident.arrived = true
            call(incident, "onArrive")
        elseif timeout then
            Threats.Leave(incident)
        end
    end

    local due = {}
    for index = #incident.timers, 1, -1 do
        if incident.age >= incident.timers[index].at then
            due[#due + 1] = incident.timers[index].callback
            table.remove(incident.timers, index)
        end
    end
    for _, callback in ipairs(due) do
        local ok, err = pcall(callback, incident)
        if not ok then log("Error", "timer failed incident=" .. incident.id .. " error=" .. tostring(err)) end
    end
    if Threats._incidents[incident.id] and #Threats.Living(incident) > 0 then call(incident, "onTick") end

    if #Threats.Living(incident) == 0 then
        resolve(incident)
    elseif incident.age >= HARD_LIFETIME_MINUTES then
        for _, member in ipairs(Threats.Living(incident)) do
            removeBody(member)
            member.state = "escaped"
        end
        resolve(incident)
    elseif not incident.leaving and incident.age >= (incident.spec.lifetimeMinutes or 120) then
        Threats.Leave(incident)
    end
end

local function tickIncidents()
    local active = {}
    for _, incident in pairs(Threats._incidents) do active[#active + 1] = incident end
    for _, incident in ipairs(active) do
        local ok, err = pcall(tickIncident, incident)
        if not ok then
            log("Error", "tick failed incident=" .. incident.id .. " error=" .. tostring(err))
            Threats._incidents[incident.id] = nil
        end
    end
end

------------------------------------------------------------
-- SCHEDULER  (every 10 in-game minutes)
------------------------------------------------------------

local function pickEvent(events, tier)
    local pool, total = {}, 0
    for _, event in ipairs(events or {}) do
        if tier >= (event.minTier or 1) and type(event.run) == "function" then
            local weight = type(event.weight) == "function" and event.weight(tier) or event.weight or 1
            weight = tonumber(weight) or 0
            if weight > 0 then
                total = total + weight
                pool[#pool + 1] = { event = event, upTo = total }
            end
        end
    end
    if total <= 0 then return nil end
    local roll = randomFloat(0, total)
    for _, entry in ipairs(pool) do
        if roll <= entry.upTo then return entry.event end
    end
    return pool[#pool].event
end

local function checkBusinesses()
    local config = Threats.Settings()
    if not config.Enabled or config.FrequencyPercent <= 0 then return end
    local now = nowHours()
    for careerId, career in pairs(Threats._careers) do
        local ok, businesses = pcall(career.businesses)
        if not ok then log("Error", "businesses provider failed career=" .. careerId .. " error=" .. tostring(businesses)) end
        for _, business in pairs(ok and type(businesses) == "table" and businesses or {}) do
            if type(business) == "table" and business.active ~= false and type(business.anchor) == "table" and business.ownerKey then
                local key = keyFor(careerId, business)
                local record = pacing(key, business)
                if record and now >= (tonumber(record.graceUntil) or 0) and now >= (tonumber(record.calmUntil) or 0)
                    and not Threats.IsBusy(key)
                then
                    local owner = Threats.OwnerNear(business, config.OwnerRadius)
                    if owner then
                        local ctx = Threats.Context(careerId, business, owner)
                        local percent = ctx.profile.rollPercent * (config.FrequencyPercent / 100) * (1 + math.min(currentHeat(record), 10) / 10)
                        if chance(percent) then
                            local event = pickEvent(career.events, ctx.tier)
                            local started, incident = false, nil
                            if event then started, incident = pcall(event.run, ctx) end
                            if started and incident then
                                log("Info", "scheduled event=" .. tostring(event.id) .. " key=" .. key .. " tier=" .. tostring(ctx.tier))
                                Threats.MarkIncident(ctx)
                            elseif not started then
                                log("Error", "event failed id=" .. tostring(event and event.id) .. " error=" .. tostring(incident))
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- PRESETS
--
-- Ready-made incidents a career can run with its own wording. Each returns
-- the incident (truthy) when bodies spawned, or nil.
------------------------------------------------------------

local function businessName(ctx)
    local name = ctx.business.name
    return (name and name ~= "") and name or "your business"
end

local function crewSize(ctx, bonus)
    local group = ctx.profile.group
    return randomInteger(group[1], group[2]) + (bonus or 0)
end

-- Thieves sneak in (passive until someone hits them), grab goods from every
-- container in the building, then run. Kill them to get the goods back.
-- opts: { lines = { arrive, steal, flee }, filter, title, count }
function Threats.Presets.Thieves(ctx, opts)
    opts = opts or {}
    local lines = opts.lines or {}
    local incident = Threats.StartIncident(ctx, {
        kind = "thieves", count = opts.count or crewSize(ctx), outfits = opts.outfits or Threats.Outfits.thieves,
        passive = true, arriveMinutes = 60, arriveOnTimeout = false, lifetimeMinutes = 150,
        onArrive = function(incident)
            local taken = Threats.Steal(incident, Threats.ContainersIn(ctx.business.bounds), { filter = opts.filter })
            if #taken == 0 then
                Threats.SayRandom(incident, lines.nothing or { "Nothing worth taking." })
                Threats.Leave(incident)
                return
            end
            Threats.SayRandom(incident, lines.steal or { "Grab it and go!", "Quick, quick!" })
            Threats.Notify(ctx, opts.title or "Thieves!", "Thieves are robbing " .. businessName(ctx) .. ". They grabbed: "
                .. Threats.Describe(taken) .. ". Stop them before they get away.")
            Threats.After(incident, randomInteger(1, 2), function(i)
                Threats.SayRandom(i, lines.flee or { "Go, go, go!", "Move it!" })
                Threats.Leave(i)
            end)
        end,
        onProvoked = function(incident)
            Threats.SayRandom(incident, lines.caught or { "We've been made!", "Get 'em!" })
        end,
        onResolve = function(incident, outcome)
            if #incident.stolen == 0 then
                if incident.killed > 0 then Threats.Notify(ctx, "Thieves stopped", "You stopped the thieves before they took anything.") end
                return
            end
            if outcome == "defeated" then
                Threats.Notify(ctx, "Goods recovered", "You stopped the thieves. Everything they took is on the ground where they fell: "
                    .. Threats.Describe(incident.recovered) .. ".")
            elseif #incident.recovered > 0 then
                Threats.Notify(ctx, "Thieves escaped", "You recovered " .. Threats.Describe(incident.recovered)
                    .. ", but the rest got away with " .. Threats.Describe(incident.lost) .. ".")
            else
                Threats.Notify(ctx, "Thieves escaped", "The thieves got away with " .. Threats.Describe(incident.lost) .. ".")
            end
        end,
    })
    if incident then Threats.SayRandom(incident, lines.arrive or {}) end
    return incident
end

-- A hostile crew hits the building: damages player-built structures and goods
-- with condition, maybe grabs some stock, and fights whoever is there.
-- opts: { lines = { arrive, smash }, steal = bool, damageStructures = bool,
--         damageItems = bool, filter, title, count, outfits }
function Threats.Presets.Raiders(ctx, opts)
    opts = opts or {}
    local lines = opts.lines or {}
    local containers = function() return Threats.ContainersIn(ctx.business.bounds) end
    local summary = { structures = 0, items = {}, stolen = {} }
    local passes = 0
    local function vandalise(incident)
        passes = passes + 1
        local damage = ctx.profile.damage
        if opts.damageStructures ~= false then
            summary.structures = summary.structures + Threats.DamageStructures(ctx.business.bounds, randomInteger(damage[1], damage[2]))
        end
        if opts.damageItems ~= false then
            for _, item in ipairs(Threats.DamageItems(containers(), randomInteger(damage[1], damage[2]), { filter = opts.filter })) do
                summary.items[#summary.items + 1] = item
            end
        end
        if opts.steal and passes == 1 then
            for _, item in ipairs(Threats.Steal(incident, containers(), { filter = opts.filter })) do summary.stolen[#summary.stolen + 1] = item end
        end
        Threats.SayRandom(incident, lines.smash or { "Wreck it!", "Tear it all down!", "Take what you want!" })
    end
    local incident = Threats.StartIncident(ctx, {
        kind = "raiders", count = opts.count or crewSize(ctx), outfits = opts.outfits or Threats.Outfits.raiders[ctx.tier],
        passive = false, arriveMinutes = 60, arriveOnTimeout = false, lifetimeMinutes = 90,
        onArrive = function(incident)
            incident.hostile = true
            vandalise(incident)
            local parts = {}
            if summary.structures > 0 then parts[#parts + 1] = tostring(summary.structures) .. " built structure(s) damaged" end
            if #summary.items > 0 then parts[#parts + 1] = "damaged goods: " .. Threats.Describe(summary.items) end
            if #summary.stolen > 0 then parts[#parts + 1] = "taken: " .. Threats.Describe(summary.stolen) end
            Threats.Notify(ctx, opts.title or "Raiders!", "Raiders are hitting " .. businessName(ctx) .. "."
                .. (#parts > 0 and (" " .. table.concat(parts, "; ") .. ".") or "") .. " Drive them off.")
            -- One or two more passes if they are left to it.
            Threats.After(incident, randomInteger(8, 14), function(i) if passes < 3 then vandalise(i) end end)
            Threats.After(incident, randomInteger(20, 30), function(i) if passes < 3 then vandalise(i) end end)
        end,
        onResolve = function(incident, outcome)
            if not incident.arrived then
                if incident.killed > 0 then Threats.Notify(ctx, "Raiders stopped", "You stopped the raiders before they reached " .. businessName(ctx) .. ".") end
                return
            end
            local text = outcome == "defeated" and "You drove the raiders off." or "The raiders left."
            if #incident.recovered > 0 then text = text .. " Recovered: " .. Threats.Describe(incident.recovered) .. "." end
            if #incident.lost > 0 then text = text .. " They got away with: " .. Threats.Describe(incident.lost) .. "." end
            if summary.structures > 0 or #summary.items > 0 then text = text .. " Check the building for damage." end
            Threats.Notify(ctx, outcome == "defeated" and "Raiders driven off" or "Raiders gone", text)
        end,
    })
    if incident then Threats.SayRandom(incident, lines.arrive or {}) end
    return incident
end

-- Hidden mood of a server-created customer, rolled when their work order is
-- completed, weighted by tier: better-known businesses draw more difficult
-- customers. Pass allowHostile = Threats.CanEscalate(ctx) so a hostile
-- customer never lands inside a grace or calm window.
function Threats.RollTemperament(ctx, allowHostile)
    local weights = ({
        { calm = 62, grumble = 30, hostile = 8 },
        { calm = 52, grumble = 33, hostile = 15 },
        { calm = 45, grumble = 35, hostile = 20 },
        { calm = 40, grumble = 35, hostile = 25 },
    })[ctx and ctx.tier or 1]
    local hostile = allowHostile and weights.hostile or 0
    local roll = ZombRand(weights.calm + weights.grumble + hostile)
    if roll < weights.calm then return "calm" end
    if roll < weights.calm + weights.grumble then return "grumble" end
    return "hostile"
end

-- A hostile crew converges on a point (a drug drop; the business itself when
-- `center` is omitted) and hunts `prey`. If `container` is given and they
-- reach it, they take the matching goods. `wallet` (monetary value) is carried
-- by one of them and drops where that one falls -- a hostile customer's crew
-- bringing the money they refused to pay.
-- opts: { center = {x,y,z}, prey, container = entry, filter, wallet, lines, title, count, outfits,
--         onStolen(incident, items), onResolve(incident, outcome) }
function Threats.Presets.Ambush(ctx, opts)
    opts = opts or {}
    local lines = opts.lines or {}
    local incident = Threats.StartIncident(ctx, {
        kind = "ambush", count = opts.count or crewSize(ctx), outfits = opts.outfits or Threats.Outfits.raiders[ctx.tier],
        passive = false, center = opts.center, target = opts.center, minDistance = 12, maxDistance = 20,
        arriveMinutes = 45, arriveOnTimeout = false, lifetimeMinutes = 90,
        onArrive = function(incident)
            if not opts.container then return end
            local taken = Threats.Steal(incident, { opts.container }, { filter = opts.filter, min = 999, max = 999, ignoreCap = true })
            if #taken > 0 then
                Threats.SayRandom(incident, lines.steal or { "Got the goods!" })
                if opts.onStolen then opts.onStolen(incident, taken) end
                Threats.After(incident, randomInteger(1, 3), function(i) Threats.Leave(i) end)
            end
        end,
        onResolve = function(incident, outcome)
            if opts.onResolve then opts.onResolve(incident, outcome) end
        end,
    })
    if incident then
        choice(incident.members).wallet = math.max(0, math.floor(tonumber(opts.wallet) or 0))
        Threats.Provoke(incident, opts.prey or ctx.owner)
        Threats.SayRandom(incident, lines.arrive or { "There they are!" })
    end
    return incident
end

------------------------------------------------------------
-- EVENTS
------------------------------------------------------------

if Events.EveryOneMinute then Events.EveryOneMinute.Add(tickIncidents) end
if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(checkBusinesses) end

return Threats
