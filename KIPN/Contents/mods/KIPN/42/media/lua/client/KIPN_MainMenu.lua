-- KIPN_MainMenu.lua
-- BBS main menu for the KIPN terminal.
--
-- This screen is a CHILD APPLICATION of KIPN_Terminal.
--
-- Responsibilities:
--   * Render the authenticated KIPN application menu.
--   * Request menu-specific server data.
--   * Receive server responses through KIPN_Terminal.
--   * Navigate to child applications.
--
-- This screen does NOT own:
--   * authentication
--   * session state
--   * terminal chrome
--   * UIManager membership
--   * server-response listeners
--   * terminal proximity
--   * logout
--   * weather/forecast state, requests, or rendering
--
-- Authentication and session enforcement belong to:
--
--   KIPN_Terminal
--       +
--   server-side AuthService / session validation
--
-- Weather/forecast state, the daily request gate, and the weather
-- widget itself belong to KIPN_Terminal (chrome, persists across
-- child-screen navigation) and KIPN_UI (presentation helpers) --
-- see KIPN_Terminal.lua's requestForecastIfNeeded()/
-- receiveForecastData() and KIPN_UI.lua's DrawWeatherReadout().
--
-- All server responses are routed by KIPN_Terminal to
-- receiveResponse() on the active child screen.
--
-- DEPENDENCY CONTRACT
--
-- MainMenu is a CLIENT-SIDE CHILD APPLICATION.
--
-- MainMenu depends on:
--
--   KIPN_Logger
--       |
--       +-- KIPN namespace
--       +-- centralized logging
--
--   KIPN_Shared
--       |
--       +-- commands
--       +-- responses
--       +-- shared constants
--       +-- shared protocol definitions
--
--   KIPN_UI
--       |
--       +-- child-screen construction
--       +-- shared KIPN UI infrastructure
--
--   Project Zomboid UI
--       |
--       +-- ISPanel
--
-- MainMenu does NOT require:
--
--   * KIPN_Terminal
--   * KIPN_Server
--   * server-side services
--
-- MENU-VISIBILITY EXCEPTION:
--
-- refreshFeatureAvailability() reads a client-local value to
-- decide which menu items to show/hide (see isMenuItemVisible()):
--
--   * SandboxVars.KIPN.SafehouseClaimsEnabled (a plain sandbox
--     option -- read directly, defensively guarded, never assumed
--     present)
--
-- This is a display-only decision. MainMenu never trusts the
-- value for anything server-authoritative -- the corresponding
-- child screens and their server-side services independently
-- re-validate everything they actually act on.
--
-- KIPN_Terminal owns the application container.
-- MainMenu is loaded as a child application and communicates with
-- the terminal through the application interface established by
-- KIPN_UI / KIPN_Terminal.
--
-- IMPORTANT:
--
-- This module must never create its own global OnServerCommand
-- listener. Server responses are routed by KIPN_Terminal.
--------------------------------------------------------------------


--------------------------------------------------------------------
-- VANILLA UI DEPENDENCIES
--
-- MainMenu directly derives from ISPanel, so the vanilla UI class
-- must be available before the screen is created.
--
-- This is a direct dependency of this file.
-- It is NOT a KIPN dependency.
--------------------------------------------------------------------

require "ISUI/ISPanel"


--------------------------------------------------------------------
-- NAMESPACE DEPENDENCY VALIDATION
--
-- Some earlier-loading KIPN module (e.g. KIPN_Logger.lua) must
-- already have established the global KIPN table.
--
-- MainMenu does not establish the root namespace itself.
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_MainMenu] "
        .. "KIPN namespace is not initialized."
    )

end


--------------------------------------------------------------------
-- SHARED CONTRACT DEPENDENCY
--
-- MainMenu uses shared KIPN definitions such as:
--
--   * command identifiers
--   * response identifiers
--   * application identifiers
--   * protocol constants
--
-- Shared must therefore exist before MainMenu is loaded.
--------------------------------------------------------------------

if not KIPN.Shared then

    error(
        "[KIPN_MainMenu] "
        .. "KIPN_Shared is not initialized."
    )

end


--------------------------------------------------------------------
-- UI INFRASTRUCTURE DEPENDENCY
--
-- KIPN_UI owns the reusable KIPN client-screen infrastructure.
--
-- MainMenu uses KIPN.UI.CreateScreen() rather than directly
-- implementing the terminal/application inheritance model.
--------------------------------------------------------------------

require "KIPN_UI"

if not KIPN.UI then

    error(
        "[KIPN_MainMenu] "
        .. "KIPN_UI is not initialized."
    )

end

--------------------------------------------------------------------
-- LOGGER DEPENDENCY
--
-- MainMenu performs diagnostic operations and therefore requires
-- the centralized KIPN logger.
--
-- MainMenu does NOT create a second logging implementation.
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN_MainMenu] "
        .. "KIPN_Logger is not initialized."
    )

end

--------------------------------------------------------------------
-- CLIENT STATE
--
-- KIPN.Client may already have been created by another KIPN client
-- module that loaded earlier. This establishes it defensively if
-- MainMenu happens to be the first to need it.
--------------------------------------------------------------------

