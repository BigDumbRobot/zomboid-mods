require "LilBubbyTeleport"
require "LilBubbySites"
require "PostalTest_Checks"

-- Guided post office test: the player is walked through setting a post office
-- up, renting a box and collecting a delivery, one step at a time. Each step
-- ends when the player clicks OK; the server then checks that everything the
-- next step needs is really there, and passes or denies the step.
--   begin    picks a nearby building and moves the player into it
--   setup    makes the building a Post Office zone, places a computer inside
--            and a running generator outside, gives the money and Blank Key
--   place    puts a PO Box where the player points (step 2 only)
--   advance  checks the step the player says is done:
--            1 the post office is set up
--            2 a box of every size stands  -> every box is checked
--            3 a box can be bought         -> notes the boxes already owned
--            4 a box was bought            -> ownership and key are checked,
--                                             a parcel is queued for the player
--            5 the parcel was collected    -> delivery and replays are checked
--   cleanup  removes everything the test placed, gave, rented or queued
-- Everything acts on the authenticated requester. The only thing taken from
-- the client is the square and size of a box in step 2, and The Post Office
-- itself decides whether a box may stand there. The server half runs these in
-- multiplayer; single player calls them directly.
PostalTest.Guided = PostalTest.Guided or {}
local G = PostalTest.Guided

G.TAG = "LilBubbyPostalGiven"  -- on every item the test gave or delivered
G.JOURNAL = "LilBubbyPostalTest" -- global mod data: order sequence and each player's test orders
G.SEARCH = 60                  -- tiles searched for a building
G.MARGIN = 3                   -- the zone reaches this far past the building's walls
G.BUNDLE = "Base.MoneyBundle"
G.BUNDLES = 10
G.PARCEL = "Base.Paper"
G.PARCEL_COUNT = 2
G.SIZES = { "small", "medium", "large" }
G.sessions = G.sessions or {}  -- per username: the test in progress (server memory)

local BOX_REASONS = {
    NOT_AUTHORIZED = "The Post Office did not accept the tester as an admin. Ask an admin to place the boxes with KIPN: Spawn PO Box.",
    TARGET_TOO_FAR = "That tile is more than 10 tiles from you.",
    POST_OFFICE_ZONE_REQUIRED = "That tile is outside the post office zone.",
    SQUARE_ALREADY_HAS_PO_BOX = "That tile already has a PO Box.",
    SQUARE_NOT_LOADED = "That tile is not loaded on the server.",
    PO_BOX_NOT_EMPTY = "it still holds items",
    PO_BOX_IS_OWNED = "another player owns it",
}

local function services()
    local s = KIPN and KIPN.Server
    if not s or not s.POBoxService or not s.POBoxConfig or not s.MarketplaceService or not s.WorldRegistry
        or not s.ClaimService or not LilBubbyDesk then
        return nil, "Enable KIP Network Terminal (KIPN) and The Post Office to run this test."
    end
    return s
end

local function zoneType(s)
    return s.WorldRegistry.ZoneTypes and s.WorldRegistry.ZoneTypes.POST_OFFICE or "post_office"
end

local function claimType(s)
    return s.ClaimService.Types and s.ClaimService.Types.PO_BOX or "po_box"
end

local function inside(rect, x, y)
    return x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2
end

local function money(amount) return "$" .. tostring(amount) end

-- Creating and removing PO Boxes are admin commands of The Post Office. The
-- player is never made an admin for them: the server calls the mod's own
-- CreateBox and DeleteBox as this operator, which stands where the player
-- stands and carries a role with admin power. Nothing of the player's or the
-- server's permissions changes.
local OPERATOR_ROLE = { hasAdminPower = function() return true end }
local function operator(player)
    local o = {}
    function o:getRole() return OPERATOR_ROLE end
    function o:getSquare() return player:getSquare() end
    function o:getUsername() return "LilBubbyModTester" end
    return o
end

------------------------------------------------------------
-- INVENTORY
------------------------------------------------------------

