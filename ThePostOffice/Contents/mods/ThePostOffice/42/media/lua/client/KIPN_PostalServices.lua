-- KIPN_PostalServices.lua
--
-- PO Box management application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- Responsibilities:
--   * Request PO Box records from the server.
--   * Request player balance data from the server.
--   * Request pending marketplace parcels from the server.
--   * Display PO Box records.
--   * Display player balance.
--   * Display and collect pending marketplace parcels.
--   * Handle PO Box purchase requests.
--   * Handle postal-service responses.
--   * Provide point-and-click PO Box selection and PURCHASE controls.
--
-- Pending parcels are queued marketplace purchases (see
-- KIPN_Marketplace.lua and media/lua/server/
-- KIPN_MarketplaceService.lua) waiting to be collected here - this
-- is the actual "PO Box delivery" half of KIPN's marketplace
-- integration.
--
-- This module does NOT:
--   * create terminal chrome
--   * create HOME / CLOSE / BACK controls
--   * register OnServerCommand
--   * manage UIManager membership
--   * perform proximity checks
--   * manage authentication sessions
--   * log the player out when the terminal closes
--   * own terminal navigation
--
-- Terminal navigation is owned by KIPN_Terminal.
--
-- Authentication persistence is intentional.
--
-- Closing the terminal or walking away from the computer does NOT
-- invalidate the player's KIPN session. The player must explicitly
-- log out to protect the account.
--
-- Shared visual responsibilities are delegated to KIPN_UI.lua.

if isServer() then
    return
end

require "ISUI/ISPanel"
require "ISUI/ISComboBox"
require "ISUI/ISModalDialog"
require "KIPN_UI"

