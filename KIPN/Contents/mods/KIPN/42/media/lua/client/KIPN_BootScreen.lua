-- KIPN_BootScreen.lua
--
-- KIPN live POST / service diagnostic screen.
--
-- The boot screen is a STANDALONE application, triggered directly by
-- the computer power-on event. It is NOT a child of KIPN_Terminal.
--
-- IMPORTANT ARCHITECTURE:
--
-- KIPN_BootScreen owns:
--   * its own UIManager membership (KIPN_BootScreen.Open())
--   * its own proximity check (closes only when the player walks
--     more than KIPN_Terminal.MAX_PROXIMITY squares away -- there is
--     no other way to dismiss it)
--   * its own server-response routing (it is no longer forwarded
--     responses by KIPN_Terminal)
--   * displaying the boot sequence, sized to the server's real
--     bootDurationMs/bootRemainingMs (see KIPN_BootScreen.Open())
--   * checking local square power for the COMPUTER stage
--   * verifying server reachability for the NETWORK stage
--   * handing off to KIPN_SplashScreen on successful completion
--
-- The BootScreen does NOT:
--   * create terminal chrome
--   * own a terminal instance
--   * manufacture successful server responses
--   * reset the server's boot timer when the player walks away --
--     closing this window is purely a client-side "stop watching";
--     the server's bootStartedAtMs/bootDurationMs keep counting
--     regardless (see KIPN.Server.GetComputerBootState() in
--     server/KIPN_Server.lua).
--
-- Power flow:
--
-- The COMPUTER stage's power check is local/client-side ONLY - it
-- reads KIPN.Shared.HasSquareElectricity() against the computer's
-- square, the same way vanilla appliances read square power, and
-- does not round-trip to the server. See
-- KIPN_BootScreen:verifyComputer().
--
-- Network flow:
--
-- The NETWORK stage is the one genuine server round trip in the
-- boot sequence: it sends GET_SERVER_STATUS and waits for a real
-- SERVER_STATUS reply (server/KIPN_Server.lua:handleGetServerStatus)
-- before resolving. See KIPN_BootScreen:requestNetworkCheck() and
-- KIPN_BootScreen:receiveResponse(). That reply also carries a fresh
-- bootRemainingMs, used to resync this screen's timeline against the
-- server in case of client-side drift.
--
-- Every other stage describes work already guaranteed by the
-- terminal/server architecture and always resolves OK once its
-- turn comes up -- no command is manufactured for those.
--
-- Timing:
--
-- The reveal timeline is driven by real elapsed time against the
-- server's bootDurationMs (itself derived from the computer's
-- baudRate -- see KIPN.Server.GetComputerBootDurationMs()), not a
-- fixed local tick count. See KIPN_BootScreen:seedTiming().

require "ISUI/ISPanel"
require "KIPN_UI"

--------------------------------------------------------------------
-- CORE DEPENDENCY
--------------------------------------------------------------------

assert(
    KIPN,
    "KIPN_BootScreen loaded before KIPN core."
)

assert(
    KIPN.Shared,
    "KIPN_BootScreen loaded before KIPN shared definitions."
)

--------------------------------------------------------------------
-- CLASS
--------------------------------------------------------------------

KIPN_BootScreen =
    ISPanel:derive("KIPN_BootScreen")

--------------------------------------------------------------------
-- SINGLE INSTANCE
--
-- Mirrors KIPN_Terminal.instance -- only one Boot Screen is ever
-- shown to the local player at a time.
--------------------------------------------------------------------

KIPN_BootScreen.instance =
    nil

--------------------------------------------------------------------
-- LOGGING
--------------------------------------------------------------------

local function log(message)

    print(
        "[KIPN BOOT] "
        .. tostring(message)
    )
end

local function logWarn(message)

    print(
        "[KIPN BOOT] WARN: "
        .. tostring(message)
    )
end

local function logError(message)

    print(
        "[KIPN BOOT] ERROR: "
        .. tostring(message)
    )
end

--------------------------------------------------------------------
-- RUNTIME CLOCK
--
-- Real elapsed time (not a frame-tick count), used both to time out
-- the NETWORK line's server round trip AND to drive the boot line
-- reveal timeline against the server's bootDurationMs. Mirrors the
-- pattern used by other terminal screens (e.g. KIPN_ServerStats).
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
-- CONSTANTS
--------------------------------------------------------------------

local HOLD_TICKS_AFTER_COMPLETE = 20

local NETWORK_TIMEOUT_MS = 5000

