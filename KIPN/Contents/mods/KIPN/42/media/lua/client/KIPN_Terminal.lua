-- KIPN_Terminal.lua
--
-- KIPN terminal shell/container.
--
-- DEPENDENCY:
--
--   KIPN_Logger.lua
--       ↓
--   KIPN_Shared.lua
--       ↓
--   KIPN_UI.lua
--       ↓
--   KIPN_Terminal.lua
--
-- The terminal is the client-side navigation controller and
-- presentation container for KIPN applications.
--
-- Responsibilities:
--   * terminal dimensions
--   * terminal positioning
--   * terminal visual shell
--   * terminal background
--   * terminal content area
--   * terminal controls
--   * HOME / CLOSE
--   * DATE / TIME DISPLAY
--   * computer context
--   * proximity
--   * active application
--   * application lifecycle
--   * server-response routing
--
-- KIPN_Terminal is only ever entered POST-BOOT. KIPN_BootScreen and
-- KIPN_SplashScreen (media/lua/client/KIPN_BootScreen.lua,
-- KIPN_SplashScreen.lua) are standalone applications in their own
-- right, triggered directly by the computer power-on event -- they
-- are NOT terminal children and the terminal has no boot gate. Once
-- KIPN_SplashScreen's display timer elapses, it calls
-- KIPN_Terminal.OpenTerminal() itself, same as "Access KIP Network"
-- does for a computer that is already fully ON.
--
-- Applications are child content and do not own:
--   * terminal chrome
--   * HOME / CLOSE controls
--   * UIManager membership
--   * global server-response listeners
--
-- The server remains authoritative for:
--   * computer power
--   * computer boot state
--   * authentication
--   * sessions
--   * application data
--
-- The terminal only maintains local UI state.
--
-- IMPORTANT:
--
-- KIPN_Terminal does NOT initialize:
--   * KIPN_Logger
--   * KIPN_Shared
--
-- Those dependencies must already exist before the terminal loads.
--
-- KIPN_Terminal DOES depend on KIPN_UI because the terminal uses
-- the shared presentation framework for its visual/UI functionality.
--
-- KIPN_Terminal does NOT load child applications here.
--
-- Child applications such as:
--
--   * KIPN_MainMenu
--   * other KIPN applications
--
-- are separate modules and must be loaded after the terminal/UI
-- foundation is available.
--
-- APPLICATION ARCHITECTURE:
--
--   KIPN_Terminal
--        │
--        ├── owns terminal shell
--        ├── owns navigation
--        ├── owns active application
--        ├── owns response routing
--        │
--        └── contains child applications
--                  │
--                  ├── KIPN_MainMenu
--                  └── future applications
--
-- Child applications are VIEW CONTENT.
--
-- KIPN_Terminal is the CONTROLLER/CONTAINER.
--
-- Vanilla Project Zomboid SandboxVars are used for KIPN's
-- server/admin feature switches.
--
-- There is no KIPN-specific SandboxVars module.
--
-- File:
--   media/lua/client/KIPN_Terminal.lua

--------------------------------------------------------------------
-- PZ UI DEPENDENCIES
--------------------------------------------------------------------
--
-- These are vanilla Project Zomboid UI classes used directly by
-- the terminal shell.
--------------------------------------------------------------------

require "ISUI/ISPanel"
require "ISUI/ISButton"

--------------------------------------------------------------------
-- KIPN UI DEPENDENCY
--------------------------------------------------------------------
--
-- KIPN_UI provides:
--
--   * shared theme
--   * common panel setup
--   * banners
--   * scanlines
--   * dividers
--   * buttons
--   * status messages
--   * screen helpers
--   * other presentation utilities
--
-- The terminal is allowed to depend on this layer because UI is
-- below the terminal in the dependency hierarchy.
--
-- KIPN_UI must NOT depend on KIPN_Terminal.
--------------------------------------------------------------------

require "KIPN_UI"

--------------------------------------------------------------------
-- KIPN DEPENDENCY CHECK
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_TERMINAL] "
        .. "KIPN core is not initialized."
    )

end

--------------------------------------------------------------------
-- SHARED CONTRACT CHECK
--------------------------------------------------------------------

if not KIPN.Shared then

    error(
        "[KIPN_TERMINAL] "
        .. "KIPN.Shared is not initialized. "
        .. "KIPN_Shared.lua must be loaded before "
        .. "KIPN_Terminal.lua."
    )

end

--------------------------------------------------------------------
-- LOGGER CHECK
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN_TERMINAL] "
        .. "KIPN.Logger is not initialized. "
        .. "KIPN_Logger.lua must be loaded before "
        .. "KIPN_Terminal.lua."
    )

end

--------------------------------------------------------------------
-- UI FRAMEWORK CHECK
--------------------------------------------------------------------

if not KIPN.UI then

    error(
        "[KIPN_TERMINAL] "
        .. "KIPN.UI is not initialized. "
        .. "KIPN_UI.lua must be loaded before "
        .. "KIPN_Terminal.lua."
    )

end

--------------------------------------------------------------------
-- CLIENT NAMESPACE
--------------------------------------------------------------------
--
-- KIPN.Client may already have been created by another KIPN client
-- module that loaded earlier. This establishes it defensively if
-- the terminal happens to be the first to need it.
--------------------------------------------------------------------

KIPN.Client =
    KIPN.Client or {}

--------------------------------------------------------------------
-- TERMINAL SHELL
--------------------------------------------------------------------
--
-- KIPN_Terminal is the actual terminal container.
--
-- Child applications are placed inside this container rather than
-- becoming independent UIManager panels.
--------------------------------------------------------------------

KIPN_Terminal =
    ISPanel:derive(
        "KIPN_Terminal"
    )

--------------------------------------------------------------------
-- SINGLE TERMINAL INSTANCE
--------------------------------------------------------------------
--
-- The terminal is intentionally represented by one active instance.
--
-- Individual applications are swapped inside the terminal's
-- content area.
--------------------------------------------------------------------

KIPN_Terminal.instance =
    nil

--------------------------------------------------------------------
-- MODULE LOAD CONFIRMATION
--------------------------------------------------------------------