if not KIPN then

    error(
        "[KIPN_PostalServices] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then

    error(
        "[KIPN_PostalServices] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then

    error(
        "[KIPN_PostalServices] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then

    error(
        "[KIPN_PostalServices] "
        .. "KIPN_UI is not initialized."
    )
end

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

local function findAvailablePOBox(poBoxes, boxNumber)
    local wanted = tonumber(boxNumber)

    if not wanted then return nil end

    for _, box in ipairs(poBoxes or {}) do
        if tonumber(box.number) == wanted and not box.owner then
            return box
        end
    end

    return nil
end

--------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------
--
-- KIPN.UI.CreateScreen() owns the common ISPanel derive/new
-- boilerplate for all child applications.
--------------------------------------------------------------------

KIPN_PostalServices =
    KIPN.UI.CreateScreen(
        "KIPN_PostalServices"
    )

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------
--
-- IMPORTANT:
--
-- Server data is NOT requested here.
--
-- KIPN_Terminal controls application activation and calls onShow()
-- when the screen becomes active.
--
-- Keeping server requests in onShow() prevents duplicate requests
-- during screen construction.
--------------------------------------------------------------------

function KIPN_PostalServices:initialise()

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

                self.poBoxes = {}

                self.selectedPOBoxNumber = nil

                self.purchasePending = false

                self.purchaseConfirmOpen = false

                self.poBoxTableHitRects = {}

                self.poBoxRowEntries = {}

                self.poBoxScrollOffset = 0

                self.poBoxMaxVisible = 10

                self.postOfficeZoneLabel = nil

                self.requiresPostOffice = false

                self.myPOBoxKeys = {}

                self.poBoxKeyCopyFee = nil

                self.loading = false

                self.timedOut = false

                self.timeoutTime = 0

                self.playerBalance = 0

                self.inventoryFunds = 0

                self.parcels = {}

                ----------------------------------------------------
                -- KEY EVENTS
                ----------------------------------------------------

                self:setWantKeyEvents(true)

                ----------------------------------------------------
                -- PURCHASE BUTTON / COPY KEY CONTROLS / COLLECT
                -- PARCELS BUTTON
                --
                -- None of these are created here. Each is
                -- conditionally created/destroyed by its own
                -- rebuild*() function -- mirrors
                -- KIPN_GovernmentServices.lua's rebuildViewWidgets()
                -- pattern (the safehouse/excavation craft buttons):
                -- a gated control only exists in the widget tree at
                -- all while eligible, rather than always existing
                -- and being toggled via :setVisible()/:setEnable().
                --
                -- The one exception is affordability: whether an
                -- existing PURCHASE/COPY KEY button is currently
                -- enabled still depends on the player's live balance,
                -- which (per prerender()'s own comment) is read fresh
                -- every frame from the active marketplace adapter's
                -- cache rather than from a discrete server response --
                -- so that specific flag is still refreshed every
                -- frame in prerender(), same as before. Only
                -- *existence* (does a selection/parcel/key exist at
                -- all) is now event-driven.
                ----------------------------------------------------

                self.purchaseButton = nil

                self.keyCopyCombo = nil

                self.copyKeyButton = nil

                self.collectButton = nil

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PostalServices:initialise(): "
            .. tostring(err)
        )

    else

        success = true

    end

end

--------------------------------------------------------------------
-- SHOW
--
-- Called by KIPN_Terminal when this application becomes active.
--
-- A new request is made each time the application is shown.
--
-- This does not alter authentication state.
--------------------------------------------------------------------

function KIPN_PostalServices:onShow()

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- RESET APPLICATION STATE
                ----------------------------------------------------

                self.poBoxes = {}

                self.selectedPOBoxNumber = nil

                self.purchasePending = false

                self.purchaseConfirmOpen = false

                self.poBoxTableHitRects = {}

                self.poBoxRowEntries = {}

                self.poBoxScrollOffset = 0

                self.postOfficeZoneLabel = nil

                self.requiresPostOffice = false

                self.myPOBoxKeys = {}

                self.poBoxKeyCopyFee = nil

                self.parcels = {}

                self:rebuildPurchaseButton()

                self:rebuildKeyCopyControls()

                self:rebuildCollectButton()

                self.loading = true

                self.timedOut = false

                self.timeoutTime =
                    getRuntimeMs()
                    + 5000

                ----------------------------------------------------
                -- VERIFY COMMANDS
                ----------------------------------------------------

                local getPOBoxesCommand =
                    KIPN.Shared.Commands.GET_PO_BOXES

                local getPlayerDataCommand =
                    KIPN.Shared.Commands.GET_PLAYER_DATA

                local getParcelsCommand =
                    KIPN.Shared.Commands.GET_PARCELS

                if not getPOBoxesCommand then

                    KIPN.Logger.Error(
                        "KIPN_PostalServices:onShow(): "
                        .. "GET_PO_BOXES command unavailable"
                    )

                    self.loading = false
                    self.timedOut = true

                    return
                end

                if not getPlayerDataCommand then

                    KIPN.Logger.Error(
                        "KIPN_PostalServices:onShow(): "
                        .. "GET_PLAYER_DATA command unavailable"
                    )

                    self.loading = false
                    self.timedOut = true

                    return
                end

                ----------------------------------------------------
                -- REQUEST PO BOX DATA
                ----------------------------------------------------

                sendClientCommand(
                    "KIPN",
                    getPOBoxesCommand,
                    {}
                )

                ----------------------------------------------------
                -- REQUEST PLAYER DATA
                ----------------------------------------------------

                sendClientCommand(
                    "KIPN",
                    getPlayerDataCommand,
                    {}
                )

                ----------------------------------------------------
                -- REQUEST PENDING PARCELS
                --
                -- Optional relative to the core PO Box screen - a
                -- missing command identifier here should not block
                -- the rest of the screen from loading.
                ----------------------------------------------------

                if getParcelsCommand then

                    sendClientCommand(
                        "KIPN",
                        getParcelsCommand,
                        {}
                    )

                end

                ----------------------------------------------------
                -- REQUEST OWNED PO BOX KEYS
                --
                -- Optional relative to the core PO Box screen, same
                -- as GET_PARCELS above.
                ----------------------------------------------------

                local getMyPOBoxKeysCommand =
                    KIPN.Shared.Commands.GET_MY_POBOX_KEYS

                if getMyPOBoxKeysCommand then

                    sendClientCommand(
                        "KIPN",
                        getMyPOBoxKeysCommand,
                        {}
                    )

                end

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PostalServices:onShow(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- LEAVE SCREEN
--
-- Called by KIPN_Terminal when navigating away from this
-- application (BACK/HOME/closing the terminal). If a PO Box
-- purchase was still in flight, silence the claim-craft
-- loop -- no tail, since no key was issued.
--------------------------------------------------------------------

function KIPN_PostalServices:onLeaveScreen()

    KIPN.ClaimCraftSound.Stop()
end

--------------------------------------------------------------------
-- REBUILD PURCHASE BUTTON
--
-- Mirrors KIPN_GovernmentServices.lua's rebuildViewWidgets(): BUY
-- NOW only exists in the widget tree while a purchasable box is
-- selected and no purchase is in flight/awaiting confirmation --
-- existence is event-driven, not a per-frame check. Whether an
-- existing button is currently enabled (afford check) is still
-- refreshed every frame in prerender(), since the player's balance
-- is deliberately live (see prerender()'s comment).
--------------------------------------------------------------------

function KIPN_PostalServices:rebuildPurchaseButton()

    if self.purchaseButton then
        self:removeChild(self.purchaseButton)
        self.purchaseButton = nil
    end

    local selectedBox =
        findAvailablePOBox(
            self.poBoxes,
            self.selectedPOBoxNumber
        )

    local exists =
        selectedBox ~= nil
        and not self.purchasePending
        and not self.purchaseConfirmOpen

    KIPN.Logger.Info(
        "KIPN_PostalServices:rebuildPurchaseButton(): selectedBox="
        .. tostring(selectedBox and selectedBox.number)
        .. " purchasePending=" .. tostring(self.purchasePending)
        .. " purchaseConfirmOpen=" .. tostring(self.purchaseConfirmOpen)
        .. " -> exists=" .. tostring(exists)
    )

    if not exists then
        return
    end

    self.purchaseButton =
        KIPN.UI.CreateButton(
            self,
            20,
            self.height - 55,
            180,
            22,
            "BUY NOW",
            KIPN_PostalServices.onPurchaseClick
        )
end

--------------------------------------------------------------------
-- REBUILD KEY COPY CONTROLS
--
-- Mirrors KIPN_GovernmentServices.lua's rebuildViewWidgets(): the
-- combo box and COPY PO BOX KEY button only exist while the player
-- owns at least one PO Box key. Whether an existing button is
-- currently enabled (afford check against the copy fee) is still
-- refreshed every frame in prerender(), for the same live-balance
-- reason as rebuildPurchaseButton().
--------------------------------------------------------------------

function KIPN_PostalServices:rebuildKeyCopyControls()

    if self.keyCopyCombo then
        self:removeChild(self.keyCopyCombo)
        self.keyCopyCombo = nil
    end

    if self.copyKeyButton then
        self:removeChild(self.copyKeyButton)
        self.copyKeyButton = nil
    end

    local keyCount =
        self.myPOBoxKeys
        and #self.myPOBoxKeys
        or 0

    local exists = keyCount > 0

    KIPN.Logger.Info(
        "KIPN_PostalServices:rebuildKeyCopyControls(): keyCount="
        .. tostring(keyCount)
        .. " -> exists=" .. tostring(exists)
    )

    if not exists then
        return
    end

    self.keyCopyCombo =
        ISComboBox:new(
            280,
            self.height - 55,
            135,
            22,
            self,
            nil
        )

    self.keyCopyCombo:initialise()
    self.keyCopyCombo:instantiate()
    self:addChild(self.keyCopyCombo)

    for _, keyData in ipairs(self.myPOBoxKeys or {}) do
        if type(keyData) == "table" and keyData.boxId then
            self.keyCopyCombo:addOptionWithData(
                "PO Box #" .. tostring(keyData.number or "---"),
                keyData
            )
        end
    end

    if #self.keyCopyCombo.options > 0 then
        self.keyCopyCombo:setSelected(1)
    end

    self.copyKeyButton =
        KIPN.UI.CreateButton(
            self,
            425,
            self.height - 55,
            145,
            22,
            "COPY PO BOX KEY",
            KIPN_PostalServices.onCopyKeyClick
        )
end

--------------------------------------------------------------------
-- REBUILD COLLECT PARCELS BUTTON
--
-- Mirrors KIPN_GovernmentServices.lua's rebuildViewWidgets(): the
-- button only exists in the widget tree while at least one parcel
-- is pending -- collect eligibility is fully discrete (only changes
-- when a GET_PARCELS/PARCEL_COLLECTED response arrives), so there is
-- no live-refresh concern here the way there is for balance.
--------------------------------------------------------------------

function KIPN_PostalServices:rebuildCollectButton()

    if self.collectButton then
        self:removeChild(self.collectButton)
        self.collectButton = nil
    end

    local parcelCount =
        self.parcels
        and #self.parcels
        or 0

    local exists = parcelCount > 0

    KIPN.Logger.Info(
        "KIPN_PostalServices:rebuildCollectButton(): parcelCount="
        .. tostring(parcelCount)
        .. " -> exists=" .. tostring(exists)
    )

    if not exists then
        return
    end

    self.collectButton =
        KIPN.UI.CreateButton(
            self,
            20,
            self.height - 145,
            200,
            22,
            "COLLECT PARCELS",
            KIPN_PostalServices.onCollectClick
        )
end

--------------------------------------------------------------------
-- PURCHASE BUTTON
--------------------------------------------------------------------
--
-- Application-specific point-and-click control.
--
-- Terminal navigation is intentionally NOT handled here.
--------------------------------------------------------------------

function KIPN_PostalServices:onPurchaseClick()

    if self.purchasePending or self.purchaseConfirmOpen then
        return
    end

    local selectedBox =
        findAvailablePOBox(
            self.poBoxes,
            self.selectedPOBoxNumber
        )

    if not selectedBox then
        return
    end

    local message =
        "Purchase PO Box #" .. tostring(selectedBox.number)
        .. " for " .. tostring(selectedBox.price or "---")
        .. "?\n\nThe purchase price and one Blank Key "
        .. "will be removed from your inventory."

    local modal =
        ISModalDialog:new(
            (getCore():getScreenWidth() / 2) - 190,
            (getCore():getScreenHeight() / 2) - 90,
            380,
            180,
            message,
            true,
            self,
            KIPN_PostalServices.onPurchaseConfirm
        )

    modal:initialise()
    modal.boxNumber = tonumber(selectedBox.number)
    modal.moveWithMouse = true
    modal:setAlwaysOnTop(true)
    modal:addToUIManager()

    self.purchaseConfirmOpen = true

    self:rebuildPurchaseButton()

end

function KIPN_PostalServices:onPurchaseConfirm(button)

    self.purchaseConfirmOpen = false

    if not button
        or button.internal ~= "YES"
    then
        self:rebuildPurchaseButton()
        return
    end

    local modal = button.parent
    local confirmedBoxNumber =
        modal and tonumber(modal.boxNumber)

    if not confirmedBoxNumber
        or confirmedBoxNumber
            ~= tonumber(self.selectedPOBoxNumber)
    then
        self:rebuildPurchaseButton()
        return
    end

    self:purchaseBox()

end

--------------------------------------------------------------------
-- PURCHASE PO BOX
--------------------------------------------------------------------

function KIPN_PostalServices:purchaseBox()

    local success = false

    local ok, err =
        pcall(
            function()

                if self.purchasePending then
                    return
                end

                local boxNumber =
                    tonumber(self.selectedPOBoxNumber)

                if not boxNumber
                    or boxNumber ~= math.floor(boxNumber)
                then

                    return
                end

                local selectedBox =
                    findAvailablePOBox(self.poBoxes, boxNumber)

                if not selectedBox or selectedBox.owner then
                    return
                end

                ----------------------------------------------------
                -- PURCHASE REQUEST
                --
                -- The server independently resolves and charges its
                -- own configured price -- no client-supplied cost is
                -- sent or trusted.
                ----------------------------------------------------

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.BUY_PO_BOX,
                    {
                        boxNumber = boxNumber,
                    }
                )

                self.purchasePending = true

                -- KIPN is now crafting the PO Box Key -- loop the
                -- claim-craft cue until PURCHASE_RESULT
                -- arrives (see receiveResponse()).
                KIPN.ClaimCraftSound.Start()

                self:rebuildPurchaseButton()

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PostalServices:purchaseBox(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- COPY PO BOX KEY
--------------------------------------------------------------------

function KIPN_PostalServices:onCopyKeyClick()
    if not self.keyCopyCombo then return end

    local selected =
        self.keyCopyCombo.options[
            self.keyCopyCombo.selected
        ]

    local keyData = selected and selected.data
    if not keyData or not keyData.boxId then return end

    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.COPY_PO_BOX_KEY,
        {
            boxId = keyData.boxId,
        }
    )
end

--------------------------------------------------------------------
-- COLLECT PARCELS
--
-- Sends one COLLECT_PARCEL request per pending parcel. Each
-- response (PARCEL_COLLECTED) refreshes self.parcels via a
-- server-side GET_PARCELS re-push, so the list and button converge
-- to empty/hidden once every parcel has been handed over.
--------------------------------------------------------------------

function KIPN_PostalServices:onCollectClick()

    local success = false

    local ok, err =
        pcall(
            function()

                if not self.parcels
                    or #self.parcels == 0
                then

                    return
                end

                local collectCommand =
                    KIPN.Shared.Commands.COLLECT_PARCEL

                if not collectCommand then

                    KIPN.Logger.Error(
                        "KIPN_PostalServices:onCollectClick(): "
                        .. "COLLECT_PARCEL command unavailable"
                    )

                    return
                end

                for _, parcel in ipairs(self.parcels) do

                    sendClientCommand(
                        "KIPN",
                        collectCommand,
                        {
                            parcelId = parcel.id
                        }
                    )
                end

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PostalServices:onCollectClick(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------
--
-- Only meaningful state transitions are logged.
--------------------------------------------------------------------

function KIPN_PostalServices:update()

    ISPanel.update(self)

    if not self.loading then
        return
    end

    if getRuntimeMs() < self.timeoutTime then
        return
    end

    self.loading = false

    self.timedOut = true

end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_PostalServices:prerender()

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
            "POSTAL SERVICES"
        )

    ---------------------------------------------------------------
    -- BALANCE
    --
    -- Read live from the active marketplace adapter's client-side
    -- cache, mirroring KIPN_GovernmentServices.lua's excavation
    -- tier picker -- KIPN's balance is a provider-agnostic concept
    -- that never round-trips through GET_PLAYER_DATA (that command
    -- only returns username/accessLevel).
    ---------------------------------------------------------------

    -- self.playerBalance is the informational combined figure shown
    -- as YOUR BALANCE: external marketplace/economy ledger (when
    -- connected) plus physical vanilla money in the inventory and
    -- bags (see KIPN.MarketplaceAdapters.GetDisplayBalance).
    --
    -- self.inventoryFunds is the physical-cash-only subset. PO Box
    -- purchase and key copy are charged against that alone, so the
    -- PURCHASE AREA gates its controls on it, not on playerBalance.
    local currency

    self.playerBalance,
        currency =
        KIPN.MarketplaceAdapters.GetDisplayBalance(
            getPlayer
            and getPlayer()
        )

    self.playerBalance =
        self.playerBalance
        or 0

    -- PO Box purchase and key copy are paid in person at the counter:
    -- the server charges the player's physical inventory only and does
    -- not touch any external economy balance. Gate the controls on the
    -- same figure the server will actually collect.
    self.inventoryFunds =
        (KIPN.MarketplaceAdapters.GetInventoryCurrencyOnHand
            and KIPN.MarketplaceAdapters.GetInventoryCurrencyOnHand(
                getPlayer and getPlayer()
            ))
        or 0

    self:drawText(
        "YOUR BALANCE: "
        .. tostring(self.playerBalance)
        .. " "
        .. tostring(currency or ""),
        20,
        y,
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    y = y + 20

    self:drawText(
        "SPENDABLE HERE (inventory cash): "
        .. tostring(self.inventoryFunds)
        .. " "
        .. tostring(currency or ""),
        20,
        y,
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    y = y + 20

    ---------------------------------------------------------------
    -- OWNED PO BOX KEYS
    ---------------------------------------------------------------

    local hasOwnedBoxes =
        self.myPOBoxKeys
        and #self.myPOBoxKeys > 0

    if hasOwnedBoxes then

        local boxLabels = {}

        for i = 1, #self.myPOBoxKeys do

            local keyData = self.myPOBoxKeys[i]
            local boxNumber = type(keyData) == "table"
                and keyData.number
                or keyData

            boxLabels[#boxLabels + 1] =
                "#" .. tostring(boxNumber)

        end

        self:drawText(
            "YOUR PO BOX(ES): "
            .. table.concat(boxLabels, ", "),
            20,
            y,
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 20

    end

    y =
        KIPN.UI.DrawDivider(
            self,
            y
        )

    y = y + 15

    self.poBoxTableHitRects = {}
    self.poBoxRowEntries = {}

    ---------------------------------------------------------------
    -- LOADING
    ---------------------------------------------------------------

    if self.loading then

        KIPN.UI.DrawStatusMessage(
            self,
            "loading",
            "SEARCHING PO BOX RECORDS...",
            "Connecting to postal system database..."
        )

        return
    end

    ---------------------------------------------------------------
    -- TIMEOUT
    ---------------------------------------------------------------

    if self.timedOut
        and #self.poBoxes == 0 then

        KIPN.UI.DrawStatusMessage(
            self,
            "timeout",
            "SEARCH TIMED OUT",
            "No response from server."
        )

        return
    end

    ---------------------------------------------------------------
    -- NO RECORDS
    ---------------------------------------------------------------

    if #self.poBoxes == 0 then

        KIPN.UI.DrawStatusMessage(
            self,
            "empty",
            "NO PO BOX RECORDS FOUND",
            self.requiresPostOffice
                and "Visit a designated Post Office Zone to view and purchase boxes."
                or "No physical PO Boxes have been registered at this post office."
        )

    else

        -----------------------------------------------------------
        -- TABLE
        -----------------------------------------------------------

        local columns = {

            {
                label = "BOX",
                width = 60
            },

            {
                label = "SIZE",
                width = 80
            },

            {
                label = "CAP.",
                width = 65
            },

            {
                label = "PRICE",
                width = 75
            },

            {
                label = "OWNER",
                width = 150
            },

            {
                label = "STATUS",
                width = 100
            },
        }

        local rows = {}
        local selectedIndex = nil

        local startIndex = (self.poBoxScrollOffset or 0) + 1
        local endIndex = math.min(
            startIndex + (self.poBoxMaxVisible or 10) - 1,
            #self.poBoxes
        )

        for i = startIndex, endIndex do

            local box =
                self.poBoxes[i]

            local ownerText =
                box.owner
                and tostring(box.owner)
                or "AVAILABLE"

            local statusText =
                box.owner
                and "ACTIVE"
                or (
                    tonumber(self.selectedPOBoxNumber)
                        == tonumber(box.number)
                    and "SELECTED"
                    or "AVAILABLE"
                )

            rows[#rows + 1] = {

                "#"
                .. tostring(
                    box.number
                    or "---"
                ),

                tostring(box.size or "---"),

                tostring(box.capacity or "---"),

                tostring(box.price or "---"),

                ownerText,

                statusText,
            }

            self.poBoxRowEntries[#self.poBoxRowEntries + 1] = box

            if not box.owner
                and tonumber(self.selectedPOBoxNumber)
                    == tonumber(box.number)
            then
                selectedIndex = #rows
            end

        end

        self.poBoxTableHitRects = KIPN.UI.DrawTable(
            self,
            20,
            y,
            columns,
            rows,
            25,
            {
                selectedIndex = selectedIndex,
            }
        )

    end

    ---------------------------------------------------------------
    -- PENDING PARCELS
    --
    -- Anchored to the bottom of the panel (like the PURCHASE AREA
    -- below it) rather than to the flowing `y` cursor above, since
    -- the PO Box table's height varies with record count. The
    -- COLLECT PARCELS button's existence itself is now the gate --
    -- see rebuildCollectButton(), called whenever self.parcels
    -- changes -- so nothing needs toggling here any more.
    ---------------------------------------------------------------

    local hasParcels =
        self.parcels
        and #self.parcels > 0

    if hasParcels then

        self:drawText(
            string.format(
                "%d PARCEL(S) WAITING AT YOUR PO BOX:",
                #self.parcels
            ),
            20,
            self.height - 180,
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        local parcelSummary = {}

        for i = 1, math.min(#self.parcels, 3) do

            local parcel =
                self.parcels[i]

            parcelSummary[#parcelSummary + 1] =
                tostring(
                    parcel.quantity
                    or 1
                )
                .. "x "
                .. tostring(
                    parcel.displayName
                    or parcel.itemFullType
                    or "Unknown Item"
                )
        end

        self:drawText(
            table.concat(parcelSummary, ", "),
            20,
            self.height - 165,
            KIPN.UI.Theme.dimText.r,
            KIPN.UI.Theme.dimText.g,
            KIPN.UI.Theme.dimText.b,
            KIPN.UI.Theme.dimText.a,
            KIPN.UI.Theme.fontBody
        )
    end

    ---------------------------------------------------------------
    -- PURCHASE AREA
    ---------------------------------------------------------------

    local purchaseY =
        self.height - 105

    y =
        KIPN.UI.DrawDivider(
            self,
            purchaseY
        )

    y = y + 15

    local selectedBox =
        findAvailablePOBox(
            self.poBoxes,
            self.selectedPOBoxNumber
        )

    local claimItemType =
        self.claimItemType
        or "Base.Key_Blank"

    local player = getPlayer()

    local inventory =
        player
        and player:getInventory()

    local hasBlankKey = false

    if inventory then

        hasBlankKey =
            inventory:getFirstTypeRecurse(claimItemType)
            ~= nil
    end

    -- PO Box purchase and key copy are charged against physical
    -- inventory cash only (see prerender's SPENDABLE HERE line and
    -- ClaimService.ClaimPOBox) -- never the external economy balance,
    -- so gate on self.inventoryFunds, not the combined YOUR BALANCE.
    local spendableFunds =
        self.inventoryFunds
        or 0

    if self.purchaseButton then
        local canAffordPurchase = selectedBox and selectedBox.price and spendableFunds >= tonumber(selectedBox.price)
        self.purchaseButton:setEnable(
            selectedBox ~= nil
                and hasBlankKey
                and canAffordPurchase
                and not self.purchasePending
                and not self.purchaseConfirmOpen
        )
    end

    if self.copyKeyButton then
        local canAffordCopy = self.poBoxKeyCopyFee and spendableFunds >= tonumber(self.poBoxKeyCopyFee)
        self.copyKeyButton:setEnable(canAffordCopy == true)
    end

    self:drawText(
        "Click an AVAILABLE row to select a PO Box.",
        20,
        y,
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    y = y + 18

    local selectionText = "Purchase requires one Blank Key."

    if selectedBox then
        selectionText =
            "Selected PO Box #" .. tostring(selectedBox.number)
            .. " for " .. tostring(selectedBox.price or "---")
            .. ". Purchase requires one Blank Key."
    end

    self:drawText(
        selectionText,
        20,
        y,
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    if self.myPOBoxKeys and #self.myPOBoxKeys > 0 then
        self:drawText(
            "KEY COPY FEE: " ..
                tostring(self.poBoxKeyCopyFee or "---"),
            280,
            y,
            KIPN.UI.Theme.dimText.r,
            KIPN.UI.Theme.dimText.g,
            KIPN.UI.Theme.dimText.b,
            KIPN.UI.Theme.dimText.a,
            KIPN.UI.Theme.fontBody
        )
    end

end

--------------------------------------------------------------------
-- PO BOX TABLE SELECTION
--------------------------------------------------------------------

function KIPN_PostalServices:onMouseDown(x, y)
    if self.loading
        or self.purchasePending
        or self.purchaseConfirmOpen
        or not self.poBoxTableHitRects
        or not self.poBoxRowEntries
        or x < 20
        or x >= 550
    then
        return false
    end

    for _, rect in ipairs(self.poBoxTableHitRects) do
        if y >= rect.y1 and y < rect.y2 then
            local box = self.poBoxRowEntries[rect.index]

            if box and not box.owner then
                self.selectedPOBoxNumber = tonumber(box.number)

                self:rebuildPurchaseButton()
            end

            return true
        end
    end

    return false
end


--------------------------------------------------------------------
-- PO BOX TABLE SCROLLING
--------------------------------------------------------------------

function KIPN_PostalServices:onMouseWheel(delta)
    local maxOffset = math.max(
        0,
        #(self.poBoxes or {}) - (self.poBoxMaxVisible or 10)
    )

    self.poBoxScrollOffset = math.max(
        0,
        math.min(
            (self.poBoxScrollOffset or 0) - delta,
            maxOffset
        )
    )

    return true
end

--------------------------------------------------------------------
-- KEY PRESS
--
-- Keyboard navigation remains intentionally unused.
--
-- ESC is owned by KIPN_Terminal.
--
--------------------------------------------------------------------

function KIPN_PostalServices:onKeyPress(key)

    return false
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
-- to this function.
--------------------------------------------------------------------

function KIPN_PostalServices:receiveResponse(
    event,
    data
)

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- PO BOX DATA
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.PO_BOXES_DATA then

                    if type(data) == "table" then

                        self.poBoxes =
                            data.boxes
                            or {}

                        if not findAvailablePOBox(
                            self.poBoxes,
                            self.selectedPOBoxNumber
                        ) then
                            self.selectedPOBoxNumber = nil
                        end

                        self.postOfficeZoneLabel =
                            data.zoneLabel

                        self.requiresPostOffice =
                            data.requiresPostOffice == true

                        self.currencyType = data.currencyType
                        self.currencyValue = data.currencyValue
                        self.claimItemType = data.claimItemType

                    else

                        self.poBoxes = {}

                        self.postOfficeZoneLabel = nil

                        self.requiresPostOffice = false

                    end

                    self.loading = false

                    self.timedOut = false

                    self:rebuildPurchaseButton()

                    success = true

                    return
                end

                ----------------------------------------------------
                -- PURCHASE RESULT
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.PURCHASE_RESULT then

                    if data
                        and data.success then

                        self.purchasePending = false

                        KIPN.ClaimCraftSound.Complete()

                        self.selectedPOBoxNumber = nil

                        KIPN.Logger.Info(
                            "KIPN_PostalServices: "
                            .. "purchased PO Box #"
                            .. tostring(data.boxNumber)
                        )

                        ------------------------------------------------
                        -- REFRESH PO BOX DATA
                        ------------------------------------------------

                        sendClientCommand(
                            "KIPN",
                            KIPN.Shared.Commands.GET_PO_BOXES,
                            {}
                        )

                        ------------------------------------------------
                        -- REFRESH OWNED PO BOX KEYS
                        ------------------------------------------------

                        sendClientCommand(
                            "KIPN",
                            KIPN.Shared.Commands.GET_MY_POBOX_KEYS,
                            {}
                        )

                        ------------------------------------------------
                        -- Balance is read live from the active
                        -- marketplace adapter in prerender() -- see
                        -- KIPN_GovernmentServices.lua's same pattern --
                        -- so no server round trip is needed here.
                        ------------------------------------------------

                    else

                        self.purchasePending = false

                        KIPN.ClaimCraftSound.Fail()

                        local failureReason =
                            data
                            and data.reason
                            or "Purchase could not be completed."

                        KIPN.Logger.Warn(
                            "KIPN_PostalServices: "
                            .. "PO Box purchase failed: "
                            .. tostring(failureReason)
                        )

                        local player = getPlayer()
                        if player then
                            player:Say(
                                "PO Box purchase failed: " ..
                                tostring(failureReason)
                            )
                        end

                    end

                    self:rebuildPurchaseButton()

                    success = true

                    return
                end

                ----------------------------------------------------
                -- PLAYER DATA
                --
                -- GET_PLAYER_DATA carries only username/accessLevel;
                -- it has no balance field. self.playerBalance is
                -- recomputed every prerender() frame from
                -- KIPN.MarketplaceAdapters.GetDisplayBalance (ledger +
                -- physical cash), so nothing to do here.
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.PLAYER_DATA then

                    success = true

                    return
                end

                ----------------------------------------------------
                -- OWNED PO BOX KEYS
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.MY_POBOX_KEYS_DATA then

                    if type(data) == "table" and data.keys then

                        self.myPOBoxKeys =
                            data.keys

                        self.poBoxKeyCopyFee =
                            data.copyFee

                        self.currencyType = data.currencyType
                        self.currencyValue = data.currencyValue

                    elseif type(data) == "table" then

                        -- Compatibility with older servers that sent
                        -- a plain array of display numbers.
                        self.myPOBoxKeys = data

                        self.poBoxKeyCopyFee = nil

                    else

                        self.myPOBoxKeys = {}

                        self.poBoxKeyCopyFee = nil

                    end

                    self:rebuildKeyCopyControls()

                    success = true

                    return
                end

                ----------------------------------------------------
                -- PO BOX KEY COPY RESULT
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.PO_BOX_KEY_COPY_RESULT
                then
                    local player = getPlayer()

                    if data and data.success then
                        if player then
                            player:Say(
                                "Copied PO Box #" ..
                                tostring(data.boxNumber) .. " key."
                            )
                        end

                        sendClientCommand(
                            "KIPN",
                            KIPN.Shared.Commands.GET_MY_POBOX_KEYS,
                            {}
                        )
                    elseif player then
                        player:Say(
                            "PO Box key copy failed: " ..
                            tostring(data and data.reason or "UNKNOWN")
                        )
                    end

                    success = true
                    return
                end

                ----------------------------------------------------
                -- PENDING PARCELS
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.PARCELS_DATA then

                    if type(data) == "table" then

                        self.parcels =
                            data

                    else

                        self.parcels = {}

                    end

                    self:rebuildCollectButton()

                    success = true

                    return
                end

                ----------------------------------------------------
                -- PARCEL COLLECTED
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.PARCEL_COLLECTED then

                    if data
                        and data.success then

                        KIPN.Logger.Info(
                            "KIPN_PostalServices: "
                            .. "parcel collected: "
                            .. tostring(
                                data.parcel
                                and data.parcel.displayName
                            )
                        )

                        local player =
                            getPlayer()

                        if player then

                            player:Say(
                                "Parcel collected: "
                                .. tostring(
                                    data.parcel
                                    and data.parcel.displayName
                                    or "item"
                                )
                            )

                        end

                    else

                        KIPN.Logger.Warn(
                            "KIPN_PostalServices: "
                            .. "parcel collection failed: "
                            .. tostring(
                                data
                                and data.reason
                            )
                        )

                        local player = getPlayer()
                        if player then
                            local reason = data and data.reason or "UNKNOWN"
                            local message = "Parcel collection failed: " .. tostring(reason)

                            if reason == "PO_BOX_ZONE_REQUIRED" then
                                message = "You must be inside a Post Office zone to collect parcels."
                            elseif reason == "VALID_PO_BOX_KEY_REQUIRED" then
                                message = "A valid key for one of your active PO Boxes is required."
                            end

                            player:Say(message)
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

                    self.loading = false

                    self.timedOut = false

                    local player =
                        getPlayer()

                    if player then

                        player:Say(
                            "ERROR: "
                            .. tostring(message)
                        )

                    end

                    KIPN.Logger.Error(
                        "KIPN_PostalServices: "
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
            "KIPN_PostalServices:receiveResponse(): "
            .. tostring(err)
        )

    end

end

--------------------------------------------------------------------
-- MODULE LOAD
--------------------------------------------------------------------