-- Wall-clock backstop, measured against this boot's OWN predicted
-- end (self.localBootEndAtMs, seeded from the server's
-- bootRemainingMs -- so it scales with whatever MaxBootDurationMs the
-- admin set, up to 5 min). However badly the boot goes -- the server
-- never answers, a diagnostic line fails, or the computer's square
-- can't be resolved so the walk-away dismissal in checkProximity()
-- never fires -- once the screen is this far PAST when boot should
-- have finished it force-closes itself, so the player is never
-- trapped in an otherwise undismissable window. Degrades safely to
-- "no backstop" only if getTimestampMs() is unavailable
-- (getRuntimeMs() returns 0), the same limitation the
-- NETWORK_TIMEOUT_MS check above already has.
local MAX_BOOT_OVERRUN_MS = 60000

-- Once boot has failed there is no recovery path from this screen, so
-- an AFK player is auto-released after this long (ESC works
-- immediately -- see onKeyPress()). Long enough to read the failed
-- line first.
local FAILED_AUTOCLOSE_MS = 10000

--------------------------------------------------------------------
-- BOOT LINES
--
-- These are LOCAL DISPLAY LINES, revealed one at a time as real
-- elapsed time crosses each line's slice of the server's
-- bootDurationMs (see KIPN_BootScreen:seedTiming() /
-- KIPN_BootScreen:update()).
--
-- The COMPUTER line performs a local, client-side square power
-- check. The NETWORK line performs a real server round trip (see
-- KIPN_BootScreen:requestNetworkCheck()). Every other line
-- describes work already guaranteed by the terminal/server
-- architecture and always resolves OK once its turn comes up.
--------------------------------------------------------------------

local BOOT_LINES = {

    {
        id = "mem_base",
        label = "640K BASE MEMORY",
        static = true,
    },

    {
        id = "mem_extended",
        label = "EXTENDED MEMORY TEST",
        static = true,
    },

    {
        id = "kernel",
        label = "INITIALIZING KERNEL",
        static = true,
    },

    {
        id = "network",
        label = "DETECTING KIPN NETWORK",
        message = "KIPN NETWORK READY",
    },

    {
        id = "server",
        label = "CONNECTING TO KIPN SERVER",
        message = "SERVER COMMUNICATION READY",
    },

    {
        id = "computer",
        label = "VERIFYING COMPUTER REGISTRY",
    },

    {
        id = "permissions",
        label = "LOADING PERMISSION SERVICES",
        message = "READY",
    },

    {
        id = "world",
        label = "LOADING WORLD REGISTRY",
        message = "READY",
    },

    {
        id = "claims",
        label = "LOADING CLAIMS SERVICE",
        message = "READY",
    },

    {
        id = "services",
        label = "STARTING KIPN TERMINAL SERVICES",
        message = "READY",
    },

}

--------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------

function KIPN_BootScreen:new(
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
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_BootScreen:initialise()

    ISPanel.initialise(self)

    ---------------------------------------------------------------
    -- APPEARANCE
    ---------------------------------------------------------------

    local colors =
        KIPN.Shared.Colors

    if colors
        and colors.bg then

        self.backgroundColor =
            colors.bg

    else

        self.backgroundColor = {
            r = 0,
            g = 0,
            b = 0,
            a = 1
        }

    end

    ---------------------------------------------------------------
    -- STATE
    ---------------------------------------------------------------

    self.tickCount = 0

    self.resolvedCount = 0

    self.finishedTick = nil

    self.done = false

    self.failed = false

    self.bootCompleted = false

    self.testResults = {}

    self.networkPending = false

    self.networkLine = nil

    self.networkRequestSentAt = nil

    ---------------------------------------------------------------
    -- DISMISSAL BACKSTOPS
    --
    -- openedAtMs is the pre-seedTiming() fallback anchor for the
    -- MAX_BOOT_OVERRUN_MS wall-clock backstop; failedAtMs is stamped
    -- the first update() tick after a boot failure and drives
    -- FAILED_AUTOCLOSE_MS. Both exist so a stuck boot can never leave
    -- the player in an undismissable window -- see update() and
    -- onKeyPress().
    ---------------------------------------------------------------

    self.openedAtMs = getRuntimeMs()

    self.failedAtMs = nil

    ---------------------------------------------------------------
    -- BOOT TIMING
    --
    -- Seeded by KIPN_BootScreen.Open() via seedTiming() -- defaults
    -- here only cover the brief window before that call.
    ---------------------------------------------------------------

    self.bootDurationMs = 0

    self.localBootEndAtMs =
        getRuntimeMs()

    self:setWantKeyEvents(true)

    log(
        "Boot diagnostic screen initialized."
    )
end

--------------------------------------------------------------------
-- SEED / RESYNC TIMING
--
-- bootInfo is whatever the server sent back on SET_POWER,
-- CHECK_POWER, or GET_SERVER_STATUS -- all three now include
-- bootDurationMs/bootRemainingMs (see server/KIPN_Server.lua). Using
-- the server's *relative* bootRemainingMs (rather than comparing
-- raw timestamps) avoids any client/server wall-clock drift in
-- multiplayer.
--------------------------------------------------------------------

