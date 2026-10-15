-- KIPN_MarketplaceService.lua
--
-- Server-authoritative service for KIPN's internal admin-supplied
-- marketplace, PO Box escrow, and optional external economy ledgers.
--
-- The internal catalog is persisted and priced here. External
-- provider catalogs remain read-only unless they explicitly hand a
-- settled purchase to QueueExternalDelivery().
--
--   PLAYER
--      |
--      v
--   PURCHASE_MARKETPLACE_ITEM  (legacy client checkout command;
--      |                        rejected unless the provider explicitly
--      |                        supports authoritative KIPN escrow checkout)
--      v
--   Provider-native purchase/settlement
--      |
--      v
--   MarketplaceService.QueueExternalDelivery(...)
--      |                        (explicit provider handoff; KIPN never
--      |                         monkeypatches ItemContainer:AddItem)
--      v
--   queue a parcel for the player's PO Box
--      |
--      v
--   MARKETPLACE_PURCHASE_RESULT (KIPN server -> client)
--
-- Parcels are collected later via GET_PARCELS / COLLECT_PARCEL,
-- handled here and surfaced by KIPN_PostalServices.lua. This is
-- deliberately a virtual queue, not a physical world container -
-- KIPN's PO Box records (see KIPN_ClaimService.lua's PO_BOX claim
-- type) carry no world coordinates today, and a provider mod's own
-- "deliver to a physical shop box" purchase pathway has no way to
-- target an arbitrary KIPN PO Box anyway (see the adapter file for
-- the full reasoning).
--
-- Responsibilities:
--   * Own the marketplace ledger adapter registry.
--   * Resolve the admin-selected provider from sandbox config.
--   * Validate and execute PURCHASE_MARKETPLACE_ITEM.
--   * Own parcel persistence (queue / list / collect).
--
-- This module does NOT:
--   * know any provider's catalog (that lives client-side, in that
--     provider's own already-synced cache; see the adapter files)
--   * validate catalog price against the provider's own database -
--     no inspected provider mod exposes a server-side catalog
--     lookup API, so KIPN trusts the client-reported price/currency
--     snapshot the same way it already trusts anything else a
--     client-driven PZ mod UI reports. A provider that DOES expose
--     a server-side price lookup should have its ledger adapter
--     re-validate against it before calling deduct().
--   * spawn a physical PO Box container in the world

if isClient() and not isServer() then
    return
end

require "KIPN_Shared"
require "KIPN_PostOfficeShared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

KIPN.Server.MarketplaceService =
    KIPN.Server.MarketplaceService or {}

local MarketplaceService =
    KIPN.Server.MarketplaceService

-- Forward declaration: external escrow intake is defined before the
-- ledger/provider-resolution section but must still fail closed when
-- a non-selected provider attempts a handoff.
local getActiveProviderId

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local function log(message)

    print(
        "[KIPN MARKETPLACE SERVICE] "
        .. tostring(message)
    )
end

local function logError(message)

    print(
        "[KIPN MARKETPLACE SERVICE] ERROR: "
        .. tostring(message)
    )
end

local function getPlayerName(player)

    local ok, name =
        pcall(
            function()
                return player and player:getUsername()
            end
        )

    if ok and name then
        return name
    end

    return "?"
end

------------------------------------------------------------
-- PARCEL PERSISTENCE
--
-- A small, dedicated ModData tag rather than piggybacking on
-- KIPN_Server's main data file - parcels are a self-contained
-- queue with no relationship to KIPN's account/claim/config schema.
------------------------------------------------------------

local PARCEL_DATA_TAG =
    "KIPN_MarketplaceParcels"

local INTERNAL_MARKET_DATA_TAG =
    "KIPN_InternalMarketplace"

local function getParcelData()

    local ok, data =
        pcall(
            ModData.getOrCreate,
            PARCEL_DATA_TAG
        )

    if not ok
        or type(data) ~= "table"
    then

        logError(
            "getParcelData() failed to access persistent data: "
            .. tostring(data)
        )

        return nil
    end

    data.version =
        math.max(
            tonumber(data.version) or 1,
            3
        )

    data.nextParcelId =
        data.nextParcelId or 1

    data.parcelsByOwner =
        data.parcelsByOwner or {}

    -- Idempotency index for provider-authorized escrow handoffs.
    -- Keys deliberately remain after collection so a replayed native
    -- purchase completion cannot mint the same order twice.
    data.externalOrders =
        data.externalOrders or {}

    -- Idempotency index for trusted KIPN subsystems such as Event prize
    -- delivery. It is deliberately separate from provider transactions.
    data.systemOrders =
        data.systemOrders or {}

    return data
end

local function addParcel(username, parcel)

    local data =
        getParcelData()

    if not data then
        return nil
    end

    data.parcelsByOwner[username] =
        data.parcelsByOwner[username] or {}

    parcel.id =
        data.nextParcelId

    data.nextParcelId =
        data.nextParcelId + 1

    table.insert(
        data.parcelsByOwner[username],
        parcel
    )

    return parcel
end

local function getParcelsFor(username)

    local data =
        getParcelData()

    if not data then
        return {}
    end

    return data.parcelsByOwner[username] or {}
end

local function removeParcel(username, parcelId)

    local data =
        getParcelData()

    if not data then
        return false, nil
    end

    local list =
        data.parcelsByOwner[username]

    if not list then
        return false, nil
    end

    for i, parcel in ipairs(list) do

        if parcel.id == parcelId then

            table.remove(list, i)

            return true, parcel
        end
    end

    return false, nil
end

------------------------------------------------------------
-- KIPN INTERNAL MARKETPLACE PERSISTENCE
------------------------------------------------------------

local function getInternalMarketData()

    local ok, data =
        pcall(ModData.getOrCreate, INTERNAL_MARKET_DATA_TAG)

    if not ok or type(data) ~= "table" then
        logError("Internal marketplace data is unavailable: " .. tostring(data))
        return nil
    end

    data.version = math.max(tonumber(data.version) or 1, 1)
    data.nextListingId = math.max(tonumber(data.nextListingId) or 1, 1)
    data.listings = data.listings or {}

    return data
end

local function isRequestingPlayerAdmin(player)

    local permissions =
        KIPN.Server.Permissions

    if not permissions
        or type(permissions.ResolveAccessLevel) ~= "function"
    then
        logError(
            "isRequestingPlayerAdmin: KIPN.Server.Permissions."
            .. "ResolveAccessLevel is unavailable -- treating "
            .. "requester as non-admin. player="
            .. getPlayerName(player)
        )
        return false
    end

    local tier = permissions.ResolveAccessLevel(player)

    log(
        "isRequestingPlayerAdmin: player=" .. getPlayerName(player)
        .. " resolvedTier=" .. tostring(tier)
    )

    return tier == "ADMIN"
end

local function internalMarketZoneRequired()

    local value =
        KIPN.Server.Settings
        and KIPN.Server.Settings.Get(
            "Marketplace",
            "MarketplaceZoneRequired",
            true
        )

    return value ~= false
end

local function getInternalCurrencySettings()

    local itemType =
        KIPN.Server.Settings
        and KIPN.Server.Settings.Get(
            "Marketplace",
            "MarketplaceCurrencyItemType",
            "Base.Money"
        )
        or "Base.Money"

    if type(itemType) ~= "string" or itemType == "" then
        itemType = "Base.Money"
    end

    local itemValue =
        tonumber(
            KIPN.Server.Settings
            and KIPN.Server.Settings.Get(
                "Marketplace",
                "MarketplaceCurrencyItemValue",
                1
            )
            or 1
        )
        or 1

    itemValue = math.max(1, math.floor(itemValue))

    return itemType, itemValue
end

local function getScriptItem(fullType)

    local manager =
        type(getScriptManager) == "function"
        and getScriptManager()

    if not manager then
        return nil
    end

    local ok, item =
        pcall(function()
            if type(manager.FindItem) == "function" then
                return manager:FindItem(fullType)
            end

            return manager:getItem(fullType)
        end)

    return ok and item or nil
end

local function getScriptDisplayName(scriptItem, fallback)

    if scriptItem and type(scriptItem.getDisplayName) == "function" then
        local ok, value = pcall(scriptItem.getDisplayName, scriptItem)
        if ok and value and value ~= "" then
            return tostring(value)
        end
    end

    return fallback
end

------------------------------------------------------------
-- VEHICLE SCRIPTS
--
-- Admin listings may be vehicle script full types (e.g.
-- "Base.CarNormal"), which live in a separate ScriptManager
-- registry from items. getScriptItem() never resolves them, so a
-- listing is treated as a vehicle only when the item lookup fails
-- AND getVehicleScript() succeeds. Vehicle listings are fulfilled
-- by spawning the vehicle next to the buyer (see
-- handleInternalVehiclePurchase()), not through PO Box parcel
-- escrow.
------------------------------------------------------------

