-- Loads the framework and the three careers' real server code together, in
-- a small fake world, and drives the real commands: the framework's Economy,
-- Storefronts, ZoneBridge, career registration, shared inbox, flyers and
-- storefront closing, and each career's license and storefront flow on them.
-- Run from this Workshop project directory: lua tests/framework_checks.lua
-- The career projects are expected beside this one (../CareersMechanic, ...);
-- set CAREERS_WORKSHOP to point somewhere else.
local L = os.getenv("CAREERS_WORKSHOP") or ".."
do
    local probe = io.open(L .. "/CareersMechanic/Contents/mods/CareersMechanic/42/media/lua/shared/KIPNCareers_MechanicShared.lua", "r")
    if not probe then print("framework_checks: SKIPPED (career projects not found beside this one)") return end
    probe:close()
end
local function lua(dir, mod) return L .. "/" .. dir .. "/Contents/mods/" .. mod .. "/42/media/lua/" end
local path = ""
for _, pair in ipairs({ { "KIPN_Careers", "CareersFramework" }, { "CareersMechanic", "CareersMechanic" },
    { "CareersBlacksmith", "CareersBlacksmith" }, { "CareersDrugDealer", "CareersDrugDealer" } }) do
    local base = lua(pair[1], pair[2])
    path = path .. base .. "shared/?.lua;" .. base .. "server/?.lua;"
end
package.path = path .. package.path

------------------------------------------------------------
-- Fake world
------------------------------------------------------------
local function list(items)
    local self = { items = items or {} }
    function self:size() return #self.items end
    function self:get(index) return self.items[index + 1] end
    return self
end
local seed = 1
function ZombRand(a, b)
    seed = (seed * 1103515245 + 12345) % 2147483648
    local minimum, maximum = 0, a - 1
    if b ~= nil then minimum, maximum = a, b - 1 end
    if maximum < minimum then return minimum end
    return minimum + seed % (maximum - minimum + 1)
end
local worldHours = 100
function getGameTime() return { getWorldAgeHours = function() return worldHours end } end
function getTimestampMs() return 0 end
function isClient() return false end
function isServer() return true end
function instanceof(object, class) return type(object) == "table" and object.__class == class end
function sendRemoveItemFromContainer() end
function sendAddItemToContainer() end
function sendItemStats() end
Events = setmetatable({}, { __index = function(events, name)
    local event = { Add = function() end, Remove = function() end }
    rawset(events, name, event)
    return event
end })
SandboxVars = { KIPNCareers = {} }

local function newItem(fullType)
    local item = { fullType = fullType, modData = {} }
    function item:getFullType() return self.fullType end
    function item:getModData() return self.modData end
    function item:getContainer() return self.container end
    function item:setName(name) self.name = name end
    return item
end
local function newContainer()
    local container = { list = {} }
    function container:getItems() return list(self.list) end
    function container:getType() return "inventory" end
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
        for _, item in ipairs(self.list) do if item.fullType == fullType then total = total + 1 end end
        return total
    end
    return container
end

-- Buildings, by name. A player stands in at most one.
local buildings = {
    A = { x1 = 100, y1 = 100, x2 = 110, y2 = 110 },
    B = { x1 = 200, y1 = 200, x2 = 210, y2 = 210 },
    C = { x1 = 300, y1 = 300, x2 = 310, y2 = 310 }, -- under a No Claim zone
    D = { x1 = 108, y1 = 108, x2 = 120, y2 = 120 }, -- overlaps A's corner
    E = { x1 = 400, y1 = 400, x2 = 410, y2 = 410 },
}
local function newPlayer(name, access)
    local player = { name = name, x = 0, y = 0, inventory = newContainer(), access = access or "none", __class = "IsoPlayer" }
    function player:getX() return self.x end
    function player:getY() return self.y end
    function player:getZ() return 0 end
    function player:isDead() return false end
    function player:getSteamID() return "0" end
    function player:getUsername() return self.name end
    function player:getInventory() return self.inventory end
    function player:getAccessLevel() return self.access end
    function player:getSquare()
        local inside = self.building and buildings[self.building]
        local def = inside and { getX = function() return inside.x1 end, getY = function() return inside.y1 end, getX2 = function() return inside.x2 end, getY2 = function() return inside.y2 end }
        return { getBuilding = function() return def and { getDef = function() return def end } or nil end }
    end
    function player:standIn(name)
        self.building = name
        self.x, self.y = buildings[name].x1 + 2, buildings[name].y1 + 2
    end
    return player