--------------------------------------------------------------------
-- TERMINAL DIMENSIONS
--------------------------------------------------------------------

KIPN_Terminal.CONTENT_X = 10
KIPN_Terminal.CONTENT_Y = 98
KIPN_Terminal.CONTENT_RIGHT = 10
KIPN_Terminal.CONTENT_BOTTOM = 10

KIPN_Terminal.DEFAULT_WIDTH = 800
KIPN_Terminal.DEFAULT_HEIGHT = 600

--------------------------------------------------------------------
-- PROXIMITY
--------------------------------------------------------------------

KIPN_Terminal.MAX_PROXIMITY = 2.0
KIPN_Terminal.MAX_Z_DIFFERENCE = 1.0

--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_Terminal:initialise()


    ISPanel.initialise(self)

    ---------------------------------------------------------------
    -- TERMINAL SHELL APPEARANCE
    ---------------------------------------------------------------

    self.backgroundColor = {
        r = 0,
        g = 0,
        b = 0,
        a = 1
    }

    self.borderColor = {
        r = 0,
        g = 1,
        b = 0,
        a = 1
    }

    self.borderWidth = 1

    ---------------------------------------------------------------
    -- VIEW PROTECTION
    --
    -- Clips all terminal-chrome drawing (weather, date/time,
    -- dividers) plus its embedded contentPanel/screen to the
    -- terminal's own bounds, so nothing can spill outside the
    -- floating window. See KIPN.UI.EnableClipping().
    ---------------------------------------------------------------

    KIPN.UI.EnableClipping(self)

    ---------------------------------------------------------------
    -- TERMINAL STATE
    ---------------------------------------------------------------

    -- Actual instantiated application panel.
    self.currentScreen = nil

    -- Class of the currently active application.
    --
    -- IMPORTANT:
    --
    -- currentScreen is an INSTANCE.
    -- currentScreenClass is the CLASS.
    --
    -- Example:
    --
    --   currentScreen      = actual KIPN_MainMenu instance
    --   currentScreenClass = KIPN_MainMenu
    self.currentScreenClass = nil

    ---------------------------------------------------------------
    -- COMPUTER CONTEXT
    --
    -- OpenTerminal() assigns computer/computerSquare BEFORE
    -- initialise(). Do not clobber them here - doing so erases the
    -- computer context OpenTerminal() just established and breaks
    -- proximity checks and computer ID resolution (both fields
    -- default to nil on a freshly created instance regardless).
    ---------------------------------------------------------------

    self.contentPanel = nil

    ---------------------------------------------------------------
    -- DATE / TIME STATE
    ---------------------------------------------------------------

    self.dateTimeText =
        "--/--/---- --:--"

    self.lastDateTimeMinute = nil

    ---------------------------------------------------------------
    -- WEATHER STATE
    --
    -- Owned by the terminal (not the active child screen) so it
    -- persists across screen navigation and renders in the chrome
    -- bar regardless of which application is active. See
    -- requestForecastIfNeeded() / receiveForecastData().
    ---------------------------------------------------------------

    self.forecastData = nil

    self.forecastRequestDay = nil

    self.forecastRequestPending = false

    self:setWantKeyEvents(true)
end

--------------------------------------------------------------------
-- CREATE CHILDREN
--------------------------------------------------------------------

function KIPN_Terminal:createChildren()


    ---------------------------------------------------------------
    -- DRAG HANDLE
    --
    -- Makes the terminal a floating, freely-moveable window: the
    -- player can click-drag any empty chrome area (the strip above
    -- the content panel, minus the HOME/CLOSE buttons added below)
    -- to reposition it. See KIPN.UI.EnableDragging().
    --
    -- IMPORTANT: this must be added BEFORE the HOME/CLOSE buttons so
    -- those buttons -- added afterward -- keep click priority over
    -- the drag handle sitting underneath them.
    ---------------------------------------------------------------

    KIPN.UI.EnableDragging(
        self,
        0,
        0,
        self.width,
        KIPN_Terminal.CONTENT_Y
    )

    ---------------------------------------------------------------
    -- CONTENT CONTAINER
    ---------------------------------------------------------------

    local contentX =
        KIPN_Terminal.CONTENT_X

    local contentY =
        KIPN_Terminal.CONTENT_Y

    local contentWidth =
        self.width
        - KIPN_Terminal.CONTENT_X
        - KIPN_Terminal.CONTENT_RIGHT

    local contentHeight =
        self.height
        - KIPN_Terminal.CONTENT_Y
        - KIPN_Terminal.CONTENT_BOTTOM

    self.contentPanel =
        ISPanel:new(
            contentX,
            contentY,
            contentWidth,
            contentHeight
        )

    self.contentPanel:initialise()

    self.contentPanel.backgroundColor = {
        r = 0,
        g = 0,
        b = 0,
        a = 1
    }

    self.contentPanel.borderColor = {
        r = 0,
        g = 0,
        b = 0,
        a = 0
    }

    self.contentPanel.borderWidth = 0

    self:addChild(
        self.contentPanel
    )

    ---------------------------------------------------------------
    -- HOME BUTTON
    ---------------------------------------------------------------

    local btnY = 5
    local btnH = 20

    self.homeButton =
        ISButton:new(
            self.width - 110,
            btnY,
            60,
            btnH,
            "HOME",
            self,
            KIPN_Terminal.onHomeClick
        )

    self.homeButton:initialise()
    self.homeButton:instantiate()

    self.homeButton.borderColor = {
        r = 0,
        g = 0.8,
        b = 0.2,
        a = 0.8
    }

    self.homeButton.backgroundColor = {
        r = 0.05,
        g = 0.15,
        b = 0.05,
        a = 0.9
    }

    self.homeButton.backgroundColorMouseOver = {
        r = 0.1,
        g = 0.5,
        b = 0.2,
        a = 0.9
    }

    self.homeButton.textColor = {
        r = 0.2,
        g = 1.0,
        b = 0.2,
        a = 1
    }

    self:addChild(
        self.homeButton
    )

    ---------------------------------------------------------------
    -- CLOSE BUTTON
    ---------------------------------------------------------------

    self.closeButton =
        ISButton:new(
            self.width - 40,
            btnY,
            30,
            btnH,
            "X",
            self,
            KIPN_Terminal.onCloseClick
        )

    self.closeButton:initialise()
    self.closeButton:instantiate()

    self.closeButton.borderColor = {
        r = 0,
        g = 0.8,
        b = 0.2,
        a = 0.8
    }

    self.closeButton.backgroundColor = {
        r = 0.05,
        g = 0.15,
        b = 0.05,
        a = 0.9
    }

    self.closeButton.backgroundColorMouseOver = {
        r = 0.8,
        g = 0.1,
        b = 0.1,
        a = 0.9
    }

    self.closeButton.textColor = {
        r = 0.2,
        g = 1.0,
        b = 0.2,
        a = 1
    }

    self:addChild(
        self.closeButton
    )

    ---------------------------------------------------------------
    -- INITIAL APPLICATION
    --
    -- KIPN_Terminal is only ever entered post-boot (see the file
    -- header) -- KIPN_SplashScreen hands off here once its display
    -- timer elapses, and "Access KIP Network" on an already-ON
    -- computer opens the terminal directly. Either way, MainMenu is
    -- the terminal's one and only starting application.
    --
    -- Access to individual menu options is gated server-side by
    -- KIPN.Server.Permissions.ResolveAccessLevel(), not by any
    -- client-side login/session state.
    ---------------------------------------------------------------

    self:setScreen(
        KIPN_MainMenu
    )
