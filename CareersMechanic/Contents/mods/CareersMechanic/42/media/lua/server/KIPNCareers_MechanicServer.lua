-- KIPNCareers_MechanicServer.lua
--
-- Server authority for the Mechanic profession. A parallel career on the
-- Careers Framework: its own data slice (GetData().careers.mechanic), its own
-- command handlers on the KIPN router, its own two menu programs. It is
-- registered with KIPNCareers.Careers, which keeps for it:
--   * the data slice, ids, reputation and money owed to players
--   * the license item and its record
--   * the storefront: site checks (No Claim, other storefronts, safehouses),
--     the capability zone and the owner permission
--   * the per-owner notification inbox (careers.notifications[ownerKey])
--   * the generic BusinessFlyer item + flyer queue
-- and moves money through KIPNCareers.Economy.
--
-- Phase 1: license, shop claim (+ capability zone + owner permission), shop
-- profile + flyer queue, the three business-container types, self-perpetuating
-- Public work-order forms, player work orders with escrow, the Fast/Regular/Slow
-- quote engine, Work Order Complete -> client approval -> payout.
--
-- Deferred (see the mod README): For Sale "Buy Now", real vehicle part
-- reads/writes, server-generated vehicle work orders + map markers + the
-- deep-wound penalty, private-container visibility enforcement, the PvP block
-- and melee-only Dispute Resolution.

if isClient() and not isServer() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_MechanicShared"

-- The career is built on the framework's career registration
-- (KIPNCareers_Careers.lua); an older framework does not have it.
if (KIPNCareers.Shared.API_VERSION or 1) < 2 then
    print("[KIPN CAREERS][Mechanic] Careers Framework is out of date; the Mechanic profession is off until it is updated.")
    return
end

require "KIPNCareers_Host"
require "KIPNCareers_Economy"
require "KIPNCareers_Storefronts"
require "KIPNCareers_Careers"

local Shared = KIPNCareers.Shared
local Mechanic = KIPNCareers.Mechanic
local Host = KIPNCareers.Host
local Economy = KIPNCareers.Economy
local Storefronts = KIPNCareers.Storefronts
local Careers = KIPNCareers.Careers
local Service = KIPNCareers.MechanicServer or {}
KIPNCareers.MechanicServer = Service

local initialized = false

local function log(level, message)
    Mechanic.Log("Server", level, message)
end

local nowHours, randomInteger = Host.NowHours, Host.RandomInteger
local identity, username, isAdmin = Host.Identity, Host.Username, Host.IsAdmin
local send, save, onlinePlayerByIdentity = Host.Send, Host.Save, Host.OnlinePlayerByIdentity
local collectItems = Host.CollectItems
local pointInBounds = Storefronts.Contains
local hasServicesAccess = Careers.HasServicesAccess

local function settings()
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    local d = Mechanic.Defaults
    return {
        Enabled = raw.MechanicEnabled ~= false,
        LicensePrice = Economy.Price(raw.MechanicLicensePrice or d.LICENSE_PRICE),
        StartingReputation = Shared.Clamp(raw.MechanicStartingReputation or d.STARTING_REPUTATION, 0, 100),
        FailureRepLoss = math.max(0, math.floor(tonumber(raw.MechanicFailureRepLoss) or d.FAILURE_REP_LOSS)),
        SuccessRepGain = math.max(0, math.floor(tonumber(raw.MechanicSuccessRepGain) or d.SUCCESS_REP_GAIN)),
        MaxActiveClientOrders = math.max(1, math.floor(tonumber(raw.MechanicMaxActiveClientOrders) or d.MAX_ACTIVE_CLIENT_ORDERS)),
        MaxActiveShopOrders = math.max(1, math.floor(tonumber(raw.MechanicMaxActiveShopOrders) or d.MAX_ACTIVE_SHOP_ORDERS)),
        OrderListingHours = math.max(1, tonumber(raw.MechanicOrderListingHours) or d.ORDER_LISTING_HOURS),
        SystemOrderIntervalHours = math.max(1, tonumber(raw.MechanicSystemOrderIntervalHours) or d.SYSTEM_ORDER_INTERVAL_HOURS),
        MaxSystemOrdersPerShop = math.max(0, math.floor(tonumber(raw.MechanicMaxSystemOrdersPerShop) or d.MAX_SYSTEM_ORDERS_PER_SHOP)),
        BasePartPrice = math.max(1, math.floor(tonumber(raw.MechanicBasePartPrice) or d.BASE_PART_PRICE)),
        LowQualityDiscountPercent = Shared.Clamp(raw.MechanicLowQualityDiscountPercent or d.LOW_QUALITY_DISCOUNT_PERCENT, 0, 90),
        FastPriceMultiplier = math.max(0.1, tonumber(raw.MechanicFastPriceMultiplier) or d.FAST_PRICE_MULTIPLIER),
        RegularPriceMultiplier = math.max(0.1, tonumber(raw.MechanicRegularPriceMultiplier) or d.REGULAR_PRICE_MULTIPLIER),
        SlowPriceMultiplier = math.max(0.1, tonumber(raw.MechanicSlowPriceMultiplier) or d.SLOW_PRICE_MULTIPLIER),
        FastCompletionHours = math.max(1, math.floor(tonumber(raw.MechanicFastCompletionHours) or d.FAST_HOURS)),
        RegularCompletionHours = math.max(1, math.floor(tonumber(raw.MechanicRegularCompletionHours) or d.REGULAR_HOURS)),
        SlowCompletionHours = math.max(1, math.floor(tonumber(raw.MechanicSlowCompletionHours) or d.SLOW_HOURS)),
        MaxRepairsPerOrder = math.max(1, math.floor(tonumber(raw.MechanicMaxRepairsPerOrder) or d.MAX_REPAIRS_PER_ORDER)),
        PublicFormRefillMinutes = math.max(1, math.floor(tonumber(raw.MechanicPublicFormRefillMinutes) or d.PUBLIC_FORM_REFILL_MINUTES)),
        ContainerInteractionDistance = math.max(1, math.floor(tonumber(raw.MechanicContainerInteractionDistance) or d.CONTAINER_DISTANCE)),
        CurrencyItemValue = Economy.ItemValue(),
    }