local function eachItem(player, fn)
    local seen = {}
    local function visit(container)
        if not container or seen[container] then return end
        seen[container] = true
        local items = container:getItems()
        for i = items:size() - 1, 0, -1 do
            local item = items:get(i)
            if item then
                if instanceof(item, "InventoryContainer") then visit(item:getInventory()) end
                fn(item, container)
            end
        end
    end
    visit(player:getInventory())
end

local function carried(player, fullType, givenOnly)
    local count = 0
    eachItem(player, function(item)
        if item:getFullType() == fullType and (not givenOnly or item:getModData()[G.TAG]) then count = count + 1 end
    end)
    return count
end

local function give(player, fullType, count)
    local inventory, given = player:getInventory(), 0
    for _ = 1, count do
        local item = inventory:AddItem(fullType)
        if not item then break end
        item:getModData()[G.TAG] = true
        if isServer() then sendAddItemToContainer(inventory, item) end
        given = given + 1
    end
    return given
end

local function remove(item, container)
    container:Remove(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
end

local function cash(s, player)
    local ok, total = pcall(function() return s.Wallet.CountInventoryCurrency(player) end)
    return ok and tonumber(total) or carried(player, G.BUNDLE) * 100
end

------------------------------------------------------------
-- THE BUILDING
------------------------------------------------------------

local function standable(square)
    return square ~= nil and square:TreatAsSolidFloor() and square:isFree(false)
end

-- The nearest square to (x, y) on the ground floor, minDistance to
-- maxDistance tiles away, that `wanted` accepts.
local function nearSquare(x, y, minDistance, maxDistance, wanted)
    local cell = getCell()
    for r = minDistance, maxDistance do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local square = cell:getGridSquare(x + dx, y + dy, 0)
                    if standable(square) and wanted(square) then return square end
                end
            end
        end
    end
end

local function indoors(square) return square:getBuilding() ~= nil end

local function anyEntry(list)
    for _ in pairs(list or {}) do return true end
    return false
end

-- Where the player stands in this building, or nil when the building cannot
-- be a test post office: a safehouse is in the way, another post office
-- already covers it, or it has no room for a player and a computer.
local function standIn(s, player, building, zone)
    local WR = s.WorldRegistry
    if WR.GetSafehousesOverlappingRectangle and anyEntry(WR.GetSafehousesOverlappingRectangle(zone)) then return nil end
    local def = building:getDef()
    local cx, cy = def:getX() + math.floor(def:getW() / 2), def:getY() + math.floor(def:getH() / 2)
    local own = LilBubbyDesk.ZoneId(player, "post_office")
    local cell, best, bestDistance = getCell(), nil, nil
    for x = def:getX(), def:getX() + def:getW() - 1 do
        for y = def:getY(), def:getY() + def:getH() - 1 do
            local distance = math.abs(x - cx) + math.abs(y - cy)
            local square = (not bestDistance or distance < bestDistance) and cell:getGridSquare(x, y, 0)
            if square and standable(square) and square:getBuilding() == building
                and nearSquare(x, y, 1, 3, indoors) then
                best, bestDistance = square, distance
            end
        end
    end
    if not best then return nil end
    for id in pairs(WR.GetZonesAtPosition(best:getX(), best:getY(), 0, zoneType(s)) or {}) do
        if tostring(id) ~= tostring(own) then return nil end
    end
    return { x = best:getX(), y = best:getY(), z = 0 }
end

-- The nearest usable building: the one the player stands in, if any.
local function findBuilding(s, player)
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local cell, seen = getCell(), {}
    for r = 0, G.SEARCH, 2 do
        for dx = -r, r, 2 do
            for dy = -r, r, 2 do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local square = cell:getGridSquare(px + dx, py + dy, 0)
                    local building = square and square:getBuilding()
                    local ok, spot, zone = pcall(function()
                        if not building then return nil end
                        local def = building:getDef()
                        local key = def:getX() .. "," .. def:getY()
                        if seen[key] then return nil end
                        seen[key] = true
                        local rect = { x1 = def:getX() - G.MARGIN, y1 = def:getY() - G.MARGIN,
                            x2 = def:getX() + def:getW() - 1 + G.MARGIN, y2 = def:getY() + def:getH() - 1 + G.MARGIN,
                            z1 = 0, z2 = 0 }
                        return standIn(s, player, building, rect), rect
                    end)
                    if ok and spot then return spot, zone end
                end
            end
        end
    end
end

------------------------------------------------------------
-- BEGIN AND SETUP
------------------------------------------------------------

-- The designated post office: the nearest usable building to the admin who
-- set the test sites up. Players never make the zone; they are moved into it.
if LilBubbySites then
    LilBubbySites.Provide("post_office", {
        label = "Post Office",
        available = function() return services() ~= nil end,
        layout = function(_, admin)
            local s = services()
            local spot, rect = findBuilding(s, admin)
            if not spot then
                return nil, "no usable building within " .. G.SEARCH
                    .. " tiles (not a safehouse, not already a post office). Set the sites up nearer a building."
            end
            return { x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2, z = 0 }, spot
        end,
        create = function(_, rect)
            local s = services()
            local zone, reason = s.WorldRegistry.CreateZoneFromCorners(zoneType(s), { x = rect.x1, y = rect.y1, z = 0 },
                { x = rect.x2, y = rect.y2, z = 0 }, { name = LilBubbySites.NAME .. "Post Office", lilBubbyTest = true })
            if not zone then return nil, reason end
            return zone.id
        end,
        remove = function(_, id)
            local s = services()
            local zone = s and s.WorldRegistry.GetZone(id)
            if zone and zone.active ~= false then s.WorldRegistry.DeactivateZone(id) end
        end,
        exists = function(id)
            local s = services()
            local zone = s and s.WorldRegistry.GetZone(id)
            return zone ~= nil and zone.active ~= false
        end,
    })
end

function G.Begin(player)
    local s, why = services()
    if not s then return { status = "BLOCKED", error = why } end
    if player:getVehicle() then return { status = "BLOCKED", error = "Get out of the vehicle first." } end
    local name = player:getUsername()
    local site = LilBubbySites.Get("post_office")
    if not site then
        G.sessions[name] = nil
        return { status = "BLOCKED", error = LilBubbySites.Missing("post_office") }
    end
    local spot = site.spot
    local zone = { x1 = site.x1, y1 = site.y1, x2 = site.x2, y2 = site.y2, z1 = 0, z2 = 0 }
    G.sessions[name] = { phase = 0, spot = spot, rect = zone }
    return { x = spot.x, y = spot.y, z = spot.z, expected = LilBubbyTeleport.Order(player, spot.x, spot.y, spot.z) }
end

local NO_SESSION = "The server has no guided test in progress for you (it may have restarted). Start the test again."

-- Orders the move again, for a player who did not arrive.
function G.Move(player)
    local session = G.sessions[player:getUsername()]
    if not session then return { error = NO_SESSION } end
    local spot = session.spot
    return { x = spot.x, y = spot.y, z = spot.z, expected = LilBubbyTeleport.Order(player, spot.x, spot.y, spot.z) }
end

local function sizes(s)
    local list = {}
    for _, size in ipairs(G.SIZES) do
        local config = s.POBoxService.GetSizeConfig(size) or {}
        list[#list + 1] = { size = size, label = config.Label or size, capacity = config.Capacity, price = config.Price }
    end
    return list
end

-- waiting = true until the player stands in the building.
function G.Setup(player)
    local s, why = services()
    if not s then return { error = why } end
    local session = G.sessions[player:getUsername()]
    if not session then return { error = NO_SESSION } end
    local spot = session.spot
    if not player:getCurrentSquare() or math.floor(player:getZ()) ~= spot.z
        or not inside(session.rect, math.floor(player:getX()), math.floor(player:getY())) then
        return { waiting = true }
    end
    -- The desk puts its generator outdoors by itself.
    local id, notes = LilBubbyDesk.Ensure(player, "post_office", { power = false,
        computerSquare = nearSquare(spot.x, spot.y, 1, 3, indoors) })
    if not id then return { error = notes } end
    session.zoneId = LilBubbyDesk.ZoneId(player, "post_office")
    local bundles = give(player, G.BUNDLE, math.max(0, G.BUNDLES - carried(player, G.BUNDLE, true)))
    local blank = s.POBoxConfig.ClaimItemType
    local keys = carried(player, blank) == 0 and give(player, blank, 1) or 0
    session.phase = 1
    local blankScript = getScriptManager():FindItem(blank)
    return { phase = 1, computer = LilBubbyDesk.ComputerSpot(player), generator = LilBubbyDesk.GeneratorSpot(player),
        bundles = bundles, blankKeys = keys, blankName = blankScript and blankScript:getDisplayName() or "Blank Key",
        cash = cash(s, player), sizes = sizes(s), margin = G.MARGIN, notes = notes }
end

------------------------------------------------------------
-- WHAT EACH STEP NEEDS
------------------------------------------------------------

-- The post office itself: the zone with the player in it, the computer, and
-- the generator, which is refilled and restarted rather than complained about.
local function postOffice(s, player, session, missing)
    local zone = s.WorldRegistry.GetZone(session.zoneId)
    if not zone or zone.active == false then
        missing[#missing + 1] = "The test Post Office zone is gone. Cancel and start the test again."
        return
    end
    local _, here = s.POBoxService.GetPlayerPostOffice(player)
    if tostring(here) ~= tostring(session.zoneId) then
        missing[#missing + 1] = "You are outside the post office. Go back into the building."
    end
    local computer, generator = LilBubbyDesk.Objects(player)
    if not computer then missing[#missing + 1] = "The test computer is gone. Cancel and start the test again." end
    if generator then LilBubbyDesk.Refuel(generator)
    else missing[#missing + 1] = "The test generator is gone. Cancel and start the test again." end
end

-- Registered boxes of this post office that stand in the world, by size.
local function boxes(s, session)
    local bySize, all = {}, {}
    for _, size in ipairs(G.SIZES) do bySize[size] = {} end
    for _, entry in ipairs(s.POBoxService.GetBoxesForZone(session.zoneId)) do
        if bySize[entry.size] and inside(session.rect, tonumber(entry.x), tonumber(entry.y))
            and s.POBoxService.FindWorldObject(entry) then
            table.insert(bySize[entry.size], entry)
            all[#all + 1] = entry
        end
    end
    return bySize, all
end

local function describeBox(s, entry)
    return s.POBoxService.GetLabel(entry) .. " #" .. tostring(entry.number) .. " (" .. money(s.POBoxService.GetPrice(entry)) .. ")"
end

-- This player's active box claims, by claim id.
local function ownedClaims(s, player)
    local owned = {}
    for _, claim in ipairs(PostalTest.Claims(s, player)) do owned[tostring(claim.id)] = claim end
    return owned
end

-- The money and Blank Key a purchase takes.
local function purse(s, player, price, missing)
    local total = cash(s, player)
    if price and total < price then
        missing[#missing + 1] = "You carry " .. money(total) .. " but the cheapest box here costs " .. money(price) .. "."
    end
    if carried(player, s.POBoxConfig.ClaimItemType) == 0 then
        missing[#missing + 1] = "You carry no Blank Key; a purchase uses one up."
    end
    return total
end

-- Puts a PO Box of args.size on the square the player pointed at.
function G.Place(player, args)
    local s, why = services()
    if not s then return { error = why } end
    local session = G.sessions[player:getUsername()]
    if not session or session.phase ~= 2 then return { ok = false, reason = "Boxes are placed in step 2 of the guided test." } end
    local size, x, y = tostring(args.size), tonumber(args.x), tonumber(args.y)
    local known = false
    for _, name in ipairs(G.SIZES) do known = known or name == size end
    if not known or not x or not y then return { ok = false, reason = "That is not a box size or a tile." } end
    x, y = math.floor(x), math.floor(y)
    local _, here = s.POBoxService.GetPlayerPostOffice(player)
    if tostring(here) ~= tostring(session.zoneId) or not inside(session.rect, x, y) then
        return { ok = false, reason = "Stand in the test post office and pick a tile inside its zone." }
    end
    local entry, reason = s.POBoxService.CreateBox(operator(player), { x = x, y = y, z = session.spot.z, size = size })
    if not entry then return { ok = false, reason = BOX_REASONS[reason] or tostring(reason) } end
    return { ok = true, box = describeBox(s, entry) }
end

------------------------------------------------------------
-- THE DELIVERY
------------------------------------------------------------

local function parcelData() return ModData.getOrCreate("KIPN_MarketplaceParcels") end

local function queuedParcels(username, order)
    local found = {}
    local data = parcelData()
    for _, parcel in ipairs(data.parcelsByOwner and data.parcelsByOwner[username] or {}) do
        if parcel.systemOrderId == order then found[#found + 1] = parcel end
    end
    return found
end

local function paperIds(player)
    local ids = {}
    eachItem(player, function(item)
        if item:getFullType() == G.PARCEL then ids[tostring(item:getID())] = true end
    end)
    return ids
end

local function delivery(order)
    return { systemOrderId = order, itemFullType = G.PARCEL, quantity = G.PARCEL_COUNT,
        displayName = "Post office test parcel (2 sheets of paper)", sourceType = "LilBubbyPostalTest" }
end

-- Queues the test parcel the way a server subsystem awards one, and checks
-- that asking twice still leaves one parcel. Returns nil and why on failure.
local function queueParcel(s, player, session, r)
    local username = player:getUsername()
    local journal = ModData.getOrCreate(G.JOURNAL)
    journal.sequence = (tonumber(journal.sequence) or 0) + 1
    local order = "LilBubbyPostalTest:" .. tostring(getTimestampMs()) .. ":" .. tostring(journal.sequence)
    journal.orders = journal.orders or {}
    journal.orders[username] = journal.orders[username] or {}
    table.insert(journal.orders[username], order)
    local market, recipient = s.MarketplaceService, { username = username }
    local parcel, reason = market.QueueSystemParcel(recipient, delivery(order))
    if not parcel then return nil, reason end
    local data = parcelData()
    r:check("The delivery is queued as one parcel of two sheets under its order", #queuedParcels(username, order) == 1
        and parcel.quantity == G.PARCEL_COUNT and parcel.itemFullType == G.PARCEL and data.systemOrders[order] == parcel.id)
    local again = market.QueueSystemParcel(recipient, delivery(order))
    r:check("Queuing the same order again before collection keeps the one parcel",
        again ~= nil and again.id == parcel.id and #queuedParcels(username, order) == 1)
    session.order, session.parcelId, session.paper = order, parcel.id, paperIds(player)
    local list = PostalTest.Handler(s, "GET_PARCELS")
    if type(list) == "function" then pcall(list, player, {}) end -- an open Postal Services page shows the parcel
    return parcel
end

local function lines(r, reply)
    reply.checks = r.lines
end

local STEPS = {}

-- 1: the overview was read. Next the player places boxes.
STEPS[1] = function(s, player, session, missing, reply)
    postOffice(s, player, session, missing)
    local cheapest
    for _, size in ipairs(sizes(s)) do
        if size.price and (not cheapest or size.price < cheapest) then cheapest = size.price end
    end
    purse(s, player, cheapest, missing)
    reply.sizes = sizes(s)
end

-- 2: a box of every size stands in the post office. Every box is checked.
STEPS[2] = function(s, player, session, missing, reply)
    postOffice(s, player, session, missing)
    local bySize, all = boxes(s, session)
    for _, size in ipairs(G.SIZES) do
        if #bySize[size] == 0 then
            missing[#missing + 1] = "No " .. size .. " PO Box stands in the post office yet."
        end
    end
    if #missing > 0 then return end
    reply.boxes = {}
    for _, entry in ipairs(all) do reply.boxes[#reply.boxes + 1] = describeBox(s, entry) end
    local r = PostalTest.Report()
    PostalTest.Boxes(r, player, s)
    lines(r, reply)
end

-- 3: the computer was explained. Next the player buys a box.
STEPS[3] = function(s, player, session, missing, reply)
    postOffice(s, player, session, missing)
    local _, all = boxes(s, session)
    local cheapest, available = nil, 0
    for _, entry in ipairs(all) do
        if not s.ClaimService.GetClaimForTarget(claimType(s), entry.id) then
            available = available + 1
            local price = s.POBoxService.GetPrice(entry)
            if price and (not cheapest or price < cheapest) then cheapest = price end
        end
    end
    if available == 0 then missing[#missing + 1] = "Every PO Box here is already owned. Cancel, clean up and start again." end
    reply.cash = purse(s, player, cheapest, missing)
    local allowed, reason = s.ClaimService.CheckMaxClaimsForType(player, claimType(s))
    if not allowed then
        missing[#missing + 1] = "You cannot rent another box: " .. tostring(reason) .. " Clean up the post office test to release your test boxes."
    end
    if #missing > 0 then return end
    session.before = {}
    for id in pairs(ownedClaims(s, player)) do session.before[id] = true end
    reply.available, reply.cheapest = available, cheapest
end

-- 4: a box of this post office was bought in this step and its key is
-- carried. Ownership and the key are checked and the test parcel is queued.
STEPS[4] = function(s, player, session, missing, reply)
    postOffice(s, player, session, missing)
    local bought
    for id, claim in pairs(ownedClaims(s, player)) do
        local entry = not session.before[id] and s.POBoxService.GetBox(claim.targetId)
        if entry and tostring(entry.zoneId) == tostring(session.zoneId) then bought = entry end
    end
    if not bought then
        missing[#missing + 1] = "No PO Box purchase at this post office is recorded for you yet."
        return
    end
    local key
    for _, held in ipairs(PostalTest.HeldKeys(s, player)) do
        if tostring(held.boxId) == tostring(bought.id) then key = held.item end
    end
    if not key then
        missing[#missing + 1] = "You own PO Box #" .. tostring(bought.number) .. " but do not carry its key. Pick the key up."
    end
    if #missing > 0 then return end
    local r = PostalTest.Report()
    PostalTest.Keys(r, player, s)
    local parcel, reason = queueParcel(s, player, session, r)
    if not parcel then
        reply.error = "the test parcel could not be queued (" .. tostring(reason) .. ")"
        return
    end
    reply.box, reply.cash = describeBox(s, bought), cash(s, player)
    lines(r, reply)
end

-- 5: the parcel was collected in Postal Services. The delivery is checked,
-- then replayed: a collected parcel can be neither collected nor queued again.
STEPS[5] = function(s, player, session, missing, reply)
    postOffice(s, player, session, missing)
    local username, order = player:getUsername(), session.order
    if #queuedParcels(username, order) > 0 then
        missing[#missing + 1] = "The parcel is still waiting. Open Postal Services on the computer and click COLLECT PARCELS."
    end
    if #missing > 0 then return end
    local r = PostalTest.Report()
    local data = parcelData()
    local function delivered()
        local found = {}
        eachItem(player, function(item)
            if item:getFullType() == G.PARCEL and not session.paper[tostring(item:getID())] then found[#found + 1] = item end
        end)
        return found
    end
    local papers = delivered()
    for _, item in ipairs(papers) do item:getModData()[G.TAG] = true end
    r:check("Collecting put the parcel's " .. G.PARCEL_COUNT .. " sheets of paper in your inventory (found " .. #papers .. ")",
        #papers == G.PARCEL_COUNT)
    r:check("The collected parcel left the queue and its order stays recorded as fulfilled",
        data.systemOrders ~= nil and data.systemOrders[order] == session.parcelId)
    local collect = PostalTest.Handler(s, "COLLECT_PARCEL")
    if r:check("The COLLECT_PARCEL command handler is registered", type(collect) == "function") then
        collect(player, { parcelId = session.parcelId })
        r:check("Collecting the same parcel a second time grants nothing", #delivered() == #papers and #queuedParcels(username, order) == 0)
    end
    local replay = s.MarketplaceService.QueueSystemParcel({ username = username }, delivery(order))
    r:check("Queuing the fulfilled order again cannot mint another parcel", replay ~= nil and replay.alreadyFulfilled == true
        and replay.id == session.parcelId and #queuedParcels(username, order) == 0)
    reply.papers = #papers
    lines(r, reply)
end

G.LAST = #STEPS

-- Checks the step the player finished and moves the test on when it passes.
-- stale = true answers a request for a step that is already behind.
function G.Advance(player, args)
    local s, why = services()
    if not s then return { error = why } end
    local session = G.sessions[player:getUsername()]
    if not session or not session.zoneId then return { error = NO_SESSION } end
    local step = STEPS[session.phase]
    if not step or tonumber(args and args.phase) ~= session.phase then return { stale = true, phase = session.phase } end
    local missing, reply = {}, {}
    step(s, player, session, missing, reply)
    if reply.error then return { error = reply.error } end
    if #missing > 0 then return { ok = false, phase = session.phase, missing = missing } end
    session.phase = session.phase + 1
    reply.ok, reply.phase = true, session.phase
    print("[LilBubbyPostalTest] " .. player:getUsername() .. " passed step " .. (session.phase - 1))
    return reply
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

-- Removes this player's test parcels still waiting, and their order records.
local function removeParcels(username)
    local journal, data, removed = ModData.getOrCreate(G.JOURNAL), parcelData(), 0
    local orders = journal.orders and journal.orders[username] or {}
    local queue = data.parcelsByOwner and data.parcelsByOwner[username] or {}
    for _, order in ipairs(orders) do
        for i = #queue, 1, -1 do
            if queue[i].systemOrderId == order then
                table.remove(queue, i)
                removed = removed + 1
            end
        end
        if data.systemOrders then data.systemOrders[order] = nil end
    end
    if journal.orders then journal.orders[username] = nil end
    return removed
end

-- Releases the boxes this player rented here, removes their keys, the boxes,
-- the test parcels, the money, Blank Key and paper the test gave, the
-- computer and the generator, and closes the zone. A box that cannot be
-- removed keeps the zone open.
function G.Cleanup(player)
    local name = player:getUsername()
    local result = { claims = 0, keys = 0, boxes = 0, items = 0, parcels = 0, kept = {} }
    G.sessions[name] = nil
    local s = services()
    local zoneId = s and LilBubbyDesk.ZoneId(player, "post_office")
    if zoneId then
        local mine = ownedClaims(s, player)
        local removable = {}
        for _, entry in ipairs(s.POBoxService.GetBoxesForZone(zoneId)) do
            local claim = s.ClaimService.GetClaimForTarget(claimType(s), entry.id)
            if claim and mine[tostring(claim.id)] and s.ClaimService.ReleaseClaim(claim.id, "lilbubby_postal_test_cleanup", player) then
                result.claims = result.claims + 1
            end
            removable[tostring(entry.id)] = entry
        end
        for _, held in ipairs(PostalTest.HeldKeys(s, player)) do
            local container = removable[tostring(held.boxId)] and held.item:getContainer()
            if container then
                remove(held.item, container)
                result.keys = result.keys + 1
            end
        end
        for _, entry in pairs(removable) do
            local ok, reason = s.POBoxService.DeleteBox(operator(player), { boxId = entry.id })
            if ok then result.boxes = result.boxes + 1
            else result.kept[#result.kept + 1] = "#" .. tostring(entry.number) .. ": " .. (BOX_REASONS[reason] or tostring(reason)) end
        end
    end
    if s then
        result.parcels = removeParcels(name)
        local list = PostalTest.Handler(s, "GET_PARCELS")
        if type(list) == "function" then pcall(list, player, {}) end
    end
    eachItem(player, function(item, container)
        if item:getModData()[G.TAG] then
            remove(item, container)
            result.items = result.items + 1
        end
    end)
    if LilBubbyDesk then
        if #result.kept > 0 then result.objects, result.zones = LilBubbyDesk.RemoveObjects(player), 0
        else result.objects, result.zones = LilBubbyDesk.Cleanup(player) end
    end
    return result
end

G.OPS = { begin = G.Begin, move = G.Move, setup = G.Setup, place = G.Place, advance = G.Advance, cleanup = G.Cleanup }

return PostalTest.Guided