function KIPN_BootScreen:seedTiming(
    bootInfo
)

    if type(bootInfo) ~= "table" then

        return
    end

    local durationMs =
        tonumber(
            bootInfo.bootDurationMs
        )

    if durationMs then

        self.bootDurationMs =
            durationMs
    end

    local remainingMs =
        tonumber(
            bootInfo.bootRemainingMs
        )

    if not remainingMs then

        remainingMs =
            self.bootDurationMs
    end

    if remainingMs < 0 then

        remainingMs =
            0
    end

    self.localBootEndAtMs =
        getRuntimeMs()
        + remainingMs
end

--------------------------------------------------------------------
-- ADD RESULT
--------------------------------------------------------------------

function KIPN_BootScreen:addResult(
    stage,
    success,
    message
)

    if not stage then

        logError(
            "addResult() received nil stage."
        )

        return false
    end

    self.testResults[stage.id] = {
        success = success == true,
        message = message or "",
    }

    return true
end

--------------------------------------------------------------------
-- GET COMPUTER ID
--------------------------------------------------------------------

function KIPN_BootScreen:getComputerId()

    return self.computerId
end

--------------------------------------------------------------------
-- RESOLVE COMPUTER SQUARE
--
-- KIPN_BootScreen.Open() records self.computerSquare once, from
-- computer:getSquare() at open time. That can legitimately come back
-- nil -- most often right after a reconnect, when the world object
-- exists but its GridSquare hasn't streamed in on this client yet.
-- Left unresolved, checkProximity()'s "not self.computerSquare then
-- return" guard fires every tick and the screen -- which swallows
-- every key (see onKeyPress()) -- never closes except on death.
--
-- This lazily re-resolves it, first from the object directly and
-- then from its coordinates via getCell():getGridSquare(), exactly
-- the fallback KIPN_Terminal.OpenTerminal() already uses. Result is
-- cached back into self.computerSquare once found.
--------------------------------------------------------------------

function KIPN_BootScreen:resolveComputerSquare()

    if self.computerSquare then

        return self.computerSquare
    end

    local computer =
        self.computer

    if not computer then

        return nil
    end

    if computer.getSquare then

        local ok, square =
            pcall(
                function()
                    return computer:getSquare()
                end
            )

        if ok and square then

            self.computerSquare =
                square

            return square
        end
    end

    if computer.getX
        and computer.getY
        and computer.getZ
        and getCell
    then

        local ok, square =
            pcall(
                function()
                    return getCell():getGridSquare(
                        math.floor(computer:getX()),
                        math.floor(computer:getY()),
                        computer:getZ()
                    )
                end
            )

        if ok and square then

            self.computerSquare =
                square

            return square
        end
    end

    return nil
end

--------------------------------------------------------------------
-- VERIFY COMPUTER
--
-- The COMPUTER line is a local, client-side power check against
-- the computer's specific square. It is client-side ONLY - no
-- server round trip. The client already has this information the
-- same way vanilla appliances do. See
-- KIPN.Shared.HasSquareElectricity() for why both
-- square:haveElectricity() and square:hasGridPower() are checked.
--------------------------------------------------------------------

function KIPN_BootScreen:verifyComputer(
    line
)

    local computerId =
        self:getComputerId()

    if not computerId then

        logError(
            "Unable to determine computer ID."
        )

        self:addResult(
            line,
            false,
            "COMPUTER ID UNAVAILABLE"
        )

        return false
    end

    ---------------------------------------------------------------
    -- LOCAL SQUARE POWER CHECK
    --
    -- Client-side ONLY. If the square this computer sits on has no
    -- electricity at all, a real machine with nothing at the
    -- outlet does not attempt POST.
    ---------------------------------------------------------------

    local square =
        self.computerSquare

    if square then

        local hasElectricity =
            KIPN.Shared.HasSquareElectricity
            and KIPN.Shared.HasSquareElectricity(
                square
            )

        if not hasElectricity then

            logError(
                "No electricity at computer square."
            )

            self:addResult(
                line,
                false,
                "NO POWER AT LOCATION"
            )

            return false
        end

    else

        logWarn(
            "Unable to resolve computer square; " ..
            "skipping local power check."
        )

    end

    ---------------------------------------------------------------
    -- COMPUTER LINE PASSES LOCALLY
    --
    -- No server round trip: the local square check above is
    -- authoritative for the boot gate.
    ---------------------------------------------------------------

    self:addResult(
        line,
        true,
        "COMPUTER REGISTRY READY"
    )

    return true