KIPN.Client =
    KIPN.Client or {}


--------------------------------------------------------------------
-- SCREEN
--
-- MainMenu is a child application.
--
-- It does NOT:
--
--   * add itself to UIManager
--   * create the terminal
--   * create terminal chrome
--   * own HOME / CLOSE
--   * register global server listeners
--
-- KIPN_Terminal controls when this screen becomes active.
--------------------------------------------------------------------

KIPN_MainMenu =
    KIPN.UI.CreateScreen(
        "KIPN_MainMenu"
    )


--------------------------------------------------------------------
-- RUNTIME TIMER
--
-- getTimestampMs() is used for millisecond-resolution timing (e.g.
-- the breathing pulse animation timing in prerender()).
--
-- It is NOT:
--
--   * Project Zomboid game time
--   * a calendar timestamp
--   * a real-world datetime
--
-- Returning zero keeps diagnostics safe during very early
-- initialization if the timing API is unavailable.
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


    if ok
        and type(result) == "number"
    then

        return result

    end


    return 0

end

--------------------------------------------------------------------
-- ANNOUNCEMENT "LAST SEEN" (CLIENT-LOCAL PRESENTATION STATE)
--
-- Not server-authoritative. KIPN_Announcement.lua writes this value
-- whenever the player actually views the announcements screen; Main
-- Menu only reads it to decide whether to show the unread badge.
--------------------------------------------------------------------

local function getAnnouncementLastSeenId()

    local ok, store =
        pcall(
            ModData.getOrCreate,
            "KIPN_ClientState"
        )

    if not ok
        or type(store) ~= "table"
    then

        return nil
    end

    return store.announcementLastSeenId
