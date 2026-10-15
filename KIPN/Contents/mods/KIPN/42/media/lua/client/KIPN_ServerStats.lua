-- KIPN_ServerStats.lua
--
-- Server statistics application.
--
-- This is a TERMINAL CHILD SCREEN.
--
-- Responsibilities:
--   * Request server statistics from the server.
--   * Handle server-statistics responses routed by KIPN_Terminal.
--   * Maintain statistics application state.
--   * Render server statistics.
--   * Refresh statistics periodically while the application is active.
--
-- This module does NOT:
--   * create terminal chrome
--   * create HOME / CLOSE controls
--   * register OnServerCommand
--   * manage UIManager membership
--   * perform proximity checks
--   * manage authentication sessions
--   * manage terminal dimensions
--   * own terminal navigation
--
-- KIPN_Terminal owns the terminal shell and response routing.
--
-- UI responsibilities are delegated to KIPN_UI.lua.

if isServer() then
    return
end

require "KIPN_UI"
require "KIPN_StatsCatalog"

if not KIPN then

    error(
        "[KIPN_ServerStats] "
        .. "KIPN core is not initialized."
    )
end

if not KIPN.Shared then

    error(
        "[KIPN_ServerStats] "
        .. "KIPN_Shared is not initialized."
    )
end

if not KIPN.Shared.StatsCatalog then

    error(
        "[KIPN_ServerStats] "
        .. "KIPN_StatsCatalog is not initialized."
    )
end

if not KIPN.Logger then

    error(
        "[KIPN_ServerStats] "
        .. "KIPN.Logger is not initialized."
    )
end