end

--------------------------------------------------------------------
-- REQUEST NETWORK CHECK
--
-- The NETWORK line is the one genuine server round trip in the
-- boot sequence: it sends GET_SERVER_STATUS and waits for a real
-- SERVER_STATUS reply (see KIPN_BootScreen:receiveResponse())
-- before resolving. The boot sequence holds on this line -- see
-- the "NETWORK CHECK IN FLIGHT" guard in update() -- until the
-- reply arrives or the request times out.
--------------------------------------------------------------------

function KIPN_BootScreen:requestNetworkCheck(
    line
)

    local computerId =
        self:getComputerId()

    if not computerId then

        logError(
            "Unable to determine computer ID."
        )

        self:addResult(
            line,
            false,
            "COMPUTER ID UNAVAILABLE"
        )

        self.failed = true

        return
    end

    local command =
        KIPN.Shared.Commands.GET_SERVER_STATUS

    if not command then

        logError(
            "GET_SERVER_STATUS command unavailable."
        )

        self:addResult(
            line,
            false,
            "NETWORK CHECK UNAVAILABLE"
        )

        self.failed = true

        return
    end

    self.networkPending = true

    self.networkLine = line

    self.networkRequestSentAt =
        getRuntimeMs()

    sendClientCommand(
        "KIPN",
        command,
        { computerId = computerId }
    )

    log(
        "Network check requested for computer "
        .. tostring(computerId)
    )
end

--------------------------------------------------------------------
-- RECEIVE RESPONSE
--
-- Unlike before, KIPN_BootScreen is no longer forwarded responses
-- by KIPN_Terminal -- it owns its own module-level OnServerCommand
-- listener at the bottom of this file, which calls this on the
-- active instance.
--------------------------------------------------------------------

function KIPN_BootScreen:receiveResponse(
    event,
    payload
)

    if event
        ~= KIPN.Shared.ResponseEvents.SERVER_STATUS then

        return
    end

    if not self.networkPending then

        return
    end

    if type(payload) == "table"
        and payload.computerId
        and tostring(payload.computerId)
            ~= tostring(self.computerId) then

        return
    end

    self.networkPending = false

    local line =
        self.networkLine

    self.networkLine = nil

    if not line then

        return
    end

    if type(payload) ~= "table" then

        logError(
            "Invalid SERVER_STATUS payload."
        )

        self:addResult(
            line,
            false,
            "NETWORK CHECK FAILED"
        )

        self.failed = true

        return
    end

    ---------------------------------------------------------------
    -- RESYNC TIMING
    --
    -- A fresh bootRemainingMs is a chance to correct any client-
    -- side drift against the server's real elapsed boot time.
    ---------------------------------------------------------------

    self:seedTiming(
        payload
    )

    self:addResult(
        line,
        true,
        "KIPN NETWORK READY"
    )
end

--------------------------------------------------------------------
-- RESOLVE LINE
--
-- Called once per boot line, in order, as the timed sequence
-- reaches it. Every line resolves OK except COMPUTER (real local
-- power check) and NETWORK (real server round trip), either of
-- which can fail the boot.
--------------------------------------------------------------------

function KIPN_BootScreen:resolveLine(
    line
)

    if line.id == "computer" then

        if not self:verifyComputer(line) then

            self.failed = true

        end

        return
    end

    if line.id == "network" then

        self:requestNetworkCheck(line)

        return
    end

    self:addResult(
        line,
        true,
        line.message
    )
end

--------------------------------------------------------------------
-- UPDATE
--------------------------------------------------------------------