local function getVehicleScript(fullType)

    if type(fullType) ~= "string" or fullType == "" then
        return nil
    end

    local manager =
        type(getScriptManager) == "function"
        and getScriptManager()

    if not manager then
        return nil
    end

    -- Direct lookup first (accepts "Base.CarNormal" or "CarNormal"
    -- depending on build); fall back to scanning every loaded vehicle
    -- script -- vanilla and enabled-mod -- by full name.
    local bareType = fullType:gsub("^%a+%.", "")

    local ok, script = pcall(function()
        if type(manager.getVehicle) ~= "function" then
            return nil
        end
        return manager:getVehicle(fullType) or manager:getVehicle(bareType)
    end)

    if ok and script then
        return script
    end

    local scanOk, found = pcall(function()
        local all =
            type(manager.getAllVehicleScripts) == "function"
            and manager:getAllVehicleScripts()

        if not all then
            return nil
        end

        for index = 0, all:size() - 1 do
            local vs = all:get(index)
            if vs and vs:getFullName() == fullType then
                return vs
            end
        end

        return nil
    end)

    return scanOk and found or nil
end

local function getVehicleDisplayName(vehicleScript, fallback)

    if not vehicleScript then
        return fallback
    end

    -- Vehicle-name translation strings ("IGUI_VehicleName<model>")
    -- resolve client-side; the server keeps the raw model/script name
    -- and the marketplace client prettifies it for display.
    local ok, name = pcall(function()
        local modelName =
            type(vehicleScript.getCarModelName) == "function"
            and vehicleScript:getCarModelName()
            or nil

        local baseName =
            modelName
            or (type(vehicleScript.getName) == "function"
                and vehicleScript:getName())
            or nil

        if not baseName or baseName == "" then
            return nil
        end

        return baseName
    end)

    if ok and name and name ~= "" then
        return tostring(name)
    end

    return fallback
end

local function marketplaceVehicleSalesEnabled()

    local value =
        KIPN.Server.Settings
        and KIPN.Server.Settings.Get(
            "Marketplace",
            "MarketplaceVehicleSalesEnabled",
            true
        )

    return value ~= false
end

local function buildInternalCatalog()

    local data = getInternalMarketData()
    local result = {}
    local currencyItemType = getInternalCurrencySettings()
    local currencyLabel = currencyItemType == "Base.Money"
        and "$"
        or currencyItemType

    if not data then
        return result
    end

    for listingId, listing in pairs(data.listings) do
        if type(listing) == "table" and listing.active ~= false then
            local kind = listing.kind == "vehicle" and "vehicle" or "item"
            result[#result + 1] = {
                id = tostring(listingId),
                itemFullType = listing.itemFullType,
                kind = kind,
                displayName = listing.displayName or listing.itemFullType,
                quantity = kind == "vehicle"
                    and 1
                    or math.max(
                        1,
                        math.min(100, math.floor(tonumber(listing.quantity) or 1))
                    ),
                unitPrice = tonumber(listing.unitPrice) or 0,
                currency = currencyLabel,
                seller = "KIPN ADMIN",
                source = "KIPN",
                purchasable = true,
            }
        end
    end

    table.sort(result, function(a, b)
        local an = string.lower(tostring(a.displayName or ""))
        local bn = string.lower(tostring(b.displayName or ""))
        if an == bn then
            return tostring(a.id) < tostring(b.id)
        end
        return an < bn
    end)

    return result
end

local function transmitInternalMarketData()

    if type(ModData.transmit) == "function" then
        pcall(ModData.transmit, INTERNAL_MARKET_DATA_TAG)
    end
end

------------------------------------------------------------
-- EXTERNAL DELIVERY ESCROW API
--
-- Cooperative provider integrations call this only AFTER their own
-- server-authoritative purchase logic has validated price/stock,
-- settled payment/seller state, and suppressed normal direct
-- delivery. This function never accepts a client quote and never
-- edits a provider balance.
--
-- delivery shape:
--   externalOrderId  required stable provider transaction id
--   itemFullType     required item script full type
--   quantity         optional, defaults to 1 (maximum 100)
--   displayName      optional
--   providerData     optional serializable audit metadata
------------------------------------------------------------

local function clonePersistentValue(value, depth, seen)

    local valueType =
        type(value)

    if valueType == "nil"
        or valueType == "string"
        or valueType == "boolean"
    then
        return value, true
    end

    if valueType == "number" then

        if value ~= value
            or value == math.huge
            or value == -math.huge
        then
            return nil, false
        end

        return value, true
    end

    if valueType ~= "table"
        or depth > 8
        or seen[value]
    then
        return nil, false
    end

    seen[value] = true

    local copy = {}

    for key, child in pairs(value) do

        local keyType =
            type(key)

        if keyType ~= "string"
            and keyType ~= "number"
        then
            seen[value] = nil
            return nil, false
        end

        local childCopy, childOk =
            clonePersistentValue(
                child,
                depth + 1,
                seen
            )

        if not childOk then
            seen[value] = nil
            return nil, false
        end

        copy[key] = childCopy
    end

    seen[value] = nil

    return copy, true
end

function MarketplaceService.CanPlayerReceiveMarketplaceDelivery(player)
    if not player then return false end

    local claimService = KIPN.Server.ClaimService
    if not claimService or type(claimService.GetPlayerClaims) ~= "function" then
        return false
    end

    local claims = claimService.GetPlayerClaims(player)
    if type(claims) == "table" then
        for _, claim in pairs(claims) do
            if claim and claim.type == "po_box" then
                return true
            end
        end
    end

    return false
end

-- Offline-safe PO Box lookup for trusted server subsystems. Steam identity is
-- preferred; username is retained as a compatibility fallback for legacy
-- records. No client-supplied identity reaches this function directly.
function MarketplaceService.HasPOBoxForIdentity(username, steamId)
    local claimService = KIPN.Server.ClaimService
    if not claimService or type(claimService.GetClaims) ~= "function" then
        log("HasPOBoxForIdentity() -> false (ClaimService unavailable)")
        return false
    end

    local poBoxType = claimService.Types and claimService.Types.PO_BOX or "po_box"
    for _, claim in pairs(claimService.GetClaims(poBoxType, false) or {}) do
        local steamMatch = steamId ~= nil
            and claim.ownerSteamId ~= nil
            and tostring(claim.ownerSteamId) == tostring(steamId)
        local usernameMatch = username ~= nil
            and claim.ownerUsername ~= nil
            and tostring(claim.ownerUsername) == tostring(username)
        if claim.active ~= false and (steamMatch or usernameMatch) then
            log("HasPOBoxForIdentity() -> true claim=" .. tostring(claim.id))
            return true
        end
    end

    log("HasPOBoxForIdentity() -> false user=" .. tostring(username))
    return false
end

function MarketplaceService.QueueExternalDelivery(
    providerId,
    player,
    delivery
)

    if not MarketplaceService.CanPlayerReceiveMarketplaceDelivery(player) then
        return nil, "PO_BOX_REQUIRED"
    end

    if type(providerId) ~= "string"
        or providerId == ""
    then
        return nil, "INVALID_PROVIDER"
    end

    local capabilities =
        KIPN.Shared.MarketplaceProviderCapabilities
        and KIPN.Shared.MarketplaceProviderCapabilities[providerId]

    if type(capabilities) ~= "table" then
        return nil, "PROVIDER_NOT_SUPPORTED"
    end

    if type(getActiveProviderId) ~= "function"
        or getActiveProviderId() ~= providerId
    then
        return nil, "PROVIDER_NOT_ACTIVE"
    end

    if not player then
        return nil, "INVALID_PLAYER"
    end

    if type(delivery) ~= "table" then
        return nil, "INVALID_DELIVERY"
    end

    local externalOrderId =
        delivery.externalOrderId

    if type(externalOrderId) ~= "string"
        or externalOrderId == ""
        or #externalOrderId > 128
    then
        return nil, "INVALID_EXTERNAL_ORDER_ID"
    end

    local itemFullType =
        delivery.itemFullType

    if type(itemFullType) ~= "string"
        or itemFullType == ""
        or #itemFullType > 200
    then
        return nil, "INVALID_ITEM"
    end

    local rawQuantity =
        tonumber(delivery.quantity) or 1

    if rawQuantity ~= rawQuantity
        or rawQuantity == math.huge
        or rawQuantity == -math.huge
    then
        return nil, "INVALID_QUANTITY"
    end

    local quantity =
        math.floor(rawQuantity)

    if quantity < 1
        or quantity > 100
    then
        return nil, "INVALID_QUANTITY"
    end

    local data =
        getParcelData()

    if not data then
        return nil, "PARCEL_DATA_UNAVAILABLE"
    end

    local idempotencyKey =
        providerId
        .. ":"
        .. externalOrderId

    local existingParcelId =
        data.externalOrders[idempotencyKey]

    if existingParcelId then
        return nil, "DUPLICATE_EXTERNAL_ORDER"
    end

    local providerData, providerDataOk =
        clonePersistentValue(
            delivery.providerData,
            0,
            {}
        )

    if not providerDataOk then
        return nil, "INVALID_PROVIDER_DATA"
    end

    local parcel =
        addParcel(
            getPlayerName(player),
            {
                itemFullType = itemFullType,
                displayName =
                    delivery.displayName
                    or itemFullType,
                quantity = quantity,
                providerId = providerId,
                externalOrderId = externalOrderId,
                providerData = providerData,
                escrowed = true,
                createdAtMs =
                    type(getTimestampMs) == "function"
                    and getTimestampMs()
                    or 0,
            }
        )

    if not parcel then
        return nil, "PARCEL_PERSIST_FAILED"
    end

    data.externalOrders[idempotencyKey] =
        parcel.id

    log(
        "External delivery escrowed: provider="
        .. providerId
        .. " order="
        .. externalOrderId
        .. " player="
        .. getPlayerName(player)
        .. " parcelId="
        .. tostring(parcel.id)
    )

    return parcel, nil
