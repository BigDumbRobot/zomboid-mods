require "SatanicTemplesTest_Checks"
require "LilBubbySites"

-- World changes for the Satanic Temples suite. They run where the world is
-- authoritative: on the server in multiplayer (SatanicTemplesTest_Server.lua),
-- or directly in single player. The suite only ever creates, edits and deletes
-- the temple named SatanicTemplesTest.TEMPLE_NAME, and tags corpses it makes
-- with SatanicTemplesTest.MARKER.
SatanicTemplesTest.World = SatanicTemplesTest.World or {}
local World = SatanicTemplesTest.World
local MARKER = SatanicTemplesTest.MARKER

World.results = World.results or {} -- by owner key: every offering result sent to that player

local function S() return SacrificialOffering end
local function ownerKey(player) return isServer() and player:getUsername() or "local" end
local function perk() return Perks[SatanicTemplesTest.PERK] end
local function perkKey() return tostring(perk()) end

-- Records results the mod sends, so the client can read the verdict of each
-- case. Installed by setup and removed by cleanup.
local function hookResults()
    local SO = S()
    if World.originalSendResult then return end
    World.originalSendResult = SO.ZoneService.SendResult
    SO.ZoneService.SendResult = function(player, resultType, translation, fields)
        if player then
            local key = ownerKey(player)
            local list = World.results[key] or {}
            World.results[key] = list
            fields = fields or {}
            list[#list + 1] = {
                type = resultType, translation = translation, tx = fields.tx, damage = fields.damage,
                greed = fields.greedTranslation, strength = fields.recoveryStrength,
            }
        end
        return World.originalSendResult(player, resultType, translation, fields)
    end
end

local function unhookResults()
    if World.originalSendResult then
        S().ZoneService.SendResult = World.originalSendResult
        World.originalSendResult = nil
    end
end

local function testZone()
    for _, zone in ipairs(S().Storage.Get().zones) do
        if zone.name == SatanicTemplesTest.TEMPLE_NAME then return zone end
    end
    return nil
end

local function containers(zone)
    local SO, f = S(), zone.fixtures
    local front = SO.Fixtures.FindTaggedObject(f.altar.x, f.altar.y, f.altar.z, SO.FIXTURE.ALTAR)
    local back = f.altarBack and SO.Fixtures.FindTaggedObject(f.altarBack.x, f.altarBack.y, f.altarBack.z, SO.FIXTURE.ALTAR_BACK)
    return front and front:getContainer(), back and back:getContainer()
end