function KIPN_BootScreen:update()

    ISPanel.update(self)

    self.tickCount =
        self.tickCount + 1

    ---------------------------------------------------------------
    -- WALL-CLOCK BACKSTOP
    --
    -- Nothing below this point -- the network wait, a failed-boot
    -- hold, the boot-line advance -- is allowed to keep this
    -- key-swallowing screen up more than MAX_BOOT_OVERRUN_MS past
    -- when this boot was predicted to finish. A computer square that
    -- never resolves (so checkProximity() can't dismiss it), a
    -- server that never answers, an unforeseen stall: all end here.
    --
    -- localBootEndAtMs is the reseed-aware predicted end; fall back
    -- to openedAtMs before seedTiming() has run.
    ---------------------------------------------------------------

    local deadlineMs =
        (self.localBootEndAtMs or self.openedAtMs)

    if deadlineMs
        and getRuntimeMs() - deadlineMs
            >= MAX_BOOT_OVERRUN_MS
    then

        logWarn(
            "Boot screen exceeded its predicted end by "
            .. "MAX_BOOT_OVERRUN_MS; force-closing."
        )

        self:closeSelf()

        return
    end

    ---------------------------------------------------------------
    -- NETWORK CHECK IN FLIGHT
    --
    -- The NETWORK line is the only line that round-trips to the
    -- server. The sequence holds here -- no further lines resolve
    -- -- until KIPN_BootScreen:receiveResponse() reports a reply
    -- or the request times out.
    ---------------------------------------------------------------

    if self.networkPending then

        if getRuntimeMs()
            - (self.networkRequestSentAt or 0)
            > NETWORK_TIMEOUT_MS then

            self.networkPending = false

            local line =
                self.networkLine

            self.networkLine = nil

            if line then

                self:addResult(
                    line,
                    false,
                    "NETWORK TIMEOUT"
                )
            end

            self.failed = true
        end

        return
    end

    ---------------------------------------------------------------
    -- BOOT FAILED
    --
    -- Do not silently enter the splash screen / main menu.
    ---------------------------------------------------------------

    if self.failed then

        if not self.finishedTick then

            self.finishedTick =
                self.tickCount

        end

        ------------------------------------------------------------
        -- A failed boot is terminal -- there is no recovery path
        -- from this screen. ESC releases the player immediately
        -- (see onKeyPress()); this auto-releases an AFK one after a
        -- grace window long enough to read the failed line.
        ------------------------------------------------------------

        if not self.failedAtMs then

            self.failedAtMs =
                getRuntimeMs()
        end

        if self.failedAtMs
            and getRuntimeMs() - self.failedAtMs
                >= FAILED_AUTOCLOSE_MS
        then

            self:closeSelf()
        end

        return
    end

    ---------------------------------------------------------------
    -- BOOT COMPLETED
    ---------------------------------------------------------------

    if self.bootCompleted then

        if not self.finishedTick then

            self.finishedTick =
                self.tickCount

        end

        if
            self.tickCount
            - self.finishedTick
            > HOLD_TICKS_AFTER_COMPLETE
        then

            self:completeBoot()

        end

        return
    end

    ---------------------------------------------------------------
    -- ADVANCE BOOT SEQUENCE
    --
    -- Real elapsed time against self.bootDurationMs (seeded from
    -- the server's baudRate-derived boot duration -- see
    -- seedTiming()) decides how many lines are revealed. As the
    -- clock crosses each line's slice, that line resolves (its OK
    -- appears) and the next line becomes visible. A failed line
    -- halts the sequence - no further lines are revealed.
    ---------------------------------------------------------------

    local totalMs =
        self.bootDurationMs
        or 0

    local remainingMs =
        (self.localBootEndAtMs or getRuntimeMs())
        - getRuntimeMs()

    if remainingMs < 0 then

        remainingMs =
            0
    end

    local elapsedMs =
        totalMs
        - remainingMs

    if elapsedMs < 0 then

        elapsedMs =
            0
    end

    local progress =
        1

    if totalMs > 0 then

        progress =
            elapsedMs / totalMs

        if progress > 1 then

            progress =
                1
        end
    end

    local targetResolved =
        math.floor(
            progress
            * #BOOT_LINES
        )

    if targetResolved
        > #BOOT_LINES then

        targetResolved =
            #BOOT_LINES

    end

    while
        self.resolvedCount
        < targetResolved
        and not self.failed
        and not self.networkPending do

        self.resolvedCount =
            self.resolvedCount + 1

        self:resolveLine(
            BOOT_LINES[self.resolvedCount]
        )
    end

    if not self.failed
        and not self.networkPending
        and self.resolvedCount
        >= #BOOT_LINES then

        self.bootCompleted =
            true

        KIPN.Logger.Info(
            "KIPN_BootScreen: "
            .. "boot sequence complete"
        )

    end
end

