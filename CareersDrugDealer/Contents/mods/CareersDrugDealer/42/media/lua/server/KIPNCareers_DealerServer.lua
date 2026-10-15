-- Server-authoritative module. Without this guard, a client's Lua VM can
-- still load this file (see KIPNCareers_MechanicServer.lua, which already
-- carries the same line) and register bootstrapTick() on Events.OnTick.
-- On a client, Service.Initialize()'s "is KIPN.Server ready" check can
-- never pass, so the tick handler never removes itself: it retries and
-- logs (a synchronous file write via KIPN.Logger) every 30 ticks forever,
-- for the whole session. Confirmed 2026-09-04 from a player's client
-- console.txt as a permanent per-tick disk-I/O stall causing UI stutter.
if isClient() and not isServer() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_DealerShared"

-- The career is built on the framework's career registration
-- (KIPNCareers_Careers.lua); an older framework does not have it.
if (KIPNCareers.Shared.API_VERSION or 1) < 2 then
    print("[KIPN CAREERS][Dealer] Careers Framework is out of date; the Drug Dealer career is off until it is updated.")
    return
end

require "KIPNCareers_Host"
require "KIPNCareers_Economy"
require "KIPNCareers_NarcoticsAdapter"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_Careers"

local Shared = KIPNCareers.Shared
local Dealer = KIPNCareers.Dealer
local Host = KIPNCareers.Host
local Adapter = KIPNCareers.NarcoticsAdapter
local Economy = KIPNCareers.Economy
local ZoneBridge = KIPNCareers.ZoneBridge
local Careers = KIPNCareers.Careers
local Service = KIPNCareers.DealerServer or {}
KIPNCareers.DealerServer = Service

local initialized = false

local SYSTEM_CLIENTS = {
    "quiet regular", "night-shift cook", "traveling musician", "warehouse crew",
    "private party", "roadside motel", "club promoter", "anonymous collector",
}
local SYSTEM_VERBS = {
    "needs a discreet package of", "is looking to purchase", "requested",
    "will pay for a sealed delivery of", "needs a rush order of",
}
local SYSTEM_CLOSERS = {
    "Keep the package dry.", "No substitutions.", "Do not attract attention.",
    "Use a quiet drop.", "The buyer values punctuality.",
}

local function log(level, message)
    Shared.Log("Dealer.Server", level, message)
end

local nowHours, randomInteger = Host.NowHours, Host.RandomInteger
local identity, username, isAdmin = Host.Identity, Host.Username, Host.IsAdmin
local send, save, onlinePlayerByIdentity = Host.Send, Host.Save, Host.OnlinePlayerByIdentity
local collectItems = Host.CollectItems