end

--------------------------------------------------------------------
-- UPDATE DATE / TIME
--
-- Runs regardless of which child application is currently active --
-- the clock is terminal chrome, not MainMenu content.
--------------------------------------------------------------------

function KIPN_Terminal:updateDateTime()

    local gameTime =
        getGameTime()

    if not gameTime then

        KIPN.Logger.Warn(
            "KIPN_Terminal:updateDateTime(): "
            .. "GameTime unavailable"
        )

        return
    end

    local year =
        gameTime:getYear()

    local month =
        gameTime:getMonth()

    local day =
        gameTime:getDay()

    local hour =
        gameTime:getHour()

    local minute =
        gameTime:getMinutes()

    if not year
        or not month
        or not day
        or not hour
        or not minute then

        KIPN.Logger.Warn(
            "KIPN_Terminal:updateDateTime(): "
            .. "incomplete GameTime data"
        )

        return
    end

    ---------------------------------------------------------------
    -- PROJECT ZOMBOID MONTHS AND DAYS ARE ZERO-BASED
    --
    -- (vanilla displays getDay() + 1 as well)
    ---------------------------------------------------------------

    local displayMonth =
        month + 1

    local displayDay =
        day + 1

    ---------------------------------------------------------------
    -- The key includes the resolved display preferences so the
    -- clock re-renders the moment the player changes 12/24 hour or
    -- date order (or the vanilla option under an "auto" choice).
    ---------------------------------------------------------------

    local Prefs =
        KIPN.Client.Preferences

    local minuteKey =
        string.format(
            "%04d-%02d-%02d-%02d-%02d",
            year,
            displayMonth,
            displayDay,
            hour,
            minute
        )
        .. "|"
        .. Prefs.Signature()

    if self.lastDateTimeMinute
        == minuteKey then

        return
    end

    self.lastDateTimeMinute =
        minuteKey

    self.dateTimeText =
        Prefs.FormatDateTime(
            year,
            displayMonth,
            displayDay,
            hour,
            minute
        )

end

--------------------------------------------------------------------
-- GET CURRENT IN-GAME DAY
--
-- This is intentionally client-side only.
--
-- The value is used ONLY to prevent duplicate forecast requests
-- during the same in-game day.
--
-- The server remains authoritative over forecast validity.
--------------------------------------------------------------------