--------------------------------------------------------------------
-- CLOSE SELF
--
-- Purely a client-side "stop watching" -- never touches server
-- boot state. The server's bootStartedAtMs/bootDurationMs keep
-- counting whether or not anyone is watching (see
-- KIPN.Server.GetComputerBootState() in server/KIPN_Server.lua),
-- which is what makes boot time persist across the player walking
-- away.
--------------------------------------------------------------------

function KIPN_BootScreen:closeSelf()

    self:setVisible(
        false
    )

    KIPN.UI.CRT.Unmount(self)

    if KIPN_BootScreen.instance
        == self then

        KIPN_BootScreen.instance =
            nil
    end
end

--------------------------------------------------------------------
-- CHECK PROXIMITY
--
-- The normal way to dismiss this screen: walking more than
-- KIPN_Terminal.MAX_PROXIMITY squares away, losing power, or dying.
-- The backstops (MAX_BOOT_OVERRUN_MS / a failed boot -- see
-- update() and onKeyPress()) cover the cases this can't.
--------------------------------------------------------------------

function KIPN_BootScreen:checkProximity()

    if KIPN_BootScreen.instance ~= self then

        return
    end

    local player =
        getPlayer()

    if not player
        or player:isDead() then

        self:closeSelf()

        return
    end

    local square =
        self:resolveComputerSquare()

    if not square then

        return
    end

    if KIPN.Shared.HasSquareElectricity
        and not KIPN.Shared.HasSquareElectricity(
            square
        ) then

        self:closeSelf()

        return
    end

    if not KIPN.Shared.IsPlayerNearSquare(
        square,
        KIPN_Terminal.MAX_PROXIMITY,
        KIPN_Terminal.MAX_Z_DIFFERENCE
    ) then

        self:closeSelf()
    end
end

--------------------------------------------------------------------
-- COMPLETE BOOT
--
-- IMPORTANT:
--
-- This does NOT open KIPN_Terminal directly.
--
-- It closes itself and hands off to KIPN_SplashScreen, which holds
-- briefly and then opens KIPN_Terminal itself once its own display
-- timer elapses. See KIPN_SplashScreen.lua.
--------------------------------------------------------------------

function KIPN_BootScreen:completeBoot()

    if self.done then

        return
    end

    if not self.bootCompleted then

        KIPN.Logger.Warn(
            "KIPN_BootScreen:completeBoot(): "
            .. "boot has not completed"
        )

        return
    end

    self.done =
        true

    KIPN.Logger.Info(
        "KIPN_BootScreen: "
        .. "boot complete; handing off to splash screen"
    )

    local computer =
        self.computer

    local computerId =
        self.computerId

    self:closeSelf()

    if not KIPN_SplashScreen
        or not KIPN_SplashScreen.Open then

        logError(
            "Unable to hand off to splash screen: "
            .. "KIPN_SplashScreen.Open() unavailable."
        )

        return
    end

    KIPN_SplashScreen.Open(
        computer,
        computerId
    )
end

--------------------------------------------------------------------
-- DRAW DIAGNOSTICS
--------------------------------------------------------------------

