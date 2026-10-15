-- KIPN_GovernmentServices.lua
--
-- Government Services desk application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- Responsibilities:
--   * Let a player, holding a freshly-crafted Property or
--     Excavation registration item, present it at this computer
--     to receive a claim artifact ("Safehouse Deed" / "Excavation
--     Permit").
--   * Display an always-available reference list of the items
--     required to craft each Registration item (display only).
--
-- This module does NOT:
--   * determine whether this computer is inside a Government
--     Building zone
--   * authoritatively validate the player's inventory
--   * create or consume any artifact/token
--   * establish property/excavation ownership
--
-- All of the above are server-authoritative
-- (KIPN_GovArtifactService.lua's issue command handlers,
-- KIPN_GovCraftingReference.lua). This
-- screen only sends requests and reports outcomes -- the client-side
-- inventory check below decides which buttons to SHOW, it does not
-- decide what the server will ALLOW.
--
-- This module does NOT:
--   * create terminal chrome
--   * create terminal HOME / CLOSE controls
--   * register OnServerCommand
--   * manage UIManager membership
--   * perform proximity checks
--   * manage authentication sessions
--
-- UI responsibilities are delegated to KIPN_UI.lua.

if isServer() then
    return
end

require "KIPN_UI"

if not KIPN then
    error(
        "[KIPN_GovernmentServices] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then
    error(
        "[KIPN_GovernmentServices] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then
    error(
        "[KIPN_GovernmentServices] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then
    error(
        "[KIPN_GovernmentServices] "
        .. "KIPN_UI is not initialized."
    )
end

--------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------

KIPN_GovernmentServices =
    KIPN.UI.CreateScreen(
        "KIPN_GovernmentServices"
    )

--------------------------------------------------------------------
-- INVENTORY CASH COUNT
--
-- Mirrors KIPN.Server.Wallet: the configured single-currency item
-- has its configured value, while Base.MoneyBundle is worth $100.
-- The server still re-counts and charges authoritatively.
--------------------------------------------------------------------

local CLAIM_CURRENCY_BUNDLE_TYPE = "Base.MoneyBundle"
local CLAIM_CURRENCY_BUNDLE_VALUE = 100

local function resolveClaimCurrencySettings()
    local vars = SandboxVars and SandboxVars.KIPN or nil
    local itemType = vars and vars.ClaimCurrencyItemType or "Base.Money"
    local itemValue = vars and tonumber(vars.ClaimCurrencyItemValue) or 1

    if type(itemType) ~= "string" or itemType == "" then
        itemType = "Base.Money"
    end
    if not itemValue or itemValue <= 0 then itemValue = 1 end

    return itemType, math.floor(itemValue)
end

local function countInventoryCurrencyItems(player)

    local inventory =
        player
        and type(player.getInventory) == "function"
        and player:getInventory()

    if not inventory then
        local itemType, itemValue = resolveClaimCurrencySettings()
        return 0, 0, itemType, itemValue
    end

    local itemType, itemValue = resolveClaimCurrencySettings()
    local singles = 0
    local bundles = 0

    local function scan(container)
        if not container or type(container.getItems) ~= "function" then
            return
        end
        local items = container:getItems()
        if not items then return end
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then
                local fullType = item:getFullType()
                if fullType == itemType then
                    singles = singles + 1
                elseif fullType == CLAIM_CURRENCY_BUNDLE_TYPE then
                    bundles = bundles + 1
                end
                if type(item.getInventory) == "function" then
                    local ok, nested = pcall(item.getInventory, item)
                    if ok and nested then
                        scan(nested)
                    end
                end
            end
        end
    end

    scan(inventory)

    return singles, bundles, itemType, itemValue
end

function KIPN_GovernmentServices.countInventoryCash(player)
    local singles, bundles, _, itemValue =
        countInventoryCurrencyItems(player)
    return (singles * itemValue)
        + (bundles * CLAIM_CURRENCY_BUNDLE_VALUE)
end

function KIPN_GovernmentServices.canAffordInventoryCash(player, amount)
    amount = math.floor(tonumber(amount) or 0)
    if amount <= 0 then return true end

    local singles, bundles, _, itemValue =
        countInventoryCurrencyItems(player)
    local bundleCount = math.min(
        bundles,
        math.floor(amount / CLAIM_CURRENCY_BUNDLE_VALUE)
    )
    local remainder = amount - (bundleCount * CLAIM_CURRENCY_BUNDLE_VALUE)

    -- The authoritative wallet cannot make change. Reduce the number of
    -- bundles until the remainder is exactly payable by configured singles.
    while bundleCount > 0 and remainder % itemValue ~= 0 do
        bundleCount = bundleCount - 1
        remainder = amount - (bundleCount * CLAIM_CURRENCY_BUNDLE_VALUE)
    end

    if remainder % itemValue ~= 0 then return false end
    return (remainder / itemValue) <= singles
end

local MENU_BUTTON_WIDTH = 300
local MENU_BUTTON_HEIGHT = 32
local MENU_BUTTON_GAP = 10

local ITEM_TYPE_MAP = {

    property =
        "Base.KIPNPropertyRegistration",

    excavation =
        "Base.KIPNExcavationRegistration",
}

local ITEM_SHORT_TYPE_MAP = {

    property =
        "KIPNPropertyRegistration",

    excavation =
        "KIPNExcavationRegistration",
}

--------------------------------------------------------------------
-- RUNTIME TIMER
--
-- Millisecond-resolution real time (NOT game time) for the crafting
-- wait below -- mirrors the getRuntimeMs() helper already used by
-- KIPN_MainMenu.lua/KIPN_PropertyRecords.lua.
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
-- CLAIM CRAFT SECONDS
--
-- SandboxVars.KIPN.<ServiceKey>ClaimCraftSeconds (see
-- KIPN_ClaimConfig.lua's Services.<X>.ClaimCraftSeconds -- this
-- reads the raw sandbox value directly rather than round-tripping
-- through a server request, the same way KIPN_MainMenu.lua reads
-- SandboxVars.KIPN.SafehouseClaimsEnabled directly for display-only
-- decisions). 0 (or unset) means instant.
--------------------------------------------------------------------

local function resolveClaimCraftSeconds(serviceKey)

    local sv =
        SandboxVars
        and SandboxVars.KIPN

    if not sv or not serviceKey then
        return 0
    end

    local value =
        sv[serviceKey .. "ClaimCraftSeconds"]

    if type(value) ~= "number"
        or value <= 0
    then
        return 0
    end

    return value
end

--------------------------------------------------------------------
-- FLAVOR MESSAGE ROTATION
--
-- How long each cosmetic "registration flavor" message
-- (KIPN.UI.PickRandomFlavorMessage(), see KIPN_UI.lua) stays on
-- screen before a new one is randomly picked, in milliseconds.
--------------------------------------------------------------------

local FLAVOR_MESSAGE_MIN_MS = 4000

local FLAVOR_MESSAGE_MAX_MS = 8000

local function resolveNextFlavorIntervalMs()

    if type(ZombRand) == "function" then

        return FLAVOR_MESSAGE_MIN_MS
            + ZombRand(
                0,
                FLAVOR_MESSAGE_MAX_MS - FLAVOR_MESSAGE_MIN_MS
            )
    end

    return FLAVOR_MESSAGE_MIN_MS
        + math.random(
            0,
            FLAVOR_MESSAGE_MAX_MS - FLAVOR_MESSAGE_MIN_MS
        )
end

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_GovernmentServices:initialise()

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

                self.view = "menu"

                self.requestInFlight = false

                self.statusKey = nil

                self.statusTitle = nil

                self.statusSubtitle = nil

                self.hasPropertyRegistrationItem = false

                self.hasExcavationRegistrationItem = false

                self.craftingRequirements = nil

                self.excavationSizeTiers = nil

                self.excavationTierHitRects = {}

                self.viewWidgets = {}

                ----------------------------------------------------
                -- CLAIM CRAFT WAIT
                --
                -- See requestClaim()/update() below. craftEndAtMs is
                -- the real-time (getRuntimeMs()) timestamp the wait
                -- ends at; pendingCraftCommand/Args are what gets
                -- sent once it does. flavorMessage/
                -- flavorMessageChangeAtMs drive the cosmetic
                -- "registration flavor" text rotation shown during
                -- the wait (KIPN.UI.PickRandomFlavorMessage()).
                ----------------------------------------------------

                self.craftEndAtMs = nil

                self.pendingCraftCommand = nil

                self.pendingCraftArgs = nil

                self.pendingCraftServiceKey = nil

                self.flavorMessage = nil

                self.flavorMessageChangeAtMs = 0

                self:setWantKeyEvents(true)

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_GovernmentServices:initialise(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SHOW
--------------------------------------------------------------------

function KIPN_GovernmentServices:onShow()

    self.view = "menu"

    self.requestInFlight = false

    self.statusKey = nil

    self.statusTitle = nil

    self.statusSubtitle = nil

    self.craftEndAtMs = nil

    self.pendingCraftCommand = nil

    self.pendingCraftArgs = nil

    self.pendingCraftServiceKey = nil

    self:checkInventory()

    self:rebuildViewWidgets()
end

--------------------------------------------------------------------
-- LEAVE SCREEN
--
-- Called by KIPN_Terminal when navigating away from this screen
-- (BACK/HOME/closing the terminal) mid-craft. The wait itself is
-- purely a client-side timer (no physical action queued), so there
-- is nothing to cancel in the world -- this only clears the pending
-- command so it can never fire after the player has already
-- navigated away and stopped watching for the result.
--------------------------------------------------------------------

function KIPN_GovernmentServices:onLeaveScreen()

    self.craftEndAtMs = nil

    self.pendingCraftCommand = nil

    self.pendingCraftArgs = nil

    self.pendingCraftServiceKey = nil

    -- Abandoned mid-craft -- silence the processing loop, no tail.
    KIPN.ClaimCraftSound.Stop()
end

--------------------------------------------------------------------
-- UPDATE
--
-- Only reason this screen needs update() at all: advancing the
-- flavor-message rotation and firing the pending craft command once
-- the wait started by requestClaim() has elapsed.
--------------------------------------------------------------------

function KIPN_GovernmentServices:update()

    ISPanel.update(self)

    if not self.craftEndAtMs then
        return
    end

    local requirementsValid, errorTitle, errorSubtitle =
        self:validateCraftRequirements(
            self.pendingCraftServiceKey,
            self.pendingCraftArgs
        )

    if not requirementsValid then
        self:abortPendingCraft(errorTitle, errorSubtitle)
        return
    end

    local now =
        getRuntimeMs()

    if now >= self.craftEndAtMs then

        self:sendPendingCraftCommand()

        return
    end

    if now >= self.flavorMessageChangeAtMs then

        self.flavorMessage =
            KIPN.UI.PickRandomFlavorMessage()

        self.flavorMessageChangeAtMs =
            now + resolveNextFlavorIntervalMs()
    end
end

--------------------------------------------------------------------
-- CHECK INVENTORY
--
-- UX-ONLY. This determines which buttons are SHOWN. It has no
-- bearing on what the server will ALLOW -- IssuePropertyClaim /
-- IssueExcavationClaim independently re-validate the player's
-- inventory server-side.
--------------------------------------------------------------------

function KIPN_GovernmentServices:checkInventory()

    local success = false

    local ok, err =
        pcall(
            function()

                local player =
                    getPlayer
                    and getPlayer()

                local inventory =
                    player
                    and player:getInventory()

                self.hasPropertyRegistrationItem =
                    inventory ~= nil
                    and (
                        inventory:containsTypeRecurse(
                            ITEM_TYPE_MAP.property
                        )
                        or inventory:containsTypeRecurse(
                            ITEM_SHORT_TYPE_MAP.property
                        )
                    )

                self.hasExcavationRegistrationItem =
                    inventory ~= nil
                    and (
                        inventory:containsTypeRecurse(
                            ITEM_TYPE_MAP.excavation
                        )
                        or inventory:containsTypeRecurse(
                            ITEM_SHORT_TYPE_MAP.excavation
                        )
                    )

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_GovernmentServices:checkInventory(): "
            .. tostring(err)
        )

        self.hasPropertyRegistrationItem = false

        self.hasExcavationRegistrationItem = false

    end

end

--------------------------------------------------------------------
-- REBUILD VIEW WIDGETS
--
-- Destroys and rebuilds self.viewWidgets for the current
-- self.view. KIPN.UI has no show/hide convention, so conditional
-- widgets (e.g. craft buttons that depend on inventory contents)
-- are rebuilt rather than toggled, mirroring
-- KIPN_AdminSettings:rebuildFieldWidgets().
--------------------------------------------------------------------

function KIPN_GovernmentServices:rebuildViewWidgets()

    for _, widget in ipairs(self.viewWidgets or {}) do
        self:removeChild(widget)
    end

    self.viewWidgets = {}

    ----------------------------------------------------------------
    -- STATUS VIEW (success / error)
    --
    -- prerender() short-circuits to DrawStatusMessage() whenever
    -- self.statusKey is set, so this view needs its own Continue
    -- widget to dismiss the result. "loading" is excluded on purpose: a
    -- request is in flight and there is nothing to continue past
    -- yet, so no widgets are shown for it (matches the
    -- requestInFlight guard elsewhere in this file).
    ----------------------------------------------------------------

    if self.statusKey == "success"
        or self.statusKey == "error"
    then

        local continueButton =
            KIPN.UI.CreateButton(
                self,
                20,
                self.height - 50,
                140,
                30,
                "CONTINUE",
                KIPN_GovernmentServices.onStatusContinueClick
            )

        table.insert(self.viewWidgets, continueButton)

        return
    end

    if self.statusKey == "loading" then
        return
    end

    if self.view == "requirements"
        or self.view == "excavationTiers"
    then

        local backButton =
            KIPN.UI.CreateButton(
                self,
                20,
                self.height - 50,
                140,
                30,
                "BACK",
                KIPN_GovernmentServices.onBackClick
            )

        table.insert(self.viewWidgets, backButton)

        return
    end

    ----------------------------------------------------------------
    -- MENU VIEW
    ----------------------------------------------------------------

    local y = 100

    if self.hasPropertyRegistrationItem then

        local deedButton =
            KIPN.UI.CreateButton(
                self,
                20,
                y,
                MENU_BUTTON_WIDTH,
                MENU_BUTTON_HEIGHT,
                "CRAFT A SAFEHOUSE DEED",
                KIPN_GovernmentServices.onCraftSafehouseDeedClick
            )

        table.insert(self.viewWidgets, deedButton)

        y = y + MENU_BUTTON_HEIGHT + MENU_BUTTON_GAP

    end

    if self.hasExcavationRegistrationItem then

        local permitButton =
            KIPN.UI.CreateButton(
                self,
                20,
                y,
                MENU_BUTTON_WIDTH,
                MENU_BUTTON_HEIGHT,
                "CRAFT AN EXCAVATION PERMIT",
                KIPN_GovernmentServices.onCraftExcavationPermitClick
            )

        table.insert(self.viewWidgets, permitButton)

        y = y + MENU_BUTTON_HEIGHT + MENU_BUTTON_GAP

    end

    local requirementsButton =
        KIPN.UI.CreateButton(
            self,
            20,
            y,
            MENU_BUTTON_WIDTH,
            MENU_BUTTON_HEIGHT,
            "SEE REQUIRED CRAFTING ITEMS",
            KIPN_GovernmentServices.onShowRequirementsClick
        )

    table.insert(self.viewWidgets, requirementsButton)

end

--------------------------------------------------------------------
-- CRAFT SAFEHOUSE DEED
--
-- Requests the server-authoritative registration -> claim
-- artifact conversion (KIPN_GovArtifactService.lua's
-- ISSUE_PROPERTY_CLAIM command handler).
--
-- The server independently re-validates everything: this
-- computer's Government Building classification, the player's
-- inventory, and all artifact/token state. This click is only a
-- request.
--------------------------------------------------------------------

function KIPN_GovernmentServices:onCraftSafehouseDeedClick()

    self:requestClaim(
        "onCraftSafehouseDeedClick",
        KIPN.Shared.Commands.ISSUE_PROPERTY_CLAIM,
        "DO NOT MOVE! PROCESSING SAFEHOUSE DEED...",
        "Contacting KIPN property authority...",
        nil,
        "House"
    )
end

--------------------------------------------------------------------
-- CRAFT EXCAVATION PERMIT
--
-- Unlike the Safehouse Deed (a single fixed size), an Excavation
-- Permit's price depends on the admin-configured size tier the
-- player selects, so this opens a tier-picker view instead of
-- immediately requesting a claim. The actual request is sent by
-- onSelectExcavationTierClick() below once a tier is chosen.
--------------------------------------------------------------------

function KIPN_GovernmentServices:onCraftExcavationPermitClick()

    self.view = "excavationTiers"

    if not self.excavationSizeTiers then

        sendClientCommand(
            "KIPN",
            KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS,
            {}
        )
    end

    self:rebuildViewWidgets()
end

--------------------------------------------------------------------
-- SELECT EXCAVATION SIZE TIER
--
-- Mirrors onCraftSafehouseDeedClick()'s use of requestClaim() --
-- see that function's comment for the server-authoritative
-- validation contract. tierId is only a hint: the server
-- (KIPN_GovArtifactService.lua's handleIssueExcavationClaimCommand)
-- re-resolves it against KIPN.Server.ClaimConfig.ExcavationSizeTiers
-- and charges/sizes the claim from ITS OWN copy, not this one.
--------------------------------------------------------------------

function KIPN_GovernmentServices:onSelectExcavationTierClick(tierId)

    if not tierId then
        return
    end

    self:requestClaim(
        "onSelectExcavationTierClick",
        KIPN.Shared.Commands.ISSUE_EXCAVATION_CLAIM,
        "DO NOT MOVE! PROCESSING EXCAVATION PERMIT...",
        "Contacting KIPN excavation authority...",
        { tierId = tierId },
        "Excavation"
    )
end

--------------------------------------------------------------------
-- REQUIRED ITEM TYPE (PRE-CHECK)
--
-- Maps a requestClaim() serviceKey to the ITEM_TYPE_MAP key for the
-- Registration item it consumes, so requestClaim() can re-verify
-- the player is still actually carrying it immediately before
-- starting the crafting wait. The menu snapshot
-- (self.hasPropertyRegistrationItem/hasExcavationRegistrationItem)
-- is only refreshed on onShow()/onStatusContinueClick(), and the
-- item may have been dropped or traded since, so the wait would
-- otherwise run for a request the server will reject.
--------------------------------------------------------------------

local REQUIRED_ITEM_TYPE_BY_SERVICE_KEY = {

    House =
        ITEM_TYPE_MAP.property,

    Excavation =
        ITEM_TYPE_MAP.excavation,
}

local REQUIRED_SHORT_ITEM_TYPE_BY_SERVICE_KEY = {

    House =
        ITEM_SHORT_TYPE_MAP.property,

    Excavation =
        ITEM_SHORT_TYPE_MAP.excavation,
}

local function inventoryContainsType(inventory, itemType)
    if not inventory or not itemType then return false end
    if inventory.containsTypeRecurse then
        return inventory:containsTypeRecurse(itemType)
    end
    return inventory.contains and inventory:contains(itemType) or false
end

function KIPN_GovernmentServices:resolveExcavationTierPrice(tierId)
    if not tierId or type(self.excavationSizeTiers) ~= "table" then
        return nil
    end

    for _, tier in ipairs(self.excavationSizeTiers) do
        if tostring(tier.id) == tostring(tierId) then
            return tonumber(tier.price)
        end
    end

    return nil
end

function KIPN_GovernmentServices:validateCraftRequirements(serviceKey, commandArgs)
    local player = getPlayer and getPlayer() or nil
    local inventory = player and player.getInventory
        and player:getInventory() or nil
    local fullType = REQUIRED_ITEM_TYPE_BY_SERVICE_KEY[serviceKey]
    local shortType = REQUIRED_SHORT_ITEM_TYPE_BY_SERVICE_KEY[serviceKey]

    if fullType
        and not inventoryContainsType(inventory, fullType)
        and not inventoryContainsType(inventory, shortType)
    then
        return false,
            "REGISTRATION NOT FOUND",
            "You are not carrying the required registration item."
    end

    if serviceKey == "Excavation" then
        local tierPrice = self:resolveExcavationTierPrice(
            commandArgs and commandArgs.tierId)

        -- If tier data is unavailable, do not guess. The authoritative server
        -- will resolve the tier and its price when it receives the request.
        if tierPrice
            and not KIPN_GovernmentServices.canAffordInventoryCash(
                player, tierPrice)
        then
            return false,
                "INSUFFICIENT CASH",
                "You need $" .. tostring(tierPrice)
                    .. " in cash to craft this Excavation Permit."
        end
    end

    return true
end

function KIPN_GovernmentServices:abortPendingCraft(title, subtitle)
    self.craftEndAtMs = nil
    self.pendingCraftCommand = nil
    self.pendingCraftArgs = nil
    self.pendingCraftServiceKey = nil
    self.requestInFlight = false
    self.statusKey = "error"
    self.statusTitle = title or "REQUIREMENTS NOT MET"
    self.statusSubtitle = subtitle or "Required materials are no longer available."
    KIPN.ClaimCraftSound.Stop()
    self:checkInventory()
    self:rebuildViewWidgets()
end

--------------------------------------------------------------------
-- REQUEST CLAIM (shared by both craft actions)
--
-- serviceKey ("House" / "Excavation") looks up
-- SandboxVars.KIPN.<serviceKey>ClaimCraftSeconds -- when > 0, the
-- actual command is held for that many real seconds (see update()),
-- during which a rotating cosmetic "registration flavor" message is
-- shown (KIPN.UI.PickRandomFlavorMessage()) instead of sending
-- immediately. This is a client-side UX duration only, same "hint,
-- not enforced" model as KIPN_RepairComputerAction.lua's maxTime --
-- the server accepts the exchange command whenever it actually
-- arrives.
--------------------------------------------------------------------

function KIPN_GovernmentServices:requestClaim(
    operationName,
    command,
    loadingTitle,
    loadingSubtitle,
    extraArgs,
    serviceKey
)

    local success = false

    local ok, err =
        pcall(
            function()

                if self.requestInFlight then
                    return
                end

                if not command then

                    KIPN.Logger.Error(
                        "KIPN_GovernmentServices:" .. operationName
                        .. "(): command unavailable"
                    )

                    return
                end

                --------------------------------------------------
                -- PRE-CHECK: STILL CARRYING THE REGISTRATION ITEM
                --
                -- Re-verifies right now, recursively (matching the
                -- server's own findArtifactItem() search depth),
                -- rather than trusting the menu-visibility snapshot
                -- from whenever this screen was last shown.
                --------------------------------------------------

                local commandArgsForPreflight = extraArgs or {}
                local requirementsValid, errorTitle, errorSubtitle =
                    self:validateCraftRequirements(
                        serviceKey,
                        commandArgsForPreflight
                    )

                if not requirementsValid then
                    self.statusKey = "error"
                    self.statusTitle = errorTitle
                    self.statusSubtitle = errorSubtitle
                    self:checkInventory()
                    self:rebuildViewWidgets()
                    return
                end

                local computerId =
                    self.terminal
                    and self.terminal.GetComputerId
                    and self.terminal:GetComputerId()

                if not computerId then

                    self.statusKey = "error"
                    self.statusTitle = "COMPUTER NOT IDENTIFIED"
                    self.statusSubtitle =
                        "Unable to identify this terminal."

                    self:rebuildViewWidgets()

                    KIPN.Logger.Error(
                        "KIPN_GovernmentServices:" .. operationName
                        .. "(): computerId unavailable"
                    )

                    return
                end

                self.requestInFlight = true

                local commandArgs = {
                    computerId = computerId,
                }

                if type(extraArgs) == "table" then

                    for key, value in pairs(extraArgs) do
                        commandArgs[key] = value
                    end
                end

                local craftSeconds =
                    resolveClaimCraftSeconds(serviceKey)

                --------------------------------------------------
                -- INSTANT (craftSeconds == 0)
                --------------------------------------------------

                if craftSeconds <= 0 then

                    self.statusKey = "loading"
                    self.statusTitle = loadingTitle
                    self.statusSubtitle = loadingSubtitle

                    self:rebuildViewWidgets()

                    self:sendClaimCommand(command, commandArgs)

                    success = true

                    return
                end

                --------------------------------------------------
                -- FLAVOR-TEXT WAIT
                --
                -- No physical animation -- the terminal screen
                -- fills the player's view, so a character animation
                -- isn't visible anyway. update() advances both the
                -- wait and the flavor-message rotation.
                --------------------------------------------------

                self.pendingCraftCommand = command

                self.pendingCraftArgs = commandArgs

                self.pendingCraftServiceKey = serviceKey

                self.craftEndAtMs =
                    getRuntimeMs()
                    + (craftSeconds * 1000)

                self.flavorMessage =
                    KIPN.UI.PickRandomFlavorMessage()

                self.flavorMessageChangeAtMs =
                    getRuntimeMs()
                    + resolveNextFlavorIntervalMs()

                self.statusKey = "loading"
                self.statusTitle = loadingTitle
                self.statusSubtitle = self.flavorMessage

                self:rebuildViewWidgets()

                -- KIPN is now crafting the claim object -- loop the
                -- claim-craft cue until the server answers
                -- (see receiveResponse()).
                KIPN.ClaimCraftSound.Start()

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_GovernmentServices:" .. operationName .. "(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SEND PENDING CRAFT COMMAND
--
-- Fires once update()'s flavor-text wait has elapsed.
--------------------------------------------------------------------

function KIPN_GovernmentServices:sendPendingCraftCommand()

    local command =
        self.pendingCraftCommand

    local commandArgs =
        self.pendingCraftArgs

    local serviceKey =
        self.pendingCraftServiceKey

    local requirementsValid, errorTitle, errorSubtitle =
        self:validateCraftRequirements(serviceKey, commandArgs)

    if not requirementsValid then
        self:abortPendingCraft(errorTitle, errorSubtitle)
        return
    end

    self.craftEndAtMs = nil

    self.pendingCraftCommand = nil

    self.pendingCraftArgs = nil

    self.pendingCraftServiceKey = nil

    if not command then
        return
    end

    self.statusSubtitle =
        "Contacting KIPN authority..."

    self:sendClaimCommand(command, commandArgs)
end

--------------------------------------------------------------------
-- SEND CLAIM COMMAND
--------------------------------------------------------------------

function KIPN_GovernmentServices:sendClaimCommand(
    command,
    commandArgs
)

    local ok, err =
        pcall(
            function()

                sendClientCommand(
                    "KIPN",
                    command,
                    commandArgs or {}
                )

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_GovernmentServices:sendClaimCommand(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SHOW REQUIRED CRAFTING ITEMS
--------------------------------------------------------------------

function KIPN_GovernmentServices:onShowRequirementsClick()

    self.view = "requirements"

    if not self.craftingRequirements then

        sendClientCommand(
            "KIPN",
            KIPN.Shared.Commands.GET_CRAFTING_REQUIREMENTS,
            {}
        )
    end

    self:rebuildViewWidgets()
end

--------------------------------------------------------------------
-- BACK
--------------------------------------------------------------------

function KIPN_GovernmentServices:onBackClick()

    self.view = "menu"

    self:rebuildViewWidgets()
end

--------------------------------------------------------------------
-- STATUS CONTINUE
--
-- Dismisses the success/error status screen set by requestClaim()/
-- receiveResponse() by clearing self.statusKey and returning to the
-- menu view.
--------------------------------------------------------------------

function KIPN_GovernmentServices:onStatusContinueClick()

    self.statusKey = nil

    self.statusTitle = nil

    self.statusSubtitle = nil

    self.craftEndAtMs = nil

    self.pendingCraftCommand = nil

    self.pendingCraftArgs = nil

    self.pendingCraftServiceKey = nil

    self:checkInventory()

    self:rebuildViewWidgets()
end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_GovernmentServices:prerender()

    ISPanel.prerender(self)

    ---------------------------------------------------------------
    -- COMMON CRT EFFECTS
    ---------------------------------------------------------------

    KIPN.UI.DrawScanlines(self)

    ---------------------------------------------------------------
    -- BANNER
    ---------------------------------------------------------------

    KIPN.UI.DrawBanner(
        self,
        "GOVERNMENT SERVICES"
    )

    ---------------------------------------------------------------
    -- CRAFT REQUEST STATUS (short-circuits both views)
    ---------------------------------------------------------------

    if self.statusKey then

        ------------------------------------------------------------
        -- While self.craftEndAtMs is set, the wait started by
        -- requestClaim() is still running and the command hasn't
        -- been sent yet -- show the rotating cosmetic flavor
        -- message (see update()) instead of the normal subtitle.
        ------------------------------------------------------------

        local subtitle =
            self.craftEndAtMs
            and self.flavorMessage
            or self.statusSubtitle

        KIPN.UI.DrawStatusMessage(
            self,
            self.statusKey,
            self.statusTitle,
            subtitle
        )

        return
    end

    ---------------------------------------------------------------
    -- REQUIREMENTS VIEW
    ---------------------------------------------------------------

    if self.view == "requirements" then

        if not self.craftingRequirements then

            KIPN.UI.DrawStatusMessage(
                self,
                "loading",
                "LOADING REQUIREMENTS...",
                nil
            )

            return
        end

        local columns = {
            { label = "ITEM", width = 260 },
            { label = "COUNT", width = 80 },
        }

        local y = 80

        -- Physical vanilla money and money bundles the player is
        -- carrying in their inventory and bags -- the currency KIPN
        -- claim fees are paid from (see KIPN_Wallet.lua server-side).
        -- Matches the excavationTiers view's balance display below so
        -- the player can compare it against the item counts required
        -- for either a Safehouse Deed or an Excavation Permit.
        local requirementsPlayer =
            getPlayer
            and getPlayer()

        local requirementsBalance =
            KIPN_GovernmentServices.countInventoryCash(requirementsPlayer)

        self:drawText(
            "BALANCE: $" .. tostring(requirementsBalance),
            20,
            y,
            0.8,
            0.8,
            0.8,
            1,
            UIFont.Small
        )

        y = y + 25

        self:drawText(
            "SAFEHOUSE DEED REQUIREMENTS",
            20,
            y,
            0,
            1,
            0,
            1,
            UIFont.Small
        )

        y = y + 20

        local propertyRows = {}

        for _, requirement in ipairs(
            self.craftingRequirements.property or {}
        ) do

            table.insert(
                propertyRows,
                {
                    requirement.displayName,
                    tostring(requirement.count),
                }
            )
        end

        KIPN.UI.DrawTable(
            self,
            20,
            y,
            columns,
            propertyRows,
            22
        )

        y = y + 22 + (22 * #propertyRows) + 30

        self:drawText(
            "EXCAVATION PERMIT REQUIREMENTS",
            20,
            y,
            0,
            1,
            0,
            1,
            UIFont.Small
        )

        y = y + 20

        local excavationRows = {}

        for _, requirement in ipairs(
            self.craftingRequirements.excavation or {}
        ) do

            table.insert(
                excavationRows,
                {
                    requirement.displayName,
                    tostring(requirement.count),
                }
            )
        end

        KIPN.UI.DrawTable(
            self,
            20,
            y,
            columns,
            excavationRows,
            22
        )

        return

    end

    ---------------------------------------------------------------
    -- EXCAVATION SIZE TIER PICKER VIEW
    ---------------------------------------------------------------

    if self.view == "excavationTiers" then

        local y = 80

        local player =
            getPlayer
            and getPlayer()

        -- Physical vanilla money and money bundles the player is
        -- carrying in their inventory and bags -- the currency KIPN
        -- claim fees are paid from (see KIPN_Wallet.lua server-side).
        local displayBalance = KIPN_GovernmentServices.countInventoryCash(player)

        self:drawText(
            "BALANCE: $" .. tostring(displayBalance),
            20,
            y,
            0.8,
            0.8,
            0.8,
            1,
            UIFont.Small
        )

        y = y + 25

        self:drawText(
            "Select a claim size to purchase an Excavation Permit:",
            20,
            y,
            0,
            1,
            0,
            1,
            UIFont.Small
        )

        y = y + 25

        if not self.excavationSizeTiers then

            KIPN.UI.DrawStatusMessage(
                self,
                "loading",
                "LOADING SIZES...",
                nil
            )

            return
        end

        local columns = {
            { label = "SIZE", width = 160 },
            { label = "DIMENSIONS", width = 140 },
            { label = "PRICE", width = 100 },
        }

        local rows = {}

        for _, tier in ipairs(self.excavationSizeTiers) do

            table.insert(
                rows,
                {
                    tostring(tier.label or tier.id),
                    tostring(tier.widthTiles) .. " x " .. tostring(tier.heightTiles),
                    tostring(tier.price),
                }
            )
        end

        self.excavationTierHitRects =
            KIPN.UI.DrawTable(
                self,
                20,
                y,
                columns,
                rows,
                25
            )

        self:drawText(
            "Click a size to purchase. The Registration item and "
                .. "purchase amount are only spent if both are met.",
            20,
            self.height - 65,
            0.7,
            0.7,
            0.7,
            1,
            UIFont.Small
        )

        return

    end

    ---------------------------------------------------------------
    -- MENU VIEW (idle)
    ---------------------------------------------------------------

    if not self.hasPropertyRegistrationItem
        and not self.hasExcavationRegistrationItem
    then

        self:drawText(
            "Craft options only appear once you are carrying "
            .. "the matching registration item.",
            20,
            75,
            0.7,
            0.7,
            0.7,
            1,
            UIFont.Small
        )
    end
end

--------------------------------------------------------------------
-- KEY PRESS
--------------------------------------------------------------------

function KIPN_GovernmentServices:onKeyPress(key)

    return false
end

--------------------------------------------------------------------
-- MOUSE
--
-- Only the excavation size tier table (view == "excavationTiers")
-- has clickable rows; every other view uses ordinary buttons.
--------------------------------------------------------------------

function KIPN_GovernmentServices:onMouseDown(x, y)

    if self.view ~= "excavationTiers" then
        return false
    end

    if self.requestInFlight then
        return false
    end

    if not self.excavationTierHitRects
        or not self.excavationSizeTiers
    then
        return false
    end

    for _, hitRect in ipairs(self.excavationTierHitRects) do

        if y >= hitRect.y1
            and y < hitRect.y2 then

            local tier =
                self.excavationSizeTiers[hitRect.index]

            if tier then
                self:onSelectExcavationTierClick(tier.id)
            end

            return true
        end
    end

    return false
end

--------------------------------------------------------------------
-- SERVER RESPONSE
--
-- The terminal is the sole OnServerCommand listener. KIPN_Terminal
-- routes event/data to this function.
--------------------------------------------------------------------

function KIPN_GovernmentServices:receiveResponse(
    event,
    data
)

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- SAFEHOUSE DEED ISSUED
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents
                        .PROPERTY_CLAIM_ARTIFACT_ISSUED then

                    self.requestInFlight = false

                    KIPN.ClaimCraftSound.Complete()

                    self.statusKey = "success"
                    self.statusTitle = "SAFEHOUSE DEED ISSUED"

                    ------------------------------------------------
                    -- GROUND-DROP NOTICE
                    --
                    -- If the item couldn't fit in inventory, the
                    -- server already dropped it on the ground and
                    -- said so via player:Say() -- but that chat
                    -- bubble is invisible while this full-screen
                    -- terminal UI covers the player's view. Surface
                    -- it here instead.
                    ------------------------------------------------

                    if type(data) == "table"
                        and data.droppedOnGround == true
                    then

                        self.statusSubtitle =
                            "Your inventory was full -- the "
                            .. "Safehouse Deed was dropped on "
                            .. "the ground at your feet."

                    else

                        self.statusSubtitle =
                            "Take it to your claimed property and "
                            .. "right-click to establish ownership."

                    end

                    self:checkInventory()

                    self:rebuildViewWidgets()

                    success = true

                    return
                end

                ----------------------------------------------------
                -- EXCAVATION PERMIT ISSUED
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents
                        .EXCAVATION_CLAIM_ARTIFACT_ISSUED then

                    self.requestInFlight = false

                    KIPN.ClaimCraftSound.Complete()

                    self.statusKey = "success"
                    self.statusTitle = "EXCAVATION PERMIT ISSUED"

                    -- See the identical ground-drop notice above.
                    if type(data) == "table"
                        and data.droppedOnGround == true
                    then

                        self.statusSubtitle =
                            "Your inventory was full -- the "
                            .. "Excavation Permit was dropped on "
                            .. "the ground at your feet."

                    else

                        self.statusSubtitle =
                            "Take it to your excavation site and "
                            .. "right-click to establish ownership."

                    end

                    self.view = "menu"

                    self:checkInventory()

                    self:rebuildViewWidgets()

                    success = true

                    return
                end

                ----------------------------------------------------
                -- CRAFTING REQUIREMENTS DATA
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents
                        .CRAFTING_REQUIREMENTS_DATA then

                    self.craftingRequirements = {
                        property =
                            type(data) == "table"
                            and data.property
                            or {},

                        excavation =
                            type(data) == "table"
                            and data.excavation
                            or {},
                    }

                    success = true

                    return
                end

                ----------------------------------------------------
                -- EXCAVATION SIZE TIERS DATA
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents
                        .EXCAVATION_SIZE_TIERS_DATA then

                    self.excavationSizeTiers =
                        type(data) == "table"
                        and data.tiers
                        or {}

                    success = true

                    return
                end

                ----------------------------------------------------
                -- SERVER ERROR (declined command)
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.ERROR then

                    self.requestInFlight = false

                    KIPN.ClaimCraftSound.Fail()

                    local reason =
                        type(data) == "table"
                        and (data.reason or data.message)
                        or data

                    self.statusKey = "error"
                    self.statusTitle = "REQUEST FAILED"
                    self.statusSubtitle =
                        tostring(
                            reason
                            or "Unknown error."
                        )

                    KIPN.Logger.Error(
                        "KIPN_GovernmentServices: server error: "
                        .. tostring(reason)
                    )

                    self:rebuildViewWidgets()

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
            "KIPN_GovernmentServices:receiveResponse(): "
            .. tostring(err)
        )
    end

end
