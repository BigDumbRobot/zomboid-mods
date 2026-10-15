-- KIPN_Marketplace.lua
--
-- Marketplace application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- This screen combines KIPN's server-owned, admin-supplied catalog
-- with a read-only view of whichever optional economy/marketplace
-- provider the admin selected. The two catalogs remain independent.
--
-- Responsibilities:
--   * Resolve the admin-selected marketplace provider adapter.
--   * Ask the adapter for that provider's catalog + balance.
--   * Display marketplace listings and player balance.
--   * Purchase KIPN listings through server-authoritative checkout.
--   * Expose external checkout only for a provider that explicitly
--     advertises an authoritative KIPN escrow handoff.
--   * Handle escrow purchase responses when such a provider exists.
--   * Provide navigation back to the main menu.
--
-- This module does NOT:
--   * create terminal chrome
--   * create terminal HOME / CLOSE controls
--   * register OnServerCommand
--   * manage UIManager membership
--   * perform proximity checks
--   * manage authentication sessions
--   * log the player out when the terminal closes
--   * implement a provider's own purchase pathway (see
--     KIPN_MarketplaceAdapter.lua for why - short version: that
--     pathway has no notion of "deliver to a KIPN PO Box")
--
-- Authentication persistence is intentional.
--
-- Closing the terminal or walking away from the computer does NOT
-- invalidate the player's KIPN session. The player must explicitly
-- log out to protect the account.
--
-- UI responsibilities are delegated to KIPN_UI.lua.

if isServer() then
    return
end

require "KIPN_UI"
require "KIPN_MarketplaceAdapter"
require "KIPN_MarketplaceAdminUI"