function KIPN_BootScreen:prerender()

    ISPanel.prerender(self)

    local colors =
        KIPN.Shared.Colors

    ---------------------------------------------------------------
    -- SAFE COLOR FALLBACK
    ---------------------------------------------------------------

    local fg = {
        r = 0.2,
        g = 1.0,
        b = 0.2,
        a = 1
    }

    local fgDim = {
        r = 0.1,
        g = 0.5,
        b = 0.1,
        a = 1
    }

    if colors then

        if colors.fg then
            fg =
                colors.fg
        end

        if colors.fgDim then
            fgDim =
                colors.fgDim
        end

    end

    local y =
        20

    ---------------------------------------------------------------
    -- HEADER
    ---------------------------------------------------------------

    self:drawText(
        "KIPN BIOS v2.11",
        14,
        y,
        fg.r,
        fg.g,
        fg.b,
        fg.a,
        UIFont.Small
    )

    y =
        y + 16

    self:drawText(
        "(C) KNOX COUNTY INFORMATION AND PROPERTY NETWORK",
        14,
        y,
        fg.r,
        fg.g,
        fg.b,
        fg.a,
        UIFont.Small
    )

    y =
        y + 24

    ---------------------------------------------------------------
    -- BOOT LINES
    --
    -- Only lines up through the current resolved point are drawn.
    -- One extra "in progress" line (label with no OK/FAILED yet)
    -- is shown while the boot sequence is still running, so the
    -- next line becomes visible only as its turn arrives.
    ---------------------------------------------------------------

    local visibleCount =
        self.resolvedCount

    if not self.failed
        and not self.bootCompleted
        and not self.networkPending
        and visibleCount
        < #BOOT_LINES then

        visibleCount =
            visibleCount + 1

    end

    for index = 1, visibleCount do

        local line =
            BOOT_LINES[index]

        local result =
            self.testResults[line.id]

        local text =
            line.label

        if result then

            if result.success then

                text =
                    text
                    .. "............ OK"

            else

                text =
                    text
                    .. "............ FAILED"

            end

        else

            text =
                text
                .. "............"

        end

        self:drawText(
            text,
            14,
            y,
            fg.r,
            fg.g,
            fg.b,
            fg.a,
            UIFont.Small
        )

        y =
            y + 16

        if result
            and result.message
            and result.message ~= "" then

            self:drawText(
                "    "
                .. tostring(result.message),
                14,
                y,
                fgDim.r,
                fgDim.g,
                fgDim.b,
                fgDim.a,
                UIFont.Small
            )

            y =
                y + 16
        end
    end

    ---------------------------------------------------------------
    -- COMPLETION STATUS
    ---------------------------------------------------------------

    if self.finishedTick then

        y =
            self.height - 42

        if self.failed then

            self:drawText(
                "KIPN STARTUP FAILED",
                14,
                y,
                fg.r,
                fg.g,
                fg.b,
                fg.a,
                UIFont.Small
            )

            self:drawText(
                "CHECK SERVER LOG FOR DETAILS",
                14,
                self.height - 26,
                fgDim.r,
                fgDim.g,
                fgDim.b,
                fgDim.a,
                UIFont.Small
            )

        elseif self.bootCompleted then

            self:drawText(
                "KIPN SYSTEM READY",
                14,
                y,
                fg.r,
                fg.g,
                fg.b,
                fg.a,
                UIFont.Small
            )

            self:drawText(
                "STARTING TERMINAL SERVICES...",
                14,
                self.height - 26,
                fgDim.r,
                fgDim.g,
                fgDim.b,
                fgDim.a,
                UIFont.Small
            )

        end
    end

    ---------------------------------------------------------------
    -- SCANLINES
    --
    -- KIPN_Shared.lua does not currently own DrawScanlines().
    --
    -- If KIPN.UI provides it, use that implementation.
    ---------------------------------------------------------------

    if KIPN.UI
        and KIPN.UI.DrawScanlines then

        KIPN.UI.DrawScanlines(
            self
        )
    end
end

--------------------------------------------------------------------
-- CREATE CHILDREN
--
-- Clickable close ("X"), matching the terminal's own. It calls
-- closeSelf() -- exactly what walking away does -- which only stops
-- WATCHING the boot: the server keeps counting it down, so this is
-- not a way to skip or bypass boot. It exists because every KIPN
-- screen must be dismissable by mouse, not keyboard alone.
--------------------------------------------------------------------

function KIPN_BootScreen:createChildren()

    ISPanel.createChildren(self)

    self.closeButton =
        KIPN.UI.CreateButton(
            self,
            self.width - 40,
            5,
            30,
            20,
            "X",
            KIPN_BootScreen.onCloseClick,
            { danger = true }
        )
end

function KIPN_BootScreen:onCloseClick()
    self:closeSelf()
end

--------------------------------------------------------------------
-- KEY INPUT
--------------------------------------------------------------------

function KIPN_BootScreen:onKeyPress(key)

    ---------------------------------------------------------------
    -- WHILE BOOT IS RUNNING, NO KEY DISMISSES THIS SCREEN.
    --
    -- The player cannot bypass or skip boot via input; walking away
    -- (checkProximity()) or the "X" button (createChildren(), same
    -- closeSelf() "stop watching") are the exits.
    --
    -- ONCE BOOT HAS FAILED, that protection has nothing left to
    -- guard and there is no recovery path from this screen, so ESC
    -- must release the player from what is otherwise an
    -- undismissable window (update() also auto-closes a failed boot
    -- after FAILED_AUTOCLOSE_MS).
    ---------------------------------------------------------------

    if self.failed
        and key == Keyboard.KEY_ESCAPE
    then

        self:closeSelf()
    end

    return true
end

--------------------------------------------------------------------
-- GAME EXIT
--------------------------------------------------------------------

function KIPN_BootScreen:onLeaveScreen()
end

--------------------------------------------------------------------
-- OPEN
--
-- The single entry point for the standalone Boot Screen. Called by
-- KIPN_Interaction.lua the moment the player who powers on a
-- computer receives confirmation it is BOOTING, and again by
-- "Access KIP Network" on a computer that is still BOOTING.
--
-- bootInfo is whatever the server sent back on that response --
-- see seedTiming() for the fields it reads.
--------------------------------------------------------------------