end

------------------------------------------------------------
-- TRUSTED KIPN SYSTEM PARCEL API
--
-- Used by server-owned subsystems after their own authorization and award
-- decisions. Unlike QueueExternalDelivery(), this accepts an offline identity,
-- has no marketplace provider requirement, and never charges currency.
------------------------------------------------------------

function MarketplaceService.QueueSystemParcel(recipient, delivery)
    if type(recipient) ~= "table" or type(delivery) ~= "table" then
        log("QueueSystemParcel() -> INVALID_DELIVERY")
        return nil, "INVALID_DELIVERY"
    end

    local username = type(recipient.username) == "string"
        and recipient.username:match("^%s*(.-)%s*$") or ""
    if username == "" then
        log("QueueSystemParcel() -> INVALID_RECIPIENT")
        return nil, "INVALID_RECIPIENT"
    end

    if not MarketplaceService.HasPOBoxForIdentity(username, recipient.steamId) then
        log("QueueSystemParcel() -> PO_BOX_REQUIRED")
        return nil, "PO_BOX_REQUIRED"
    end

    local systemOrderId = tostring(delivery.systemOrderId or "")
    local itemFullType = tostring(delivery.itemFullType or "")
    local quantity = math.floor(tonumber(delivery.quantity) or 1)
    if systemOrderId == "" or #systemOrderId > 160 then
        log("QueueSystemParcel() -> INVALID_SYSTEM_ORDER_ID")
        return nil, "INVALID_SYSTEM_ORDER_ID"
    end
    if itemFullType == "" or #itemFullType > 200 then
        log("QueueSystemParcel() -> INVALID_ITEM")
        return nil, "INVALID_ITEM"
    end
    if quantity < 1 or quantity > 100 then
        log("QueueSystemParcel() -> INVALID_QUANTITY")
        return nil, "INVALID_QUANTITY"
    end

    local data = getParcelData()
    if not data then return nil, "PARCEL_DATA_UNAVAILABLE" end
    local existingParcelId = data.systemOrders[systemOrderId]
    if existingParcelId then
        for _, existingParcel in ipairs(data.parcelsByOwner[username] or {}) do
            if tostring(existingParcel.id) == tostring(existingParcelId) then
                log("QueueSystemParcel() -> existing parcel=" .. tostring(existingParcel.id))
                return existingParcel
            end
        end
        -- The parcel may already have been collected. The durable order index
        -- still proves fulfillment and prevents the trusted caller minting it
        -- a second time.
        log("QueueSystemParcel() -> previously fulfilled parcel=" .. tostring(existingParcelId))
        return { id = existingParcelId, alreadyFulfilled = true }
    end

    local sourceData, sourceDataOk = clonePersistentValue(delivery.sourceData, 0, {})
    if not sourceDataOk then
        log("QueueSystemParcel() -> INVALID_SOURCE_DATA")
        return nil, "INVALID_SOURCE_DATA"
    end

    local parcel = addParcel(username, {
        itemFullType = itemFullType,
        displayName = tostring(delivery.displayName or itemFullType),
        quantity = quantity,
        providerId = "KIPN_SYSTEM",
        systemOrderId = systemOrderId,
        sourceType = tostring(delivery.sourceType or "KIPN_SYSTEM"),
        sourceData = sourceData,
        recipientSteamId = recipient.steamId and tostring(recipient.steamId) or nil,
        escrowed = true,
        createdAtMs = type(getTimestampMs) == "function" and getTimestampMs() or 0,
    })

    if not parcel then
        logError("QueueSystemParcel() failed to persist parcel")
        return nil, "PARCEL_PERSIST_FAILED"
    end

    data.systemOrders[systemOrderId] = parcel.id
    log(
        "QueueSystemParcel() -> parcel=" .. tostring(parcel.id)
        .. " recipient=" .. username
        .. " source=" .. tostring(parcel.sourceType)
    )
    return parcel
end

------------------------------------------------------------
-- PROVIDER LEDGER REGISTRY
--
-- A ledger adapter is a function:
--
--     (player, currency, amount, reason) -> ok, reason
--
-- that charges the player through a provider mod's own authoritative
-- server-side economy API for generic KIPN service fees. A ledger is
-- not a marketplace checkout or delivery adapter. It must NOT touch
-- KIPN's own data - only the provider's.
--
-- TO ADD A NEW COMPATIBLE PROVIDER, register its ledger here (and
-- add its id to KIPN.Shared.MarketplaceProviderOrder in
-- KIPN_Shared.lua, plus a matching client display adapter). Nothing
-- else in this file needs to change.
------------------------------------------------------------

MarketplaceService.Ledgers =
    MarketplaceService.Ledgers or {}

function MarketplaceService.RegisterLedger(providerId, deductFn)

    if type(providerId) ~= "string"
        or providerId == ""
    then

        logError(
            "RegisterLedger(): providerId must be a non-empty string."
        )

        return false
    end

    if type(deductFn) ~= "function" then

        logError(
            "RegisterLedger(): deductFn must be a function for "
            .. tostring(providerId)
        )

        return false
    end

    ------------------------------------------------------------
    -- CAPABILITY CHECK
    --
    -- KIPN.Shared.MarketplaceProviderCapabilities
    -- (shared/KIPN_Shared.lua) is the single declared source of
    -- truth for whether generic KIPN services may debit a provider,
    -- shared with the client registry. This does not enable
    -- marketplace checkout; that is gated separately and fail-closed.
    ------------------------------------------------------------

    local capabilities =
        KIPN.Shared.MarketplaceProviderCapabilities
        and KIPN.Shared.MarketplaceProviderCapabilities[providerId]

    if type(capabilities) ~= "table"
        or capabilities.deduct ~= true
    then

        logError(
            "RegisterLedger(): provider '"
            .. tostring(providerId)
            .. "' is not declared deduct = true in "
            .. "KIPN.Shared.MarketplaceProviderCapabilities; "
            .. "refusing to register a ledger for it."
        )

        return false
    end

    MarketplaceService.Ledgers[providerId] =
        deductFn

    log(
        "Registered marketplace ledger adapter: "
        .. tostring(providerId)
    )

    return true
end

------------------------------------------------------------
-- PZ MARKETPLACE LEDGER ADAPTER (MyPZMarketplaceMod, mod id
-- "PZMarketplace" - not to be confused with "PZMarketplaceGES"
-- below, a different mod)
--
-- This mod exposes no grant/deduct function; every balance mutation
-- lives inline inside its OnClientCommand
-- handlers (media/lua/server/PZMarketplace_Server.lua). It DOES
-- keep its balance in a standard, public vanilla ModData tag
-- ("PZMarketplaceAccounts", flat table keyed by username -> number)
-- using the ordinary ModData.getOrCreate / ModData.transmit API -
-- the same public surface that mod's own code uses to persist and
-- broadcast it. Writing to that tag directly is standard PZ
-- mod-to-mod interoperability, not a private-internals reach: any
-- mod's server Lua can call ModData.getOrCreate() with any key.
------------------------------------------------------------

MarketplaceService.RegisterLedger(
    KIPN.Shared.MarketplaceProviders.PZ_MARKETPLACE,
    function(player, _currency, amount, _reason)

        local ok, accounts =
            pcall(
                ModData.getOrCreate,
                "PZMarketplaceAccounts"
            )

        if not ok
            or type(accounts) ~= "table"
        then
            return false, "PROVIDER_UNAVAILABLE"
        end

        local username =
            player and player:getUsername()

        if not username then
            return false, "INVALID_PLAYER"
        end

        local balance =
            tonumber(accounts[username]) or 0

        if balance < amount then
            return false, "INSUFFICIENT_BALANCE"
        end

        accounts[username] =
            math.max(0, math.floor(balance - amount))

        pcall(ModData.transmit, "PZMarketplaceAccounts")

        return true, nil
    end
)

------------------------------------------------------------
-- MX - ECONOMY LEDGER ADAPTER (mod id "MX-Economy")
--
-- No grant/deduct function is exposed either; balance lives on
-- standard per-player ModData (`player:getModData().cash`, a plain
-- number) rather than a mod-owned table. `player:getModData()` /
-- `player:transmitModData()` are vanilla PZ API, public on every
-- player object - this mirrors exactly how MX-Economy's own server
-- file (MX-Economy.lua) mutates and syncs it.
------------------------------------------------------------

