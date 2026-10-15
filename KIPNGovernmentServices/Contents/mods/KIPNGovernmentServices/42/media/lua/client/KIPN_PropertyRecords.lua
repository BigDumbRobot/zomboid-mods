-- KIPN_PropertyRecords.lua
--
-- Property ownership records application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- Responsibilities:
--   * Request property records from the server.
--   * Display property records and their expiry status.
--   * Send release and renewal requests (the server validates both;
--     renewal needs a powered government computer and a matching
--     Registration Form).
--   * Handle property-record responses.
--
-- This module does NOT:
--   * create terminal chrome
--   * create HOME / BACK / CLOSE controls
--   * handle terminal navigation
--   * register OnServerCommand
--   * manage UIManager membership
--   * perform proximity checks
--   * manage authentication sessions
--   * log the player out when the terminal closes
--
-- Authentication persistence is intentional.
--
-- Closing the terminal or walking away from the computer does NOT
-- invalidate the player's KIPN session. The player must explicitly
-- log out to protect the account.
--
-- UI responsibilities are delegated to KIPN_UI.lua.
--
-- KIPN_Terminal owns:
--   * HOME
--   * BACK
--   * CLOSE
--   * ESC
--   * application switching
--   * terminal-level navigation state

if isServer() then
    return
end

require "KIPN_UI"
require "KIPN_GovShared"

