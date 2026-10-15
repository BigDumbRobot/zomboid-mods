-- KIPN_MarketplaceAdapter.lua
--
-- Marketplace provider adapter registry.
--
-- This is the CLIENT half of the KIPN <-> external economy mod
-- translation layer (see KIPN_MarketplaceEvents.lua for the
-- normalized events this layer speaks in, and
-- media/lua/server/KIPN_MarketplaceService.lua for the SERVER escrow
-- intake and generic KIPN-service fee ledger).
--
-- KIPN does NOT run its own marketplace. An admin selects ONE
-- installed provider mod via the KIPN.MarketplaceProvider sandbox
-- option; KIPN_Marketplace.lua then displays that provider's
-- catalog/balance as a SECONDARY DISPLAY.
--
-- IMPORTANT - WHERE PURCHASES ACTUALLY HAPPEN:
--
-- This client adapter is display-only. It does NOT drive a
-- a provider's own purchase pathway, because those pathways have no
-- notion of "deliver to a KIPN PO Box" unless they explicitly adopt
-- KIPN's escrow handoff.
--
-- Catalog/balance support never implies checkout support. A provider
-- must expose a separate authoritative escrow handoff before its
-- `capabilities.escrowCheckout` may be true. The supplied providers
-- currently remain read-only in KIPN because their delivery happens
-- inside provider-local handlers or an external bridge.
--
-- ADAPTER CONTRACT
--
-- A provider adapter is a plain table registered with
-- KIPN.MarketplaceAdapters.Register(adapter), where adapter has:
--
--   id            (string)   Must equal one of
--                             KIPN.Shared.MarketplaceProviders.*, and
--                             must have a matching entry in
--                             KIPN.Shared.MarketplaceProviderCapabilities
--                             (shared/KIPN_Shared.lua) - registration
--                             is refused otherwise.
--   label         (string)   Display name for UI/log messages.
--
--   isInstalled() -> boolean
--       Whether the provider mod's own client namespace is present
--       in this game session. False does not mean misconfigured -
--       the server may simply not have that mod loaded.
--
-- The remaining fields are required only when the provider's declared
-- capabilities call for them - Register() checks this and refuses
-- registration if a required field is missing for a capability the
-- provider claims:
--
--   requestCatalog(player)   -- required iff capabilities.catalog
--       Ask the provider (or read its already-synced client cache)
--       for its sellable items, then normalize and fire:
--         triggerEvent("KIPN_Marketplace_OnCatalogUpdated", items)
--       Normalized item shape - see KIPN_MarketplaceEvents.lua.
--       Each normalized row's .raw field must carry the provider's
--       native row so the server ledger adapter can log a
--       provider-meaningful purchase reason. Set `purchasable =
--       false` on any row backed by a real player seller rather
--       than system/admin stock - see the "NOT EVERY PROVIDER ...
--       IS PURCHASABLE" note in KIPN_Shared.lua for why, and
--       KIPN_MarketplaceAdapter_PZMarketplaceGES.lua for a worked
--       view-only example. A provider declared `capabilities.catalog
--       = false` (see KIPN_MarketplaceAdapter_GlocServerEconomy.lua)
--       need not implement this at all - KIPN_Marketplace.lua never
--       calls it.
--
--   getCachedBalance(player) -> amount, currencyLabel
--                            -- required iff capabilities.balance
--       Providers already keep their own balance in sync on their
--       own schedule (heartbeat / event push) - KIPN reads that
--       cache rather than requesting a duplicate round trip. May
--       also fire KIPN_Marketplace_OnBalanceUpdated itself when the
--       provider's own balance event fires, so the screen stays
--       live while open.
--
-- Register() stamps the resolved capability table onto the adapter
-- itself as `adapter.capabilities` - callers (KIPN_Marketplace.lua,
-- KIPN_GovernmentServices.lua, KIPN_PostalServices.lua) read that
-- rather than assuming every field exists.
--
-- To add a new compatible mod:
--   1. Add its id + declare its capabilities in
--      KIPN.Shared.MarketplaceProviderCapabilities
--      (shared/KIPN_Shared.lua).
--   2. Implement this contract in a new
--      media/lua/client/KIPN_MarketplaceAdapter_<Mod>.lua file that
--      ends with KIPN.MarketplaceAdapters.Register(adapter).
--   3. `deduct` may register a ledger for generic KIPN service fees;
--      it does not enable Marketplace checkout.
--   4. Set `escrowCheckout = true` only after implementing a native,
--      server-authoritative purchase-to-KIPN-escrow handoff.
-- Nothing in KIPN_Marketplace.lua needs to change.

