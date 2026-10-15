-- KIPNCareers_BlacksmithServer.lua
--
-- Server authority for the Blacksmith profession. A parallel career inside
-- the Careers Framework: its own data slice (GetData().careers.blacksmith), its own
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
-- Forge order line items are free-text (an item name + a target quality),
-- exactly like Mechanic's repair line items: this module prices, escrows,
-- and tracks reputation for the job; the forging itself is roleplayed
-- in-world using PZ's real blacksmithing skill.

if isClient() and not isServer() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_BlacksmithShared"

-- The career is built on the framework's career registration
-- (KIPNCareers_Careers.lua); an older framework does not have it.
if (KIPNCareers.Shared.API_VERSION or 1) < 2 then
    print("[KIPN CAREERS][Blacksmith] Careers Framework is out of date; the Blacksmith profession is off until it is updated.")
    return
end

require "KIPNCareers_Host"
require "KIPNCareers_Economy"
require "KIPNCareers_Storefronts"
require "KIPNCareers_Careers"

local Shared = KIPNCareers.Shared
local Blacksmith = KIPNCareers.Blacksmith
local Host = KIPNCareers.Host
local Economy = KIPNCareers.Economy
local Storefronts = KIPNCareers.Storefronts
local Careers = KIPNCareers.Careers
local Service = KIPNCareers.BlacksmithServer or {}
KIPNCareers.BlacksmithServer = Service

local initialized = false

local function log(level, message)
    Blacksmith.Log("Server", level, message)
end

local nowHours, randomInteger = Host.NowHours, Host.RandomInteger
local identity, username, isAdmin = Host.Identity, Host.Username, Host.IsAdmin
local send, save, onlinePlayerByIdentity = Host.Send, Host.Save, Host.OnlinePlayerByIdentity
local collectItems = Host.CollectItems
local pointInBounds = Storefronts.Contains
local hasServicesAccess = Careers.HasServicesAccess

local function settings()
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    local d = Blacksmith.Defaults
    return {
        Enabled = raw.BlacksmithEnabled ~= false,
        LicensePrice = Economy.Price(raw.BlacksmithLicensePrice or d.LICENSE_PRICE),
        StartingReputation = Shared.Clamp(raw.BlacksmithStartingReputation or d.STARTING_REPUTATION, 0, 100),
        FailureRepLoss = math.max(0, math.floor(tonumber(raw.BlacksmithFailureRepLoss) or d.FAILURE_REP_LOSS)),
        SuccessRepGain = math.max(0, math.floor(tonumber(raw.BlacksmithSuccessRepGain) or d.SUCCESS_REP_GAIN)),
        MaxActiveClientOrders = math.max(1, math.floor(tonumber(raw.BlacksmithMaxActiveClientOrders) or d.MAX_ACTIVE_CLIENT_ORDERS)),
        MaxActiveShopOrders = math.max(1, math.floor(tonumber(raw.BlacksmithMaxActiveShopOrders) or d.MAX_ACTIVE_SHOP_ORDERS)),
        OrderListingHours = math.max(1, tonumber(raw.BlacksmithOrderListingHours) or d.ORDER_LISTING_HOURS),
        SystemOrderIntervalHours = math.max(1, tonumber(raw.BlacksmithSystemOrderIntervalHours) or d.SYSTEM_ORDER_INTERVAL_HOURS),
        MaxSystemOrdersPerShop = math.max(0, math.floor(tonumber(raw.BlacksmithMaxSystemOrdersPerShop) or d.MAX_SYSTEM_ORDERS_PER_SHOP)),
        BaseItemPrice = math.max(1, math.floor(tonumber(raw.BlacksmithBaseItemPrice) or d.BASE_ITEM_PRICE)),
        QualityPremiumPercent = Shared.Clamp(raw.BlacksmithQualityPremiumPercent or d.QUALITY_PREMIUM_PERCENT, 0, 200),
        FastPriceMultiplier = math.max(0.1, tonumber(raw.BlacksmithFastPriceMultiplier) or d.FAST_PRICE_MULTIPLIER),
        RegularPriceMultiplier = math.max(0.1, tonumber(raw.BlacksmithRegularPriceMultiplier) or d.REGULAR_PRICE_MULTIPLIER),
        SlowPriceMultiplier = math.max(0.1, tonumber(raw.BlacksmithSlowPriceMultiplier) or d.SLOW_PRICE_MULTIPLIER),
        FastCompletionHours = math.max(1, math.floor(tonumber(raw.BlacksmithFastCompletionHours) or d.FAST_HOURS)),
        RegularCompletionHours = math.max(1, math.floor(tonumber(raw.BlacksmithRegularCompletionHours) or d.REGULAR_HOURS)),
        SlowCompletionHours = math.max(1, math.floor(tonumber(raw.BlacksmithSlowCompletionHours) or d.SLOW_HOURS)),
        MaxItemsPerOrder = math.max(1, math.floor(tonumber(raw.BlacksmithMaxItemsPerOrder) or d.MAX_ITEMS_PER_ORDER)),
        PublicFormRefillMinutes = math.max(1, math.floor(tonumber(raw.BlacksmithPublicFormRefillMinutes) or d.PUBLIC_FORM_REFILL_MINUTES)),
        ContainerInteractionDistance = math.max(1, math.floor(tonumber(raw.BlacksmithContainerInteractionDistance) or d.CONTAINER_DISTANCE)),
        CurrencyItemValue = Economy.ItemValue(),
    }
