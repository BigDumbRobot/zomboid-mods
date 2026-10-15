-- KIPN_Logger.lua
-- Centralized KIPN logging system.
--
-- Writes KIPN logs to:
--   Zomboid/Lua/KIPN.log
--
-- The logger:
--   1. Writes to the dedicated KIPN.log file.
--   2. Also prints to the normal PZ console/log.
--   3. Records Project Zomboid GAME TIME as the visible log timestamp.
--   4. Uses GAME STARTUP as the timestamp state before world load.
--   5. Identifies the execution side as SERVER, CLIENT, HOST, or UNKNOWN.
--   6. Supports module-scoped loggers through Logger.Create().
--
-- IMPORTANT TIME CONTRACT:
--
--   GAME TIME
--       Project Zomboid's in-world calendar/time.
--       This is affected by the world configuration and game clock.
--       This is the ONLY timestamp shown in the visible KIPN.log line.
--
--   REAL-WORLD DATETIME
--       The operating system's wall-clock datetime is intentionally
--       NOT included in the visible KIPN.log prefix. The KIPN log is
--       a WORLD-TIME log. Real-world datetime must not appear in the
--       public log output.
--------------------------------------------------------------------

KIPN = KIPN or {}
KIPN.Logger = KIPN.Logger or {}

--------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------

KIPN.Logger.Config = KIPN.Logger.Config or {
    FILE_NAME = "KIPN.log",
    PREFIX = "[KIPN]",

    ENABLE_FILE = true,
    ENABLE_CONSOLE = true,

    -- Include the module name in normal log lines when a
    -- module-scoped logger is used.
    ENABLE_MODULE = true,

    -- Minimum level that is emitted. Anything below this is dropped
    -- before any string building or I/O. Overridden at runtime by the
    -- SandboxVars.KIPN.LogLevel enum when that option is present
    -- (1=DEBUG 2=INFO 3=WARN 4=ERROR).
    MIN_LEVEL = "INFO",

    -- Size-based rotation of the dedicated log file, counted in lines
    -- (Project Zomboid's Lua file API has no stat/rename, so the
    -- logger tracks its own line count and trims the file in place).
    -- When the file reaches MAX_LINES it is rewritten keeping only the
    -- most recent ROTATE_KEEP_LINES, prefixed with a rotation marker.
    -- Set MAX_LINES to 0 to disable rotation.
    MAX_LINES = 50000,
    ROTATE_KEEP_LINES = 20000,
}

--------------------------------------------------------------------
-- LEVELS
--------------------------------------------------------------------

KIPN.Logger.Levels = KIPN.Logger.Levels or {
    DEBUG = 10,
    INFO = 20,
    WARN = 30,
    ERROR = 40,
}

-- SandboxVars enum index -> level name.
local SANDBOX_LEVEL_BY_INDEX = {
    [1] = "DEBUG",
    [2] = "INFO",
    [3] = "WARN",
    [4] = "ERROR",
}

-- Cached once a valid sandbox value is seen; nil means "not resolved
-- yet, keep checking" (SandboxVars may not be populated at the moment
-- the first log line is emitted during early boot).
local resolvedMinLevelName = nil

local function levelValue(name)
    return KIPN.Logger.Levels[tostring(name or "INFO"):upper()]
        or KIPN.Logger.Levels.INFO
end

local function currentMinLevelValue()
    if not resolvedMinLevelName then

        local ok, idx = pcall(function()
            if SandboxVars and SandboxVars.KIPN then
                return SandboxVars.KIPN.LogLevel
            end
            return nil
        end)

        if ok and type(idx) == "number" and SANDBOX_LEVEL_BY_INDEX[idx] then
            resolvedMinLevelName = SANDBOX_LEVEL_BY_INDEX[idx]
        end
    end

    return levelValue(
        resolvedMinLevelName
        or KIPN.Logger.Config.MIN_LEVEL
    )
end

--------------------------------------------------------------------
-- LOGGER STATE
--------------------------------------------------------------------

KIPN.Logger.State = KIPN.Logger.State or {
    initialized = false,
}

--------------------------------------------------------------------
-- INTERNAL HELPERS
--------------------------------------------------------------------

--------------------------------------------------------------------
-- EXECUTION SIDE
--
-- SERVER
--     Dedicated server or multiplayer server execution.
--
-- CLIENT
--     Multiplayer client execution.
--
-- HOST
--     Local/single-player execution.
--
-- UNKNOWN
--     Execution context cannot yet be determined.
--------------------------------------------------------------------

