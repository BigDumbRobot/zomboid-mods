-- KIPN_VehicleRegistration.lua
--
-- Vehicle registration desk application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- Responsibilities:
--   * Let a player, holding a freshly-crafted vehicle
--     registration item, present it at this computer to receive
--     a vehicle claim artifact.
--   * Display the result of that request.
--
-- This module does NOT:
--   * determine whether this computer is inside a dealership zone
--   * inspect the player's inventory
--   * create or consume any artifact/token
--   * establish vehicle ownership
--
-- All of the above are server-authoritative (KIPN_ArtifactService.lua
-- IssueVehicleClaim command handler, KIPN_ClaimService.lua). This
-- screen only sends the request and reports the outcome.
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
        "[KIPN_VehicleRegistration] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then
    error(
        "[KIPN_VehicleRegistration] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then
    error(
        "[KIPN_VehicleRegistration] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then
    error(
        "[KIPN_VehicleRegistration] "
        .. "KIPN_UI is not initialized."
    )
end

--------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------

KIPN_VehicleRegistration =
    KIPN.UI.CreateScreen(
        "KIPN_VehicleRegistration"
    )

--------------------------------------------------------------------
-- RUNTIME TIMER
--
-- Millisecond-resolution real time (NOT game time) for the crafting
-- wait below -- mirrors the getRuntimeMs() helper already used by
-- KIPN_MainMenu.lua/KIPN_PropertyRecords.lua/
-- KIPN_GovernmentServices.lua.
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
-- SandboxVars.KIPN.VehicleClaimCraftSeconds (see
-- KIPN_ClaimConfig.lua's Services.Vehicle.ClaimCraftSeconds). 0 (or
-- unset) means instant.
--------------------------------------------------------------------

local function resolveVehicleClaimCraftSeconds()

    local sv =
        SandboxVars
        and SandboxVars.KIPN

    if not sv then
        return 0
    end

    local value =
        sv.VehicleClaimCraftSeconds

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
-- REQUIRED ITEM TYPE
--
-- The Vehicle Registration item onProcessClick() re-verifies the
-- player is still carrying, recursively, immediately before starting
-- the crafting wait -- see requestClaim()'s equivalent pre-check in
-- KIPN_GovernmentServices.lua for the full rationale.
--------------------------------------------------------------------

local VEHICLE_REGISTRATION_ITEM_TYPE =
    "Base.KIPNVehicleRegistration"

local VEHICLE_REGISTRATION_SHORT_TYPE =
    "KIPNVehicleRegistration"

local function playerHasVehicleRegistration()
    local player = getPlayer and getPlayer() or nil
    local inventory = player and player.getInventory
        and player:getInventory() or nil

    if not inventory then return false end

    if inventory.containsTypeRecurse then
        return inventory:containsTypeRecurse(VEHICLE_REGISTRATION_ITEM_TYPE)
            or inventory:containsTypeRecurse(VEHICLE_REGISTRATION_SHORT_TYPE)
    end

    return inventory.contains
        and (inventory:contains(VEHICLE_REGISTRATION_ITEM_TYPE)
            or inventory:contains(VEHICLE_REGISTRATION_SHORT_TYPE))
        or false
end

function KIPN_VehicleRegistration:abortPendingClaimForMissingRegistration()
    self.craftEndAtMs = nil
    self.pendingClaimArgs = nil
    self.requestInFlight = false
    self.statusKey = "error"
    self.statusTitle = "REGISTRATION NOT FOUND"
    self.statusSubtitle = "You are not carrying a Vehicle Registration Form."
    KIPN.ClaimCraftSound.Stop()
    self:checkInventory()
end

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_VehicleRegistration:initialise()

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

                self.requestInFlight = false

                self.statusKey = nil

                self.statusTitle = nil

                self.statusSubtitle = nil

                ----------------------------------------------------
                -- CLAIM CRAFT WAIT
                --
                -- See onProcessClick()/update() below. craftEndAtMs
                -- is the real-time (getRuntimeMs()) timestamp the
                -- wait ends at; pendingClaimArgs is what gets sent
                -- once it does. flavorMessage/flavorMessageChangeAtMs
                -- drive the cosmetic "registration flavor" text
                -- rotation shown during the wait
                -- (KIPN.UI.PickRandomFlavorMessage()).
                ----------------------------------------------------

                self.craftEndAtMs = nil

                self.pendingClaimArgs = nil

                self.flavorMessage = nil

                self.flavorMessageChangeAtMs = 0

                ----------------------------------------------------
                -- PROCESS REGISTRATION BUTTON
                --
                -- NOT created here. KIPN_Terminal calls a child
                -- screen's initialise() BEFORE its final
                -- instantiate() (see KIPN.UI.EnableScroll()'s
                -- "ATTACH AFTER INSTANTIATION" note for the same
                -- hazard): KIPN.UI.CreateButton() -> self:addChild()
                -- implicitly instantiates this panel while its
                -- javaObject is still nil, and the terminal's later
                -- instantiate() then throws that Java UI object away
                -- -- taking the button with it, so it never renders.
                -- The button is built in onShow() instead, once the
                -- final UI object exists. This was the "I never see
                -- the Craft a Vehicle Title button" bug.
                ----------------------------------------------------

                self.processButton = nil

                self:setWantKeyEvents(true)

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_VehicleRegistration:initialise(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SHOW
--------------------------------------------------------------------

function KIPN_VehicleRegistration:onShow()

    KIPN.Logger.Info("[KIPN] Vehicle Registration page opened.")

    self.requestInFlight = false

    self.statusKey = nil

    self.statusTitle = nil

    self.statusSubtitle = nil

    self.craftEndAtMs = nil

    self.pendingClaimArgs = nil

    -- Build the "Craft a Vehicle Title" button here rather than in
    -- initialise(). KIPN_Terminal instantiates this screen AFTER
    -- initialise() returns, so a button added during initialise()
    -- gets stranded on a discarded Java UI object (see the note in
    -- initialise()). By onShow() the final UI object exists and
    -- self.height is real, so the button both attaches and anchors
    -- correctly. Created once, then just re-anchored on later shows.
    if not self.processButton then
        self.processButton =
            KIPN.UI.CreateButton(
                self,
                20,
                self.height - 50,
                220,
                30,
                "Craft a Vehicle Title",
                KIPN_VehicleRegistration.onProcessClick
            )
    end

    if self.processButton then
        self.processButton:setX(20)
        self.processButton:setY(self.height - 50)
        self.processButton:setWidth(220)
        self.processButton:setVisible(true)
        self.processButton:bringToTop()
    end

    -- checkInventory() sets the button's enabled state from whether
    -- the player is carrying a Vehicle Registration Form.
    self:checkInventory()
end

local function getRegistrationFormCount(inventory)
    if not inventory then return 0 end
    local count = 0
    local items = inventory:getItems()
    if not items then return 0 end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item then
            local fullType = item:getFullType()
            if fullType == VEHICLE_REGISTRATION_ITEM_TYPE or fullType == VEHICLE_REGISTRATION_SHORT_TYPE then
                count = count + 1
            elseif type(item.getInventory) == "function" then
                local nestedInv = item:getInventory()
                if nestedInv then
                    count = count + getRegistrationFormCount(nestedInv)
                end
            end
        end
    end
    return count
end

--------------------------------------------------------------------
-- CHECK INVENTORY
--
-- Dealership-zone eligibility is not re-checked here -- KIPN_MainMenu
-- already gates the "VEHICLE REGISTRATION" menu item on
-- computerClassification.dealership == true, so this screen is only
-- ever reached from a computer that already passed that check (see
-- KIPN_GovernmentServices.lua for the same trust-the-menu-gate
-- pattern). Re-verifying it here via a second, independent
-- GET_COMPUTER_INFO round trip only added a fragile async dependency
-- that could leave the button permanently hidden if that request
-- ever failed or was slow to resolve.
--------------------------------------------------------------------

function KIPN_VehicleRegistration:checkInventory()

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

                local count = getRegistrationFormCount(inventory)
                self.hasRegistrationItem = count > 0

                KIPN.Logger.Info(string.format("[KIPN] Vehicle Registration Form lookup result: %s, count: %d", tostring(self.hasRegistrationItem), count))

                -- The button stays VISIBLE at all times (hiding it was
                -- the old "I can never see the button" bug -- see the
                -- header note above), but it is only ENABLED while the
                -- player is actually carrying a Vehicle Registration
                -- Form: greyed out and unclickable otherwise. This is a
                -- pure local inventory walk (getRegistrationFormCount(),
                -- recursive, no server round trip), and onProcessClick()
                -- + the server both re-verify the form before anything
                -- is consumed, so a disabled button that should be
                -- enabled self-corrects on the next onShow().
                if self.processButton then
                    self.processButton.enable =
                        self.hasRegistrationItem == true
                    self.processButton:setVisible(true)
                end

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_VehicleRegistration:checkInventory(): "
            .. tostring(err)
        )

        self.hasRegistrationItem = false

        -- The inventory walk itself errored (an API change, not a
        -- missing form). Fail OPEN -- leave the button enabled and let
        -- onProcessClick()'s own containsTypeRecurse() re-check plus
        -- the server's re-validation catch a genuinely missing form,
        -- rather than hard-locking the player out of the desk.
        if self.processButton then
            self.processButton.enable = true
            self.processButton:setVisible(true)
        end

    end

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

function KIPN_VehicleRegistration:onLeaveScreen()

    self.craftEndAtMs = nil

    self.pendingClaimArgs = nil

    -- Abandoned mid-craft -- silence the processing loop, no tail.
    KIPN.ClaimCraftSound.Stop()
end

--------------------------------------------------------------------
-- UPDATE
--
-- Only reason this screen needs update() at all: advancing the
-- flavor-message rotation and firing the pending claim command once
-- the wait started by onProcessClick() has elapsed.
--------------------------------------------------------------------

function KIPN_VehicleRegistration:update()

    ISPanel.update(self)

    if not self.craftEndAtMs then
        return
    end

    if not playerHasVehicleRegistration() then
        self:abortPendingClaimForMissingRegistration()
        return
    end

    local now =
        getRuntimeMs()

    if now >= self.craftEndAtMs then

        self:sendPendingClaimCommand()

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
-- PROCESS CLICK
--
-- Requests the server-authoritative registration -> claim
-- artifact conversion (KIPN_ArtifactService.lua's
-- IssueVehicleClaim command handler).
--
-- The server independently re-validates everything: this
-- computer's dealership classification, the player's inventory,
-- and all artifact/token state. This click is only a request.
--------------------------------------------------------------------

function KIPN_VehicleRegistration:onProcessClick()

    local success = false

    local ok, err =
        pcall(
            function()

                if self.requestInFlight then
                    return
                end

                local command =
                    KIPN.Shared.Commands.ISSUE_VEHICLE_CLAIM

                if not command then

                    KIPN.Logger.Error(
                        "KIPN_VehicleRegistration:onProcessClick(): "
                        .. "ISSUE_VEHICLE_CLAIM command unavailable"
                    )

                    return
                end

                --------------------------------------------------
                -- PRE-CHECK: STILL CARRYING THE REGISTRATION ITEM
                --
                -- Re-verifies right now, recursively (matching the
                -- server's own findArtifactItem() search depth) --
                -- this button isn't gated on inventory contents at
                -- all otherwise, so without this a player who never
                -- had (or has since lost) the registration item
                -- would be made to wait out the full crafting
                -- duration for a request the server was always
                -- going to reject.
                --------------------------------------------------

                if not playerHasVehicleRegistration() then

                    self.statusKey = "error"
                    self.statusTitle = "REGISTRATION NOT FOUND"
                    self.statusSubtitle =
                        "You are not carrying a Vehicle "
                        .. "Registration Form."

                    self:checkInventory()

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

                    KIPN.Logger.Error(
                        "KIPN_VehicleRegistration:onProcessClick(): "
                        .. "computerId unavailable"
                    )

                    return
                end

                self.requestInFlight = true

                local commandArgs = {
                    computerId = computerId,
                }

                local craftSeconds =
                    resolveVehicleClaimCraftSeconds()

                --------------------------------------------------
                -- INSTANT (craftSeconds == 0)
                --------------------------------------------------

                if craftSeconds <= 0 then

                    self.statusKey = "loading"
                    self.statusTitle = "PROCESSING REGISTRATION..."
                    self.statusSubtitle =
                        "Contacting KIPN vehicle authority..."

                    self:sendClaimCommand(commandArgs)

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

                self.pendingClaimArgs =
                    commandArgs

                self.craftEndAtMs =
                    getRuntimeMs()
                    + (craftSeconds * 1000)

                self.flavorMessage =
                    KIPN.UI.PickRandomFlavorMessage()

                self.flavorMessageChangeAtMs =
                    getRuntimeMs()
                    + resolveNextFlavorIntervalMs()

                self.statusKey = "loading"
                self.statusTitle = "PROCESSING REGISTRATION..."
                self.statusSubtitle = self.flavorMessage

                -- KIPN is now crafting the Vehicle Title -- loop the
                -- claim-craft cue until the server answers
                -- (see receiveResponse()).
                KIPN.ClaimCraftSound.Start()

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_VehicleRegistration:onProcessClick(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SEND PENDING CLAIM COMMAND
--
-- Fires once update()'s flavor-text wait has elapsed.
--------------------------------------------------------------------

function KIPN_VehicleRegistration:sendPendingClaimCommand()

    local commandArgs =
        self.pendingClaimArgs

    if commandArgs and not playerHasVehicleRegistration() then
        self:abortPendingClaimForMissingRegistration()
        return
    end

    self.craftEndAtMs = nil

    self.pendingClaimArgs = nil

    if not commandArgs then
        return
    end

    self.statusSubtitle =
        "Contacting KIPN vehicle authority..."

    self:sendClaimCommand(commandArgs)
end

--------------------------------------------------------------------
-- SEND CLAIM COMMAND
--------------------------------------------------------------------

function KIPN_VehicleRegistration:sendClaimCommand(commandArgs)

    local ok, err =
        pcall(
            function()

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.ISSUE_VEHICLE_CLAIM,
                    commandArgs or {}
                )

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_VehicleRegistration:sendClaimCommand(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_VehicleRegistration:prerender()

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
        "VEHICLE REGISTRATION DESK"
    )

    ---------------------------------------------------------------
    -- STATUS
    ---------------------------------------------------------------

    if self.statusKey then

        ------------------------------------------------------------
        -- While self.craftEndAtMs is set, the wait started by
        -- onProcessClick() is still running and the command hasn't
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
    -- IDLE INSTRUCTIONS
    ---------------------------------------------------------------

    KIPN.UI.DrawStatusMessage(
        self,
        "idle",
        "PRESENT REGISTRATION FOR PROCESSING",
        "Carry a crafted Vehicle Registration Form and press "
        .. "Craft a Vehicle Title to receive a Vehicle Title "
        .. "for this dealership."
    )
end

--------------------------------------------------------------------
-- KEY PRESS
--------------------------------------------------------------------

function KIPN_VehicleRegistration:onKeyPress(key)

    return false
end

--------------------------------------------------------------------
-- SERVER RESPONSE
--
-- The terminal is the sole OnServerCommand listener. KIPN_Terminal
-- routes event/data to this function.
--------------------------------------------------------------------

function KIPN_VehicleRegistration:receiveResponse(
    event,
    data
)

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- CLAIM ARTIFACT ISSUED
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents
                        .VEHICLE_CLAIM_ARTIFACT_ISSUED then

                    self.requestInFlight = false

                    KIPN.ClaimCraftSound.Complete()

                    self.statusKey = "success"
                    self.statusTitle = "VEHICLE TITLE ISSUED"

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
                            .. "Vehicle Title was dropped on "
                            .. "the ground at your feet."

                    else

                        self.statusSubtitle =
                            "Take it to any vehicle in this "
                            .. "dealership and right-click to claim."

                    end

                    self:checkInventory()

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
                    self.statusTitle = "REGISTRATION FAILED"
                    self.statusSubtitle =
                        tostring(
                            reason
                            or "Unknown error."
                        )

                    KIPN.Logger.Error(
                        "KIPN_VehicleRegistration: server error: "
                        .. tostring(reason)
                    )

                    self:checkInventory()

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
            "KIPN_VehicleRegistration:receiveResponse(): "
            .. tostring(err)
        )
    end

end