MarketplaceService.RegisterLedger(
    KIPN.Shared.MarketplaceProviders.MX_ECONOMY,
    function(player, _currency, amount, _reason)

        if not player then
            return false, "INVALID_PLAYER"
        end

        local ok, modData =
            pcall(player.getModData, player)

        if not ok
            or type(modData) ~= "table"
        then
            return false, "PROVIDER_UNAVAILABLE"
        end

        local cash =
            tonumber(modData.cash) or 0

        if cash < amount then
            return false, "INSUFFICIENT_BALANCE"
        end

        modData.cash =
            cash - amount

        pcall(player.transmitModData, player)

        return true, nil
    end
)

------------------------------------------------------------
-- SELL & SHOP SYSTEM LEDGER ADAPTER (mod id "SellAndShop")
--
-- Same shape as MX-Economy: no exposed grant/deduct, balance is
-- standard per-player ModData (`player:getModData().SAS_Points`).
------------------------------------------------------------

MarketplaceService.RegisterLedger(
    KIPN.Shared.MarketplaceProviders.SELL_AND_SHOP,
    function(player, _currency, amount, _reason)

        if not player then
            return false, "INVALID_PLAYER"
        end

        local ok, modData =
            pcall(player.getModData, player)

        if not ok
            or type(modData) ~= "table"
        then
            return false, "PROVIDER_UNAVAILABLE"
        end

        local points =
            tonumber(modData.SAS_Points) or 0

        if points < amount then
            return false, "INSUFFICIENT_BALANCE"
        end

        modData.SAS_Points =
            points - amount

        pcall(player.transmitModData, player)

        return true, nil
    end
)

------------------------------------------------------------
-- ACTIVE PROVIDER RESOLUTION
------------------------------------------------------------

getActiveProviderId = function()

    local order =
        KIPN.Shared.MarketplaceProviderOrder

    if type(order) ~= "table" then
        return KIPN.Shared.MarketplaceProviders.NONE
    end

    local index =
        KIPN.Server.Settings
        and KIPN.Server.Settings.Get(
            "Marketplace",
            "MarketplaceProvider",
            1
        )
        or 1

    if type(index) ~= "number" then
        index = 1
    end

    return order[index]
        or KIPN.Shared.MarketplaceProviders.NONE
end

------------------------------------------------------------
-- SERVICE-FEE CURRENCY TOKEN
--
-- Current ledger adapters hold one flat balance and ignore this
-- argument. Keep a neutral token in the generic ledger contract for
-- providers that may distinguish currencies in the future.
------------------------------------------------------------

local function resolvePrimaryCurrency()
    return "$"
end