local function getCurrentGameDay()

    local success =
        false

    local result =
        nil

    local ok, err =
        pcall(
            function()


                ----------------------------------------------------
                -- Project Zomboid game time
                ----------------------------------------------------

                if not getGameTime then


                    return
                end

                local gameTime =
                    getGameTime()

                if not gameTime then


                    return
                end

                ----------------------------------------------------
                -- Prefer world age in days when available.
                ----------------------------------------------------

                if gameTime.getWorldAgeDays then

                    local worldAgeDays =
                        gameTime:getWorldAgeDays()

                    if type(worldAgeDays) == "number" then

                        result =
                            math.floor(
                                worldAgeDays
                            )

                        success =
                            true

                        return
                    end
                end

                ----------------------------------------------------
                -- Fallback to calendar date.
                ----------------------------------------------------

                if gameTime.getYear
                    and gameTime.getMonth
                    and gameTime.getDay
                then

                    result =
                        string.format(
                            "%04d-%02d-%02d",
                            gameTime:getYear(),
                            gameTime:getMonth(),
                            gameTime:getDay()
                        )

                    success =
                        true

                    return
                end

            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Terminal:getCurrentGameDay() failed: "
            .. tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- REQUEST FORECAST IF NEEDED
--
-- The daily request gate for the weather widget. Owned by the
-- terminal (not the active child screen) so it survives navigation
-- between applications and keeps working no matter which screen is
-- active when the terminal is opened.
--
-- The client only determines:
--
--   "Have I already asked the server for today's forecast?"
--
-- The server determines:
--
--   "Which forecast should I return?"
--------------------------------------------------------------------

function KIPN_Terminal:requestForecastIfNeeded()

    local success =
        false

    local ok, err =
        pcall(
            function()


                ----------------------------------------------------
                -- Resolve current in-game day.
                ----------------------------------------------------

                local currentDay =
                    getCurrentGameDay()

                if currentDay == nil then


                elseif self.forecastRequestDay
                    == currentDay
                then


                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- Do not duplicate an outstanding request.
                ----------------------------------------------------

                if self.forecastRequestPending then


                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- Validate command.
                ----------------------------------------------------

                if not KIPN.Shared.Commands.GET_FORECAST then


                    return
                end

                if not sendClientCommand then

                    KIPN.Logger.Error(
                        "KIPN_Terminal:requestForecastIfNeeded(): "
                        .. "sendClientCommand unavailable"
                    )

                    return
                end

                ----------------------------------------------------
                -- Mark request day BEFORE sending.
                --
                -- This prevents repeated requests if this is called
                -- again (e.g. next frame) before the response
                -- arrives.
                ----------------------------------------------------

                if currentDay ~= nil then

                    self.forecastRequestDay =
                        currentDay
                end

                self.forecastRequestPending =
                    true

                ----------------------------------------------------
                -- SEND SERVER REQUEST
                ----------------------------------------------------

                sendClientCommand(
                    "KIPN",
                    KIPN.Shared.Commands.GET_FORECAST,
                    {}
                )


                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_Terminal:requestForecastIfNeeded() failed: "
            .. tostring(err)
        )
    end

    return success
end

--------------------------------------------------------------------
-- RECEIVE FORECAST DATA
--
-- Called by onServerResponse() below for FORECAST_DATA / forecast
-- ERROR responses, regardless of which child screen is active.
--------------------------------------------------------------------

function KIPN_Terminal:receiveForecastData(data)

    self.forecastRequestPending =
        false

    if type(data) ~= "table" then


        return
    end

    self.forecastData =
        data
end

--------------------------------------------------------------------
-- GET COMPUTER ID
--------------------------------------------------------------------

function KIPN_Terminal:GetComputerId()


    if not self.computerSquare
        and self.computer
        and self.computer.getSquare then

        self.computerSquare =
            self.computer:getSquare()
    end

    if self.computer
        and KIPN.Shared
        and KIPN.Shared.GetComputerId then

        local id =
            KIPN.Shared.GetComputerId(
                self.computer
            )

        if id then
            return id
        end
    end

    if self.computerSquare then

        return string.format(
            "comp_%d_%d_%d",
            self.computerSquare:getX(),
            self.computerSquare:getY(),
            self.computerSquare:getZ()
        )
    end

    return nil
end

--------------------------------------------------------------------
-- GET COMPUTER SQUARE
--------------------------------------------------------------------

function KIPN_Terminal:GetComputerSquare()


    if not self.computerSquare
        and self.computer
        and self.computer.getSquare then

        self.computerSquare =
            self.computer:getSquare()
    end

    return self.computerSquare
end

--------------------------------------------------------------------
-- HOME
--------------------------------------------------------------------

function KIPN_Terminal:onHomeClick()


    self:setScreen(
        KIPN_MainMenu
    )
end

--------------------------------------------------------------------
-- CLOSE
--------------------------------------------------------------------

function KIPN_Terminal:onCloseClick()

    self:close()
end

--------------------------------------------------------------------
-- KEY PRESS
--------------------------------------------------------------------

function KIPN_Terminal:onKeyPress(key)


    if key == Keyboard.KEY_ESCAPE then

        self:close()

        return true
    end

    return false
end

--------------------------------------------------------------------
-- SET SCREEN
--
-- Central application transition point.
--
-- currentScreen:
--     actual instantiated UI panel
--
-- currentScreenClass:
--     class of the active application
--
-- This distinction is important because:
--
--     self.currentScreen == KIPN_MainMenu
--
-- is incorrect.
--
-- The correct comparison is:
--
--     self.currentScreenClass == KIPN_MainMenu
--------------------------------------------------------------------

function KIPN_Terminal:setScreen(
    screenClass
)


    if not screenClass then

        KIPN.Logger.Warn(
            "KIPN_Terminal:setScreen(): "
            .. "screenClass is nil"
        )

        return false
    end

    ---------------------------------------------------------------
    -- VERIFY CONTENT CONTAINER
    ---------------------------------------------------------------

    if not self.contentPanel then

        KIPN.Logger.Error(
            "KIPN_Terminal:setScreen(): "
            .. "contentPanel is unavailable"
        )

        return false
    end

    ---------------------------------------------------------------
    -- FAILURE FALLBACK
    ---------------------------------------------------------------

    local function showScreenError(
        reason,
        failedScreenClass
    )

        KIPN.Logger.Error(
            "KIPN_Terminal:setScreen(): "
            .. "application failed: "
            .. tostring(reason)
        )

        if not self.contentPanel then

            KIPN.Logger.Error(
                "KIPN_Terminal:setScreen(): "
                .. "cannot display error fallback; "
                .. "contentPanel unavailable"
            )

            return false
        end

        local fallback =
            ISPanel:new(
                0,
                0,
                self.contentPanel.width,
                self.contentPanel.height
            )

        if not fallback then

            KIPN.Logger.Error(
                "KIPN_Terminal:setScreen(): "
                .. "failed to create error fallback"
            )

            return false
        end

        -----------------------------------------------------------
        -- INITIALIZE FALLBACK
        -----------------------------------------------------------

        local fallbackInitOk,
            fallbackInitErr =
            pcall(
                function()
                    fallback:initialise()
                end
            )

        if not fallbackInitOk then

            KIPN.Logger.Error(
                "KIPN_Terminal:setScreen(): "
                .. "error fallback initialise() failed: "
                .. tostring(fallbackInitErr)
            )

            return false
        end

        -----------------------------------------------------------
        -- DEFAULT FALLBACK STYLE
        -----------------------------------------------------------

        local background =
            {
                r = 0,
                g = 0,
                b = 0,
                a = 1
            }

        local border =
            {
                r = 0,
                g = 1,
                b = 0,
                a = 1
            }

        local borderWidth =
            1

        -----------------------------------------------------------
        -- KIPN UI THEME
        -----------------------------------------------------------

        if KIPN.UI
            and KIPN.UI.Theme then

            if KIPN.UI.Theme.background then

                background =
                    KIPN.UI.Theme.background
            end

            if KIPN.UI.Theme.border then

                border =
                    KIPN.UI.Theme.border
            end

            if KIPN.UI.Theme.borderWidth then

                borderWidth =
                    KIPN.UI.Theme.borderWidth
            end
        end

        fallback.backgroundColor =
            background

        fallback.borderColor =
            border

        fallback.borderWidth =
            borderWidth

        fallback.terminal =
            self

        fallback.contentPanel =
            self.contentPanel

        -----------------------------------------------------------
        -- LEAVE SCREEN
        -----------------------------------------------------------

        function fallback:onLeaveScreen()

        end

        -----------------------------------------------------------
        -- RENDER ERROR
        -----------------------------------------------------------

        function fallback:prerender()

            ISPanel.prerender(self)

            if KIPN.UI
                and KIPN.UI.DrawScanlines then

                KIPN.UI.DrawScanlines(self)
            end

            local centerX =
                math.floor(
                    self.width / 2
                )

            local centerY =
                math.floor(
                    self.height / 2
                )

            -------------------------------------------------------
            -- TITLE
            -------------------------------------------------------

            local title =
                "APPLICATION ERROR"

            local titleWidth =
                getTextManager():MeasureStringX(
                    UIFont.Medium,
                    title
                )

            self:drawText(
                title,
                centerX
                    - math.floor(
                        titleWidth / 2
                    ),
                centerY - 70,
                1,
                0.3,
                0.3,
                1,
                UIFont.Medium
            )

            -------------------------------------------------------
            -- MESSAGE
            -------------------------------------------------------

            local message =
                "THE APPLICATION COULD NOT BE LOADED."

            local messageWidth =
                getTextManager():MeasureStringX(
                    UIFont.Small,
                    message
                )

            self:drawText(
                message,
                centerX
                    - math.floor(
                        messageWidth / 2
                    ),
                centerY - 35,
                0.7,
                0.3,
                0.3,
                1,
                UIFont.Small
            )

            -------------------------------------------------------
            -- DETAIL
            -------------------------------------------------------

            local detail =
                "ERROR: "
                .. tostring(reason)

            local detailWidth =
                getTextManager():MeasureStringX(
                    UIFont.Small,
                    detail
                )

            self:drawText(
                detail,
                centerX
                    - math.floor(
                        detailWidth / 2
                    ),
                centerY - 10,
                0.5,
                0.5,
                0.5,
                1,
                UIFont.Small
            )
        end

        -----------------------------------------------------------
        -- RETRY BUTTON
        -----------------------------------------------------------

        local retryX =
            math.floor(
                (fallback.width - 120) / 2
            )

        local retryY =
            math.floor(
                fallback.height / 2
            ) + 20

        local retryButton = nil

        -----------------------------------------------------------
        -- PREFERRED KIPN BUTTON
        -----------------------------------------------------------

        if KIPN.UI
            and KIPN.UI.CreateButton then

            local ok, result =
                pcall(
                    function()

                        return KIPN.UI.CreateButton(
                            fallback,
                            retryX,
                            retryY,
                            120,
                            28,
                            "RETRY",
                            function()

                                KIPN.Logger.Info(
                                    "KIPN_Terminal: "
                                    .. "retrying failed application"
                                )

                                self:setScreen(
                                    failedScreenClass
                                )
                            end
                        )
                    end
                )

            if ok then

                retryButton =
                    result

            else

                KIPN.Logger.Warn(
                    "KIPN_Terminal:setScreen(): "
                    .. "KIPN.UI.CreateButton() failed: "
                    .. tostring(result)
                )
            end
        end

        -----------------------------------------------------------
        -- NATIVE BUTTON FALLBACK
        -----------------------------------------------------------

        if not retryButton then


            retryButton =
                ISButton:new(
                    retryX,
                    retryY,
                    120,
                    28,
                    "RETRY",
                    fallback,
                    function()

                        KIPN.Logger.Info(
                            "KIPN_Terminal: "
                            .. "retrying failed application"
                        )

                        self:setScreen(
                            failedScreenClass
                        )
                    end
                )

            retryButton:initialise()
            retryButton:instantiate()

            fallback:addChild(
                retryButton
            )
        end

        -----------------------------------------------------------
        -- INSTANTIATE FALLBACK
        -----------------------------------------------------------

        local fallbackInstantiateOk,
            fallbackInstantiateErr =
            pcall(
                function()
                    if not fallback.javaObject then
                        fallback:instantiate()
                    end
                end
            )

        if not fallbackInstantiateOk then

            KIPN.Logger.Error(
                "KIPN_Terminal:setScreen(): "
                .. "error fallback instantiate() failed: "
                .. tostring(fallbackInstantiateErr)
            )

            return false
        end

        -----------------------------------------------------------
        -- ADD FALLBACK
        -----------------------------------------------------------

        self.contentPanel:addChild(
            fallback
        )

        self.currentScreen =
            fallback

        self.currentScreenClass =
            nil

        -----------------------------------------------------------
        -- KEEP CHROME ON TOP
        -----------------------------------------------------------

        if self.homeButton then

            self.homeButton:bringToTop()
        end

        if self.closeButton then

            self.closeButton:bringToTop()
        end

        KIPN.Logger.Info(
            "KIPN_Terminal: "
            .. "application error fallback displayed"
        )

        return false
    end

    ---------------------------------------------------------------
    -- LEAVE CURRENT APPLICATION
    ---------------------------------------------------------------

    if self.currentScreen then


        if self.currentScreen.onLeaveScreen then

            local ok, err =
                pcall(
                    self.currentScreen.onLeaveScreen,
                    self.currentScreen
                )

            if not ok then

                KIPN.Logger.Warn(
                    "KIPN_Terminal:setScreen(): "
                    .. "onLeaveScreen() failed: "
                    .. tostring(err)
                )
            end
        end

        self.contentPanel:removeChild(
            self.currentScreen
        )

        self.currentScreen =
            nil

        self.currentScreenClass =
            nil
    end

    ---------------------------------------------------------------
    -- RESET DATE / TIME STATE
    ---------------------------------------------------------------

    self.lastDateTimeMinute =
        nil

    ---------------------------------------------------------------
    -- CREATE APPLICATION
    ---------------------------------------------------------------

    local screenOk, screen =
        pcall(
            function()

                return screenClass:new(
                    0,
                    0,
                    self.contentPanel.width,
                    self.contentPanel.height
                )
            end
        )

    if not screenOk
        or not screen then

        return showScreenError(
            "SCREEN CREATION FAILED",
            screenClass
        )
    end

    ---------------------------------------------------------------
    -- PROVIDE TERMINAL CONTEXT
    ---------------------------------------------------------------

    screen.terminal =
        self

    screen.contentPanel =
        self.contentPanel

    ---------------------------------------------------------------
    -- INITIALIZE SCREEN
    ---------------------------------------------------------------

    local initOk, initErr =
        pcall(
            function()
                screen:initialise()
            end
        )

    if not initOk then

        return showScreenError(
            "INITIALISE FAILED: "
            .. tostring(initErr),
            screenClass
        )
    end

    ---------------------------------------------------------------
    -- INSTANTIATE SCREEN
    ---------------------------------------------------------------

    local instantiateOk,
        instantiateErr =
        pcall(
            function()
                -- initialise() may already instantiate the panel when it
                -- adds children. Replacing that native panel disconnects
                -- its text entries and buttons from rendering/input.
                if not screen.javaObject then
                    screen:instantiate()
                end
            end
        )

    if not instantiateOk then

        return showScreenError(
            "INSTANTIATE FAILED: "
            .. tostring(instantiateErr),
            screenClass
        )
    end

    ---------------------------------------------------------------
    -- ADD APPLICATION TO CONTENT PANEL
    ---------------------------------------------------------------

    self.contentPanel:addChild(
        screen
    )

    self.currentScreen =
        screen

    self.currentScreenClass =
        screenClass

    ---------------------------------------------------------------
    -- APPLICATION LIFECYCLE
    ---------------------------------------------------------------

    if screen.onShow then

        local ok, err =
            pcall(
                screen.onShow,
                screen
            )

        if not ok then

            self.contentPanel:removeChild(
                screen
            )

            self.currentScreen =
                nil

            self.currentScreenClass =
                nil

            return showScreenError(
                "ON SHOW FAILED: "
                .. tostring(err),
                screenClass
            )
        end
    end

    ---------------------------------------------------------------
    -- TERMINAL CHROME ALWAYS STAYS ON TOP
    ---------------------------------------------------------------

    if self.homeButton then

        self.homeButton:bringToTop()
    end

    if self.closeButton then

        self.closeButton:bringToTop()
    end

    ---------------------------------------------------------------
    -- INITIAL DATE / TIME UPDATE
    ---------------------------------------------------------------

    self:updateDateTime()


    return true
end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------

function KIPN_Terminal:update()

    ISPanel.update(self)

    self:updateDateTime()

    ---------------------------------------------------------------
    -- DAILY FORECAST REQUEST
    --
    -- KIPN_Terminal is only ever entered post-boot (see the file
    -- header), so this can run unconditionally every update() --
    -- unlike before, there is no longer a boot sequence for it to
    -- wait out.
    ---------------------------------------------------------------

    self:requestForecastIfNeeded()
end

--------------------------------------------------------------------
-- PRERENDER
--------------------------------------------------------------------

function KIPN_Terminal:prerender()

    ISPanel.prerender(self)

    ---------------------------------------------------------------
    -- CLOCK
    --
    -- Chrome, not MainMenu content -- always drawn regardless of
    -- which child application is currently active.
    ---------------------------------------------------------------

    local dateTime =
        self.dateTimeText
        or "--/--/---- --:--"

    local dateTimeWidth =
        getTextManager():MeasureStringX(
            UIFont.Small,
            dateTime
        )

    local dateTimeX =
        self.width
        - 110
        - dateTimeWidth
        - 12

    self:drawText(
        dateTime,
        dateTimeX,
        9,
        0.2,
        1.0,
        0.2,
        0.9,
        UIFont.Small
    )

    ---------------------------------------------------------------
    -- WEATHER
    --
    -- Also chrome -- occupies its own band below the HOME/CLOSE
    -- buttons and date/time row, spanning the full chrome width.
    -- Current conditions sit on the left; the multi-day forecast
    -- strip fills the remaining width. See KIPN.UI.DrawWeatherReadout()
    -- / KIPN.UI.DrawWeatherForecastStrip(). Both are drawn here on
    -- the outer KIPN_Terminal object, so they render every frame
    -- regardless of which child screen is currently active.
    --
    -- The band's height is derived from CONTENT_Y (where the opaque
    -- content panel begins) rather than a fixed guess -- this is the
    -- actual widget pane available before that panel draws over
    -- anything below it. KIPN.UI.DrawWeatherForecastStrip() sizes its
    -- own rows to fit inside whatever height it's given, so passing
    -- the true available height (instead of a value smaller than
    -- what the strip actually needs) is what keeps the low-temp row
    -- from being covered by the content panel.
    ---------------------------------------------------------------

    KIPN.UI.DrawDivider(
        self,
        30
    )

    local weatherY = 40
    local weatherBottomMargin = 8

    local weatherHeight =
        KIPN_Terminal.CONTENT_Y
        - weatherY
        - weatherBottomMargin

    local currentConditionsWidth = 220

    KIPN.UI.DrawWeatherReadout(
        self,
        14,
        weatherY,
        currentConditionsWidth,
        weatherHeight,
        self.forecastData
    )

    KIPN.UI.DrawWeatherForecastStrip(
        self,
        14 + currentConditionsWidth + 16,
        weatherY,
        self.width - (14 + currentConditionsWidth + 16) - 10,
        weatherHeight,
        self.forecastData and self.forecastData.days
    )
