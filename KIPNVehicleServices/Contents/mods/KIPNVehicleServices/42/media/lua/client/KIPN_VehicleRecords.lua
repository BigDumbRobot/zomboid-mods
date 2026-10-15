-- KIPN_VehicleRecords.lua
--
-- Vehicle ownership claim records screen for KIPN: Vehicle Services.
-- Adapted from KIPN: Government Services' KIPN_PropertyRecords.lua;
-- shows only the caller's vehicle claims (GET_MY_CLAIMS returns all).
--
-- Property ownership records application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- Responsibilities:
--   * Request property records from the server.
--   * Display property records.
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

if not KIPN then

    error(
        "[KIPN_VehicleRecords] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then

    error(
        "[KIPN_VehicleRecords] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Logger then

    error(
        "[KIPN_VehicleRecords] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then

    error(
        "[KIPN_VehicleRecords] "
        .. "KIPN_UI is not initialized."
    )
end

local RELEASE_CONFIRM_WINDOW_MS = 6000

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

KIPN_VehicleRecords =
    KIPN.UI.CreateScreen(
        "KIPN_VehicleRecords"
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

function KIPN_VehicleRecords:initialise()

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
            "KIPN_VehicleRecords:initialise(): "
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

function KIPN_VehicleRecords:onShow()

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
                        "KIPN_VehicleRecords:onShow(): "
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
            "KIPN_VehicleRecords:onShow(): "
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

function KIPN_VehicleRecords:update()

    ISPanel.update(self)

    ----------------------------------------------------------------
    -- RELEASE ARM WINDOW
    ----------------------------------------------------------------

    if self.pendingReleaseId
        and getRuntimeMs() - self.pendingReleaseArmedAt
            > RELEASE_CONFIRM_WINDOW_MS then

        self.pendingReleaseId = nil
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
        "KIPN_VehicleRecords:update(): "
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

function KIPN_VehicleRecords:prerender()

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
            "VEHICLE RECORDS"
        )

    ---------------------------------------------------------------
    -- LOADING
    ---------------------------------------------------------------

    if self.loading then

        KIPN.UI.DrawStatusMessage(
            self,
            "loading",
            "SEARCHING VEHICLE RECORDS...",
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
            "You do not hold any registered vehicle claims."
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
        
        local isPending = self.pendingReleaseId and self.pendingReleaseId == claim.id
        local actionText = not releasable and "LEGACY" or (isPending and "[ CONFIRM RELEASE? ]" or "[ RELEASE CLAIM ]")
        
        self:drawText(typeText, 20, KIPN.UI.ScrollY(self, y), acc.r, acc.g, acc.b, acc.a, KIPN.UI.Theme.fontBody)
        self:drawText("ID: " .. tostring(claim.id or "---"), 300, KIPN.UI.ScrollY(self, y), dim.r, dim.g, dim.b, dim.a, KIPN.UI.Theme.fontBody)
        y = y + 18
        
        self:drawText("LOCATION: " .. locationText, 20, KIPN.UI.ScrollY(self, y), txt.r, txt.g, txt.b, txt.a, KIPN.UI.Theme.fontBody)
        y = y + 18
        
        self:drawText("CLAIMED: " .. claimedText, 20, KIPN.UI.ScrollY(self, y), txt.r, txt.g, txt.b, txt.a, KIPN.UI.Theme.fontBody)
        self:drawText("EXPIRES: " .. expiresText, 200, KIPN.UI.ScrollY(self, y), txt.r, txt.g, txt.b, txt.a, KIPN.UI.Theme.fontBody)
        y = y + 18
        
        local actionColor = releasable and txt or dim
        if isPending then
            actionColor = warn
        end
        
        self:drawText(actionText, 20, KIPN.UI.ScrollY(self, y), actionColor.r, actionColor.g, actionColor.b, actionColor.a, KIPN.UI.Theme.fontBody)
        
        if releasable then
            rowHitRects[#rowHitRects + 1] = {
                y1 = KIPN.UI.ScrollY(self, y - 2),
                y2 = KIPN.UI.ScrollY(self, y + 18),
                index = #rowClaimIds + 1
            }
            rowClaimIds[#rowClaimIds + 1] = claim.id
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
-- Only the ACTION column is interactive -- clicking RELEASE arms
-- that row (see self.pendingReleaseId / update()'s auto-disarm
-- window), clicking CONFIRM? on the still-armed row sends
-- RELEASE_CLAIM. Clicking any other row's RELEASE re-arms onto
-- that row instead, discarding the previous arm.
--------------------------------------------------------------------

function KIPN_VehicleRecords:onMouseDown(_x, y)

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
                        and y < rect.y2 then

                        local claimId =
                            self.rowClaimIds[rect.index]

                        if not claimId then

                            return
                        end

                        if self.pendingReleaseId == claimId then

                            self.pendingReleaseId = nil

                            self:sendReleaseClaim(claimId)

                        else

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
            "KIPN_VehicleRecords:onMouseDown(): "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- SEND RELEASE CLAIM
--------------------------------------------------------------------

function KIPN_VehicleRecords:sendReleaseClaim(claimId)

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
            "KIPN_VehicleRecords:sendReleaseClaim(): "
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

function KIPN_VehicleRecords:onKeyPress(key)

    return false
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--------------------------------------------------------------------

function KIPN_VehicleRecords:onMouseWheel(del)

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

function KIPN_VehicleRecords:receiveResponse(
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

                        local vehicleOnly = {}
                        for _, claim in ipairs(data) do
                            if type(claim) == "table" and claim.type == "vehicle" then
                                vehicleOnly[#vehicleOnly + 1] = claim
                            end
                        end
                        self.properties = vehicleOnly

                    else

                        self.properties = {}

                        KIPN.Logger.Warn(
                            "KIPN_VehicleRecords:receiveResponse(): "
                            .. "claims response data was not a table"
                        )
                    end

                    self.loading = false

                    self.timedOut = false

                    ------------------------------------------------
                    -- RELEASE CONFIRMATION CUE
                    --
                    -- The server only re-sends MY_CLAIMS_DATA
                    -- after a successful self-service release, so
                    -- a pending flag here means the release went
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
                -- SERVER ERROR
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.ERROR then

                    self.loading = false

                    self.timedOut = false

                    self.pendingReleaseFeedback = false

                    local player =
                        getPlayer()

                    if player then

                        player:Say(
                            "ERROR: "
                            .. tostring(data)
                        )
                    end

                    KIPN.Logger.Error(
                        "KIPN_VehicleRecords: "
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
            "KIPN_VehicleRecords:receiveResponse(): "
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
