#!/usr/bin/env lua
-- tests/careers_threats_checks.lua
--
-- Standalone harness for the Careers Framework threats layer
-- (KIPNCareers_Threats.lua + the Economy helpers it uses), the Mechanic
-- walk-in completion flow and the Dealer threats built on it. A small mock of the PZ world stands in for
-- the game: loaded squares, containers and items, player-built thumpables,
-- zombies that walk toward wherever they were told to path, online players,
-- KIPN.Server data/save/send, and a controllable clock.
--
-- Run from the LilBubbyModTester folder:  lua tests/careers_threats_checks.lua
-- It loads Careers Framework, Careers: Mechanic and Careers: Drug Dealer from
-- their Steam Workshop subscriptions.
-- Exits 0 if every assertion passes, 1 otherwise.
--
-- What this cannot show: how real B42 zombies path, fight and sync. Those
-- need the dedicated-server smoke test in the README.

-- Every mod comes from the Steam Workshop: its subscribed copy under
-- steamapps/workshop/content/108600/<Workshop ID>/mods/<mod id>/.
local WORKSHOP = (os.getenv("HOME") or "") .. "/Library/Application Support/Steam/steamapps/workshop/content/108600/"
local function modLua(workshopId, modId) return WORKSHOP .. workshopId .. "/mods/" .. modId .. "/42/media/lua/" end
local framework = modLua("3795313541", "CareersFramework")
local mechanic = modLua("3806124670", "CareersMechanic")
local dealer = modLua("3806118332", "CareersDrugDealer")
package.path = framework .. "shared/?.lua;" .. framework .. "server/?.lua;"
    .. mechanic .. "shared/?.lua;" .. mechanic .. "server/?.lua;"
    .. dealer .. "shared/?.lua;" .. dealer .. "server/?.lua;" .. package.path

------------------------------------------------------------
-- MOCK WORLD
------------------------------------------------------------

local function list(items)
    local self = { items = items or {} }
    function self:size() return #self.items end
    function self:get(index) return self.items[index + 1] end
    return self
end

local seed = 1
local function nextRandom()
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed
end
function ZombRand(a, b)
    local minimum, maximum = 0, a - 1
    if b ~= nil then minimum, maximum = a, b - 1 end
    if maximum < minimum then return minimum end
    return minimum + nextRandom() % (maximum - minimum + 1)
end

local worldHours = 100
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
function getTimestampMs() return 0 end
function isClient() return false end
function isServer() return true end
function instanceof(object, class) return type(object) == "table" and object.__class == class end

local synced = { removed = 0, added = 0, stats = 0 }
function sendRemoveItemFromContainer() synced.removed = synced.removed + 1 end
function sendAddItemToContainer() synced.added = synced.added + 1 end
function sendItemStats() synced.stats = synced.stats + 1 end