end

------------------------------------------------------------
-- CAREER
--
-- The framework keeps what every career keeps the same way: the data slice
-- (GetData().careers.mechanic), ids, the shared inbox, reputation, money owed,
-- licenses, the storefront and its flyers. See KIPNCareers_Careers.lua.
------------------------------------------------------------

local Career = Careers.Register(Mechanic.CAREER_ID, {
    label = "Mechanic", logScope = "Mechanic.Server", idPrefix = "mech-",
    schemaVersion = Mechanic.SCHEMA_VERSION,
    tables = { "orders", "messages" },
    storefronts = "shops", storefrontNoun = "shop",
    events = { RESULT = Mechanic.Events.RESULT, NOTIFICATION = Mechanic.Events.NOTIFICATION },
    startingReputation = function() return settings().StartingReputation end,
    license = {
        item = Mechanic.Items.LICENSE, tokenField = "kipnMechToken",
        name = "Mechanic Business License -- ",
    },
    storefront = {
        capability = Mechanic.Capabilities.SHOP, label = "Mechanic Shop",
        permission = Mechanic.Permissions.OWNER,
    },
    flyer = {
        title = "Flyer -- ",
        fields = { "name", "proprietorAlias", "description", "services", "hours", "contact", "adText" },
        write = function(modData, shop, fields, revision)
            modData.kipnMechShopId = shop.id
            modData.kipnMechFlyerRevision = revision
            modData.kipnMechName = fields.name or shop.name
            modData.kipnMechProprietor = fields.proprietorAlias or shop.proprietorAlias
            modData.kipnMechDescription = fields.description or shop.description
            modData.kipnMechServices = fields.services or shop.services
            modData.kipnMechHours = fields.hours or shop.hours
            modData.kipnMechContact = fields.contact or shop.contact
            modData.kipnMechAdText = fields.adText or shop.adText
            return modData.kipnMechName
        end,
    },
})

local function state() return Career:State() end
local function makeId(prefix) return Career:MakeId(prefix) end
local function result(player, action, ok, code, message, extra) return Career:Result(player, action, ok, code, message, extra) end
local function notify(ownerKey, title, body, relatedId) return Career:Notify(ownerKey, title, body, relatedId) end
local function reputationFor(ownerKey) return Career:ReputationFor(ownerKey) end
local function adjustReputation(ownerKey, delta, reason) return Career:AdjustReputation(ownerKey, delta, reason) end
local function credit(ownerKey, amount, reason) return Career:Credit(ownerKey, amount, reason) end
local function settlePending(player) return Career:SettlePending(player) end
local function ownedShop(ownerKey) return Career:OwnedStorefront(ownerKey) end
local function shopForPoint(x, y, z) return Career:StorefrontAt(x, y, z) end
local function shopAtComputer(computerId, player) return Career:StorefrontAtComputer(computerId, player) end