end

--------------------------------------------------------------------
-- PROXIMITY CHECK
--------------------------------------------------------------------

function KIPN_Terminal:checkProximity()

    if KIPN_Terminal.instance ~= self then
        return
    end

    local player =
        getPlayer()

    if not player
        or player:isDead() then

        self:close()

        return
    end

    ---------------------------------------------------------------
    -- RESOLVE COMPUTER SQUARE
    ---------------------------------------------------------------

    if not self.computerSquare then

        if self.computer
            and self.computer.getSquare then

            self.computerSquare =
                self.computer:getSquare()
        end

        if not self.computerSquare then
            return
        end
    end

    ---------------------------------------------------------------
    -- POWER CHECK
    --
    -- Proximity is re-checked every OnPlayerUpdate while the
    -- terminal is open, so this is also the place that keeps
    -- BootScreen/MainMenu from staying shown after the
    -- computer's square loses power mid-session.
    ---------------------------------------------------------------

    if KIPN.Shared.HasSquareElectricity
        and not KIPN.Shared.HasSquareElectricity(
            self.computerSquare
        ) then

        self:close()

        return
    end

    ---------------------------------------------------------------
    -- RANGE CHECK
    ---------------------------------------------------------------

    if not KIPN.Shared.IsPlayerNearSquare(
        self.computerSquare,
        KIPN_Terminal.MAX_PROXIMITY,
        KIPN_Terminal.MAX_Z_DIFFERENCE
    ) then

        self:close()
    end