-- Once the execution side resolves to a definite value it never
-- changes for the life of the Lua state. getSide() runs on every
-- single log line (several pcalls + engine calls), so cache the
-- first definite answer and short-circuit every later call. "UNKNOWN"
-- is not cached -- that only happens before world context exists and
-- must be allowed to resolve later.
local resolvedSide = nil

local function resolveSideUncached()
    ----------------------------------------------------------------
    -- Dedicated server.
    --
    -- getCore():isDedicated() is an engine-level distinction and
    -- is useful when the server is running without a client UI.
    ----------------------------------------------------------------
    local okDedicated, dedicated = pcall(function()
        if not _G.getCore then
            return false
        end

        local core = _G.getCore()

        if not core then
            return false
        end

        return core:isDedicated()
    end)

    if okDedicated and dedicated then
        return "SERVER"
    end

    ----------------------------------------------------------------
    -- Multiplayer server.
    ----------------------------------------------------------------
    local okServer, server = pcall(function()
        if not _G.isServer then
            return false
        end

        return _G.isServer()
    end)

    if okServer and server then
        return "SERVER"
    end

    ----------------------------------------------------------------
    -- Multiplayer client.
    ----------------------------------------------------------------
    local okClient, client = pcall(function()
        if not _G.isClient then
            return false
        end

        return _G.isClient()
    end)

    if okClient and client then
        return "CLIENT"
    end

    ----------------------------------------------------------------
    -- If neither multiplayer side reports true, determine whether
    -- the environment is a local/single-player game.
    ----------------------------------------------------------------
    local okGameMode, gameMode = pcall(function()
        if not _G.getWorld then
            return nil
        end

        local world = _G.getWorld()

        if not world then
            return nil
        end

        return world:getGameMode()
    end)

    if okGameMode and gameMode then
        if tostring(gameMode) ~= "Multiplayer" then
            return "HOST"
        end
    end

    ----------------------------------------------------------------
    -- Startup can occur before the normal world context exists.
    -- Do NOT mislabel that as HOST.
    ----------------------------------------------------------------
    return "UNKNOWN"
end

local function getSide()
    if resolvedSide then
        return resolvedSide
    end

    local side = resolveSideUncached()

    -- Only cache a settled answer. "UNKNOWN" means world context is
    -- not up yet and a real side is still coming.
    if side ~= "UNKNOWN" then
        resolvedSide = side
    end

    return side
end

--------------------------------------------------------------------
-- WORLD LOADED CHECK
--
-- The logger must not assume GameTime is valid merely because
-- getGameTime() exists.
--
-- We require an actual GameTime instance and valid calendar values.
--------------------------------------------------------------------

local function getGameDate()
    local ok, result = pcall(function()
        if not _G.getGameTime then
            return nil
        end

        local gameTime = _G.getGameTime()

        if not gameTime then
            return nil
        end

        local year = gameTime:getYear()
        local month = gameTime:getMonth()
        local day = gameTime:getDay()
        local hour = gameTime:getHour()
        local minute = gameTime:getMinutes()

        if year == nil
            or month == nil
            or day == nil
            or hour == nil
            or minute == nil then
            return nil
        end

        ----------------------------------------------------------------
        -- PZ / Java month representation is zero-based.
        --
        -- January = 0
        -- February = 1
        -- ...
        -- December = 11
        --
        -- Convert to conventional 1-12 representation.
        ----------------------------------------------------------------
        month = month + 1

        return string.format(
            "%04d-%02d-%02d %02d:%02d",
            year,
            month,
            day,
            hour,
            minute
        )
    end)

    if ok and result then
        return result
    end

    return nil
end

--------------------------------------------------------------------
-- DISPLAY TIMESTAMP
--
-- Before world load:
--
--   GAME STARTUP
--
-- After world load:
--
--   GAME 1993-07-08 21:14
--
-- This is the ONLY timestamp shown in the visible KIPN.log prefix.
-- Real-world datetime is intentionally NOT included.
--------------------------------------------------------------------

local function getGameTimestamp()
    local gameDate = getGameDate()

    if gameDate then
        return "GAME " .. gameDate
    end

    return "GAME STARTUP"
end

--------------------------------------------------------------------
-- LOG PREFIX
--------------------------------------------------------------------