------------------------------------------------------------
-- VANILLA CASH FALLBACK
--
-- Optional fallback for ChargePlayer() (see allowVanillaCashFallback
-- below): when the player has no marketplace account linked, or the
-- provider ledger declines the charge (e.g. insufficient balance),
-- this lets vanilla physical cash -- Base.Money ($1) and
-- Base.MoneyBundle ($100, matching the bundle value KIPN already
-- assumes elsewhere; see KIPN_MarketplaceAdapter_GlocServerEconomy
-- .lua's CURRENCY_BUNDLE_VALUE fallback) -- fulfil the purchase
-- instead.
--
-- Recurses into nested containers (a bag, a wallet) the same way
-- KIPN_ArtifactService's findArtifactItem()/findArtifactItemById()
-- now do -- previously this scanned only the player's own top-level
-- inventory, so cash carried in a bag was invisible to this check
-- even though the player's total on-hand cash was genuinely
-- sufficient (a likely contributor to "money was not consumed" when
-- an Excavation Permit purchase silently failed this check before
-- ArtifactService ever ran).
--
-- Removal still uses inventory:Remove(item) called on whichever
-- ItemContainer actually holds that item (the bag's own container,
-- not necessarily the player's root inventory).
--
-- Only ever removes cash if the player's on-hand total can cover
-- `amount` EXACTLY with whole bundles/bills -- it never leaves a
-- partial charge or makes change.
------------------------------------------------------------

local VANILLA_MONEY_SINGLE_TYPE = "Base.Money"
local VANILLA_MONEY_BUNDLE_TYPE = "Base.MoneyBundle"
local VANILLA_MONEY_BUNDLE_VALUE = 100

-- Collects every item of the two vanilla money types found anywhere
-- under `container`, recursing into nested item containers (bags).
-- singles/bundles are appended as {item=item, container=container}
-- so removal later calls Remove() on the container that actually
-- holds each item.
local function collectVanillaCashRecurse(container, singles, bundles)

    if not container then
        return
    end

    if type(container.getItems) ~= "function" then
        return
    end

    local items = container:getItems()

    if not items then
        return
    end

    for i = 0, items:size() - 1 do

        local item = items:get(i)

        if item then

            local fullType = item:getFullType()

            if fullType == VANILLA_MONEY_SINGLE_TYPE then

                table.insert(singles, { item = item, container = container })

            elseif fullType == VANILLA_MONEY_BUNDLE_TYPE then

                table.insert(bundles, { item = item, container = container })

            end

            local nestedOk, nestedInventory =
                pcall(function()

                    if type(item.getInventory) == "function" then
                        return item:getInventory()
                    end

                    return nil
                end)

            if nestedOk and nestedInventory then

                collectVanillaCashRecurse(nestedInventory, singles, bundles)

            end
        end
    end
end

local function chargeVanillaCash(player, amount)

    local inventory =
        player
        and player:getInventory()

    if not inventory then
        return false, "INVENTORY_UNAVAILABLE"
    end

    local singles = {}
    local bundles = {}

    collectVanillaCashRecurse(inventory, singles, bundles)

    -- Using as many bundles as possible minimizes the singles
    -- required, so this is the only combination worth checking --
    -- using fewer bundles only ever increases the singles needed.
    local bundleCount =
        math.min(
            #bundles,
            math.floor(amount / VANILLA_MONEY_BUNDLE_VALUE)
        )

    local singleCount =
        amount - (bundleCount * VANILLA_MONEY_BUNDLE_VALUE)

    if singleCount > #singles then
        return false, "INSUFFICIENT_VANILLA_CASH"
    end

    -- ItemContainer:Remove() only updates the server-side container --
    -- it does not itself notify the owning client, so each removal
    -- must also be pushed with sendRemoveItemFromContainer() or the
    -- spent cash (bundle or single) stays visible in the player's
    -- inventory UI despite genuinely being gone server-side. Same
    -- Remove() + sendRemoveItemFromContainer() sequence used
    -- elsewhere in this file (see removeCurrencyPlan() above) and by
    -- KIPN_ArtifactService.ConsumeArtifactItem() for the Registration
    -- Form.
    for i = 1, bundleCount do
        bundles[i].container:Remove(bundles[i].item)

        if type(sendRemoveItemFromContainer) == "function" then
            pcall(sendRemoveItemFromContainer, bundles[i].container, bundles[i].item)
        end
    end

    for i = 1, singleCount do
        singles[i].container:Remove(singles[i].item)

        if type(sendRemoveItemFromContainer) == "function" then
            pcall(sendRemoveItemFromContainer, singles[i].container, singles[i].item)
        end
    end

    return true, nil
end

------------------------------------------------------------
-- INTERNAL MARKETPLACE SPLIT PAYMENT
--
-- Physical currency is selected and removed first. Any remainder
-- is then charged through the already-registered provider ledger.
-- If that second stage declines, every removed item object is put
-- back into the exact container it came from.
------------------------------------------------------------

local function collectCurrencyItemsRecurse(
    container,
    currencyItemType,
    currencyItemValue,
    entries
)

    if not container or type(container.getItems) ~= "function" then
        return
    end

    local items = container:getItems()
    if not items then
        return
    end

    for i = 0, items:size() - 1 do
        local item = items:get(i)

        if item then
            local fullType = item:getFullType()
            local value

            if fullType == currencyItemType then
                value = currencyItemValue
            elseif currencyItemType == VANILLA_MONEY_SINGLE_TYPE
                and fullType == VANILLA_MONEY_BUNDLE_TYPE
            then
                value = VANILLA_MONEY_BUNDLE_VALUE
            end

            if value then
                entries[#entries + 1] = {
                    item = item,
                    container = container,
                    fullType = fullType,
                    value = value,
                }
            end

            local nestedOk, nested = pcall(function()
                return type(item.getInventory) == "function"
                    and item:getInventory()
                    or nil
            end)

            if nestedOk and nested then
                collectCurrencyItemsRecurse(
                    nested,
                    currencyItemType,
                    currencyItemValue,
                    entries
                )
            end
        end
    end
end

local function buildPhysicalCurrencyPlan(player, amount, excludedItems)

    local inventory = player and player:getInventory()
    if not inventory then
        return nil, 0, "INVENTORY_UNAVAILABLE"
    end

    local currencyItemType, currencyItemValue =
        getInternalCurrencySettings()

    local entries = {}
    collectCurrencyItemsRecurse(
        inventory,
        currencyItemType,
        currencyItemValue,
        entries
    )

    table.sort(entries, function(a, b)
        return a.value > b.value
    end)

    local plan = {}
    local paid = 0
    local selected = {}

    for _, entry in ipairs(entries) do
        if not (excludedItems and excludedItems[entry.item])
            and paid + entry.value <= amount
        then
            plan[#plan + 1] = entry
            paid = paid + entry.value
            selected[entry.item] = true
        end

        if paid >= amount then
            break
        end
    end

    local changeDue = 0

    -- Vanilla $100 bundles are divisible: if the only way to cover a
    -- sub-$100 remainder is to open one bundle, return the difference
    -- as Base.Money rather than incorrectly reporting insufficient
    -- funds or charging the external balance while cash is on hand.
    if currencyItemType == VANILLA_MONEY_SINGLE_TYPE and paid < amount then
        local remainder = amount - paid

        for _, entry in ipairs(entries) do
            if not selected[entry.item]
                and not (excludedItems and excludedItems[entry.item])
                and entry.fullType == VANILLA_MONEY_BUNDLE_TYPE
                and entry.value >= remainder
            then
                plan[#plan + 1] = entry
                paid = amount
                changeDue = entry.value - remainder
                break
            end
        end
    end

    return plan, paid, nil, changeDue
end

local function restoreCurrencyPlan(plan)

    local restoredAll = true

    for _, entry in ipairs(plan or {}) do
        local ok, restored = pcall(function()
            return entry.container:AddItem(entry.item)
        end)

        if not ok or not restored then
            restoredAll = false
            logError(
                "Failed to restore currency item after declined split payment: "
                .. tostring(entry.fullType)
            )
        elseif type(sendAddItemToContainer) == "function" then
            sendAddItemToContainer(entry.container, entry.item)
        end
    end

    return restoredAll
end

local function currencyContainerHasItem(container, wantedItem)

    if not container
        or not wantedItem
        or type(container.getItems) ~= "function"
    then
        return nil
    end

    local ok, found = pcall(function()
        local items = container:getItems()
        if not items then return false end

        for i = 0, items:size() - 1 do
            if items:get(i) == wantedItem then
                return true
            end
        end

        return false
    end)

    -- found may legitimately be `false` (item confirmed absent), which
    -- `ok and found or nil` would collapse into `nil` -- and
    -- removeCurrencyPlan() below treats anything but an explicit
    -- `false` after Remove() as a failed removal. Return the real
    -- tri-state instead.
    if not ok then
        return nil
    end

    return found
end

local function removeCurrencyPlan(plan)

    local removed = {}

    for _, entry in ipairs(plan or {}) do
        if currencyContainerHasItem(entry.container, entry.item) ~= true then
            restoreCurrencyPlan(removed)
            return false, "CURRENCY_ITEM_MISSING"
        end

        local ok = pcall(entry.container.Remove, entry.container, entry.item)

        if not ok
            or currencyContainerHasItem(entry.container, entry.item) ~= false
        then
            restoreCurrencyPlan(removed)
            return false, "CURRENCY_ITEM_REMOVAL_FAILED"
        end

        removed[#removed + 1] = entry

        if type(sendRemoveItemFromContainer) == "function" then
            -- A failed network notification must not turn a successful
            -- authoritative removal into an ambiguous rollback window.
            pcall(sendRemoveItemFromContainer, entry.container, entry.item)
        end
    end

    return true, nil
end

local function giveVanillaChange(player, amount)

    if amount <= 0 then
        return true, {}
    end

    local inventory = player and player:getInventory()
    if not inventory then
        return false
    end

    local added = {}

    for _ = 1, amount do
        local ok, item = pcall(function()
            local created = KIPN.Server.CreateItem(VANILLA_MONEY_SINGLE_TYPE)
            if not created then return nil end
            return inventory:AddItem(created)
        end)

        if not ok or not item then
            for _, addedItem in ipairs(added) do
                pcall(inventory.Remove, inventory, addedItem)
                if type(sendRemoveItemFromContainer) == "function" then
                    pcall(sendRemoveItemFromContainer, inventory, addedItem)
                end
            end
            return false
        end

        added[#added + 1] = item
        if type(sendAddItemToContainer) == "function" then
            pcall(sendAddItemToContainer, inventory, item)
        end
    end

    return true, added
end

local function removeGrantedItems(items)

    local removedAll = true

    for _, entry in ipairs(items or {}) do
        local item
        local container

        if type(entry) == "table" then
            item = entry.item
            container = entry.container
        else
            item = entry
        end

        if not container
            and item
            and type(item.getContainer) == "function"
        then
            local ok, result = pcall(item.getContainer, item)
            if ok then
                container = result
            end
        end

        if not item or not container then
            removedAll = false
        else
            local ok = pcall(container.Remove, container, item)
            if not ok then
                removedAll = false
            elseif type(sendRemoveItemFromContainer) == "function" then
                pcall(sendRemoveItemFromContainer, container, item)
            end
        end
    end

    return removedAll
end

------------------------------------------------------------
-- INVENTORY-ONLY PURCHASE
--
-- Used by purchases whose contract explicitly requires physical
-- currency to leave the player's inventory. Unlike
-- ChargeInternalPurchase(), this never pays a remainder from an
-- external provider balance. The returned private receipt lets the
-- caller restore the exact item objects if a later transaction step
-- (such as consuming another required item) fails.
------------------------------------------------------------

function MarketplaceService.ChargeInventoryPurchase(
    player,
    amount,
    excludedItems
)

    local chargeAmount = tonumber(amount)
    if not player or not chargeAmount or chargeAmount <= 0 then
        return false, "INVALID_AMOUNT"
    end

    chargeAmount = math.floor(chargeAmount)

    local plan, physicalAmount, planReason, changeDue =
        buildPhysicalCurrencyPlan(
            player,
            chargeAmount,
            excludedItems
        )

    if not plan then
        return false, planReason
    end

    if physicalAmount < chargeAmount then
        return false, "INSUFFICIENT_INVENTORY_CURRENCY"
    end

    local removedOk, removeReason = removeCurrencyPlan(plan)
    if not removedOk then
        return false, removeReason
    end

    local changeOk, changeItems =
        giveVanillaChange(player, changeDue or 0)

    if not changeOk then
        local restored = restoreCurrencyPlan(plan)
        return false,
            restored
                and "CHANGE_CREATION_FAILED"
                or "PAYMENT_ROLLBACK_FAILED"
    end

    return true, nil, {
        inventoryAmount = chargeAmount,
        removedItems = plan,
        changeItems = changeItems or {},
    }
end

function MarketplaceService.RefundInventoryPurchase(receipt)

    if type(receipt) ~= "table"
        or type(receipt.removedItems) ~= "table"
    then
        return false
    end

    local removedChange =
        removeGrantedItems(receipt.changeItems)

    local restored = restoreCurrencyPlan(receipt.removedItems)
    return removedChange and restored
end

function MarketplaceService.ChargeInternalPurchase(player, amount, reason, excludedItems)

    local chargeAmount = tonumber(amount)
    if not player or not chargeAmount or chargeAmount <= 0 then
        return false, "INVALID_AMOUNT"
    end

    chargeAmount = math.floor(chargeAmount)

    local plan, physicalAmount, planReason, changeDue =
        buildPhysicalCurrencyPlan(player, chargeAmount, excludedItems)

    if not plan then
        return false, planReason
    end

    local remainder = chargeAmount - physicalAmount
    local activeProviderId = getActiveProviderId()
    local ledger =
        activeProviderId ~= KIPN.Shared.MarketplaceProviders.NONE
        and MarketplaceService.Ledgers[activeProviderId]
        or nil

    if remainder > 0 and not ledger then
        return false, "INSUFFICIENT_CURRENCY"
    end

    local removedOk, removeReason = removeCurrencyPlan(plan)
    if not removedOk then
        return false, removeReason
    end

    local changeOk, changeItems =
        giveVanillaChange(player, changeDue or 0)

    if not changeOk then
        local restored = restoreCurrencyPlan(plan)
        return false, restored and "CHANGE_CREATION_FAILED" or "PAYMENT_ROLLBACK_FAILED"
    end

    if remainder > 0 then
        local callOk, ledgerOk, ledgerReason = pcall(
            ledger,
            player,
            resolvePrimaryCurrency(),
            remainder,
            reason or "KIPN Marketplace purchase"
        )

        if not callOk or not ledgerOk then
            local changeRemoved = removeGrantedItems(changeItems)
            local restored = restoreCurrencyPlan(plan)
            if not changeRemoved or not restored then
                return false, "PAYMENT_ROLLBACK_FAILED"
            end
            return false,
                callOk
                    and (ledgerReason or "INSUFFICIENT_BALANCE")
                    or "PROVIDER_ERROR"
        end
    end

    return true, nil, {
        inventoryAmount = physicalAmount,
        balanceAmount = remainder,
        providerId = activeProviderId,
        changeReturned = changeDue,
    }
end

------------------------------------------------------------
-- CHARGE PLAYER (GENERIC, NOT TIED TO A LISTING)
--
-- Lets other KIPN services (e.g. KIPN_ArtifactService's
-- Excavation Permit purchase) charge the player through whichever
-- marketplace provider the admin has configured, without going
-- through the PURCHASE_MARKETPLACE_ITEM listing flow (which
-- assumes a catalog item + PO Box delivery, neither of which apply
-- here).
--
-- allowVanillaCashFallback (optional, default false): if true, and
-- the player has no marketplace account linked or the provider
-- ledger declines the charge, retries the charge against vanilla
-- physical cash (see chargeVanillaCash() above) before failing.
-- Existing callers that omit this keep their original all-or-
-- nothing marketplace-only behavior.
------------------------------------------------------------

function MarketplaceService.ChargePlayer(player, amount, reason, allowVanillaCashFallback)

    if not player then
        return false, "INVALID_PLAYER"
    end

    local chargeAmount =
        tonumber(amount)

    if not chargeAmount
        or chargeAmount <= 0
    then
        return false, "INVALID_AMOUNT"
    end

    local activeProviderId =
        getActiveProviderId()

    local ledger =
        activeProviderId ~= KIPN.Shared.MarketplaceProviders.NONE
        and MarketplaceService.Ledgers[activeProviderId]

    local providerDeclineReason

    if ledger then

        local ok, deductReason =
            ledger(
                player,
                resolvePrimaryCurrency(),
                chargeAmount,
                reason or "KIPN charge"
            )

        if ok then
            return true, nil
        end

        providerDeclineReason =
            deductReason or "DECLINED"

        log(
            "ChargePlayer() declined by provider ledger ("
            .. tostring(activeProviderId)
            .. "): "
            .. tostring(providerDeclineReason)
        )

    else

        providerDeclineReason =
            "NO_PROVIDER_CONFIGURED"

    end

    if not allowVanillaCashFallback then
        return false, providerDeclineReason
    end

    local cashOk, cashReason =
        chargeVanillaCash(player, chargeAmount)

    if not cashOk then

        log(
            "ChargePlayer() vanilla cash fallback also failed: "
            .. tostring(cashReason)
        )

        return false,
            "No marketplace balance and insufficient vanilla " ..
            "cash on hand."
    end

    log(
        "ChargePlayer() fulfilled via vanilla cash fallback " ..
        "(marketplace declined: "
        .. tostring(providerDeclineReason)
        .. ")"
    )

    return true, nil
end

------------------------------------------------------------
-- KIPN INTERNAL MARKETPLACE COMMANDS
------------------------------------------------------------

local function isPlayerInZoneType(player, zoneType)

    local registry = KIPN.Server.WorldRegistry
    if not registry or type(registry.GetZoneAtPosition) ~= "function" then
        return false
    end

    local ok, zone = pcall(function()
        return registry.GetZoneAtPosition(
            player:getX(),
            player:getY(),
            player:getZ(),
            zoneType
        )
    end)

    return ok and zone ~= nil
end

local function canPurchaseInternalMarketHere(player)

    if not internalMarketZoneRequired() then
        return true
    end

    local zoneType =
        KIPN.Server.WorldRegistry
        and KIPN.Server.WorldRegistry.ZoneTypes
        and KIPN.Server.WorldRegistry.ZoneTypes.MARKETPLACE
        or "marketplace"

    return isPlayerInZoneType(player, zoneType)
end

local function sendInternalCatalog(player)

    local currencyItemType = getInternalCurrencySettings()

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.KIPN_MARKETPLACE_ITEMS_DATA,
        {
            items = buildInternalCatalog(),
            isAdmin = isRequestingPlayerAdmin(player),
            zoneRequired = internalMarketZoneRequired(),
            purchaseAllowedHere = canPurchaseInternalMarketHere(player),
            currencyItemType = currencyItemType,
            currency = currencyItemType == "Base.Money" and "$" or currencyItemType,
            hasPOBox = MarketplaceService.CanPlayerReceiveMarketplaceDelivery(player),
        }
    )
end

local function sendInternalAdminResult(player, success, reason, listing)

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.KIPN_MARKETPLACE_ADMIN_RESULT,
        {
            success = success == true,
            reason = reason,
            listing = listing,
        }
    )
end

local function handleGetInternalMarketplaceItems(player, _args)
    sendInternalCatalog(player)
end

local function handleSaveInternalMarketplaceItem(player, args)

    if not isRequestingPlayerAdmin(player) then
        sendInternalAdminResult(player, false, "ADMIN_REQUIRED")
        return
    end

    args = args or {}

    local itemFullType = type(args.itemFullType) == "string"
        and args.itemFullType
        or nil
    local quantity = tonumber(args.quantity)
    local unitPrice = tonumber(args.unitPrice)

    if itemFullType then
        itemFullType = string.match(itemFullType, "^%s*(.-)%s*$")
    end

    if not itemFullType
        or itemFullType == ""
        or #itemFullType > 200
        or not quantity
        or quantity <= 0
        or quantity > 100
        or not unitPrice
        or unitPrice <= 0
        or unitPrice > 1000000000
    then
        sendInternalAdminResult(player, false, "INVALID_LISTING")
        return
    end

    quantity = math.floor(quantity)
    unitPrice = math.floor(unitPrice)

    if quantity < 1 or unitPrice < 1 then
        sendInternalAdminResult(player, false, "INVALID_LISTING")
        return
    end

    -- Items and vehicles are looked up in separate ScriptManager
    -- registries. Only when the type is not an item AND is a vehicle
    -- script is the listing treated as a vehicle sale.
    local scriptItem = getScriptItem(itemFullType)
    local vehicleScript = nil

    if not scriptItem then
        vehicleScript = getVehicleScript(itemFullType)
    end

    if not scriptItem and not vehicleScript then
        sendInternalAdminResult(player, false, "ITEM_TYPE_NOT_FOUND")
        return
    end

    local listingKind = vehicleScript and "vehicle" or "item"

    if listingKind == "vehicle" then
        if not marketplaceVehicleSalesEnabled() then
            sendInternalAdminResult(player, false, "VEHICLE_SALES_DISABLED")
            return
        end

        -- A vehicle listing always sells exactly one vehicle for its
        -- configured price, regardless of the quantity field.
        quantity = 1
    end

    local data = getInternalMarketData()
    if not data then
        sendInternalAdminResult(player, false, "MARKET_DATA_UNAVAILABLE")
        return
    end

    local listingId = args.listingId and tostring(args.listingId) or nil
    local listing = listingId and data.listings[listingId] or nil

    -- One authoritative listing per item type. Supplying an existing
    -- type updates its quantity and price instead of creating ambiguous
    -- duplicates.
    for existingId, existing in pairs(data.listings) do
        if existing.itemFullType == itemFullType
            and tostring(existingId) ~= tostring(listingId)
        then
            if listing then
                sendInternalAdminResult(player, false, "ITEM_ALREADY_LISTED")
                return
            else
                listingId = tostring(existingId)
                listing = existing
                break
            end
        end
    end

    if not listing then
        listingId = "KIPN-SHOP-" .. tostring(data.nextListingId)
        data.nextListingId = data.nextListingId + 1
        listing = {}
        data.listings[listingId] = listing
    end

    listing.id = listingId
    listing.itemFullType = itemFullType
    listing.kind = listingKind
    listing.displayName = vehicleScript
        and getVehicleDisplayName(vehicleScript, itemFullType)
        or getScriptDisplayName(scriptItem, itemFullType)
    listing.quantity = quantity
    listing.unitPrice = unitPrice
    local currencyItemType = getInternalCurrencySettings()
    listing.currency = currencyItemType == "Base.Money"
        and "$"
        or currencyItemType
    listing.active = true
    listing.updatedBy = getPlayerName(player)
    listing.updatedAtMs = type(getTimestampMs) == "function"
        and getTimestampMs()
        or 0

    transmitInternalMarketData()

    sendInternalAdminResult(player, true, nil, listing)
    sendInternalCatalog(player)

    log(
        "Internal listing saved: id=" .. listingId
        .. " item=" .. itemFullType
        .. " quantity=" .. tostring(quantity)
        .. " price=" .. tostring(unitPrice)
        .. " admin=" .. getPlayerName(player)
    )
end

local function handleRemoveInternalMarketplaceItem(player, args)

    if not isRequestingPlayerAdmin(player) then
        sendInternalAdminResult(player, false, "ADMIN_REQUIRED")
        return
    end

    local listingId = args and args.listingId and tostring(args.listingId)
    local data = getInternalMarketData()

    if not listingId or not data or not data.listings[listingId] then
        sendInternalAdminResult(player, false, "LISTING_NOT_FOUND")
        return
    end

    local removed = data.listings[listingId]
    data.listings[listingId] = nil
    transmitInternalMarketData()

    sendInternalAdminResult(player, true, nil, removed)
    sendInternalCatalog(player)

    log(
        "Internal listing removed: id=" .. listingId
        .. " admin=" .. getPlayerName(player)
    )
end

local function sendInternalPurchaseResult(player, payload)
    payload.internal = true
    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
        payload
    )
end

------------------------------------------------------------
-- VEHICLE LISTING FULFILMENT
--
-- Vehicles cannot be escrowed into a PO Box parcel, so a vehicle
-- purchase spawns the vehicle on a free square next to the buyer
-- and hands them a matching key. The vehicle is spawned FIRST and
-- removed again if payment then declines, so a failed charge can
-- never leave a free car in the world.
------------------------------------------------------------

local function findVehicleSpawnSquare(player)

    local cell = type(getCell) == "function" and getCell()
    if not cell then
        return nil
    end

    local baseX = math.floor(player:getX())
    local baseY = math.floor(player:getY())
    local baseZ = math.floor(player:getZ())

    if baseZ ~= 0 then
        -- Vehicles only exist on the ground floor.
        return nil
    end

    local function squareIsClear(square)
        if not square then
            return false
        end
        if type(square.hasFloor) == "function" and not square:hasFloor() then
            return false
        end
        if type(square.getRoom) == "function" and square:getRoom() ~= nil then
            -- Outdoors only -- never spawn inside a building.
            return false
        end
        if type(square.isVehicleIntersecting) == "function"
            and square:isVehicleIntersecting()
        then
            return false
        end
        if type(square.isFreeOrMidair) == "function"
            and not square:isFreeOrMidair(false)
        then
            return false
        end
        return true
    end

    local function candidateIsClear(cx, cy)
        for ox = -1, 1 do
            for oy = -1, 1 do
                if not squareIsClear(cell:getGridSquare(cx + ox, cy + oy, 0)) then
                    return false
                end
            end
        end
        return true
    end

    for radius = 2, 9 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.max(math.abs(dx), math.abs(dy)) == radius then
                    if candidateIsClear(baseX + dx, baseY + dy) then
                        return cell:getGridSquare(baseX + dx, baseY + dy, 0)
                    end
                end
            end
        end
    end

    return nil
end

local function handleInternalVehiclePurchase(player, listing, listingId)

    if not marketplaceVehicleSalesEnabled() then
        sendInternalPurchaseResult(player, { success = false, reason = "VEHICLE_SALES_DISABLED" })
        return
    end

    local fullType = listing.itemFullType
    local displayName = listing.displayName or fullType
    local unitPrice = tonumber(listing.unitPrice)
    local vehicleScript = getVehicleScript(fullType)

    if not vehicleScript
        or not unitPrice
        or unitPrice <= 0
        or unitPrice > 1000000000
    then
        sendInternalPurchaseResult(player, { success = false, reason = "LISTING_UNAVAILABLE" })
        return
    end

    if type(player.getVehicle) == "function" and player:getVehicle() ~= nil then
        sendInternalPurchaseResult(player, { success = false, reason = "ALREADY_IN_VEHICLE" })
        return
    end

    local square = findVehicleSpawnSquare(player)
    if not square then
        sendInternalPurchaseResult(player, { success = false, reason = "NO_SPACE_FOR_VEHICLE" })
        return
    end

    local username = getPlayerName(player)

    local spawnOk, vehicle = pcall(function()
        if type(addVehicleDebug) ~= "function" then
            return nil
        end
        return addVehicleDebug(fullType, IsoDirections.N, nil, square)
    end)

    if not spawnOk or not vehicle then
        logError(
            "Vehicle purchase spawn failed: player=" .. username
            .. " type=" .. tostring(fullType)
            .. " err=" .. tostring(vehicle)
        )
        sendInternalPurchaseResult(player, { success = false, reason = "VEHICLE_SPAWN_FAILED" })
        return
    end

    local charged, chargeReason, payment =
        MarketplaceService.ChargeInternalPurchase(
            player,
            math.floor(unitPrice),
            "KIPN Marketplace vehicle purchase: " .. tostring(displayName)
        )

    if not charged then
        pcall(function() vehicle:permanentlyRemove() end)
        sendInternalPurchaseResult(player, { success = false, reason = chargeReason or "DECLINED" })
        return
    end

    local keyDelivered = false
    pcall(function()
        local key = type(vehicle.createVehicleKey) == "function"
            and vehicle:createVehicleKey()
            or nil
        if not key then
            return
        end
        local inventory = player:getInventory()
        if not inventory then
            return
        end
        inventory:AddItem(key)
        if type(sendAddItemToContainer) == "function" then
            sendAddItemToContainer(inventory, key)
        end
        keyDelivered = true
    end)

    -- With the key delivered, lock it so a bystander cannot simply
    -- drive it off in the seconds before the buyer walks over. Never
    -- lock a car the buyer has no key for.
    if keyDelivered then
        pcall(function()
            if type(vehicle.setKeysInIgnition) == "function" then
                vehicle:setKeysInIgnition(false)
            end
            for partIndex = 0, (vehicle:getPartCount() or 0) - 1 do
                local part = vehicle:getPartByIndex(partIndex)
                local door = part and type(part.getDoor) == "function" and part:getDoor()
                if door and type(door.setLocked) == "function" then
                    door:setLocked(true)
                    if type(vehicle.transmitPartDoor) == "function" then
                        vehicle:transmitPartDoor(part)
                    end
                end
            end
        end)
    end

    log(
        "Internal vehicle purchase: player=" .. username
        .. " listing=" .. tostring(listingId)
        .. " type=" .. tostring(fullType)
        .. " price=" .. tostring(math.floor(unitPrice))
        .. " keyDelivered=" .. tostring(keyDelivered)
    )

    sendInternalPurchaseResult(player, {
        success = true,
        vehicle = true,
        keyDelivered = keyDelivered,
        item = {
            itemFullType = fullType,
            displayName = displayName,
            quantity = 1,
        },
        payment = payment,
    })
end

local function handlePurchaseInternalMarketplaceItem(player, args)

    args = args or {}

    local listingId = args.listingId and tostring(args.listingId)
    local data = getInternalMarketData()
    local listing = data and listingId and data.listings[listingId]

    if not listing or listing.active == false then
        sendInternalPurchaseResult(player, { success = false, reason = "INVALID_LISTING" })
        return
    end

    if not canPurchaseInternalMarketHere(player) then
        sendInternalPurchaseResult(player, { success = false, reason = "MARKETPLACE_ZONE_REQUIRED" })
        return
    end

    if listing.kind == "vehicle" then
        handleInternalVehiclePurchase(player, listing, listingId)
        return
    end

    if not MarketplaceService.CanPlayerReceiveMarketplaceDelivery(player) then
        sendInternalPurchaseResult(player, { success = false, reason = "PO_BOX_REQUIRED" })
        return
    end

    local quantity = math.floor(tonumber(listing.quantity) or 1)

    if quantity < 1 or quantity > 100 then
        sendInternalPurchaseResult(player, { success = false, reason = "INVALID_LISTING" })
        return
    end

    local scriptItem = getScriptItem(listing.itemFullType)
    local unitPrice = tonumber(listing.unitPrice)
    -- Quantity belongs to the listing: its price buys the complete
    -- configured bundle. Never trust a client-supplied quantity here.
    local totalAmount = unitPrice

    if not scriptItem
        or not totalAmount
        or totalAmount <= 0
        or totalAmount > 1000000000
    then
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            { success = false, reason = "LISTING_UNAVAILABLE", internal = true }
        )
        return
    end

    -- Reserve escrow before payment. If payment declines, the
    -- reservation is removed; this ordering avoids a charged player
    -- ever being left without a recoverable parcel.
    local username = getPlayerName(player)
    local currencyItemType = getInternalCurrencySettings()
    local currencyLabel = currencyItemType == "Base.Money"
        and "$"
        or currencyItemType
    local parcel = addParcel(username, {
        itemFullType = listing.itemFullType,
        displayName = listing.displayName or listing.itemFullType,
        quantity = quantity,
        currency = currencyLabel,
        unitPrice = unitPrice,
        providerId = "KIPN_INTERNAL",
        internalListingId = listingId,
        escrowed = true,
        createdAtMs = type(getTimestampMs) == "function"
            and getTimestampMs()
            or 0,
    })

    if not parcel then
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            { success = false, reason = "PARCEL_PERSIST_FAILED", internal = true }
        )
        return
    end

    local charged, chargeReason, payment =
        MarketplaceService.ChargeInternalPurchase(
            player,
            totalAmount,
            "KIPN Marketplace purchase: "
                .. tostring(listing.displayName or listing.itemFullType)
                .. " x" .. tostring(quantity)
        )

    if not charged then
        removeParcel(username, parcel.id)
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            { success = false, reason = chargeReason or "DECLINED", internal = true }
        )
        return
    end

    parcel.payment = payment

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
        { success = true, item = parcel, internal = true, payment = payment }
    )

    log(
        "Internal purchase escrowed: player=" .. username
        .. " listing=" .. listingId
        .. " item=" .. tostring(listing.itemFullType)
        .. " x" .. tostring(quantity)
        .. " parcelId=" .. tostring(parcel.id)
    )
