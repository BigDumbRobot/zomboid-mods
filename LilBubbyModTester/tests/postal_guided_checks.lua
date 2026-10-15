-- Offline checks for the guided post office test's server half: the building
-- it picks, what it sets up there, the boxes it places for the player without
-- making them an admin, the check behind each step's OK, the delivery and its
-- replays, and its cleanup. KIPN and The Post
-- Office are stand-ins; LilBubbyDesk and LilBubbyTeleport are the real files.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
print = function() end
require = function() end
function isServer() return true end
function isClient() return false end
function getTimestampMs() return 0 end
Events = { EveryOneMinute = { Add = function() end } }
local modData = {}
ModData = { getOrCreate = function(tag) modData[tag] = modData[tag] or {}; return modData[tag] end }

------------------------------------------------------------
-- World: open ground with two buildings
------------------------------------------------------------
local function building(x, y, w, h)
    local b = {}
    function b:getDef()
        return { getX = function() return x end, getY = function() return y end,
            getW = function() return w end, getH = function() return h end }
    end
    return b
end
local guarded = building(92, 200, 6, 6)  -- nearer the player, under a safehouse
local office = building(110, 200, 10, 8) -- the one the test should pick
local function buildingAt(x, y)
    if x >= 92 and x <= 97 and y >= 200 and y <= 205 then return guarded end
    if x >= 110 and x <= 119 and y >= 200 and y <= 207 then return office end