end

--------------------------------------------------------------------
-- CLOSE TERMINAL
--------------------------------------------------------------------

function KIPN_Terminal:close()


    ---------------------------------------------------------------
    -- CLOSE ACTIVE APPLICATION
    ---------------------------------------------------------------

    if self.currentScreen then

        if self.currentScreen.onLeaveScreen then

            local ok, err =
                pcall(
                    self.currentScreen.onLeaveScreen,
                    self.currentScreen
                )

            if not ok then

                KIPN.Logger.Warn(
                    "KIPN_Terminal:close(): "
                    .. "onLeaveScreen() failed: "
                    .. tostring(err)
                )
            end
        end

        if self.contentPanel then

            self.contentPanel:removeChild(
                self.currentScreen
            )

        else

            self:removeChild(
                self.currentScreen
            )
        end

        self.currentScreen =
            nil
    end

    ---------------------------------------------------------------
    -- RESET APPLICATION CLASS
    ---------------------------------------------------------------

    self.currentScreenClass =
        nil

    ---------------------------------------------------------------
    -- RESET CLOCK
    ---------------------------------------------------------------

    self.lastDateTimeMinute =
        nil

    self.dateTimeText =
        "--/--/---- --:--"

    ---------------------------------------------------------------
    -- RESET WEATHER STATE
    ---------------------------------------------------------------

    self.forecastData =
        nil

    self.forecastRequestDay =
        nil

    self.forecastRequestPending =
        false

    ---------------------------------------------------------------
    -- UNMOUNT FROM CRT MONITOR HOUSING
    --
    -- The housing plays its switch-off and removes itself unless
    -- another screen mounts in the meantime. See KIPN.UI.CRT.
    ---------------------------------------------------------------

    self:setVisible(
        false
    )

    KIPN.UI.CRT.Unmount(self)

    if KIPN_Terminal.instance
        == self then

        KIPN_Terminal.instance =
            nil
    end