if isServer() then
    return
end

require "KIPN_MarketplaceEvents"

if not KIPN then
    error(
        "[KIPN_MarketplaceAdapter] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then
    error(
        "[KIPN_MarketplaceAdapter] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then
    error(
        "[KIPN_MarketplaceAdapter] "
        .. "KIPN.Logger is not initialized."
    )
end

--------------------------------------------------------------------
-- REGISTRY
--------------------------------------------------------------------

KIPN.MarketplaceAdapters =
    KIPN.MarketplaceAdapters or {}

KIPN.MarketplaceAdapters.byId =
    KIPN.MarketplaceAdapters.byId or {}

local REQUIRED_FIELDS = {
    "id",
    "label",
    "isInstalled",
}

--------------------------------------------------------------------
-- REGISTER
--
-- The set of further-required fields is driven by the provider's
-- declared capabilities (KIPN.Shared.MarketplaceProviderCapabilities,
-- shared/KIPN_Shared.lua - the single source of truth also read by
-- server/KIPN_MarketplaceService.lua's RegisterLedger()). A provider
-- not declared there is a configuration error, not a provider that
-- happens to support nothing - registration is refused.
--------------------------------------------------------------------

function KIPN.MarketplaceAdapters.Register(adapter)

    if type(adapter) ~= "table" then

        KIPN.Logger.Error(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "adapter must be a table."
        )

        return false
    end

    for _, field in ipairs(REQUIRED_FIELDS) do

        local value = adapter[field]

        local ok =
            (field == "id" or field == "label")
                and type(value) == "string"
                and value ~= ""
            or type(value) == "function"

        if not ok then

            KIPN.Logger.Error(
                "KIPN.MarketplaceAdapters.Register(): "
                .. "adapter is missing required field '"
                .. tostring(field)
                .. "'."
            )

            return false
        end
    end

    local capabilities =
        KIPN.Shared.MarketplaceProviderCapabilities
        and KIPN.Shared.MarketplaceProviderCapabilities[adapter.id]

    if type(capabilities) ~= "table" then

        KIPN.Logger.Error(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "provider '"
            .. tostring(adapter.id)
            .. "' has no declared entry in "
            .. "KIPN.Shared.MarketplaceProviderCapabilities."
        )

        return false
    end

    if type(capabilities.escrowCheckout) ~= "boolean"
        or type(capabilities.deliveryMode) ~= "string"
        or capabilities.deliveryMode == ""
    then

        KIPN.Logger.Error(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "provider '"
            .. tostring(adapter.id)
            .. "' has an invalid escrow/delivery capability profile."
        )

        return false
    end

    if capabilities.escrowCheckout
        and capabilities.deliveryMode
            ~= KIPN.Shared.MarketplaceDeliveryModes.EXPLICIT_KIPN_ESCROW
    then

        KIPN.Logger.Error(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "provider '"
            .. tostring(adapter.id)
            .. "' enables escrowCheckout without declaring "
            .. "EXPLICIT_KIPN_ESCROW delivery."
        )

        return false
    end

    if capabilities.catalog
        and type(adapter.requestCatalog) ~= "function"
    then

        KIPN.Logger.Error(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "provider '"
            .. tostring(adapter.id)
            .. "' declares catalog capability but has no "
            .. "requestCatalog()."
        )

        return false
    end

    if capabilities.balance
        and type(adapter.getCachedBalance) ~= "function"
    then

        KIPN.Logger.Error(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "provider '"
            .. tostring(adapter.id)
            .. "' declares balance capability but has no "
            .. "getCachedBalance()."
        )

        return false
    end

    if KIPN.MarketplaceAdapters.byId[adapter.id] then

        KIPN.Logger.Warn(
            "KIPN.MarketplaceAdapters.Register(): "
            .. "provider '"
            .. tostring(adapter.id)
            .. "' is already registered; overwriting."
        )
    end

    adapter.capabilities =
        capabilities

    KIPN.MarketplaceAdapters.byId[adapter.id] = adapter

    return true
end

--------------------------------------------------------------------
-- RESOLVE THE ADMIN-SELECTED PROVIDER
--
-- Reads the KIPN.MarketplaceProvider sandbox enum and maps it
-- through KIPN.Shared.MarketplaceProviderOrder to a provider id -
-- the same mapping the server uses (see KIPN_MarketplaceService.lua)
-- so both realms always agree on which provider is active.
--------------------------------------------------------------------

function KIPN.MarketplaceAdapters.GetActiveProviderId()

    local order =
        KIPN.Shared.MarketplaceProviderOrder

    if type(order) ~= "table" then
        return KIPN.Shared.MarketplaceProviders.NONE
    end

    local index =
        SandboxVars
        and SandboxVars.KIPN
        and SandboxVars.KIPN.MarketplaceProvider

    if type(index) ~= "number" then
        return KIPN.Shared.MarketplaceProviders.NONE
    end

    return order[index]
        or KIPN.Shared.MarketplaceProviders.NONE
end

--------------------------------------------------------------------
-- GET ACTIVE ADAPTER
--
-- Returns:
--   adapter, nil                       on success
--   nil, "NO_PROVIDER_CONFIGURED"      admin left it on None
--   nil, "PROVIDER_NOT_SUPPORTED"      id has no registered adapter
--   nil, "PROVIDER_NOT_INSTALLED"      adapter registered, mod absent
--------------------------------------------------------------------

function KIPN.MarketplaceAdapters.GetActive()

    local providerId =
        KIPN.MarketplaceAdapters.GetActiveProviderId()

    if providerId == KIPN.Shared.MarketplaceProviders.NONE then
        return nil, "NO_PROVIDER_CONFIGURED"
    end

    local adapter =
        KIPN.MarketplaceAdapters.byId[providerId]

    if not adapter then
        return nil, "PROVIDER_NOT_SUPPORTED"
    end

    local ok, installed =
        pcall(adapter.isInstalled)

    if not ok or not installed then
        return nil, "PROVIDER_NOT_INSTALLED"
    end

    return adapter, nil
end

--------------------------------------------------------------------
-- INVENTORY CURRENCY ON HAND
--
-- Sums the player's physical currency, recursively through nested
-- containers (bags), so balance displays can add it on top of
-- whatever the active provider's own ledger reports (see
-- capabilities.balanceIsPhysicalInventory in
-- KIPN.Shared.MarketplaceProviderCapabilities, shared/KIPN_Shared
-- .lua, for the two providers where this would double-count and
-- must be skipped).
--
-- Always counts vanilla Base.Money (1 each) / Base.MoneyBundle (100
-- each) regardless of configuration, PLUS the server's configured
-- marketplace currency item (KIPN.MarketplaceCurrencyItemType /
-- MarketplaceCurrencyItemValue sandbox options) at its configured
-- value - matched in that priority order so a single item is never
-- counted twice, and so an admin override of Base.Money's own value
-- is honored when that is the configured currency type.
--
-- Display-only. Does NOT drive any purchase/charge path - see
-- server/KIPN_MarketplaceService.lua for the server-authoritative
-- equivalent used when actually spending currency.
--------------------------------------------------------------------

local VANILLA_MONEY_SINGLE_TYPE = "Base.Money"
local VANILLA_MONEY_BUNDLE_TYPE = "Base.MoneyBundle"
local VANILLA_MONEY_BUNDLE_VALUE = 100

local function getConfiguredCurrencySettings()

    local itemType =
        SandboxVars
        and SandboxVars.KIPN
        and SandboxVars.KIPN.MarketplaceCurrencyItemType

    if type(itemType) ~= "string"
        or itemType == ""
    then
        itemType = VANILLA_MONEY_SINGLE_TYPE
    end

    local itemValue =
        tonumber(
            SandboxVars
            and SandboxVars.KIPN
            and SandboxVars.KIPN.MarketplaceCurrencyItemValue
        )

    if not itemValue
        or itemValue < 1
    then
        itemValue = 1
    end

    return itemType, math.floor(itemValue)
end

function KIPN.MarketplaceAdapters.GetInventoryCurrencyOnHand(player)

    if not player then
        return 0
    end

    local ok, inventory =
        pcall(player.getInventory, player)

    if not ok or not inventory then
        return 0
    end

    local currencyItemType, currencyItemValue =
        getConfiguredCurrencySettings()

    local total = 0

    local function scan(container, depth)

        if not container
            or depth > 16
            or type(container.getItems) ~= "function"
        then
            return
        end

        local items =
            container:getItems()

        if not items then
            return
        end

        for i = 0, items:size() - 1 do

            local item =
                items:get(i)

            if item then

                local fullType =
                    item:getFullType()

                local value = nil

                if fullType == currencyItemType then
                    value = currencyItemValue
                elseif fullType == VANILLA_MONEY_SINGLE_TYPE then
                    value = 1
                elseif fullType == VANILLA_MONEY_BUNDLE_TYPE then
                    value = VANILLA_MONEY_BUNDLE_VALUE
                end

                if value then
                    total = total + value
                end

                local nestedOk, nested =
                    pcall(
                        function()

                            if item:IsInventoryContainer() then
                                return item:getInventory()
                            end

                            return nil
                        end
                    )

                if nestedOk and nested then
                    scan(nested, depth + 1)
                end
            end
        end
    end

    local scanOk, scanErr =
        pcall(scan, inventory, 0)

    if not scanOk then

        KIPN.Logger.Warn(
            "KIPN.MarketplaceAdapters.GetInventoryCurrencyOnHand(): "
            .. tostring(scanErr)
        )

        return 0
    end

    return total
end

--------------------------------------------------------------------
-- DISPLAY BALANCE
--
-- The single "what currency does this player have" figure every
-- KIPN screen shows (Main Menu header, Marketplace, Postal
-- Services, Government Services excavation tiers).
--
-- Definition:
--   * If an external marketplace/economy provider is connected and
--     declares capabilities.balance, start from its client-cached
--     ledger balance (adapter.getCachedBalance).
--   * Add the player's physical currency on hand
--     (GetInventoryCurrencyOnHand: vanilla Base.Money +
--     Base.MoneyBundle + the configured marketplace currency item,
--     recursively through bags) UNLESS the provider's own ledger
--     already IS that physical cash
--     (capabilities.balanceIsPhysicalInventory), which would
--     double-count.
--   * With no provider connected, the result is simply the
--     player's vanilla money (bills + bundles, inventory + bags).
--
-- Returns: total (number), currencyLabel (string or nil - the
-- provider's label when it has one; nil implies vanilla dollars).
--
-- Display-only. Never drives a charge - see
-- server/KIPN_MarketplaceService.lua for the authoritative spend.
--------------------------------------------------------------------

function KIPN.MarketplaceAdapters.GetDisplayBalance(player)

    player =
        player
        or (getPlayer and getPlayer())

    local adapter =
        KIPN.MarketplaceAdapters.GetActive
        and KIPN.MarketplaceAdapters.GetActive()

    local ledgerBalance = 0
    local currencyLabel = nil

    if adapter
        and adapter.capabilities
        and adapter.capabilities.balance
        and type(adapter.getCachedBalance) == "function"
    then

        local ok, amount, currency =
            pcall(adapter.getCachedBalance, player)

        if ok then
            ledgerBalance = amount or 0
            currencyLabel = currency
        end
    end

    local skipInventoryCurrency =
        adapter
        and adapter.capabilities
        and adapter.capabilities.balanceIsPhysicalInventory == true

    local inventoryCurrency = 0

    if not skipInventoryCurrency then
        inventoryCurrency =
            KIPN.MarketplaceAdapters.GetInventoryCurrencyOnHand(player)
            or 0
    end

    return ledgerBalance + inventoryCurrency, currencyLabel
end