end

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_MainMenu:initialise()

    local success =
        false

    local ok, err =
        pcall(
            function()


                ISPanel.initialise(
                    self
                )

                self:create()

                ------------------------------------------------------
                -- SCROLLING
                --
                -- Menu items are added over time (announcements,
                -- admin-only entries, etc.) and can exceed the
                -- terminal's fixed content height -- see
                -- KIPN.UI.EnableScroll() in KIPN_UI.lua.
                ------------------------------------------------------

                KIPN.UI.EnableScroll(
                    self
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:initialise() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- CREATE
--------------------------------------------------------------------

function KIPN_MainMenu:create()

    local success =
        false

    local ok, err =
        pcall(
            function()


                KIPN.UI.SetupScreen(
                    self
                )

                ----------------------------------------------------
                -- SCREEN STATE
                ----------------------------------------------------

                self.playerData =
                    nil

                self.mode =
                    nil

                self.isMultiplayer =
                    false

                ----------------------------------------------------
                -- COMPUTER ZONE CLASSIFICATION
                --
                -- computerClassification:
                --     Server-authoritative zone booleans for THIS
                --     computer's current position (see
                --     KIPN_WorldRegistry.GetComputerClassification()
                --     via the GET_COMPUTER_INFO command). Requested
                --     fresh every onShow(), like player data / mode
                --     -- not gated like the daily forecast, since an
                --     admin can move zones while the server runs.
                --
                -- nil until the first COMPUTER_INFO response
                -- arrives. Zone-gated menu items (see
                -- isMenuItemVisible()) stay hidden until then --
                -- fail closed, not open.
                ----------------------------------------------------

                self.computerClassification =
                    nil

                ----------------------------------------------------
                -- FEATURE AVAILABILITY
                --
                -- safehouseClaimsEnabled:
                --     SandboxVars.KIPN.SafehouseClaimsEnabled.
                --     Gates PROPERTY RECORDS.
                --
                -- discordConfigured:
                --     Server-reported (via ANNOUNCEMENT_SYNC) flag
                --     that a Discord channel URL is configured.
                --     Gates ANNOUNCEMENTS.
                --
                -- All default to false (fail closed / hidden) until
                -- computed or received.
                ----------------------------------------------------

                self.safehouseClaimsEnabled =
                    false

                self.discordConfigured =
                    false

                ----------------------------------------------------
                -- ANNOUNCEMENT STATE
                --
                -- announcementLatestId:
                --     id of the newest announcement the server has
                --     told us about (from the last ANNOUNCEMENT_SYNC
                --     response, requested or broadcast).
                --
                -- hasUnreadAnnouncements:
                --     announcementLatestId differs from the
                --     client-local "last seen" marker written by
                --     KIPN_Announcement.lua.
                ----------------------------------------------------

                self.announcementLatestId =
                    nil

                self.hasUnreadAnnouncements =
                    false

                ----------------------------------------------------
                -- NEW MESSAGE SOUND
                --
                -- lastSoundPlayedForId:
                --     announcementLatestId the chime has already
                --     played for. Prevents replaying the same chime
                --     every time GET_ANNOUNCEMENTS re-confirms the
                --     same still-unread announcement, while still
                --     chiming again for a genuinely new one that
                --     arrives later in the same session (or on the
                --     next time the terminal is opened, since this
                --     screen is recreated then).
                ----------------------------------------------------

                self.lastSoundPlayedForId =
                    nil

                ----------------------------------------------------
                -- MENU ITEMS
                --
                -- The menu is SERVER-DRIVEN: onShow() asks
                -- GET_APPLICATIONS and receiveResponse() rebuilds this
                -- list from APPLICATIONS_DATA (see those functions).
                -- The server has already applied every permission /
                -- capability / zone / powered-computer gate, so a
                -- companion service mod's menu program appears here
                -- with no edit to this file. ADMIN SETTINGS (id 99) is
                -- still inserted client-side from PLAYER_DATA.
                --
                -- Screen-class globals are resolved lazily in
                -- selectItem() -- never here.
                ----------------------------------------------------

                self.menuItems = {}

                ----------------------------------------------------
                -- INPUT
                ----------------------------------------------------

                self:setWantKeyEvents(
                    true
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:create() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- SHOW
--
-- Called whenever Main Menu becomes the active application.
--
-- IMPORTANT:
--
-- Main Menu may be shown multiple times during one day.
--
-- Player data and server mode may be requested whenever the screen
-- becomes active.
--
-- The daily weather forecast is requested by KIPN_Terminal, not
-- here -- see requestForecastIfNeeded() in KIPN_Terminal.lua.
--------------------------------------------------------------------

function KIPN_MainMenu:onShow()

    local success =
        false

    local ok, err =
        pcall(
            function()


                ----------------------------------------------------
                -- ATTACH SCROLLBAR
                --
                -- initialise() opts this screen into scrolling before
                -- it has its final Java UI object. Re-entering the
                -- helper here, after KIPN_Terminal has instantiated
                -- the screen, attaches the visible native scrollbar.
                ----------------------------------------------------

                KIPN.UI.EnableScroll(
                    self
                )


                ----------------------------------------------------
                -- REQUEST NORMAL MAIN MENU DATA
                ----------------------------------------------------

                self:requestPlayerData()

                self:requestMode()

                self:requestAnnouncements()

                self:requestComputerInfo()

                self:requestApplications()

                ----------------------------------------------------
                -- REFRESH CLIENT-LOCAL FEATURE AVAILABILITY
                ----------------------------------------------------

                self:refreshFeatureAvailability()

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:onShow() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- REQUEST PLAYER DATA
--------------------------------------------------------------------

function KIPN_MainMenu:requestPlayerData()

    local success =
        false

    local ok, err =
        pcall(
            function()


                if not KIPN.Shared.Commands.GET_PLAYER_DATA then


                    return
                end

                if not sendClientCommand then

                    KIPN.Logger.Error(
                        "KIPN_MainMenu:requestPlayerData(): "
                        .. "sendClientCommand unavailable"
                    )

                    return
                end

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_PLAYER_DATA,
                    {}
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:requestPlayerData() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- REQUEST SERVER MODE
--------------------------------------------------------------------

function KIPN_MainMenu:requestMode()

    local success =
        false

    local ok, err =
        pcall(
            function()


                if not KIPN.Shared.Commands.GET_MODE then


                    return
                end

                if not sendClientCommand then

                    KIPN.Logger.Error(
                        "KIPN_MainMenu:requestMode(): "
                        .. "sendClientCommand unavailable"
                    )

                    return
                end

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_MODE,
                    {}
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:requestMode() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- REQUEST ANNOUNCEMENTS
--
-- Requested every time Main Menu is shown (like player data / mode,
-- not gated like the daily forecast) so the unread badge reflects
-- current server state as soon as the terminal is opened -- this is
-- the "pull at launch" entry point for the Discord bridge feed.
--------------------------------------------------------------------

function KIPN_MainMenu:requestAnnouncements()

    local success =
        false

    local ok, err =
        pcall(
            function()


                if not KIPN.Shared.Commands.GET_ANNOUNCEMENTS then


                    return
                end

                if not sendClientCommand then

                    KIPN.Logger.Error(
                        "KIPN_MainMenu:requestAnnouncements(): "
                        .. "sendClientCommand unavailable"
                    )

                    return
                end

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_ANNOUNCEMENTS,
                    {}
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:requestAnnouncements() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- REQUEST COMPUTER INFO
--
-- Asks the server for this computer's CURRENT zone classification
-- (see KIPN_WorldRegistry.GetComputerClassification()), used to
-- decide which zone-gated menu items to show -- e.g. Vehicle
-- Registration only inside a Vehicle Dealership Zone.
--
-- Requested every time Main Menu is shown, like player data / mode
-- -- not gated like the daily forecast, since an admin can move or
-- redraw zones while the server keeps running.
--------------------------------------------------------------------

function KIPN_MainMenu:requestComputerInfo()

    local success =
        false

    local ok, err =
        pcall(
            function()


                if not KIPN.Shared.Commands.GET_COMPUTER_INFO then


                    return
                end

                if not sendClientCommand then

                    KIPN.Logger.Error(
                        "KIPN_MainMenu:requestComputerInfo(): "
                        .. "sendClientCommand unavailable"
                    )

                    return
                end

                local computerId =
                    self.terminal
                    and self.terminal.GetComputerId
                    and self.terminal:GetComputerId()

                if not computerId then


                    return
                end

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_COMPUTER_INFO,
                    {
                        computerId = computerId,
                    }
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:requestComputerInfo() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- REQUEST APPLICATIONS
--
-- Asks the server which applications this player should see at THIS
-- computer. The reply (APPLICATIONS_DATA) rebuilds self.menuItems.
-- Re-requested whenever the computer's zone classification changes
-- (see the COMPUTER_INFO branch of receiveResponse()).
--------------------------------------------------------------------

function KIPN_MainMenu:requestApplications()

    local ok, err =
        pcall(
            function()

                if not KIPN.Shared.Commands.GET_APPLICATIONS then
                    return
                end

                if not sendClientCommand then
                    return
                end

                local computerId =
                    self.terminal
                    and self.terminal.GetComputerId
                    and self.terminal:GetComputerId()

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_APPLICATIONS,
                    {
                        computerId = computerId,
                    }
                )
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:requestApplications() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- REFRESH FEATURE AVAILABILITY
--
-- Client-local (no server round trip) computation of the
-- feature-availability flags that CAN be answered purely from data
-- already on the client:
--
--   safehouseClaimsEnabled:
--       SandboxVars.KIPN.SafehouseClaimsEnabled, a real
--       sandbox-options.txt boolean. Defaults to true (the sandbox
--       default) only when SandboxVars data is genuinely
--       unavailable.
--
-- discordConfigured is NOT computed here. KIPN.DiscordChannelUrl
-- is a sandbox-options.txt string, but the client can't tell from
-- the raw value alone whether it parses to a usable channel ID --
-- that check lives server-side (AnnouncementConfig.ParseChannelId).
-- So the flag arrives already-resolved on the server's
-- ANNOUNCEMENT_SYNC response -- see receiveResponse().
--------------------------------------------------------------------

function KIPN_MainMenu:refreshFeatureAvailability()

    local success =
        false

    local ok, err =
        pcall(
            function()


                ----------------------------------------------------
                -- SAFEHOUSE CLAIMS ENABLED
                ----------------------------------------------------

                local sandboxValue =
                    SandboxVars
                    and SandboxVars.KIPN
                    and SandboxVars.KIPN.SafehouseClaimsEnabled

                if sandboxValue == nil then

                    self.safehouseClaimsEnabled =
                        true

                else

                    self.safehouseClaimsEnabled =
                        sandboxValue == true
                end

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:refreshFeatureAvailability() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- PLAY NEW MESSAGE SOUND
--
-- UI cue only -- no game-world/positional meaning, so this plays
-- through playUISound() rather than an emitter attached to the
-- player. See media/scripts/KIPN_Sounds.txt for the sound
-- definitions backing "KIPN_NewMessage" / "KIPN_gotMail".
--
-- Almost always plays KIPN_NewMessage. Roughly 1 time in
-- GOT_MAIL_ONE_IN it plays KIPN_gotMail instead -- a deliberately
-- rare easter-egg nod to dial-up-era "you've got mail".
--------------------------------------------------------------------

local GOT_MAIL_ONE_IN = 250

function KIPN_MainMenu:playNewMessageSound()

    local success =
        false

    local ok, err =
        pcall(
            function()


                if not getSoundManager then


                    return
                end

                local soundName =
                    "KIPN_NewMessage"

                if type(ZombRand) == "function"
                    and ZombRand(GOT_MAIL_ONE_IN) == 0
                then

                    soundName =
                        "KIPN_gotMail"
                end

                getSoundManager():playUISound(
                    soundName
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:playNewMessageSound() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------

function KIPN_MainMenu:update()

    local success =
        false

    local ok, err =
        pcall(
            function()

                ISPanel.update(
                    self
                )

                self.scanlineOffset =
                    (
                        self.scanlineOffset
                        + 0.5
                    ) % 4

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:update() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- MENU ITEM VISIBILITY
--
-- Server Statistics is always shown.
--
-- Property Records is gated on self.safehouseClaimsEnabled, read
-- from SandboxVars.KIPN.SafehouseClaimsEnabled (also computed in
-- refreshFeatureAvailability()).
--
-- Announcements is gated on self.discordConfigured (NOT zone-gated
-- -- it shows at any computer once set), reported by the server on
-- the ANNOUNCEMENT_SYNC response (see receiveResponse()) because
-- whether KIPN.DiscordChannelUrl parses to a usable channel ID is
-- a server-side check, not a raw SandboxVars read.
--
-- Vehicle Registration / Government Services are zone-gated: only
-- shown while this computer's server-authoritative classification
-- (self.computerClassification, from GET_COMPUTER_INFO) reports
-- dealership / government == true respectively. They stay hidden
-- while that data hasn't arrived yet (fail closed, not open).
--
-- Admin Settings (id 99) is not zone-gated at all -- it is only
-- ever inserted into self.menuItems once PLAYER_DATA reports
-- accessLevel == "ADMIN" (see receiveResponse()), so by the time
-- it exists in the list it should always be shown, regardless of
-- which zone this computer happens to be in.
--------------------------------------------------------------------

function KIPN_MainMenu:isMenuItemVisible(
    item
)

    if not item then

        return false
    end

    -- The server (GET_APPLICATIONS) has already applied every
    -- permission / capability / zone / powered-computer gate, so
    -- every server-provided row is visible. The menu is now fully
    -- server-driven; no client-only filters remain.
    return true
end

--------------------------------------------------------------------
-- PRERENDER
--------------------------------------------------------------------

function KIPN_MainMenu:prerender()

    local success =
        false

    local ok, err =
        pcall(
            function()

                ISPanel.prerender(
                    self
                )

                KIPN.UI.DrawScanlines(
                    self
                )

                ----------------------------------------------------
                -- BANNER
                ----------------------------------------------------

                local y =
                    KIPN.UI.DrawBanner(
                        self,
                        "KNOX COUNTY INFORMATION & PROPERTY NETWORK"
                    )

                ----------------------------------------------------
                -- SYSTEM STATUS
                ----------------------------------------------------

                self:drawText(
                    "* SYSTEM: OPERATIONAL",
                    15,
                    KIPN.UI.ScrollY(self, y),
                    0,
                    1,
                    0,
                    1,
                    UIFont.Small
                )

                ----------------------------------------------------
                -- PLAYER INFORMATION
                ----------------------------------------------------

                if self.playerData then

                    self:drawText(
                        "USER: "
                        .. tostring(
                            self.playerData.username
                            or "UNKNOWN"
                        ),
                        280,
                        KIPN.UI.ScrollY(self, y),
                        0.3,
                        0.7,
                        0.3,
                        1,
                        UIFont.Small
                    )

                    -- BALANCE is a client-side figure: the physical
                    -- vanilla money and money bundles the player is
                    -- carrying in their inventory and bags. This is
                    -- the same currency KIPN's claim fees (e.g. an
                    -- Excavation Permit) are paid from. It never
                    -- round-trips through GET_PLAYER_DATA, which only
                    -- carries username/accessLevel.
                    local balanceTotal = 0

                    local ok, computed = pcall(function()
                        local player = getSpecificPlayer(0)
                        local inv = player and player:getInventory()
                        if not inv then return 0 end

                        local total = 0
                        local function scan(container)
                            if not container or type(container.getItems) ~= "function" then return end
                            local items = container:getItems()
                            if not items then return end
                            for i = 0, items:size() - 1 do
                                local it = items:get(i)
                                if it then
                                    local ft = it:getFullType()
                                    if ft == "Base.Money" then
                                        total = total + 1
                                    elseif ft == "Base.MoneyBundle" then
                                        total = total + 100
                                    end
                                    if type(it.getInventory) == "function" then
                                        local nOk, nested = pcall(it.getInventory, it)
                                        if nOk and nested then scan(nested) end
                                    end
                                end
                            end
                        end
                        scan(inv)
                        return total
                    end)

                    if ok and computed then
                        balanceTotal = computed
                    end

                    local balanceText =
                        "BALANCE: $" .. tostring(balanceTotal)

                    self:drawText(
                        balanceText,
                        480,
                        KIPN.UI.ScrollY(self, y),
                        0.3,
                        0.7,
                        0.3,
                        1,
                        UIFont.Small
                    )
                end

                y =
                    y + 22

                ----------------------------------------------------
                -- SERVER MODE
                ----------------------------------------------------

                if self.isMultiplayer then

                    local modeText =
                        string.upper(
                            tostring(
                                self.mode
                                or "PVE"
                            )
                        )

                    self:drawText(
                        "* MODE: "
                        .. modeText,
                        15,
                        KIPN.UI.ScrollY(self, y),
                        0.3,
                        0.7,
                        0.3,
                        0.6,
                        UIFont.Small
                    )

                else

                    self:drawText(
                        "* SINGLEPLAYER MODE",
                        15,
                        KIPN.UI.ScrollY(self, y),
                        0.3,
                        0.7,
                        0.3,
                        0.6,
                        UIFont.Small
                    )
                end

                y =
                    y + 22

                ----------------------------------------------------
                -- MENU DIVIDER
                --
                -- Weather is no longer drawn here -- it's rendered
                -- persistently in the terminal chrome bar instead
                -- (see KIPN_Terminal:prerender() /
                -- KIPN.UI.DrawWeatherReadout()), so this section no
                -- longer reserves vertical space for it.
                ----------------------------------------------------

                y =
                    KIPN.UI.DrawDivider(
                        self,
                        y + 24
                    ) + 24

                ----------------------------------------------------
                -- MENU ITEMS
                ----------------------------------------------------

                self.menuStartY =
                    y

                self.lineHeight =
                    50

                for _, item in ipairs(
                    self.menuItems
                ) do

                    ------------------------------------------------
                    -- ZONE / ACCESS VISIBILITY
                    --
                    -- Hidden items get no hit-test rectangle (a
                    -- stale one from a previous frame, while this
                    -- item was visible, would let a click on an
                    -- unrelated visible item phantom-select this
                    -- one -- see onMouseDown()). They also do not
                    -- consume vertical space, so the remaining
                    -- visible items stay stacked without a gap.
                    ------------------------------------------------

                    if not self:isMenuItemVisible(
                        item
                    ) then

                        item._yStart =
                            nil

                        item._yEnd =
                            nil

                    else

                        ----------------------------------------------
                        -- VISUAL ROW POSITION
                        --
                        -- item._yStart/_yEnd are compared directly
                        -- against onMouseDown()'s raw mouse-y, which
                        -- is in the same (scrolled) space actually
                        -- drawn to -- not the logical/unscrolled
                        -- layout cursor `y` used below.
                        ----------------------------------------------

                        local rowY =
                            KIPN.UI.ScrollY(self, y)

                        item._yStart =
                            rowY

                        item._yEnd =
                            rowY + self.lineHeight

                        --------------------------------------------
                        -- UNREAD ANNOUNCEMENT HIGHLIGHT
                        --
                        -- A slow breathing pulse (independent of
                        -- scanlineOffset, which drives the CRT
                        -- scanline sweep, not this) so the item
                        -- visibly stands out from the rest of the
                        -- menu without being distracting.
                        --------------------------------------------

                        local isUnreadAnnouncement =
                            item.screenName == "KIPN_Announcement"
                            and self.hasUnreadAnnouncements == true

                        local pulse =
                            0.5
                            + 0.5
                            * math.sin(
                                getRuntimeMs() / 250
                            )

                        --------------------------------------------
                        -- BACKGROUND
                        --------------------------------------------

                        if isUnreadAnnouncement then

                            self:drawRect(
                                18,
                                rowY - 2,
                                self.width - 36,
                                self.lineHeight - 2,
                                0.08 + (0.08 * pulse),
                                0.9,
                                0.7,
                                0
                            )

                        else

                            self:drawRect(
                                18,
                                rowY - 2,
                                self.width - 36,
                                self.lineHeight - 2,
                                0.03,
                                0.1,
                                0.03,
                                0.2
                            )
                        end

                        --------------------------------------------
                        -- BORDER
                        --------------------------------------------

                        if isUnreadAnnouncement then

                            self:drawRectBorder(
                                18,
                                rowY - 2,
                                self.width - 36,
                                self.lineHeight - 2,
                                1,
                                0.9,
                                0.7,
                                0,
                                0.5 + (0.4 * pulse)
                            )

                        else

                            self:drawRectBorder(
                                18,
                                rowY - 2,
                                self.width - 36,
                                self.lineHeight - 2,
                                1,
                                0,
                                0.4,
                                0,
                                0.2
                            )
                        end

                        --------------------------------------------
                        -- ITEM NUMBER
                        --------------------------------------------

                        self:drawText(
                            "["
                            .. string.format(
                                "%02d",
                                item.id
                            )
                            .. "]",
                            28,
                            rowY + 14,
                            isUnreadAnnouncement and 1 or 0,
                            isUnreadAnnouncement and 0.8 or 1,
                            isUnreadAnnouncement and 0 or 0,
                            0.6,
                            UIFont.Medium
                        )

                        --------------------------------------------
                        -- ITEM LABEL
                        --------------------------------------------

                        self:drawText(
                            " "
                            .. item.label
                            .. (
                                isUnreadAnnouncement
                                and "  * NEW"
                                or ""
                            ),
                            80,
                            rowY + 14,
                            isUnreadAnnouncement and 1 or 0,
                            isUnreadAnnouncement and 0.8 or 1,
                            isUnreadAnnouncement and 0 or 0,
                            1,
                            UIFont.Medium
                        )

                        --------------------------------------------
                        -- ARROW
                        --------------------------------------------

                        self:drawText(
                            ">",
                            self.width - 40,
                            rowY + 14,
                            isUnreadAnnouncement and 1 or 0,
                            isUnreadAnnouncement and 0.8 or 1,
                            isUnreadAnnouncement and 0 or 0,
                            isUnreadAnnouncement
                                and (0.4 + 0.4 * pulse)
                                or 0.3,
                            UIFont.Medium
                        )

                        y =
                            y + self.lineHeight

                    end
                end

                ----------------------------------------------------
                -- FOOTER
                ----------------------------------------------------

                y =
                    y + 9

                y =
                    KIPN.UI.DrawDivider(
                        self,
                        y
                    ) + 25

                self:drawText(
                    "[CLICK OPTION]  [WHEEL/SCROLLBAR] SCROLL  [ESC] EXIT",
                    20,
                    KIPN.UI.ScrollY(self, y),
                    0.3,
                    0.7,
                    0.3,
                    0.6,
                    UIFont.Small
                )

                ----------------------------------------------------
                -- CONTENT HEIGHT / SCROLLBAR
                --
                -- `y` is still the logical (unscrolled) layout
                -- cursor at this point -- its final value is exactly
                -- how tall the content would need to be to show
                -- everything at once. A trailing margin keeps the
                -- footer text from sitting flush against the very
                -- bottom edge when scrolled all the way down.
                ----------------------------------------------------

                KIPN.UI.SetContentHeight(
                    self,
                    y + 20
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:prerender() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--------------------------------------------------------------------

function KIPN_MainMenu:onMouseWheel(del)

    return KIPN.UI.OnScrollMouseWheel(
        self,
        del
    )
end

--------------------------------------------------------------------
-- MOUSE INPUT
--------------------------------------------------------------------

function KIPN_MainMenu:onMouseDown(
    x,
    y
)

    local success =
        false

    local ok, err =
        pcall(
            function()


                if not self.menuItems then


                    return
                end

                for _, item in ipairs(
                    self.menuItems
                ) do

                    if item._yStart
                        and item._yEnd
                        and y >= item._yStart
                        and y < item._yEnd
                    then


                        self:selectItem(
                            item.id
                        )

                        success =
                            true

                        return
                    end
                end

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:onMouseDown() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- RESOLVE CHILD SCREEN
--
-- Child applications are resolved lazily.
--
-- This avoids load-order failures where:
--
--     KIPN_PropertyRecords
--
-- is nil when KIPN_MainMenu.lua is loaded.
--------------------------------------------------------------------

function KIPN_MainMenu:resolveChildScreen(
    item
)

    local success =
        false

    local result =
        nil

    local ok, err =
        pcall(
            function()

                if not item then


                    return
                end

                if not item.screenName then


                    return
                end

                result =
                    _G[item.screenName]

                if not result then


                    return
                end

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:resolveChildScreen() failed: "
            .. tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- SELECT MENU ITEM
--------------------------------------------------------------------

function KIPN_MainMenu:selectItem(
    id
)

    local success =
        false

    local ok, err =
        pcall(
            function()


                for _, item in ipairs(
                    self.menuItems
                ) do

                    if item.id == id then

                        ------------------------------------------------
                        -- FLOATING WINDOW LAUNCH (ADMIN SETTINGS)
                        --
                        -- item.launchGlobal marks an item that is NOT
                        -- a KIPN_Terminal child screen -- it is a
                        -- standalone floating window with its own
                        -- .Toggle() (same pattern
                        -- KIPN_AdminSettings.lua's "Zones" section
                        -- already uses for KIPN_ZoneAdminUI).
                        --
                        -- Routing this through KIPN.UI.SetScreen()
                        -- instead would embed a full standalone panel
                        -- inside the terminal's small content pane and
                        -- break its own close button (it calls
                        -- self:removeFromUIManager(), but it would
                        -- never have been added to UIManager as a
                        -- top-level panel). So this bypasses terminal
                        -- navigation entirely -- MainMenu remains the
                        -- active terminal screen underneath.
                        ------------------------------------------------

                        if item.launchGlobal then

                            local target =
                                _G[item.launchGlobal]

                            if not target
                                or type(target.Toggle)
                                    ~= "function"
                            then

                                KIPN.Logger.Error(
                                    "KIPN_MainMenu:selectItem(): "
                                    .. tostring(item.launchGlobal)
                                    .. " is unavailable or has no "
                                    .. "Toggle()."
                                )

                                return
                            end

                            target.Toggle()

                            success =
                                true

                            return
                        end

                        ------------------------------------------------
                        -- ADMIN ITEM
                        --
                        -- Admin item is inserted dynamically after
                        -- PLAYER_DATA arrives.
                        ------------------------------------------------

                        if item.screen then

                            ------------------------------------------------
                            -- Already resolved.
                            ------------------------------------------------

                            local navigationSuccess =
                                KIPN.UI.SetScreen(
                                    self,
                                    item.screen
                                )

                            if navigationSuccess then


                                success =
                                    true

                            else

                            end

                            return
                        end

                        ------------------------------------------------
                        -- Resolve child application.
                        ------------------------------------------------

                        local screen =
                            self:resolveChildScreen(
                                item
                            )

                        if not screen then


                            return
                        end

                        item.screen =
                            screen

                        ------------------------------------------------
                        -- Navigate.
                        ------------------------------------------------

                        local navigationSuccess =
                            KIPN.UI.SetScreen(
                                self,
                                screen
                            )

                        if not navigationSuccess then


                            return
                        end


                        success =
                            true

                        return
                    end
                end

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:selectItem() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- KEY PRESS
--------------------------------------------------------------------

function KIPN_MainMenu:onKeyPress(
    key
)

    local success =
        false

    local ok, err =
        pcall(
            function()


                ----------------------------------------------------
                -- ESCAPE
                ----------------------------------------------------

                if key ==
                    Keyboard.KEY_ESCAPE
                then

                    ------------------------------------------------
                    -- Prefer terminal reference supplied by the
                    -- terminal lifecycle.
                    ------------------------------------------------

                    if self.terminal
                        and self.terminal.close
                    then

                        self.terminal:close()

                        success =
                            true

                        return
                    end

                    ------------------------------------------------
                    -- Fallback to KIPN_Terminal instance.
                    ------------------------------------------------

                    if KIPN_Terminal
                        and KIPN_Terminal.instance
                        and KIPN_Terminal.instance.close
                    then

                        KIPN_Terminal.instance:close()

                        success =
                            true

                        return
                    end


                    return
                end

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:onKeyPress() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- SERVER RESPONSE ROUTING
--
-- KIPN_Terminal is the ONLY client-side OnServerCommand listener.
--
-- It calls:
--
--   activeScreen:receiveResponse(event, data)
--
-- Main Menu never registers its own listener.
--------------------------------------------------------------------

function KIPN_MainMenu:receiveResponse(
    event,
    data
)

    local success =
        false

    local ok, err =
        pcall(
            function()


                ----------------------------------------------------
                -- PLAYER DATA
                ----------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.PLAYER_DATA
                then

                    if type(data) ~= "table" then


                        return
                    end

                    self.playerData =
                        data

                    -- All KIPN configuration is Sandbox-managed; there
                    -- is no in-terminal admin settings screen. The Zone
                    -- Admin tool has its own right-click entry
                    -- (KIPN_ZoneAdminTrigger.lua).

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- SERVER MODE
                ----------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.MODE_DATA
                then

                    if type(data) ~= "table" then


                        return
                    end

                    self.mode =
                        data.mode

                    self.isMultiplayer =
                        data.isMultiplayer == true


                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- ANNOUNCEMENT SYNC
                --
                -- Arrives both as a direct reply to GET_ANNOUNCEMENTS
                -- and as an unsolicited broadcast whenever the
                -- Discord bridge or an admin post changes the feed
                -- while Main Menu happens to be the active screen.
                ----------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.ANNOUNCEMENT_SYNC
                then

                    if type(data) ~= "table" then


                        return
                    end

                    self.announcementLatestId =
                        data.latestId

                    ------------------------------------------------
                    -- DISCORD CONFIGURED (MENU VISIBILITY)
                    --
                    -- See isMenuItemVisible() -- ANNOUNCEMENTS is
                    -- hidden until the server reports a configured
                    -- Discord channel URL.
                    ------------------------------------------------

                    self.discordConfigured =
                        data.discordConfigured == true

                    local lastSeenId =
                        getAnnouncementLastSeenId()

                    self.hasUnreadAnnouncements =
                        self.announcementLatestId ~= nil
                        and self.announcementLatestId ~= lastSeenId


                    ------------------------------------------------
                    -- NEW MESSAGE SOUND
                    --
                    -- Plays once per distinct unread announcement
                    -- id -- not on every GET_ANNOUNCEMENTS
                    -- reconfirmation of the same still-unread item,
                    -- but again if a genuinely newer one arrives
                    -- later in this same terminal session.
                    ------------------------------------------------

                    if self.hasUnreadAnnouncements
                        and self.announcementLatestId
                            ~= self.lastSoundPlayedForId
                    then

                        self.lastSoundPlayedForId =
                            self.announcementLatestId

                        self:playNewMessageSound()
                    end

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- COMPUTER INFO
                --
                -- Zone classification for THIS computer's current
                -- position (see requestComputerInfo() /
                -- isMenuItemVisible()).
                ----------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.COMPUTER_INFO
                then

                    if type(data) ~= "table"
                        or type(data.classification) ~= "table"
                    then


                        return
                    end

                    self.computerClassification =
                        data.classification

                    -- Zone classification affects which applications
                    -- the server offers -- re-ask now that it is known.
                    self:requestApplications()

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- APPLICATIONS
                --
                -- Server-driven menu list. Every row here has already
                -- passed the server's permission / capability / zone
                -- gating; the client renders it as-is. ADMIN SETTINGS
                -- (id 99) is re-appended from PLAYER_DATA.
                ----------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.APPLICATIONS_DATA
                then

                    if type(data) ~= "table"
                        or type(data.applications) ~= "table"
                    then

                        return
                    end

                    local rows = {}

                    for _, row in ipairs(data.applications) do
                        if type(row) == "table"
                            and type(row.screen) == "string"
                        then
                            rows[#rows + 1] = row
                        end
                    end

                    table.sort(
                        rows,
                        function(a, b)
                            local oa = tonumber(a.order) or 500
                            local ob = tonumber(b.order) or 500
                            if oa == ob then
                                return tostring(a.name) < tostring(b.name)
                            end
                            return oa < ob
                        end
                    )

                    local newItems = {}

                    for i, row in ipairs(rows) do
                        newItems[i] = {
                            id = i,
                            label = string.upper(
                                tostring(row.name or row.screen)
                            ),
                            screenName = row.screen,
                        }
                    end

                    self.menuItems = newItems

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- UNKNOWN RESPONSE
                --
                -- Includes FORECAST_DATA -- weather is handled by
                -- KIPN_Terminal now (see KIPN_Terminal.lua's
                -- onServerResponse()/receiveForecastData()), not by
                -- the active child screen.
                ----------------------------------------------------


                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_MainMenu:receiveResponse() failed: "
            .. tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- LOADED
--------------------------------------------------------------------

print(
    "[KIPN] Main Menu loaded"
)