end

--------------------------------------------------------------------
-- OPEN TERMINAL
--
-- IMPORTANT:
--
-- The caller is responsible for only reaching this once the
-- computer's server-authoritative boot state is ON -- either via
-- KIPN_SplashScreen's post-boot handoff, or "Access KIP Network" on
-- a computer already fully ON. KIPN_Terminal itself performs no
-- boot gating; see the file header.
--------------------------------------------------------------------

function KIPN_Terminal.OpenTerminal(
    computer
)


    ---------------------------------------------------------------
    -- PLAYER
    ---------------------------------------------------------------

    local player =
        getPlayer()

    if not player then

        KIPN.Logger.Warn(
            "KIPN_Terminal.OpenTerminal(): "
            .. "no player found"
        )

        return
    end

    ---------------------------------------------------------------
    -- COMPUTER
    ---------------------------------------------------------------

    if not computer then

        KIPN.Logger.Warn(
            "KIPN_Terminal.OpenTerminal(): "
            .. "computer is nil"
        )

        return
    end

    ---------------------------------------------------------------
    -- RESOLVE COMPUTER SQUARE
    ---------------------------------------------------------------

    local computerSquare =
        nil

    if computer.getSquare then

        computerSquare =
            computer:getSquare()
    end

    if not computerSquare then

        local square =
            getCell():getGridSquare(
                math.floor(
                    computer:getX()
                ),
                math.floor(
                    computer:getY()
                ),
                computer:getZ()
            )

        if square then

            computerSquare =
                square
        end
    end

    if not computerSquare then

        KIPN.Logger.Warn(
            "KIPN_Terminal.OpenTerminal(): "
            .. "unable to resolve computer square"
        )

        return
    end

    ---------------------------------------------------------------
    -- POWER GATE
    --
    -- This is the single entry point every path into the terminal
    -- (fresh open, reused instance, boot screen, login, main menu)
    -- passes through, so none of them can be shown against a
    -- square that has no electricity - the same local, client-side
    -- square read BootScreen's COMPUTER line and Interaction's
    -- context-menu gate already rely on. See
    -- KIPN.Shared.HasSquareElectricity().
    ---------------------------------------------------------------

    local hasPower =
        KIPN.Shared.HasSquareElectricity
        and KIPN.Shared.HasSquareElectricity(
            computerSquare
        )

    if not hasPower then

        KIPN.Logger.Warn(
            "KIPN_Terminal.OpenTerminal(): "
            .. "computer square has no electricity; "
            .. "refusing to open terminal"
        )

        if player.Say then

            player:Say(
                "No power."
            )
        end

        if KIPN_Terminal.instance then

            KIPN_Terminal.instance:close()

        end

        return
    end

    ---------------------------------------------------------------
    -- REUSE EXISTING TERMINAL
    ---------------------------------------------------------------

    if KIPN_Terminal.instance then


        local terminal =
            KIPN_Terminal.instance

        terminal.computer =
            computer

        terminal.computerSquare =
            computerSquare

        terminal:setVisible(
            true
        )

        KIPN.UI.CRT.Mount(terminal)

        -----------------------------------------------------------
        -- RESTORE APPLICATION
        -----------------------------------------------------------

        if not terminal.currentScreen then

            terminal:setScreen(
                KIPN_MainMenu
            )

        elseif terminal.currentScreen.onShow then

            local ok, err =
                pcall(
                    terminal.currentScreen.onShow,
                    terminal.currentScreen
                )

            if not ok then

                KIPN.Logger.Warn(
                    "KIPN_Terminal.OpenTerminal(): "
                    .. "active screen onShow() failed: "
                    .. tostring(err)
                )
            end
        end

        terminal.lastDateTimeMinute =
            nil

        terminal:updateDateTime()

        return
    end

    ---------------------------------------------------------------
    -- CREATE TERMINAL
    ---------------------------------------------------------------

    local w =
        KIPN_Terminal.DEFAULT_WIDTH

    local h =
        KIPN_Terminal.DEFAULT_HEIGHT

    local x =
        (getCore():getScreenWidth() - w)
        / 2

    local y =
        (getCore():getScreenHeight() - h)
        / 2

    local ui =
        KIPN_Terminal:new(
            x,
            y,
            w,
            h
        )

    ui.computer =
        computer

    ui.computerSquare =
        computerSquare

    ---------------------------------------------------------------
    -- INITIALIZE TERMINAL
    ---------------------------------------------------------------

    local initOk, initErr =
        pcall(
            function()
                ui:initialise()
            end
        )

    if not initOk then

        KIPN.Logger.Error(
            "KIPN_Terminal.OpenTerminal(): "
            .. "terminal initialise() failed: "
            .. tostring(initErr)
        )

        return
    end

    ---------------------------------------------------------------
    -- INSTANTIATE TERMINAL
    ---------------------------------------------------------------

    local instantiateOk,
        instantiateErr =
        pcall(
            function()
                ui:instantiate()
            end
        )

    if not instantiateOk then

        KIPN.Logger.Error(
            "KIPN_Terminal.OpenTerminal(): "
            .. "terminal instantiate() failed: "
            .. tostring(instantiateErr)
        )

        return
    end

    ---------------------------------------------------------------
    -- MOUNT IN CRT MONITOR HOUSING
    --
    -- The housing (not the terminal) is what joins the UIManager;
    -- it repositions the terminal inside its bezel, so x/y above
    -- only matter if the housing fails. See KIPN.UI.CRT.
    ---------------------------------------------------------------

    KIPN.UI.CRT.Mount(ui)

    KIPN_Terminal.instance =
        ui

    KIPN.Logger.Info(
        "KIPN_Terminal.OpenTerminal(): "
        .. "terminal opened successfully"
    )