Events = setmetatable({}, { __index = function(events, name)
    local event = { handlers = {} }
    function event.Add(handler) event.handlers[#event.handlers + 1] = handler end
    function event.Remove(handler)
        for index = #event.handlers, 1, -1 do if event.handlers[index] == handler then table.remove(event.handlers, index) end end
    end
    rawset(events, name, event)
    return event
end })
local function fire(name, ...) for _, handler in ipairs(Events[name].handlers) do handler(...) end end

SandboxVars = { KIPNCareers = {} }

-- Items / containers
local itemId = 0
local function newItem(fullType, conditionMax)
    itemId = itemId + 1
    local item = { fullType = fullType, id = itemId, modData = {}, conditionMax = conditionMax or 0, condition = conditionMax or 0 }
    function item:getFullType() return self.fullType end
    function item:getDisplayName() return (self.fullType:gsub("^.-%.", "")) end
    function item:getModData() return self.modData end
    function item:getConditionMax() return self.conditionMax end
    function item:getCondition() return self.condition end
    function item:setCondition(value) self.condition = value end
    function item:getContainer() return self.container end
    return item
end

local function newContainer(kind)
    local container = { kind = kind or "crate", list = {} }
    function container:getItems() return list(self.list) end
    function container:getType() return self.kind end
    function container:AddItem(what)
        local item = type(what) == "string" and newItem(what) or what
        item.container = self
        self.list[#self.list + 1] = item
        return item
    end
    function container:Remove(item)
        for index, candidate in ipairs(self.list) do
            if candidate == item then table.remove(self.list, index) item.container = nil return end
        end
    end
    function container:count(fullType)
        local total = 0
        for _, item in ipairs(self.list) do if not fullType or item.fullType == fullType then total = total + 1 end end
        return total
    end
    return container
end

-- Squares: everything in a 400x400 area is loaded. Building bounds are inside.
local squares = {}
local building = { x1 = 100, y1 = 100, x2 = 110, y2 = 110 }
local function squareAt(x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z or 0)
    if x < 0 or y < 0 or x > 400 or y > 400 or z ~= 0 then return nil end
    local key = x .. "," .. y .. "," .. z
    if squares[key] then return squares[key] end
    local square = { x = x, y = y, z = z, objects = {}, world = {} }
    function square:getX() return self.x end
    function square:getY() return self.y end
    function square:getZ() return self.z end
    function square:getObjects() return list(self.objects) end
    function square:isFree() return true end
    function square:isOutside()
        return not (self.x >= building.x1 and self.x <= building.x2 and self.y >= building.y1 and self.y <= building.y2)
    end
    function square:AddWorldInventoryItem(what)
        local item = type(what) == "string" and newItem(what) or what
        self.world[#self.world + 1] = item
        return item
    end
    squares[key] = square
    return square
end
local cell = {}
function cell:getGridSquare(x, y, z) return squareAt(x, y, z) end
function getCell() return cell end

local function addContainerObject(x, y, container)
    local object = { container = container }
    function object:getContainer() return self.container end
    table.insert(squareAt(x, y, 0).objects, object)
    return object
end

local function addThumpable(x, y, health)
    local object = { __class = "IsoThumpable", health = health, maxHealth = health, syncs = 0 }
    function object:getMaxHealth() return self.maxHealth end
    function object:getHealth() return self.health end
    function object:setHealth(value) self.health = value end
    function object:syncIsoThumpable() self.syncs = self.syncs + 1 end
    table.insert(squareAt(x, y, 0).objects, object)
    return object
end

-- Zombies walk 4 tiles per in-game minute toward their last path target.
local zombies = {}
local onlineIds = 0
function addZombiesInOutfit(x, y, z, count, outfit)
    local spawned = {}
    for _ = 1, count do
        onlineIds = onlineIds + 1
        local zombie = { x = x, y = y, z = z, outfit = outfit, dead = false, exists = true, useless = false, health = 1.5, onlineId = onlineIds, modData = {}, said = {} }
        function zombie:isDead() return self.dead end
        function zombie:getCurrentSquare() return self.exists and squareAt(self.x, self.y, self.z) or nil end
        function zombie:isExistInTheWorld() return self.exists end
        function zombie:getModData() return self.modData end
        function zombie:setUseless(value) self.useless = value end
        function zombie:getHealth() return self.health end
        function zombie:setHealth(value) self.health = value end
        function zombie:pathToLocationF(tx, ty) self.dest = { x = tx, y = ty } end
        function zombie:getOnlineID() return self.onlineId end
        function zombie:getAttackedBy() return self.attackedBy end
        function zombie:getTarget() return self.target end
        function zombie:setTarget(value) self.target = value end
        function zombie:removeFromWorld() self.exists = false end
        function zombie:removeFromSquare() end
        function zombie:addLineChatElement(text) self.said[#self.said + 1] = text end
        zombies[#zombies + 1] = zombie
        spawned[#spawned + 1] = zombie
    end
    return list(spawned)
end

local function walk()
    for _, zombie in ipairs(zombies) do
        if not zombie.dead and zombie.exists and zombie.dest then
            local dx, dy = zombie.dest.x - zombie.x, zombie.dest.y - zombie.y
            local length = math.sqrt(dx * dx + dy * dy)
            if length <= 4 then zombie.x, zombie.y = math.floor(zombie.dest.x), math.floor(zombie.dest.y)
            else zombie.x, zombie.y = math.floor(zombie.x + dx / length * 4), math.floor(zombie.y + dy / length * 4) end
        end
    end
end

-- Players
local function newPlayer(name, x, y)
    local player = { name = name, x = x, y = y, dead = false, inventory = newContainer("inventory") }
    function player:getX() return self.x end
    function player:getY() return self.y end
    function player:getZ() return 0 end
    function player:isDead() return self.dead end
    function player:getSteamID() return "0" end
    function player:getUsername() return self.name end
    function player:getInventory() return self.inventory end
    function player:getSquare() return squareAt(self.x, self.y, 0) end
    function player:getAccessLevel() return "none" end
    player.__class = "IsoPlayer"
    return player
end
local players = {}
function getOnlinePlayers() return list(players) end

-- KIPN host
local root = {}
local sent = {}
local handlers = {}
KIPN = {
    Logger = { Create = function()
        local noop = function() end
        return { Info = noop, Warn = noop, Debug = noop, Error = function(_, text) io.write("    [log] " .. text .. "\n") end }
    end },
    Server = {
        GetData = function() return root end,
        Save = function() return true end,
        SendToPlayer = function(player, event, payload) sent[#sent + 1] = { player = player, event = event, payload = payload } return true end,
        RegisterCommandHandler = function(command, handler) handlers[command] = handler return true end,
        GetCommandHandler = function(command) return handlers[command] end,
        AuthService = { GetPlayerSession = function() return { authenticated = true } end },
    },
    Shared = { Commands = { SERVER_RESPONSE = "response" } },
}

-- Advance the world `minutes` in-game minutes, firing the game's clock events.
local function advance(minutes)
    for minute = 1, minutes do
        worldHours = worldHours + 1 / 60
        walk()
        fire("EveryOneMinute")
        if minute % 10 == 0 then fire("EveryTenMinutes") end
    end
end

local function kill(zombie) zombie.dead = true end

local function worldItems()
    local total = {}
    for _, square in pairs(squares) do for _, item in ipairs(square.world) do total[#total + 1] = item end end
    return total
end

local function clearWorld()
    for _, zombie in ipairs(zombies) do zombie.exists = false end
    zombies = {}
    squares = {}
    sent = {}
end

------------------------------------------------------------
-- ASSERTIONS
------------------------------------------------------------

local total, failed = 0, 0
local function report(ok, description)
    total = total + 1
    if not ok then failed = failed + 1 end
    io.write((ok and "  PASS  " or "  FAIL  ") .. description .. "\n")
end
local function assertEqual(actual, expected, description)
    report(actual == expected, description .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end
local function assertTrue(value, description) report(value == true, description) end

------------------------------------------------------------
-- LOAD
------------------------------------------------------------

require("KIPNCareers_Shared")
require("KIPNCareers_Economy")
require("KIPNCareers_Threats")
local Economy = KIPNCareers.Economy
local Threats = KIPNCareers.Threats

local notices = {}
local fake = {
    reputation = 10,
    shops = {},
}
Threats.Register("fake", {
    businesses = function() return fake.shops end,
    reputation = function() return fake.reputation end,
    notify = function(ownerKey, title, body) notices[#notices + 1] = { owner = ownerKey, title = title, body = body } end,
    events = { { id = "thieves", weight = 1, run = function(ctx) return Threats.Presets.Thieves(ctx, {}) end } },
})

local function newShop(id)
    local shop = { id = id, ownerKey = "user:owner", name = "Test Shop", active = true, createdAt = worldHours,
        bounds = { x1 = building.x1, y1 = building.y1, x2 = building.x2, y2 = building.y2, z1 = 0, z2 = 0 },
        anchor = { x = 105, y = 105, z = 0 } }
    fake.shops[id] = shop
    return shop
end

local owner = newPlayer("owner", 105, 105)
players = { owner }

local function lastNotice() return notices[#notices] end

------------------------------------------------------------
-- ECONOMY HELPERS (bundles)
------------------------------------------------------------
print("Economy helpers")
do
    local box = newContainer()
    box:AddItem("Base.MoneyBundle") box:AddItem("Base.MoneyBundle")
    for _ = 1, 30 do box:AddItem("Base.Money") end
    local entries = { { container = box } }
    assertEqual(Economy.CountIn(entries), 230, "CountIn counts bundles as 100 and notes as 1")
    assertTrue(Economy.TakeFrom(entries, 150), "TakeFrom succeeds when enough is present")
    assertEqual(Economy.CountIn(entries), 80, "TakeFrom leaves exactly the remainder, making change from a bundle")
    assertEqual(box:count("Base.MoneyBundle"), 0, "the broken bundle is gone")
    local ok = Economy.TakeFrom(entries, 500)
    assertEqual(ok, false, "TakeFrom refuses when there is not enough")
    assertEqual(Economy.CountIn(entries), 80, "a refused TakeFrom removes nothing")
    local square = squareAt(10, 10, 0)
    Economy.DropAt(square, 250)
    local bundles, notes = 0, 0
    for _, item in ipairs(square.world) do
        if item.fullType == "Base.MoneyBundle" then bundles = bundles + 1 elseif item.fullType == "Base.Money" then notes = notes + 1 end
    end
    assertEqual(bundles, 2, "DropAt 250 drops 2 bundles")
    assertEqual(notes, 50, "DropAt 250 drops 50 notes")
end

------------------------------------------------------------
-- THIEVES: steal within the cap, drop on death, lose to escapees
------------------------------------------------------------
print("Thieves")
do
    clearWorld()
    local shop = newShop("s1")
    local stock = newContainer()
    for index = 1, 20 do stock:AddItem("Base.Part" .. index) end
    stock:AddItem("Base.MoneyBundle")
    local license = stock:AddItem("KIPNCareers.MechanicLicense")
    license.modData.kipnMechToken = "t1"
    addContainerObject(104, 104, stock)
    fake.reputation = 80 -- tier 4: crews of 3-5, loot 3-8
    local ctx = Threats.Context("fake", shop)
    assertEqual(ctx.tier, 4, "reputation 80 is tier 4")
    local incident = Threats.Presets.Thieves(ctx, {})
    assertTrue(incident ~= nil, "thieves spawned")
    local crew = #incident.members
    assertTrue(crew >= 3 and crew <= 5, "tier 4 crew size is 3-5 (got " .. crew .. ")")
    local allPassive = true
    for _, member in ipairs(incident.members) do if not member.zombie.useless then allPassive = false end end
    assertTrue(allPassive, "thieves spawn passive")
    local spawnedOutside = not (incident.origin.x >= building.x1 and incident.origin.x <= building.x2 and incident.origin.y >= building.y1 and incident.origin.y <= building.y2)
    assertTrue(spawnedOutside, "thieves spawn outside the building")
    local before = stock:count()
    local minutes = 0
    while not incident.arrived and minutes < 60 do advance(1) minutes = minutes + 1 end
    assertTrue(incident.arrived, "thieves reached the shop")
    local taken = before - stock:count()
    assertTrue(taken >= 1 and taken <= 5, "stolen count respects the 25% cap of 20 eligible items (took " .. taken .. ")")
    assertEqual(stock:count("KIPNCareers.MechanicLicense"), 1, "career paperwork is never stolen")
    assertEqual(stock:count("Base.MoneyBundle"), 1, "currency is not stolen by default")
    assertTrue(synced.removed >= taken, "every removal was synced to clients")
    assertTrue(lastNotice() and lastNotice().title == "Thieves!", "owner was told about the theft")

    -- Kill the first carrier; let the rest run.
    local carrier
    for _, member in ipairs(incident.members) do if #member.carrying > 0 then carrier = member break end end
    local carried = #carrier.carrying
    kill(carrier.zombie)
    advance(1)
    local dropped = 0
    for _, item in ipairs(squareAt(carrier.x, carrier.y, 0).world) do dropped = dropped + 1 end
    assertEqual(dropped, carried, "a dead thief drops exactly what they carried where they fell")
    advance(120)
    assertTrue(Threats._incidents[incident.id] == nil, "incident resolved after the rest escaped")
    assertEqual(#incident.recovered + #incident.lost, taken, "every stolen item is either recovered or lost")
    local title = lastNotice().title
    assertTrue(title == "Thieves escaped" or title == "Goods recovered", "owner got the outcome (" .. title .. ")")
    fake.shops = {}
end

print("Thieves: loss cap of 0")
do
    clearWorld()
    SandboxVars.KIPNCareers.ThreatMaxLossPercent = 0
    local shop = newShop("s2")
    local stock = newContainer()
    for index = 1, 10 do stock:AddItem("Base.Part" .. index) end
    addContainerObject(104, 104, stock)
    local incident = Threats.Presets.Thieves(Threats.Context("fake", shop), {})
    advance(60)
    assertEqual(stock:count(), 10, "ThreatMaxLossPercent 0 means nothing is stolen")
    advance(200)
    SandboxVars.KIPNCareers.ThreatMaxLossPercent = nil
    fake.shops = {}
end

print("Thieves: hitting a passive thief makes the crew fight")
do
    clearWorld()
    local shop = newShop("s3")
    local incident = Threats.Presets.Thieves(Threats.Context("fake", shop), {})
    incident.members[1].zombie.attackedBy = owner
    advance(1)
    assertTrue(incident.hostile == true, "incident turned hostile")
    local anyUseless = false
    for _, member in ipairs(incident.members) do if member.zombie.useless then anyUseless = true end end
    assertTrue(not anyUseless, "every thief is no longer passive")
    advance(400)
    fake.shops = {}
end

------------------------------------------------------------
-- RAIDERS: structure damage floor, item condition floor
------------------------------------------------------------
print("Raiders")
do
    clearWorld()
    local shop = newShop("s4")
    local walls = {}
    for index = 0, 5 do walls[#walls + 1] = addThumpable(101 + index, 101, 100) end
    local rack = newContainer()
    local blades = {}
    for _ = 1, 6 do blades[#blades + 1] = rack:AddItem(newItem("Base.Machete", 20)) end
    addContainerObject(106, 106, rack)
    fake.reputation = 80
    local incident = Threats.Presets.Raiders(Threats.Context("fake", shop), { steal = false })
    advance(200)
    local minHealth, damaged = 100, 0
    for _, wall in ipairs(walls) do
        if wall.health < 100 then damaged = damaged + 1 end
        if wall.health < minHealth then minHealth = wall.health end
    end
    assertTrue(damaged >= 1, "raiders damaged player-built structures (" .. damaged .. ")")
    assertTrue(minHealth >= 25, "no structure fell below 25% (min " .. minHealth .. ")")
    local minCondition = 20
    for _, blade in ipairs(blades) do if blade.condition < minCondition then minCondition = blade.condition end end
    assertTrue(minCondition >= 1 and minCondition < 20, "goods lost condition but none broke (min " .. minCondition .. ")")
    assertTrue(Threats._incidents[incident.id] == nil, "raid ended")
    fake.shops = {}
end

------------------------------------------------------------
-- SCHEDULER PACING
------------------------------------------------------------
print("Scheduler pacing")
do
    clearWorld()
    root.careers.threats = nil
    SandboxVars.KIPNCareers.ThreatFrequencyPercent = 300
    local shop = newShop("s5")
    local started = 0
    local original = Threats.StartIncident
    Threats.StartIncident = function(...) started = started + 1 return original(...) end
    advance(60 * 20) -- 20 hours: inside the 24h grace period
    assertEqual(started, 0, "no incident during the new-business grace period")
    advance(60 * 40) -- well past grace; owner is standing at the shop
    assertTrue(started >= 1, "an incident starts once grace is over and the owner is near")
    local record = root.careers.threats.businesses["fake:s5"]
    assertTrue(record.calmUntil > record.lastIncidentAt, "a calm window follows the incident")
    local countAfterFirst = started
    local calmLeft = (record.calmUntil - worldHours) * 60
    advance(math.max(0, math.floor(calmLeft) - 10))
    assertEqual(started, countAfterFirst, "nothing new during the calm window")
    Threats.StartIncident = original
    owner.x, owner.y = 300, 300 -- owner walks away
    local before = started
    advance(60 * 80)
    assertEqual(started, before, "no incidents while the owner is away")
    owner.x, owner.y = 105, 105
    SandboxVars.KIPNCareers.ThreatFrequencyPercent = nil
    advance(400)
    fake.shops = {}
end

------------------------------------------------------------
-- MECHANIC WALK-IN PICKUP (end to end through the Mechanic server)
------------------------------------------------------------
print("Mechanic walk-in pickup")
require("KIPNCareers_MechanicServer")
require("KIPNCareers_MechanicThreats")
local Mechanic = KIPNCareers.Mechanic
KIPNCareers.MechanicServer.Initialize()

local function mechanicState() return root.careers.mechanic end

local function walkIn(temperament)
    clearWorld()
    local data = mechanicState()
    data.reputation["user:owner"] = 60
    data.pendingCurrency = {}
    data.shops.m1 = data.shops.m1 or {
        id = "m1", ownerKey = "user:owner", ownerName = "owner", name = "Owner's Garage", active = true,
        createdAt = worldHours - 100, bounds = { x1 = building.x1, y1 = building.y1, x2 = building.x2, y2 = building.y2, z1 = 0, z2 = 0 },
        anchor = { x = 105, y = 105, z = 0 }, containers = {},
    }
    root.careers.threats.businesses["mechanic:m1"] = nil -- fresh pacing: hostile customers allowed
    local order = {
        id = "o-" .. temperament .. "-" .. tostring(worldHours), status = Mechanic.Status.ACCEPTED, source = Mechanic.OrderSources.SYSTEM,
        clientName = "Test Client", targetShopId = "m1", shopKey = "user:owner", shopId = "m1",
        payout = 200, escrowState = "SYSTEM_FUNDED", tier = "regular",
    }
    data.orders[order.id] = order
    local originalRoll = Threats.RollTemperament
    Threats.RollTemperament = function(ctx, allowHostile)
        if temperament == "hostile" and not allowHostile then return "grumble" end
        return temperament
    end
    owner.inventory = newContainer("inventory")
    local before = #zombies
    handlers[Mechanic.Commands.COMPLETE_ORDER](owner, { orderId = order.id })
    Threats.RollTemperament = originalRoll
    return order, #zombies - before
end

local function ownerCash() return Economy.Balance(owner) + (tonumber(mechanicState().pendingCurrency["user:owner"]) or 0) end

do
    local order, spawned = walkIn("calm")
    assertEqual(spawned, 0, "customers never spawn a body; they are work orders")
    assertEqual(order.status, Mechanic.Status.CLOSED, "order closes on completion")
    assertEqual(order.escrowState, "RELEASED", "calm customer pays on completion")
    assertTrue(ownerCash() >= 200, "calm customer paid at least the full price (" .. ownerCash() .. ")")
end

do
    local order, spawned = walkIn("grumble")
    local paid = ownerCash()
    assertEqual(spawned, 0, "a grumbling customer spawns nothing")
    assertEqual(order.escrowState, "RELEASED", "grumbling customer pays on completion")
    assertTrue(paid >= 140 and paid <= 180, "grumbling customer haggled to 70-90% (" .. paid .. ")")
    assertEqual(order.paidAmount, paid, "the order records what was actually paid")
end

do
    local order, spawned = walkIn("hostile")
    assertEqual(ownerCash(), 0, "hostile customer paid nothing")
    assertEqual(order.escrowState, "WITHHELD", "payment is withheld")
    assertTrue(spawned >= 1, "the customer's crew is sent to the shop (" .. spawned .. ")")
    local hostile = true
    for _, zombie in ipairs(zombies) do if zombie.useless then hostile = false end end
    assertTrue(hostile, "the crew is hostile")
    advance(5)
    for _, zombie in ipairs(zombies) do kill(zombie) end
    advance(2)
    local cash = 0
    for _, item in ipairs(worldItems()) do
        if item.fullType == "Base.MoneyBundle" then cash = cash + 100 elseif item.fullType == "Base.Money" then cash = cash + 1 end
    end
    assertEqual(cash, 200, "the 200 owed dropped where the carrier fell")
    assertEqual(order.escrowState, "RECOVERED", "order records the recovered payment")
end

do
    local order = walkIn("hostile")
    advance(400) -- nobody fights them; they leave
    assertEqual(order.escrowState, "UNPAID", "a crew that gets away leaves the order unpaid")
end

do
    owner.x, owner.y = 300, 300
    local order, spawned = walkIn("hostile")
    assertEqual(spawned, 0, "no crew when the owner is away from the shop")
    assertEqual(order.escrowState, "RELEASED", "an away owner gets a haggle at worst, never a refusal")
    owner.x, owner.y = 105, 105
end

------------------------------------------------------------
-- DRUG DEALER: Syndicate shakedown and drop ambush
--
-- The Dealer server itself is stubbed (its adapter needs the real game), so
-- this drives KIPNCareers_DealerThreats.lua through a fake bridge.
------------------------------------------------------------
print("Drug Dealer threats")
do
    clearWorld()
    local dealerData = { businesses = {}, orders = {}, reputation = { ["user:owner"] = 60 } }
    local dealerNotices = {}
    package.preload["KIPNCareers_NarcoticsAdapter"] = function()
        KIPNCareers.NarcoticsAdapter = { Get = function(fullType) return fullType == "Base.Weed" and { type = fullType } or nil end }
        return KIPNCareers.NarcoticsAdapter
    end
    -- The Dealer's server file, as a stand-in. 1.3 names it KIPNCareers_DealerServer
    -- and registers threats through its career object; earlier versions used
    -- KIPNCareers_Server and registered with the threats layer themselves.
    local function dealerServer()
        require("KIPNCareers_DealerShared")
        local career = { id = (KIPNCareers.Dealer or KIPNCareers.Shared).CAREER_ID }
        function career:RegisterThreats(events)
            return Threats.Register(self.id, {
                businesses = function() return dealerData.businesses end,
                reputation = function(ownerKey) return dealerData.reputation[ownerKey] or 0 end,
                notify = function(ownerKey, title, body) dealerNotices[#dealerNotices + 1] = { title = title, body = body } end,
                events = events,
            })
        end
        local server = { Bridge = {
            career = career,
            state = function() return dealerData end, save = function() return true end,
            settings = function() return { FailureRepLoss = 5 } end, nowHours = function() return worldHours end,
            notify = function(ownerKey, title, body) dealerNotices[#dealerNotices + 1] = { title = title, body = body } end,
            reputationFor = function(ownerKey) return dealerData.reputation[ownerKey] or 0 end,
            businessById = function(id) return dealerData.businesses[id] end,
            onlinePlayerByIdentity = function() return owner end,
        } }
        KIPNCareers.Server, KIPNCareers.DealerServer = server, server
        return server
    end
    package.preload["KIPNCareers_Server"] = dealerServer
    package.preload["KIPNCareers_DealerServer"] = dealerServer
    require("KIPNCareers_DealerThreats")
    local Shared = KIPNCareers.Dealer or KIPNCareers.Shared
    local business = {
        id = "d1", careerId = Shared.CAREER_ID, ownerKey = "user:owner", name = "Corner Store", active = true,
        createdAt = worldHours - 200, bounds = { x1 = building.x1, y1 = building.y1, x2 = building.x2, y2 = building.y2, z1 = 0, z2 = 0 },
        anchor = { x = 105, y = 105, z = 0 },
    }
    dealerData.businesses.d1 = business
    dealerData.orders.o1 = { id = "o1", dealerKey = "user:owner", status = Shared.Status.DELIVERED, deliveredAt = worldHours - 10, payout = 1000 }

    local shakedown
    for _, event in ipairs(Threats._careers[Shared.CAREER_ID].events) do if event.id == "shakedown" then shakedown = event end end
    local ctx = Threats.Context(Shared.CAREER_ID, business)
    local bodies = #zombies
    assertTrue(shakedown.run(ctx) ~= nil, "the Syndicate makes a demand")
    assertEqual(#zombies, bodies, "the demand is a KIPN notice, not a body")
    assertTrue(dealerNotices[#dealerNotices].title == "Message from the Syndicate", "dealer was told the amount and deadline")
    local demand = dealerData.protection.d1
    assertTrue(demand.amount >= 100 and demand.amount <= 200, "demand is 10-20% of the week's 1000 (" .. demand.amount .. ")")
    assertEqual(shakedown.run(ctx), nil, "no second demand while one is open")

    -- Pay it: cash in a container inside the storefront.
    local safe = newContainer()
    safe:AddItem("Base.MoneyBundle") safe:AddItem("Base.MoneyBundle") safe:AddItem("Base.MoneyBundle")
    addContainerObject(103, 103, safe)
    advance(10)
    assertEqual(demand.status, "PAID", "the Syndicate collects from a storefront container")
    assertEqual(Economy.CountIn({ { container = safe } }), 300 - demand.amount, "exactly the demanded amount was taken")
    advance(200)

    -- Refuse the next one: overdue, then enforcers while the dealer is there.
    demand.status = "CLOSED"
    safe.list = {}
    assertTrue(shakedown.run(Threats.Context(Shared.CAREER_ID, business)) ~= nil, "a second, later demand")
    local refused = dealerData.protection.d1
    advance(60 * 26)
    assertTrue(refused.status == "OVERDUE" or refused.status == "COLLECTED", "an unpaid demand goes overdue (" .. refused.status .. ")")
    local waited = 0
    while refused.status == "OVERDUE" and waited < 600 do advance(10) waited = waited + 10 end
    assertEqual(refused.status, "COLLECTED", "enforcers turn up at the storefront")
    local warned = false
    for _, notice in ipairs(dealerNotices) do if notice.title == "The Syndicate came to collect" then warned = true end end
    assertTrue(warned, "the enforcer crew hit the storefront and the dealer was told")
    advance(400)

    -- Drop ambush: goods in the drop container get taken, and drop back when killed.
    clearWorld()
    root.careers.threats.businesses["drug_dealer:d1"] = nil
    local drop = newContainer()
    for _ = 1, 5 do drop:AddItem("Base.Weed") end
    drop:AddItem("Base.Apple")
    local dropObject = addContainerObject(150, 150, drop)
    local order = { id = "o2", dealerBusinessId = "d1", itemType = "Base.Weed" }
    owner.x, owner.y = 150, 150
    SandboxVars.KIPNCareers.ThreatFrequencyPercent = 300
    local originalRoll = Threats.RollMoment
    Threats.RollMoment = function(careerId, b, percent, player) return Threats.Context(careerId, b, player) end
    KIPNCareers.DealerThreats.OnDrop(order, owner, 150, 150, 0, dropObject)
    Threats.RollMoment = originalRoll
    local ambush
    for _, incident in pairs(Threats._incidents) do if incident.kind == "ambush" then ambush = incident end end
    assertTrue(ambush ~= nil and ambush.hostile, "a hostile crew ambushes the drop")
    local minutes = 0
    while drop:count("Base.Weed") > 0 and minutes < 60 do advance(1) minutes = minutes + 1 end
    assertEqual(drop:count("Base.Weed"), 0, "they took the whole delivery from the drop")
    assertEqual(drop:count("Base.Apple"), 1, "and only the delivery")
    for _, zombie in ipairs(zombies) do kill(zombie) end
    advance(2)
    local recovered = 0
    for _, item in ipairs(worldItems()) do if item.fullType == "Base.Weed" then recovered = recovered + 1 end end
    assertEqual(recovered, 5, "killing the crew drops the delivery back on the ground")
    assertTrue(dealerNotices[#dealerNotices].title == "Package recovered", "dealer is told to put it back before completing")
    owner.x, owner.y = 105, 105
    SandboxVars.KIPNCareers.ThreatFrequencyPercent = nil
end

print(string.format("\n%d/%d passed", total - failed, total))
os.exit(failed == 0 and 0 or 1)