local function altarItems(zone)
    local list = {}
    for _, c in ipairs({ containers(zone) }) do
        if c then
            for i = 0, c:getItems():size() - 1 do list[#list + 1] = c:getItems():get(i):getFullType() end
        end
    end
    return list
end

-- Health changes made here must reach the player's client. applyDamageFromWeapon
-- always ends by syncing all injuries on a server; damageType 0 adds no wound.
local function syncBody(player)
    if isServer() then player:getBodyDamage():applyDamageFromWeapon(0, 0.0, 0, 0.0) end
end

local function record(player)
    local SO = S()
    return SO.Storage.GetPlayer(SO.PlayerLedger.GetIdentity(player))
end

-- A fresh life that lost `xp` of the test skill to its previous death.
local function fakeDeath(player, xp)
    local rec = record(player)
    rec.lastDeathMs = 0
    S().PlayerLedger.RecordDeath(player, "tester")
    rec.awaitingRespawn = false
    rec.bestXP[perkKey()] = player:getXp():getXP(perk()) + xp
end

-- A fresh life with nothing lost: every personal best equals current XP.
local function noGap(player)
    local current = S().PlayerLedger.ReadXP(player)
    local rec = record(player)
    rec.lastDeathMs = 0
    S().PlayerLedger.RecordDeath(player, "tester")
    rec.awaitingRespawn = false
    for key, value in pairs(current) do rec.bestXP[key] = value end
end

local function clearAltar(zone)
    for _, c in ipairs({ containers(zone) }) do
        if c then
            while c:getItems():size() > 0 do
                local item = c:getItems():get(0)
                c:DoRemoveItem(item)
                if isServer() then sendRemoveItemFromContainer(c, item) end
            end
        end
    end
    local f = zone.fixtures
    for _, center in ipairs({ f.altar, f.altarBack }) do
        for dx = -1, 1 do for dy = -1, 1 do
            local sq = getCell():getGridSquare(center.x + dx, center.y + dy, center.z)
            local bodies = sq and sq:getStaticMovingObjects()
            for i = (bodies and bodies:size() or 0) - 1, 0, -1 do
                local body = bodies:get(i)
                if instanceof(body, "IsoDeadBody") then sq:removeCorpse(body, isServer()) end
            end
        end end
    end
end

-- A human corpse item in the altar. owner nil: a plain zombie corpse.
local function addHumanCorpse(zone, owner, playerName)
    local SO, a = S(), zone.fixtures.altar
    local list = addZombiesInOutfit(a.x + 2, a.y + 1, a.z, 1, nil, 0)
    local zombie = list and list:size() > 0 and list:get(0)
    if not zombie then return false end
    local body = IsoDeadBody.new(zombie, false)
    pcall(function() zombie:removeFromWorld(); zombie:removeFromSquare() end)
    body:getModData()[MARKER] = true
    if owner then
        local md = body:getModData()
        md[SO.MOD_DATA.CORPSE_OWNER] = owner
        md[SO.MOD_DATA.CORPSE_ONLINE_ID] = -1
        md[SO.MOD_DATA.CORPSE_PLAYER_NAME] = playerName
    end
    local item = body:getItem()
    if owner then
        local imd = item:getModData()
        imd[SO.MOD_DATA.CORPSE_OWNER] = owner
        imd[SO.MOD_DATA.CORPSE_ONLINE_ID] = -1
        pcall(function() item:storeInByteData(body) end)
    end
    body:getSquare():removeCorpse(body, false)
    local front = containers(zone)
    front:AddItem(item)
    if isServer() then sendAddItemToContainer(front, item) end
    return true
end

-- An intact animal carcass on the ground beside the altar.
local function addAnimalCarcass(zone, preferred)
    local defs = getAllAnimalsDefinitions()
    local def
    for i = 0, defs:size() - 1 do
        if defs:get(i):getAnimalType() == preferred then def = defs:get(i) end
    end
    def = def or defs:get(0)
    local a = zone.fixtures.altar
    local animal = addAnimal(getCell(), a.x + 1, a.y, a.z, def:getAnimalType(), def:getBreeds():get(0), false)
    animal:addToWorld()
    local body = IsoDeadBody.new(animal, false)
    pcall(function() animal:removeFromWorld(); animal:removeFromSquare() end)
    if body then body:getModData()[MARKER] = true end
    return body ~= nil, def:getAnimalType()
end

local function describe(zone)
    local SO, f = S(), zone.fixtures
    return {
        zoneId = zone.id,
        altar = { x = f.altar.x, y = f.altar.y, z = f.altar.z },
        mannequins = f.mannequins,
        lanterns = f.lanterns,
        campfire = f.campfire,
    }
end

-- The designated test temple. The server makes it with the other test sites
-- (LilBubbySites); players are moved beside it and never create a temple.
-- The temple mod answers whoever creates or deletes a temple; when that is the
-- server's own stand-in there is nobody to answer, so the answer is dropped.
local function quietly(who, fn)
    local Z = S().ZoneService
    local send = Z.SendResult
    if type(who) == "table" then Z.SendResult = function(target, ...) if target ~= who then return send(target, ...) end end end
    local ok, err = pcall(fn)
    Z.SendResult = send
    if not ok then error(err, 0) end
end

if LilBubbySites then
    LilBubbySites.Provide("temple", {
        label = "Satanic Temple",
        available = function() return SatanicTemplesTest.available() and S() ~= nil and S().ZoneService ~= nil end,
        layout = function(origin)
            -- The same 14 x 14 temple the test always built, north of where the player stands.
            local x, y = origin.x + 95, origin.y + 14
            return { x1 = x - 6, y1 = y - 14, x2 = x + 7, y2 = y, z = origin.z }, { x = x, y = y, z = origin.z }
        end,
        create = function(admin, rect)
            -- A temple an earlier version of the tester built for a player is adopted, not doubled.
            if testZone() then return testZone().id end
            quietly(admin, function()
                S().ZoneService.Create(admin, { x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2 - 1,
                    name = SatanicTemplesTest.TEMPLE_NAME })
            end)
            local zone = testZone()
            if not zone then return nil, "the temple could not be created there (overlap or bad ground)" end
            return zone.id
        end,
        remove = function(admin, id)
            local zone = testZone()
            if zone and tostring(zone.id) == tostring(id) then
                quietly(admin, function() S().ZoneService.Delete(admin, { zoneId = zone.id }) end)
                pcall(S().Fixtures.CleanupTombstones)
            end
        end,
        exists = function(id)
            local zone = testZone()
            return zone ~= nil and tostring(zone.id) == tostring(id)
        end,
    })
end

-- Readies the designated test temple: provisions it, lights its campfire and
-- starts recording offering results. It never creates the temple.
function World.setup(player, args)
    local SO = S()
    local zone = testZone()
    local created = false
    if not zone then return { status = "BLOCKED", error = LilBubbySites.Missing("temple") } end
    hookResults()
    if not zone.fixtures or zone.pendingFixtures then SO.ZoneService.ProvisionAndRepair() end
    if not zone.fixtures or not zone.fixtures.altar then return { error = "the temple has no altar yet" } end
    local result = describe(zone)
    result.created = created
    return result
end

local function setFire(zone, lit)
    local c = zone.fixtures.campfire
    local cf = SCampfireSystem.instance:getLuaObjectAt(c.x, c.y, c.z)
    if not cf then return false end
    if lit then cf:setFuel(600); cf:lightFire() else cf:putOut() end
    return cf.isLit == lit
end

-- Sets up one case: a clean altar, the fire, the ledger, the offering and the
-- player's health. Every field is optional.
function World.prepare(player, args)
    local SO = S()
    local zone = testZone()
    if not zone then return { error = "no test temple" } end
    local body = player:getBodyDamage()
    if args.heal ~= false then body:RestoreToFullHealth() end
    if args.clear ~= false then clearAltar(zone) end
    setFire(zone, args.fire ~= false)
    if args.death == "fake" then fakeDeath(player, tonumber(args.xp) or 5000)
    elseif args.death == "none" then noGap(player) end
    if args.redeemed then
        local rec = record(player)
        rec.recoveryStrengthGeneration = rec.deathGeneration
        rec.recoveryStrengthRedeemed = tonumber(args.redeemed)
    end
    if args.xpBoost then
        player:getXp():AddXP(perk(), tonumber(args.xpBoost), false, false, false, false)
        SO.PlayerLedger.UpdateBest(player)
    end
    local front = containers(zone)
    for _, fullType in ipairs(args.items or {}) do
        local item = front:AddItem(fullType)
        if item and isServer() then sendAddItemToContainer(front, item) end
    end
    local made = true
    if args.corpse == "zombie" then made = addHumanCorpse(zone, nil)
    elseif args.corpse == "victim" then made = addHumanCorpse(zone, SatanicTemplesTest.VICTIM, "Test Victim")
    elseif args.corpse == "self" then made = addHumanCorpse(zone, SO.PlayerLedger.GetIdentity(player), "Yourself") end
    local animal
    if args.animal then made, animal = addAnimalCarcass(zone, args.animal) end
    if args.reduceHealth then body:ReduceGeneralHealth(tonumber(args.reduceHealth)) end
    syncBody(player)
    local list = World.results[ownerKey(player)] or {}
    return { made = made, animal = animal, mark = #list, items = altarItems(zone) }
end

-- Runs the server half of a ritual. stage: "begin" (ritual starts), "make" (it
-- completes; pass tx), "both", or "abandon" (starts, then the player walks away
-- and the ritual's full length is skipped).
function World.offer(player, args)
    local SO = S()
    local zone = testZone()
    if not zone then return { error = "no test temple" } end
    local a = zone.fixtures.altar
    local tx = args.tx or ("tester-" .. getTimestampMs() .. "-" .. ZombRand(100000))
    local offerArgs = { tx = tx, zoneId = zone.id, x = a.x, y = a.y, z = a.z }
    local stage = args.stage or "both"
    if stage ~= "make" then SO.OfferingService.Begin(player, offerArgs) end
    if stage == "abandon" then
        local pending = SO.OfferingService.PendingRituals[tx]
        if pending then pending.elapsedMs = 1e9 end
    end
    if stage == "make" or stage == "both" then SO.OfferingService.Make(player, offerArgs) end
    return { tx = tx }
end

-- A second offering at the same altar while the first one's verdict is due.
function World.busy(player, args)
    local SO = S()
    local zone = testZone()
    if not zone then return { error = "no test temple" } end
    World.offer(player, { stage = "both" })
    local front = containers(zone)
    front:AddItem("Base.Plank")
    local key = ownerKey(player)
    local before = #(World.results[key] or {})
    World.offer(player, { stage = "begin" })
    local after = World.results[key] or {}
    local last = after[#after]
    return { busy = #after > before and last.translation == SO.TRANSLATION.BUSY }
end

-- Everything a case checks, read in one reply.
function World.state(player, args)
    local SO = S()
    local zone = testZone()
    if not zone then return { error = "no test temple" } end
    local body = player:getBodyDamage()
    local deep, fractures, parts = 0, 0, body:getBodyParts()
    for i = 0, parts:size() - 1 do
        if parts:get(i):isDeepWounded() then deep = deep + 1 end
        if parts:get(i):getFractureTime() > 0 then fractures = fractures + 1 end
    end
    local list = World.results[ownerKey(player)] or {}
    local since = {}
    for i = (tonumber(args.since) or 0) + 1, #list do since[#since + 1] = list[i] end
    local skeletons = {}
    for i, pos in ipairs(zone.fixtures.mannequins or {}) do
        local m = SO.Fixtures.FindTaggedObject(pos.x, pos.y, pos.z, SO.FIXTURE.MANNEQUIN)
        skeletons[i] = m and {
            script = m:getMannequinScriptName(),
            worn = m:getWornItems():size(),
            katanas = m:getContainer() and m:getContainer():getCountType("Katana") or 0,
            items = m:getContainer() and m:getContainer():getItems():size() or 0,
        } or { missing = true }
    end
    local lanterns = 0
    for _, pos in ipairs(zone.fixtures.lanterns or {}) do
        local sq = getCell():getGridSquare(pos.x, pos.y, pos.z)
        local objects = sq and sq:getWorldObjects()
        for i = 0, (objects and objects:size() or 0) - 1 do
            if SO.Fixtures.IsLanternItem(objects:get(i):getItem()) then lanterns = lanterns + 1 end
        end
    end
    local pending = args.tx and SO.OfferingService.PendingRituals[args.tx]
    return {
        results = since, count = #list,
        health = body:getOverallBodyHealth(), dead = player:isDead(),
        xp = player:getXp():getXP(perk()),
        deep = deep, fractures = fractures,
        items = altarItems(zone),
        skeletons = skeletons, lanterns = lanterns, lanternSpots = #(zone.fixtures.lanterns or {}),
        pending = pending and { valid = pending.verdict.valid, reason = pending.verdict.reason } or nil,
        victimUses = record(player).playerCorpseSacrifices[SatanicTemplesTest.VICTIM],
        identity = SO.PlayerLedger.GetIdentity(player),
    }
end

-- Damages the temple the way players or old versions could, then runs the
-- mod's one-minute integrity pass twice (the second must change nothing).
function World.repair(player, args)
    local SO = S()
    local zone = testZone()
    if not zone then return { error = "no test temple" } end
    local f = zone.fixtures
    local m1 = SO.Fixtures.FindTaggedObject(f.mannequins[1].x, f.mannequins[1].y, f.mannequins[1].z, SO.FIXTURE.MANNEQUIN)
    local m3 = SO.Fixtures.FindTaggedObject(f.mannequins[3].x, f.mannequins[3].y, f.mannequins[3].z, SO.FIXTURE.MANNEQUIN)
    if not m1 or not m3 then return { error = "skeletons missing" } end
    m1:getContainer():DoRemoveItem(m1:getContainer():getItems():get(0))
    m3:setMannequinScriptName("MaleWhite01")
    m3:getModData().SO_OutfitVersion = 3
    local lp = f.lanterns[2]
    local sq = getCell():getGridSquare(lp.x, lp.y, lp.z)
    for i = sq:getWorldObjects():size() - 1, 0, -1 do
        local o = sq:getWorldObjects():get(i)
        if SO.Fixtures.IsLanternItem(o:getItem()) then sq:transmitRemoveItemFromSquare(o); sq:removeWorldObject(o) end
    end
    local savedLanterns = f.lanterns
    f.lanterns = nil
    SO.ZoneService.ProvisionAndRepair()
    local function lanternsOnSquare()
        local n = 0
        for i = 0, sq:getWorldObjects():size() - 1 do
            if SO.Fixtures.IsLanternItem(sq:getWorldObjects():get(i):getItem()) then n = n + 1 end
        end
        return n
    end
    local first = {
        katanas = m1:getContainer():getCountType("Katana"),
        script = m3:getMannequinScriptName(),
        m3katanas = m3:getContainer():getCountType("Katana"),
        lantern = lanternsOnSquare(),
        lanternSpots = f.lanterns and #f.lanterns or 0,
    }
    SO.ZoneService.ProvisionAndRepair()
    first.secondPassKatanas = m1:getContainer():getCountType("Katana")
    first.secondPassLantern = lanternsOnSquare()
    if not f.lanterns then f.lanterns = savedLanterns end
    return first
end

-- Lets the next katana-theft attempt be punished at once.
function World.relicReady(player, args)
    S().RelicService.lastStrikeAt = {}
    player:getBodyDamage():RestoreToFullHealth()
    syncBody(player)
    return {}
end

function World.heal(player, args)
    player:getBodyDamage():RestoreToFullHealth()
    syncBody(player)
    return {}
end

-- Removes the test temple (skeletons, katanas, pumpkins, altar, campfire),
-- test corpses and the result recorder.
function World.cleanup(player, args)
    local SO = S()
    local zone = testZone()
    -- The designated temple stays for the next player; only what the test left on it goes.
    if zone then
        clearAltar(zone)
        SO.Fixtures.CleanupTombstones()
    end
    unhookResults()
    World.results[ownerKey(player)] = nil
    return { cleared = zone ~= nil }
end

return World