end

------------------------------------------------------------
-- COMMAND: PURCHASE_MARKETPLACE_ITEM
------------------------------------------------------------

local function handlePurchaseMarketplaceItem(player, args)

    args =
        args or {}

    local activeProviderId =
        getActiveProviderId()

    if activeProviderId == KIPN.Shared.MarketplaceProviders.NONE then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = "NO_PROVIDER_CONFIGURED",
            }
        )

        return
    end

    if args.providerId ~= activeProviderId then

        log(
            "Rejected purchase: client providerId="
            .. tostring(args.providerId)
            .. " does not match active provider="
            .. tostring(activeProviderId)
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = "PROVIDER_MISMATCH",
            }
        )

        return
    end

    local capabilities =
        KIPN.Shared.MarketplaceProviderCapabilities
        and KIPN.Shared.MarketplaceProviderCapabilities[activeProviderId]

    if type(capabilities) ~= "table"
        or capabilities.escrowCheckout ~= true
        or capabilities.deliveryMode
            ~= KIPN.Shared.MarketplaceDeliveryModes.EXPLICIT_KIPN_ESCROW
    then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = "ESCROW_CHECKOUT_NOT_SUPPORTED",
            }
        )

        return
    end

    local ledger =
        MarketplaceService.Ledgers[activeProviderId]

    if not ledger then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = "PROVIDER_NOT_SUPPORTED",
            }
        )

        return
    end

    local item =
        args.item

    local quantity =
        math.max(
            1,
            math.floor(
                tonumber(args.quantity) or 1
            )
        )

    if type(item) ~= "table"
        or type(item.itemFullType) ~= "string"
        or item.itemFullType == ""
        or type(item.currency) ~= "string"
        or item.currency == ""
        or type(item.unitPrice) ~= "number"
        or item.unitPrice <= 0
    then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = "INVALID_ITEM",
            }
        )

        return
    end

    local totalAmount =
        item.unitPrice * quantity

    local reasonText =
        "KIPN Marketplace purchase: "
        .. tostring(item.displayName or item.itemFullType)
        .. " x"
        .. tostring(quantity)

    local ok, deductReason =
        ledger(
            player,
            item.currency,
            totalAmount,
            reasonText
        )

    if not ok then

        log(
            "Purchase declined by provider ledger ("
            .. tostring(activeProviderId)
            .. "): "
            .. tostring(deductReason)
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = deductReason or "DECLINED",
            }
        )

        return
    end

    local parcel =
        addParcel(
            getPlayerName(player),
            {
                itemFullType = item.itemFullType,
                displayName = item.displayName or item.itemFullType,
                quantity = quantity,
                currency = item.currency,
                unitPrice = item.unitPrice,
                providerId = activeProviderId,
                createdAtMs =
                    type(getTimestampMs) == "function"
                    and getTimestampMs()
                    or 0,
            }
        )

    if not parcel then

        logError(
            "Purchase charged but parcel could not be persisted for "
            .. getPlayerName(player)
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
            {
                success = false,
                reason = "PARCEL_PERSIST_FAILED",
            }
        )

        return
    end

    log(
        "Purchase complete: player="
        .. getPlayerName(player)
        .. " item="
        .. tostring(item.itemFullType)
        .. " x"
        .. tostring(quantity)
        .. " parcelId="
        .. tostring(parcel.id)
    )

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT,
        {
            success = true,
            item = parcel,
        }
    )