local function getLogPrefix(level, moduleName)
    -- VISIBLE LOG PREFIX -- PROJECT ZOMBOID GAME TIME ONLY.
    --
    -- The visible KIPN.log timestamp MUST represent the Project
    -- Zomboid world calendar/time. Real-world datetime (os.date)
    -- and getTimestampMs() must NEVER appear here.

    local prefix = string.format(
        "%s [%s] [%s] [%s]",
        KIPN.Logger.Config.PREFIX,
        getGameTimestamp(),
        getSide(),
        tostring(level)
    )

    if KIPN.Logger.Config.ENABLE_MODULE
        and moduleName
        and moduleName ~= "" then

        prefix = prefix .. " [" .. tostring(moduleName) .. "]"
    end

    return prefix
end

--------------------------------------------------------------------
-- FILE OUTPUT (with in-place size rotation)
--------------------------------------------------------------------

-- nil until counted from disk on the first write of this session.
local fileLineCount = nil

local function countExistingLines()
    local count = 0

    pcall(function()
        if type(getFileReader) ~= "function" then
            return
        end

        local reader = getFileReader(
            KIPN.Logger.Config.FILE_NAME,
            false
        )

        if not reader then
            return
        end

        while true do
            local l = reader:readLine()
            if l == nil then
                break
            end
            count = count + 1
        end

        reader:close()
    end)

    return count
end