end
local players = {}
function getOnlinePlayers() return list(players) end
function getCell() return { getGridSquare = function() return nil end } end

-- KIPN host: data, command router, world registry (zones), computers.
local root, sent, handlers, zones, granted, revoked = {}, {}, {}, {}, {}, {}
local zoneSequence = 0
local servicesComputer = { x = 50, y = 50, z = 0 }
local registry = {}
function registry.RegisterZoneType() return true end
function registry.CreateZoneFromCorners(zoneType, a, b, metadata, capabilities)
    zoneSequence = zoneSequence + 1
    local zone = { id = "zone-" .. zoneSequence, type = zoneType, metadata = metadata, capabilities = capabilities, active = true,
        geometry = { x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y, z1 = a.z, z2 = b.z } }
    zones[zone.id] = zone
    return zone
end
function registry.GetZones(zoneType, includeInactive)
    local out = {}
    for id, zone in pairs(zones) do
        if (not zoneType or zone.type == zoneType) and (includeInactive or zone.active) then out[id] = zone end
    end
    return out
end
function registry.UpdateZone(id, changes)
    if not zones[id] then return nil, "ZONE_NOT_FOUND" end
    for key, value in pairs(changes) do zones[id][key] = value end
    return true
end
function registry.SetZoneActive(id, active)
    if not zones[id] then return nil, "ZONE_NOT_FOUND" end
    zones[id].active = active
    return true
end
function registry.GetComputerCapabilities(computerId)
    return computerId == "services" and { ["career.services"] = true } or {}