end

------------------------------------------------------------
-- COMMAND: GET_PARCELS
------------------------------------------------------------

local function handleGetParcels(player, _args)

    local parcels =
        getParcelsFor(
            getPlayerName(player)
        )

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PARCELS_DATA,
        parcels
    )
end

local function playerHasValidPOBoxKey(player)

    -- PO Box key lookup moved from Terminal's ArtifactService into
    -- this mod's KIPN_POBoxClaimService.lua.
    local artifacts = KIPN.Server.POBoxClaimService
    local claims = KIPN.Server.ClaimService

    if not artifacts
        or type(artifacts.FindPlayerPOBoxKeyItems) ~= "function"
        or not claims
        or type(claims.GetPlayerClaims) ~= "function"
    then
        return false
    end

    local heldTargets = {}
    for _, entry in ipairs(artifacts.FindPlayerPOBoxKeyItems(player) or {}) do
        if entry.boxId ~= nil then
            heldTargets[tostring(entry.boxId)] = true
        end
    end

    local poBoxType = claims.Types and claims.Types.PO_BOX or "po_box"

    for _, claim in pairs(claims.GetPlayerClaims(player) or {}) do
        if claim.type == poBoxType
            and claim.active ~= false
            and heldTargets[tostring(claim.targetId)]
        then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- COMMAND: COLLECT_PARCEL