end

------------------------------------------------------------
-- CAREER
--
-- The framework keeps what every career keeps the same way: the data slice
-- (GetData().careers.blacksmith), ids, the shared inbox, reputation, money owed,
-- licenses, the storefront and its flyers. See KIPNCareers_Careers.lua.
------------------------------------------------------------

local Career = Careers.Register(Blacksmith.CAREER_ID, {
    label = "Blacksmith", logScope = "Blacksmith.Server", idPrefix = "bsmith-",
    schemaVersion = Blacksmith.SCHEMA_VERSION,
    tables = { "orders", "messages" },
    storefronts = "shops", storefrontNoun = "shop",
    events = { RESULT = Blacksmith.Events.RESULT, NOTIFICATION = Blacksmith.Events.NOTIFICATION },
    startingReputation = function() return settings().StartingReputation end,
    license = {
        item = Blacksmith.Items.LICENSE, tokenField = "kipnBSmithToken",
        name = "Blacksmith Business License -- ",
    },
    storefront = {
        capability = Blacksmith.Capabilities.SHOP, label = "Blacksmith Shop",
        permission = Blacksmith.Permissions.OWNER,
    },
    flyer = {
        title = "Flyer -- ",
        fields = { "name", "proprietorAlias", "description", "services", "hours", "contact", "adText" },
        write = function(modData, shop, fields, revision)
            modData.kipnBSmithShopId = shop.id
            modData.kipnBSmithFlyerRevision = revision
            modData.kipnBSmithName = fields.name or shop.name
            modData.kipnBSmithProprietor = fields.proprietorAlias or shop.proprietorAlias
            modData.kipnBSmithDescription = fields.description or shop.description
            modData.kipnBSmithServices = fields.services or shop.services
            modData.kipnBSmithHours = fields.hours or shop.hours
            modData.kipnBSmithContact = fields.contact or shop.contact
            modData.kipnBSmithAdText = fields.adText or shop.adText
            return modData.kipnBSmithName
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
        shopName = Shared.Trim(message.shopName, Blacksmith.Defaults.SHOP_NAME_MAX),
        subject = Shared.Trim(message.subject, 80), body = Shared.Trim(message.body, 500),
        orderId = message.orderId, createdAt = nowHours(), unread = true,
    }
    local list = data.messages[recipientKey]
    list[#list + 1] = entry
    while #list > 30 do table.remove(list, 1) end
    local player = onlinePlayerByIdentity(recipientKey)
    if player then send(player, Blacksmith.Events.MESSAGE, entry) end
    notify(recipientKey, (entry.shopName ~= "" and entry.shopName or "Blacksmith shop") .. ": " .. entry.subject, entry.body, entry.orderId)
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
        if matches and Blacksmith.IsOrderActive(order.status) then count = count + 1 end
    end
    return count
end

local function orderVisibleToShop(order, ownerKey, shop)
    if not order or not shop then return false end
    if order.targetShopId ~= shop.id then return false end
    if order.status == Blacksmith.Status.SUBMITTED then return true end
    return order.shopKey == ownerKey and (order.status == Blacksmith.Status.ACCEPTED or order.status == Blacksmith.Status.COMPLETED)
end

local function publicOrder(order)
    return {
        id = order.id, status = order.status, clientName = order.clientName,
        source = order.source or Blacksmith.OrderSources.PLAYER,
        targetShopId = order.targetShopId, forgeItems = order.forgeItems, tier = order.tier,
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
-- SERVER-ASSIGNED FORGE ORDERS
--
-- The career is server authoritative: a forge must have work whether or not
-- another player is online. The server posts its own walk-in customers to
-- every active shop, capped per shop and spaced by SystemOrderIntervalHours.
-- They run through the same accept -> complete path as a player's order; the
-- server pays on completion, since no client is there to approve.
------------------------------------------------------------

local function randomChoice(list)
    return list[randomInteger(1, #list)]
end

local function systemForgeItems()
    local wanted = randomInteger(Blacksmith.Defaults.SYSTEM_MIN_ITEMS, Blacksmith.Defaults.SYSTEM_MAX_ITEMS)
    local pool, items = {}, {}
    for _, name in ipairs(Blacksmith.SystemItems) do pool[#pool + 1] = name end
    for _ = 1, math.min(wanted, #pool) do
        local index = randomInteger(1, #pool)
        items[#items + 1] = {
            itemName = pool[index],
            quantity = randomInteger(Blacksmith.Defaults.QUANTITY_MIN, Blacksmith.Defaults.QUANTITY_MAX),
            quality = randomInteger(Blacksmith.Defaults.QUALITY_MIN, Blacksmith.Defaults.QUALITY_MAX),
        }
        table.remove(pool, index)
    end
    return items
end

local function createSystemOrder(shop)
    local data, config = state(), settings()
    if not data then return nil end
    local items = Blacksmith.SanitizeForgeItems(systemForgeItems())
    if not items then return nil end
    local tier = Blacksmith.TierOrder[randomInteger(1, #Blacksmith.TierOrder)]
    local quotes = Blacksmith.ComputeQuotes(items, config)
    local order = {
        id = makeId("order"), status = Blacksmith.Status.SUBMITTED, source = Blacksmith.OrderSources.SYSTEM,
        clientName = randomChoice(Blacksmith.SystemClients), targetShopId = shop.id,
        forgeItems = items, tier = tier, quote = quotes, payout = Blacksmith.TierPrice(quotes, tier),
        escrowState = "SYSTEM_FUNDED",
        note = "Walk-in customer. Payment is settled by the customer on completion.",
        createdAt = nowHours(), expiresAt = nowHours() + config.OrderListingHours,
    }
    data.orders[order.id] = order
    notify(shop.ownerKey, "Walk-in forge order",
        order.clientName .. " wants " .. tostring(#items) .. " item(s) forged (" .. tier .. ", offer " .. tostring(order.payout) .. ").", order.id)
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
                if order.source == Blacksmith.OrderSources.SYSTEM and order.targetShopId == shop.id
                    and order.status == Blacksmith.Status.SUBMITTED then open = open + 1 end
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
        if order.status == Blacksmith.Status.SUBMITTED and order.expiresAt and now >= order.expiresAt then
            order.status = Blacksmith.Status.EXPIRED
            if order.escrowState == "HELD" then
                credit(order.clientKey, order.payout, "expired unaccepted order")
                order.escrowState = "REFUNDED"
                notify(order.clientKey, "Forge order expired", "No shop accepted your forge order in time; your escrow was refunded.", order.id)
            end
            changed = true
        elseif order.status == Blacksmith.Status.ACCEPTED and order.deadlineAt and now >= order.deadlineAt then
            order.status = Blacksmith.Status.EXPIRED
            adjustReputation(order.shopKey, -settings().FailureRepLoss, "accepted order expired")
            if order.escrowState == "HELD" then
                credit(order.clientKey, order.payout, "shop missed deadline")
                order.escrowState = "REFUNDED"
                notify(order.clientKey, "Forge order failed", "The shop missed the agreed completion window; your escrow was refunded.", order.id)
            end
            notify(order.shopKey, "Forge order failed", "You missed the completion window on a forge order and lost reputation.", order.id)
            changed = true
        end
    end
    if changed then save() end
    return changed
end

------------------------------------------------------------
-- SNAPSHOT (client-facing state for the Blacksmith Services screen)
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
        version = Blacksmith.VERSION, enabled = config.Enabled,
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
    send(player, Blacksmith.Events.SNAPSHOT, payload)
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
    send(player, Blacksmith.Events.SHOP_PROFILE, payload)
    return true
end

------------------------------------------------------------
-- LICENSE / SHOP
------------------------------------------------------------

local function handleBuyLicense(player, args)
    local action = "buyLicense"
    if not settings().Enabled then result(player, action, false, "DISABLED", "The Blacksmith profession is disabled.") return true end
    if not hasServicesAccess(args and args.computerId, player) then
        result(player, action, false, "SERVICES_ZONE_REQUIRED", "Use the nearby KIPN terminal inside a Career Services zone.") return true
    end
    if not identity(player) or not state() then return false, "STATE_UNAVAILABLE" end
    local tokenId, code, message = Career:IssueLicense(player, settings().LicensePrice)
    if not tokenId then result(player, action, false, code, message) return true end
    result(player, action, true, "LICENSE_ISSUED", "Your bearer Blacksmith license was issued to your inventory.", { tokenId = tokenId })
    return true
end

local function handleStartShop(player, args)
    local action = "startShop"
    local ownerKey = identity(player)
    if ownedShop(ownerKey) then result(player, action, false, "SHOP_ALREADY_EXISTS", "You already operate an active blacksmith shop.") return true end
    local license, entry = Career:FindLicense(player, args and args.tokenId)
    if not license then
        result(player, action, false, "VALID_LICENSE_REQUIRED", "A valid bearer Blacksmith license must be in your inventory.") return true
    end
    local rect, code, message = Career:CheckSite(player)
    if not rect then result(player, action, false, code, message) return true end
    local shopId = makeId("shop")
    local shop = {
        id = shopId, ownerKey = ownerKey, ownerName = username(player),
        active = true, createdAt = nowHours(), bounds = rect,
        anchor = { x = player:getX(), y = player:getY(), z = player:getZ() },
        name = username(player) .. "'s Forge", proprietorAlias = username(player),
        description = "Independent blacksmith shop.", services = "Custom forging.",
        hours = "By appointment", contact = "Contact through KIPN.", adText = "Forged to order.",
        containers = {}, flyerRevision = 0, distributedFlyerRevision = 0,
    }
    local opened
    opened, code, message = Career:OpenStorefront(player, license, entry, shop)
    if not opened then result(player, action, false, code, message) return true end
    result(player, action, true, "SHOP_STARTED", "Your blacksmith shop is established. Open Blacksmith Shop from a terminal here to assign containers and take work.", { shopId = shopId })
    return true
end

local function handleSaveShop(player, args)
    local action = "saveShop"
    local shop = ownedShop(identity(player))
    if not shop then result(player, action, false, "SHOP_REQUIRED", "You do not have an active shop.") return true end
    local fields = args and args.fields or {}
    shop.name = Shared.Trim(fields.name, Blacksmith.Defaults.SHOP_NAME_MAX)
    shop.proprietorAlias = Shared.Trim(fields.proprietorAlias, Blacksmith.Defaults.SHOP_NAME_MAX)
    shop.description = Shared.Trim(fields.description, Blacksmith.Defaults.TEXT_MAX)
    shop.services = Shared.Trim(fields.services, Blacksmith.Defaults.TEXT_MAX)
    shop.hours = Shared.Trim(fields.hours, 96)
    shop.contact = Shared.Trim(fields.contact, Blacksmith.Defaults.TEXT_MAX)
    shop.adText = Shared.Trim(fields.adText, Blacksmith.Defaults.TEXT_MAX)
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
    if not Blacksmith.IsValidContainerType(kind) then result(player, action, false, "INVALID_CONTAINER_TYPE", "Choose Private, Public, or For Sale.") return true end
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
    if not config.Enabled then return nil, "CAREER_UNAVAILABLE", "Blacksmith forge orders are unavailable." end
    local items = Blacksmith.SanitizeForgeItems(args and args.items, config.MaxItemsPerOrder)
    if not items then return nil, "INVALID_ITEMS", "Add at least one item to forge (a name; quality defaults to 100%)." end
    local tier = tostring(args and args.tier or Blacksmith.Tiers.REGULAR)
    if not Blacksmith.IsValidTier(tier) then tier = Blacksmith.Tiers.REGULAR end
    local data = state()
    local targetShopId = Shared.Trim(args and args.targetShopId, 128)
    local shop = data and targetShopId ~= "" and data.shops[targetShopId] or nil
    if not shop or shop.active == false then return nil, "INVALID_SHOP", "Choose a blacksmith shop to send the work order to." end
    return { config = config, items = items, tier = tier, shop = shop, quotes = Blacksmith.ComputeQuotes(items, config) }
end

local function handleQuoteOrder(player, args)
    local action = "quoteOrder"
    local plan, code, message = validateOrderRequest(args)
    if not plan then result(player, action, false, code, message) return true end
    send(player, Blacksmith.Events.QUOTE, {
        requestId = args and args.requestId, targetShopId = plan.shop.id,
        items = plan.items, quotes = plan.quotes,
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
    local formEntry = player and collectItems(player:getInventory(), Blacksmith.Items.WORK_ORDER, {})[1]
    if not formEntry then result(player, action, false, "WORK_ORDER_FORM_REQUIRED", "You need a Forge Order form. Craft one or take one from a shop's public container.") return true end
    local payout = Blacksmith.TierPrice(plan.quotes, plan.tier)
    local paid, reason, receipt = Economy.Charge(player, payout)
    if not paid then result(player, action, false, reason, "Escrow payment failed: " .. tostring(reason)) return true end
    formEntry.container:Remove(formEntry.item)
    local order = {
        id = makeId("order"), status = Blacksmith.Status.SUBMITTED,
        clientKey = clientKey, clientName = username(player), targetShopId = plan.shop.id,
        forgeItems = plan.items, tier = plan.tier, quote = plan.quotes, payout = payout,
        escrowState = "HELD", note = Shared.Trim(args and args.note, Blacksmith.Defaults.TEXT_MAX),
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
    notify(plan.shop.ownerKey, "New forge order",
        username(player) .. " sent a " .. plan.tier .. " forge order (" .. tostring(#plan.items) .. " items, offer " .. tostring(payout) .. ").", order.id)
    result(player, action, true, "ORDER_SUBMITTED", "Your forge order is held in escrow until the shop completes it or it is refunded.", { orderId = order.id })
    return true
end

local function handleCancelOrder(player, args)
    local action = "cancelOrder"
    local clientKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.clientKey ~= clientKey then result(player, action, false, "ORDER_NOT_OWNED", "That work order is not yours.") return true end
    if order.status ~= Blacksmith.Status.SUBMITTED then result(player, action, false, "ORDER_COMMITTED", "Only an unaccepted work order can be cancelled.") return true end
    local previousPending = tonumber(data.pendingCurrency[clientKey]) or 0
    order.status = Blacksmith.Status.CANCELLED
    if order.escrowState == "HELD" then credit(clientKey, order.payout, "order cancelled") order.escrowState = "REFUNDED" end
    if not save() then
        order.status = Blacksmith.Status.SUBMITTED
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
    if not shop then result(player, action, false, "SHOP_REQUIRED", "An active blacksmith shop is required.") return true end
    if not order or not orderVisibleToShop(order, ownerKey, shop) or order.status ~= Blacksmith.Status.SUBMITTED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That work order is no longer available.") return true
    end
    if countActiveOrders(ownerKey, "shop") >= settings().MaxActiveShopOrders then
        result(player, action, false, "SHOP_ORDER_LIMIT", "You have reached your active work-order limit.") return true
    end
    order.status = Blacksmith.Status.ACCEPTED
    order.shopKey = ownerKey
    order.shopId = shop.id
    order.acceptedAt = nowHours()
    order.deadlineAt = nowHours() + Blacksmith.TierHours(order.tier, settings())
    if not save() then
        order.status = Blacksmith.Status.SUBMITTED
        order.shopKey = nil; order.shopId = nil; order.acceptedAt = nil; order.deadlineAt = nil
        result(player, action, false, "PERSISTENCE_FAILED", "The acceptance could not be saved.")
        return true
    end
    publishMessage(order.clientKey, {
        shopId = shop.id, shopName = shop.name, orderId = order.id,
        subject = "Forge order accepted",
        body = "We started forging your " .. tostring(order.tier) .. " order. We will message you when it is ready for pickup.",
    })
    result(player, action, true, "ORDER_ACCEPTED", "Forge order accepted. Finish the work, then press Work Order Complete.")
    return true
end

local function handleDeclineOrder(player, args)
    local action = "declineOrder"
    local ownerKey = identity(player)
    local shop = ownedShop(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not shop or not order or not orderVisibleToShop(order, ownerKey, shop) or order.status ~= Blacksmith.Status.SUBMITTED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That work order cannot be declined.") return true
    end
    local previousPending = order.clientKey and (tonumber(data.pendingCurrency[order.clientKey]) or 0) or 0
    order.status = Blacksmith.Status.DECLINED
    if order.escrowState == "HELD" then credit(order.clientKey, order.payout, "order declined") order.escrowState = "REFUNDED" end
    if not save() then
        order.status = Blacksmith.Status.SUBMITTED
        order.escrowState = "HELD"
        if order.clientKey then data.pendingCurrency[order.clientKey] = previousPending > 0 and previousPending or nil end
        result(player, action, false, "PERSISTENCE_FAILED", "The decline could not be saved.")
        return true
    end
    notify(order.clientKey, "Forge order declined", (shop.name or "The shop") .. " declined your forge order; your escrow was refunded.", order.id)
    save()
    result(player, action, true, "ORDER_DECLINED", "Forge order declined and escrow refunded to the client.")
    return true
end

-- Work Order Complete button in the shop's Blacksmith Shop profile.
local function handleCompleteOrder(player, args)
    local action = "completeOrder"
    local ownerKey = identity(player)
    local shop = ownedShop(ownerKey)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not shop or not order or order.shopKey ~= ownerKey or order.status ~= Blacksmith.Status.ACCEPTED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That accepted work order is unavailable.") return true
    end
    order.status = Blacksmith.Status.COMPLETED
    order.completedAt = nowHours()
    if order.source == Blacksmith.OrderSources.SYSTEM then
        -- A walk-in customer pays and leaves: no approval step exists.
        local previousPending = tonumber(data.pendingCurrency[ownerKey]) or 0
        local previousReputation = reputationFor(ownerKey)
        if not credit(ownerKey, order.payout, "walk-in forge order completed") then
            order.status = Blacksmith.Status.ACCEPTED
            order.completedAt = nil
            result(player, action, false, "PAYOUT_FAILED", "Payment could not be queued; nothing changed.")
            return true
        end
        order.escrowState = "RELEASED"
        order.status = Blacksmith.Status.CLOSED
        order.closedAt = nowHours()
        local newRep = adjustReputation(ownerKey, settings().SuccessRepGain, "walk-in forge order completed")
        if not save() then
            order.status = Blacksmith.Status.ACCEPTED
            order.completedAt, order.closedAt = nil, nil
            order.escrowState = "SYSTEM_FUNDED"
            data.pendingCurrency[ownerKey] = previousPending > 0 and previousPending or nil
            data.reputation[ownerKey] = previousReputation
            result(player, action, false, "PERSISTENCE_FAILED", "Completion could not be saved; nothing changed.")
            return true
        end
        settlePending(player)
        local threats = KIPNCareers.BlacksmithThreats
        if threats then
            threats.AddHeat(shop)
            threats.OnWalkInPickup(shop, order, player)
        end
        result(player, action, true, "ORDER_COMPLETED", tostring(order.clientName)
            .. " paid " .. tostring(order.payout) .. " and took the work. Reputation: " .. tostring(newRep) .. ".")
        return true
    end
    if not save() then
        order.status = Blacksmith.Status.ACCEPTED
        order.completedAt = nil
        result(player, action, false, "PERSISTENCE_FAILED", "Completion could not be saved.")
        return true
    end
    publishMessage(order.clientKey, {
        shopId = shop.id, shopName = shop.name, orderId = order.id,
        subject = "Your forge order is ready",
        body = "Your order is finished. Come to the shop, inspect the finished piece, and approve payment when satisfied.",
    })
    result(player, action, true, "ORDER_COMPLETED", "The client was notified that the forge order is complete.")
    return true
end

-- Client approves after inspecting; escrow releases to the shop.
local function handleApproveOrder(player, args)
    local action = "approveOrder"
    local clientKey = identity(player)
    local data = state()
    local order = data and data.orders[tostring(args and args.orderId or "")]
    if not order or order.clientKey ~= clientKey or order.status ~= Blacksmith.Status.COMPLETED then
        result(player, action, false, "ORDER_UNAVAILABLE", "That completed work order is unavailable.") return true
    end
    local shop = data.shops[order.shopId or ""]
    local previousPending = order.shopKey and (tonumber(data.pendingCurrency[order.shopKey]) or 0) or 0
    local previousReputation = order.shopKey and reputationFor(order.shopKey) or 0
    order.status = Blacksmith.Status.CLOSED
    order.closedAt = nowHours()
    if order.escrowState == "HELD" then
        if not credit(order.shopKey, order.payout, "work order approved") then
            order.status = Blacksmith.Status.COMPLETED
            order.closedAt = nil
            result(player, action, false, "PAYOUT_FAILED", "Payment could not be queued; nothing changed.")
            return true
        end
        order.escrowState = "RELEASED"
    end
    local newRep = order.shopKey and adjustReputation(order.shopKey, settings().SuccessRepGain, "work order approved") or nil
    if not save() then
        order.status = Blacksmith.Status.COMPLETED
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
    local threats = KIPNCareers.BlacksmithThreats
    if shop and threats then
        threats.AddHeat(shop)
        threats.OnPlayerPickup(shop, order, player)
    end
    notify(order.shopKey, "Payment received", "A client approved a forge order. Payment: " .. tostring(order.payout) .. ". Reputation: " .. tostring(newRep) .. ".", order.id)
    if shop then
        publishMessage(order.clientKey, {
            shopId = shop.id, shopName = shop.name, orderId = order.id,
            subject = "Thanks for your business", body = "Payment received. Enjoy your new piece.",
        })
    end
    result(player, action, true, "ORDER_APPROVED", "Forge order approved and payment released to the shop.")
    return true
end

------------------------------------------------------------
-- SELF-PERPETUATING PUBLIC WORK-ORDER FORMS
------------------------------------------------------------

local function countServerForms(container, shopId)
    local total = 0
    for _, entry in ipairs(collectItems(container, Blacksmith.Items.WORK_ORDER, {})) do
        local modData = entry.item:getModData()
        if modData.kipnBSmithServerForm and tostring(modData.kipnBSmithShopId or "") == tostring(shopId) then total = total + 1 end
    end
    return total
end

local function ensurePublicForm(shop, record)
    local object = resolveContainerObject(record.x, record.y, record.z, { type = record.containerType, sprite = record.sprite })
    if not object then return false end
    local container = object:getContainer()
    if not container then return false end
    if countServerForms(container, shop.id) >= 1 then return false end
    local item = container:AddItem(Blacksmith.Items.WORK_ORDER)
    if not item then return false end
    local modData = item:getModData()
    modData.kipnBSmithServerForm = true
    modData.kipnBSmithShopId = shop.id
    modData.kipnBSmithName = shop.name
    if type(item.setName) == "function" then item:setName("Forge Order -- " .. tostring(shop.name)) end
    return true
end

local function refillPublicForms()
    local data = state()
    if not data then return false end
    local changed = false
    for _, shop in pairs(data.shops) do
        if shop.active ~= false then
            for _, record in pairs(shop.containers or {}) do
                if record.type == Blacksmith.ContainerTypes.PUBLIC and ensurePublicForm(shop, record) then changed = true end
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
                if record and record.type == Blacksmith.ContainerTypes.PUBLIC and ensurePublicForm(shop, record) then save() end
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
-- BRIDGE  (internals for KIPNCareers_BlacksmithThreats.lua)
------------------------------------------------------------

Service.Bridge = {
    career = Career,
    state = state, save = save, settings = settings, nowHours = nowHours,
    notify = notify, reputationFor = reputationFor, adjustReputation = adjustReputation,
    onlinePlayerByIdentity = onlinePlayerByIdentity,
}

------------------------------------------------------------
-- ROUTER
------------------------------------------------------------

local handlers = {
    [Blacksmith.Commands.SNAPSHOT] = handleSnapshot,
    [Blacksmith.Commands.SHOP_PROFILE] = handleShopProfile,
    [Blacksmith.Commands.BUY_LICENSE] = handleBuyLicense,
    [Blacksmith.Commands.START_SHOP] = handleStartShop,
    [Blacksmith.Commands.SAVE_SHOP] = handleSaveShop,
    [Blacksmith.Commands.SET_CONTAINER_TYPE] = handleSetContainerType,
    [Blacksmith.Commands.CLEAR_CONTAINER_TYPE] = handleClearContainerType,
    [Blacksmith.Commands.QUOTE_ORDER] = handleQuoteOrder,
    [Blacksmith.Commands.SUBMIT_ORDER] = handleSubmitOrder,
    [Blacksmith.Commands.CANCEL_ORDER] = handleCancelOrder,
    [Blacksmith.Commands.ACCEPT_ORDER] = handleAcceptOrder,
    [Blacksmith.Commands.DECLINE_ORDER] = handleDeclineOrder,
    [Blacksmith.Commands.COMPLETE_ORDER] = handleCompleteOrder,
    [Blacksmith.Commands.APPROVE_ORDER] = handleApproveOrder,
}

local sessionCommands = {
    [Blacksmith.Commands.BUY_LICENSE] = true,
    [Blacksmith.Commands.START_SHOP] = true,
    [Blacksmith.Commands.SAVE_SHOP] = true,
    [Blacksmith.Commands.SET_CONTAINER_TYPE] = true,
    [Blacksmith.Commands.CLEAR_CONTAINER_TYPE] = true,
    [Blacksmith.Commands.SUBMIT_ORDER] = true,
    [Blacksmith.Commands.CANCEL_ORDER] = true,
    [Blacksmith.Commands.ACCEPT_ORDER] = true,
    [Blacksmith.Commands.DECLINE_ORDER] = true,
    [Blacksmith.Commands.COMPLETE_ORDER] = true,
    [Blacksmith.Commands.APPROVE_ORDER] = true,
}

function Service.Initialize()
    if initialized then return true end
    if not Career:RegisterCommands(handlers, sessionCommands, "Log in to KIPN before using this Blacksmith action.") then
        log("Warn", "KIPN server is not ready; Blacksmith initialization deferred")
        return false
    end
    initialized = true
    Career:ActivateFlyerQueue()
    expireOrders()
    generateSystemOrders()
    refillPublicForms()
    log("Info", "Careers: Blacksmith initialized version=" .. Blacksmith.VERSION)
    return true
end

Careers.Bootstrap(Service.Initialize)
if Events.LoadGridsquare then Events.LoadGridsquare.Add(scanSquare) end
if Events.EveryTenMinutes then Events.EveryTenMinutes.Add(periodicTick) end

return Service