end
KIPN = {
    Server = {
        GetData = function() return root end,
        Save = function() return true end,
        SendToPlayer = function(player, event, payload) sent[#sent + 1] = { player = player, event = event, payload = payload } return true end,
        RegisterCommandHandler = function(command, handler)
            if handlers[command] then return false end
            handlers[command] = handler
            return true
        end,
        GetCommandHandler = function(command) return handlers[command] end,
        GetComputer = function(id) return (id == "services" or id == "elsewhere") and servicesComputer or nil end,
        AuthService = { GetPlayerSession = function() return { authenticated = true } end },
        WorldRegistry = registry,
        Permissions = {
            GrantPermission = function(id, permission) granted[#granted + 1] = permission return true end,
            RevokePermission = function(id, permission) revoked[#revoked + 1] = permission return true end,
        },
    },
    Shared = { Commands = { SERVER_RESPONSE = "response" }, GetPlayerId = function(player) return "user:" .. player.name end }, -- the server account, as KIPN returns it
}

local total, failed = 0, 0
local function check(ok, description)
    total = total + 1
    if not ok then failed = failed + 1 end
    io.write((ok and "  PASS  " or "  FAIL  ") .. description .. "\n")
end
local function equal(actual, expected, description)
    check(actual == expected, description .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

------------------------------------------------------------
-- Load everything, the way a server with all four mods does
------------------------------------------------------------
package.preload["KIPNCareers_NarcoticsAdapter"] = function()
    KIPNCareers.NarcoticsAdapter = {
        available = true, modActive = true, Initialize = function() end,
        Get = function() return nil end, GetCatalog = function() return {} end, SelectForReputation = function() return nil end,
    }
    return KIPNCareers.NarcoticsAdapter
end
for _, name in ipairs({ "KIPNCareers_Shared", "KIPNCareers_Host", "KIPNCareers_Economy", "KIPNCareers_ZoneBridge",
    "KIPNCareers_Storefronts", "KIPNCareers_Careers", "KIPNCareers_Services", "KIPNCareers_Init", "KIPNCareers_Threats",
    "KIPNCareers_MechanicServer", "KIPNCareers_MechanicThreats",
    "KIPNCareers_BlacksmithServer", "KIPNCareers_BlacksmithThreats",
    "KIPNCareers_DealerServer", "KIPNCareers_DealerThreats" }) do
    require(name)
end
local Shared, Economy, Storefronts, ZoneBridge, Threats = KIPNCareers.Shared, KIPNCareers.Economy, KIPNCareers.Storefronts, KIPNCareers.ZoneBridge, KIPNCareers.Threats
local Mechanic, Blacksmith, Dealer = KIPNCareers.Mechanic, KIPNCareers.Blacksmith, KIPNCareers.Dealer
local Host, Careers = KIPNCareers.Host, KIPNCareers.Careers
Shared.Log = function(scope, level, message) if level == "Error" then io.write("    [log] " .. tostring(message) .. "\n") end end

print("Load and registration")
check(KIPNCareers.Services.Initialize() == true, "Framework services initialize")
check(KIPNCareers.MechanicServer.Initialize() == true, "Mechanic initializes")
check(KIPNCareers.BlacksmithServer.Initialize() == true, "Blacksmith initializes")
check(KIPNCareers.DealerServer.Initialize() == true, "Drug Dealer initializes")
do
    local providers = 0
    for _ in pairs(Storefronts._providers) do providers = providers + 1 end
    equal(providers, 3, "three storefront providers registered")
    local careers = 0
    for _ in pairs(Threats._careers) do careers = careers + 1 end
    equal(careers, 3, "three careers registered for threats")
    local commands, seen, clash = {}, {}, nil
    for _, set in ipairs({ Mechanic.Commands, Blacksmith.Commands, Dealer.Commands, Shared.Commands }) do
        for _, command in pairs(set) do
            if seen[command] then clash = command end
            seen[command] = true
            commands[#commands + 1] = command
        end
    end
    check(clash == nil, "no two careers share a command name" .. (clash and (": " .. clash) or ""))
    local missing
    for _, command in ipairs(commands) do if not handlers[command] then missing = command end end
    check(missing == nil, "every declared command has a handler" .. (missing and (": " .. missing) or ""))
end

local careers = {
    { name = "Mechanic", buy = Mechanic.Commands.BUY_LICENSE, start = Mechanic.Commands.START_SHOP, license = Mechanic.Items.LICENSE,
      price = Mechanic.Defaults.LICENSE_PRICE, capability = Mechanic.Capabilities.SHOP, permission = Mechanic.Permissions.OWNER,
      records = function() return root.careers.mechanic.shops end, sandboxPrice = "MechanicLicensePrice" },
    { name = "Blacksmith", buy = Blacksmith.Commands.BUY_LICENSE, start = Blacksmith.Commands.START_SHOP, license = Blacksmith.Items.LICENSE,
      price = Blacksmith.Defaults.LICENSE_PRICE, capability = Blacksmith.Capabilities.SHOP, permission = Blacksmith.Permissions.OWNER,
      records = function() return root.careers.blacksmith.shops end, sandboxPrice = "BlacksmithLicensePrice" },
    { name = "Drug Dealer", buy = Dealer.Commands.BUY_LICENSE, start = Dealer.Commands.START_BUSINESS, license = Dealer.Items.LICENSE,
      price = Dealer.Defaults.LICENSE_PRICE, capability = Dealer.Capabilities.BUSINESS, permission = Dealer.Permissions.BUSINESS_OWNER,
      records = function() return root.careers.drug_dealer.businesses end, sandboxPrice = "DrugDealerLicensePrice" },
}
local function lastResult() return sent[#sent] and sent[#sent].payload or {} end
local function count(records) local n = 0 for _ in pairs(records) do n = n + 1 end return n end

------------------------------------------------------------
print("Economy: buying a license")
------------------------------------------------------------
local owners = {}
for index, career in ipairs(careers) do
    local player = newPlayer("owner" .. index)
    players[#players + 1] = player
    owners[index] = player
    player.x, player.y = 51, 51 -- beside the Career Services terminal

    handlers[career.buy](player, { computerId = "services" })
    equal(lastResult().code, "INSUFFICIENT_FUNDS", career.name .. ": no money, no license")
    equal(player.inventory:count(career.license), 0, career.name .. ": nothing was issued")

    Economy.GrantNow(player, career.price + 300)
    handlers[career.buy](player, { computerId = "elsewhere" })
    check(lastResult().ok == false and Economy.Balance(player) == career.price + 300, career.name .. ": refused away from a Career Services zone, nothing charged (" .. tostring(lastResult().code) .. ")")

    handlers[career.buy](player, { computerId = "services" })
    equal(lastResult().code, "LICENSE_ISSUED", career.name .. ": license bought")
    equal(Economy.Balance(player), 300, career.name .. ": charged exactly the license price " .. career.price)
    equal(player.inventory:count(career.license), 1, career.name .. ": one license item issued")
    career.tokenId = lastResult().tokenId
end

------------------------------------------------------------
print("ZoneBridge: No Claim zones")
------------------------------------------------------------
registry.CreateZoneFromCorners("no_claim", { x = 295, y = 295, z = 0 }, { x = 315, y = 315, z = 0 }, { name = "Town Hall" }, {})
for index, career in ipairs(careers) do
    owners[index]:standIn("C")
    handlers[career.start](owners[index], { tokenId = career.tokenId })
    equal(lastResult().code, "NO_CLAIM_ZONE", career.name .. ": cannot open in a No Claim zone")
    equal(owners[index].inventory:count(career.license), 1, career.name .. ": license kept")
end

------------------------------------------------------------
print("Storefronts: one storefront per building, across careers")
------------------------------------------------------------
-- The Mechanic takes building A; the other two careers then try A and the
-- overlapping building D before settling elsewhere.
owners[1]:standIn("A")
handlers[careers[1].start](owners[1], { tokenId = careers[1].tokenId })
equal(lastResult().code, "SHOP_STARTED", "Mechanic opens in building A")
for index = 2, 3 do
    local career = careers[index]
    for _, name in ipairs({ "A", "D" }) do
        owners[index]:standIn(name)
        handlers[career.start](owners[index], { tokenId = career.tokenId })
        equal(lastResult().code, "STOREFRONT_OCCUPIED", career.name .. ": blocked in building " .. name .. " by the Mechanic's shop")
    end
    equal(count(career.records()), 0, career.name .. ": no record was written")
    equal(owners[index].inventory:count(career.license), 1, career.name .. ": license kept")
end
owners[2]:standIn("B")
handlers[careers[2].start](owners[2], { tokenId = careers[2].tokenId })
equal(lastResult().code, "SHOP_STARTED", "Blacksmith opens in building B")
owners[3]:standIn("B")
handlers[careers[3].start](owners[3], { tokenId = careers[3].tokenId })
equal(lastResult().code, "STOREFRONT_OCCUPIED", "Drug Dealer: blocked in building B by the Blacksmith's shop")
owners[3]:standIn("E")
handlers[careers[3].start](owners[3], { tokenId = careers[3].tokenId })
check(lastResult().ok == true, "Drug Dealer opens in building E (" .. tostring(lastResult().code) .. ")")
do
    local hit, careerId = Storefronts.Overlaps(buildings.E)
    check(hit and careerId == "drug_dealer", "the registry reports the Dealer's storefront in E")
    local ignored = Storefronts.Overlaps(buildings.E, "drug_dealer", next(careers[3].records()))
    check(ignored == false, "and skips it when asked to ignore that record")
end

------------------------------------------------------------
print("ZoneBridge: each storefront gets its capability zone")
------------------------------------------------------------
for index, career in ipairs(careers) do
    local _, record = next(career.records())
    local zone = record and zones[record.capabilityZoneId]
    check(zone ~= nil, career.name .. ": storefront record points at a zone")
    if zone then
        check(zone.type == "custom" and zone.capabilities[career.capability] == true, career.name .. ": zone carries " .. career.capability)
        check(zone.geometry.x1 == record.bounds.x1 and zone.geometry.y2 == record.bounds.y2, career.name .. ": zone covers the building")
        equal(zone.metadata.careerBusinessId, record.id, career.name .. ": zone is tagged with the storefront id the framework way")
        equal(zone.metadata.category, "Careers", career.name .. ": zone is in the Careers category")
    end
    equal(owners[index].inventory:count(career.license), 0, career.name .. ": license was used up")
    local has = false
    for _, permission in ipairs(granted) do if permission == career.permission then has = true end end
    check(has, career.name .. ": owner permission granted")
end

------------------------------------------------------------
print("Storefronts: lookup by place and by owner")
------------------------------------------------------------
do
    local careerId, id, record = Storefronts.At(102, 102, 0)
    check(careerId == "mechanic" and record and record.ownerKey == "user:owner1" and id == record.id, "At finds the Mechanic's shop in building A")
    check(Storefronts.At(50, 50, 0) == nil, "At finds nothing in the street")
    local owned = Storefronts.ForOwner("user:owner3")
    check(#owned == 1 and owned[1].careerId == "drug_dealer", "ForOwner lists the Dealer's one storefront")
    equal(#Storefronts.ForOwner("user:nobody"), 0, "ForOwner lists nothing for someone with no storefront")
    local hit, careerId2 = Storefronts.Overlaps(buildings.E)
    check(hit and careerId2 == Dealer.CAREER_ID, "one id per career: the registry and the career agree")
    check(Threats._careers[Dealer.CAREER_ID] ~= nil and Careers.Get(Dealer.CAREER_ID) ~= nil, "and so do threats and the career registry")
end

------------------------------------------------------------
print("Inbox: one inbox for every career, answered by the framework")
------------------------------------------------------------
do
    local function inboxFor(player)
        handlers[Shared.Commands.INBOX](player, { requestId = "r1" })
        return sent[#sent]
    end
    local before = #sent
    Careers.Get("mechanic"):Notify("user:owner1", "Test <notice>", "From the garage")
    local events = {}
    for index = before + 1, #sent do events[sent[index].event] = sent[index].payload end
    check(events[Mechanic.Events.NOTIFICATION] ~= nil, "a Mechanic notice still reaches the Mechanic's own screen")
    check(events[Shared.Events.INBOX_CHANGED] ~= nil, "and tells the inbox screen to refresh")
    local reply = inboxFor(owners[1])
    equal(reply.event, Shared.Events.INBOX, "the framework answers careers.inbox")
    check(reply.payload.hasBusiness == true, "a Mechanic owner is shown MY BUSINESS (was Drug Dealer owners only)")
    local last = reply.payload.notifications[#reply.payload.notifications]
    check(last.title == "Test (notice)" and last.source == "mechanic" and last.unread == true, "the notice is filed, cleaned and tagged with its career")
    handlers[Shared.Commands.MARK_INBOX_READ](owners[1], { ids = { last.id } })
    check(root.careers.notifications["user:owner1"][#root.careers.notifications["user:owner1"]].unread == false, "marking it read sticks")
    local stranger = newPlayer("stranger")
    check(inboxFor(stranger).payload.hasBusiness == false, "someone with no storefront is not shown MY BUSINESS")
    local published
    Careers.SetNotificationPublisher(function(ownerKey, notice, careerId) published = careerId .. ":" .. ownerKey end)
    Careers.Get(Dealer.CAREER_ID):Notify("user:owner3", "Hello", "From the corner")
    equal(published, "drug_dealer:user:owner3", "a notification publisher hears every career's notices")
    Careers.SetNotificationPublisher(nil)
end

------------------------------------------------------------
print("ZoneBridge: zone types, and the admin editor in the framework")
------------------------------------------------------------
do
    local admin, pleb = newPlayer("admin", "admin"), newPlayer("pleb")
    local args = { zoneType = Shared.ZoneTypes.CAREER_SERVICES, cornerA = { x = 1, y = 1, z = 0 }, cornerB = { x = 9, y = 9, z = 0 }, name = "Job <Centre>" }
    handlers[Shared.Commands.ADMIN_CREATE_ZONE](pleb, args)
    equal(lastResult().code, "ADMIN_REQUIRED", "a non-admin cannot create a Career Services zone")
    handlers[Shared.Commands.ADMIN_CREATE_ZONE](admin, args)
    local zone = lastResult().zone
    check(lastResult().ok and zone and zone.type == "career_services" and zone.capabilities["career.services"] == true, "an admin creates one")
    equal(sent[#sent].event, Shared.Events.RESULT, "the answer goes out on the framework's result event")
    equal(zone and zone.metadata.name, "Job (Centre)", "its name is cleaned")
    handlers[Shared.Commands.ADMIN_TOGGLE_ZONE](admin, { zoneId = zone.id, active = false })
    check(zones[zone.id].active == false and count(ZoneBridge.GetZones("career_services", false)) == 0, "and can switch it off")

    handlers[Shared.Commands.ADMIN_CREATE_ZONE](admin, { zoneType = "smithing_district", cornerA = args.cornerA, cornerB = args.cornerB })
    equal(lastResult().code, "INVALID_ZONE_TYPE", "an unregistered zone type is refused")
    check(ZoneBridge.RegisterZoneType("smithing_district", { label = "Smithing District", capabilities = { ["career.smith.district"] = true } }), "a career registers its own zone type")
    handlers[Shared.Commands.ADMIN_CREATE_ZONE](admin, { zoneType = "smithing_district", cornerA = args.cornerA, cornerB = args.cornerB })
    zone = lastResult().zone
    check(lastResult().ok and zone and zone.capabilities["career.smith.district"] == true and zone.capabilities["career.services"] == nil,
        "and an admin can draw it, with that type's capabilities")
    equal(zone and zone.metadata.name, "Smithing District", "an unnamed zone takes its type's label")
end

------------------------------------------------------------
print("Flyers: queued at start-up, left in loot")
------------------------------------------------------------
do
    SandboxVars.KIPNCareers.FlyerSpawnChancePercent = 100
    for index, career in ipairs(careers) do
        local object = Careers.Get(index == 3 and Dealer.CAREER_ID or career.name:lower())
        local _, record = next(career.records())
        record.flyerRevision, record.name = 2, career.name .. " Co"
        check(object:ActivateFlyerQueue() == true, career.name .. ": the new flyer revision is queued")
        local crate = newContainer()
        function crate:getType() return "crate" end
        local wardrobe = newContainer()
        function wardrobe:getType() return "wardrobe" end
        check(object:DistributeFlyer({ getContainer = function() return wardrobe end }) == false, career.name .. ": no flyer in a wardrobe")
        check(object:DistributeFlyer({ getContainer = function() return crate end }) == true, career.name .. ": a flyer is left in a crate")
        local flyer = crate.list[1]
        local named
        for key, value in pairs(flyer and flyer.modData or {}) do if value == career.name .. " Co" then named = key end end
        check(flyer and flyer.fullType == Shared.Items.FLYER and named ~= nil, career.name .. ": it is the shared flyer item, carrying the business name (" .. tostring(named) .. ")")
        local queue = object:State().flyerQueue[record.id]
        equal(queue and queue.remaining, Shared.Defaults.FLYERS_PER_RESTART - 1, career.name .. ": one fewer left to hand out")
    end
    SandboxVars.KIPNCareers.FlyerSpawnChancePercent = nil
end

------------------------------------------------------------
print("Storefronts: closing one")
------------------------------------------------------------
do
    local mechanic = careers[1]
    local _, shop = next(mechanic.records())
    handlers[Shared.Commands.CLOSE_STOREFRONT](owners[2], { careerId = "mechanic", storefrontId = shop.id })
    equal(lastResult().code, "NOT_YOUR_STOREFRONT", "another player cannot close the Mechanic's shop")
    handlers[Shared.Commands.CLOSE_STOREFRONT](owners[1], { careerId = "mechanic", storefrontId = shop.id })
    equal(lastResult().code, "STOREFRONT_CLOSED", "the owner closes their own shop")
    check(shop.active == false and shop.closedAt ~= nil, "the record is kept, inactive")
    check(zones[shop.capabilityZoneId].active == false, "its capability zone is switched off")
    local lost = false
    for _, permission in ipairs(revoked) do if permission == mechanic.permission then lost = true end end
    check(lost, "the owner permission is revoked")
    check(Storefronts.Overlaps(buildings.A) == false, "building A is free again")
    check(Careers.Get("mechanic"):State().flyerQueue[shop.id] == nil, "its flyers stop")
    local notices = root.careers.notifications["user:owner1"]
    equal(notices[#notices].title, "Storefront closed", "the owner is told")
    handlers[Shared.Commands.CLOSE_STOREFRONT](owners[1], { careerId = "mechanic", storefrontId = shop.id })
    equal(lastResult().code, "STOREFRONT_NOT_FOUND", "it cannot be closed twice")
    -- The Blacksmith may now take the building the Mechanic left... once they have a license again.
    local admin = newPlayer("admin", "admin")
    local _, business = next(careers[3].records())
    handlers[Shared.Commands.CLOSE_STOREFRONT](admin, { careerId = Dealer.CAREER_ID, storefrontId = business.id })
    check(lastResult().ok == true and business.active == false, "an admin can close anyone's storefront")
    equal(#Storefronts.ForOwner("user:owner3"), 0, "and it no longer counts as the owner's business")
end

------------------------------------------------------------
print("Economy: prices, currency and money owed")
------------------------------------------------------------
do
    check(Economy.IsCurrency("Base.Money") and Economy.IsCurrency("Base.MoneyBundle") and not Economy.IsCurrency("Base.GoldCoin"),
        "default currency: notes and bundles are currency, a gold coin is not")
    equal(Economy.Price(750), 750, "at value 1 a price is left alone")

    Economy._cache = nil
    SandboxVars.KIPNCareers.CurrencyItemType = "Base.GoldCoin"
    SandboxVars.KIPNCareers.CurrencyItemValue = 20
    function getScriptManager() return { FindItem = function() return {} end } end
    equal(Economy.ItemValue(), 20, "a 20-value custom currency is in force")
    check(Economy.IsCurrency("Base.GoldCoin") and not Economy.IsCurrency("Base.Money"), "the gold coin is the currency now, notes are not")
    equal(Economy.Price(750), 760, "a 750 price becomes 760, the next amount 20-value coins can pay")
    equal(Economy.Price(760), 760, "an exact multiple is left alone")
    equal(Economy.Price(0), 0, "free stays free")
    for index, career in ipairs(careers) do
        local player = newPlayer("coin" .. index)
        player.x, player.y = 51, 51
        for _ = 1, 100 do player.inventory:AddItem("Base.GoldCoin") end -- worth 2000
        SandboxVars.KIPNCareers[career.sandboxPrice] = 750
        handlers[career.buy](player, { computerId = "services" })
        check(lastResult().code == "LICENSE_ISSUED" and Economy.Balance(player) == 1240, career.name .. ": a 750 license is sold for 760 in coins (was refused)")
        SandboxVars.KIPNCareers[career.sandboxPrice] = nil
    end
    Economy._cache = nil
    SandboxVars.KIPNCareers.CurrencyItemType, SandboxVars.KIPNCareers.CurrencyItemValue = nil, nil

    local ledger, payee = {}, newPlayer("payee")
    check(Economy.Credit(ledger, "user:payee", 150) and Economy.Credit(ledger, "user:payee", 50), "money owed adds up in a ledger")
    equal(Economy.Pending(ledger, "user:payee"), 200, "200 is owed")
    local ok, paid = Economy.Settle(ledger, "user:payee", payee)
    check(ok and paid == 200 and Economy.Balance(payee) == 200 and ledger["user:payee"] == nil, "settling pays it into the inventory and clears the ledger")
    ok, paid = Economy.Settle(ledger, "user:payee", payee)
    check(ok and paid == 0, "settling again pays nothing")
end

------------------------------------------------------------
print("Drug Dealer: old sandbox names and old save data")
------------------------------------------------------------
do
    local buyer = newPlayer("legacy")
    buyer.x, buyer.y = 51, 51
    Economy.GrantNow(buyer, 1000)
    SandboxVars.KIPNCareers.LicensePrice = 300 -- the name before 1.3
    handlers[Dealer.Commands.BUY_LICENSE](buyer, { computerId = "services" })
    equal(Economy.Balance(buyer), 700, "an old un-prefixed LicensePrice is still read")
    SandboxVars.KIPNCareers.DrugDealerLicensePrice = 200
    handlers[Dealer.Commands.BUY_LICENSE](buyer, { computerId = "services" })
    equal(Economy.Balance(buyer), 500, "the DrugDealer-prefixed name wins when both are set")
    SandboxVars.KIPNCareers.LicensePrice, SandboxVars.KIPNCareers.DrugDealerLicensePrice = nil, nil

    -- A 1.2 save: the Dealer's tables at the root of careers, beside the others' slices.
    local mechanicSlice, inbox = root.careers.mechanic, root.careers.notifications
    for name in pairs(root.careers) do root.careers[name] = nil end
    root.careers.mechanic, root.careers.notifications = mechanicSlice, inbox
    root.careers.businesses = { b1 = { id = "b1", careerId = "drug_dealer", ownerKey = "user:old", active = true, bounds = buildings.B, anchor = { x = 201, y = 201, z = 0 } } }
    root.careers.licenses = { l1 = { id = "l1", status = "REDEEMED" } }
    root.careers.orders = { o1 = { id = "o1", status = "OPEN" } }
    root.careers.reputation = { ["user:old"] = 77 }
    root.careers.pendingCurrency = { ["user:old"] = 40 }
    root.careers.protection = { b1 = { status = "PAID" } }
    root.careers.sequence, root.careers.schemaVersion = 41, 2
    local career = Careers.Get(Dealer.CAREER_ID)
    career._migrated = nil -- as on a fresh server start
    local data = career:State()
    check(root.careers.drug_dealer == data and data.businesses.b1 ~= nil and data.orders.o1 ~= nil and data.licenses.l1 ~= nil, "the old tables are now in careers.drug_dealer")
    check(data.reputation["user:old"] == 77 and data.pendingCurrency["user:old"] == 40 and data.protection.b1 ~= nil, "reputation, money owed and Syndicate demands came along")
    check(root.careers.businesses == nil and root.careers.orders == nil and root.careers.sequence == nil, "and are gone from the root")
    equal(data.sequence, 41, "ids carry on from the old sequence")
    equal(data.schemaVersion, Dealer.SCHEMA_VERSION, "the slice is marked with the new schema version")
    check(root.careers.mechanic == mechanicSlice and root.careers.notifications == inbox, "the Mechanic's slice and the shared inbox are untouched")
    equal(career:ReputationFor("user:old"), 77, "the career reads the moved data")
    check(Storefronts.Overlaps(buildings.B) == true, "the old storefront still blocks its building")
    career._migrated = nil
    root.careers.businesses = { stray = { id = "stray" } }
    data = career:State()
    check(data.businesses.b1 ~= nil and data.businesses.stray == nil, "it runs once: a later start does not overwrite the slice")
end

print(string.format("\n%d/%d passed", total - failed, total))
os.exit(failed == 0 and 0 or 1)