-- Business -> consumer message channel (own list; also mirrored to the inbox).
local function publishMessage(recipientKey, message)
    local data = state()
    if not data or not recipientKey or type(message) ~= "table" then return false end
    data.messages[recipientKey] = data.messages[recipientKey] or {}
    local entry = {
        id = makeId("msg"), shopId = message.shopId,
        shopName = Shared.Trim(message.shopName, Mechanic.Defaults.SHOP_NAME_MAX),
        subject = Shared.Trim(message.subject, 80), body = Shared.Trim(message.body, 500),
        orderId = message.orderId, createdAt = nowHours(), unread = true,
    }
    local list = data.messages[recipientKey]
    list[#list + 1] = entry
    while #list > 30 do table.remove(list, 1) end
    local player = onlinePlayerByIdentity(recipientKey)
    if player then send(player, Mechanic.Events.MESSAGE, entry) end
    notify(recipientKey, (entry.shopName ~= "" and entry.shopName or "Mechanic shop") .. ": " .. entry.subject, entry.body, entry.orderId)
    return true
end

------------------------------------------------------------
-- CONTAINER RESOLUTION
------------------------------------------------------------

local function objectContainerFields(object)
    local fields = { type = "", sprite = "", name = "" }
    if not object then return fields end
    local container = type(object.getContainer) == "function" and object:getContainer() or nil
    if container and type(container.getType) == "function" then fields.type = tostring(container:getType() or "") end
    local sprite = type(object.getSprite) == "function" and object:getSprite() or nil
    if sprite and type(sprite.getName) == "function" then fields.sprite = tostring(sprite:getName() or "") end
    if type(object.getName) == "function" then fields.name = tostring(object:getName() or "") end
    return fields
end

local function containerKey(x, y, z, fields)
    return table.concat({
        math.floor(x), math.floor(y), math.floor(z or 0),
        fields.type ~= "" and fields.type or "?",
        fields.sprite ~= "" and fields.sprite or "?",
    }, ":")
end

local function resolveContainerObject(x, y, z, descriptor)
    if type(getCell) ~= "function" or not getCell() then return nil end
    local square = getCell():getGridSquare(math.floor(x), math.floor(y), math.floor(z or 0))
    if not square then return nil end
    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        if object and type(object.getContainer) == "function" and object:getContainer() then
            local fields = objectContainerFields(object)
            local key = containerKey(x, y, z, fields)
            if not descriptor
                or descriptor.key == key
                or ((descriptor.type == nil or descriptor.type == fields.type)
                    and (descriptor.sprite == nil or descriptor.sprite == fields.sprite))
            then
                return object, key, fields
            end
        end
    end
    return nil
end

------------------------------------------------------------
-- ORDER VIEWS
------------------------------------------------------------

local function countActiveOrders(ownerKey, role)
    local count = 0
    for _, order in pairs((state() or {}).orders or {}) do
        local matches = (role == "client" and order.clientKey == ownerKey)
            or (role == "shop" and order.shopKey == ownerKey)
        if matches and Mechanic.IsOrderActive(order.status) then count = count + 1 end
    end
    return count
end

local function orderVisibleToShop(order, ownerKey, shop)
    if not order or not shop then return false end
    if order.targetShopId ~= shop.id then return false end
    if order.status == Mechanic.Status.SUBMITTED then return true end
    return order.shopKey == ownerKey and (order.status == Mechanic.Status.ACCEPTED or order.status == Mechanic.Status.COMPLETED)
end

local function publicOrder(order)
    return {
        id = order.id, status = order.status, clientName = order.clientName,
        source = order.source or Mechanic.OrderSources.PLAYER,
        targetShopId = order.targetShopId, repairs = order.repairs, tier = order.tier,
        quote = order.quote, payout = order.payout, note = order.note,
        createdAt = order.createdAt, expiresAt = order.expiresAt,
        acceptedAt = order.acceptedAt, deadlineAt = order.deadlineAt, completedAt = order.completedAt,
    }
end

local function shopCard(shop)
    return {
        id = shop.id, name = shop.name, proprietorAlias = shop.proprietorAlias,
        description = shop.description, services = shop.services, hours = shop.hours,
        contact = shop.contact, adText = shop.adText,
    }
end

------------------------------------------------------------
-- SERVER-ASSIGNED WORK ORDERS
--
-- The career is server authoritative: a shop must have work to do whether or
-- not another player is online. The server posts its own walk-in customers to
-- every active shop, capped per shop and spaced by SystemOrderIntervalHours.
-- They run through the same accept -> complete path as a player's order; the
-- server pays on completion, since no client is there to approve.
------------------------------------------------------------

local function randomChoice(list)
    return list[randomInteger(1, #list)]
end

local function systemRepairs()
    local wanted = randomInteger(Mechanic.Defaults.SYSTEM_MIN_REPAIRS, Mechanic.Defaults.SYSTEM_MAX_REPAIRS)
    local pool, repairs = {}, {}
    for _, part in ipairs(Mechanic.SystemParts) do pool[#pool + 1] = part end
    for _ = 1, math.min(wanted, #pool) do
        local index = randomInteger(1, #pool)
        repairs[#repairs + 1] = { part = pool[index], quality = randomInteger(Mechanic.Defaults.QUALITY_MIN, Mechanic.Defaults.QUALITY_MAX) }
        table.remove(pool, index)
    end
    return repairs
end

local function createSystemOrder(shop)
    local data, config = state(), settings()
    if not data then return nil end
    local repairs = Mechanic.SanitizeRepairs(systemRepairs())
    if not repairs then return nil end
    local tier = Mechanic.TierOrder[randomInteger(1, #Mechanic.TierOrder)]
    local quotes = Mechanic.ComputeQuotes(repairs, config)
    local order = {
        id = makeId("order"), status = Mechanic.Status.SUBMITTED, source = Mechanic.OrderSources.SYSTEM,
        clientName = randomChoice(Mechanic.SystemClients), targetShopId = shop.id,
        repairs = repairs, tier = tier, quote = quotes, payout = Mechanic.TierPrice(quotes, tier),
        escrowState = "SYSTEM_FUNDED",
        note = "Walk-in customer. Payment is settled by the customer on completion.",
        createdAt = nowHours(), expiresAt = nowHours() + config.OrderListingHours,
    }
    data.orders[order.id] = order
    notify(shop.ownerKey, "Walk-in work order",
        order.clientName .. " needs " .. tostring(#repairs) .. " repair(s) (" .. tier .. ", offer " .. tostring(order.payout) .. ").", order.id)
    log("Info", "createSystemOrder shop=" .. tostring(shop.id) .. " order=" .. tostring(order.id))
    return order
end

local function generateSystemOrders()
    local data, config = state(), settings()
    if not data or not config.Enabled or config.MaxSystemOrdersPerShop <= 0 then return false end
    if nowHours() < (tonumber(data.meta.nextSystemOrderAt) or 0) then return false end
    data.meta.nextSystemOrderAt = nowHours() + config.SystemOrderIntervalHours
    local changed = false
    for _, shop in pairs(data.shops) do
        if shop.active ~= false then
            local open = 0
            for _, order in pairs(data.orders) do
                if order.source == Mechanic.OrderSources.SYSTEM and order.targetShopId == shop.id
                    and order.status == Mechanic.Status.SUBMITTED then open = open + 1 end
            end
            if open < config.MaxSystemOrdersPerShop and createSystemOrder(shop) then changed = true end
        end
    end
    if changed then save() end
    return changed
end

------------------------------------------------------------
-- EXPIRY
------------------------------------------------------------

local function expireOrders()
    local data = state()
    if not data then return false end
    local now = nowHours()
    local changed = false
    for _, order in pairs(data.orders) do
        if order.status == Mechanic.Status.SUBMITTED and order.expiresAt and now >= order.expiresAt then
            order.status = Mechanic.Status.EXPIRED
            if order.escrowState == "HELD" then
                credit(order.clientKey, order.payout, "expired unaccepted order")
                order.escrowState = "REFUNDED"
                notify(order.clientKey, "Work order expired", "No shop accepted your work order in time; your escrow was refunded.", order.id)
            end
            changed = true
        elseif order.status == Mechanic.Status.ACCEPTED and order.deadlineAt and now >= order.deadlineAt then
            order.status = Mechanic.Status.EXPIRED
            adjustReputation(order.shopKey, -settings().FailureRepLoss, "accepted order expired")
            if order.escrowState == "HELD" then
                credit(order.clientKey, order.payout, "shop missed deadline")
                order.escrowState = "REFUNDED"
                notify(order.clientKey, "Work order failed", "The shop missed the agreed completion window; your escrow was refunded.", order.id)
            end
            notify(order.shopKey, "Work order failed", "You missed the completion window on a work order and lost reputation.", order.id)
            changed = true
        end
    end
    if changed then save() end
    return changed
end

------------------------------------------------------------
-- SNAPSHOT (client-facing state for the Mechanic Services screen)
------------------------------------------------------------

local function snapshot(player)
    settlePending(player)
    expireOrders()
    local data = state()
    local ownerKey = identity(player)
    if not data or not ownerKey then return nil end
    local config = settings()
    local shop = ownedShop(ownerKey)
    local payload = {
        version = Mechanic.VERSION, enabled = config.Enabled,
        reputation = reputationFor(ownerKey), licensePrice = config.LicensePrice,
        currencyItemValue = config.CurrencyItemValue,
        tierHours = { fast = config.FastCompletionHours, regular = config.RegularCompletionHours, slow = config.SlowCompletionHours },
        shop = shop and {
            id = shop.id, name = shop.name, proprietorAlias = shop.proprietorAlias,
            description = shop.description, services = shop.services, hours = shop.hours,
            contact = shop.contact, adText = shop.adText, bounds = shop.bounds,
            containers = shop.containers or {}, anchor = shop.anchor,
        } or nil,
        licenses = {}, shops = {}, clientOrders = {},
        messages = data.messages[ownerKey] or {},
        notifications = Careers.Inbox(ownerKey),
        pendingCurrency = tonumber(data.pendingCurrency[ownerKey]) or 0,
        isAdmin = isAdmin(player),
    }
    for _, license in pairs(data.licenses) do
        if license.ownerKey == ownerKey and license.status == "ACTIVE" then payload.licenses[#payload.licenses + 1] = license end
    end
    for _, candidate in pairs(data.shops) do
        if candidate.active ~= false then payload.shops[#payload.shops + 1] = shopCard(candidate) end
    end
    for _, order in pairs(data.orders) do
        if order.clientKey == ownerKey then payload.clientOrders[#payload.clientOrders + 1] = publicOrder(order) end
    end
    return payload
end

local function handleSnapshot(player, args)
    local payload = snapshot(player)
    if not payload then return false, "STATE_UNAVAILABLE" end
    payload.requestId = args and args.requestId
    send(player, Mechanic.Events.SNAPSHOT, payload)
    return true
end

------------------------------------------------------------
-- SHOP PROFILE (owner-only, at a terminal inside the shop)
------------------------------------------------------------

local function shopProfilePayload(player, computerId)
    local ownerKey = identity(player)
    local shop = shopAtComputer(computerId, player)
    if not shop or shop.ownerKey ~= ownerKey then
        return { shop = nil, atShop = shop ~= nil }
    end
    local data = state()
    local payload = {
        atShop = true, reputation = reputationFor(ownerKey),
        pendingCurrency = tonumber(data.pendingCurrency[ownerKey]) or 0,
        currencyItemValue = settings().CurrencyItemValue,
        shop = {
            id = shop.id, name = shop.name, proprietorAlias = shop.proprietorAlias,
            description = shop.description, services = shop.services, hours = shop.hours,
            contact = shop.contact, adText = shop.adText, anchor = shop.anchor,
            bounds = shop.bounds, containers = shop.containers or {},
            flyerRevision = shop.flyerRevision,
        },
        orders = {},
    }
    for _, order in pairs(data.orders) do
        if orderVisibleToShop(order, ownerKey, shop) then
            payload.orders[#payload.orders + 1] = publicOrder(order)
        end
    end
    return payload
end

local function handleShopProfile(player, args)
    local payload = shopProfilePayload(player, args and args.computerId)
    payload.requestId = args and args.requestId
    send(player, Mechanic.Events.SHOP_PROFILE, payload)
    return true
end

------------------------------------------------------------
-- LICENSE / SHOP
------------------------------------------------------------

local function handleBuyLicense(player, args)
    local action = "buyLicense"
    if not settings().Enabled then result(player, action, false, "DISABLED", "The Mechanic profession is disabled.") return true end
    if not hasServicesAccess(args and args.computerId, player) then
        result(player, action, false, "SERVICES_ZONE_REQUIRED", "Use the nearby KIPN terminal inside a Career Services zone.") return true
    end
    if not identity(player) or not state() then return false, "STATE_UNAVAILABLE" end
    local tokenId, code, message = Career:IssueLicense(player, settings().LicensePrice)
    if not tokenId then result(player, action, false, code, message) return true end
    result(player, action, true, "LICENSE_ISSUED", "Your bearer Mechanic license was issued to your inventory.", { tokenId = tokenId })
    return true
end

local function handleStartShop(player, args)
    local action = "startShop"
    local ownerKey = identity(player)
    if ownedShop(ownerKey) then result(player, action, false, "SHOP_ALREADY_EXISTS", "You already operate an active mechanic shop.") return true end
    local license, entry = Career:FindLicense(player, args and args.tokenId)
    if not license then
        result(player, action, false, "VALID_LICENSE_REQUIRED", "A valid bearer Mechanic license must be in your inventory.") return true
    end
    local rect, code, message = Career:CheckSite(player)
    if not rect then result(player, action, false, code, message) return true end
    local shopId = makeId("shop")
    local shop = {
        id = shopId, ownerKey = ownerKey, ownerName = username(player),
        active = true, createdAt = nowHours(), bounds = rect,
        anchor = { x = player:getX(), y = player:getY(), z = player:getZ() },
        name = username(player) .. "'s Garage", proprietorAlias = username(player),
        description = "Independent mechanic shop.", services = "General repairs.",
        hours = "By appointment", contact = "Contact through KIPN.", adText = "Repairs done right.",
        containers = {}, flyerRevision = 0, distributedFlyerRevision = 0,
    }
    local opened
    opened, code, message = Career:OpenStorefront(player, license, entry, shop)
    if not opened then result(player, action, false, code, message) return true end
    result(player, action, true, "SHOP_STARTED", "Your mechanic shop is established. Open Mechanic Shop from a terminal here to assign containers and take work.", { shopId = shopId })
    return true
end

local function handleSaveShop(player, args)
    local action = "saveShop"
    local shop = ownedShop(identity(player))
    if not shop then result(player, action, false, "SHOP_REQUIRED", "You do not have an active shop.") return true end
    local fields = args and args.fields or {}
    shop.name = Shared.Trim(fields.name, Mechanic.Defaults.SHOP_NAME_MAX)
    shop.proprietorAlias = Shared.Trim(fields.proprietorAlias, Mechanic.Defaults.SHOP_NAME_MAX)
    shop.description = Shared.Trim(fields.description, Mechanic.Defaults.TEXT_MAX)
    shop.services = Shared.Trim(fields.services, Mechanic.Defaults.TEXT_MAX)
    shop.hours = Shared.Trim(fields.hours, 96)
    shop.contact = Shared.Trim(fields.contact, Mechanic.Defaults.TEXT_MAX)
    shop.adText = Shared.Trim(fields.adText, Mechanic.Defaults.TEXT_MAX)
    if shop.name == "" or shop.description == "" then result(player, action, false, "REQUIRED_FIELDS", "Shop name and description are required.") return true end
    shop.flyerRevision = (tonumber(shop.flyerRevision) or 0) + 1
    shop.updatedAt = nowHours()
    if not save() then result(player, action, false, "PERSISTENCE_FAILED", "Shop changes could not be saved.") return true end
    result(player, action, true, "SHOP_SAVED", "Shop details saved. The new flyer revision enters loot distribution after the next server restart.")
    return true
end

------------------------------------------------------------
-- CONTAINER TYPES
------------------------------------------------------------

local function handleSetContainerType(player, args)
    local action = "setContainerType"
    local shop = ownedShop(identity(player))
    if not shop then result(player, action, false, "SHOP_REQUIRED", "Only a shop owner can assign business containers.") return true end
    local kind = tostring(args and args.containerType or "")
    if not Mechanic.IsValidContainerType(kind) then result(player, action, false, "INVALID_CONTAINER_TYPE", "Choose Private, Public, or For Sale.") return true end
    local x, y, z = tonumber(args and args.x), tonumber(args and args.y), tonumber(args and args.z)
    if not x or not y then result(player, action, false, "NO_CONTAINER", "No container was targeted.") return true end
    if not pointInBounds(shop.bounds, x, y, z) then result(player, action, false, "OUTSIDE_SHOP", "That container is not inside your shop building.") return true end
    local distance = settings().ContainerInteractionDistance
    local dx, dy = player:getX() - x, player:getY() - y
    if dx * dx + dy * dy > (distance + 1) * (distance + 1) then result(player, action, false, "TOO_FAR", "Stand next to the container you want to assign.") return true end
    local object, key, fields = resolveContainerObject(x, y, z, args.descriptor)
    if not object then result(player, action, false, "CONTAINER_NOT_FOUND", "That container could not be resolved on the server.") return true end
    shop.containers = shop.containers or {}
    shop.containers[key] = {
        type = kind, x = math.floor(x), y = math.floor(y), z = math.floor(z or 0),
        containerType = fields.type, sprite = fields.sprite,
        label = Shared.Trim(args.label, 48), assignedAt = nowHours(),
    }
    if not save() then shop.containers[key] = nil result(player, action, false, "PERSISTENCE_FAILED", "The assignment could not be saved.") return true end
    result(player, action, true, "CONTAINER_ASSIGNED", "Container assigned as " .. kind .. ".", { key = key, containerType = kind })
    return true
end

local function handleClearContainerType(player, args)
    local action = "clearContainerType"
    local shop = ownedShop(identity(player))
    if not shop then result(player, action, false, "SHOP_REQUIRED", "Only a shop owner can change business containers.") return true end
    local x, y, z = tonumber(args and args.x), tonumber(args and args.y), tonumber(args and args.z)
    local _, key = resolveContainerObject(x or 0, y or 0, z or 0, args and args.descriptor)
    key = key or (args and args.key)
    if not key or not shop.containers or not shop.containers[key] then
        result(player, action, false, "NOT_ASSIGNED", "That container has no assignment.") return true
    end
    local previous = shop.containers[key]
    shop.containers[key] = nil
    if not save() then shop.containers[key] = previous result(player, action, false, "PERSISTENCE_FAILED", "The change could not be saved.") return true end
    result(player, action, true, "CONTAINER_CLEARED", "Container reset to Private (the default).")
    return true
end

------------------------------------------------------------
-- WORK ORDERS
------------------------------------------------------------

local function validateOrderRequest(args)
    local config = settings()
    if not config.Enabled then return nil, "CAREER_UNAVAILABLE", "Mechanic work orders are unavailable." end
    local repairs = Mechanic.SanitizeRepairs(args and args.repairs, config.MaxRepairsPerOrder)
    if not repairs then return nil, "INVALID_REPAIRS", "Add at least one repair (a part name; quality defaults to 100%)." end
    local tier = tostring(args and args.tier or Mechanic.Tiers.REGULAR)
    if not Mechanic.IsValidTier(tier) then tier = Mechanic.Tiers.REGULAR end
    local data = state()
    local targetShopId = Shared.Trim(args and args.targetShopId, 128)
    local shop = data and targetShopId ~= "" and data.shops[targetShopId] or nil
    if not shop or shop.active == false then return nil, "INVALID_SHOP", "Choose a mechanic shop to send the work order to." end
    return { config = config, repairs = repairs, tier = tier, shop = shop, quotes = Mechanic.ComputeQuotes(repairs, config) }
end

local function handleQuoteOrder(player, args)
    local action = "quoteOrder"
    local plan, code, message = validateOrderRequest(args)
    if not plan then result(player, action, false, code, message) return true end
    send(player, Mechanic.Events.QUOTE, {
        requestId = args and args.requestId, targetShopId = plan.shop.id,
        repairs = plan.repairs, quotes = plan.quotes,
        tierHours = { fast = plan.config.FastCompletionHours, regular = plan.config.RegularCompletionHours, slow = plan.config.SlowCompletionHours },
    })
    result(player, action, true, "QUOTE_READY", "Three quotes are ready. Pick a turnaround to send the order.")
    return true
end

local function handleSubmitOrder(player, args)
    local action = "submitOrder"
    local clientKey = identity(player)
    local data = state()
    local plan, code, message = validateOrderRequest(args)
    if not plan then result(player, action, false, code, message) return true end
    if countActiveOrders(clientKey, "client") >= plan.config.MaxActiveClientOrders then
        result(player, action, false, "CLIENT_ORDER_LIMIT", "You have reached your active work-order limit.") return true
    end
    if plan.shop.ownerKey == clientKey then result(player, action, false, "SELF_ORDER_BLOCKED", "You cannot send a work order to your own shop.") return true end
    local formEntry = player and collectItems(player:getInventory(), Mechanic.Items.WORK_ORDER, {})[1]
    if not formEntry then result(player, action, false, "WORK_ORDER_FORM_REQUIRED", "You need a Mechanic Work Order form. Craft one or take one from a shop's public container.") return true end
    local payout = Mechanic.TierPrice(plan.quotes, plan.tier)
    local paid, reason, receipt = Economy.Charge(player, payout)
    if not paid then result(player, action, false, reason, "Escrow payment failed: " .. tostring(reason)) return true end
    formEntry.container:Remove(formEntry.item)
    local order = {
        id = makeId("order"), status = Mechanic.Status.SUBMITTED,
        clientKey = clientKey, clientName = username(player), targetShopId = plan.shop.id,
        repairs = plan.repairs, tier = plan.tier, quote = plan.quotes, payout = payout,
        escrowState = "HELD", note = Shared.Trim(args and args.note, Mechanic.Defaults.TEXT_MAX),
        createdAt = nowHours(), expiresAt = nowHours() + plan.config.OrderListingHours,
    }
    data.orders[order.id] = order
    if not save() then
        data.orders[order.id] = nil
        pcall(function() formEntry.container:AddItem(formEntry.item) end)
        Economy.RefundReceipt(receipt)
        result(player, action, false, "PERSISTENCE_FAILED", "The work order could not be saved; escrow was refunded.")
        return true
    end
    notify(plan.shop.ownerKey, "New work order",
        username(player) .. " sent a " .. plan.tier .. " work order (" .. tostring(#plan.repairs) .. " repairs, offer " .. tostring(payout) .. ").", order.id)
    result(player, action, true, "ORDER_SUBMITTED", "Your work order is held in escrow until the shop completes it or it is refunded.", { orderId = order.id })
    return true
end

local function handleCancelOrder(player, args)
    local action = "cancelOrder"
    local clientKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.clientKey ~= clientKey then result(player, action, false, "ORDER_NOT_OWNED", "That work order is not yours.") return true end
    if order.status ~= Mechanic.Status.SUBMITTED then result(player, action, false, "ORDER_COMMITTED", "Only an unaccepted work order can be cancelled.") return true end
    local previousPending = tonumber(data.pendingCurrency[clientKey]) or 0
    order.status = Mechanic.Status.CANCELLED
    if order.escrowState == "HELD" then credit(clientKey, order.payout, "order cancelled") order.escrowState = "REFUNDED" end
    if not save() then
        order.status = Mechanic.Status.SUBMITTED
        order.escrowState = "HELD"
        data.pendingCurrency[clientKey] = previousPending > 0 and previousPending or nil
        result(player, action, false, "PERSISTENCE_FAILED", "The cancellation could not be saved.")
        return true
    end
    settlePending(player)
    result(player, action, true, "ORDER_CANCELLED", "Work order cancelled and escrow refunded.")
    return true
end

local function handleAcceptOrder(player, args)
    local action = "acceptOrder"
    local ownerKey = identity(player)
    local shop = ownedShop(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not shop then result(player, action, false, "SHOP_REQUIRED", "An active mechanic shop is required.") return true end
    if not order or not orderVisibleToShop(order, ownerKey, shop) or order.status ~= Mechanic.Status.SUBMITTED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That work order is no longer available.") return true
    end
    if countActiveOrders(ownerKey, "shop") >= settings().MaxActiveShopOrders then
        result(player, action, false, "SHOP_ORDER_LIMIT", "You have reached your active work-order limit.") return true
    end
    order.status = Mechanic.Status.ACCEPTED
    order.shopKey = ownerKey
    order.shopId = shop.id
    order.acceptedAt = nowHours()
    order.deadlineAt = nowHours() + Mechanic.TierHours(order.tier, settings())
    if not save() then
        order.status = Mechanic.Status.SUBMITTED
        order.shopKey = nil; order.shopId = nil; order.acceptedAt = nil; order.deadlineAt = nil
        result(player, action, false, "PERSISTENCE_FAILED", "The acceptance could not be saved.")
        return true
    end
    publishMessage(order.clientKey, {
        shopId = shop.id, shopName = shop.name, orderId = order.id,
        subject = "Work order accepted",
        body = "We have your vehicle and started the " .. tostring(order.tier) .. " repair. We will message you when it is ready for pickup.",
    })
    result(player, action, true, "ORDER_ACCEPTED", "Work order accepted. Complete the repairs, then press Work Order Complete.")
    return true
end

local function handleDeclineOrder(player, args)
    local action = "declineOrder"
    local ownerKey = identity(player)
    local shop = ownedShop(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not shop or not order or not orderVisibleToShop(order, ownerKey, shop) or order.status ~= Mechanic.Status.SUBMITTED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That work order cannot be declined.") return true
    end
    local previousPending = order.clientKey and (tonumber(data.pendingCurrency[order.clientKey]) or 0) or 0
    order.status = Mechanic.Status.DECLINED
    if order.escrowState == "HELD" then credit(order.clientKey, order.payout, "order declined") order.escrowState = "REFUNDED" end
    if not save() then
        order.status = Mechanic.Status.SUBMITTED
        order.escrowState = "HELD"
        if order.clientKey then data.pendingCurrency[order.clientKey] = previousPending > 0 and previousPending or nil end
        result(player, action, false, "PERSISTENCE_FAILED", "The decline could not be saved.")
        return true
    end
    notify(order.clientKey, "Work order declined", (shop.name or "The shop") .. " declined your work order; your escrow was refunded.", order.id)
    save()
    result(player, action, true, "ORDER_DECLINED", "Work order declined and escrow refunded to the client.")
    return true
end

-- Work Order Complete button in the shop's Mechanic Shop profile.
local function handleCompleteOrder(player, args)
    local action = "completeOrder"
    local ownerKey = identity(player)
    local shop = ownedShop(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not shop or not order or order.shopKey ~= ownerKey or order.status ~= Mechanic.Status.ACCEPTED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That accepted work order is unavailable.") return true
    end
    order.status = Mechanic.Status.COMPLETED
    order.completedAt = nowHours()
    if order.source == Mechanic.OrderSources.SYSTEM then
        -- A walk-in customer pays and leaves: no approval step exists. Their
        -- hidden mood (KIPNCareers_MechanicThreats.lua) can change what they
        -- pay: a tip, a haggle, or a refusal backed by their crew.
        local threats = KIPNCareers.MechanicThreats
        local plan = threats and threats.PlanCompletion(shop, order, player) or nil
        local amount = plan and plan.amount or order.payout
        local previousPending = tonumber(data.pendingCurrency[ownerKey]) or 0
        local previousReputation = reputationFor(ownerKey)
        if not credit(ownerKey, amount, "walk-in work order completed") then
            order.status = Mechanic.Status.ACCEPTED
            order.completedAt = nil
            result(player, action, false, "PAYOUT_FAILED", "Payment could not be queued; nothing changed.")
            return true
        end
        order.escrowState = plan and plan.escrowState or "RELEASED"
        order.paidAmount = amount
        order.status = Mechanic.Status.CLOSED
        order.closedAt = nowHours()
        local newRep = adjustReputation(ownerKey, settings().SuccessRepGain, "walk-in work order completed")
        if not save() then
            order.status = Mechanic.Status.ACCEPTED
            order.completedAt, order.closedAt, order.paidAmount = nil, nil, nil
            order.escrowState = "SYSTEM_FUNDED"
            data.pendingCurrency[ownerKey] = previousPending > 0 and previousPending or nil
            data.reputation[ownerKey] = previousReputation
            result(player, action, false, "PERSISTENCE_FAILED", "Completion could not be saved; nothing changed.")
            return true
        end
        if threats then
            threats.AddHeat(shop)
            if plan and plan.after then plan.after() end
        end
        settlePending(player)
        local message = plan and plan.message
            or (tostring(order.clientName) .. " paid " .. tostring(order.payout) .. " and drove away.")
        result(player, action, true, "ORDER_COMPLETED", message .. " Reputation: " .. tostring(newRep) .. ".")
        return true
    end
    if not save() then
        order.status = Mechanic.Status.ACCEPTED
        order.completedAt = nil
        result(player, action, false, "PERSISTENCE_FAILED", "Completion could not be saved.")
        return true
    end
    publishMessage(order.clientKey, {
        shopId = shop.id, shopName = shop.name, orderId = order.id,
        subject = "Your vehicle is ready",
        body = "Repairs are finished. Come to the shop, check the work against your order, and approve payment when satisfied.",
    })
    result(player, action, true, "ORDER_COMPLETED", "The client was notified that the work order is complete.")
    return true
end

-- Client approves after inspecting; escrow releases to the shop.
local function handleApproveOrder(player, args)
    local action = "approveOrder"
    local clientKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.clientKey ~= clientKey or order.status ~= Mechanic.Status.COMPLETED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That completed work order is unavailable.") return true
    end
    local shop = data.shops[order.shopId or ""]
    local previousPending = order.shopKey and (tonumber(data.pendingCurrency[order.shopKey]) or 0) or 0
    local previousReputation = order.shopKey and reputationFor(order.shopKey) or 0
    order.status = Mechanic.Status.CLOSED
    order.closedAt = nowHours()
    if order.escrowState == "HELD" then
        if not credit(order.shopKey, order.payout, "work order approved") then
            order.status = Mechanic.Status.COMPLETED
            order.closedAt = nil
            result(player, action, false, "PAYOUT_FAILED", "Payment could not be queued; nothing changed.")
            return true
        end
        order.escrowState = "RELEASED"
    end
    local newRep = order.shopKey and adjustReputation(order.shopKey, settings().SuccessRepGain, "work order approved") or nil
    if not save() then
        order.status = Mechanic.Status.COMPLETED
        order.closedAt = nil
        order.escrowState = "HELD"
        if order.shopKey then
            data.pendingCurrency[order.shopKey] = previousPending > 0 and previousPending or nil
            data.reputation[order.shopKey] = previousReputation
        end
        result(player, action, false, "PERSISTENCE_FAILED", "Approval could not be committed; nothing changed.")
        return true
    end
    local shopPlayer = order.shopKey and onlinePlayerByIdentity(order.shopKey) or nil
    if shopPlayer then settlePending(shopPlayer) end
    if shop and KIPNCareers.MechanicThreats then KIPNCareers.MechanicThreats.AddHeat(shop) end
    notify(order.shopKey, "Payment received", "A client approved a work order. Payment: " .. tostring(order.payout) .. ". Reputation: " .. tostring(newRep) .. ".", order.id)
    if shop then
        publishMessage(order.clientKey, {
            shopId = shop.id, shopName = shop.name, orderId = order.id,
            subject = "Thanks for your business", body = "Payment received. Your vehicle is all yours.",
        })
    end
    result(player, action, true, "ORDER_APPROVED", "Repairs approved and payment released to the shop.")
    return true
end

------------------------------------------------------------
-- SELF-PERPETUATING PUBLIC WORK-ORDER FORMS
------------------------------------------------------------

local function countServerForms(container, shopId)
    local total = 0
    for _, entry in ipairs(collectItems(container, Mechanic.Items.WORK_ORDER, {})) do
        local modData = entry.item:getModData()
        if modData.kipnMechServerForm and tostring(modData.kipnMechShopId or "") == tostring(shopId) then total = total + 1 end
    end
    return total
end

local function ensurePublicForm(shop, record)
    local object = resolveContainerObject(record.x, record.y, record.z, { type = record.containerType, sprite = record.sprite })
    if not object then return false end
    local container = object:getContainer()
    if not container then return false end
    if countServerForms(container, shop.id) >= 1 then return false end
    local item = container:AddItem(Mechanic.Items.WORK_ORDER)
    if not item then return false end
    local modData = item:getModData()
    modData.kipnMechServerForm = true
    modData.kipnMechShopId = shop.id
    modData.kipnMechName = shop.name
    if type(item.setName) == "function" then item:setName("Mechanic Work Order -- " .. tostring(shop.name)) end
    return true
end

local function refillPublicForms()
    local data = state()
    if not data then return false end
    local changed = false
    for _, shop in pairs(data.shops) do
        if shop.active ~= false then
            for _, record in pairs(shop.containers or {}) do
                if record.type == Mechanic.ContainerTypes.PUBLIC and ensurePublicForm(shop, record) then changed = true end
            end
        end
    end
    if changed then save() end
    return changed
end

------------------------------------------------------------
-- WORLD SCAN + TICKS
------------------------------------------------------------

local function scanSquare(square)
    if not initialized or not square then return end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    local shop = shopForPoint(x, y, z)
    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        if object then
            Career:DistributeFlyer(object)
            if shop and type(object.getContainer) == "function" and object:getContainer() then
                local fields = objectContainerFields(object)
                local record = shop.containers and shop.containers[containerKey(x, y, z, fields)]
                if record and record.type == Mechanic.ContainerTypes.PUBLIC and ensurePublicForm(shop, record) then save() end
            end
        end
    end
end

local lastFormRefillMs = 0
local function periodicTick()
    if not initialized then Service.Initialize() return end
    expireOrders()
    generateSystemOrders()
    local now = type(getTimestampMs) == "function" and getTimestampMs() or 0
    if now == 0 or now - lastFormRefillMs >= settings().PublicFormRefillMinutes * 60000 then
        lastFormRefillMs = now
        refillPublicForms()
    end
end

------------------------------------------------------------
-- BRIDGE  (internals for KIPNCareers_MechanicThreats.lua)
------------------------------------------------------------

Service.Bridge = {
    career = Career,
    state = state, save = save, settings = settings, nowHours = nowHours,
    notify = notify, publishMessage = publishMessage,
    reputationFor = reputationFor, adjustReputation = adjustReputation,
    credit = credit, settlePending = settlePending,
    onlinePlayerByIdentity = onlinePlayerByIdentity,
}

------------------------------------------------------------
-- ROUTER
------------------------------------------------------------

local handlers = {
    [Mechanic.Commands.SNAPSHOT] = handleSnapshot,
    [Mechanic.Commands.SHOP_PROFILE] = handleShopProfile,
    [Mechanic.Commands.BUY_LICENSE] = handleBuyLicense,
    [Mechanic.Commands.START_SHOP] = handleStartShop,
    [Mechanic.Commands.SAVE_SHOP] = handleSaveShop,
    [Mechanic.Commands.SET_CONTAINER_TYPE] = handleSetContainerType,
    [Mechanic.Commands.CLEAR_CONTAINER_TYPE] = handleClearContainerType,
    [Mechanic.Commands.QUOTE_ORDER] = handleQuoteOrder,
    [Mechanic.Commands.SUBMIT_ORDER] = handleSubmitOrder,
    [Mechanic.Commands.CANCEL_ORDER] = handleCancelOrder,
    [Mechanic.Commands.ACCEPT_ORDER] = handleAcceptOrder,
    [Mechanic.Commands.DECLINE_ORDER] = handleDeclineOrder,
    [Mechanic.Commands.COMPLETE_ORDER] = handleCompleteOrder,
    [Mechanic.Commands.APPROVE_ORDER] = handleApproveOrder,
}

local sessionCommands = {
    [Mechanic.Commands.BUY_LICENSE] = true,
    [Mechanic.Commands.START_SHOP] = true,
    [Mechanic.Commands.SAVE_SHOP] = true,
    [Mechanic.Commands.SET_CONTAINER_TYPE] = true,
    [Mechanic.Commands.CLEAR_CONTAINER_TYPE] = true,
    [Mechanic.Commands.SUBMIT_ORDER] = true,
    [Mechanic.Commands.CANCEL_ORDER] = true,
    [Mechanic.Commands.ACCEPT_ORDER] = true,
    [Mechanic.Commands.DECLINE_ORDER] = true,
    [Mechanic.Commands.COMPLETE_ORDER] = true,
    [Mechanic.Commands.APPROVE_ORDER] = true,
}

function Service.Initialize()
    if initialized then return true end
    if not Career:RegisterCommands(handlers, sessionCommands, "Log in to KIPN before using this Mechanic action.") then
        log("Warn", "KIPN server is not ready; Mechanic initialization deferred")
        return false
    end
    initialized = true
    Career:ActivateFlyerQueue()
    expireOrders()
    generateSystemOrders()
    refillPublicForms()
    log("Info", "Careers: Mechanic initialized version=" .. Mechanic.VERSION)
    return true
end

Careers.Bootstrap(Service.Initialize)
if Events.LoadGridsquare then Events.LoadGridsquare.Add(scanSquare) end
if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(periodicTick) end

return Service