function KIPN_BootScreen.Open(
    computer,
    computerId,
    bootInfo
)

    if not computer
        or not computerId then

        logWarn(
            "KIPN_BootScreen.Open(): "
            .. "computer/computerId missing"
        )

        return nil
    end

    ---------------------------------------------------------------
    -- CLOSE ANY STRAY SPLASH SCREEN
    --
    -- Boot always precedes splash -- if one is somehow still open
    -- (e.g. a very short bootDurationMs raced a second power-on),
    -- it is superseded.
    ---------------------------------------------------------------

    if KIPN_SplashScreen
        and KIPN_SplashScreen.instance then

        KIPN_SplashScreen.instance:closeSelf()
    end

    ---------------------------------------------------------------
    -- REUSE AN EXISTING INSTANCE FOR THE SAME COMPUTER
    --
    -- Just resync its timing against the fresher bootInfo rather
    -- than tearing down and recreating the window.
    ---------------------------------------------------------------

    if KIPN_BootScreen.instance
        and KIPN_BootScreen.instance.computerId
            == computerId then

        KIPN_BootScreen.instance:seedTiming(
            bootInfo
        )

        return KIPN_BootScreen.instance
    end

    ---------------------------------------------------------------
    -- CLOSE A STRAY INSTANCE FOR A DIFFERENT COMPUTER
    ---------------------------------------------------------------

    if KIPN_BootScreen.instance then

        KIPN_BootScreen.instance:closeSelf()
    end

    ---------------------------------------------------------------
    -- CREATE
    --
    -- Same size/centering as KIPN_Terminal.OpenTerminal(), so Boot
    -- -> Splash -> Terminal all occupy the identical screen rect.
    --
    -- All three mount into the one KIPN.UI.CRT monitor housing,
    -- which positions them inside its bezel.
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

    local screen =
        KIPN_BootScreen:new(
            x,
            y,
            w,
            h
        )

    screen.computer =
        computer

    screen.computerId =
        computerId

    screen.computerSquare =
        computer.getSquare
        and computer:getSquare()
        or nil

    ---------------------------------------------------------------
    -- SOUND
    --
    -- The dial-up tone and the looping "on" hum are both entirely
    -- server-driven now (KIPN_Server.lua broadcasts
    -- COMPUTER_SOUND_ON/OFF/SYNC to every online player, not just
    -- whoever opened this screen). The tone is broadcast only for
    -- an explicit "Power On Computer" action; login/state syncs
    -- restore the hum without replaying it. See KIPN_Interaction.lua's
    -- onComputerSoundResponse() handling of those events. This
    -- screen no longer triggers any sound itself.
    ---------------------------------------------------------------

    local initOk, initErr =
        pcall(
            function()
                screen:initialise()
            end
        )

    if not initOk then

        logError(
            "KIPN_BootScreen.Open(): "
            .. "initialise() failed: "
            .. tostring(initErr)
        )

        return nil
    end

    screen:seedTiming(
        bootInfo
    )

    local instantiateOk, instantiateErr =
        pcall(
            function()
                screen:instantiate()
            end
        )

    if not instantiateOk then

        logError(
            "KIPN_BootScreen.Open(): "
            .. "instantiate() failed: "
            .. tostring(instantiateErr)
        )

        return nil
    end

    
    KIPN.UI.CRT.Mount(screen)

    KIPN_BootScreen.instance =
        screen

    log(
        "Opened for computer "
        .. tostring(computerId)
    )

    return screen
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

    if KIPN_BootScreen.instance then

        KIPN_BootScreen.instance:checkProximity()
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
-- KIPN_BootScreen is a standalone application (see file header) and
-- so owns its own top-level OnServerCommand listener, the same way
-- KIPN_Terminal owns one for its own child applications.
--------------------------------------------------------------------

local function onServerResponse(
    module,
    command,
    args
)

    if module ~= "KIPN" then
        return
    end

    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or command
            ~= KIPN.Shared.Commands.SERVER_RESPONSE then

        return
    end

    if not KIPN_BootScreen.instance then

        return
    end

    KIPN_BootScreen.instance:receiveResponse(
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

    if KIPN_BootScreen.instance then

        KIPN_BootScreen.instance:closeSelf()
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

--------------------------------------------------------------------
-- LOADED
--------------------------------------------------------------------

print(
    "[KIPN] Boot Screen loaded"
)