if not KIPN then
    error(
        "[KIPN_Marketplace] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then
    error(
        "[KIPN_Marketplace] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then
    error(
        "[KIPN_Marketplace] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then
    error(
        "[KIPN_Marketplace] "
        .. "KIPN_UI is not initialized."
    )
end

if not KIPN.MarketplaceAdapters then
    error(
        "[KIPN_Marketplace] "
        .. "KIPN_MarketplaceAdapter is not initialized."
    )
end

--------------------------------------------------------------------
-- RUNTIME CLOCK
--
-- Used by the loading-timeout check in update(). Not a logging
-- helper; do not remove.
--------------------------------------------------------------------

local function getRuntimeMs()

    if not _G.getTimestampMs then
        return 0
    end

    local ok, result =
        pcall(
            function()
                return _G.getTimestampMs()
            end
        )

    if ok and type(result) == "number" then
        return result
    end

    return 0
end

--------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------
--
-- KIPN.UI.CreateScreen() owns the common ISPanel derive/new
-- boilerplate for all child applications.
--------------------------------------------------------------------

KIPN_Marketplace =
    KIPN.UI.CreateScreen(
        "KIPN_Marketplace"
    )

--------------------------------------------------------------------
-- PROVIDER UNAVAILABLE MESSAGES
--------------------------------------------------------------------

local PROVIDER_UNAVAILABLE_MESSAGES = {

    NO_PROVIDER_CONFIGURED = {
        "NO MARKETPLACE CONFIGURED",
        "The server admin has not selected a marketplace "
            .. "provider (KIPN.MarketplaceProvider sandbox option).",
    },

    PROVIDER_NOT_SUPPORTED = {
        "UNSUPPORTED MARKETPLACE PROVIDER",
        "The configured marketplace provider has no KIPN "
            .. "adapter installed.",
    },

    PROVIDER_NOT_INSTALLED = {
        "MARKETPLACE PROVIDER OFFLINE",
        "The configured marketplace mod does not appear to be "
            .. "running on this server.",
    },
}

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------
--
-- IMPORTANT:
--
-- Server/adapter data is NOT requested here.
--
-- KIPN_Terminal controls application activation and calls onShow()
-- when this screen becomes active.
--
-- Keeping requests in onShow() prevents duplicate requests caused
-- by screen construction.
--
-- The normalized marketplace event subscriptions ARE installed
-- here, once, since this screen instance is created once and reused
-- across every onShow()/onHide() cycle for the life of the terminal.
--------------------------------------------------------------------

function KIPN_Marketplace:initialise()

    local success = false

    local ok, err =
        pcall(
            function()

                ISPanel.initialise(self)

                ----------------------------------------------------
                -- COMMON UI SETUP
                ----------------------------------------------------

                KIPN.UI.SetupScreen(self)

                ----------------------------------------------------
                -- SCREEN STATE
                ----------------------------------------------------

                self.listings = {}

                self.internalListings = {}

                self.providerListings = {}

                self.activeTab = "internal"

                self.internalLoading = false

                self.internalTimedOut = false

                self.internalCurrencyLabel = "$"

                self.internalZoneRequired = true

                self.internalPurchaseAllowedHere = false

                self.isMarketplaceAdmin = false

                self.loading = false

                self.timedOut = false

                self.timeoutTime = 0

                self.adapter = nil

                self.providerLabel = nil

                self.providerUnavailableReason = nil

                self.playerBalance = 0

                self.currencyLabel = nil

                self.scrollOffset = 0

                self.maxVisible = 10

                self.tableHitRects = {}

                ----------------------------------------------------
                -- BACK BUTTON
                ----------------------------------------------------

                self.backButton =
                    KIPN.UI.CreateButton(
                        self,
                        10,
                        self.height - 30,
                        100,
                        22,
                        "< BACK",
                        KIPN_Marketplace.onBackClick,
                        { fixed = true }
                    )

                ----------------------------------------------------
                -- ADMIN ITEMS BUTTON
                --
                -- Not created here. Conditionally created/destroyed
                -- by rebuildAdminItemsButton() -- mirrors
                -- KIPN_GovernmentServices.lua's rebuildViewWidgets()
                -- pattern (the safehouse/excavation craft buttons):
                -- a gated control only exists in the widget tree at
                -- all while eligible, rather than always existing
                -- and being toggled via :setVisible().
                ----------------------------------------------------

                self.adminItemsButton = nil

                ----------------------------------------------------
                -- NORMALIZED MARKETPLACE EVENTS
                --
                -- Installed once per screen instance. Each handler
                -- closes over `self` rather than relying on a
                -- global, so multiple terminals (if ever supported)
                -- would not cross-talk.
                ----------------------------------------------------

                if not self._marketplaceHandlersInstalled then

                    self._onCatalogUpdatedHandler =
                        function(items)
                            self:onCatalogUpdated(items)
                        end

                    self._onBalanceUpdatedHandler =
                        function(amount, currency)
                            self:onBalanceUpdated(amount, currency)
                        end

                    self._onProviderUnavailableHandler =
                        function(reason)
                            self:onProviderUnavailableEvent(reason)
                        end

                    Events.KIPN_Marketplace_OnCatalogUpdated.Add(
                        self._onCatalogUpdatedHandler
                    )

                    Events.KIPN_Marketplace_OnBalanceUpdated.Add(
                        self._onBalanceUpdatedHandler
                    )

                    Events.KIPN_Marketplace_OnProviderUnavailable.Add(
                        self._onProviderUnavailableHandler
                    )

                    self._marketplaceHandlersInstalled = true
                end

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Marketplace:initialise(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- CATALOG TABS
--------------------------------------------------------------------

function KIPN_Marketplace:createTabButtons()

    if self.adminShopTabButton or self.providerTabButton then
        return
    end

    local tabWidth =
        math.floor((self.width - 52) / 2)

    self.adminShopTabButton =
        KIPN.UI.CreateButton(
            self,
            20,
            84,
            tabWidth,
            24,
            "Admin Shop",
            function()
                self:setActiveTab("internal")
            end,
            { fixed = true }
        )

    self.providerTabButton =
        KIPN.UI.CreateButton(
            self,
            32 + tabWidth,
            84,
            tabWidth,
            24,
            "EXTERNAL MARKETPLACE",
            function()
                self:setActiveTab("provider")
            end,
            { fixed = true }
        )

    self.providerTabButton:setVisible(false)
    self:updateTabButtonStyles()
end

function KIPN_Marketplace:rebuildListings()

    self.listings = {}

    if self.activeTab == "provider" then
        for _, item in ipairs(self.providerListings or {}) do
            item.source = item.source or "EXTERNAL"
            self.listings[#self.listings + 1] = item
        end
    else
        for _, item in ipairs(self.internalListings or {}) do
            item.source = "KIPN"
            item.currency = item.currency or self.internalCurrencyLabel or "$"
            self.listings[#self.listings + 1] = item
        end
    end

    self.scrollOffset = 0
end

function KIPN_Marketplace:setActiveTab(tab)

    if tab == "provider" and not self.adapter then
        tab = "internal"
    end

    if tab ~= "provider" then
        tab = "internal"
    end

    if self.activeTab == tab then
        self:updateTabButtonStyles()
        self:rebuildAdminItemsButton()
        return
    end

    self.activeTab = tab
    self.tableHitRects = {}
    self:rebuildListings()
    self:updateTabButtonStyles()
    self:rebuildAdminItemsButton()
end

function KIPN_Marketplace:updateTabButtonStyles()

    local activeColor = KIPN.UI.Theme.accent
    local inactiveColor =
        KIPN.UI.Theme.button
        and KIPN.UI.Theme.button.background

    if self.adminShopTabButton then
        self.adminShopTabButton.backgroundColor =
            self.activeTab == "internal"
            and activeColor
            or inactiveColor
    end

    if self.providerTabButton then
        self.providerTabButton.backgroundColor =
            self.activeTab == "provider"
            and activeColor
            or inactiveColor
    end
end

--------------------------------------------------------------------
-- REBUILD ADMIN ITEMS BUTTON
--
-- Mirrors KIPN_GovernmentServices.lua's rebuildViewWidgets(): the
-- eligible control is destroyed and recreated from scratch on every
-- state transition (onShow, tab switch, catalog response) rather
-- than persisting one instance and toggling :setVisible() on it.
-- Call sites are the same points that previously called
-- updateAdminItemsButtonVisibility().
--------------------------------------------------------------------

function KIPN_Marketplace:rebuildAdminItemsButton()

    if self.adminItemsButton then
        self:removeChild(self.adminItemsButton)
        self.adminItemsButton = nil
    end

    local visible =
        self.isMarketplaceAdmin == true
        and self.activeTab == "internal"

    KIPN.Logger.Info(
        "KIPN_Marketplace:rebuildAdminItemsButton(): "
        .. "isMarketplaceAdmin=" .. tostring(self.isMarketplaceAdmin)
        .. " activeTab=" .. tostring(self.activeTab)
        .. " -> visible=" .. tostring(visible)
    )

    if not visible then
        return
    end

    self.adminItemsButton =
        KIPN.UI.CreateButton(
            self,
            130,
            self.height - 30,
            250,
            22,
            "ADD KIPN MARKETPLACE ITEMS",
            KIPN_Marketplace.onAdminItemsClick,
            { fixed = true }
        )
end

--------------------------------------------------------------------
-- SHOW
--
-- Called by KIPN_Terminal when this application becomes active.
--
-- A new request is made each time the application is shown.
--------------------------------------------------------------------

function KIPN_Marketplace:onShow()

    local success = false

    local ok, err =
        pcall(
            function()

                self:createTabButtons()

                ----------------------------------------------------
                -- RESET APPLICATION STATE
                ----------------------------------------------------

                self.listings = {}

                self.internalListings = {}

                self.providerListings = {}

                self.activeTab = "internal"

                self.scrollOffset = 0

                self.tableHitRects = {}

                self.providerUnavailableReason = nil

                self.isMarketplaceAdmin = false

                self.internalPurchaseAllowedHere = false

                self:rebuildAdminItemsButton()

                if self.providerTabButton then
                    self.providerTabButton:setVisible(false)
                    self.providerTabButton:setTitle("EXTERNAL MARKETPLACE")
                end

                self:updateTabButtonStyles()

                self.loading = true

                self.internalLoading = true

                self.timedOut = false

                self.internalTimedOut = false

                self.timeoutTime =
                    getRuntimeMs()
                    + 5000

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_KIPN_MARKETPLACE_ITEMS,
                    {}
                )

                ----------------------------------------------------
                -- RESOLVE ACTIVE MARKETPLACE PROVIDER
                ----------------------------------------------------

                local adapter, reason =
                    KIPN.MarketplaceAdapters.GetActive()

                self.adapter = adapter

                if not adapter then

                    self.loading = false

                    self.providerLabel = "None"

                    KIPN.Logger.Warn(
                        "KIPN_Marketplace:onShow(): "
                        .. "no active external marketplace provider ("
                        .. tostring(reason or "NO_PROVIDER_CONFIGURED")
                        .. "); KIPN internal listings remain available"
                    )

                    success = true

                    return
                end

                self.providerLabel =
                    adapter.label

                if self.providerTabButton then
                    self.providerTabButton:setTitle(
                        tostring(adapter.label or "External Marketplace")
                    )
                    self.providerTabButton:setVisible(true)
                end

                ----------------------------------------------------
                -- REQUEST CATALOG + BALANCE
                --
                -- Gated by the provider's declared capabilities
                -- (KIPN.Shared.MarketplaceProviderCapabilities,
                -- stamped onto the adapter as adapter.capabilities
                -- by KIPN.MarketplaceAdapters.Register()) rather than
                -- assuming every adapter supports both.
                ----------------------------------------------------

                local player =
                    getPlayer()

                local capabilities =
                    adapter.capabilities
                    or {}

                if capabilities.balance then

                    local amount, currency =
                        adapter.getCachedBalance(player)

                    self.playerBalance =
                        amount or 0

                    self.currencyLabel =
                        currency
                end

                if capabilities.catalog then

                    adapter.requestCatalog(player)

                else

                    -- No catalog to wait for - stop "loading" now
                    -- rather than sitting until the 5s timeout.
                    self.providerListings = {}

                    self.loading = false
                end

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Marketplace:onShow(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- BACK
--------------------------------------------------------------------

function KIPN_Marketplace:onBackClick()

    local success = false

    local ok, err =
        pcall(
            function()

                local parent =
                    self:getParent()

                if parent and parent.setScreen then

                    parent:setScreen(
                        KIPN_MainMenu
                    )

                    success = true

                    return
                end
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Marketplace:onBackClick(): "
            .. tostring(err)
        )
    end

end

function KIPN_Marketplace:onAdminItemsClick()

    if self.isMarketplaceAdmin
        and KIPN_MarketplaceAdminUI
        and KIPN_MarketplaceAdminUI.Open
    then
        KIPN_MarketplaceAdminUI.Open()
    end
end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------
--
-- Only meaningful state transitions are logged.
--
-- Do NOT emit a Meta Time Run Log every frame.
--------------------------------------------------------------------

function KIPN_Marketplace:update()

    ISPanel.update(self)

    if not self.loading
        and not self.internalLoading
    then
        return
    end

    if getRuntimeMs() < self.timeoutTime then
        return
    end

    if self.loading then
        self.loading = false
        self.timedOut = true
    end

    if self.internalLoading then
        self.internalLoading = false
        self.internalTimedOut = true
    end

    KIPN.Logger.Warn(
        "KIPN_Marketplace:update(): "
        .. "marketplace catalog request timed out"
    )
end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_Marketplace:prerender()

    ISPanel.prerender(self)

    ---------------------------------------------------------------
    -- COMMON CRT EFFECTS
    ---------------------------------------------------------------

    KIPN.UI.DrawScanlines(self)

    ---------------------------------------------------------------
    -- BANNER
    ---------------------------------------------------------------

    local y =
        KIPN.UI.DrawBanner(
            self,
            "MARKETPLACE"
        )

    -- Reserve the fixed tab-button row at y=84.
    y = y + 42

    ---------------------------------------------------------------
    -- PROVIDER UNAVAILABLE
    ---------------------------------------------------------------

    if self.activeTab == "provider"
        and self.providerUnavailableReason
    then

        local message =
            PROVIDER_UNAVAILABLE_MESSAGES[
                self.providerUnavailableReason
            ]
            or PROVIDER_UNAVAILABLE_MESSAGES.PROVIDER_NOT_SUPPORTED

        KIPN.UI.DrawStatusMessage(
            self,
            "empty",
            message[1],
            message[2]
        )

        return
    end

    ---------------------------------------------------------------
    -- ACTIVE TAB SUMMARY
    ---------------------------------------------------------------

    if self.activeTab == "provider" then

        -- Provider-agnostic spendable currency: the connected
        -- provider's ledger plus physical vanilla money and money
        -- bundles in the inventory and bags (skipped when the
        -- provider's own ledger already IS that physical cash). See
        -- KIPN.MarketplaceAdapters.GetDisplayBalance. self.playerBalance
        -- stays the ledger-only figure the purchase math below needs.
        local displayBalance =
            KIPN.MarketplaceAdapters.GetDisplayBalance(getPlayer())
            or 0

        self:drawText(
            "PROVIDER: "
                .. tostring(self.providerLabel or "---")
                .. "   BALANCE: "
                .. tostring(displayBalance)
                .. " "
                .. tostring(self.currencyLabel or ""),
            20,
            y,
            KIPN.UI.Theme.dimText.r,
            KIPN.UI.Theme.dimText.g,
            KIPN.UI.Theme.dimText.b,
            KIPN.UI.Theme.dimText.a,
            KIPN.UI.Theme.fontBody
        )

    else

        self:drawText(
            "ADMIN SHOP   CURRENCY: "
                .. tostring(self.internalCurrencyLabel or "$"),
            20,
            y,
            KIPN.UI.Theme.dimText.r,
            KIPN.UI.Theme.dimText.g,
            KIPN.UI.Theme.dimText.b,
            KIPN.UI.Theme.dimText.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 25

        self:drawText(
            self.internalZoneRequired
                and (self.internalPurchaseAllowedHere
                    and "KIPN SHOP ZONE: VERIFIED"
                    or "KIPN SHOP ZONE: REQUIRED")
                or "KIPN SHOP ZONE: NOT REQUIRED",
            20,
            y,
            self.internalPurchaseAllowedHere and 0.3 or 0.8,
            self.internalPurchaseAllowedHere and 1.0 or 0.7,
            0.4,
            1,
            KIPN.UI.Theme.fontBody
        )
    end

    if not self.hasPOBox then
        y = y + 25
        self:drawText(
            "PO BOX REQUIRED FOR PURCHASE",
            20,
            y,
            KIPN.UI.Theme.warning.r,
            KIPN.UI.Theme.warning.g,
            KIPN.UI.Theme.warning.b,
            1,
            KIPN.UI.Theme.fontBody
        )
    end

    y = y + 20

    y =
        KIPN.UI.DrawDivider(
            self,
            y,
            15
        )

    y = y + 15

    ---------------------------------------------------------------
    -- LOADING
    ---------------------------------------------------------------

    local activeLoading = self.internalLoading

    if self.activeTab == "provider" then
        activeLoading = self.loading
    end

    if activeLoading then

        KIPN.UI.DrawStatusMessage(
            self,
            "loading",
            self.activeTab == "provider"
                and "SEARCHING MARKETPLACE LISTINGS..."
                or "LOADING ADMIN SHOP...",
            self.activeTab == "provider"
                and ("Contacting " .. tostring(self.providerLabel or "provider") .. "...")
                or "Requesting KIPN's server-owned catalog..."
        )

        return
    end

    ---------------------------------------------------------------
    -- NO CATALOG CAPABILITY
    --
    -- Structural, not transient - distinct from "NO LISTINGS" below,
    -- which means the provider CAN have a catalog but currently has
    -- zero rows. See KIPN_MarketplaceAdapter_GlocServerEconomy.lua.
    ---------------------------------------------------------------

    if self.activeTab == "provider"
        and self.adapter
        and self.adapter.capabilities
        and not self.adapter.capabilities.catalog
    then

        KIPN.UI.DrawStatusMessage(
            self,
            "empty",
            "NO CATALOG FOR THIS PROVIDER",
            tostring(self.providerLabel or "This provider")
                .. " has no browsable catalog. Balance shown above "
                .. "is still live."
        )

        return
    end

    ---------------------------------------------------------------
    -- TIMEOUT
    ---------------------------------------------------------------

    local activeTimedOut = self.internalTimedOut

    if self.activeTab == "provider" then
        activeTimedOut = self.timedOut
    end

    if activeTimedOut
        and #self.listings == 0 then

        KIPN.UI.DrawStatusMessage(
            self,
            "timeout",
            "SEARCH TIMED OUT",
            self.activeTab == "provider"
                and "No response from marketplace provider."
                or "No response from the KIPN marketplace service."
        )

        return
    end

    ---------------------------------------------------------------
    -- NO LISTINGS
    ---------------------------------------------------------------

    if #self.listings == 0 then

        KIPN.UI.DrawStatusMessage(
            self,
            "empty",
            self.activeTab == "provider"
                and "NO PROVIDER LISTINGS FOUND"
                or "NO ADMIN SHOP ITEMS FOUND",
            self.activeTab == "provider"
                and "No active listings are available from this marketplace."
                or "An administrator has not listed any KIPN items yet."
        )

        return
    end

    ---------------------------------------------------------------
    -- TABLE
    ---------------------------------------------------------------

    local columns = {

        {
            label = "ITEM",
            width = 165
        },

        {
            label = "QUANTITY",
            width = 65
        },

        {
            label = "PRICE",
            width = 85
        },

        {
            label = "CURRENCY",
            width = 80
        },

        {
            label = "SELLER",
            width = 110
        },

        {
            label = "STATUS",
            width = 125
        },
    }

    local rows = {}

    local startIndex =
        self.scrollOffset + 1

    local endIndex =
        math.min(
            self.scrollOffset + self.maxVisible,
            #self.listings
        )

    for i = startIndex, endIndex do

        local item =
            self.listings[i]

        local escrowCheckout =
            (item.source == "KIPN"
                and item.purchasable ~= false)
            or (
                self.adapter
                and self.adapter.capabilities
                and self.adapter.capabilities.escrowCheckout == true
                and item.purchasable ~= false
            )

        -- Vehicle listings are delivered by spawning the vehicle next
        -- to the buyer, not via a PO Box parcel, so they never need a
        -- PO Box.
        local isVehicle = item.kind == "vehicle"
        local requiresPOBox =
            ((item.source == "KIPN") or escrowCheckout)
            and not isVehicle
        local disabled = requiresPOBox and not self.hasPOBox

        rows[#rows + 1] = {
            disabled = disabled,

            tostring(
                item.displayName
                or "Unknown"
            ),

            tostring(isVehicle and 1 or (item.quantity or 1)),

            tostring(
                item.unitPrice
                or 0
            ),

            tostring(
                item.currency
                or ""
            ),

            tostring(
                item.seller
                or "Unknown"
            ),

            isVehicle
                and "BUY / DRIVE OFF"
                or (escrowCheckout
                    and (item.source == "KIPN" and "BUY / PO BOX" or "PO BOX")
                    or "EXTERNAL"),
        }
    end

    self.tableHitRects =
        KIPN.UI.DrawTable(
            self,
            20,
            y,
            columns,
            rows,
            25
        )

    ---------------------------------------------------------------
    -- FOOTER
    ---------------------------------------------------------------

    local footerY =
        self.height - 65

    KIPN.UI.DrawDivider(
        self,
        footerY,
        15
    )

    local footerText =
        "KIPN items are purchased here and sent to escrow. Collect them at a Post Office with your PO Box key."

    if self.activeTab == "provider" then
        footerText =
            self.adapter
            and self.adapter.capabilities
            and self.adapter.capabilities.escrowCheckout == true
            and "This provider supports KIPN PO Box escrow checkout."
            or "External marketplace view. Complete purchases in the provider's own interface."
    end

    self:drawText(
        footerText,
        20,
        footerY + 20,
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    self:drawText(
        string.format(
            "Listings: %d",
            #self.listings
        ),
        self.width - 150,
        footerY + 20,
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )
end

--------------------------------------------------------------------
-- MOUSE
--------------------------------------------------------------------

function KIPN_Marketplace:onMouseDown(x, y)

    if (self.activeTab == "provider" and self.loading)
        or (self.activeTab == "internal" and self.internalLoading)
    then
        return false
    end

    if not self.tableHitRects then
        return false
    end

    for _, hitRect in ipairs(self.tableHitRects) do

        if y >= hitRect.y1
            and y < hitRect.y2 then

            local index =
                self.scrollOffset
                + hitRect.index

            if index <= #self.listings then

                local item = self.listings[index]
                local escrowCheckout =
                    (item.source == "KIPN" and item.purchasable ~= false)
                    or (
                        self.adapter
                        and self.adapter.capabilities
                        and self.adapter.capabilities.escrowCheckout == true
                        and item.purchasable ~= false
                    )

                local requiresPOBox =
                    ((item.source == "KIPN") or escrowCheckout)
                    and item.kind ~= "vehicle"

                if requiresPOBox and not self.hasPOBox then
                    local player = getPlayer()
                    if player then
                        player:Say("Purchase unavailable: KIPN PO Box required.")
                    end
                else
                    self:buyItem(index)
                end

            end

            return true
        end
    end

    return false
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--------------------------------------------------------------------

function KIPN_Marketplace:onMouseWheel(delta)

    local maxOffset =
        math.max(
            0,
            #self.listings - self.maxVisible
        )

    self.scrollOffset =
        math.max(
            0,
            math.min(
                self.scrollOffset - delta,
                maxOffset
            )
        )

    return true
end

--------------------------------------------------------------------
-- KEY PRESS
--------------------------------------------------------------------
--
-- Keyboard navigation remains intentionally unused.
--
-- ESC is owned by KIPN_Terminal.
--------------------------------------------------------------------

function KIPN_Marketplace:onKeyPress(key)

    return false
end

--------------------------------------------------------------------
-- CATALOG / BALANCE EVENT HANDLERS
--
-- Normalized events fired by the active provider adapter. See
-- KIPN_MarketplaceEvents.lua.
--------------------------------------------------------------------

function KIPN_Marketplace:onCatalogUpdated(items)

    if type(items) == "table" then

        self.providerListings =
            items

    else

        self.providerListings = {}

    end

    self:rebuildListings()

    self.loading = false

    self.timedOut = false

    self.scrollOffset = 0

end

function KIPN_Marketplace:onBalanceUpdated(amount, currency)

    self.playerBalance =
        amount or 0

    self.currencyLabel =
        currency
        or self.currencyLabel

end

function KIPN_Marketplace:onProviderUnavailableEvent(reason)

    self.loading = false

    self.timedOut = false

    self.providerUnavailableReason =
        reason
        or "PROVIDER_NOT_INSTALLED"

    self.providerListings = {}
    self:rebuildListings()

    KIPN.Logger.Warn(
        "KIPN_Marketplace: provider unavailable: "
        .. tostring(self.providerUnavailableReason)
    )
end

--------------------------------------------------------------------
-- PURCHASE
--
-- Reserved for a provider which explicitly implements authoritative
-- escrow checkout. All supplied providers are read-only here, so
-- this function exits with provider-interface guidance before
-- sending a command.
--------------------------------------------------------------------

function KIPN_Marketplace:buyItem(index)

    local success = false

    local ok, err =
        pcall(
            function()

                local item =
                    self.listings[index]

                if not item then

                    KIPN.Logger.Warn(
                        "KIPN_Marketplace:buyItem(): "
                        .. "listing not found"
                    )

                    return
                end

                if item.source == "KIPN" then
                    sendClientCommand(
                        "KIPN",
                        KIPN.Shared.Commands.PURCHASE_KIPN_MARKETPLACE_ITEM,
                        {
                            listingId = item.id,
                        }
                    )

                    success = true
                    return
                end

                if not self.adapter then

                    KIPN.Logger.Warn(
                        "KIPN_Marketplace:buyItem(): "
                        .. "no active marketplace provider"
                    )

                    return
                end

                -- Fail closed. A readable catalog and a usable
                -- ledger do not mean KIPN can replace delivery.
                -- Checkout is exposed only when the provider has an
                -- authoritative purchase integration that explicitly
                -- hands fulfillment to KIPN escrow.
                local escrowCheckout =
                    self.adapter.capabilities
                    and self.adapter.capabilities.escrowCheckout == true

                if item.purchasable == false
                    or not escrowCheckout then

                    local viewOnlyPlayer =
                        getPlayer()

                    if viewOnlyPlayer then

                        viewOnlyPlayer:Say(
                            "KIPN is displaying this listing read-only. "
                            .. "Complete the purchase through "
                            .. tostring(
                                self.providerLabel
                                or "its own interface"
                            )
                            .. "."
                        )
                    end

                    success = true

                    return
                end

                local raw =
                    item.raw
                    or {}

                local player =
                    getPlayer()

                if player then

                    player:Say(
                        "Purchasing: "
                        .. tostring(item.displayName)
                        .. " for "
                        .. tostring(item.unitPrice)
                        .. " "
                        .. tostring(item.currency)
                    )
                end

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.PURCHASE_MARKETPLACE_ITEM,
                    {
                        providerId = self.adapter.id,

                        quantity = 1,

                        item = {
                            sourceId = item.id,
                            itemFullType = raw.itemFullType,
                            kind = raw.kind,
                            displayName = item.displayName,
                            unitPrice = item.unitPrice,
                            currency = item.currency,
                        },
                    }
                )

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Marketplace:buyItem(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SERVER RESPONSE
--
-- The terminal is the sole OnServerCommand listener.
--
-- KIPN_Terminal routes:
--
--   event
--   data
--
-- to this function. This is KIPN's OWN server responding to
-- PURCHASE_MARKETPLACE_ITEM - never the provider mod's response,
-- which this screen never subscribes to directly (that translation
-- happens inside the active adapter; see onCatalogUpdated /
-- onBalanceUpdated / onProviderUnavailableEvent above).
--------------------------------------------------------------------

function KIPN_Marketplace:receiveResponse(
    event,
    data
)

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- KIPN INTERNAL CATALOG
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.KIPN_MARKETPLACE_ITEMS_DATA
                then
                    local payload = type(data) == "table" and data or {}
                    self.internalListings = type(payload.items) == "table"
                        and payload.items
                        or {}
                    self.internalCurrencyLabel = payload.currency or "$"
                    self.internalZoneRequired = payload.zoneRequired ~= false
                    self.internalPurchaseAllowedHere =
                        payload.purchaseAllowedHere == true
                        or self.internalZoneRequired == false
                    self.isMarketplaceAdmin = payload.isAdmin == true
                    self.hasPOBox = payload.hasPOBox == true

                    self.internalLoading = false
                    self.internalTimedOut = false

                    self:rebuildAdminItemsButton()

                    self:rebuildListings()
                    success = true
                    return
                end

                ----------------------------------------------------
                -- MARKETPLACE PURCHASE RESULT
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.MARKETPLACE_PURCHASE_RESULT then

                    if data
                        and data.success then

                        KIPN.Logger.Info(
                            "KIPN_Marketplace: purchase complete: "
                            .. tostring(
                                data.item
                                and data.item.displayName
                            )
                        )

                        local player =
                            getPlayer()

                        if player then

                            if data.vehicle then
                                player:Say(
                                    data.keyDelivered == false
                                        and "Vehicle purchased. It is parked nearby (no key issued -- you will need to hotwire it)."
                                        or "Vehicle purchased. It is parked nearby and the key is in your inventory."
                                )
                            else
                                player:Say(
                                    "Purchase complete. Check your PO Box."
                                )
                            end
                        end

                        ------------------------------------------------
                        -- REFRESH CATALOG + BALANCE FROM THE PROVIDER
                        ------------------------------------------------

                        if self.adapter then

                            local capabilities =
                                self.adapter.capabilities
                                or {}

                            if capabilities.catalog
                                and self.adapter.requestCatalog
                            then
                                self.adapter.requestCatalog(player)
                            end

                            if capabilities.balance
                                and self.adapter.getCachedBalance
                            then

                                local amount, currency =
                                    self.adapter.getCachedBalance(player)

                                self.playerBalance =
                                    amount or 0

                                self.currencyLabel =
                                    currency
                            end

                        end

                        sendClientCommand(
                            "KIPN",
                            KIPN.Shared.Commands.GET_KIPN_MARKETPLACE_ITEMS,
                            {}
                        )

                    else

                        KIPN.Logger.Warn(
                            "KIPN_Marketplace: "
                            .. "purchase failed: "
                            .. tostring(
                                data
                                and data.reason
                            )
                        )

                        local player =
                            getPlayer()

                        if player then

                            local reason =
                                data
                                and data.reason
                                or "UNKNOWN"

                            local message =
                                "Purchase failed: "
                                .. tostring(reason)

                            if reason == "MARKETPLACE_ZONE_REQUIRED" then
                                message = "This purchase requires a KIPN Marketplace zone."
                            elseif reason == "INSUFFICIENT_CURRENCY"
                                or reason == "INSUFFICIENT_BALANCE"
                            then
                                message = "Purchase failed: insufficient inventory currency and marketplace balance."
                            elseif reason == "NO_SPACE_FOR_VEHICLE" then
                                message = "No clear ground nearby to deliver the vehicle. Move to an open outdoor area and try again."
                            elseif reason == "ALREADY_IN_VEHICLE" then
                                message = "Get out of your current vehicle before buying another."
                            elseif reason == "VEHICLE_SALES_DISABLED" then
                                message = "Vehicle sales are disabled on this server."
                            elseif reason == "VEHICLE_SPAWN_FAILED" then
                                message = "The vehicle could not be delivered. You have not been charged."
                            end

                            player:Say(
                                message
                            )
                        end

                    end

                    success = true

                    return
                end

                ----------------------------------------------------
                -- SERVER ERROR
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.ERROR then

                    local message =
                        data

                    if type(data) == "table" then

                        message =
                            data.message
                            or data.reason
                            or "Unknown server error"

                    end

                    local player =
                        getPlayer()

                    if player then

                        player:Say(
                            "ERROR: "
                            .. tostring(message)
                        )

                    end

                    KIPN.Logger.Error(
                        "KIPN_Marketplace: "
                        .. "server error: "
                        .. tostring(message)
                    )

                    success = true

                    return
                end

                ----------------------------------------------------
                -- UNHANDLED RESPONSE
                ----------------------------------------------------

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Marketplace:receiveResponse(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- NEW
--
-- KIPN.UI.CreateScreen() already supplies the standard :new()
-- implementation.
--
-- No local :new() is required.
--------------------------------------------------------------------