end
local squares = {}
local function square(x, y, z)
    local key = x .. "," .. y .. "," .. z
    if not squares[key] then
        local s = { x = x, y = y, z = z, objects = {} }
        function s:getX() return self.x end
        function s:getY() return self.y end
        function s:getZ() return self.z end
        function s:TreatAsSolidFloor() return true end
        function s:isFree() return #self.objects == 0 end
        function s:getBuilding() return buildingAt(self.x, self.y) end
        function s:isOutside() return buildingAt(self.x, self.y) == nil end
        function s:getObjects() local o = self.objects; return { size = function() return #o end, get = function(_, i) return o[i + 1] end } end
        function s:AddTileObject(object) object.square = self; self.objects[#self.objects + 1] = object end
        function s:transmitRemoveItemFromSquare(object)
            for i, x in ipairs(self.objects) do if x == object then table.remove(self.objects, i) end end
            object.square = nil
        end
        squares[key] = s
    end
    return squares[key]
end
function getCell() return { getGridSquare = function(_, x, y, z) return square(x, y, z) end } end

local function worldObject(sprite)
    local o = { modData = {}, sprite = sprite }
    function o:getModData() return self.modData end
    function o:getSprite() return { getName = function() return sprite end } end
    function o:getSquare() return self.square end
    function o:transmitCompleteItemToClients() end
    function o:isLockedToCharacter() return false end
    function o:isLockedByPadlock() return true end
    function o:getKeyId() return self.keyId end
    function o:getContainer() local c = self.capacity; return { getCapacity = function() return c end } end
    return o
end
IsoObject = { new = function(_, sprite) return worldObject(sprite) end }
IsoGenerator = { new = function(_, _, sq)
    local g = worldObject("generator")
    g.isGenerator, g.fuel, g.max = true, 0, 10
    function g:setCondition() end
    function g:setFuel(v) self.fuel = v end
    function g:getMaxFuel() return self.max end
    function g:setConnected(v) self.connected = v end
    function g:setActivated(v) self.activated = v end
    function g:setSurroundingElectricity() end
    function g:sync() end
    function g:remove() end
    sq:AddTileObject(g)
    return g
end }
function instanceof(o, class) return class == "IsoGenerator" and o.isGenerator == true end
function instanceItem() return { setCondition = function() end } end
function getScriptManager() return { FindItem = function() return { getDisplayName = function() return "Blank Key" end } end } end

------------------------------------------------------------
-- The player and their inventory
------------------------------------------------------------
local inventory = { items = {} }
local nextItem = 0
local function item(fullType)
    nextItem = nextItem + 1
    local i = { fullType = fullType, modData = {}, container = inventory, id = nextItem }
    function i:getID() return self.id end
    function i:getFullType() return self.fullType end
    function i:getModData() return self.modData end
    function i:getContainer() return self.container end
    function i:getKeyId() return self.keyId end
    return i
end
function inventory:getItems()
    local items = self.items
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
function inventory:AddItem(fullType) local i = item(fullType); self.items[#self.items + 1] = i; return i end
function inventory:Remove(target)
    for i, x in ipairs(self.items) do if x == target then table.remove(self.items, i) end end
end
local function count(fullType)
    local n = 0
    for _, i in ipairs(inventory.items) do if i.fullType == fullType then n = n + 1 end end
    return n
end
sendAddItemToContainer, sendRemoveItemFromContainer = function() end, function() end

local px, py = 85, 203
local online = true
local player = { getUsername = function() return "Tester" end, getOnlineID = function() return 7 end,
    getX = function() return px + 0.5 end, getY = function() return py + 0.5 end, getZ = function() return 0 end,
    getCurrentSquare = function() return square(px, py, 0) end, getSquare = function() return square(px, py, 0) end,
    getVehicle = function() return nil end,
    getInventory = function() return inventory end }
function getOnlinePlayers()
    local list = online and { player } or {}
    return { size = function() return #list end, get = function(_, i) return list[i + 1] end }
end
local moves = {}
function sendServerCommand(_, module, command, args) if command == "move" then moves[#moves + 1] = args end end

------------------------------------------------------------
-- KIPN and The Post Office stand-ins
------------------------------------------------------------
SandboxVars = { KIPN = { AdminAccounts = "Alice, Bob" } }
local zones, nextZone, powered = {}, 0, {}
local registry, nextBox, claims, nextClaim, quotaReason = {}, 0, {}, 0, nil
local parcelStore = { parcelsByOwner = {}, systemOrders = {}, nextId = 0 }
modData.KIPN_MarketplaceParcels = parcelStore
local SIZES = { small = { Label = "Small", Capacity = 10, Price = 250 }, medium = { Label = "Medium", Capacity = 25, Price = 500 },
    large = { Label = "Large", Capacity = 50, Price = 1000 } }
local function inZone(zone, x, y)
    local g = zone.geometry
    return zone.active and x >= g.x1 and x <= g.x2 and y >= g.y1 and y <= g.y2
end
local function zoneAt(x, y)
    for id, zone in pairs(zones) do if inZone(zone, x, y) then return zone, id end end
end
-- As KIPN decides it: the admin account list, then the role's admin power.
local function admin(who)
    if who.getSteamID then
        for entry in string.gmatch(SandboxVars.KIPN.AdminAccounts, "[^,]+") do
            if entry:match("^%s*(.-)%s*$") == who:getUsername() then return true end
        end
    end
    local role = who.getRole and who:getRole()
    return role ~= nil and role.hasAdminPower ~= nil and role:hasAdminPower() == true
end
player.getSteamID = function() return 1 end
player.isDead = function() return false end
local creators = {}
local function ownedBox()
    for _, claim in pairs(claims) do if claim.active then return true end end
    return false
end
local commands = { GET_PARCELS = "getParcels", COLLECT_PARCEL = "collectParcel", GET_PO_BOXES = "getPOBoxes", BUY_PO_BOX = "buyPOBox" }
local listed = 0
local handlers = {
    getParcels = function() listed = listed + 1 end,
    collectParcel = function(who, args)
        local queue = parcelStore.parcelsByOwner[who:getUsername()] or {}
        for i, parcel in ipairs(queue) do
            if parcel.id == args.parcelId then
                table.remove(queue, i)
                for _ = 1, parcel.quantity do who:getInventory():AddItem(parcel.itemFullType) end
            end
        end
    end,
    getPOBoxes = function() end, buyPOBox = function() end,
}
KIPN = {
    Shared = { GetComputerId = function(o) return "comp_" .. o.square.x .. "_" .. o.square.y end, Commands = commands },
    Server = {
        GetOrCreateComputer = function() return {} end,
        SetComputerPower = function(id, on) powered[id] = on end,
        Save = function() return true end,
        GetCommandHandler = function(command) return handlers[command] end,
        Permissions = { ResolveAccessLevel = function(who) return admin(who) and "ADMIN" or "USER" end },
        POBoxConfig = { ClaimItemType = "Base.Key_Blank" },
        Wallet = { CountInventoryCurrency = function() return count("Base.MoneyBundle") * 100 end },
        WorldRegistry = {
            ZoneTypes = { POST_OFFICE = "post_office" },
            GetZone = function(id) return zones[id] end,
            CreateZoneFromCorners = function(zoneType, a, b)
                nextZone = nextZone + 1
                local id = zoneType .. "_" .. nextZone
                zones[id] = { id = id, type = zoneType, active = true, geometry = { x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y } }
                return zones[id]
            end,
            UpdateZone = function(id, changes) zones[id].active, zones[id].geometry = changes.active, changes.geometry; return true end,
            DeactivateZone = function(id) zones[id].active = false; return true end,
            GetZonesAtPosition = function(x, y)
                local found = {}
                for id, zone in pairs(zones) do if inZone(zone, x, y) then found[id] = zone end end
                return found
            end,
            GetSafehousesOverlappingRectangle = function(rect)
                return (rect.x1 <= 97 and rect.x2 >= 92) and { "safehouse" } or {}
            end,
        },
        POBoxService = {
            GetSizeConfig = function(size) return SIZES[size] end,
            GetPrice = function(entry) return SIZES[entry.size].Price end,
            GetCapacity = function(entry) return SIZES[entry.size].Capacity end,
            GetLabel = function(entry) return SIZES[entry.size].Label end,
            GetBox = function(id) return registry[id] end,
            GetBoxesForZone = function(zoneId)
                local list = {}
                for _, entry in pairs(registry) do if entry.zoneId == zoneId then list[#list + 1] = entry end end
                table.sort(list, function(a, b) return a.number < b.number end)
                return list
            end,
            GetBoxAtZoneNumber = function(zoneId, number)
                for _, entry in pairs(registry) do if entry.zoneId == zoneId and entry.number == number then return entry end end
            end,
            GetNextBoxNumber = function() return nextBox + 1 end,
            ResolvePurchasableBox = function(_, number)
                for _, entry in pairs(registry) do if entry.number == number then return entry end end
            end,
            FindWorldObject = function(entry) return entry.object end,
            GetPlayerPostOffice = function(who)
                local sq = who:getSquare()
                return zoneAt(sq:getX(), sq:getY())
            end,
            -- The real service's order of refusals.
            CreateBox = function(who, args)
                if not admin(who) then return nil, "NOT_AUTHORIZED" end
                if not args.x or not args.y or not args.z then return nil, "INVALID_SQUARE" end
                if not SIZES[args.size] then return nil, "INVALID_SIZE" end
                local sq = who:getSquare()
                if math.abs(sq:getX() - args.x) > 10 or math.abs(sq:getY() - args.y) > 10 then return nil, "TARGET_TOO_FAR" end
                local _, here = zoneAt(sq:getX(), sq:getY())
                local _, there = zoneAt(args.x, args.y)
                if not here or here ~= there then return nil, "POST_OFFICE_ZONE_REQUIRED" end
                for _, entry in pairs(registry) do
                    if entry.x == args.x and entry.y == args.y then return nil, "SQUARE_ALREADY_HAS_PO_BOX" end
                end
                nextBox = nextBox + 1
                local id = "pobox_" .. nextBox
                local object = worldObject("box")
                object.keyId, object.capacity = 1000 + nextBox, SIZES[args.size].Capacity
                object.modData.KIPNProtectedMoveable, object.modData.KIPNPOBoxRegistryId = true, id
                registry[id] = { id = id, number = nextBox, size = args.size, zoneId = here, x = args.x, y = args.y, z = 0,
                    keyId = object.keyId, object = object }
                creators[#creators + 1] = who:getUsername()
                return registry[id]
            end,
            DeleteBox = function(who, args)
                if not admin(who) then return false, "NOT_AUTHORIZED" end
                if not registry[args.boxId] then return false, "PO_BOX_NOT_FOUND" end
                registry[args.boxId] = nil
                return true
            end,
            ReleaseForRemovedKey = function(_, args)
                if not args.boxId or not args.keySerial then return false, "INVALID_KEY_IDENTITY" end
                for _, claim in pairs(claims) do
                    if claim.active and claim.targetId == args.boxId then
                        if claim.poBoxKeySerial ~= args.keySerial then return false, "KEY_IDENTITY_MISMATCH" end
                        return false, "KEY_STILL_EXISTS"
                    end
                end
                return true, "ALREADY_AVAILABLE"
            end,
        },
        ClaimService = {
            Types = { PO_BOX = "po_box" },
            GetPlayerClaims = function() return claims end,
            GetClaimForTarget = function(_, target)
                for _, claim in pairs(claims) do if claim.active and claim.targetId == target then return claim end end
            end,
            CheckMaxClaimsForType = function() return quotaReason == nil, quotaReason end,
            ReleaseClaim = function(id) claims[id].active = false; return true end,
        },
        POBoxClaimService = {
            FindPlayerPOBoxKeyItems = function()
                local keys = {}
                for _, i in ipairs(inventory.items) do
                    if i.fullType == "Base.KIPNPOBoxKey" then keys[#keys + 1] = { item = i, boxId = i.modData.KIPNPOBoxId } end
                end
                return keys
            end,
            ValidatePOBoxTarget = function(_, number)
                number = tonumber(number)
                return number ~= nil and number == math.floor(number) and number >= 1 and number <= 999999
            end,
        },
        MarketplaceService = {
            CanPlayerReceiveMarketplaceDelivery = ownedBox,
            QueueSystemParcel = function(recipient, delivery)
                if type(recipient) ~= "table" or type(delivery) ~= "table" then return nil, "INVALID_DELIVERY" end
                local username = type(recipient.username) == "string" and recipient.username:match("^%s*(.-)%s*$") or ""
                if username == "" then return nil, "INVALID_RECIPIENT" end
                if not ownedBox() then return nil, "PO_BOX_REQUIRED" end
                local order, quantity = tostring(delivery.systemOrderId or ""), math.floor(tonumber(delivery.quantity) or 1)
                if order == "" then return nil, "INVALID_SYSTEM_ORDER_ID" end
                if tostring(delivery.itemFullType or "") == "" then return nil, "INVALID_ITEM" end
                if quantity < 1 or quantity > 100 then return nil, "INVALID_QUANTITY" end
                local existing = parcelStore.systemOrders[order]
                if existing then
                    for _, parcel in ipairs(parcelStore.parcelsByOwner[username] or {}) do
                        if parcel.id == existing then return parcel end
                    end
                    return { id = existing, alreadyFulfilled = true }
                end
                parcelStore.nextId = parcelStore.nextId + 1
                local parcel = { id = parcelStore.nextId, systemOrderId = order, itemFullType = delivery.itemFullType, quantity = quantity }
                parcelStore.parcelsByOwner[username] = parcelStore.parcelsByOwner[username] or {}
                table.insert(parcelStore.parcelsByOwner[username], parcel)
                parcelStore.systemOrders[order] = parcel.id
                return parcel
            end,
            QueueExternalDelivery = function(provider)
                if not ownedBox() then return nil, "PO_BOX_REQUIRED" end
                if provider == "" then return nil, "INVALID_PROVIDER" end
                return nil, "PROVIDER_NOT_SUPPORTED"
            end,
        },
    },
}
local function buy(entry)
    nextClaim = nextClaim + 1
    local id = "claim_" .. nextClaim
    claims[id] = { id = id, type = "po_box", active = true, targetId = entry.id, poBoxKeySerial = "serial_" .. nextClaim }
    local key = inventory:AddItem("Base.KIPNPOBoxKey")
    key.modData.KIPNPOBoxId, key.modData.KIPNPOBoxKeySerial, key.keyId = entry.id, claims[id].poBoxKeySerial, entry.keyId
    return claims[id], key
end

dofile(root .. "shared/LilBubbyTeleport.lua")
dofile(root .. "shared/LilBubbySites.lua")
-- This fixture's world is not the vanilla map: it has no default sites, so an admin lays them out.
LilBubbySites.DEFAULTS = {}
dofile(root .. "server/LilBubbyDesk.lua")
dofile(root .. "shared/PostalTest_Checks.lua")
dofile(root .. "shared/PostalTest_Guided.lua")
local G = PostalTest.Guided
local function missing(reply, fragment)
    for _, line in ipairs(reply.missing or {}) do if line:find(fragment, 1, true) then return true end end
    return false
end

------------------------------------------------------------
-- Begin: a nearby building, and the move into it
------------------------------------------------------------
assert(G.Advance(player, { phase = 1 }).error, "a step cannot be checked before the test has begun")
-- Players never make the post office zone: an admin lays the test sites out first.
local begun = G.Begin(player)
assert(begun.status == "BLOCKED" and begun.error:find("does not exist", 1, true) and nextZone == 0, "no test post office before an admin sets the sites up")
assert(LilBubbySites.SetUp(player).status == "BLOCKED" and nextZone == 0, "a player cannot set the sites up")
local siteAdmin = setmetatable({ getUsername = function() return "SiteAdmin" end,
    getRole = function() return { hasAdminPower = function() return true end } end }, { __index = player })
local laid = LilBubbySites.SetUp(siteAdmin)
assert(LilBubbySites.Get("post_office") and nextZone == 1, "an admin sets up the test post office: " .. table.concat(laid.lines or {}, "; "))
begun = G.Begin(player)
assert(not begun.error, tostring(begun.error))
assert(buildingAt(begun.x, begun.y) == office, "the building under a safehouse is passed over for the next one")
assert(#moves == 1 and moves[1].x == begun.x and moves[1].y == begun.y, "the player is moved into the building")
assert(G.Setup(player).waiting, "setup waits until the player stands in the building")
assert(#G.Move(player) == 0 and #moves == 2, "a player who did not arrive is moved again")
px, py = begun.x, begun.y

------------------------------------------------------------
-- Setup: zone, computer, generator, money and Blank Key
------------------------------------------------------------
local setup = G.Setup(player)
assert(setup.phase == 1, tostring(setup.error))
local zoneId = LilBubbyDesk.ZoneId(player, "post_office")
local g = zones[zoneId].geometry
assert(g.x1 == 107 and g.y1 == 197 and g.x2 == 122 and g.y2 == 210, "the zone is the building and 3 tiles around it")
assert(buildingAt(setup.computer.x, setup.computer.y) == office, "the computer stands inside the building")
assert(buildingAt(setup.generator.x, setup.generator.y) == nil, "the generator stands outside it")
local computer, generator = LilBubbyDesk.Objects(player)
assert(computer and generator.activated and generator.fuel == generator.max, "the generator runs on a full tank")
for _, on in pairs(powered) do error("the computer is left off for the player to switch on: " .. tostring(on)) end
assert(count("Base.MoneyBundle") == 10 and count("Base.Key_Blank") == 1 and setup.cash == 1000, "ten money bundles and a Blank Key are given")

------------------------------------------------------------
-- Step 1: the overview
------------------------------------------------------------
local function failures(reply)
    local failed = {}
    for _, line in ipairs(reply.checks or {}) do
        if not line:find("^PASS") then failed[#failed + 1] = line end
    end
    return table.concat(failed, " | ")
end
assert(G.Advance(player, { phase = 2 }).stale, "a check for another step than the current one changes nothing")
assert(G.Place(player, { x = begun.x + 1, y = begun.y, size = "small" }).ok == false and nextBox == 0, "no box can be placed before step 2")
generator.fuel, generator.activated = 0, false
px = 60
local denied = G.Advance(player, { phase = 1 })
assert(denied.ok == false and missing(denied, "outside the post office"), "step 1 is denied outside the post office")
px = begun.x
local one = G.Advance(player, { phase = 1 })
assert(one.ok and one.phase == 2, "step 1 passes")
assert(generator.fuel == generator.max and generator.activated, "an empty or stopped generator is refilled and restarted")
assert(#one.sizes == 3 and one.sizes[1].price == 250, "the box sizes and prices are sent for the instructions")

------------------------------------------------------------
-- Step 2: the tester places the boxes; the player is never an admin
------------------------------------------------------------
local two = G.Advance(player, { phase = 2 })
assert(two.ok == false and #two.missing == 3, "step 2 is denied with no boxes: one line per missing size")
local placed = G.Place(player, { x = 112, y = 202, size = "small" })
assert(placed.ok and placed.box == "Small #1 ($250)" and registry.pobox_1.zoneId == zoneId, "a box is placed where the player points: " .. tostring(placed.reason))
assert(creators[1] == "LilBubbyModTester", "The Post Office's own CreateBox placed it, called by the tester's operator")
assert(not admin(player) and SandboxVars.KIPN.AdminAccounts == "Alice, Bob", "the player is not an admin and KIPN's admin list is untouched")
assert(KIPN.Server.POBoxService.CreateBox(player, { x = 113, y = 203, z = 0, size = "small" }) == nil, "the player's own request is still refused")
local refused = G.Place(player, { x = 112, y = 202, size = "medium" })
assert(refused.ok == false and refused.reason:find("already has a PO Box", 1, true), "a refusal is given in plain words")
assert(G.Place(player, { x = 112, y = 203, size = "huge" }).ok == false, "an unknown size is refused")
assert(G.Place(player, { x = 300, y = 300, size = "large" }).ok == false and nextBox == 1, "a tile outside the test zone is refused")
assert(G.Place(player, { x = 108, y = 198, size = "medium" }).ok, "a box can stand outside the walls, inside the zone")
two = G.Advance(player, { phase = 2 })
assert(two.ok == false and #two.missing == 1 and missing(two, "No large PO Box"), "step 2 names the size still missing")
assert(G.Place(player, { x = 113, y = 202, size = "large" }).ok)
registry.pobox_3.object.capacity = 1 -- a box whose container was built with the wrong capacity
two = G.Advance(player, { phase = 2 })
assert(two.ok and two.phase == 3 and #two.boxes == 3 and two.boxes[1] == "Small #1 ($250)", "step 2 passes with a box of every size")
assert(failures(two) == "FAIL: Box #3 physical capacity matches configuration", "every box is checked and a fault is reported, not hidden: " .. failures(two))
assert(#two.checks == 25, "eight checks per box and the numbering check: " .. #two.checks)
registry.pobox_3.object.capacity = 50
assert(G.Place(player, { x = 114, y = 202, size = "small" }).ok == false, "boxes are only placed during step 2")

------------------------------------------------------------
-- Step 3: everything a purchase needs
------------------------------------------------------------
local elsewhere = { id = "pobox_elsewhere", number = 9, size = "small", zoneId = "other", keyId = 5, object = worldObject("box") }
registry.pobox_elsewhere = elsewhere
local earlier = buy(elsewhere) -- a box rented at another post office before this test
local blank
for _, i in ipairs(inventory.items) do if i.fullType == "Base.Key_Blank" then blank = i end end
inventory:Remove(blank)
quotaReason = "Maximum PO Boxes reached."
local three = G.Advance(player, { phase = 3 })
assert(three.ok == false and missing(three, "no Blank Key") and missing(three, "Maximum PO Boxes reached."),
    "step 3 is denied without a Blank Key or over the rental limit")
quotaReason = nil
inventory.items[#inventory.items + 1] = blank
three = G.Advance(player, { phase = 3 })
assert(three.ok and three.phase == 4 and three.available == 3 and three.cheapest == 250 and three.cash == 1000, "step 3 passes: three free boxes, the cheapest $250")

------------------------------------------------------------
-- Step 4: a box rented here, in this step, and its key carried
------------------------------------------------------------
local four = G.Advance(player, { phase = 4 })
assert(four.ok == false and missing(four, "No PO Box purchase"), "a box rented before the step does not count")
local claim, key = buy(registry.pobox_1)
inventory:Remove(key)
four = G.Advance(player, { phase = 4 })
assert(four.ok == false and missing(four, "do not carry its key"), "step 4 is denied without the key")
assert(#(parcelStore.parcelsByOwner.Tester or {}) == 0, "no parcel is sent before the rental passes")
inventory.items[#inventory.items + 1] = key
inventory:AddItem("Base.Paper") -- paper the player already had
four = G.Advance(player, { phase = 4 })
assert(four.ok and four.phase == 5 and four.box == "Small #1 ($250)", "step 4 passes with the rental and its key")
assert(failures(four) == "", "ownership, key and lock checks pass: " .. failures(four))
local waiting = parcelStore.parcelsByOwner.Tester
assert(#waiting == 1 and waiting[1].itemFullType == "Base.Paper" and waiting[1].quantity == 2 and listed == 1,
    "one parcel of two sheets waits for the player, and an open postal page is refreshed")

------------------------------------------------------------
-- Step 5: the delivery is collected, then replayed
------------------------------------------------------------
local five = G.Advance(player, { phase = 5 })
assert(five.ok == false and missing(five, "still waiting"), "step 5 is denied until the parcel is collected")
handlers.collectParcel(player, { parcelId = waiting[1].id }) -- the player clicks COLLECT PARCELS
five = G.Advance(player, { phase = 5 })
assert(five.ok and five.phase == 6 and five.papers == 2, "step 5 passes once the two sheets arrived")
assert(failures(five) == "" and #five.checks == 5, "delivery, second collection and replayed order are checked: " .. failures(five))
assert(count("Base.Paper") == 3 and #parcelStore.parcelsByOwner.Tester == 0, "the replays gave nothing more")
assert(G.Advance(player, { phase = 5 }).stale, "a finished test has no step left to check")

------------------------------------------------------------
-- Cleanup
------------------------------------------------------------
local cleaned = G.Cleanup(player)
assert(cleaned.claims == 1 and not claim.active and earlier.active, "only the rental made at the test post office is released")
assert(cleaned.keys == 1 and count("Base.KIPNPOBoxKey") == 1, "its key is removed; the other box's key is kept")
assert(cleaned.boxes == 3 and #cleaned.kept == 0 and registry.pobox_elsewhere, "every box of the test zone is removed, and no other")
assert(count("Base.MoneyBundle") == 0 and count("Base.Key_Blank") == 0 and count("Base.Paper") == 1,
    "the money, Blank Key and delivered paper are removed; the player's own paper stays")
for order in pairs(parcelStore.systemOrders) do error("a test order is left behind: " .. order) end
assert(cleaned.objects == 2 and cleaned.zones == 0 and zones[zoneId].active and nextZone == 1,
    "the computer and generator are removed; the designated zone stays and no other zone was ever made")
assert(not admin(player) and SandboxVars.KIPN.AdminAccounts == "Alice, Bob", "the player was never an admin")

-- Cancelled while the parcel waits: the parcel goes too.
px, py = 85, 203
begun = G.Begin(player)
px, py = begun.x, begun.y
assert(G.Setup(player).phase == 1 and G.Advance(player, { phase = 1 }).ok)
for i, size in ipairs({ "small", "medium", "large" }) do assert(G.Place(player, { x = 111 + i, y = 204, size = size }).ok) end
assert(G.Advance(player, { phase = 2 }).ok and G.Advance(player, { phase = 3 }).ok)
buy(registry.pobox_4)
assert(G.Advance(player, { phase = 4 }).ok and #parcelStore.parcelsByOwner.Tester == 1)
cleaned = G.Cleanup(player)
assert(cleaned.parcels == 1 and #parcelStore.parcelsByOwner.Tester == 0 and cleaned.boxes == 3, "a waiting test parcel is removed by cleanup")

------------------------------------------------------------
-- Check invalid requests and command registration
------------------------------------------------------------
local function guards()
    local text = PostalTest.Run(player, "guards")
    return text, text:match("^[^\n]*")
end
local itemsBefore, boxesBefore = #inventory.items, nextBox
local text, summary = guards() -- an ordinary player who owns a box (the one rented elsewhere) and carries its key
assert(summary == "Postal functional tests: 19 PASS, 0 FAIL, 0 BLOCKED, 0 ERROR", summary .. "\n" .. text)
assert(text:find("not an admin cannot create a box (NOT_AUTHORIZED)", 1, true) and text:find("wrong serial is refused (KEY_IDENTITY_MISMATCH)", 1, true)
    and not text:find("KEY_STILL_EXISTS", 1, true), text)
assert(#inventory.items == itemsBefore and nextBox == boxesBefore and earlier.active and #parcelStore.parcelsByOwner.Tester == 0,
    "the refused requests created, released, queued and granted nothing")
earlier.active = false
text, summary = guards() -- a player without a box
assert(summary == "Postal functional tests: 13 PASS, 0 FAIL, 1 BLOCKED, 0 ERROR" and text:find("without a PO Box is refused (PO_BOX_REQUIRED)", 1, true), summary .. "\n" .. text)
SandboxVars.KIPN.AdminAccounts = "Alice, Tester"
text, summary = guards() -- an admin: the argument checks behind the admin gate
assert(summary == "Postal functional tests: 15 PASS, 0 FAIL, 1 BLOCKED, 0 ERROR" and text:find("unknown size is refused (INVALID_SIZE)", 1, true)
    and text:find("500 tiles away is refused (TARGET_TOO_FAR)", 1, true) and nextBox == boxesBefore, summary .. "\n" .. text)
KIPN.Server.POBoxClaimService.ValidatePOBoxTarget = function() return true end
text, summary = guards()
assert(summary:find("1 FAIL", 1, true) and text:find("FAIL: Purchase validation refuses", 1, true), "a service that accepts a bad request is reported")

io.write("PASS: the guided post office test picks a usable building, sets up the zone, computer, outdoor generator, money and Blank Key, places boxes for the player without making them an admin, checks each step before the next, checks every box, the rental and its key, delivers a parcel and replays it, and cleans up; invalid requests are refused\n")