if not KIPN then

    error(
        "[KIPN_PropertyRecords] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then

    error(
        "[KIPN_PropertyRecords] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then

    error(
        "[KIPN_PropertyRecords] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then

    error(
        "[KIPN_PropertyRecords] "
        .. "KIPN_UI is not initialized."
    )
end

local RELEASE_CONFIRM_WINDOW_MS = 6000

-- Claims this close to expiry are flagged "RENEW SOON".
local RENEW_SOON_DAYS = 7

-- Registration Form each claim type is renewed with.
local RENEWAL_FORMS = {
    property = { itemType = "Base.KIPNPropertyRegistration", label = "Safehouse Registration Form" },
    excavation = { itemType = "Base.KIPNExcavationRegistration", label = "Excavation Registration Form" },
}

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

KIPN_PropertyRecords =
    KIPN.UI.CreateScreen(
        "KIPN_PropertyRecords"
    )

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------
--
-- IMPORTANT:
--
-- Data is NOT requested here.
--
-- KIPN_Terminal controls application activation and calls onShow()
-- when the screen becomes active.
--
-- Keeping the request in onShow() prevents duplicate requests when
-- a screen is constructed and immediately displayed.
--------------------------------------------------------------------

function KIPN_PropertyRecords:initialise()

    local success = false

    local ok, err =
        pcall(
            function()

                ISPanel.initialise(self)

                ----------------------------------------------------
                -- COMMON UI SETUP
                ----------------------------------------------------

                KIPN.UI.SetupScreen(self)
                KIPN.UI.EnableScroll(self)

                ----------------------------------------------------
                -- SCREEN STATE
                ----------------------------------------------------

                self.properties = {}

                self.loading = false

                self.timedOut = false

                self.timeoutTime = 0

                ----------------------------------------------------
                -- RELEASE ACTION STATE
                --
                -- Self-service claim release (see
                -- KIPN.Shared.Commands.RELEASE_CLAIM). Clicking a
                -- row's RELEASE action arms it; a second click on
                -- the SAME row within RELEASE_CONFIRM_WINDOW_MS
                -- confirms and sends the release. Clicking any
                -- other row, or letting the window lapse (checked
                -- in update()), disarms it. This mirrors a
                -- press-again-to-confirm pattern rather than a
                -- separate popup dialog, since KIPN screens don't
                -- have a modal confirmation primitive.
                ----------------------------------------------------

                self.pendingReleaseId = nil

                self.pendingReleaseArmedAt = 0

                -- Renewal uses the same press-again-to-confirm
                -- pattern (see KIPN.Shared.Commands.RENEW_CLAIM).
                self.pendingRenewId = nil

                self.pendingRenewArmedAt = 0

                self.pendingRenewFeedback = false

                -- Set when a RELEASE_CLAIM is sent; the next
                -- MY_CLAIMS_DATA response (only sent by the server
                -- after a successful release) plays KIPN_Beep and
                -- clears it. A server ERROR clears it silently.
                self.pendingReleaseFeedback = false

                self.rowHitRects = {}

                ----------------------------------------------------
                -- KEY EVENTS
                ----------------------------------------------------

                self:setWantKeyEvents(true)

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PropertyRecords:initialise(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- SHOW
--
-- Called by KIPN_Terminal when this application becomes active.
--
-- A new request is made each time the application is shown.
--
-- This is intentionally separate from authentication persistence.
-- Showing this application does not alter the login session.
--------------------------------------------------------------------

function KIPN_PropertyRecords:onShow()

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- RESET APPLICATION STATE
                ----------------------------------------------------

                self.loading = true

                self.timedOut = false

                self.properties = {}

                self.pendingReleaseId = nil

                self.pendingReleaseFeedback = false

                self.pendingRenewId = nil

                self.pendingRenewFeedback = false

                self.timeoutTime =
                    getRuntimeMs()
                    + 5000

                KIPN.UI.EnableScroll(self)

                ----------------------------------------------------
                -- VERIFY COMMAND
                ----------------------------------------------------

                local command =
                    KIPN.Shared.Commands.GET_MY_CLAIMS

                if not command then

                    KIPN.Logger.Error(
                        "KIPN_PropertyRecords:onShow(): "
                        .. "GET_MY_CLAIMS command unavailable"
                    )

                    self.loading = false
                    self.timedOut = true

                    return
                end

                ----------------------------------------------------
                -- REQUEST SERVER DATA
                ----------------------------------------------------

                sendClientCommand(
                    "KIPN",
                    command,
                    {}
                )

                success = true

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PropertyRecords:onShow(): "
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

function KIPN_PropertyRecords:update()

    ISPanel.update(self)

    ----------------------------------------------------------------
    -- RELEASE ARM WINDOW
    ----------------------------------------------------------------

    if self.pendingReleaseId
        and getRuntimeMs() - self.pendingReleaseArmedAt
            > RELEASE_CONFIRM_WINDOW_MS then

        self.pendingReleaseId = nil
    end

    if self.pendingRenewId
        and getRuntimeMs() - self.pendingRenewArmedAt
            > RELEASE_CONFIRM_WINDOW_MS then

        self.pendingRenewId = nil
    end

    if not self.loading then
        return
    end

    if getRuntimeMs() < self.timeoutTime then
        return
    end

    self.loading = false

    self.timedOut = true

    KIPN.Logger.Warn(
        "KIPN_PropertyRecords:update(): "
        .. "property request timed out"
    )
end

--------------------------------------------------------------------
-- DISPLAY FORMATTING
--
-- Raw claim fields (type keys, day counts) are translated into
-- human-readable text here, kept separate from the render loop.
--------------------------------------------------------------------

local CLAIM_TYPE_LABELS = {

    vehicle = "VEHICLE",

    property = "SAFEHOUSE",

    excavation = "EXCAVATION",
}

local function formatClaimType(claim)

    local label =
        claim.type
        and CLAIM_TYPE_LABELS[claim.type]
        or "UNKNOWN"

    if claim.type == "excavation"
        and claim.sizeTierLabel
    then

        return label
            .. " ("
            .. tostring(claim.sizeTierLabel)
            .. ")"
    end

    if claim.type == "property"
        and claim.managedByKIPN == false
    then

        return label
            .. " (LEGACY)"

    end

    return label
end

local function expiryDays(claim)

    local raw = tonumber(claim.expiryDaysRemaining)

    return raw and math.floor(raw + 0.5) or nil
end

local function isRenewable(claim)

    return claim.releasable ~= false
        and RENEWAL_FORMS[claim.type] ~= nil
        and not claim.ownershipNeverExpires
end

local function carriesRenewalForm(claim)

    local form = RENEWAL_FORMS[claim.type]
    local player = getPlayer()
    local inventory = player and player:getInventory()

    return form ~= nil
        and inventory ~= nil
        and inventory:containsTypeRecurse(form.itemType)
end

local function formatClaimExpiry(claim)

    if claim.ownershipNeverExpires then

        return "NEVER"
    end

    local rawDaysRemaining =
        tonumber(claim.expiryDaysRemaining)

    if not rawDaysRemaining then

        return "---"
    end

    local daysRemaining =
        math.floor(rawDaysRemaining + 0.5)

    if daysRemaining <= 0 then

        return "EXPIRED"
    end

    if daysRemaining == 1 then

        return "1 DAY"
    end

    return tostring(daysRemaining)
        .. " DAYS"
end

--------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------

function KIPN_PropertyRecords:prerender()

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
            "PROPERTY RECORDS"
        )

    ---------------------------------------------------------------
    -- LOADING
    ---------------------------------------------------------------

    if self.loading then

        KIPN.UI.DrawStatusMessage(
            self,
            "loading",
            "SEARCHING PROPERTY RECORDS...",
            "Connecting to network database..."
        )

        return
    end

    ---------------------------------------------------------------
    -- TIMEOUT
    ---------------------------------------------------------------

    if self.timedOut
        and #self.properties == 0 then

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

    if #self.properties == 0 then

        KIPN.UI.DrawStatusMessage(
            self,
            "empty",
            "NO CLAIM RECORDS FOUND",
            "You do not hold any registered property "
                .. "or excavation claims."
        )

        return
    end

    ---------------------------------------------------------------
    -- DOCUMENT SECTIONS
    ---------------------------------------------------------------

    local groupedProperties = {
        property = {},
        vehicle = {},
        excavation = {}
    }
    
    local otherProperties = {}
    
    for _, claim in ipairs(self.properties) do
        local t = claim.type
        if groupedProperties[t] then
            table.insert(groupedProperties[t], claim)
        else
            table.insert(otherProperties, claim)
        end
    end

    local CLAIM_TYPE_TITLES = {
        property = "SAFEHOUSE CLAIMS",
        vehicle = "VEHICLE CLAIMS",
        excavation = "EXCAVATION CLAIMS"
    }

    local orderedTypes = { "property", "vehicle", "excavation" }

    local rowClaimIds = {}
    local rowHitRects = {}
    
    local dim = KIPN.UI.Theme.dimText
    local txt = KIPN.UI.Theme.text
    local acc = KIPN.UI.Theme.accent
    local warn = KIPN.UI.Theme.warning
    
    local function drawClaimBlock(claim)
        
        local typeText = formatClaimType(claim)
        
        local locationText = "---"
        if claim.locationX and claim.locationY then
            locationText = string.format("X:%d  Y:%d", claim.locationX, claim.locationY)
        end
        
        local claimedText = "---"
        local calendar = claim.createdAtCalendar
        if type(calendar) == "table" and calendar.month and calendar.day and calendar.year then
            claimedText = string.format("%02d/%02d/%d", calendar.month, calendar.day, calendar.year)
        end
        
        local expiresText = formatClaimExpiry(claim)
        local releasable = claim.releasable ~= false
        local renewable = isRenewable(claim)
        local daysLeft = expiryDays(claim)
        local renewSoon = renewable and daysLeft ~= nil and daysLeft <= RENEW_SOON_DAYS
        if renewSoon then
            expiresText = expiresText .. " - RENEW SOON"
        end
        
        local isPending = self.pendingReleaseId and self.pendingReleaseId == claim.id
        local actionText = not releasable and "LEGACY" or (isPending and "[ CONFIRM RELEASE? ]" or "[ RELEASE CLAIM ]")
        local renewPending = self.pendingRenewId and self.pendingRenewId == claim.id
        local hasForm = renewable and carriesRenewalForm(claim)
        local renewText = renewPending and "[ CONFIRM RENEW? ]" or "[ RENEW ]"
        
        self:drawText(typeText, 20, KIPN.UI.ScrollY(self, y), acc.r, acc.g, acc.b, acc.a, KIPN.UI.Theme.fontBody)
        self:drawText("ID: " .. tostring(claim.id or "---"), 300, KIPN.UI.ScrollY(self, y), dim.r, dim.g, dim.b, dim.a, KIPN.UI.Theme.fontBody)
        y = y + 18
        
        self:drawText("LOCATION: " .. locationText, 20, KIPN.UI.ScrollY(self, y), txt.r, txt.g, txt.b, txt.a, KIPN.UI.Theme.fontBody)
        y = y + 18
        
        self:drawText("CLAIMED: " .. claimedText, 20, KIPN.UI.ScrollY(self, y), txt.r, txt.g, txt.b, txt.a, KIPN.UI.Theme.fontBody)
        local expiresColor = renewSoon and warn or txt
        self:drawText("EXPIRES: " .. expiresText, 200, KIPN.UI.ScrollY(self, y), expiresColor.r, expiresColor.g, expiresColor.b, expiresColor.a, KIPN.UI.Theme.fontBody)
        y = y + 18
        
        local actionColor = releasable and txt or dim
        if isPending then
            actionColor = warn
        end
        
        self:drawText(actionText, 20, KIPN.UI.ScrollY(self, y), actionColor.r, actionColor.g, actionColor.b, actionColor.a, KIPN.UI.Theme.fontBody)
        
        local releaseRight = 20 + getTextManager():MeasureStringX(KIPN.UI.Theme.fontBody, actionText)
        
        if releasable then
            rowHitRects[#rowHitRects + 1] = {
                x1 = 0,
                x2 = releaseRight + 10,
                y1 = KIPN.UI.ScrollY(self, y - 2),
                y2 = KIPN.UI.ScrollY(self, y + 18),
                index = #rowClaimIds + 1,
                action = "release",
            }
            rowClaimIds[#rowClaimIds + 1] = claim.id
        end
        
        if renewable then
            local renewX = releaseRight + 30
            local renewColor = renewPending and warn or (hasForm and txt or dim)
            self:drawText(renewText, renewX, KIPN.UI.ScrollY(self, y), renewColor.r, renewColor.g, renewColor.b, renewColor.a, KIPN.UI.Theme.fontBody)
            if hasForm then
                rowHitRects[#rowHitRects + 1] = {
                    x1 = renewX - 10,
                    x2 = renewX + getTextManager():MeasureStringX(KIPN.UI.Theme.fontBody, renewText) + 10,
                    y1 = KIPN.UI.ScrollY(self, y - 2),
                    y2 = KIPN.UI.ScrollY(self, y + 18),
                    index = #rowClaimIds + 1,
                    action = "renew",
                }
                rowClaimIds[#rowClaimIds + 1] = claim.id
            else
                y = y + 18
                self:drawText("Renew at a Government computer with a " .. RENEWAL_FORMS[claim.type].label .. ".",
                    20, KIPN.UI.ScrollY(self, y), dim.r, dim.g, dim.b, dim.a, KIPN.UI.Theme.fontBody)
            end
        end
        
        y = y + 32
    end
    
    for _, claimType in ipairs(orderedTypes) do
        local claims = groupedProperties[claimType]
        if claims and #claims > 0 then
            y = KIPN.UI.DrawSectionHeader(self, y, CLAIM_TYPE_TITLES[claimType])
            y = y + 8
            for _, claim in ipairs(claims) do
                drawClaimBlock(claim)
            end
            y = y + 16
        end
    end
    
    if #otherProperties > 0 then
        y = KIPN.UI.DrawSectionHeader(self, y, "OTHER CLAIMS")
        y = y + 8
        for _, claim in ipairs(otherProperties) do
            drawClaimBlock(claim)
        end
    end
    
    if self.pendingRenewId then
        y = y + 8
        self:drawText(
            "Click [ CONFIRM RENEW? ] to turn in the form and restart the ownership period.",
            20,
            KIPN.UI.ScrollY(self, y),
            warn.r,
            warn.g,
            warn.b,
            warn.a,
            KIPN.UI.Theme.fontBody
        )
        y = y + 24
    end

    if self.pendingReleaseId then
        y = y + 8
        self:drawText(
            "Click [ CONFIRM RELEASE? ] again to release the claim.",
            20,
            KIPN.UI.ScrollY(self, y),
            warn.r,
            warn.g,
            warn.b,
            warn.a,
            KIPN.UI.Theme.fontBody
        )
        y = y + 24
    end

    self.rowHitRects = rowHitRects
    self.rowClaimIds = rowClaimIds
    
    KIPN.UI.SetContentHeight(self, y + 20)
end

--------------------------------------------------------------------
-- MOUSE INPUT
--
-- Only the action line is interactive. Clicking RELEASE or RENEW
-- arms that action on that row (see update()'s auto-disarm window);
-- clicking the CONFIRM? prompt on the still-armed row sends
-- RELEASE_CLAIM or RENEW_CLAIM. Arming anything else discards the
-- previous arm.
--------------------------------------------------------------------

function KIPN_PropertyRecords:onMouseDown(x, y)

    local success = false

    local ok, err =
        pcall(
            function()

                if not self.rowHitRects
                    or not self.rowClaimIds then

                    return
                end

                for _, rect in ipairs(self.rowHitRects) do

                    if y >= rect.y1
                        and y < rect.y2
                        and x >= rect.x1
                        and x < rect.x2 then

                        local claimId =
                            self.rowClaimIds[rect.index]

                        if not claimId then

                            return
                        end

                        if rect.action == "renew" then

                            self.pendingReleaseId = nil

                            if self.pendingRenewId == claimId then

                                self.pendingRenewId = nil

                                self:sendRenewClaim(claimId)

                            else

                                self.pendingRenewId = claimId

                                self.pendingRenewArmedAt = getRuntimeMs()
                            end

                        elseif self.pendingReleaseId == claimId then

                            self.pendingReleaseId = nil

                            self:sendReleaseClaim(claimId)

                        else

                            self.pendingRenewId = nil

                            self.pendingReleaseId =
                                claimId

                            self.pendingReleaseArmedAt =
                                getRuntimeMs()
                        end

                        success = true

                        return
                    end
                end

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PropertyRecords:onMouseDown(): "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- SEND RELEASE CLAIM
--------------------------------------------------------------------

function KIPN_PropertyRecords:sendReleaseClaim(claimId)

    local ok, err =
        pcall(
            function()

                local player = getPlayer()
                local username = player and player:getUsername() or "unknown"

                print("[KIPN Safehouse Release] Request initiated")
                print("[KIPN Safehouse Release] claimId=" .. tostring(claimId))
                print("[KIPN Safehouse Release] requestingPlayer=" .. tostring(username))

                self.pendingReleaseFeedback = true

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.RELEASE_CLAIM,
                    {
                        claimId = claimId,
                    }
                )
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PropertyRecords:sendReleaseClaim(): "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- SEND RENEW CLAIM
--
-- The server checks the computer (government zone, power), the
-- claim's owner, and consumes the matching Registration Form.
--------------------------------------------------------------------

function KIPN_PropertyRecords:sendRenewClaim(claimId)

    local ok, err =
        pcall(
            function()

                local computerId =
                    self.terminal
                    and self.terminal.GetComputerId
                    and self.terminal:GetComputerId()

                if not computerId then

                    local player = getPlayer()

                    if player then
                        player:Say("Unable to identify this terminal.")
                    end

                    return
                end

                self.pendingRenewFeedback = true

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.RENEW_CLAIM,
                    {
                        claimId = claimId,
                        computerId = computerId,
                    }
                )
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_PropertyRecords:sendRenewClaim(): "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- KEY PRESS
--------------------------------------------------------------------
--
-- Keyboard navigation remains intentionally unused.
--
-- ESC is owned by KIPN_Terminal.
--------------------------------------------------------------------

function KIPN_PropertyRecords:onKeyPress(key)

    return false
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--------------------------------------------------------------------

function KIPN_PropertyRecords:onMouseWheel(del)

    return KIPN.UI.OnScrollMouseWheel(self, del)
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

function KIPN_PropertyRecords:receiveResponse(
    event,
    data
)

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- CLAIM DATA
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA then

                    if type(data) == "table" then

                        -- GET_MY_CLAIMS returns every claim type the
                        -- player owns; Property Records shows only the
                        -- Government Services ones. Vehicle claims have
                        -- their own screen (KIPN: Vehicle Services).
                        local govOnly = {}
                        for _, claim in ipairs(data) do
                            if type(claim) == "table"
                                and (claim.type == "property"
                                    or claim.type == "excavation")
                            then
                                govOnly[#govOnly + 1] = claim
                            end
                        end
                        self.properties = govOnly

                    else

                        self.properties = {}

                        KIPN.Logger.Warn(
                            "KIPN_PropertyRecords:receiveResponse(): "
                            .. "claims response data was not a table"
                        )
                    end

                    self.loading = false

                    self.timedOut = false

                    ------------------------------------------------
                    -- RELEASE CONFIRMATION CUE
                    --
                    -- After a release request the server only
                    -- re-sends MY_CLAIMS_DATA on success, so a
                    -- pending flag here means the release went
                    -- through. UI cue only (is3D = false) -- see
                    -- media/scripts/KIPN_Sounds.txt "KIPN_Beep".
                    ------------------------------------------------

                    if self.pendingReleaseFeedback then

                        self.pendingReleaseFeedback = false

                        if getSoundManager then

                            getSoundManager():playUISound(
                                "KIPN_Beep"
                            )
                        end
                    end

                    success = true

                    return
                end

                ----------------------------------------------------
                -- CLAIM RENEWED
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.CLAIM_RENEWED then

                    self.pendingRenewFeedback = false

                    if getSoundManager then

                        getSoundManager():playUISound(
                            "KIPN_Beep"
                        )
                    end

                    local player = getPlayer()

                    if player then
                        player:Say("Claim renewed. The ownership period has restarted.")
                    end

                    success = true

                    return
                end

                ----------------------------------------------------
                -- SERVER ERROR
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.ERROR then

                    self.loading = false

                    self.timedOut = false

                    self.pendingReleaseFeedback = false

                    self.pendingRenewFeedback = false

                    local player =
                        getPlayer()

                    if player then

                        local message =
                            type(data) == "table"
                            and (data.message or data.reason or data.code)
                            or data

                        player:Say(
                            "ERROR: "
                            .. tostring(message)
                        )
                    end

                    KIPN.Logger.Error(
                        "KIPN_PropertyRecords: "
                        .. "server error: "
                        .. tostring(data)
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
            "KIPN_PropertyRecords:receiveResponse(): "
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