if not KIPN.UI then

    error(
        "[KIPN_ServerStats] "
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

--------------------------------------------------------------------
-- SCREEN
--------------------------------------------------------------------
--
-- KIPN.UI.CreateScreen() owns the common ISPanel derive/new
-- boilerplate for all child applications.
--------------------------------------------------------------------

KIPN_ServerStats =
    KIPN.UI.CreateScreen(
        "KIPN_ServerStats"
    )

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_ServerStats:initialise()

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
                -- APPLICATION STATE
                ----------------------------------------------------

                self.stats = nil

                self.leaderboard = nil

                self.myStats = nil

                self.loading = false

                self.timedOut = false

                self.timeoutTime = 0

                self.lastRefresh = 0

                ----------------------------------------------------
                -- STAT DISPLAY POLICY
                --
                -- Loaded from the server-owned statsDisplaySettings
                -- namespace. Every player receives the same visibility
                -- policy; only SYSOP_CONFIGURATION users may edit it.
                ----------------------------------------------------

                self.statVisibility = {}
                self.statVisibilityLoaded = false
                self.canEditStatVisibility = false
                self.displaySavePending = false
                self.displayDirty = false
                self.displayMessage = nil
                self.displayHitRows = {}

                ----------------------------------------------------
                -- TABS
                --
                -- "server" (mode/uptime/leaderboard/totals) and
                -- "player" (the viewing player's own stats). Only
                -- the activeTab state is set up here -- the actual
                -- tab BUTTONS are created in onShow(), see
                -- createTabButtons() below, because self.javaObject
                -- does not exist yet at this point in the screen
                -- lifecycle (KIPN_Terminal:setScreen() calls
                -- initialise() before instantiate()). Attaching
                -- child widgets here forces an early instantiate()
                -- via addChild(), which is then discarded when
                -- instantiate() runs again for real -- the buttons
                -- end up attached to a javaObject that no longer
                -- backs this panel, so they never render.
                ----------------------------------------------------

                self.activeTab = "server"

                ----------------------------------------------------
                -- SCROLLING
                --
                -- Both tabs can grow past the panel's visible height
                -- once several stats/leaderboard sections are
                -- enabled -- opt into KIPN.UI's generic scroll
                -- container rather than hand-rolling an offset.
                --
                -- contentTop = 112: the tab button row sits at
                -- y=84..108 (see createTabButtons()); the scrollable
                -- body is hard-clipped to start just below it so
                -- scrolled-up text can never render behind the tabs.
                ----------------------------------------------------

                KIPN.UI.EnableScroll(self, { contentTop = 112 })

                ----------------------------------------------------
                -- KEY EVENTS
                ----------------------------------------------------

                self:setWantKeyEvents(true)

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_ServerStats:initialise(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- CREATE TAB BUTTONS
--
-- Called from onShow(), not initialise() -- see the TABS comment in
-- initialise() above for why. self.javaObject is guaranteed to exist
-- by onShow() time, since KIPN_Terminal:setScreen() has already
-- called instantiate() before invoking onShow().
--
-- Each KIPN_ServerStats instance only ever receives onShow() once
-- (KIPN_Terminal:setScreen() constructs a fresh screen instance per
-- navigation), so there is no risk of duplicate buttons here.
--------------------------------------------------------------------

function KIPN_ServerStats:createTabButtons()

    if self.tabButtonServer
        or self.tabButtonPlayer then

        return
    end

    self.tabButtonServer =
        KIPN.UI.CreateButton(
            self,
            20,
            84,
            120,
            24,
            "SERVER",
            function()
                self:setActiveTab("server")
            end,
            { fixed = true }
        )

    self.tabButtonPlayer =
        KIPN.UI.CreateButton(
            self,
            146,
            84,
            120,
            24,
            "PLAYER",
            function()
                self:setActiveTab("player")
            end,
            { fixed = true }
        )

    self:updateTabButtonStyles()
end

--------------------------------------------------------------------
-- CREATE DISPLAY OPTIONS CONTROLS
--
-- This tab is created only after the server confirms that the viewing
-- player has SYSOP_CONFIGURATION. Non-admin players still receive the
-- visibility policy, but never receive editing controls.
--------------------------------------------------------------------

function KIPN_ServerStats:createDisplayControls()

    if not self.canEditStatVisibility then
        return
    end

    if not self.tabButtonDisplay then
        self.tabButtonDisplay =
            KIPN.UI.CreateButton(
                self,
                272,
                84,
                120,
                24,
                "DISPLAY",
                function()
                    self:setActiveTab("display")
                end,
                { fixed = true }
            )
    end

    if not self.displaySaveButton then
        self.displaySaveButton =
            KIPN.UI.CreateButton(
                self,
                math.max(404, self.width - 110),
                84,
                90,
                24,
                "SAVE",
                function()
                    self:saveDisplaySettings()
                end,
                { fixed = true }
            )

        if self.displaySaveButton
            and self.displaySaveButton.setVisible then

            self.displaySaveButton:setVisible(false)
        end
    end

    self:updateTabButtonStyles()
end

--------------------------------------------------------------------
-- TAB SWITCHING
--------------------------------------------------------------------

function KIPN_ServerStats:setActiveTab(tab)

    if tab == "display"
        and not self.canEditStatVisibility then

        return
    end

    if self.activeTab == tab then
        return
    end

    self.activeTab = tab

    self:updateTabButtonStyles()

    -- Reaching a resting scroll position that made sense for the
    -- previous tab's (different) content height could otherwise
    -- leave the newly-shown tab scrolled past its own content.
    self:setYScroll(0)
end

function KIPN_ServerStats:updateTabButtonStyles()

    local activeColor =
        KIPN.UI.Theme.accent

    local inactiveColor =
        KIPN.UI.Theme.button
        and KIPN.UI.Theme.button.background

    if self.tabButtonServer then

        self.tabButtonServer.backgroundColor =
            (self.activeTab == "server")
            and activeColor
            or inactiveColor
    end

    if self.tabButtonPlayer then

        self.tabButtonPlayer.backgroundColor =
            (self.activeTab == "player")
            and activeColor
            or inactiveColor
    end

    if self.tabButtonDisplay then

        self.tabButtonDisplay.backgroundColor =
            (self.activeTab == "display")
            and activeColor
            or inactiveColor
    end

    if self.displaySaveButton
        and self.displaySaveButton.setVisible then

        self.displaySaveButton:setVisible(
            self.activeTab == "display"
            and self.canEditStatVisibility
        )

        if self.displaySaveButton.setTitle then

            if self.displaySavePending then
                self.displaySaveButton:setTitle("SAVING...")
            elseif self.displayDirty then
                self.displaySaveButton:setTitle("SAVE *")
            else
                self.displaySaveButton:setTitle("SAVE")
            end
        end
    end
end

--------------------------------------------------------------------
-- SHOW
--
-- Called by KIPN_Terminal when this application becomes active.
--
-- The server request belongs here rather than in initialise(),
-- because application construction and application activation are
-- separate lifecycle events.
--------------------------------------------------------------------

function KIPN_ServerStats:onShow()

    local success = false

    local ok, err =
        pcall(
            function()

                -- Attach the native scrollbar now that the terminal
                -- has instantiated this child screen. initialise()
                -- only records the screen's scrolling opt-in.
                KIPN.UI.EnableScroll(self, { contentTop = 112 })

                self:createTabButtons()

                self:requestStatistics()

                self:requestDisplaySettings()

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_ServerStats:onShow(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- LEAVE SCREEN
--
-- No event listeners or external resources are owned by this
-- application.
--------------------------------------------------------------------

function KIPN_ServerStats:onLeaveScreen()

    local success = false

    local ok, err =
        pcall(
            function()

                -- Nothing to clean up.

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_ServerStats:onLeaveScreen(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- REQUEST STATISTICS
--
-- Server Stats is completely server-authoritative.
--
-- There is deliberately no singleplayer/local-data path.
--------------------------------------------------------------------

function KIPN_ServerStats:requestStatistics()

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- RESET REQUEST STATE
                ----------------------------------------------------

                self.loading = true

                self.timedOut = false

                self.timeoutTime =
                    getRuntimeMs() + 5000

                ----------------------------------------------------
                -- VERIFY COMMAND
                ----------------------------------------------------

                local command =
                    KIPN.Shared.Commands.GET_SERVER_STATS

                if not command then

                    self.loading = false

                    self.timedOut = true

                    KIPN.Logger.Error(
                        "KIPN_ServerStats:requestStatistics(): "
                        .. "GET_SERVER_STATS command unavailable"
                    )

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

                ----------------------------------------------------
                -- REQUEST LEADERBOARD DATA
                --
                -- Sent alongside the core stats request so the
                -- leaderboard is polled fresh every time this page
                -- opens. Shares the same loading/timeout window;
                -- its response is handled independently so a
                -- leaderboard failure never blocks the rest of the
                -- page.
                ----------------------------------------------------

                local leaderboardCommand =
                    KIPN.Shared.Commands.GET_LEADERBOARD

                if leaderboardCommand then

                    sendClientCommand(
                        "KIPN",
                        leaderboardCommand,
                        {}
                    )

                else

                    KIPN.Logger.Error(
                        "KIPN_ServerStats:requestStatistics(): "
                        .. "GET_LEADERBOARD command unavailable"
                    )
                end

                ----------------------------------------------------
                -- REQUEST MY OWN STATS (PLAYER TAB)
                --
                -- Same independence rationale as GET_LEADERBOARD
                -- above -- a failure here must not block the SERVER
                -- tab's content.
                ----------------------------------------------------

                local myStatsCommand =
                    KIPN.Shared.Commands.GET_MY_STATS

                if myStatsCommand then

                    sendClientCommand(
                        "KIPN",
                        myStatsCommand,
                        {}
                    )

                else

                    KIPN.Logger.Error(
                        "KIPN_ServerStats:requestStatistics(): "
                        .. "GET_MY_STATS command unavailable"
                    )
                end

                success = true
            end
        )

    if not ok then

        self.loading = false
        self.timedOut = true

        KIPN.Logger.Error(
            "KIPN_ServerStats:requestStatistics(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- REQUEST STAT DISPLAY SETTINGS
--
-- Public read: every player needs the same policy so hidden stats are
-- hidden consistently on both SERVER and PLAYER tabs. The server also
-- returns canEdit=true only for SYSOP_CONFIGURATION users.
--------------------------------------------------------------------

function KIPN_ServerStats:requestDisplaySettings()

    sendClientCommand(
        "KIPN",
        "GetStatsDisplaySettings",
        {}
    )
end

--------------------------------------------------------------------
-- SAVE STAT DISPLAY SETTINGS
--------------------------------------------------------------------

function KIPN_ServerStats:saveDisplaySettings()

    if not self.canEditStatVisibility
        or self.displaySavePending then

        return
    end

    local visible = {}
    local seen = {}

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do

        if entry
            and entry.sandboxOption then

            local optionName =
                "Stat"
                .. tostring(entry.sandboxOption)
                .. "Visible"

            if not seen[optionName] then

                seen[optionName] = true

                visible[optionName] =
                    self.statVisibility[optionName] ~= false
            end
        end
    end

    self.displaySavePending = true
    self.displayMessage = "Saving display options..."
    self:updateTabButtonStyles()

    sendClientCommand(
        "KIPN",
        "SaveStatsDisplaySettings",
        {
            visible = visible,
        }
    )
end

--------------------------------------------------------------------
-- RECEIVE RESPONSE
--
-- KIPN_Terminal is the single client-side server-response router.
--
-- This application does NOT register its own OnServerCommand
-- listener.
--------------------------------------------------------------------

function KIPN_ServerStats:receiveResponse(
    event,
    payload
)

    local success = false

    local ok, err =
        pcall(
            function()

                self:handleServerResponse(
                    event,
                    payload
                )

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_ServerStats:receiveResponse(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- HANDLE SERVER RESPONSE
--
-- Interprets the response routed by KIPN_Terminal.
--
-- The terminal transports the response.
-- Server Stats owns interpretation of the statistics payload.
--------------------------------------------------------------------

function KIPN_ServerStats:handleServerResponse(
    event,
    payload
)

    local success = false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- STAT DISPLAY SETTINGS
                ----------------------------------------------------

                if event == "statsDisplaySettings" then

                    if type(payload) == "table"
                        and type(payload.visible) == "table" then

                        self.statVisibility = payload.visible
                        self.statVisibilityLoaded = true
                        self.canEditStatVisibility =
                            payload.canEdit == true

                        if self.canEditStatVisibility then
                            self:createDisplayControls()
                        elseif self.activeTab == "display" then
                            self:setActiveTab("server")
                        end

                        self.displayMessage = nil
                    end

                    success = true
                    return
                end

                if event == "statsDisplaySettingsSaved" then

                    self.displaySavePending = false

                    if type(payload) == "table"
                        and payload.success == true then

                        if type(payload.visible) == "table" then
                            self.statVisibility = payload.visible
                            self.statVisibilityLoaded = true
                        end

                        self.displayDirty = false
                        self.displayMessage =
                            "Display options saved server-wide."
                    else

                        self.displayMessage =
                            "Save failed: "
                            .. tostring(
                                payload
                                and payload.message
                                or "unknown error"
                            )
                    end

                    self:updateTabButtonStyles()

                    success = true
                    return
                end

                ----------------------------------------------------
                -- LEADERBOARD RESPONSE
                --
                -- Handled independently of the core stats response
                -- below, so a leaderboard failure never blocks the
                -- rest of the page.
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.LEADERBOARD_DATA then

                    if type(payload) == "table" then

                        self.leaderboard = payload

                    else

                        KIPN.Logger.Warn(
                            "KIPN_ServerStats:handleServerResponse(): "
                            .. "invalid leaderboard payload"
                        )
                    end

                    success = true

                    return
                end

                ----------------------------------------------------
                -- MY STATS RESPONSE (PLAYER TAB)
                --
                -- Handled independently for the same reason as the
                -- leaderboard response above.
                ----------------------------------------------------

                if event
                    == KIPN.Shared.ResponseEvents.MY_STATS_DATA then

                    if type(payload) == "table" then

                        self.myStats = payload

                    else

                        KIPN.Logger.Warn(
                            "KIPN_ServerStats:handleServerResponse(): "
                            .. "invalid my-stats payload"
                        )
                    end

                    success = true

                    return
                end

                ----------------------------------------------------
                -- VERIFY RESPONSE TYPE
                ----------------------------------------------------

                if event
                    ~= KIPN.Shared.ResponseEvents.SERVER_STATS then

                    success = true

                    return
                end

                ----------------------------------------------------
                -- VERIFY PAYLOAD
                ----------------------------------------------------

                if type(payload) ~= "table" then

                    KIPN.Logger.Warn(
                        "KIPN_ServerStats:handleServerResponse(): "
                        .. "invalid statistics payload"
                    )

                    self.stats = nil
                    self.loading = false
                    self.timedOut = true
                    self.lastRefresh = getRuntimeMs()

                    return
                end

                ----------------------------------------------------
                -- STORE SERVER STATISTICS
                ----------------------------------------------------

                self.stats = payload

                self.loading = false

                self.timedOut = false

                self.lastRefresh =
                    getRuntimeMs()

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_ServerStats:handleServerResponse(): "
            .. tostring(err)
        )
    end

end

--------------------------------------------------------------------
-- UPDATE
--
-- Handles:
--   * request timeout
--   * periodic refresh
--
-- IMPORTANT:
--
-- A previous version returned when self.stats was nil. That meant
-- that once a request timed out, the application could never recover
-- because the 30-second refresh path was unreachable.
--
-- The refresh timer therefore operates independently of whether
-- valid statistics currently exist.
--------------------------------------------------------------------

function KIPN_ServerStats:update()

    ISPanel.update(self)

    ---------------------------------------------------------------
    -- WAIT FOR CURRENT REQUEST
    ---------------------------------------------------------------

    if self.loading then

        if getRuntimeMs() < self.timeoutTime then
            return
        end

        self.loading = false

        self.timedOut = true

        self.lastRefresh =
            getRuntimeMs() - 30000

        KIPN.Logger.Warn(
            "KIPN_ServerStats:update(): "
            .. "server statistics request timed out"
        )

        return
    end

    ---------------------------------------------------------------
    -- PERIODIC REFRESH
    --
    -- This works both when statistics were successfully received
    -- and when the previous request timed out.
    ---------------------------------------------------------------

    if getRuntimeMs() - self.lastRefresh <= 30000 then
        return
    end

    self:requestStatistics()
end

--------------------------------------------------------------------
-- PRERENDER
--
-- The terminal owns the overall shell.
--
-- This application renders only its own content.
--------------------------------------------------------------------

local function isStatVisible(screen, entry)

    if not entry or not entry.sandboxOption then
        return true
    end

    local optionName =
        "Stat"
        .. tostring(entry.sandboxOption)
        .. "Visible"

    if not screen
        or type(screen.statVisibility) ~= "table"
        or screen.statVisibility[optionName] == nil then

        return true
    end

    return screen.statVisibility[optionName] == true
end

function KIPN_ServerStats:prerender()

    ISPanel.prerender(self)

    ---------------------------------------------------------------
    -- CRT EFFECT
    ---------------------------------------------------------------

    KIPN.UI.DrawScanlines(self)

    ---------------------------------------------------------------
    -- BANNER
    ---------------------------------------------------------------

    local y =
        KIPN.UI.DrawBanner(
            self,
            (self.activeTab == "player")
                and "PLAYER STATISTICS"
                or "SERVER STATISTICS"
        )

    ---------------------------------------------------------------
    -- LOADING
    --
    -- Shared across both tabs -- tied to the core GET_SERVER_STATS
    -- round trip, same as before tabs existed.
    ---------------------------------------------------------------

    if self.loading then

        KIPN.UI.DrawStatusMessage(
            self,
            "loading",
            "LOADING SERVER STATISTICS...",
            "Querying server status database..."
        )

        return
    end

    ---------------------------------------------------------------
    -- SKIP PAST TAB BUTTON ROW
    --
    -- self.tabButtonServer / self.tabButtonPlayer are real ISButton
    -- children created once in onShow() (see createTabButtons()) at
    -- a fixed y=84 -- they are not redrawn here, this just reserves
    -- the vertical space below them for hand-drawn tab content.
    ---------------------------------------------------------------

    y = y + 46

    ---------------------------------------------------------------
    -- CLIP THE SCROLLABLE BODY
    --
    -- Hard boundary below the tab row (see the contentTop=112 passed
    -- to KIPN.UI.EnableScroll() in initialise()/onShow()) -- content
    -- scrolled past this line is clipped away instead of rendering
    -- behind/through the tab buttons.
    ---------------------------------------------------------------

    KIPN.UI.BeginScrollClip(self)

    local contentEndY

    if self.activeTab == "player" then

        contentEndY =
            self:renderPlayerTab(y)

    elseif self.activeTab == "display" then

        contentEndY =
            self:renderDisplayTab(y)

    else

        contentEndY =
            self:renderServerTab(y)
    end

    KIPN.UI.EndScrollClip(self)

    KIPN.UI.SetContentHeight(
        self,
        contentEndY
    )
end

--------------------------------------------------------------------
-- RENDER: DISPLAY OPTIONS
--
-- Admin-only presentation controls. These settings never disable
-- collection/tracking; they only determine which catalog rows and
-- leaderboard sections are shown to players.
--------------------------------------------------------------------

function KIPN_ServerStats:renderDisplayTab(y)

    self.displayHitRows = {}

    if not self.canEditStatVisibility then

        self:drawText(
            "DISPLAY OPTIONS REQUIRE ADMIN CONFIGURATION ACCESS.",
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.warning.r,
            KIPN.UI.Theme.warning.g,
            KIPN.UI.Theme.warning.b,
            KIPN.UI.Theme.warning.a,
            KIPN.UI.Theme.fontBody
        )

        return y + 30
    end

    self:drawText(
        "STAT DISPLAY OPTIONS",
        20,
        KIPN.UI.ScrollY(self, y),
        KIPN.UI.Theme.accent.r,
        KIPN.UI.Theme.accent.g,
        KIPN.UI.Theme.accent.b,
        KIPN.UI.Theme.accent.a,
        KIPN.UI.Theme.fontHeader
    )

    y = y + 24

    self:drawText(
        "Click a stat to show/hide it. Applies server-wide to Server and Player Stats.",
        20,
        KIPN.UI.ScrollY(self, y),
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    y = y + 20

    self:drawText(
        "Tracking and leaderboard data collection continue regardless of visibility.",
        20,
        KIPN.UI.ScrollY(self, y),
        KIPN.UI.Theme.dimText.r,
        KIPN.UI.Theme.dimText.g,
        KIPN.UI.Theme.dimText.b,
        KIPN.UI.Theme.dimText.a,
        KIPN.UI.Theme.fontBody
    )

    y = y + 28

    if self.displayMessage then

        self:drawText(
            tostring(self.displayMessage),
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.warning.r,
            KIPN.UI.Theme.warning.g,
            KIPN.UI.Theme.warning.b,
            KIPN.UI.Theme.warning.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 24
    end

    local seen = {}

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do

        if entry
            and entry.sandboxOption then

            local optionName =
                "Stat"
                .. tostring(entry.sandboxOption)
                .. "Visible"

            if not seen[optionName] then

                seen[optionName] = true

                local enabled =
                    self.statVisibility[optionName] ~= false

                local rowY =
                    KIPN.UI.ScrollY(self, y)

                local marker =
                    enabled and "[X]" or "[ ]"

                self:drawText(
                    marker
                        .. " "
                        .. tostring(entry.label or optionName),
                    25,
                    rowY,
                    enabled
                        and KIPN.UI.Theme.text.r
                        or KIPN.UI.Theme.dimText.r,
                    enabled
                        and KIPN.UI.Theme.text.g
                        or KIPN.UI.Theme.dimText.g,
                    enabled
                        and KIPN.UI.Theme.text.b
                        or KIPN.UI.Theme.dimText.b,
                    enabled
                        and KIPN.UI.Theme.text.a
                        or KIPN.UI.Theme.dimText.a,
                    KIPN.UI.Theme.fontBody
                )

                self.displayHitRows[#self.displayHitRows + 1] = {
                    optionName = optionName,
                    x1 = 20,
                    x2 = math.max(320, self.width - 20),
                    y1 = rowY - 2,
                    y2 = rowY + 20,
                }

                y = y + 22
            end
        end
    end

    return y + 10
end

--------------------------------------------------------------------
-- RENDER: SERVER TAB
--
-- Mode/uptime/terminal counts (KIPN's own domain data), the
-- catalog-driven leaderboard (top-5 sections for stats flagged
-- leaderboard=true), and a compact server-totals table for every
-- other enabled cumulative/peak stat. See shared/KIPN_StatsCatalog.lua.
--------------------------------------------------------------------

function KIPN_ServerStats:renderServerTab(y)

    ---------------------------------------------------------------
    -- TIMEOUT / INVALID RESPONSE
    --
    -- A missing/timed-out core stats response no longer aborts the
    -- whole tab: the leaderboard request is independent and may
    -- still have valid data to show below.
    ---------------------------------------------------------------

    if self.timedOut or not self.stats then

        if type(self.leaderboard) ~= "table" then

            -- Nothing else to show on this tab: use the big
            -- centered status message as before.

            KIPN.UI.DrawStatusMessage(
                self,
                "timeout",
                "SERVER STATISTICS UNAVAILABLE",
                "No valid response from server."
            )

            return y
        end

        -- The leaderboard below still has data, so this is a
        -- small inline note in the normal top-down flow instead
        -- of the panel-centered message (which would otherwise
        -- overlap the leaderboard content).

        self:drawText(
            "Core server statistics unavailable.",
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.warning.r,
            KIPN.UI.Theme.warning.g,
            KIPN.UI.Theme.warning.b,
            KIPN.UI.Theme.warning.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 25
    end

    ---------------------------------------------------------------
    -- SERVER MODE
    ---------------------------------------------------------------

    if self.stats
        and self.stats.mode ~= nil then

        self:drawText(
            string.format(
                "Mode: %s",
                tostring(self.stats.mode)
            ),
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 25
    end

    ---------------------------------------------------------------
    -- UPTIME
    ---------------------------------------------------------------

    if self.stats
        and self.stats.uptime ~= nil then

        self:drawText(
            string.format(
                "Uptime: %s",
                self:formatUptime(
                    self.stats.uptime
                )
            ),
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 25
    end

    ---------------------------------------------------------------
    -- TERMINALS
    ---------------------------------------------------------------

    if self.stats
        and self.stats.totalTerminals ~= nil then

        self:drawText(
            string.format(
                "Total Terminals: %d",
                tonumber(
                    self.stats.totalTerminals
                ) or 0
            ),
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 22
    end

    ---------------------------------------------------------------
    -- LISTINGS
    ---------------------------------------------------------------

    if self.stats
        and self.stats.totalListings ~= nil then

        self:drawText(
            string.format(
                "Total Listings: %d",
                tonumber(
                    self.stats.totalListings
                ) or 0
            ),
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 22
    end


    ---------------------------------------------------------------
    -- PROPERTIES
    ---------------------------------------------------------------

    if self.stats
        and self.stats.totalProperties ~= nil then

        self:drawText(
            string.format(
                "Total Properties: %d",
                tonumber(
                    self.stats.totalProperties
                ) or 0
            ),
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.text.r,
            KIPN.UI.Theme.text.g,
            KIPN.UI.Theme.text.b,
            KIPN.UI.Theme.text.a,
            KIPN.UI.Theme.fontBody
        )

        y = y + 22
    end

    ---------------------------------------------------------------
    -- PLAYER COUNT
    ---------------------------------------------------------------

    if self.stats
        and self.stats.totalPlayers ~= nil then

        local onlineCount = nil

        if type(self.stats.onlinePlayers) == "table" then

            onlineCount =
                #self.stats.onlinePlayers
        end

        if onlineCount ~= nil then

            self:drawText(
                string.format(
                    "Online Players: %d/%d",
                    onlineCount,
                    tonumber(
                        self.stats.totalPlayers
                    ) or 0
                ),
                20,
                KIPN.UI.ScrollY(self, y),
                KIPN.UI.Theme.text.r,
                KIPN.UI.Theme.text.g,
                KIPN.UI.Theme.text.b,
                KIPN.UI.Theme.text.a,
                KIPN.UI.Theme.fontBody
            )

        else

            self:drawText(
                string.format(
                    "Players: %d",
                    tonumber(
                        self.stats.totalPlayers
                    ) or 0
                ),
                20,
                KIPN.UI.ScrollY(self, y),
                KIPN.UI.Theme.text.r,
                KIPN.UI.Theme.text.g,
                KIPN.UI.Theme.text.b,
                KIPN.UI.Theme.text.a,
                KIPN.UI.Theme.fontBody
            )
        end

        y = y + 25
    end

    ---------------------------------------------------------------
    -- ONLINE PLAYER NAMES
    --
    -- Only displayed when the server explicitly exposes
    -- onlinePlayers.
    ---------------------------------------------------------------

    if self.stats
        and type(self.stats.onlinePlayers) == "table"
        and #self.stats.onlinePlayers > 0 then

        y =
            KIPN.UI.DrawDivider(
                self,
                y,
                20
            )

        y = y + 8

        self:drawText(
            "ONLINE PLAYERS",
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.accent.r,
            KIPN.UI.Theme.accent.g,
            KIPN.UI.Theme.accent.b,
            KIPN.UI.Theme.accent.a,
            KIPN.UI.Theme.fontHeader
        )

        y = y + 22

        -- The panel already scrolls (see KIPN.UI.EnableScroll() in
        -- initialise()), so the full roster is rendered here rather
        -- than hard-capping the list and printing "...and N more" --
        -- overflow is the scroll container's job, not this loop's.

        for i = 1, #self.stats.onlinePlayers do

            local player =
                self.stats.onlinePlayers[i]

            if type(player) == "table" then

                local name =
                    player.username
                    or "Unknown"

                self:drawText(
                    string.format(
                        "- %s",
                        tostring(name)
                    ),
                    25,
                    KIPN.UI.ScrollY(self, y),
                    KIPN.UI.Theme.text.r,
                    KIPN.UI.Theme.text.g,
                    KIPN.UI.Theme.text.b,
                    KIPN.UI.Theme.text.a,
                    KIPN.UI.Theme.fontBody
                )

                y = y + 20
            end
        end
    end

    ---------------------------------------------------------------
    -- ANNOUNCEMENT
    ---------------------------------------------------------------

    if self.stats
        and self.stats.announcement
        and self.stats.announcement.active then

        y = y + 5

        y =
            KIPN.UI.DrawDivider(
                self,
                y,
                20
            )

        y = y + 8

        self:drawText(
            "ANNOUNCEMENT",
            20,
            KIPN.UI.ScrollY(self, y),
            KIPN.UI.Theme.warning.r,
            KIPN.UI.Theme.warning.g,
            KIPN.UI.Theme.warning.b,
            KIPN.UI.Theme.warning.a,
            KIPN.UI.Theme.fontHeader
        )

        y = y + 22

        local text =
            tostring(
                self.stats.announcement.text
                or ""
            )

        local maxWidth =
            self.width - 40

        local words = {}

        for word in string.gmatch(
            text,
            "%S+"
        ) do

            table.insert(
                words,
                word
            )
        end

        local line = ""

        for _, word in ipairs(words) do

            local testLine

            if line == "" then

                testLine = word

            else

                testLine =
                    line .. " " .. word
            end

            local measuredWidth =
                getTextManager():MeasureStringX(
                    KIPN.UI.Theme.fontBody,
                    testLine
                )

            if measuredWidth <= maxWidth then

                line = testLine

            else

                if line ~= "" then

                    self:drawText(
                        line,
                        20,
                        KIPN.UI.ScrollY(self, y),
                        KIPN.UI.Theme.warning.r,
                        KIPN.UI.Theme.warning.g,
                        KIPN.UI.Theme.warning.b,
                        KIPN.UI.Theme.warning.a,
                        KIPN.UI.Theme.fontBody
                    )

                    y = y + 20
                end

                line = word
            end
        end

        if line ~= "" then

            self:drawText(
                line,
                20,
                KIPN.UI.ScrollY(self, y),
                KIPN.UI.Theme.warning.r,
                KIPN.UI.Theme.warning.g,
                KIPN.UI.Theme.warning.b,
                KIPN.UI.Theme.warning.a,
                KIPN.UI.Theme.fontBody
            )

            y = y + 20
        end
    end

    ---------------------------------------------------------------
    -- LEADERBOARD
    --
    -- Independent of self.stats -- rendered whenever leaderboard
    -- data has been received, even if the core stats request
    -- above failed or timed out. Loops KIPN.Shared.StatsCatalog
    -- (leaderboard == true entries only) instead of hand-listing
    -- fields -- see shared/KIPN_StatsCatalog.lua.
    ---------------------------------------------------------------

    if type(self.leaderboard) == "table" then

        local boards =
            self.leaderboard.boards
            or {}

        local function drawLeaderboardSection(
            title,
            entries,
            formatValue
        )

            y =
                KIPN.UI.DrawDivider(
                    self,
                    y,
                    20
                )

            y = y + 8

            self:drawText(
                title,
                20,
                KIPN.UI.ScrollY(self, y),
                KIPN.UI.Theme.accent.r,
                KIPN.UI.Theme.accent.g,
                KIPN.UI.Theme.accent.b,
                KIPN.UI.Theme.accent.a,
                KIPN.UI.Theme.fontHeader
            )

            y = y + 22

            if type(entries) ~= "table"
                or #entries == 0 then

                self:drawText(
                    "No data yet",
                    25,
                    KIPN.UI.ScrollY(self, y),
                    KIPN.UI.Theme.dimText.r,
                    KIPN.UI.Theme.dimText.g,
                    KIPN.UI.Theme.dimText.b,
                    KIPN.UI.Theme.dimText.a,
                    KIPN.UI.Theme.fontBody
                )

                y = y + 20

                return
            end

            for i, entry in ipairs(entries) do

                if type(entry) == "table" then

                    self:drawText(
                        string.format(
                            "%d. %s - %s",
                            i,
                            tostring(entry.username or "Unknown"),
                            formatValue(entry.value)
                        ),
                        25,
                        KIPN.UI.ScrollY(self, y),
                        KIPN.UI.Theme.text.r,
                        KIPN.UI.Theme.text.g,
                        KIPN.UI.Theme.text.b,
                        KIPN.UI.Theme.text.a,
                        KIPN.UI.Theme.fontBody
                    )

                    y = y + 20
                end
            end
        end

        for _, catalogEntry in ipairs(KIPN.Shared.StatsCatalog) do

            if catalogEntry.leaderboard
                and isStatVisible(self, catalogEntry) then

                drawLeaderboardSection(
                    "LEADERBOARD - "
                        .. string.upper(catalogEntry.label),
                    boards[catalogEntry.id],
                    function(value)

                        if catalogEntry.id == "hoursSurvived" then

                            return self:formatUptime(
                                (tonumber(value) or 0) * 3600
                            )
                        end

                        return KIPN.Shared.StatsCatalog.FormatValue(
                            catalogEntry,
                            value,
                            KIPN.Client.Preferences.StatsFormatters
                        )
                    end
                )
            end
        end

    end

    return y
end

--------------------------------------------------------------------
-- RENDER: PLAYER TAB
--
-- The viewing player's own stats -- Tier A fields read live
-- server-side, Tier B fields persisted from KIPN_StatsTracker.lua
-- flushes. Both arrive together in self.myStats (GET_MY_STATS).
--------------------------------------------------------------------

function KIPN_ServerStats:renderPlayerTab(y)

    if type(self.myStats) ~= "table" then

        KIPN.UI.DrawStatusMessage(
            self,
            "empty",
            "PERSONAL STATISTICS UNAVAILABLE",
            "No valid response from server."
        )

        return y
    end

    self:drawText(
        string.format(
            "Player: %s",
            tostring(self.myStats.username or "Unknown")
        ),
        20,
        KIPN.UI.ScrollY(self, y),
        KIPN.UI.Theme.text.r,
        KIPN.UI.Theme.text.g,
        KIPN.UI.Theme.text.b,
        KIPN.UI.Theme.text.a,
        KIPN.UI.Theme.fontBody
    )

    y = y + 30

    local columns = {
        { label = "STAT", width = 220 },
        { label = "VALUE", width = 180 },
    }

    local rows = {}

    for _, entry in ipairs(KIPN.Shared.StatsCatalog) do

        if isStatVisible(self, entry) then

            local value =
                self.myStats[entry.id]

            local formatted

            if entry.id == "hoursSurvived" then

                formatted =
                    self:formatUptime(
                        (tonumber(value) or 0) * 3600
                    )

            else

                formatted =
                    KIPN.Shared.StatsCatalog.FormatValue(
                        entry,
                        value,
                        KIPN.Client.Preferences.StatsFormatters
                    )
            end

            rows[#rows + 1] =
                { entry.label, formatted }
        end
    end

    KIPN.UI.DrawTable(
        self,
        20,
        y,
        columns,
        rows,
        22
    )

    y = y + (22 * (1 + #rows))

    return y
end

--------------------------------------------------------------------
-- FORMAT UPTIME
--------------------------------------------------------------------

function KIPN_ServerStats:formatUptime(seconds)

    local success = false

    local result

    local ok, err =
        pcall(
            function()

                seconds =
                    tonumber(seconds) or 0

                local days =
                    math.floor(
                        seconds / 86400
                    )

                seconds =
                    seconds - (days * 86400)

                local hours =
                    math.floor(
                        seconds / 3600
                    )

                seconds =
                    seconds - (hours * 3600)

                local minutes =
                    math.floor(
                        seconds / 60
                    )

                seconds =
                    math.floor(
                        seconds - (minutes * 60)
                    )

                if days > 0 then

                    result =
                        string.format(
                            "%dd %02dh %02dm",
                            days,
                            hours,
                            minutes
                        )

                elseif hours > 0 then

                    result =
                        string.format(
                            "%dh %02dm %02ds",
                            hours,
                            minutes,
                            seconds
                        )

                elseif minutes > 0 then

                    result =
                        string.format(
                            "%dm %02ds",
                            minutes,
                            seconds
                        )

                else

                    result =
                        string.format(
                            "%ds",
                            seconds
                        )
                end

                success = true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_ServerStats:formatUptime(): "
            .. tostring(err)
        )

        result = "0s"
    end

    return result
end

--------------------------------------------------------------------
-- DISPLAY OPTION CLICK HANDLING
--------------------------------------------------------------------

function KIPN_ServerStats:onMouseDown(x, y)

    if self.activeTab == "display"
        and self.canEditStatVisibility
        and type(self.displayHitRows) == "table" then

        for _, row in ipairs(self.displayHitRows) do

            if x >= row.x1
                and x <= row.x2
                and y >= row.y1
                and y <= row.y2 then

                local optionName =
                    row.optionName

                self.statVisibility[optionName] =
                    not (
                        self.statVisibility[optionName]
                        ~= false
                    )

                self.displayDirty = true
                self.displayMessage =
                    "Unsaved display changes."
                self:updateTabButtonStyles()

                return true
            end
        end
    end

    if ISPanel.onMouseDown then
        return ISPanel.onMouseDown(self, x, y)
    end

    return false
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--
-- Forwards to KIPN.UI's generic scroll container (see
-- KIPN.UI.EnableScroll() in initialise()).
--------------------------------------------------------------------

function KIPN_ServerStats:onMouseWheel(del)

    return KIPN.UI.OnScrollMouseWheel(self, del)
end

--------------------------------------------------------------------
-- KEY PRESS
--
-- The terminal owns ESC / CLOSE.
--
-- Do not close UIManager from this child.
--------------------------------------------------------------------

function KIPN_ServerStats:onKeyPress(key)

    if key == Keyboard.KEY_ESCAPE then

        if self.terminal then

            self.terminal:onKeyPress(
                key
            )
        end

        return true
    end

    return false
end

--------------------------------------------------------------------
-- NEW
--
-- KIPN.UI.CreateScreen() supplies the standard :new()
-- implementation.
--
-- No local :new() is required.
--------------------------------------------------------------------