--
-- Hands the parcel's item(s) directly to the player's inventory.
-- This is the point at which a queued marketplace purchase becomes
-- a physical item - deliberately triggered by the player (from the
-- Postal Services screen) rather than happening automatically, so
-- it behaves like checking a real PO Box rather than teleporting
-- loot into an offline player's bag.
------------------------------------------------------------

local function handleCollectParcel(player, args)

    args =
        args or {}

    local username =
        getPlayerName(player)

    local postOfficeType =
        KIPN.Server.WorldRegistry
        and KIPN.Server.WorldRegistry.ZoneTypes
        and KIPN.Server.WorldRegistry.ZoneTypes.POST_OFFICE
        or "post_office"

    if not isPlayerInZoneType(player, postOfficeType) then
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
            {
                success = false,
                reason = "PO_BOX_ZONE_REQUIRED",
            }
        )
        return
    end

    if not playerHasValidPOBoxKey(player) then
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
            {
                success = false,
                reason = "VALID_PO_BOX_KEY_REQUIRED",
            }
        )
        return
    end

    local parcelId =
        tonumber(args.parcelId)

    if not parcelId then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
            {
                success = false,
                reason = "INVALID_PARCEL",
            }
        )

        return
    end

    local removed, parcel =
        removeParcel(username, parcelId)

    if not removed or not parcel then

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
            {
                success = false,
                reason = "PARCEL_NOT_FOUND",
            }
        )

        return
    end

    local inventory =
        player:getInventory()

    if not inventory then
        addParcel(username, parcel)
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
            { success = false, reason = "INVENTORY_UNAVAILABLE" }
        )
        return
    end

    local quantity =
        parcel.quantity or 1

    local spawned =
        0

    for _ = 1, quantity do

        local ok, itemOrErr = pcall(function()
            local item = KIPN.Server.CreateItem(parcel.itemFullType)
            if not item then return nil end
            local added = inventory:AddItem(item)
            if not added then return nil end
            if type(sendAddItemToContainer) == "function" then
                sendAddItemToContainer(inventory, item)
            end
            return item
        end)

        if ok and itemOrErr then

            spawned =
                spawned + 1

        else

            logError(
                "CollectParcel: failed to spawn "
                .. tostring(parcel.itemFullType)
                .. ": "
                .. tostring(itemOrErr)
            )
        end
    end

    if spawned == 0 then

        -- Nothing could be spawned (e.g. the item type no longer
        -- exists after a mod update) - restore the parcel rather
        -- than silently destroying a paid-for purchase.
        addParcel(username, parcel)

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
            {
                success = false,
                reason = "SPAWN_FAILED",
            }
        )

        return
    end

    if spawned < quantity then
        local remainderParcel = {}
        for key, value in pairs(parcel) do
            if key ~= "id" then
                remainderParcel[key] = value
            end
        end
        remainderParcel.quantity = quantity - spawned
        addParcel(username, remainderParcel)
    end

    log(
        "Parcel collected: player="
        .. username
        .. " item="
        .. tostring(parcel.itemFullType)
        .. " spawned="
        .. tostring(spawned)
        .. "/"
        .. tostring(quantity)
    )

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PARCEL_COLLECTED,
        {
            success = true,
            parcel = parcel,
            spawned = spawned,
        }
    )

    handleGetParcels(player, {})
end

------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function MarketplaceService.Initialize()

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then

        logError(
            "KIPN.Server.RegisterCommandHandler() is unavailable; "
            .. "marketplace commands will not be reachable."
        )

        return false
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.PURCHASE_MARKETPLACE_ITEM,
        handlePurchaseMarketplaceItem
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_KIPN_MARKETPLACE_ITEMS,
        handleGetInternalMarketplaceItems
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.PURCHASE_KIPN_MARKETPLACE_ITEM,
        handlePurchaseInternalMarketplaceItem
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.SAVE_KIPN_MARKETPLACE_ITEM,
        handleSaveInternalMarketplaceItem
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.REMOVE_KIPN_MARKETPLACE_ITEM,
        handleRemoveInternalMarketplaceItem
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_PARCELS,
        handleGetParcels
    )

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.COLLECT_PARCEL,
        handleCollectParcel
    )

    log(
        "Marketplace Service initialized."
    )

    return true
end

------------------------------------------------------------
-- COMPLETE
------------------------------------------------------------

log(
    "KIPN Marketplace Service loaded."
)