-- Rewrite the file keeping only the most recent ROTATE_KEEP_LINES.
-- Best-effort: any failure leaves the file untouched and logging
-- continues in append mode.
local function rotateFile()
    local keep = tonumber(KIPN.Logger.Config.ROTATE_KEEP_LINES) or 20000

    local ok = pcall(function()
        if type(getFileReader) ~= "function"
            or type(getFileWriter) ~= "function"
        then
            error("file API unavailable")
        end

        local lines = {}

        local reader = getFileReader(
            KIPN.Logger.Config.FILE_NAME,
            false
        )

        if reader then
            while true do
                local l = reader:readLine()
                if l == nil then
                    break
                end
                lines[#lines + 1] = l
            end
            reader:close()
        end

        local startIndex = math.max(1, #lines - keep + 1)

        local writer = getFileWriter(
            KIPN.Logger.Config.FILE_NAME,
            true,
            false
        )

        if not writer then
            error("getFileWriter() returned nil")
        end

        local marker =
            "[KIPN] [GAME " .. tostring(getGameDate() or "STARTUP") .. "]"
            .. " [LOGGER] KIPN.log rotated -- kept most recent "
            .. tostring(#lines - startIndex + 1)
            .. " of " .. tostring(#lines) .. " lines."

        writer:write(marker)
        writer:write("\n")

        for i = startIndex, #lines do
            writer:write(lines[i])
            writer:write("\n")
        end

        writer:close()

        fileLineCount = (#lines - startIndex + 1) + 1
    end)

    return ok
end

local function writeToFile(line)
    if not KIPN.Logger.Config.ENABLE_FILE then
        return true
    end

    if fileLineCount == nil then
        fileLineCount = countExistingLines()
    end

    local maxLines = tonumber(KIPN.Logger.Config.MAX_LINES) or 0

    if maxLines > 0 and fileLineCount >= maxLines then
        if not rotateFile() then
            -- Rotation failed; keep going in append mode but don't
            -- retry every single line.
            fileLineCount = 0
        end
    end

    local writer = nil

    local ok, err = pcall(function()
        writer = getFileWriter(
            KIPN.Logger.Config.FILE_NAME,
            true,
            true
        )

        if not writer then
            error("getFileWriter() returned nil")
        end

        writer:write(line)
        writer:write("\n")

        writer:close()
        writer = nil
    end)

    if not ok then
        if writer then
            pcall(function()
                writer:close()
            end)
        end

        return false, err
    end

    fileLineCount = (fileLineCount or 0) + 1

    return true
end

--------------------------------------------------------------------
-- CONSOLE OUTPUT
--------------------------------------------------------------------

local function writeToConsole(line)
    if not KIPN.Logger.Config.ENABLE_CONSOLE then
        return
    end

    print(line)
end

--------------------------------------------------------------------
-- PUBLIC LOG FUNCTION
--
-- This remains the single underlying logging operation.
--------------------------------------------------------------------

function KIPN.Logger.Log(level, message, moduleName)
    level = tostring(level or "INFO")

    ----------------------------------------------------------------
    -- LEVEL FILTER
    --
    -- Dropped before any string work or I/O.
    ----------------------------------------------------------------
    if levelValue(level) < currentMinLevelValue() then
        return true
    end

    message = tostring(message or "")

    if moduleName ~= nil then
        moduleName = tostring(moduleName)
    end

    local success = false

    local ok, err = pcall(function()
        ------------------------------------------------------------
        -- Build complete log line.
        ------------------------------------------------------------
        local line = string.format(
            "%s %s",
            getLogPrefix(level, moduleName),
            message
        )

        ------------------------------------------------------------
        -- Console output.
        ------------------------------------------------------------
        writeToConsole(line)

        ------------------------------------------------------------
        -- Dedicated KIPN log file.
        ------------------------------------------------------------
        local fileOK, fileError = writeToFile(line)

        if not fileOK then
            print(
                "[KIPN][LOGGER ERROR] Failed to write dedicated log file: " ..
                tostring(fileError)
            )

            error(fileError)
        end

        success = true
    end)

    if not ok then
        return false
    end

    return success
end

--------------------------------------------------------------------
-- ROOT CONVENIENCE FUNCTIONS
--------------------------------------------------------------------

function KIPN.Logger.Info(message)
    return KIPN.Logger.Log("INFO", message)
end

function KIPN.Logger.Warn(message)
    return KIPN.Logger.Log("WARN", message)
end

function KIPN.Logger.Error(message)
    return KIPN.Logger.Log("ERROR", message)
end

function KIPN.Logger.Debug(message)
    return KIPN.Logger.Log("DEBUG", message)
end

--------------------------------------------------------------------
-- MODULE LOGGER
--
-- Creates a lightweight scoped logger for a KIPN subsystem.
--
-- Example:
--
--     local log = KIPN.Logger.Create("AuthService")
--
--     log:Info("Authentication service initialized.")
--     log:Debug("Looking up account.")
--     log:Warn("Invalid credentials.")
--     log:Error("Account database unavailable.")
--
-- The returned object does NOT maintain separate logger state.
-- All output continues through KIPN.Logger.Log().
--------------------------------------------------------------------

---@class KIPN.ModuleLogger
---@field moduleName string
---@field Info fun(self:KIPN.ModuleLogger, message:any):boolean
---@field Warn fun(self:KIPN.ModuleLogger, message:any):boolean
---@field Error fun(self:KIPN.ModuleLogger, message:any):boolean
---@field Debug fun(self:KIPN.ModuleLogger, message:any):boolean

---@param moduleName string Name of the KIPN subsystem.
---@return KIPN.ModuleLogger logger
function KIPN.Logger.Create(moduleName)
    moduleName = tostring(moduleName or "Unknown")

    local logger = {}

    logger.moduleName = moduleName

    ----------------------------------------------------------------
    -- INFO
    ----------------------------------------------------------------

    function logger:Info(message)
        return KIPN.Logger.Log(
            "INFO",
            message,
            self.moduleName
        )
    end

    ----------------------------------------------------------------
    -- WARN
    ----------------------------------------------------------------

    function logger:Warn(message)
        return KIPN.Logger.Log(
            "WARN",
            message,
            self.moduleName
        )
    end

    ----------------------------------------------------------------
    -- ERROR
    ----------------------------------------------------------------

    function logger:Error(message)
        return KIPN.Logger.Log(
            "ERROR",
            message,
            self.moduleName
        )
    end

    ----------------------------------------------------------------
    -- DEBUG
    ----------------------------------------------------------------

    function logger:Debug(message)
        return KIPN.Logger.Log(
            "DEBUG",
            message,
            self.moduleName
        )
    end

    return logger
end

--------------------------------------------------------------------
-- INITIALIZATION
--
-- Initialization is intentionally idempotent.
--
-- This prevents KIPN.Logger initialization messages from being
-- emitted repeatedly if this file is required more than once within
-- the same Lua environment.
--------------------------------------------------------------------

if not KIPN.Logger.State.initialized then
    KIPN.Logger.State.initialized = true

    KIPN.Logger.Info("KIPN Logger initialized.")

    KIPN.Logger.Info(
        "Dedicated log file: " ..
        tostring(KIPN.Logger.Config.FILE_NAME)
    )

    KIPN.Logger.Info(
        "Execution side: " ..
        tostring(getSide())
    )

    KIPN.Logger.Info(
        "Timestamp sources: Project Zomboid GameTime after world load; " ..
        "GAME STARTUP before world load."
    )
end