end

--------------------------------------------------------------------
-- NEW
--------------------------------------------------------------------

function KIPN_Terminal:new(
    x,
    y,
    width,
    height
)


    local o =
        ISPanel.new(
            self,
            x,
            y,
            width,
            height
        )

    setmetatable(
        o,
        self
    )

    self.__index =
        self

    return o
end

--------------------------------------------------------------------
-- PLAYER PROXIMITY
--------------------------------------------------------------------

local function onPlayerUpdate(
    isoPlayer
)

    if not isoPlayer then
        return
    end

    if KIPN_Terminal.instance then

        KIPN_Terminal.instance:checkProximity()
    end
end

if Events.OnPlayerUpdate then

    Events.OnPlayerUpdate.Add(
        onPlayerUpdate
    )
end

--------------------------------------------------------------------
-- SERVER RESPONSE ROUTING
--
-- Terminal routes responses to whichever KIPN_MainMenu-family
-- application is active inside it. KIPN_BootScreen and
-- KIPN_SplashScreen are standalone applications outside the
-- terminal and own their own top-level OnServerCommand listeners
-- (see KIPN_BootScreen.lua) -- they are never forwarded through
-- here.
--------------------------------------------------------------------

local function onServerResponse(
    module,
    command,
    args
)


    ---------------------------------------------------------------
    -- KIPN MODULE ONLY
    ---------------------------------------------------------------

    if module ~= "KIPN" then
        return
    end

    ---------------------------------------------------------------
    -- KIPN RESPONSE CHANNEL ONLY
    ---------------------------------------------------------------

    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or command
            ~= KIPN.Shared.Commands.SERVER_RESPONSE then

        return
    end

    ---------------------------------------------------------------
    -- ACTIVE TERMINAL
    ---------------------------------------------------------------

    local terminal =
        KIPN_Terminal.instance

    if not terminal then


        return
    end

    ---------------------------------------------------------------
    -- WEATHER (TERMINAL-OWNED)
    --
    -- Handled here, ahead of the active-screen checks below, so a
    -- FORECAST_DATA/ERROR reply is never dropped just because no
    -- child screen happens to be active/ready yet (e.g. mid
    -- setScreen() transition, or the boot screen, which has no
    -- receiveResponse()). Still falls through to forward the event
    -- to the active screen afterward, unchanged.
    ---------------------------------------------------------------

    local event =
        args and args.event

    if event
        == KIPN.Shared.ResponseEvents.FORECAST_DATA then

        terminal:receiveForecastData(
            args and args.data
        )

    elseif event
        == KIPN.Shared.ResponseEvents.ERROR
        and terminal.forecastRequestPending
        and args
        and args.data
        and args.data.code == "FORECAST_UNAVAILABLE" then

        terminal.forecastRequestPending =
            false
    end

    ---------------------------------------------------------------
    -- ACTIVE SCREEN
    ---------------------------------------------------------------

    local screen =
        terminal.currentScreen

    if not screen then


        return
    end

    ---------------------------------------------------------------
    -- RESPONSE HANDLER
    ---------------------------------------------------------------

    if not screen.receiveResponse then


        return
    end

    ---------------------------------------------------------------
    -- FORWARD RESPONSE
    ---------------------------------------------------------------

    screen:receiveResponse(
        args and args.event,
        args and args.data
    )
end

if Events.OnServerCommand then

    Events.OnServerCommand.Add(
        onServerResponse
    )

end

--------------------------------------------------------------------
-- GAME EXIT
--------------------------------------------------------------------

local function onGameExit()


    if KIPN_Terminal.instance then

        KIPN_Terminal.instance:close()
    end
end

if Events.OnGameExit then

    Events.OnGameExit.Add(
        onGameExit
    )

elseif Events.OnGameQuit then

    Events.OnGameQuit.Add(
        onGameExit
    )
end