local function randomChoice(values)
    if not values or #values == 0 then return nil end
    return values[randomInteger(1, #values)]
end

-- Sandbox options are KIPNCareers.DrugDealer<Name>. Up to 1.2 they had no
-- prefix; an old name is still read when the new one is absent.
local function option(raw, name)
    local value = raw["DrugDealer" .. name]
    if value == nil then value = raw[name] end
    return value
end

local function settings()
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    local defaults = Dealer.Defaults
    return {
        Enabled = option(raw, "Enabled") ~= false,
        RequireNarcoticsMod = option(raw, "RequireNarcoticsMod") ~= false,
        LicensePrice = Economy.Price(option(raw, "LicensePrice") or defaults.LICENSE_PRICE),
        StartingReputation = Shared.Clamp(option(raw, "StartingReputation") or defaults.STARTING_REPUTATION, 0, 100),
        SystemDeclineRepLoss = math.max(0, math.floor(tonumber(option(raw, "SystemDeclineRepLoss")) or defaults.SYSTEM_DECLINE_REP_LOSS)),
        FailureRepLoss = math.max(0, math.floor(tonumber(option(raw, "FailureRepLoss")) or defaults.FAILURE_REP_LOSS)),
        SuccessRepGain = math.max(0, math.floor(tonumber(option(raw, "SuccessRepGain")) or defaults.SUCCESS_REP_GAIN)),
        MaxActiveBuyerOrders = math.max(1, math.floor(tonumber(option(raw, "MaxActiveBuyerOrders")) or defaults.MAX_ACTIVE_BUYER_ORDERS)),
        MaxActiveDealerOrders = math.max(1, math.floor(tonumber(option(raw, "MaxActiveDealerOrders")) or defaults.MAX_ACTIVE_DEALER_ORDERS)),
        PlayerOrderListingHours = math.max(1, tonumber(option(raw, "PlayerOrderListingHours")) or defaults.PLAYER_ORDER_LISTING_HOURS),
        StandardDeadlineMinHours = math.max(1, tonumber(option(raw, "StandardDeadlineMinHours")) or defaults.STANDARD_MIN_HOURS),
        StandardDeadlineMaxHours = math.max(1, tonumber(option(raw, "StandardDeadlineMaxHours")) or defaults.STANDARD_MAX_HOURS),
        UrgentDeadlineMinHours = math.max(1, tonumber(option(raw, "UrgentDeadlineMinHours")) or defaults.URGENT_MIN_HOURS),
        UrgentDeadlineMaxHours = math.max(1, tonumber(option(raw, "UrgentDeadlineMaxHours")) or defaults.URGENT_MAX_HOURS),
        SystemOfferIntervalHours = math.max(1, tonumber(option(raw, "SystemOfferIntervalHours")) or defaults.SYSTEM_OFFER_INTERVAL_HOURS),
        MaxSystemOffersPerBusiness = math.max(0, math.floor(tonumber(option(raw, "MaxSystemOffersPerBusiness")) or defaults.MAX_SYSTEM_OFFERS)),
        PayoutMultiplier = math.max(0.1, tonumber(option(raw, "PayoutMultiplier")) or defaults.PAYOUT_MULTIPLIER),
        ContainerInteractionDistance = math.max(1, tonumber(option(raw, "MailboxInteractionDistance")) or defaults.CONTAINER_INTERACTION_DISTANCE),
        AdditionalDrugItemTypes = tostring(option(raw, "AdditionalDrugItemTypes") or ""),
        DisabledDrugItemTypes = tostring(option(raw, "DisabledDrugItemTypes") or ""),
    }
end

------------------------------------------------------------
-- CAREER
--
-- The framework keeps what every career keeps the same way: the data slice
-- (GetData().careers.drug_dealer), ids, the shared inbox, reputation, money
-- owed, licenses, the storefront and its flyers. See KIPNCareers_Careers.lua.
------------------------------------------------------------

-- Up to 1.2 the Drug Dealer's tables sat at the root of GetData().careers,
-- beside the other careers' slices. They move into its own slice once.
local LEGACY_ROOT_TABLES = {
    "licenses", "businesses", "orders", "reputation", "parcels",
    "pendingCurrency", "flyerQueue", "meta", "protection",
}

local function isEmpty(values)
    for _ in pairs(values) do return false end
    return true
end

local function migrateFromRoot(root, data)
    if data.migratedFromRoot then return end
    local moved = 0
    for _, name in ipairs(LEGACY_ROOT_TABLES) do
        if type(root[name]) == "table" and (type(data[name]) ~= "table" or isEmpty(data[name])) then
            data[name] = root[name]
            root[name] = nil
            moved = moved + 1
        end
    end
    data.sequence = math.max(tonumber(data.sequence) or 0, tonumber(root.sequence) or 0)
    root.sequence, root.schemaVersion = nil, nil
    -- Legacy from the zone-based delivery model.
    root.mailboxes = nil
    data.migratedFromRoot = true
    if moved > 0 then
        Shared.Log("Dealer.Server", "Info", "moved " .. tostring(moved) .. " Drug Dealer table(s) into careers." .. Dealer.CAREER_ID)
    end
end

local Career = Careers.Register(Dealer.CAREER_ID, {
    label = "Drug Dealer", logScope = "Dealer.Server",
    schemaVersion = Dealer.SCHEMA_VERSION,
    tables = { "orders", "parcels" },
    storefronts = "businesses", storefrontNoun = "storefront",
    events = { RESULT = Dealer.Events.RESULT, NOTIFICATION = Dealer.Events.NOTIFICATION },
    startingReputation = function() return settings().StartingReputation end,
    migrate = migrateFromRoot,
    license = {
        item = Dealer.Items.LICENSE, tokenField = "kipnCareersTokenId",
        name = "Drug Dealer Business License - ",
        modData = { kipnCareersCareerId = Dealer.CAREER_ID },
    },
    -- The capability zone gates the Business Profile menu program to the storefront.
    storefront = { capability = Dealer.Capabilities.BUSINESS, permission = Dealer.Permissions.BUSINESS_OWNER },
    flyer = {
        title = "Flyer - ",
        fields = { "name", "proprietorAlias", "description", "products", "hours", "meetingMethod", "adText" },
        write = function(modData, business, fields, revision)
            modData.kipnCareersBusinessId = business.id
            modData.kipnCareersFlyerRevision = revision
            modData.kipnCareersName = fields.name or business.name
            modData.kipnCareersProprietor = fields.proprietorAlias or business.proprietorAlias
            modData.kipnCareersDescription = fields.description or business.description
            modData.kipnCareersProducts = fields.products or business.products
            modData.kipnCareersHours = fields.hours or business.hours
            modData.kipnCareersMeeting = fields.meetingMethod or business.meetingMethod
            modData.kipnCareersAdText = fields.adText or business.adText
            return modData.kipnCareersName
        end,
    },
})

local function state() return Career:State() end
local function makeId(prefix) return Career:MakeId(prefix) end
local function result(player, action, ok, code, message, extra) return Career:Result(player, action, ok, code, message, extra) end
local function notify(ownerKey, title, body, relatedId) return Career:Notify(ownerKey, title, body, relatedId) end
local function reputationFor(ownerKey) return Career:ReputationFor(ownerKey) end
local function adjustReputation(ownerKey, delta, reason) return Career:AdjustReputation(ownerKey, delta, reason) end

------------------------------------------------------------
-- CURRENCY  (all via KIPNCareers_Economy -- see that file)
------------------------------------------------------------

local charge, refundReceipt = Economy.Charge, Economy.RefundReceipt

-- Payouts and refunds are queued first, then minted into inventory the next
-- time the payee is around (settlePending / snapshot).
local function credit(ownerKey, amount, reason) return Career:Credit(ownerKey, amount, reason) end
local function settlePending(player) return Career:SettlePending(player) end

------------------------------------------------------------
-- ITEM / CONTAINER HELPERS
------------------------------------------------------------

local function removeEntries(entries, count)
    local removed = {}
    for index = 1, count do
        local entry = entries[index]
        if not entry then return nil end
        entry.container:Remove(entry.item)
        removed[#removed + 1] = entry
    end
    return removed
end

local function restoreEntries(entries)
    local all = true
    for _, entry in ipairs(entries or {}) do
        local ok, item = pcall(entry.container.AddItem, entry.container, entry.item)
        if not ok or not item then all = false end
    end
    return all
end

local function isMailboxObject(object)
    if not object or type(object.getContainer) ~= "function" or not object:getContainer() then return false end
    local fields = {}
    local container = object:getContainer()
    fields[#fields + 1] = type(container.getType) == "function" and container:getType() or ""
    local sprite = type(object.getSprite) == "function" and object:getSprite() or nil
    fields[#fields + 1] = sprite and type(sprite.getName) == "function" and sprite:getName() or ""
    fields[#fields + 1] = type(object.getName) == "function" and object:getName() or ""
    local haystack = string.lower(table.concat(fields, " "))
    return string.find(haystack, "mailbox", 1, true) ~= nil
        or string.find(haystack, "postbox", 1, true) ~= nil
        or string.find(haystack, "mail_box", 1, true) ~= nil
end

-- Resolve a physical container object at a world square. wantMailbox true
-- returns a mailbox object; false returns the first non-mailbox container.
local function resolveContainerAt(x, y, z, wantMailbox)
    if type(getCell) ~= "function" or not getCell() then return nil end
    local square = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
    if not square then return nil end
    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        if object and type(object.getContainer) == "function" and object:getContainer() then
            local mb = isMailboxObject(object)
            if wantMailbox and mb then return object end
            if not wantMailbox and not mb then return object end
        end
    end
    return nil
end

local function nearPosition(player, x, y, z)
    if not player then return false end
    local dx, dy, dz = player:getX() - x, player:getY() - y, player:getZ() - (z or 0)
    local distance = settings().ContainerInteractionDistance
    return dx * dx + dy * dy <= distance * distance and math.abs(dz) <= 1
end

------------------------------------------------------------
-- BUSINESS
------------------------------------------------------------

local function ownedBusiness(ownerKey) return Career:OwnedStorefront(ownerKey) end

local function businessById(id)
    return id and Career:Storefronts()[id] or nil
end

-- The active storefront whose building bounds contain this terminal.
local function businessAtComputer(computerId) return Career:StorefrontAtComputer(computerId) end

------------------------------------------------------------
-- ORDERS
------------------------------------------------------------

local function deadlineHours(urgency)
    local config = settings()
    if urgency == Dealer.Urgencies.URGENT then
        return randomInteger(config.UrgentDeadlineMinHours, config.UrgentDeadlineMaxHours)
    end
    return randomInteger(config.StandardDeadlineMinHours, config.StandardDeadlineMaxHours)
end

local function orderVisibleToDealer(order, ownerKey, business)
    if not order or not business then return false end
    if order.status == Dealer.Status.OPEN then
        if order.source == Dealer.OrderSources.SYSTEM then return order.targetBusinessId == business.id end
        if order.targetBusinessId then return order.targetBusinessId == business.id end
        return not (order.declinedBy and order.declinedBy[ownerKey])
    end
    return order.dealerKey == ownerKey
        and (order.status == Dealer.Status.ACCEPTED or order.status == Dealer.Status.FULFILLED)
end

-- Every order the given business is responsible for (assigned or targeted).
local function orderBelongsToBusiness(order, business)
    if not order or not business then return false end
    return order.dealerBusinessId == business.id or order.targetBusinessId == business.id
end

local function publicOrder(order, viewerKey, dealerView)
    local copy = {
        id = order.id, source = order.source, status = order.status,
        itemType = order.itemType, itemLabel = order.itemLabel, quantity = order.quantity,
        payout = order.payout, urgency = order.urgency, objective = order.objective,
        createdAt = order.createdAt, expiresAt = order.expiresAt, deadlineAt = order.deadlineAt,
        fulfilledAt = order.fulfilledAt, deliveredAt = order.deliveredAt,
        targetBusinessId = order.targetBusinessId,
        note = order.note, dealerKey = order.dealerKey == viewerKey and order.dealerKey or nil,
    }
    if order.status == Dealer.Status.FULFILLED and type(order.dropAt) == "table" then
        copy.dropAt = { x = order.dropAt.x, y = order.dropAt.y, z = order.dropAt.z }
    end
    return copy
end

-- One reusable resolver: does the recorded drop container still hold the goods?
local function dropContainerReady(order)
    if order.status ~= Dealer.Status.FULFILLED or type(order.dropAt) ~= "table" then return false, nil end
    local object = resolveContainerAt(order.dropAt.x, order.dropAt.y, order.dropAt.z, false)
    if not object then return false, nil end
    local entries = collectItems(object:getContainer(), order.itemType, {})
    return #entries >= (tonumber(order.quantity) or 0), object
end

local function currencyValue()
    return Economy.ItemValue()
end

local function createSystemOrder(business)
    log("Info", "createSystemOrder business=" .. tostring(business and business.id))
    local data = state()
    local definition = Adapter.SelectForReputation(reputationFor(business.ownerKey))
    if not data or not definition then return nil, "NO_DRUG_ITEMS" end
    local reputation = reputationFor(business.ownerKey)
    local quantity = randomInteger(1, reputation >= 75 and 8 or (reputation >= 50 and 5 or 3))
    local urgency = randomInteger(1, 100) <= 25 and Dealer.Urgencies.URGENT or Dealer.Urgencies.STANDARD
    local variance = randomInteger(90, 115) / 100
    local rawPayout = definition.value * quantity * (urgency == Dealer.Urgencies.URGENT and 1.40 or 1.0) * variance * settings().PayoutMultiplier
    local payout = Economy.RoundDown(rawPayout)
    local objective = "A " .. randomChoice(SYSTEM_CLIENTS) .. " " .. randomChoice(SYSTEM_VERBS) .. " " .. tostring(quantity) .. " x " .. definition.label .. ". " .. randomChoice(SYSTEM_CLOSERS)
    local order = {
        id = makeId("order"), source = Dealer.OrderSources.SYSTEM, status = Dealer.Status.OPEN,
        careerId = Dealer.CAREER_ID, targetBusinessId = business.id, itemType = definition.type,
        itemLabel = definition.label, quantity = quantity, payout = payout, urgency = urgency,
        objective = objective, createdAt = nowHours(), expiresAt = nowHours() + settings().PlayerOrderListingHours,
    }
    data.orders[order.id] = order
    notify(business.ownerKey, "New purchase order", objective .. " Offer: " .. tostring(payout) .. ".", order.id)
    return order
end

local function expireOrders()
    local data = state()
    if not data then return false end
    local now = nowHours()
    local changed = false
    for _, order in pairs(data.orders) do
        if order.status == Dealer.Status.OPEN and order.expiresAt and now >= order.expiresAt then
            order.status = Dealer.Status.EXPIRED
            if order.source == Dealer.OrderSources.PLAYER and order.escrowState == "HELD" then
                credit(order.buyerKey, order.payout, "expired player order")
                order.escrowState = "REFUNDED"
                notify(order.buyerKey, "Order expired", "Your unaccepted order was refunded.", order.id)
            end
            changed = true
        elseif order.status == Dealer.Status.ACCEPTED and order.deadlineAt and now >= order.deadlineAt then
            -- FULFILLED orders never reach here: the dealer already delivered.
            order.status = Dealer.Status.EXPIRED
            adjustReputation(order.dealerKey, -settings().FailureRepLoss, "accepted order expired")
            if order.source == Dealer.OrderSources.PLAYER and order.escrowState == "HELD" then
                credit(order.buyerKey, order.payout, "failed player order")
                order.escrowState = "REFUNDED"
                notify(order.buyerKey, "Order failed", "The dealer missed the deadline; escrow was refunded.", order.id)
            end
            notify(order.dealerKey, "Delivery failed", "The deadline expired and your reputation fell.", order.id)
            changed = true
        end
    end
    if changed then save() end
    return changed
end

local function generateSystemOffers()
    local data = state()
    local config = settings()
    if not data or not config.Enabled or not Adapter.available or config.MaxSystemOffersPerBusiness <= 0 then return false end
    if nowHours() < (tonumber(data.meta.nextSystemOfferAt) or 0) then return false end
    local activeBusinesses = false
    for _, business in pairs(data.businesses) do
        if business.active ~= false and business.careerId == Dealer.CAREER_ID then activeBusinesses = true break end
    end
    if not activeBusinesses then return false end
    data.meta.nextSystemOfferAt = nowHours() + config.SystemOfferIntervalHours
    local changed = false
    for _, business in pairs(data.businesses) do
        if business.active ~= false and business.careerId == Dealer.CAREER_ID then
            local count = 0
            for _, order in pairs(data.orders) do
                if order.source == Dealer.OrderSources.SYSTEM and order.targetBusinessId == business.id and order.status == Dealer.Status.OPEN then count = count + 1 end
            end
            if count < config.MaxSystemOffersPerBusiness then createSystemOrder(business) changed = true end
        end
    end
    if changed then save() end
    return changed
end

------------------------------------------------------------
-- PARCELS  (player orders)
------------------------------------------------------------

local function createParcel(containerObject, order)
    local data = state()
    local container = containerObject and containerObject:getContainer()
    if not data or not container then return nil, "DELIVERY_CONTAINER_UNAVAILABLE" end
    local tokenId = makeId("parcel")
    local parcelItem = container:AddItem(Dealer.Items.PARCEL)
    if not parcelItem then return nil, "PARCEL_CREATION_FAILED" end
    parcelItem:getModData().kipnCareersTokenId = tokenId
    parcelItem:getModData().kipnCareersOrderId = order.id
    if type(parcelItem.setName) == "function" then parcelItem:setName("Sealed Parcel - " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel)) end
    data.parcels[tokenId] = {
        id = tokenId, orderId = order.id, itemType = order.itemType, itemLabel = order.itemLabel,
        quantity = order.quantity, status = "SEALED", createdAt = nowHours(),
        buyerKey = order.buyerKey, dealerKey = order.dealerKey,
    }
    return { tokenId = tokenId, item = parcelItem, container = container }
end

------------------------------------------------------------
-- POST-WORK-ORDER ACTIONS
--
-- The single finalize path shared by one-step mailbox delivery and two-step
-- Complete Work Order. Consumes the goods from `deliveryObject`, pays the
-- dealer, adjusts reputation, and (player orders) seals a bearer parcel and
-- notifies the buyer. Rolls everything back on any persistence failure.
-- New careers extend this by adding their own steps around the payout.
------------------------------------------------------------

local function runPostWorkOrderActions(order, deliveryObject, dealerPlayer)
    local data = state()
    if not data then return false, "STATE_UNAVAILABLE", "Career state unavailable." end
    local container = deliveryObject and deliveryObject:getContainer()
    if not container then return false, "DELIVERY_CONTAINER_UNAVAILABLE", "The delivery container is not loaded." end

    local entries = collectItems(container, order.itemType, {})
    if #entries < order.quantity then
        return false, "DELIVERY_ITEMS_MISSING", "The container needs " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel) .. "."
    end
    local removed = removeEntries(entries, order.quantity)
    if not removed then return false, "ITEM_REMOVAL_FAILED", "The delivery items could not be secured." end

    local parcel
    if order.source == Dealer.OrderSources.PLAYER then
        local reason
        parcel, reason = createParcel(deliveryObject, order)
        if not parcel then
            restoreEntries(removed)
            return false, reason, "The sealed parcel could not be created; the drugs were restored."
        end
        order.parcelTokenId = parcel.tokenId
    end

    local ownerKey = order.dealerKey
    local previousPending = tonumber(data.pendingCurrency[ownerKey]) or 0
    local previousReputation = reputationFor(ownerKey)
    local previousStatus = order.status
    order.status = Dealer.Status.DELIVERED
    order.deliveredAt = nowHours()

    local function rollback()
        order.status = previousStatus
        order.deliveredAt = nil
        data.pendingCurrency[ownerKey] = previousPending > 0 and previousPending or nil
        data.reputation[ownerKey] = previousReputation
        if parcel then
            parcel.container:Remove(parcel.item)
            data.parcels[parcel.tokenId] = nil
            order.parcelTokenId = nil
        end
        restoreEntries(removed)
    end

    if order.source == Dealer.OrderSources.PLAYER then
        if order.escrowState ~= "HELD" or not credit(ownerKey, order.payout, "player delivery") then
            rollback()
            return false, "PAYOUT_FAILED", "Payment could not be released; the delivery was rolled back."
        end
        order.escrowState = "RELEASED"
    else
        if not credit(ownerKey, order.payout, "system delivery") then
            rollback()
            return false, "PAYOUT_FAILED", "Payment could not be issued; the delivery was rolled back."
        end
    end

    local newRep = adjustReputation(ownerKey, settings().SuccessRepGain, "order completed")

    if not save() then
        if order.source == Dealer.OrderSources.PLAYER then order.escrowState = "HELD" end
        rollback()
        return false, "PERSISTENCE_FAILED", "The delivery transaction could not be committed; all items were restored."
    end

    settlePending(dealerPlayer or onlinePlayerByIdentity(ownerKey))

    local dropCoords = "a drop"
    local square = type(deliveryObject.getSquare) == "function" and deliveryObject:getSquare() or nil
    if square then dropCoords = tostring(square:getX()) .. ", " .. tostring(square:getY()) .. ", " .. tostring(square:getZ()) end
    if order.source == Dealer.OrderSources.PLAYER then
        notify(order.buyerKey, "Order delivered", "Your sealed parcel is waiting at " .. dropCoords .. ". Anyone carrying it can open it.", order.id)
    end
    notify(ownerKey, "Delivery complete", "Payment: " .. tostring(order.payout) .. ". Reputation: " .. tostring(newRep) .. ".", order.id)
    if KIPNCareers.DealerThreats then KIPNCareers.DealerThreats.AddHeat(businessById(order.dealerBusinessId)) end
    save()
    return true, "DELIVERY_COMPLETE", "Delivery complete. Payment released and reputation increased.", { reputation = newRep }
end

------------------------------------------------------------
-- SNAPSHOT  (Career Services screen)
------------------------------------------------------------

local function snapshot(player)
    settlePending(player)
    expireOrders()
    local data = state()
    local ownerKey = identity(player)
    if not data or not ownerKey then return nil end
    local business = ownedBusiness(ownerKey)
    local payload = {
        version = Dealer.VERSION, enabled = settings().Enabled, narcoticsAvailable = Adapter.available,
        narcoticsDetected = Adapter.modActive, reputation = reputationFor(ownerKey),
        licensePrice = settings().LicensePrice, currencyItemType = Economy.ItemType(),
        currencyItemValue = Economy.ItemValue(), balance = Economy.Balance(player),
        business = business, licenses = {}, dealerOrders = {}, buyerOrders = {},
        catalog = Adapter.GetCatalog(), businesses = {},
        notifications = Careers.Inbox(ownerKey),
        pendingCurrency = tonumber(data.pendingCurrency[ownerKey]) or 0, isAdmin = isAdmin(player),
        careerZones = {},
    }
    for _, license in pairs(data.licenses) do
        if license.ownerKey == ownerKey and license.status == "ACTIVE" then payload.licenses[#payload.licenses + 1] = license end
    end
    for _, candidate in pairs(data.businesses) do
        if candidate.active ~= false then payload.businesses[#payload.businesses + 1] = {
            id = candidate.id, name = candidate.name, proprietorAlias = candidate.proprietorAlias,
            description = candidate.description, products = candidate.products, hours = candidate.hours,
            meetingMethod = candidate.meetingMethod, adText = candidate.adText,
        } end
    end
    if business then
        for _, order in pairs(data.orders) do
            if orderVisibleToDealer(order, ownerKey, business) then
                payload.dealerOrders[#payload.dealerOrders + 1] = publicOrder(order, ownerKey, true)
            end
        end
    end
    for _, order in pairs(data.orders) do
        if order.buyerKey == ownerKey then payload.buyerOrders[#payload.buyerOrders + 1] = publicOrder(order, ownerKey, false) end
    end
    if isAdmin(player) then
        for zoneId, zone in pairs(ZoneBridge.GetZones(Shared.ZoneTypes.CAREER_SERVICES, true)) do
            payload.careerZones[#payload.careerZones + 1] = { id = zoneId, type = zone.type, name = (zone.metadata or {}).name or (zone.metadata or {}).label or zoneId, geometry = zone.geometry, active = zone.active ~= false }
        end
    end
    return payload
end

local function handleSnapshot(player, args)
    local payload = snapshot(player)
    if not payload then return false, "STATE_UNAVAILABLE" end
    payload.requestId = args and args.requestId
    send(player, Dealer.Events.SNAPSHOT, payload)
    return true
end

------------------------------------------------------------
-- LICENSE / BUSINESS
------------------------------------------------------------

local function handleBuyLicense(player, args)
    log("Info", "handleBuyLicense player=" .. username(player))
    local action = "buyLicense"
    if not settings().Enabled then result(player, action, false, "DISABLED", "The Drug Dealer career is disabled.") return true end
    if not Adapter.available then result(player, action, false, "NARCOTICS_UNAVAILABLE", "N&C's Narcotics item catalog is unavailable.") return true end
    if not Careers.HasServicesAccess(args and args.computerId, player) then result(player, action, false, "CAREER_SERVICES_ZONE_REQUIRED", "Use the nearby KIPN terminal inside a Career Services zone.") return true end
    if not identity(player) or not state() then return false, "STATE_UNAVAILABLE" end
    local tokenId, code, message = Career:IssueLicense(player, settings().LicensePrice)
    if not tokenId then result(player, action, false, code, message) return true end
    result(player, action, true, "LICENSE_ISSUED", "Your bearer license was issued to your inventory.", { tokenId = tokenId })
    return true
end

local function handleStartBusiness(player, args)
    log("Info", "handleStartBusiness player=" .. username(player))
    local action = "startBusiness"
    local ownerKey = identity(player)
    if ownedBusiness(ownerKey) then result(player, action, false, "BUSINESS_ALREADY_EXISTS", "You already operate an active Drug Dealer business.") return true end
    local license, entry = Career:FindLicense(player, args and args.tokenId)
    if not license then
        result(player, action, false, "VALID_LICENSE_REQUIRED", "A valid bearer Drug Dealer license must be in your inventory.") return true
    end
    local rect, code, message = Career:CheckSite(player)
    if not rect then result(player, action, false, code, message) return true end
    local businessId = makeId("business")
    local business = {
        id = businessId, careerId = Dealer.CAREER_ID, ownerKey = ownerKey, ownerName = username(player),
        active = true, createdAt = nowHours(), bounds = rect,
        anchor = { x = player:getX(), y = player:getY(), z = player:getZ() },
        name = username(player) .. "'s Business", proprietorAlias = username(player),
        description = "Independent supplier.", products = "See current inventory.",
        hours = "By appointment", meetingMethod = "Contact through KIPN.", adText = "Discreet service.",
        flyerRevision = 0, distributedFlyerRevision = 0,
    }
    local opened
    opened, code, message = Career:OpenStorefront(player, license, entry, business)
    if not opened then result(player, action, false, code, message) return true end

    result(player, action, true, "BUSINESS_STARTED", "Your storefront is established. Open Business Profile from a terminal here.", { businessId = businessId })
    return true
end

local function handleSaveBusiness(player, args)
    log("Info", "handleSaveBusiness player=" .. username(player))
    local action = "saveBusiness"
    local business = ownedBusiness(identity(player))
    if not business then result(player, action, false, "BUSINESS_REQUIRED", "You do not have an active business.") return true end
    local fields = args and args.fields or {}
    business.name = Shared.Trim(fields.name, Dealer.Defaults.BUSINESS_NAME_MAX)
    business.proprietorAlias = Shared.Trim(fields.proprietorAlias, Dealer.Defaults.BUSINESS_NAME_MAX)
    business.description = Shared.Trim(fields.description, Dealer.Defaults.TEXT_MAX)
    business.products = Shared.Trim(fields.products, Dealer.Defaults.TEXT_MAX)
    business.hours = Shared.Trim(fields.hours, 96)
    business.meetingMethod = Shared.Trim(fields.meetingMethod, Dealer.Defaults.TEXT_MAX)
    business.adText = Shared.Trim(fields.adText, Dealer.Defaults.TEXT_MAX)
    if business.name == "" or business.description == "" then result(player, action, false, "REQUIRED_FIELDS", "Business name and description are required.") return true end
    business.flyerRevision = (tonumber(business.flyerRevision) or 0) + 1
    business.updatedAt = nowHours()
    if not save() then result(player, action, false, "PERSISTENCE_FAILED", "Business changes could not be saved.") return true end
    result(player, action, true, "BUSINESS_SAVED", "Business details saved. The new flyer revision enters loot distribution after the next server restart.")
    return true
end

------------------------------------------------------------
-- PLAYER ORDERS
------------------------------------------------------------

local function countActiveOrders(ownerKey, role)
    local count = 0
    for _, order in pairs((state() or {}).orders or {}) do
        local matches = role == "buyer" and order.buyerKey == ownerKey or role == "dealer" and order.dealerKey == ownerKey
        if matches and Dealer.IsDrugOrderStatusActive(order.status) then count = count + 1 end
    end
    return count
end

local function handleSubmitOrder(player, args)
    log("Info", "handleSubmitOrder player=" .. username(player))
    local action = "submitOrder"
    local config = settings()
    local buyerKey = identity(player)
    local data = state()
    if not config.Enabled or not Adapter.available then result(player, action, false, "CAREER_UNAVAILABLE", "Drug Dealer orders are unavailable.") return true end
    if countActiveOrders(buyerKey, "buyer") >= config.MaxActiveBuyerOrders then result(player, action, false, "BUYER_ORDER_LIMIT", "You have reached the active work-order limit.") return true end
    local definition = Adapter.Get(args and args.itemType)
    if not definition then result(player, action, false, "INVALID_DRUG_ITEM", "Choose an enabled drug item.") return true end
    local quantity = math.floor(tonumber(args.quantity) or 0)
    local payout = math.floor(tonumber(args.payout) or 0)
    local itemValue = currencyValue()
    if quantity < 1 or quantity > 100 then result(player, action, false, "INVALID_QUANTITY", "Quantity must be between 1 and 100.") return true end
    if payout < itemValue or payout > 1000000 or payout % itemValue ~= 0 then result(player, action, false, "INVALID_OFFER", "Offer must be between one currency unit and 1,000,000, and an exact multiple of the configured item value.") return true end
    local targetBusinessId = Shared.Trim(args.targetBusinessId, 128)
    if targetBusinessId == "PUBLIC" or targetBusinessId == "" then targetBusinessId = nil end
    if targetBusinessId and (not data.businesses[targetBusinessId] or data.businesses[targetBusinessId].active == false) then result(player, action, false, "INVALID_BUSINESS", "The selected business is unavailable.") return true end
    local paid, reason, receipt = charge(player, payout)
    if not paid then result(player, action, false, reason, "Escrow payment failed: " .. tostring(reason)) return true end
    local urgency = args.urgency == Dealer.Urgencies.URGENT and Dealer.Urgencies.URGENT or Dealer.Urgencies.STANDARD
    local order = {
        id = makeId("order"), source = Dealer.OrderSources.PLAYER, status = Dealer.Status.OPEN,
        careerId = Dealer.CAREER_ID, buyerKey = buyerKey, buyerName = username(player),
        targetBusinessId = targetBusinessId,
        itemType = definition.type, itemLabel = definition.label, quantity = quantity,
        payout = payout, escrowState = "HELD", urgency = urgency,
        note = Shared.Trim(args.note, Dealer.Defaults.TEXT_MAX), createdAt = nowHours(),
        expiresAt = nowHours() + config.PlayerOrderListingHours, declinedBy = {},
    }
    order.objective = "Player order: deliver " .. tostring(quantity) .. " x " .. definition.label .. ". Offer: " .. tostring(payout) .. ". " .. order.note
    data.orders[order.id] = order
    if not save() then data.orders[order.id] = nil refundReceipt(receipt) result(player, action, false, "PERSISTENCE_FAILED", "The order could not be saved; escrow was refunded.") return true end
    if targetBusinessId then notify(data.businesses[targetBusinessId].ownerKey, "Direct player work order", order.objective, order.id) end
    result(player, action, true, "ORDER_POSTED", "Your offer is held in escrow until delivery or refund.", { orderId = order.id })
    return true
end

local function handleAcceptOrder(player, args)
    log("Info", "handleAcceptOrder player=" .. username(player))
    local action = "acceptOrder"
    local ownerKey = identity(player)
    local business = ownedBusiness(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not business then result(player, action, false, "BUSINESS_REQUIRED", "An active Drug Dealer business is required.") return true end
    if countActiveOrders(ownerKey, "dealer") >= settings().MaxActiveDealerOrders then result(player, action, false, "DEALER_ORDER_LIMIT", "You have reached the accepted-order limit.") return true end
    if not order or order.status ~= Dealer.Status.OPEN or not orderVisibleToDealer(order, ownerKey, business) then result(player, action, false, "ORDER_UNAVAILABLE", "That work order is no longer available to you.") return true end
    if order.source == Dealer.OrderSources.PLAYER and order.buyerKey == ownerKey then result(player, action, false, "SELF_DEALING_BLOCKED", "You cannot accept your own player-funded work order.") return true end
    if order.expiresAt and nowHours() >= order.expiresAt then expireOrders() result(player, action, false, "ORDER_EXPIRED", "That work order has expired.") return true end
    local previousStatus = order.status
    order.status = Dealer.Status.ACCEPTED
    order.dealerKey = ownerKey
    order.dealerBusinessId = business.id
    order.acceptedAt = nowHours()
    order.deadlineAt = nowHours() + deadlineHours(order.urgency)
    if not save() then
        order.status = previousStatus order.dealerKey = nil order.dealerBusinessId = nil order.acceptedAt = nil order.deadlineAt = nil
        result(player, action, false, "PERSISTENCE_FAILED", "The acceptance could not be saved.") return true
    end
    notify(ownerKey, "Order accepted", "Deliver " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel)
        .. " before hour " .. string.format("%.1f", order.deadlineAt)
        .. ". Right-click any mailbox to seal it instantly, or drop it in any container and press Complete Work Order.", order.id)
    result(player, action, true, "ORDER_ACCEPTED", "Order accepted. The timer is now running.", { orderId = order.id, deadlineAt = order.deadlineAt })
    return true
end

local function handleDeclineOrder(player, args)
    log("Info", "handleDeclineOrder player=" .. username(player))
    local action = "declineOrder"
    local ownerKey = identity(player)
    local business = ownedBusiness(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not business or not order or order.status ~= Dealer.Status.OPEN or not orderVisibleToDealer(order, ownerKey, business) then result(player, action, false, "ORDER_UNAVAILABLE", "That work order cannot be declined.") return true end
    local previousStatus = order.status
    local previousReputation = reputationFor(ownerKey)
    local previousPending = order.buyerKey and (tonumber(data.pendingCurrency[order.buyerKey]) or 0) or 0
    local publicDecline = false
    if order.source == Dealer.OrderSources.SYSTEM then
        order.status = Dealer.Status.DECLINED
        adjustReputation(ownerKey, -settings().SystemDeclineRepLoss, "system offer declined")
    elseif order.targetBusinessId then
        order.status = Dealer.Status.DECLINED
        if order.escrowState == "HELD" then credit(order.buyerKey, order.payout, "direct order declined") order.escrowState = "REFUNDED" end
    else
        order.declinedBy = order.declinedBy or {}
        order.declinedBy[ownerKey] = true
        publicDecline = true
    end
    if not save() then
        order.status = previousStatus
        data.reputation[ownerKey] = previousReputation
        if order.buyerKey then data.pendingCurrency[order.buyerKey] = previousPending > 0 and previousPending or nil end
        if order.source == Dealer.OrderSources.PLAYER and order.targetBusinessId then order.escrowState = "HELD" end
        if publicDecline then order.declinedBy[ownerKey] = nil end
        result(player, action, false, "PERSISTENCE_FAILED", "The decline could not be saved.")
        return true
    end
    if order.source == Dealer.OrderSources.PLAYER and order.targetBusinessId then
        notify(order.buyerKey, "Direct order declined", "The selected business declined your order; escrow was refunded.", order.id)
        save()
    end
    result(player, action, true, "ORDER_DECLINED", "The offer was declined.")
    return true
end

local function handleCancelOrder(player, args)
    log("Info", "handleCancelOrder player=" .. username(player))
    local action = "cancelOrder"
    local ownerKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.buyerKey ~= ownerKey or order.source ~= Dealer.OrderSources.PLAYER then result(player, action, false, "ORDER_NOT_OWNED", "That player order does not belong to you.") return true end
    if order.status ~= Dealer.Status.OPEN then result(player, action, false, "ORDER_ALREADY_COMMITTED", "Accepted or completed orders cannot be cancelled.") return true end
    local previousPending = tonumber(data.pendingCurrency[ownerKey]) or 0
    order.status = Dealer.Status.CANCELLED
    if order.escrowState == "HELD" then credit(ownerKey, order.payout, "player order cancelled") order.escrowState = "REFUNDED" end
    if not save() then
        order.status = Dealer.Status.OPEN
        order.escrowState = "HELD"
        data.pendingCurrency[ownerKey] = previousPending > 0 and previousPending or nil
        result(player, action, false, "PERSISTENCE_FAILED", "The cancellation could not be saved.")
        return true
    end
    settlePending(player)
    result(player, action, true, "ORDER_CANCELLED", "The order was cancelled and escrow was refunded.")
    return true
end

------------------------------------------------------------
-- DELIVERY
------------------------------------------------------------

-- One-step: right-click any mailbox that holds the goods.
local function handleSealDelivery(player, args)
    log("Info", "handleSealDelivery player=" .. username(player))
    local action = "sealDelivery"
    local ownerKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.dealerKey ~= ownerKey or order.status ~= Dealer.Status.ACCEPTED then result(player, action, false, "ORDER_UNAVAILABLE", "That accepted order is unavailable.") return true end
    if order.deadlineAt and nowHours() >= order.deadlineAt then expireOrders() result(player, action, false, "ORDER_EXPIRED", "The delivery deadline has expired.") return true end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z or 0)
    if not x or not y then result(player, action, false, "MAILBOX_REQUIRED", "Right-click a mailbox to seal the delivery.") return true end
    if not nearPosition(player, x, y, z) then result(player, action, false, "TOO_FAR", "Stand beside the mailbox.") return true end
    local object = resolveContainerAt(x, y, z, true)
    if not object then result(player, action, false, "MAILBOX_REQUIRED", "That is not a loaded mailbox. Use a container drop instead.") return true end
    local ok, code, message, extra = runPostWorkOrderActions(order, object, player)
    result(player, action, ok, code, message, extra)
    if ok and KIPNCareers.DealerThreats then KIPNCareers.DealerThreats.OnDrop(order, player, x, y, z, nil) end
    return true
end

-- Two-step step 1: drop the goods in any non-mailbox container. The business
-- owner finishes with Complete Work Order.
local function handleDropDelivery(player, args)
    log("Info", "handleDropDelivery player=" .. username(player))
    local action = "dropDelivery"
    local ownerKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.dealerKey ~= ownerKey or order.status ~= Dealer.Status.ACCEPTED then result(player, action, false, "ORDER_UNAVAILABLE", "That accepted order is unavailable.") return true end
    if order.deadlineAt and nowHours() >= order.deadlineAt then expireOrders() result(player, action, false, "ORDER_EXPIRED", "The delivery deadline has expired.") return true end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z or 0)
    if not x or not y then result(player, action, false, "CONTAINER_REQUIRED", "Right-click a container to drop the delivery.") return true end
    if not nearPosition(player, x, y, z) then result(player, action, false, "TOO_FAR", "Stand beside the container.") return true end
    local object = resolveContainerAt(x, y, z, false)
    if not object then result(player, action, false, "CONTAINER_REQUIRED", "That is not a usable drop container. Mailboxes seal instantly instead.") return true end
    local entries = collectItems(object:getContainer(), order.itemType, {})
    if #entries < order.quantity then
        result(player, action, false, "DELIVERY_ITEMS_MISSING", "Put " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel) .. " in the container first.")
        return true
    end
    local previousStatus = order.status
    order.status = Dealer.Status.FULFILLED
    order.fulfilledAt = nowHours()
    order.dropAt = { x = math.floor(x), y = math.floor(y), z = math.floor(z) }
    if not save() then
        order.status = previousStatus order.fulfilledAt = nil order.dropAt = nil
        result(player, action, false, "PERSISTENCE_FAILED", "The drop could not be saved.")
        return true
    end
    local business = businessById(order.dealerBusinessId)
    if business then
        notify(business.ownerKey, "Work order ready to complete",
            tostring(order.quantity) .. " x " .. tostring(order.itemLabel)
            .. " is waiting at " .. tostring(order.dropAt.x) .. ", " .. tostring(order.dropAt.y) .. ", " .. tostring(order.dropAt.z)
            .. ". Press Complete Work Order in Business Profile.", order.id)
    end
    result(player, action, true, "DELIVERY_DROPPED", "Delivery dropped. The business owner completes the work order.")
    if KIPNCareers.DealerThreats then KIPNCareers.DealerThreats.OnDrop(order, player, x, y, z, object) end
    return true
end

-- Two-step step 2: from Business Profile, at the storefront terminal.
local function handleCompleteWorkOrder(player, args)
    log("Info", "handleCompleteWorkOrder player=" .. username(player))
    local action = "completeWorkOrder"
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.status ~= Dealer.Status.FULFILLED then result(player, action, false, "ORDER_UNAVAILABLE", "That work order cannot be completed.") return true end
    local business = businessAtComputer(args and args.computerId)
    if not business or business.ownerKey ~= identity(player) then result(player, action, false, "BUSINESS_PROFILE_REQUIRED", "Use a terminal inside your own storefront.") return true end
    if not orderBelongsToBusiness(order, business) then result(player, action, false, "NOT_YOUR_ORDER", "This work order belongs to another business.") return true end
    local ready, object = dropContainerReady(order)
    if not ready then result(player, action, false, "DROP_ITEMS_MISSING", "The drop container no longer holds " .. tostring(order.quantity) .. " x " .. tostring(order.itemLabel) .. ".") return true end
    local ok, code, message, extra = runPostWorkOrderActions(order, object, onlinePlayerByIdentity(order.dealerKey))
    result(player, action, ok, code, message, extra)
    return true
end

local function handleOpenParcel(player, args)
    log("Info", "handleOpenParcel player=" .. username(player))
    local action = "openParcel"
    local tokenId = tostring(args and args.tokenId or "")
    local data = state()
    local parcel = data and data.parcels[tokenId]
    local entry = player and Careers.FindTokenItem(player, Dealer.Items.PARCEL, "kipnCareersTokenId", tokenId)
    if not parcel or parcel.status ~= "SEALED" or not entry then result(player, action, false, "INVALID_PARCEL", "This parcel token is missing, copied, or already redeemed.") return true end
    local inventory = player:getInventory()
    local granted = {}
    for _ = 1, parcel.quantity do
        local item = inventory:AddItem(parcel.itemType)
        if not item then
            for _, rollbackItem in ipairs(granted) do inventory:Remove(rollbackItem) end
            result(player, action, false, "PARCEL_CONTENT_CREATION_FAILED", "Parcel contents could not be created.") return true
        end
        granted[#granted + 1] = item
    end
    entry.container:Remove(entry.item)
    parcel.status = "REDEEMED"
    parcel.redeemedAt = nowHours()
    parcel.redeemedBy = identity(player)
    local order = data.orders[parcel.orderId]
    if order then order.status = Dealer.Status.COLLECTED order.collectedAt = nowHours() order.collectedBy = identity(player) end
    if not save() then
        for _, rollbackItem in ipairs(granted) do inventory:Remove(rollbackItem) end
        entry.container:AddItem(entry.item)
        parcel.status = "SEALED" parcel.redeemedAt = nil parcel.redeemedBy = nil
        if order then order.status = Dealer.Status.DELIVERED order.collectedAt = nil order.collectedBy = nil end
        result(player, action, false, "PERSISTENCE_FAILED", "The parcel could not be redeemed safely.") return true
    end
    result(player, action, true, "PARCEL_OPENED", "Parcel opened: " .. tostring(parcel.quantity) .. " x " .. tostring(parcel.itemLabel) .. ".")
    return true
end

------------------------------------------------------------
-- BUSINESS PROFILE
------------------------------------------------------------

local function businessProfilePayload(player, computerId)
    local business = businessAtComputer(computerId)
    local ownerKey = identity(player)
    if not business or business.ownerKey ~= ownerKey then
        return { business = nil, atStorefront = business ~= nil }
    end
    local data = state()
    local payload = {
        atStorefront = true,
        business = {
            id = business.id, name = business.name, proprietorAlias = business.proprietorAlias,
            description = business.description, products = business.products, hours = business.hours,
            meetingMethod = business.meetingMethod, adText = business.adText,
            createdAt = business.createdAt, flyerRevision = business.flyerRevision,
            anchor = business.anchor,
        },
        reputation = reputationFor(ownerKey),
        pendingCurrency = tonumber(data.pendingCurrency[ownerKey]) or 0,
        currencyItemType = Economy.ItemType(),
        orders = {},
    }
    for _, order in pairs(data.orders) do
        if orderBelongsToBusiness(order, business) then
            local row = publicOrder(order, ownerKey, true)
            row.isSystem = order.source == Dealer.OrderSources.SYSTEM
            row.buyerName = order.source == Dealer.OrderSources.PLAYER and order.buyerName or nil
            if order.status == Dealer.Status.FULFILLED then
                row.canComplete = (dropContainerReady(order)) == true
            end
            payload.orders[#payload.orders + 1] = row
        end
    end
    return payload
end

local function handleBusinessProfile(player, args)
    local payload = businessProfilePayload(player, args and args.computerId)
    payload.requestId = args and args.requestId
    send(player, Dealer.Events.BUSINESS_PROFILE, payload)
    return true
end

------------------------------------------------------------
-- COMMAND ROUTING
------------------------------------------------------------

-- Internals for KIPNCareers_DealerThreats.lua.
Service.Bridge = {
    career = Career,
    state = state, save = save, settings = settings, nowHours = nowHours,
    notify = notify, reputationFor = reputationFor, businessById = businessById,
    onlinePlayerByIdentity = onlinePlayerByIdentity,
}

local handlers = {
    [Dealer.Commands.SNAPSHOT] = handleSnapshot,
    [Dealer.Commands.BUY_LICENSE] = handleBuyLicense,
    [Dealer.Commands.START_BUSINESS] = handleStartBusiness,
    [Dealer.Commands.SAVE_BUSINESS] = handleSaveBusiness,
    [Dealer.Commands.ACCEPT_ORDER] = handleAcceptOrder,
    [Dealer.Commands.DECLINE_ORDER] = handleDeclineOrder,
    [Dealer.Commands.SEAL_DELIVERY] = handleSealDelivery,
    [Dealer.Commands.DROP_DELIVERY] = handleDropDelivery,
    [Dealer.Commands.COMPLETE_WORK_ORDER] = handleCompleteWorkOrder,
    [Dealer.Commands.BUSINESS_PROFILE] = handleBusinessProfile,
    [Dealer.Commands.SUBMIT_ORDER] = handleSubmitOrder,
    [Dealer.Commands.CANCEL_ORDER] = handleCancelOrder,
    [Dealer.Commands.OPEN_PARCEL] = handleOpenParcel,
}

local commandsRequiringSession = {
    [Dealer.Commands.BUY_LICENSE] = true,
    [Dealer.Commands.SAVE_BUSINESS] = true,
    [Dealer.Commands.ACCEPT_ORDER] = true,
    [Dealer.Commands.DECLINE_ORDER] = true,
    [Dealer.Commands.COMPLETE_WORK_ORDER] = true,
    [Dealer.Commands.BUSINESS_PROFILE] = true,
    [Dealer.Commands.SUBMIT_ORDER] = true,
    [Dealer.Commands.CANCEL_ORDER] = true,
}

local function scanSquare(square)
    if not initialized or not square then return end
    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        Career:DistributeFlyer(objects:get(index))
    end
end

local function periodicTick()
    if not initialized then Service.Initialize() return end
    expireOrders()
    generateSystemOffers()
end

function Service.Initialize()
    if initialized then return true end
    if not KIPN or not KIPN.Server or not state() then
        log("Warn", "KIPN server is not ready; initialization deferred")
        return false
    end
    Adapter.Initialize(settings())
    if not Career:RegisterCommands(handlers, commandsRequiringSession, "Log in to KIPN before using this Career Services action.") then
        log("Warn", "KIPN server is not ready; initialization deferred")
        return false
    end
    initialized = true
    Career:ActivateFlyerQueue()
    expireOrders()
    generateSystemOffers()
    log("Info", "Careers: Drug Dealer initialized version=" .. Dealer.VERSION)
    return true
end

Careers.Bootstrap(Service.Initialize)
if Events.LoadGridsquare then Events.LoadGridsquare.Add(scanSquare) end
if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(periodicTick) end

return Service
