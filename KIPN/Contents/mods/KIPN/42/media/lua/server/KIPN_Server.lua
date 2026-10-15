-- KIPN_Server.lua
--
-- KIPN server authority and persistent data foundation.
--
-- KIPN_Server.lua is an ORCHESTRATOR.
--
-- It owns:
--   * persistent server state
--   * server authority
--   * command routing
--   * computer lifecycle
--   * networking
--   * service initialization
--
-- It does NOT own:
--   * accounts
--   * sessions
--   * permissions
--   * claims
--   * applications
--   * sandbox implementation
--
-- External integrations belong behind KIPN-owned adapters.
--
-- DEPENDENCY ARCHITECTURE
--
--   KIPN_Logger
--       |
--       v
--   KIPN_Shared
--       |
--       v
--   Server infrastructure
--       |
--       v
--   WorldRegistry
--   Permissions
--   ApplicationRegistry
--       |
--       v
--   Configuration
--       |
--       v
--   Services
--       |
--       v
--   KIPN_Server
--
-- IMPORTANT:
--
-- This file is SERVER ONLY.
--
-- The server bootstrap must load:
--
--   KIPN_Logger
--   KIPN_Shared
--
-- before loading this module.
--
-- KIPN_Server therefore validates those dependencies rather than
-- silently initializing the core infrastructure itself.
--
-- This makes dependency failures explicit and prevents accidental
-- circular initialization.
--
-- IMPORTANT SANDBOX CONFIGURATION:
--
-- KIPN does NOT have a KIPN-specific SandboxVars module.
--
-- Vanilla Project Zomboid SandboxVars are used for KIPN's
-- server/admin feature switches.
--
-- Those vanilla sandbox switches control whether additional
-- administrator configuration controls are available.
--
-- KIPN runtime configuration is handled by KIPN's own
-- configuration/settings services.
--------------------------------------------------------------------


--------------------------------------------------------------------
-- SERVER ONLY
--------------------------------------------------------------------
--
-- KIPN_Server must never execute on a remote multiplayer client.
--
-- isClient() is true in BOTH single-player and multiplayer, since
-- single-player still runs as a client talking to an embedded
-- server. isServer() is the only reliable signal for "this side
-- is authoritative": true in single-player and on the host/
-- dedicated server, false on a remote MP client.
--
-- A bare `if isClient() then return end` guard skips this entire
-- module in single-player, since isClient() is true there too.
--------------------------------------------------------------------

if isClient()
    and not isServer()
then

    return

end


--------------------------------------------------------------------
-- NAMESPACE DEPENDENCY CHECK
--------------------------------------------------------------------
--
-- Some earlier-loading KIPN module (e.g. KIPN_Logger.lua) must
-- already have established the global KIPN table.
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN SERVER] "
        .. "KIPN namespace is not initialized. "
        .. "A KIPN module that establishes it (e.g. "
        .. "KIPN_Logger.lua) must be loaded before "
        .. "KIPN_Server.lua."
    )

end


--------------------------------------------------------------------
-- SERVER NAMESPACE
--------------------------------------------------------------------

KIPN.Server =
    KIPN.Server or {}


--------------------------------------------------------------------
-- DUPLICATE / RECURSIVE LOAD GUARD
--------------------------------------------------------------------
--
-- This guard protects the server orchestrator itself, so that a
-- recursive/duplicate load of this file (e.g. another module's
-- require() chain reaching back into KIPN_Server while it is still
-- mid-execution) returns early instead of re-running the file.
--
-- These are separate responsibilities and both are intentional.
--------------------------------------------------------------------

if KIPN.Server._loading then

    if KIPN.Logger
        and type(KIPN.Logger.Create) == "function"
    then

        local guardLog =
            KIPN.Logger.Create(
                "KIPN_Server"
            )

        guardLog:Warn(
            "Server orchestrator is already loading. "
            .. "Ignoring recursive initialization request."
        )

    else

        print(
            "[KIPN SERVER] "
            .. "Server orchestrator is already loading. "
            .. "Ignoring recursive initialization request."
        )

    end

    return

end


if KIPN.Server._loaded then

    if KIPN.Logger
        and type(KIPN.Logger.Create) == "function"
    then

    else

        print(
            "[KIPN SERVER] "
            .. "Server orchestrator is already initialized. "
            .. "Ignoring duplicate initialization request."
        )

    end

    return

end


--------------------------------------------------------------------
-- MARK SERVER ORCHESTRATOR AS LOADING
--------------------------------------------------------------------

KIPN.Server._loading =
    true


--------------------------------------------------------------------
-- LOGGING DEPENDENCY
--------------------------------------------------------------------
--
-- The logger must already exist.
--
-- KIPN_Server is an orchestrator and therefore does not initialize
-- the logging infrastructure itself.
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN SERVER] "
        .. "KIPN.Logger is not initialized. "
        .. "KIPN_Logger.lua must be loaded before "
        .. "KIPN_Server.lua."
    )

end


if type(KIPN.Logger.Create) ~= "function" then

    error(
        "[KIPN SERVER] "
        .. "KIPN.Logger.Create() is unavailable."
    )

end


--------------------------------------------------------------------
-- MODULE LOGGER
--
-- KIPN.Logger.Create() returns an OBJECT (logger:Info(msg), ...),
-- not a callable value. The rest of this file calls
-- logInfo(...)/logWarn(...)/logError(...) directly, so those must
-- be plain local functions delegating to the logger object's
-- methods.
--------------------------------------------------------------------

local logger =
    KIPN.Logger.Create(
        "KIPN_Server"
    )

local function logInfo(message)

    logger:Info(message)

end

local function logWarn(message)

    logger:Warn(message)

end

local function logError(message)

    logger:Error(message)

end


--------------------------------------------------------------------
-- SHARED CONTRACT DEPENDENCY
--------------------------------------------------------------------
--
-- Shared definitions are required by virtually every KIPN server
-- subsystem.
--
-- require() is idempotent -- it is safe for this call to occur even
-- if the bootstrap has already loaded KIPN_Shared.
--------------------------------------------------------------------

require "KIPN_Shared"
require "KIPN_MD5"

if not KIPN.Shared then

    error(
        "[KIPN SERVER] "
        .. "KIPN.Shared is unavailable after loading "
        .. "KIPN_Shared."
    )

end


--------------------------------------------------------------------
-- SERVER INFRASTRUCTURE
--------------------------------------------------------------------
--
-- These modules establish the foundational registries used by
-- higher-level services.
--
-- They must be loaded before services that depend upon them.
--------------------------------------------------------------------

require "KIPN_WorldRegistry"

-- KIPN_Permissions.lua requires KIPN_Server at its own module top
-- level, so requiring KIPN_Permissions from here would form a
-- circular dependency. Nothing in this file actually calls into
-- Permissions, so it does not need to be required here;
-- KIPN_Permissions.lua already guarantees KIPN_Server is loaded on
-- its own.

require "KIPN_ApplicationRegistry"


--------------------------------------------------------------------
-- CONFIGURATION MODULES
--------------------------------------------------------------------
--
-- These modules define KIPN's configurable rules and settings.
--
-- IMPORTANT:
--
-- There is NO KIPN_SandboxVars.lua here.
--
-- Vanilla SandboxVars are accessed by the appropriate KIPN
-- configuration/settings implementation when needed.
--
-- The configuration modules themselves are loaded before the
-- services that consume them.
--------------------------------------------------------------------

require "KIPN_Config"
require "KIPN_Settings"
require "KIPN_AccountConfig"
require "KIPN_ComputerConfig"
require "KIPN_ArtifactConfig"
require "KIPN_CraftingRequirementsConfig"
require "KIPN_ClaimConfig"
require "KIPN_AnnouncementConfig"


--------------------------------------------------------------------
-- SERVER SERVICES
--------------------------------------------------------------------
--
-- Loading a Lua module and initializing a service are intentionally
-- separate operations.
--
-- This section ONLY loads the service modules.
--
-- Their Initialize() methods are called later in the explicit
-- initialization phase.
--------------------------------------------------------------------

require "KIPN_ArtifactService"
require "KIPN_Wallet"
require "KIPN_ClaimService"
require "KIPN_TokenServer"
require "KIPN_AuthService"
require "KIPN_AdminService"
require "KIPN_AnnouncementService"
require "KIPN_CombatZoneService"
require "KIPN_LeaderboardService"
require "KIPN_StatsService"


--------------------------------------------------------------------
-- FORECAST SERVICE
--------------------------------------------------------------------
--
-- Forecasting is independent of authentication/session management.
--
-- It remains a separate server service and is not mixed into the
-- terminal or client UI.
--------------------------------------------------------------------

require "KIPN_ForecastService"


--------------------------------------------------------------------
-- SERVER MODULE LOAD COMPLETE
--------------------------------------------------------------------
--
-- At this point:
--
--   Core
--   Logger
--   Shared
--   Starlit adapter
--   Registries
--   Configuration modules
--   Server services
--
-- have been loaded.
--
-- They have NOT necessarily been initialized yet.
--
-- Loading and initialization are intentionally separate phases.
--------------------------------------------------------------------




--------------------------------------------------------------------
-- CONFIGURATION
--------------------------------------------------------------------

local DATA_TAG =
    "KIPN_Data"

local LEGACY_POWER_TAG =
    "KIPN_PowerData"

local CURRENT_SCHEMA_VERSION =
    KIPN.Shared.SCHEMA_VERSION

--------------------------------------------------------------------
-- PER-SUBSYSTEM MODDATA TAGS
--------------------------------------------------------------------
--
-- Each top-level field of KIPN.Server.Data is backed by its own
-- ModData tag rather than one shared "KIPN_Data" tag. This lets
-- saveKIPNData(domain) transmit only the subsystem that actually
-- changed instead of broadcasting the entire (claims + computers +
-- accounts + stats + ...) table to every connected client on every
-- unrelated mutation. The shape KIPN.Server.Data presents to the
-- rest of the mod (data.claims, data.computers, ...) is unchanged;
-- only the storage backing each field is split.
--------------------------------------------------------------------

local SUBSYSTEM_TAGS = {

    metadata =
        DATA_TAG .. "_meta",

    computers =
        DATA_TAG .. "_computers",

    computerProfiles =
        DATA_TAG .. "_computerProfiles",

    accounts =
        DATA_TAG .. "_accounts",

    accountsBySteamId =
        DATA_TAG .. "_accountsBySteamId",

    sessions =
        DATA_TAG .. "_sessions",

    records =
        DATA_TAG .. "_records",

    claims =
        DATA_TAG .. "_claims",

    validationKeys =
        DATA_TAG .. "_validationKeys",

    configuration =
        DATA_TAG .. "_configuration",

    audit =
        DATA_TAG .. "_audit",

    playerStats =
        DATA_TAG .. "_playerStats",

    tokens =
        DATA_TAG .. "_tokens",

    adminConfigOverrides =
        DATA_TAG .. "_adminConfigOverrides",

    announcements =
        DATA_TAG .. "_announcements",

    forecast =
        DATA_TAG .. "_forecast",

    statsDisplaySettings =
        DATA_TAG .. "_statsDisplaySettings",

    artifacts =
        DATA_TAG .. "_artifacts",
}

local SUBSYSTEM_FIELDS = {}

for field in pairs(SUBSYSTEM_TAGS) do

    SUBSYSTEM_FIELDS[#SUBSYSTEM_FIELDS + 1] =
        field

end


--------------------------------------------------------------------
-- ADD-ON DATA DOMAINS
--------------------------------------------------------------------
--
-- KIPN.Server.RegisterDataDomain(name, defaultValue)
--
-- Lets a companion service mod claim its own persisted, per-subsystem-
-- transmitted ModData slice without editing this file. The domain
-- becomes GetData().<name>; Save("<name>") persists + transmits only
-- that slice. Must be called at module load, before initServer() runs
-- loadKIPNData() -- companion services register at require() time.
--
-- Built-in domains above are never overridden.
--------------------------------------------------------------------

local extraDataDomains = {}

KIPN.Server._extraDataDomains = extraDataDomains

function KIPN.Server.RegisterDataDomain(name, defaultValue)

    if type(name) ~= "string"
        or name == ""
    then

        logError(
            "RegisterDataDomain rejected: invalid domain name."
        )

        return false
    end

    if SUBSYSTEM_TAGS[name] then

        -- Already a built-in or previously-registered domain.
        return true
    end

    SUBSYSTEM_TAGS[name] =
        DATA_TAG .. "_" .. name

    SUBSYSTEM_FIELDS[#SUBSYSTEM_FIELDS + 1] =
        name

    extraDataDomains[name] =
        (type(defaultValue) == "table")
        and defaultValue
        or {}

    logInfo(
        "Registered add-on data domain: " .. name
    )

    return true
end


--------------------------------------------------------------------
-- HARDWARE CONFIGURATION
--------------------------------------------------------------------

local DEFAULT_BAUD_RATE =
    9600

local REFERENCE_BAUD_RATE =
    9600

local REFERENCE_BOOT_DURATION_MS =
    KIPN.Shared.DEFAULT_BOOT_DURATION_MS
    or 4000

local MIN_BAUD_RATE =
    300

local MAX_BAUD_RATE =
    1000000

local MIN_BOOT_DURATION_MS =
    1000

local MAX_BOOT_DURATION_MS =
    60000

--------------------------------------------------------------------
-- HARDWARE CONDITION
--------------------------------------------------------------------

-- Below this Computer Condition percentage, a computer refuses to
-- power on entirely, regardless of building electricity.
local CONDITION_POWER_OFF_REFUSAL_THRESHOLD =
    10


------------------------------------------------------------
-- BOOT DIAGNOSTIC HELPERS
------------------------------------------------------------
--
-- KIPN_Server owns the diagnostic data returned to clients.
--
-- These diagnostics are intentionally non-destructive.
--
-- IMPORTANT:
--
-- A diagnostic failure must never crash the KIPN server.
-- Diagnostic checks therefore validate the availability of
-- required infrastructure and tolerate optional services.
--
-- These functions do NOT initialize services.
-- They only inspect the current server state.
------------------------------------------------------------

local function createBootDiagnostic(
    id,
    label,
    status,
    message
)



    local diagnostic = {
        id =
            tostring(id),

        label =
            tostring(label),

        status =
            tostring(status),

        message =
            tostring(message),
    }


    return diagnostic
end

------------------------------------------------------------

local function logBootDiagnostic(
    computerId,
    diagnostic
)

end

------------------------------------------------------------
-- CONFIGURATION ACCESS
------------------------------------------------------------

local function getConfig(
    key,
    default
)



    if key == nil then

        logError(
            "getConfig rejected: key is nil."
        )


        return default
    end

    local ok,
        data =
        pcall(
            ModData.getOrCreate,
            DATA_TAG
        )

    if not ok
        or type(data) ~= "table"
    then

        logError(
            "getConfig failed to access persistent data: " ..
            tostring(data)
        )


        return default
    end

    local value =
        data[key]

    if value == nil then

        value =
            default

    end


    return value
end

------------------------------------------------------------

local function setConfig(
    key,
    value
)



    if key == nil then

        logError(
            "setConfig rejected: key is nil."
        )


        return false
    end

    local ok,
        data =
        pcall(
            ModData.getOrCreate,
            DATA_TAG
        )

    if not ok
        or type(data) ~= "table"
    then

        logError(
            "setConfig failed to access persistent data: " ..
            tostring(data)
        )


        return false
    end

    data[key] =
        value


    return true
end

KIPN.Server.GetConfig =
    getConfig

KIPN.Server.SetConfig =
    setConfig

------------------------------------------------------------
-- BAUD RATE
------------------------------------------------------------

local function normalizeBaudRate(
    baudRate
)



    local value =
        tonumber(
            baudRate
        )

    if not value then

        value =
            DEFAULT_BAUD_RATE

    end

    value =
        math.floor(
            value
        )

    if value <
        MIN_BAUD_RATE
    then

        value =
            MIN_BAUD_RATE

    end

    if value >
        MAX_BAUD_RATE
    then

        value =
            MAX_BAUD_RATE

    end


    return value
end

------------------------------------------------------------
-- BOOT DURATION
------------------------------------------------------------

local function calculateBootDurationMs(
    baudRate
)



    local normalizedBaud =
        normalizeBaudRate(
            baudRate
        )

    local duration =
        REFERENCE_BOOT_DURATION_MS
        * (
            REFERENCE_BAUD_RATE /
            normalizedBaud
        )

    duration =
        math.floor(
            duration
        )

    if duration <
        MIN_BOOT_DURATION_MS
    then

        duration =
            MIN_BOOT_DURATION_MS

    end

    if duration >
        MAX_BOOT_DURATION_MS
    then

        duration =
            MAX_BOOT_DURATION_MS

    end


    return duration
end

------------------------------------------------------------
-- HARDWARE CONDITION: INITIAL ROLL
------------------------------------------------------------
--
-- Weighted-band random roll for a computer's starting Computer
-- Condition, keyed off the KIPN.ComputerConditionInitial sandbox
-- preset (Good/Normal/Bad). Each preset is a list of {min, max,
-- weight} bands; a band is picked by weight, then the result is a
-- uniform roll inside that band -- NOT a flat uniform roll across
-- the preset's whole range.
------------------------------------------------------------

local CONDITION_PRESET_BANDS = {

    GOOD = {
        { min = 70, max = 84,  weight = 15 },
        { min = 85, max = 100, weight = 85 },
    },

    NORMAL = {
        { min = 45, max = 50,  weight = 5  },
        { min = 51, max = 74,  weight = 15 },
        { min = 75, max = 85,  weight = 55 },
        { min = 86, max = 95,  weight = 20 },
        { min = 96, max = 100, weight = 5  },
    },

    BAD = {
        { min = 2,  max = 50, weight = 90 },
        { min = 51, max = 80, weight = 10 },
    },
}

local function rollWeightedBand(
    bands
)

    if type(bands) ~= "table"
        or #bands == 0
    then

        return 100
    end

    local totalWeight =
        0

    for _, band in ipairs(bands) do

        totalWeight =
            totalWeight + (band.weight or 0)
    end

    if totalWeight <= 0 then

        return bands[1].min or 100
    end

    local roll

    if type(ZombRand) == "function" then

        roll = ZombRand(totalWeight)

    else

        roll = math.random(0, totalWeight - 1)
    end

    local cursor =
        0

    for _, band in ipairs(bands) do

        cursor =
            cursor + (band.weight or 0)

        if roll < cursor then

            local span =
                band.max - band.min

            local offset

            if type(ZombRand) == "function" then

                offset = ZombRand(span + 1)

            else

                offset = math.random(0, span)
            end

            return band.min + offset
        end
    end

    return bands[#bands].max
end

local function rollInitialComputerCondition()

    local presetIndex =
        (
            KIPN.Server.ComputerConfig
            and KIPN.Server.ComputerConfig.ComputerConditionInitial
        )
        or 2

    local presetKey =
        (
            KIPN.Shared.ComputerConditionPresetOrder
            and KIPN.Shared.ComputerConditionPresetOrder[presetIndex]
        )
        or "NORMAL"

    local bands =
        CONDITION_PRESET_BANDS[presetKey]
        or CONDITION_PRESET_BANDS.NORMAL

    return rollWeightedBand(bands) + 0.0
end

------------------------------------------------------------
-- HARDWARE CONDITION: PERSISTENT HARDWARE IDENTITY
------------------------------------------------------------
--
-- computerId (comp_X_Y_Z) remains the authoritative key for
-- power/boot/baud state and building-electricity checks -- see
-- CheckBuildingPower()'s header comment for why an object hash is
-- deliberately NOT used there.
--
-- Computer Condition is different: it should survive a computer
-- being relocated to a new square, so it is keyed separately, off a
-- UUID the SERVER mints and writes into the world object's modData
-- the first time that specific object is ever registered. Clients
-- never supply or trust this value.
--
-- This UUID is deliberately stored under modData.movableData rather
-- than as a top-level modData key. Vanilla's pickup/place code
-- (ISMoveableSpriteProps.lua) only guarantees a full modData copy
-- between object and item for IsoThumpable moveables -- for other
-- moveable types (which placed computers are) it special-cases just
-- a nested modData.movableData table (plus a couple of unrelated
-- hardcoded keys) when carrying data from object to item and back.
-- A top-level key would silently be dropped on pickup, causing a
-- fresh UUID (and therefore a re-rolled Condition) to be minted the
-- next time the computer is placed and interacted with. Nesting
-- under movableData makes the UUID survive pickup/place using
-- vanilla's own supported mechanism, with no client-side hook
-- needed.
------------------------------------------------------------

local COMPUTER_UUID_MOD_DATA_KEY =
    "KIPN_ComputerHardwareId"

local function resolveComputerWorldObject(
    computerId
)

    local x,
        y,
        z =
        KIPN.Shared.ParseComputerIdCoords(
            computerId
        )

    if not x
        or not y
        or not z
    then

        return nil
    end

    if type(getCell) ~= "function" then

        return nil
    end

    local okCell,
        cell =
        pcall(
            function()

                return getCell()
            end
        )

    if not okCell
        or not cell
        or type(cell.getGridSquare) ~= "function"
    then

        return nil
    end

    local okSquare,
        square =
        pcall(
            function()

                return cell:getGridSquare(x, y, z)
            end
        )

    if not okSquare
        or not square
        or type(square.getObjects) ~= "function"
    then

        return nil
    end

    local okObjects,
        objects =
        pcall(
            function()

                return square:getObjects()
            end
        )

    if not okObjects
        or not objects
        or type(objects.size) ~= "function"
        or type(objects.get) ~= "function"
    then

        return nil
    end

    local okCount,
        count =
        pcall(
            function()

                return objects:size()
            end
        )

    if not okCount
        or not count
    then

        return nil
    end

    for i = 0, count - 1 do

        local okObj,
            obj =
            pcall(
                function()

                    return objects:get(i)
                end
            )

        if okObj
            and obj
            and KIPN.Shared.IsComputerObjectSprite(obj)
        then

            return obj
        end
    end

    return nil
end

local function generateHardwareProfileId(
    profiles
)

    local timestamp =
        os.time()

    local randomPart

    if type(ZombRand) == "function" then

        randomPart = ZombRand(100000, 999999)

    else

        randomPart = math.random(100000, 999999)
    end

    local id

    repeat

        id =
            "hw_" ..
            tostring(timestamp) ..
            "_" ..
            tostring(randomPart)

        if profiles[id] then

            if type(ZombRand) == "function" then

                randomPart = ZombRand(100000, 999999)

            else

                randomPart = math.random(100000, 999999)
            end
        end

    until not profiles[id]

    return id
end

------------------------------------------------------------
-- HARDWARE CONDITION: GET OR CREATE PROFILE
------------------------------------------------------------
--
-- Resolves (creating if necessary) the persistent Computer
-- Condition profile for a computer.
--
-- Returns profileId, profile, changed (changed = true if the
-- caller must persist data).
--
-- Falls back to using computerId itself as the profile key when the
-- world object can't currently be resolved (e.g. an unloaded
-- square) -- this keeps the feature working, at the cost of
-- behaving like a square-keyed model until the object can actually
-- be reached again.
------------------------------------------------------------

local function getOrCreateHardwareProfile(
    computerId,
    data
)

    if type(data) ~= "table" then

        return nil, nil, false
    end

    if type(data.computerProfiles) ~= "table" then

        data.computerProfiles =
            {}
    end

    local profiles =
        data.computerProfiles

    local profileId =
        nil

    local obj =
        resolveComputerWorldObject(
            computerId
        )

    if obj
        and obj.getModData
    then

        local okModData,
            modData =
            pcall(
                function()

                    return obj:getModData()
                end
            )

        if okModData
            and modData
        then

            if type(modData.movableData) ~= "table" then

                modData.movableData =
                    {}
            end

            local movableData =
                modData.movableData

            local existingId =
                movableData[COMPUTER_UUID_MOD_DATA_KEY]

            -- Migration: earlier KIPN versions wrote this UUID as a
            -- top-level modData key instead of nesting it under
            -- movableData (see the header comment above). Fall back
            -- to that legacy location so computers registered before
            -- this fix don't lose their established Condition
            -- profile the first time they're read under the new
            -- scheme -- then re-write it into movableData so it
            -- survives pickup/place going forward.
            if not existingId
                and modData[COMPUTER_UUID_MOD_DATA_KEY]
                and type(modData[COMPUTER_UUID_MOD_DATA_KEY]) == "string"
                and modData[COMPUTER_UUID_MOD_DATA_KEY] ~= ""
            then

                existingId =
                    modData[COMPUTER_UUID_MOD_DATA_KEY]

                movableData[COMPUTER_UUID_MOD_DATA_KEY] =
                    existingId
            end

            if existingId
                and type(existingId) == "string"
                and existingId ~= ""
            then

                profileId =
                    existingId

            else

                profileId =
                    generateHardwareProfileId(
                        profiles
                    )

                movableData[COMPUTER_UUID_MOD_DATA_KEY] =
                    profileId
            end
        end
    end

    if not profileId then

        profileId =
            computerId
    end

    local changed =
        false

    local profile =
        profiles[profileId]

    if type(profile) ~= "table" then

        profile = {

            condition =
                rollInitialComputerCondition(),

            useCount =
                0,

            useDegradationRemainder =
                0,

            lastConditionCheckWorldHours =
                nil,
        }

        profiles[profileId] =
            profile

        changed =
            true
    end

    return profileId,
        profile,
        changed
end

------------------------------------------------------------
-- HARDWARE CONDITION: RESOLVE PROFILE FOR A COMPUTER RECORD
------------------------------------------------------------
--
-- Cheap-path accessor used by every function that needs a
-- computer's Condition data once its record already exists
-- (SetComputerPower, buildBootDiagnostics, the condition tick,
-- etc). Avoids re-scanning the world square on every call: once
-- computer.hardwareProfileId is cached on the record, this is a
-- plain table lookup.
------------------------------------------------------------

local function getComputerProfile(
    computerId,
    computer,
    data
)

    if type(computer) ~= "table"
        or type(data) ~= "table"
    then

        return nil,
            false
    end

    if type(data.computerProfiles) ~=
        "table"
    then

        data.computerProfiles =
            {}
    end

    if computer.hardwareProfileId
        and data.computerProfiles[
            computer.hardwareProfileId
        ]
    then

        return data.computerProfiles[
            computer.hardwareProfileId
        ],
            false
    end

    local profileId,
        profile =
        getOrCreateHardwareProfile(
            computerId,
            data
        )

    if profileId then

        computer.hardwareProfileId =
            profileId
    end

    return profile,
        true
end

------------------------------------------------------------
-- FORWARD DECLARATIONS
------------------------------------------------------------
--
-- These functions are assigned later in KIPN_Server.lua.
--
-- Hardware functions can therefore reference them before the
-- registry implementation physically appears in this file.
------------------------------------------------------------

local saveKIPNData

local loadKIPNData

------------------------------------------------------------
-- JSON DIAGNOSTIC EXPORT THROTTLE
------------------------------------------------------------
--
-- kipn_data.json is a human-readable snapshot of the ENTIRE
-- persisted database, written for bug reports / manual inspection.
-- It is never read back on the normal path and is not authoritative
-- (ModData is).
--
-- saveKIPNData() can fire many times per second on a populated
-- server (every player stat-delta flush calls Save("playerStats")).
-- Re-serializing and rewriting the whole database file on every one
-- of those is pure waste, and it grows more expensive as the save
-- ages. Throttle the snapshot to at most once per interval; the
-- authoritative ModData write above is untouched and still runs on
-- every save.
--
-- Set KIPN.Server.DiagnosticJsonExportEnabled = false (console or a
-- patch) to disable the snapshot entirely. A SandboxVars.KIPN
-- boolean of the same name, if present, overrides the default.
------------------------------------------------------------

local DIAGNOSTIC_JSON_EXPORT_MIN_INTERVAL_MS =
    60000

local lastDiagnosticJsonExportMs =
    nil

-- OFF by default. When on, every throttled Save() re-serializes the
-- ENTIRE KIPN dataset and rewrites kipn_data.json -- useful for a
-- one-off look at the data, not something a live server should pay
-- for on every persist. Turn it on from the console or a sandbox
-- override (KIPN.DiagnosticJsonExportEnabled) only while inspecting.
KIPN.Server.DiagnosticJsonExportEnabled =
    false

local function diagnosticJsonExportAllowed()

    ----------------------------------------------------------
    -- Optional sandbox override (the option does not have to
    -- exist -- a missing field just leaves the Lua default).
    ----------------------------------------------------------

    local sandboxValue = nil

    local okSandbox = pcall(function()
        if SandboxVars
            and SandboxVars.KIPN
        then
            sandboxValue =
                SandboxVars.KIPN.DiagnosticJsonExportEnabled
        end
    end)

    if okSandbox and type(sandboxValue) == "boolean" then

        if not sandboxValue then
            return false
        end

    elseif not KIPN.Server.DiagnosticJsonExportEnabled then

        return false
    end

    ----------------------------------------------------------
    -- Time throttle.
    ----------------------------------------------------------

    local now =
        (type(getTimestampMs) == "function")
        and getTimestampMs()
        or 0

    if lastDiagnosticJsonExportMs ~= nil
        and (now - lastDiagnosticJsonExportMs)
            < DIAGNOSTIC_JSON_EXPORT_MIN_INTERVAL_MS
    then

        return false
    end

    lastDiagnosticJsonExportMs =
        now

    return true
end

------------------------------------------------------------
-- COMPUTER BAUD RATE
------------------------------------------------------------

function KIPN.Server.GetComputerBaudRate(
    computerId
)



    if not computerId then

        logError(
            "GetComputerBaudRate rejected: " ..
            "missing computerId."
        )


        return DEFAULT_BAUD_RATE
    end

    if type(
        KIPN.Server.GetData
    ) ~= "function"
    then

        logError(
            "GetComputerBaudRate failed: " ..
            "KIPN.Server.GetData() is unavailable."
        )


        return DEFAULT_BAUD_RATE
    end

    local okData,
        data =
        pcall(
            KIPN.Server.GetData
        )

    if not okData
        or type(data) ~= "table"
        or type(data.computers) ~= "table"
    then

        logError(
            "GetComputerBaudRate failed: " ..
            "computer registry unavailable."
        )


        return DEFAULT_BAUD_RATE
    end

    local computer =
        data.computers[
            computerId
        ]

    if type(computer) ~= "table" then

        logWarn(
            "No computer record exists for " ..
            tostring(computerId) ..
            ". Using default baud rate."
        )


        return DEFAULT_BAUD_RATE
    end

    local dataChanged =
        false

    --------------------------------------------------------
    -- MIGRATE MISSING BAUD RATE
    --------------------------------------------------------

    if computer.baudRate == nil then

        computer.baudRate =
            DEFAULT_BAUD_RATE

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- NORMALIZE EXISTING BAUD RATE
    --------------------------------------------------------

    local originalBaudRate =
        computer.baudRate

    local baudRate =
        normalizeBaudRate(
            computer.baudRate
        )

    if originalBaudRate ~=
        baudRate
    then

        computer.baudRate =
            baudRate

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- PERSIST MIGRATION / NORMALIZATION
    --------------------------------------------------------

    if dataChanged then

        if type(saveKIPNData) ==
            "function"
        then

            local saved =
                saveKIPNData()

            if not saved then

                logError(
                    "Failed to persist baud rate migration " ..
                    "for computer " ..
                    tostring(computerId) ..
                    "."
                )


                return baudRate
            end

        else

            logError(
                "saveKIPNData() is unavailable while " ..
                "persisting baud rate migration."
            )


            return baudRate
        end
    end


    return baudRate
end

------------------------------------------------------------
-- COMPUTER BAUD RATE SETTER
------------------------------------------------------------

function KIPN.Server.SetComputerBaudRate(
    computerId,
    baudRate
)



    if not computerId
        or baudRate == nil
    then

        logError(
            "SetComputerBaudRate rejected: " ..
            "computerId and baudRate are required."
        )


        return false
    end

    if type(
        KIPN.Server.GetOrCreateComputer
    ) ~= "function"
    then

        logError(
            "SetComputerBaudRate failed: " ..
            "KIPN.Server.GetOrCreateComputer() is unavailable."
        )


        return false
    end

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if type(computer) ~= "table" then

        logError(
            "Unable to resolve computer " ..
            tostring(computerId) ..
            " while setting baud rate."
        )


        return false
    end

    local normalized =
        normalizeBaudRate(
            baudRate
        )

    computer.baudRate =
        normalized


    --------------------------------------------------------
    -- UPDATE FUTURE BOOT DURATION
    --------------------------------------------------------
    --
    -- Do not alter an active boot sequence.
    --
    -- If the computer is currently powered on and not
    -- booting, update the stored boot duration so the next
    -- boot uses the new baud rate.
    --------------------------------------------------------

    if computer.power == true
        and computer.bootState ~=
            KIPN.Shared.BootStates.BOOTING
    then

        computer.bootDurationMs =
            calculateBootDurationMs(
                normalized
            )

    end

    --------------------------------------------------------
    -- PERSIST
    --------------------------------------------------------

    if type(saveKIPNData) ~=
        "function"
    then

        logError(
            "SetComputerBaudRate failed: " ..
            "saveKIPNData() is unavailable."
        )


        return false
    end

    local saved =
        saveKIPNData()


    return saved
end

------------------------------------------------------------
-- COMPUTER BOOT DIAGNOSTICS
------------------------------------------------------------

local function buildBootDiagnostics(
    computerId
)



    local diagnostics = {}

    --------------------------------------------------------
    -- VALIDATE COMPUTER ID
    --------------------------------------------------------

    if not computerId then

        logError(
            "buildBootDiagnostics rejected: " ..
            "missing computerId."
        )


        return diagnostics,
            false
    end

    --------------------------------------------------------
    -- BIOS / CORE
    --------------------------------------------------------

    local biosOk =
        KIPN ~= nil
        and KIPN.Server ~= nil
        and KIPN.Shared ~= nil

    local biosDiagnostic =
        createBootDiagnostic(
            "bios",
            "KIPN BIOS",
            biosOk
                and "OK"
                or "FAILED",
            biosOk
                and "KIPN server foundation available."
                or "KIPN server foundation unavailable."
        )

    diagnostics[#diagnostics + 1] =
        biosDiagnostic

    logBootDiagnostic(
        computerId,
        biosDiagnostic
    )

    --------------------------------------------------------
    -- MEMORY
    --------------------------------------------------------

    local data =
        nil

    local memoryOk =
        false

    if KIPN.Server
        and type(
            KIPN.Server.GetData
        ) == "function"
    then

        local okData,
            dataResult =
            pcall(
                KIPN.Server.GetData
            )

        if okData then

            data =
                dataResult

            memoryOk =
                type(data) == "table"

            if not memoryOk then

                logError(
                    "MEMORY TEST failed: " ..
                    "KIPN.Server.GetData() returned " ..
                    "an invalid data structure."
                )
            end

        else

            logError(
                "MEMORY TEST failed while retrieving " ..
                "KIPN data: " ..
                tostring(dataResult)
            )
        end

    else

        logError(
            "MEMORY TEST failed: " ..
            "KIPN.Server.GetData() unavailable."
        )
    end

    local memoryDiagnostic =
        createBootDiagnostic(
            "memory",
            "MEMORY TEST",
            memoryOk
                and "OK"
                or "FAILED",
            memoryOk
                and "KIPN persistent data structure available."
                or "KIPN persistent data unavailable."
        )

    diagnostics[#diagnostics + 1] =
        memoryDiagnostic

    logBootDiagnostic(
        computerId,
        memoryDiagnostic
    )

    --------------------------------------------------------
    -- KIPN.SYS
    --------------------------------------------------------

    local kernelOk =
        KIPN.Server ~= nil
        and type(
            KIPN.Server.GetData
        ) == "function"
        and type(
            KIPN.Server.GetComputer
        ) == "function"

    local kernelDiagnostic =
        createBootDiagnostic(
            "kipn_sys",
            "KIPN.SYS",
            kernelOk
                and "OK"
                or "FAILED",
            kernelOk
                and "KIPN server core is operational."
                or "Required KIPN server functions unavailable."
        )

    diagnostics[#diagnostics + 1] =
        kernelDiagnostic

    logBootDiagnostic(
        computerId,
        kernelDiagnostic
    )

    --------------------------------------------------------
    -- NETSVC.SYS
    --------------------------------------------------------
    --
    -- sendServerCommand() is the vanilla server-to-client
    -- transport primitive.
    --
    -- Its existence establishes that the transport API is
    -- available. It does not prove that a specific client is
    -- currently connected.
    --------------------------------------------------------

    local networkTransportOk =
        type(
            sendServerCommand
        ) == "function"

    local networkResponseOk =
        KIPN.Server ~= nil
        and type(
            KIPN.Server.SendToPlayer
        ) == "function"

    local networkOk =
        networkTransportOk
        and networkResponseOk

    local networkDiagnostic =
        createBootDiagnostic(
            "netsvc_sys",
            "NETSVC.SYS",
            networkOk
                and "OK"
                or "FAILED",
            networkOk
                and "KIPN server command transport available."
                or "KIPN server command transport unavailable."
        )

    diagnostics[#diagnostics + 1] =
        networkDiagnostic

    logBootDiagnostic(
        computerId,
        networkDiagnostic
    )

    --------------------------------------------------------
    -- CLAIMS.SYS
    --------------------------------------------------------

    local claimService =
        KIPN.Server.ClaimService
        or KIPN.ClaimService

    local claimsOk =
        type(
            claimService
        ) == "table"

    local claimsDiagnostic =
        createBootDiagnostic(
            "claims_sys",
            "CLAIMS.SYS",
            claimsOk
                and "OK"
                or "FAILED",
            claimsOk
                and "KIPN Claim Service available."
                or "KIPN Claim Service unavailable."
        )

    diagnostics[#diagnostics + 1] =
        claimsDiagnostic

    logBootDiagnostic(
        computerId,
        claimsDiagnostic
    )

    --------------------------------------------------------
    -- TERMINAL SERVICES
    --------------------------------------------------------
    --
    -- The command router may expose either:
    --
    --   GetCommandHandler()
    --
    -- or the registration surface:
    --
    --   RegisterCommandHandler()
    --
    -- Accept either as evidence that the command-routing
    -- interface exists.
    --------------------------------------------------------

    local commandRouterOk =
        KIPN.Server ~= nil
        and (
            type(
                KIPN.Server.GetCommandHandler
            ) == "function"
            or
            type(
                KIPN.Server.RegisterCommandHandler
            ) == "function"
        )

    local terminalResponseOk =
        KIPN.Server ~= nil
        and type(
            KIPN.Server.SendToPlayer
        ) == "function"

    local terminalOk =
        commandRouterOk
        and terminalResponseOk

    local terminalDiagnostic =
        createBootDiagnostic(
            "terminal_services",
            "TERMINAL SERVICES",
            terminalOk
                and "OK"
                or "FAILED",
            terminalOk
                and "KIPN terminal communication services available."
                or "KIPN terminal communication services unavailable."
        )

    diagnostics[#diagnostics + 1] =
        terminalDiagnostic

    logBootDiagnostic(
        computerId,
        terminalDiagnostic
    )

    --------------------------------------------------------
    -- NETWORK DETECTION
    --------------------------------------------------------

    local computer =
        nil

    local networkDetectionOk =
        false

    if KIPN.Server
        and type(
            KIPN.Server.GetComputer
        ) == "function"
    then

        local okComputer,
            computerResult =
            pcall(
                KIPN.Server.GetComputer,
                computerId
            )

        if okComputer then

            computer =
                computerResult

            networkDetectionOk =
                type(computer) == "table"

            if not networkDetectionOk then

                logError(
                    "NETWORK DETECTION failed: " ..
                    "computer " ..
                    tostring(computerId) ..
                    " is not registered."
                )
            end

        else

            logError(
                "NETWORK DETECTION failed for computer " ..
                tostring(computerId) ..
                ": " ..
                tostring(computerResult)
            )
        end

    else

        logError(
            "NETWORK DETECTION failed: " ..
            "KIPN.Server.GetComputer() unavailable."
        )
    end

    local networkDetectionDiagnostic =
        createBootDiagnostic(
            "network_detection",
            "NETWORK DETECTION",
            networkDetectionOk
                and "CONNECTED"
                or "FAILED",
            networkDetectionOk
                and "Computer registered with KIPN server."
                or "Computer record unavailable."
        )

    diagnostics[#diagnostics + 1] =
        networkDetectionDiagnostic

    logBootDiagnostic(
        computerId,
        networkDetectionDiagnostic
    )

    --------------------------------------------------------
    -- NETWORK CONNECTION
    --------------------------------------------------------

    local networkConnectionOk =
        networkDetectionOk
        and networkTransportOk
        and networkResponseOk

    local networkConnectionDiagnostic =
        createBootDiagnostic(
            "network_connection",
            "NETWORK CONNECTION",
            networkConnectionOk
                and "CONNECTED"
                or "FAILED",
            networkConnectionOk
                and "KIPN server communication established."
                or "Unable to establish KIPN server communication."
        )

    diagnostics[#diagnostics + 1] =
        networkConnectionDiagnostic

    logBootDiagnostic(
        computerId,
        networkConnectionDiagnostic
    )

    --------------------------------------------------------
    -- KIPN NETWORK
    --------------------------------------------------------

    local kipnNetworkOk =
        networkConnectionOk
        and KIPN.Server ~= nil
        and (
            type(
                KIPN.Server.GetCommandHandler
            ) == "function"
            or
            type(
                KIPN.Server.RegisterCommandHandler
            ) == "function"
        )
        and type(
            KIPN.Server.SendToPlayer
        ) == "function"

    local kipnNetworkDiagnostic =
        createBootDiagnostic(
            "kipn_network",
            "KIPN NETWORK",
            kipnNetworkOk
                and "CONNECTED"
                or "FAILED",
            kipnNetworkOk
                and "KIPN network services operational."
                or "KIPN network services unavailable."
        )

    diagnostics[#diagnostics + 1] =
        kipnNetworkDiagnostic

    logBootDiagnostic(
        computerId,
        kipnNetworkDiagnostic
    )

    --------------------------------------------------------
    -- CONNECTION SPEED / BAUD RATE
    --------------------------------------------------------

    local baudRate =
        DEFAULT_BAUD_RATE

    local baudOk =
        false

    if KIPN.Server
        and type(
            KIPN.Server.GetComputerBaudRate
        ) == "function"
    then

        local okBaud,
            baudResult =
            pcall(
                KIPN.Server.GetComputerBaudRate,
                computerId
            )

        if okBaud
            and baudResult ~= nil
        then

            baudRate =
                normalizeBaudRate(
                    baudResult
                )

            baudOk =
                true

        else

            logError(
                "Unable to resolve baud rate for computer " ..
                tostring(computerId) ..
                ". Using default " ..
                tostring(DEFAULT_BAUD_RATE) ..
                " BAUD."
            )
        end

    else

        logError(
            "GetComputerBaudRate() unavailable for computer " ..
            tostring(computerId) ..
            ". Using default " ..
            tostring(DEFAULT_BAUD_RATE) ..
            " BAUD."
        )
    end

    local baudDiagnostic =
        createBootDiagnostic(
            "baud",
            "CONNECTION SPEED",
            baudOk
                and "OK"
                or "DEFAULT",
            tostring(baudRate) ..
            " BAUD"
        )

    diagnostics[#diagnostics + 1] =
        baudDiagnostic

    logBootDiagnostic(
        computerId,
        baudDiagnostic
    )

    --------------------------------------------------------
    -- HARDWARE CONDITION
    --------------------------------------------------------

    local condition =
        100

    if KIPN.Server
        and type(
            KIPN.Server.GetComputerProfile
        ) == "function"
    then

        local okProfile,
            profileResult =
            pcall(
                KIPN.Server.GetComputerProfile,
                computerId
            )

        if okProfile
            and type(profileResult) == "table"
            and profileResult.condition ~= nil
        then

            condition =
                profileResult.condition
        end
    end

    local conditionRounded =
        math.floor(condition + 0.5)

    local conditionStatus =
        "OK"

    if conditionRounded < CONDITION_POWER_OFF_REFUSAL_THRESHOLD then

        conditionStatus =
            "FAILED"

    elseif conditionRounded < 30 then

        conditionStatus =
            "CRITICAL"

    elseif conditionRounded < 60 then

        conditionStatus =
            "DEGRADED"
    end

    local conditionDiagnostic =
        createBootDiagnostic(
            "hardware_condition",
            "HARDWARE CONDITION",
            conditionStatus,
            tostring(conditionRounded) ..
            "%"
        )

    diagnostics[#diagnostics + 1] =
        conditionDiagnostic

    logBootDiagnostic(
        computerId,
        conditionDiagnostic
    )

    --------------------------------------------------------
    -- FINAL RESULT
    --------------------------------------------------------
    --
    -- BAUD is intentionally NOT included in allRequiredOk.
    --
    -- HARDWARE CONDITION is also NOT included in allRequiredOk --
    -- a computer whose condition drops below the refusal threshold
    -- never reaches BOOTING in the first place (SetComputerPower
    -- refuses it beforehand), so FAILED is theoretically
    -- unreachable here; the branch exists defensively only.
    --
    -- A missing/invalid baud configuration falls back to the
    -- safe default and therefore does not make the KIPN machine
    -- itself fail POST.
    --------------------------------------------------------

    local allRequiredOk =
        biosOk
        and memoryOk
        and kernelOk
        and networkOk
        and claimsOk
        and terminalOk
        and networkDetectionOk
        and networkConnectionOk
        and kipnNetworkOk



    return diagnostics,
        allRequiredOk
end

------------------------------------------------------------
-- PUBLIC BOOT DIAGNOSTIC ACCESS
------------------------------------------------------------

function KIPN.Server.GetComputerBootDiagnostics(
    computerId
)



    if not computerId then

        logError(
            "GetComputerBootDiagnostics rejected: " ..
            "missing computerId."
        )


        return {}
    end

    if type(
        KIPN.Server.GetComputer
    ) ~= "function"
    then

        logError(
            "GetComputerBootDiagnostics failed: " ..
            "KIPN.Server.GetComputer() is unavailable."
        )


        return {}
    end

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerBootDiagnostics failed: " ..
            "computer not found: " ..
            tostring(computerId)
        )


        return {}
    end

    --------------------------------------------------------
    -- RETURN EXISTING DIAGNOSTICS
    --------------------------------------------------------
    --
    -- Diagnostics are generated during boot and persisted
    -- with the computer record.
    --
    -- Do not rebuild them every time this function is called.
    --------------------------------------------------------

    if type(
        computer.bootDiagnostics
    ) == "table"
        and #computer.bootDiagnostics > 0
    then



        return computer.bootDiagnostics
    end

    --------------------------------------------------------
    -- GENERATE DIAGNOSTICS
    --------------------------------------------------------

    if type(
        buildBootDiagnostics
    ) ~= "function"
    then

        logError(
            "GetComputerBootDiagnostics failed: " ..
            "buildBootDiagnostics() is unavailable."
        )


        return {}
    end

    local diagnostics,
        diagnosticsOk =
        buildBootDiagnostics(
            computerId
        )

    if type(diagnostics) ~= "table" then

        logError(
            "buildBootDiagnostics() returned an invalid " ..
            "diagnostic collection for computer=" ..
            tostring(computerId)
        )


        return {}
    end

    computer.bootDiagnostics =
        diagnostics


    --------------------------------------------------------
    -- PERSIST GENERATED DIAGNOSTICS
    --------------------------------------------------------

    local saved =
        false

    if type(saveKIPNData) ==
        "function"
    then

        saved =
            saveKIPNData()

    else

        logError(
            "Unable to persist boot diagnostics: " ..
            "saveKIPNData() is unavailable."
        )
    end

    --------------------------------------------------------
    -- FINAL RESULT
    --------------------------------------------------------

    local success =
        diagnosticsOk
        and saved


    return diagnostics
end

------------------------------------------------------------
-- COMMAND ROUTER
------------------------------------------------------------

KIPN.Server.CommandHandlers =
    KIPN.Server.CommandHandlers
    or {}

------------------------------------------------------------
-- REGISTER COMMAND HANDLER
------------------------------------------------------------

function KIPN.Server.RegisterCommandHandler(
    command,
    handler
)



    if type(command) ~= "string"
        or command == ""
    then

        logError(
            "Cannot register command handler: " ..
            "missing or invalid command."
        )


        return false
    end

    if type(handler) ~= "function" then

        logError(
            "Cannot register command handler for " ..
            tostring(command) ..
            ": handler is not a function."
        )


        return false
    end

    if KIPN.Server.CommandHandlers[
        command
    ] ~= nil
    then

        logError(
            "Command handler already registered: " ..
            tostring(command)
        )


        return false
    end

    KIPN.Server.CommandHandlers[
        command
    ] =
        handler



    return true
end

------------------------------------------------------------
-- GET COMMAND HANDLER
------------------------------------------------------------

function KIPN.Server.GetCommandHandler(
    command
)



    if type(command) ~= "string"
        or command == ""
    then


        return nil
    end

    local handler =
        KIPN.Server.CommandHandlers[
            command
        ]

    local found =
        type(handler) == "function"


    return handler
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRY
------------------------------------------------------------
--
-- KIPN.Server.RegisterService(name, def)
--
--   def = {
--       initialize = function() ... end,   -- returns false on failure
--       dependsOn  = { "WorldRegistry", "ClaimService", ... },
--       order      = <number>,             -- tie-breaker, default 500
--   }
--
-- A companion service mod calls this at module load. After KIPN's own
-- built-in services have initialized (end of initServer(), just before
-- the final Save()), RunRegisteredServices() initializes every
-- registrant in dependsOn / order topological order, each guarded and
-- logged the same way the built-in initializeService() helper does.
--
-- KIPN's own in-tree services may also register this way as they are
-- migrated off the hardcoded init ladder; a name already initialized
-- by the ladder is skipped here (idempotent).
------------------------------------------------------------

KIPN.Server._registeredServices =
    KIPN.Server._registeredServices
    or {}

KIPN.Server._serviceInitDone =
    KIPN.Server._serviceInitDone
    or {}

function KIPN.Server.RegisterService(name, def)

    if type(name) ~= "string"
        or name == ""
    then

        logError(
            "RegisterService rejected: invalid service name."
        )

        return false
    end

    if type(def) ~= "table" then

        logError(
            "RegisterService rejected for " .. name ..
            ": definition is not a table."
        )

        return false
    end

    if KIPN.Server._registeredServices[name] then

        logError(
            "RegisterService: service already registered: " .. name
        )

        return false
    end

    def.name = name

    if type(def.dependsOn) ~= "table" then
        def.dependsOn = {}
    end

    if type(def.order) ~= "number" then
        def.order = 500
    end

    --------------------------------------------------------
    -- SERVICE API VERSION CHECK
    --------------------------------------------------------
    --
    -- Advisory, not enforced: a mismatch is logged prominently but
    -- the service is still registered and initialized. The companion
    -- mod is responsible for its own hard bail (KIPN.API.Require) if
    -- it cannot run against this KIPN.
    --
    -- A missing apiVersion is NOT a warning: an add-on that does not
    -- pin a version is declaring "build me against whatever KIPN ships",
    -- i.e. latest. Only an explicitly-declared, incompatible version is
    -- worth surfacing.
    --------------------------------------------------------

    if def.apiVersion == nil then

        def.apiVersion = KIPN.Shared.API_VERSION

    elseif KIPN.API and type(KIPN.API.IsCompatible) == "function" then

        local compatible, reason =
            KIPN.API.IsCompatible(def.apiVersion)

        if not compatible then

            logWarn(
                "Service '" .. name .. "' " .. tostring(reason) ..
                ". KIPN will still attempt to initialize it -- it may " ..
                "misbehave. Update the mod(s) involved."
            )
        end
    end

    KIPN.Server._registeredServices[name] = def

    logInfo(
        "Registered add-on service: " .. name ..
        " (API v" .. tostring(def.apiVersion) .. ")"
    )

    return true
end

------------------------------------------------------------
-- RUN REGISTERED SERVICES
------------------------------------------------------------
--
-- Topological order over def.dependsOn, then def.order, then name.
-- A dependency that is not itself a registered add-on service is
-- treated as already satisfied (it is a built-in initialized by the
-- ladder above this call site).
------------------------------------------------------------

function KIPN.Server.RunRegisteredServices()

    local services =
        KIPN.Server._registeredServices

    local done =
        KIPN.Server._serviceInitDone

    local pending = {}

    for name in pairs(services) do
        if not done[name] then
            pending[#pending + 1] = name
        end
    end

    table.sort(
        pending,
        function(a, b)

            local da = services[a]
            local db = services[b]

            if da.order ~= db.order then
                return da.order < db.order
            end

            return a < b
        end
    )

    local allOk = true
    local guard = 0
    local maxPasses = #pending + 2

    while #pending > 0 and guard < maxPasses do

        guard = guard + 1

        local progressed = false
        local stillPending = {}

        for _, name in ipairs(pending) do

            local def = services[name]

            local depsReady = true

            for _, depName in ipairs(def.dependsOn) do

                if services[depName]
                    and not done[depName]
                then
                    depsReady = false
                    break
                end
            end

            if not depsReady then

                stillPending[#stillPending + 1] = name

            else

                progressed = true

                local initFn = def.initialize
                local ok, result = true, true

                if type(initFn) == "function" then
                    ok, result = pcall(initFn)
                end

                if not ok then

                    logError(
                        "Add-on service init failed for " .. name ..
                        ": " .. tostring(result)
                    )

                    allOk = false

                elseif result == false then

                    logError(
                        "Add-on service rejected init: " .. name
                    )

                    allOk = false

                else

                    logInfo(
                        "Add-on service initialized: " .. name
                    )
                end

                done[name] = true
            end
        end

        pending = stillPending

        if not progressed then
            break
        end
    end

    if #pending > 0 then

        allOk = false

        for _, name in ipairs(pending) do

            logError(
                "Add-on service not initialized (unresolved " ..
                "dependency cycle or missing dependency): " .. name
            )

            done[name] = true
        end
    end

    return allOk
end

------------------------------------------------------------
-- DEFAULT SCHEMA
------------------------------------------------------------

local function createDefaultSchema()



    local data = {

        schemaVersion =
            CURRENT_SCHEMA_VERSION,

        metadata = {

            createdAt =
                nil,

            lastLoadedAt =
                nil,

            lastSavedAt =
                nil,
        },

        computers = {},

        computerProfiles = {},

        accounts = {},

        accountsBySteamId = {},

        sessions = {},

        records = {},

        claims = {},

        validationKeys = {},

        configuration = {

            account = {},

            permissions = {},

            computers = {},

            applications = {},

            claims = {},

            world = {},
        },

        audit = {},
    }

    --------------------------------------------------------
    -- ADD-ON DATA DOMAINS
    --
    -- Any domain a companion service registered via
    -- KIPN.Server.RegisterDataDomain() gets an empty slice
    -- here so GetData().<name> is always a table.
    --------------------------------------------------------

    for domainName in pairs(extraDataDomains) do

        if data[domainName] == nil then

            data[domainName] = {}

        end
    end


    return data
end

------------------------------------------------------------
-- SCHEMA VALIDATION
------------------------------------------------------------

local function ensureTable(
    parent,
    key
)



    if type(parent) ~= "table" then

        logError(
            "ensureTable failed: parent is not a table " ..
            "for key=" ..
            tostring(key)
        )


        return nil
    end

    if type(parent[key]) ~= "table" then

        parent[key] =
            {}

    end


    return parent[key]
end

------------------------------------------------------------
-- ENSURE SCHEMA
------------------------------------------------------------

local function ensureSchema(
    data
)



    --------------------------------------------------------
    -- INVALID ROOT DATA
    --------------------------------------------------------

    if type(data) ~= "table" then

        logWarn(
            "KIPN persistent data was invalid. " ..
            "Creating default schema."
        )

        local defaultData =
            createDefaultSchema()


        return defaultData,
            true
    end

    --------------------------------------------------------
    -- SCHEMA VERSION
    --------------------------------------------------------

    local currentVersion =
        tonumber(
            data.schemaVersion
        )
        or 0

    local targetVersion =
        tonumber(
            CURRENT_SCHEMA_VERSION
        )
        or 1

    local schemaChanged =
        false

    if currentVersion <
        targetVersion
    then


        ----------------------------------------------------
        -- FUTURE MIGRATIONS
        ----------------------------------------------------
        --
        -- Version-specific migrations belong here.
        --
        -- Example:
        --
        -- if currentVersion < 2 then
        --     ...
        --     currentVersion = 2
        -- end
        --
        -- The current migration layer is intentionally
        -- structural because the schema is being normalized
        -- below.
        ----------------------------------------------------

        schemaChanged =
            true
    end

    --------------------------------------------------------
    -- CORE TABLES
    --------------------------------------------------------

    ensureTable(
        data,
        "metadata"
    )

    ensureTable(
        data,
        "computers"
    )

    ensureTable(
        data,
        "computerProfiles"
    )

    ensureTable(
        data,
        "accounts"
    )

    ensureTable(
        data,
        "accountsBySteamId"
    )

    ensureTable(
        data,
        "sessions"
    )

    ensureTable(
        data,
        "records"
    )

    ensureTable(
        data,
        "claims"
    )

    ensureTable(
        data,
        "validationKeys"
    )

    ensureTable(
        data,
        "configuration"
    )

    ensureTable(
        data,
        "audit"
    )

    ensureTable(
        data,
        "playerStats"
    )

    --------------------------------------------------------
    -- ADD-ON DATA DOMAINS
    --
    -- Registered via KIPN.Server.RegisterDataDomain(). Ensured
    -- here so a companion service that was enabled after the
    -- save was first created still finds GetData().<name> ready.
    --------------------------------------------------------

    for domainName in pairs(extraDataDomains) do

        ensureTable(
            data,
            domainName
        )
    end

    --------------------------------------------------------
    -- METADATA
    --------------------------------------------------------

    if data.metadata.createdAt == nil then

        data.metadata.createdAt =
            nil

    end

    if data.metadata.lastLoadedAt == nil then

        data.metadata.lastLoadedAt =
            nil

    end

    if data.metadata.lastSavedAt == nil then

        data.metadata.lastSavedAt =
            nil

    end

    --------------------------------------------------------
    -- CONFIGURATION SUBTABLES
    --------------------------------------------------------

    ensureTable(
        data.configuration,
        "account"
    )

    ensureTable(
        data.configuration,
        "permissions"
    )

    ensureTable(
        data.configuration,
        "computers"
    )

    ensureTable(
        data.configuration,
        "applications"
    )

    ensureTable(
        data.configuration,
        "claims"
    )

    ensureTable(
        data.configuration,
        "world"
    )

    --------------------------------------------------------
    -- NORMALIZE SCHEMA VERSION
    --------------------------------------------------------
    --
    -- This is important.
    --
    -- A schema migration is not complete if the persistent
    -- record continues to report the old schema version.
    --------------------------------------------------------

    if data.schemaVersion ~=
        targetVersion
    then


        data.schemaVersion =
            targetVersion

        schemaChanged =
            true
    end

    --------------------------------------------------------
    -- RESULT
    --------------------------------------------------------



    return data,
        schemaChanged
end

------------------------------------------------------------
-- RECORD-MAP SANITIZATION (corrupt-row resilience)
------------------------------------------------------------
--
-- ensureSchema() guarantees each subsystem's top-level container is a
-- table, but not that every ROW inside it is well-formed. A single
-- malformed entry -- a string where a record table is expected, a nil
-- hole, a number -- can throw deep inside a service that iterates the
-- map, and one bad row must never stop the whole server coming up.
--
-- This pass walks the flat `id -> record-table` maps (and the two
-- nested record stores) and moves any non-table entry into the
-- KIPN_Data__quarantine ModData tag: nothing is silently lost, the
-- operator can inspect/recover it by hand, and the live maps are left
-- containing only iterable rows. Capped so a pathologically corrupt
-- save can't balloon the quarantine.
------------------------------------------------------------

local QUARANTINE_TAG = DATA_TAG .. "__quarantine"
local QUARANTINE_MAX = 500

local SANITIZE_FLAT_MAPS = {
    "accounts",
    "computers",
    "computerProfiles",
    "playerStats",
    "audit",
    "sessions",
    "validationKeys",
    "tokens",
}

local function sanitizeNowMs()
    if type(getTimestampMs) ~= "function" then
        return 0
    end

    local ok, value = pcall(getTimestampMs)
    return (ok and type(value) == "number") and value or 0
end

local function quarantineRow(qStore, mapName, key, value)
    if (qStore.count or 0) >= QUARANTINE_MAX then
        return false
    end

    qStore.rows = qStore.rows or {}
    qStore.rows[mapName] = qStore.rows[mapName] or {}

    qStore.rows[mapName][tostring(key)] = {
        valueType = type(value),
        -- Stringify non-tables so a weird value type can never
        -- re-enter the live data through the quarantine.
        rendered = (type(value) == "table") and "<table>" or tostring(value),
        quarantinedAtMs = sanitizeNowMs(),
    }

    qStore.count = (qStore.count or 0) + 1
    return true
end

local function sanitizeMap(map, mapName, qStore, summary)
    if type(map) ~= "table" then
        return
    end

    local bad = {}

    for key, value in pairs(map) do
        if type(value) ~= "table" then
            bad[#bad + 1] = key
        end
    end

    for _, key in ipairs(bad) do
        quarantineRow(qStore, mapName, key, map[key])
        map[key] = nil
        summary[mapName] = (summary[mapName] or 0) + 1
    end
end

local function sanitizeRecordMaps(data)
    if type(data) ~= "table" then
        return
    end

    local qStore
    local okQ, q = pcall(ModData.getOrCreate, QUARANTINE_TAG)
    if okQ and type(q) == "table" then
        qStore = q
    else
        qStore = {}
    end

    local summary = {}

    for _, mapName in ipairs(SANITIZE_FLAT_MAPS) do
        pcall(sanitizeMap, data[mapName], mapName, qStore, summary)
    end

    if type(data.claims) == "table" then
        pcall(sanitizeMap, data.claims.records, "claims.records", qStore, summary)
    end

    if type(data.artifacts) == "table" then
        pcall(sanitizeMap, data.artifacts.records, "artifacts.records", qStore, summary)
    end

    local total = 0

    for name, n in pairs(summary) do
        total = total + n
        logError(
            "Data sanitize: quarantined " .. tostring(n) ..
            " malformed row(s) from '" .. tostring(name) .. "'."
        )
    end

    if total > 0 then
        logError(
            "Data sanitize: " .. tostring(total) .. " malformed row(s) moved to " ..
            "ModData tag '" .. QUARANTINE_TAG .. "'. KIPN started normally; " ..
            "inspect that tag to recover anything important."
        )

        if (qStore.count or 0) >= QUARANTINE_MAX then
            logError(
                "Data sanitize: quarantine cap (" .. QUARANTINE_MAX ..
                ") reached -- further malformed rows are dropped, not stored."
            )
        end
    end
end

------------------------------------------------------------
-- EXISTING COMPUTER RECORD MIGRATION
------------------------------------------------------------
--
-- Normalize existing computer records after schema validation.
--
-- This migration is intentionally non-destructive.
--
-- Existing computer records retain their identity and state.
-- Missing hardware/runtime fields receive safe defaults.
------------------------------------------------------------

local function migrateExistingComputerRecords(
    data,
    targetVersion
)



    if type(data) ~= "table" then

        logError(
            "Computer migration failed: " ..
            "data is not a table."
        )


        return false
    end

    if type(data.computers) ~= "table" then

        logError(
            "Computer migration failed: " ..
            "data.computers is not a table."
        )


        return false
    end

    local bootStates =
        KIPN.Shared
        and KIPN.Shared.BootStates

    local migratedCount =
        0

    local changedCount =
        0

    --------------------------------------------------------
    -- EXISTING COMPUTER RECORDS
    --------------------------------------------------------

    for computerId,
        computer in pairs(
            data.computers
        )
    do

        if type(computer) == "table" then

            local changed =
                false

            ------------------------------------------------
            -- BAUD RATE
            ------------------------------------------------

            if computer.baudRate == nil then

                computer.baudRate =
                    DEFAULT_BAUD_RATE

                changed =
                    true


            else

                local originalBaudRate =
                    computer.baudRate

                local normalizedBaudRate =
                    normalizeBaudRate(
                        computer.baudRate
                    )

                if originalBaudRate ~=
                    normalizedBaudRate
                then

                    computer.baudRate =
                        normalizedBaudRate

                    changed =
                        true

                end
            end

            ------------------------------------------------
            -- BOOT DURATION
            ------------------------------------------------
            --
            -- Only powered computers need an active boot
            -- duration during migration.
            ------------------------------------------------

            if computer.power == true then

                local expectedBootDuration =
                    calculateBootDurationMs(
                        computer.baudRate
                    )

                if computer.bootDurationMs == nil then

                    computer.bootDurationMs =
                        expectedBootDuration

                    changed =
                        true


                else

                    local normalizedBootDuration =
                        tonumber(
                            computer.bootDurationMs
                        )

                    if not normalizedBootDuration then

                        normalizedBootDuration =
                            expectedBootDuration

                    else

                        normalizedBootDuration =
                            math.floor(
                                normalizedBootDuration
                            )

                        if normalizedBootDuration <
                            MIN_BOOT_DURATION_MS
                        then

                            normalizedBootDuration =
                                MIN_BOOT_DURATION_MS

                        elseif normalizedBootDuration >
                            MAX_BOOT_DURATION_MS
                        then

                            normalizedBootDuration =
                                MAX_BOOT_DURATION_MS
                        end
                    end

                    if computer.bootDurationMs ~=
                        normalizedBootDuration
                    then

                        computer.bootDurationMs =
                            normalizedBootDuration

                        changed =
                            true

                    end
                end
            end

            ------------------------------------------------
            -- BOOT DIAGNOSTICS
            ------------------------------------------------

            if type(
                computer.bootDiagnostics
            ) ~= "table"
            then

                computer.bootDiagnostics =
                    {}

                changed =
                    true

            end

            ------------------------------------------------
            -- BOOT STATE
            ------------------------------------------------

            if computer.bootState == nil then

                if computer.power == true then

                    if bootStates
                        and bootStates.BOOTING
                    then

                        computer.bootState =
                            bootStates.BOOTING

                    else

                        logError(
                            "Unable to migrate computer " ..
                            tostring(computerId) ..
                            ": " ..
                            "KIPN.Shared.BootStates.BOOTING " ..
                            "is unavailable."
                        )

                    end

                    if not computer.bootStartedAtMs then

                        computer.bootStartedAtMs =
                            getTimestampMs
                            and getTimestampMs()
                            or 0

                        changed =
                            true
                    end

                    changed =
                        true


                else

                    if bootStates
                        and bootStates.OFF
                    then

                        computer.bootState =
                            bootStates.OFF

                        changed =
                            true


                    else

                        logError(
                            "Unable to migrate computer " ..
                            tostring(computerId) ..
                            ": " ..
                            "KIPN.Shared.BootStates.OFF " ..
                            "is unavailable."
                        )
                    end
                end
            end

            ------------------------------------------------
            -- CAPABILITIES
            ------------------------------------------------

            if type(
                computer.capabilities
            ) ~= "table"
            then

                computer.capabilities =
                    {}

                changed =
                    true

            end

            ------------------------------------------------
            -- MIGRATION ACCOUNTING
            ------------------------------------------------

            if changed then

                changedCount =
                    changedCount + 1


            end

            migratedCount =
                migratedCount + 1
        end
    end

    --------------------------------------------------------
    -- SCHEMA VERSION
    --------------------------------------------------------

    data.schemaVersion =
        targetVersion



    return true
end

------------------------------------------------------------
-- LEGACY POWER DATA MIGRATION
------------------------------------------------------------
--
-- Legacy power data is intentionally NOT copied into the
-- current schema automatically.
--
-- The current computer registry is authoritative.
--
-- We only detect the legacy dataset here so that an older
-- KIPN installation does not silently lose track of it.
------------------------------------------------------------

local function migrateLegacyPowerData()



    local data =
        KIPN.Server.Data

    if not data then

        logError(
            "Legacy power migration failed: " ..
            "KIPN data unavailable."
        )


        return false
    end

    --------------------------------------------------------
    -- DETECT LEGACY DATA WITHOUT CREATING IT
    --------------------------------------------------------

    local legacyExists =
        false

    if ModData
        and type(
            ModData.exists
        ) == "function"
    then

        local okExists,
            existsResult =
            pcall(
                ModData.exists,
                LEGACY_POWER_TAG
            )

        if okExists then

            legacyExists =
                existsResult == true

        else


        end

    else



        return true
    end

    --------------------------------------------------------
    -- NO LEGACY DATA
    --------------------------------------------------------

    if not legacyExists then



        return true
    end

    --------------------------------------------------------
    -- LEGACY DATA DETECTED
    --------------------------------------------------------
    --
    -- Do NOT destructively delete or overwrite it.
    --
    -- The current computer records remain authoritative.
    --------------------------------------------------------



    return true
end

------------------------------------------------------------
-- SCHEMA MIGRATION (with automatic rollback)
------------------------------------------------------------
--
-- When a loaded save's schemaVersion is older than
-- CURRENT_SCHEMA_VERSION, the ordered steps in SCHEMA_MIGRATIONS are
-- run to bring it forward. Before any step runs, every KIPN_Data_*
-- tag is duplicated to a `<tag>__migbak_v<oldVersion>` sibling. If any
-- step errors, the live tags are restored from those backups IN PLACE
-- (so the `data` table's references stay valid) and KIPN continues on
-- the OLD schema version -- the server stays fully up; the operator
-- sees a loud warning. Backups are emptied after the first clean save
-- following a successful migration.
--
-- To add a migration: add SCHEMA_MIGRATIONS[N] = function(data) ... end
-- where N is the *target* version that step produces, and bump
-- KIPN.Shared.SCHEMA_VERSION. Steps must be idempotent-safe and must
-- only mutate `data.<field>` tables in place.
------------------------------------------------------------

local SCHEMA_MIGRATIONS = {
    -- [2] = function(data) ... end,
    -- [3] = function(data) ... end,
}

local MIGBAK_SUFFIX = "__migbak_v"

local migrationAttemptedThisProcess = false

local function migbakTagFor(field, oldVersion)
    return SUBSYSTEM_TAGS[field] .. MIGBAK_SUFFIX .. tostring(oldVersion)
end

local function deepCopyValue(value, depth)
    if type(value) ~= "table" then
        return value
    end

    if depth and depth > 60 then
        return nil
    end

    local out = {}

    for k, v in pairs(value) do
        out[k] = deepCopyValue(v, (depth or 0) + 1)
    end

    return out
end

-- Replace the contents of `dst` with a deep copy of `src`, keeping the
-- same table object (so existing references to `dst` stay valid).
local function refillTable(dst, src)
    for k in pairs(dst) do
        dst[k] = nil
    end

    if type(src) == "table" then
        for k, v in pairs(src) do
            dst[k] = deepCopyValue(v)
        end
    end
end

local function backupSubsystemTags(oldVersion)
    local created = {}

    for _, field in ipairs(SUBSYSTEM_FIELDS) do
        local bakTag = migbakTagFor(field, oldVersion)

        local okSrc, src = pcall(ModData.getOrCreate, SUBSYSTEM_TAGS[field])
        local okBak, bak = pcall(ModData.getOrCreate, bakTag)

        if okSrc and okBak
            and type(src) == "table"
            and type(bak) == "table"
        then
            refillTable(bak, src)
            created[#created + 1] = bakTag
        else
            error("could not back up tag for field=" .. tostring(field))
        end
    end

    return created
end

local function restoreSubsystemTags(oldVersion, data)
    for _, field in ipairs(SUBSYSTEM_FIELDS) do
        local bakTag = migbakTagFor(field, oldVersion)

        local okBak, bak = pcall(ModData.getOrCreate, bakTag)
        local live = data[field]

        if okBak and type(bak) == "table" and type(live) == "table" then
            refillTable(live, bak)
        end
    end
end

local function emptyBackupTags(tagList)
    if type(tagList) ~= "table" then
        return
    end

    for _, bakTag in ipairs(tagList) do
        -- Empty it first so it serializes to nothing even on engine
        -- builds where ModData.remove is a no-op or absent.
        local okBak, bak = pcall(ModData.getOrCreate, bakTag)

        if okBak and type(bak) == "table" then
            for k in pairs(bak) do
                bak[k] = nil
            end
        end

        if ModData and type(ModData.remove) == "function" then
            pcall(ModData.remove, bakTag)
        end
    end
end

-- Runs migrations fromVersion -> toVersion. Returns true on success,
-- or false plus an error string (after restoring the backups).
local function runSchemaMigrations(data, fromVersion, toVersion)

    local backupTags

    local okBackup, backupErr = pcall(function()
        backupTags = backupSubsystemTags(fromVersion)
    end)

    if not okBackup then
        return false, "backup failed: " .. tostring(backupErr)
    end

    local okRun, runErr = pcall(function()
        for v = fromVersion + 1, toVersion do
            local step = SCHEMA_MIGRATIONS[v]

            if type(step) == "function" then
                logInfo(
                    "Running schema migration to version " .. tostring(v) .. "."
                )
                step(data)
            end
        end
    end)

    if not okRun then
        logError(
            "Schema migration " .. tostring(fromVersion) .. " -> " ..
            tostring(toVersion) .. " FAILED: " .. tostring(runErr) ..
            ". Restoring pre-migration data."
        )

        pcall(restoreSubsystemTags, fromVersion, data)

        return false, tostring(runErr)
    end

    -- Success -- hand the backup list to the save path for cleanup.
    KIPN.Server._migrationBackupTags = backupTags

    return true
end

local function maybeMigrateSchema(data)

    if migrationAttemptedThisProcess then
        return
    end

    local oldVersion = tonumber(data.schemaVersion)
    local targetVersion = tonumber(CURRENT_SCHEMA_VERSION) or 1

    -- A fresh save has no schemaVersion yet -- that is not a migration,
    -- ensureSchema() stamps it below.
    if not oldVersion
        or oldVersion <= 0
        or oldVersion >= targetVersion
    then
        return
    end

    migrationAttemptedThisProcess = true

    logInfo(
        "KIPN save schema v" .. tostring(oldVersion) ..
        " < current v" .. tostring(targetVersion) ..
        " -- migrating (a pre-migration backup is taken first)."
    )

    if type(data.metadata) ~= "table" then
        data.metadata = {}
    end

    local ok = runSchemaMigrations(data, oldVersion, targetVersion)

    if ok then
        data.schemaVersion = targetVersion
        data.metadata.schemaVersion = targetVersion

        KIPN.Server._migrationResult = {
            outcome = "migrated",
            from = oldVersion,
            to = targetVersion,
        }

        logInfo(
            "Schema migration to v" .. tostring(targetVersion) ..
            " complete."
        )
    else
        -- Stay on the old schema; server continues running.
        data.schemaVersion = oldVersion
        data.metadata.schemaVersion = oldVersion

        KIPN.Server._migrationResult = {
            outcome = "rolled_back",
            from = oldVersion,
            to = targetVersion,
        }

        logError(
            "==============================================================\n" ..
            "KIPN SCHEMA MIGRATION ROLLED BACK.\n" ..
            "The save has been restored to schema v" .. tostring(oldVersion) ..
            " and KIPN is running normally on that version.\n" ..
            "Some v" .. tostring(targetVersion) .. " features may be " ..
            "unavailable until this is resolved. Check the lines above " ..
            "for the migration error, and report it.\n" ..
            "=============================================================="
        )
    end
end

------------------------------------------------------------
-- PERSISTENT DATA LOADING
------------------------------------------------------------

loadKIPNData = function()



    --------------------------------------------------------
    -- LOAD MODDATA (PER SUBSYSTEM)
    --------------------------------------------------------
    --
    -- Each subsystem tag is loaded independently so a failure
    -- loading one field (e.g. "claims") falls back to an empty
    -- table for that field only, instead of discarding every
    -- other already-working subsystem. ensureSchema() repairs
    -- structure below regardless of which fields were fresh.
    --------------------------------------------------------

    local data =
        {}

    for _, field in ipairs(SUBSYSTEM_FIELDS) do

        local ok,
            fieldData =
            pcall(
                ModData.getOrCreate,
                SUBSYSTEM_TAGS[field]
            )

        if ok
            and type(fieldData) == "table"
        then

            data[field] =
                fieldData

        else

            logError(
                "Unable to load/create KIPN persistent data " ..
                "for field=" ..
                tostring(field) ..
                ". Falling back to an empty table."
            )

            data[field] =
                {}

        end

    end

    --------------------------------------------------------
    -- SCHEMA VERSION
    --------------------------------------------------------
    --
    -- schemaVersion is a bare number, not a table, so it has no
    -- ModData tag of its own -- it rides inside the "metadata"
    -- tag instead. Pull it onto the container root here so every
    -- existing data.schemaVersion reader/writer elsewhere keeps
    -- working unchanged; saveKIPNData() pushes it back before
    -- transmitting "metadata".
    --------------------------------------------------------

    data.schemaVersion =
        data.metadata
        and data.metadata.schemaVersion

    --------------------------------------------------------
    -- SCHEMA MIGRATION (with rollback)
    --------------------------------------------------------
    --
    -- Runs before ensureSchema()/the structural migrations below so a
    -- versioned data transform sees the save exactly as it was written
    -- by the older build. Backs up every tag first; on failure it
    -- restores and leaves data.schemaVersion at the old value so the
    -- rest of load + the server run normally on the old schema.
    --------------------------------------------------------

    pcall(maybeMigrateSchema, data)

    --------------------------------------------------------
    -- ENSURE SCHEMA
    --------------------------------------------------------
    --
    -- pcall-guarded: a throw here (e.g. from an unexpected data shape)
    -- must not stop the server booting. On failure we fall back to the
    -- pre-ensure `data`, which is still a table of loaded tags -- the
    -- sanitize + per-service guards below then keep it usable.
    --------------------------------------------------------

    local okEnsure, ensuredData =
        pcall(ensureSchema, data)

    if not okEnsure then

        logError(
            "ensureSchema() threw (" .. tostring(ensuredData) ..
            "); continuing with unnormalized data."
        )

        ensuredData = data
    end

    if type(ensuredData) ~= "table" then

        logError(
            "ensureSchema() did not return a valid table; " ..
            "continuing with raw loaded data."
        )

        ensuredData = data
    end

    KIPN.Server.Data =
        ensuredData

    --------------------------------------------------------
    -- SANITIZE RECORD MAPS (corrupt-row resilience)
    --------------------------------------------------------

    pcall(sanitizeRecordMaps, KIPN.Server.Data)

    --------------------------------------------------------
    -- CREATED TIMESTAMP
    --------------------------------------------------------
    --
    -- Set only the first time metadata is ever created (its
    -- backing tag starts empty), so this fires once per server.
    --------------------------------------------------------

    if KIPN.Server.Data.metadata.createdAt == nil
        and getGameTime
    then

        local okTime,
            worldHours =
            pcall(
                function()

                    return getGameTime()
                        :getWorldAgeHours()
                end
            )

        if okTime then

            KIPN.Server.Data.metadata.createdAt =
                tostring(worldHours)

        end
    end

    --------------------------------------------------------
    -- EXISTING COMPUTER MIGRATION
    --------------------------------------------------------

    local okCompMig, migrationOk =
        pcall(
            migrateExistingComputerRecords,
            KIPN.Server.Data,
            CURRENT_SCHEMA_VERSION
        )

    if not okCompMig then

        logError(
            "Existing computer record migration threw (" ..
            tostring(migrationOk) .. "); continuing."
        )

        migrationOk = true
    end

    if not migrationOk then

        logError(
            "Existing computer record migration failed."
        )


        return KIPN.Server.Data
    end

    --------------------------------------------------------
    -- LAST LOADED WORLD TIME
    --------------------------------------------------------

    if getGameTime then

        local okTime,
            worldHours =
            pcall(
                function()

                    return getGameTime()
                        :getWorldAgeHours()
                end
            )

        if okTime then

            KIPN.Server.Data.metadata.lastLoadedAt =
                tostring(worldHours)

        else

        end
    end

    --------------------------------------------------------
    -- LEGACY POWER DATA
    --------------------------------------------------------

    local okLegacy, legacyMigrationOk =
        pcall(migrateLegacyPowerData)

    if not okLegacy then

        logError(
            "Legacy power data migration threw (" ..
            tostring(legacyMigrationOk) .. "); continuing."
        )

    elseif not legacyMigrationOk then

        logError(
            "Legacy power data migration reported failure."
        )
    end

    --------------------------------------------------------
    -- LOAD COMPLETE
    --------------------------------------------------------



    return KIPN.Server.Data
end

------------------------------------------------------------
-- PERSISTENT DATA SAVING
------------------------------------------------------------
--
-- ModData is authoritative.
--
-- JSON export is diagnostic only.
------------------------------------------------------------

saveKIPNData = function(domain)



    --------------------------------------------------------
    -- VALIDATE DATA
    --------------------------------------------------------

    if type(
        KIPN.Server.Data
    ) ~= "table"
    then

        logError(
            "Cannot save KIPN data: " ..
            "data object does not exist."
        )


        return false
    end

    --------------------------------------------------------
    -- ENSURE METADATA
    --------------------------------------------------------

    if type(
        KIPN.Server.Data.metadata
    ) ~= "table"
    then

        KIPN.Server.Data.metadata =
            {}

    end

    --------------------------------------------------------
    -- SCHEMA VERSION
    --------------------------------------------------------
    --
    -- Push the root-level scalar back into the "metadata" tag
    -- so it's actually persisted -- see the matching pull in
    -- loadKIPNData().
    --------------------------------------------------------

    KIPN.Server.Data.metadata.schemaVersion =
        KIPN.Server.Data.schemaVersion

    --------------------------------------------------------
    -- LAST SAVED WORLD TIME
    --------------------------------------------------------

    if getGameTime then

        local okTime,
            worldHours =
            pcall(
                function()

                    return getGameTime()
                        :getWorldAgeHours()
                end
            )

        if okTime then

            KIPN.Server.Data.metadata.lastSavedAt =
                tostring(worldHours)

        else


            KIPN.Server.Data.metadata.lastSavedAt =
                nil
        end

    else


        KIPN.Server.Data.metadata.lastSavedAt =
            nil
    end

    --------------------------------------------------------
    -- AUTHORITATIVE MODDATA TRANSMISSION
    --------------------------------------------------------
    --
    -- initServer() normally runs from OnInitGlobalModData. At that
    -- point the persistent table is ready, but GameServer.udpEngine
    -- is not. ModData.transmit() attempts to enumerate connections
    -- and throws from inside the engine even though there cannot be
    -- any clients to receive the update yet.
    --
    -- Mutations made here are already applied to the authoritative
    -- ModData table and will be serialized by the normal world-save
    -- path. Defer only the network transmission while the server
    -- orchestrator is initializing; every later Save() retains the
    -- existing immediate-transmit behavior.
    --
    -- If the caller named a domain (one of SUBSYSTEM_TAGS' keys),
    -- only that subsystem's tag is transmitted -- an unrelated
    -- mutation (e.g. a claim change) no longer re-broadcasts the
    -- computers/accounts/stats/... tables to every client. Callers
    -- that don't name a domain get the previous behavior: every
    -- subsystem tag is transmitted, so untouched call sites keep
    -- working exactly as before.
    --------------------------------------------------------

    if not KIPN.Server._initializing then

        local tagsToTransmit =
            {}

        if domain
            and SUBSYSTEM_TAGS[domain]
        then

            tagsToTransmit[1] =
                SUBSYSTEM_TAGS[domain]

        else

            for _, field in ipairs(SUBSYSTEM_FIELDS) do

                tagsToTransmit[#tagsToTransmit + 1] =
                    SUBSYSTEM_TAGS[field]

            end

        end

        for _, tag in ipairs(tagsToTransmit) do

            local okTransmit,
                transmitError =
                pcall(
                    ModData.transmit,
                    tag
                )

            if not okTransmit then

                logError(
                    "ModData.transmit failed for tag=" ..
                    tostring(tag) ..
                    ": " ..
                    tostring(transmitError)
                )


                return false
            end

        end
    end


    --------------------------------------------------------
    -- JSON DIAGNOSTIC EXPORT
    --------------------------------------------------------
    --
    -- This is intentionally non-authoritative.
    --
    -- A JSON export failure must NEVER cause a successful
    -- ModData save to be reported as failed.
    --------------------------------------------------------

    if KIPN.Json
        and type(
            KIPN.Json.WriteFile
        ) == "function"
        and diagnosticJsonExportAllowed()
    then

        local jsonOk,
            jsonResult =
            pcall(
                KIPN.Json.WriteFile,
                "kipn_data.json",
                KIPN.Server.Data
            )

        if jsonOk
            and jsonResult
        then

            logger:Debug(
                "Diagnostic JSON snapshot written (" ..
                tostring(KIPN.Json.DiskName("kipn_data.json")) .. ")."
            )

        elseif not jsonOk then

            logWarn(
                "Diagnostic JSON snapshot errored: " ..
                tostring(jsonResult)
            )

        else

            logger:Debug(
                "Diagnostic JSON snapshot not written this pass."
            )

        end

    end

    --------------------------------------------------------
    -- POST-MIGRATION BACKUP CLEANUP
    --------------------------------------------------------
    --
    -- A successful schema migration hands its pre-migration backup
    -- tag list to us. Now that the migrated data has been persisted
    -- at least once, the backups are no longer needed.
    --------------------------------------------------------

    if type(KIPN.Server._migrationBackupTags) == "table" then

        local bakList = KIPN.Server._migrationBackupTags
        KIPN.Server._migrationBackupTags = nil

        pcall(emptyBackupTags, bakList)

        logInfo(
            "Post-migration backup tags cleared (" ..
            tostring(#bakList) .. ")."
        )
    end

    --------------------------------------------------------
    -- SAVE COMPLETE
    --------------------------------------------------------



    return true
end

------------------------------------------------------------
-- PUBLIC DATA ACCESS
------------------------------------------------------------

function KIPN.Server.GetData()



    --------------------------------------------------------
    -- LOAD DATA IF NOT CURRENTLY AVAILABLE
    --------------------------------------------------------

    if type(
        KIPN.Server.Data
    ) ~= "table"
    then


        local loadedData =
            loadKIPNData()

        if type(loadedData) ~= "table" then

            logError(
                "GetData() failed: " ..
                "loadKIPNData() did not return valid data."
            )


            return nil
        end
    end

    --------------------------------------------------------
    -- BASIC STRUCTURE VALIDATION
    --------------------------------------------------------
    --
    -- Do not rebuild the entire schema here.
    --
    -- ensureSchema() belongs to the persistent-data loading
    -- path and is responsible for structural repair.
    --------------------------------------------------------

    if type(
        KIPN.Server.Data.computers
    ) ~= "table"
    then


        local loadedData =
            loadKIPNData()

        if type(loadedData) ~= "table"
            or type(
                loadedData.computers
            ) ~= "table"
        then

            logError(
                "GetData() failed: " ..
                "persistent KIPN data remains invalid " ..
                "after reload."
            )


            return nil
        end
    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------



    return KIPN.Server.Data
end

------------------------------------------------------------
-- PUBLIC SAVE
------------------------------------------------------------

function KIPN.Server.Save(domain)



    local result =
        saveKIPNData(domain)


    return result
end

------------------------------------------------------------
-- ITEM FACTORY
------------------------------------------------------------
--
-- Build 42 no longer exposes InventoryItemFactory to the Lua VM;
-- the vanilla global for creating a detached InventoryItem is
-- instanceItem(fullType). This wrapper is the single server-side
-- entry point so a missing/renamed engine API degrades to a clean
-- nil instead of an uncaught "attempted index of nil" that would
-- unwind a command handler mid-transaction.
--
-- Returns the new InventoryItem, or nil (never raises).
------------------------------------------------------------

function KIPN.Server.CreateItem(fullType)

    if type(fullType) ~= "string" or fullType == "" then
        return nil
    end

    local ok, item = pcall(function()
        if type(instanceItem) == "function" then
            return instanceItem(fullType)
        end

        -- Legacy fallback for any build that still exposes the
        -- Build 41 factory.
        if type(InventoryItemFactory) == "table"
            and type(InventoryItemFactory.CreateItem) == "function"
        then
            return InventoryItemFactory.CreateItem(fullType)
        end

        return nil
    end)

    if not ok then
        return nil
    end

    return item
end

------------------------------------------------------------
-- COMPUTER REGISTRY
------------------------------------------------------------

function KIPN.Server.GetComputer(
    computerId
)



    --------------------------------------------------------
    -- VALIDATE COMPUTER ID
    --------------------------------------------------------

    if computerId == nil
        or computerId == ""
    then

        logError(
            "GetComputer failed: invalid computerId."
        )


        return nil
    end

    --------------------------------------------------------
    -- GET PERSISTENT DATA
    --------------------------------------------------------

    local data =
        KIPN.Server.GetData()

    if type(data) ~= "table" then

        logError(
            "GetComputer failed: " ..
            "KIPN server data unavailable. " ..
            "computerId=" ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- VALIDATE COMPUTER REGISTRY
    --------------------------------------------------------

    if type(
        data.computers
    ) ~= "table"
    then

        logError(
            "GetComputer failed: " ..
            "computer registry unavailable. " ..
            "computerId=" ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- LOOK UP COMPUTER
    --------------------------------------------------------

    local computer =
        data.computers[
            computerId
        ]

    if type(computer) ~= "table" then



        return nil
    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------



    return computer
end

------------------------------------------------------------
-- GET OR CREATE COMPUTER
------------------------------------------------------------

function KIPN.Server.GetOrCreateComputer(
    computerId
)



    if not computerId then

        logError(
            "GetOrCreateComputer failed: " ..
            "computerId is nil."
        )


        return nil
    end

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "GetOrCreateComputer failed: " ..
            "KIPN server data unavailable. " ..
            "computerId=" ..
            tostring(computerId)
        )


        return nil
    end

    if type(data.computers) ~=
        "table"
    then


        data.computers =
            {}

    end

    local dataChanged =
        false

    --------------------------------------------------------
    -- CREATE NEW COMPUTER RECORD
    --------------------------------------------------------

    if not data.computers[
        computerId
    ]
    then

        local worldAgeHours =
            nil

        if type(getGameTime) ==
            "function"
        then

            local okTime,
                gameTime =
                pcall(
                    getGameTime
                )

            if okTime
                and gameTime
                and type(
                    gameTime.getWorldAgeHours
                ) == "function"
            then

                local okWorldAge,
                    worldAgeResult =
                    pcall(
                        function()

                            return gameTime
                                :getWorldAgeHours()
                        end
                    )

                if okWorldAge then

                    worldAgeHours =
                        worldAgeResult

                else

                end
            end
        end

        data.computers[
            computerId
        ] = {

            id =
                computerId,

            power =
                false,

            -- Discovery (CHECK_POWER) must not start the first boot.
            -- Wait for SET_POWER so the OFF -> BOOTING transition
            -- and its startup sound happen together. SET_POWER clears
            -- this flag, allowing normal power-outage recovery later.
            manualOff =
                true,

            baudRate =
                DEFAULT_BAUD_RATE,

            bootState =
                KIPN.Shared.BootStates.OFF,

            bootStartedAtMs =
                nil,

            bootDurationMs =
                calculateBootDurationMs(
                    DEFAULT_BAUD_RATE
                ),

            bootDiagnostics =
                {},

            locationKey =
                computerId,

            registeredAtWorldHours =
                worldAgeHours,

            capabilities =
                {},
        }

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- VALIDATE COMPUTER RECORD
    --------------------------------------------------------

    local computer =
        data.computers[
            computerId
        ]

    if type(computer) ~=
        "table"
    then

        logError(
            "GetOrCreateComputer failed: existing " ..
            "computer record is not a table. " ..
            "computerId=" ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- ID
    --------------------------------------------------------

    if computer.id == nil then

        computer.id =
            computerId

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- POWER
    --------------------------------------------------------

    if computer.power == nil then

        computer.power =
            false

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- MANUAL OVERRIDE
    --
    -- New records start with this flag set until their first explicit
    -- SET_POWER request. It also marks a player's deliberate power-off,
    -- preventing CHECK_POWER from starting the computer merely because
    -- the building has electricity. Preserve the previous default for
    -- legacy records whose manual state was never recorded.
    --------------------------------------------------------

    if computer.manualOff == nil then

        computer.manualOff =
            false

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- LOCATION
    --------------------------------------------------------

    if computer.locationKey ==
        nil
    then

        computer.locationKey =
            computerId

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- BAUD RATE
    --------------------------------------------------------

    local originalBaudRate =
        computer.baudRate

    if computer.baudRate ==
        nil
    then

        computer.baudRate =
            DEFAULT_BAUD_RATE

        dataChanged =
            true

    end

    local normalizedBaudRate =
        normalizeBaudRate(
            computer.baudRate
        )

    if computer.baudRate ~=
        normalizedBaudRate
    then

        computer.baudRate =
            normalizedBaudRate

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- BOOT STATE
    --------------------------------------------------------

    if computer.bootState ==
        nil
    then

        if computer.power == true then

            computer.bootState =
                KIPN.Shared.BootStates.BOOTING

        else

            computer.bootState =
                KIPN.Shared.BootStates.OFF

        end

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- BOOT START TIME
    --------------------------------------------------------
    --
    -- A powered computer in BOOTING state must have a valid
    -- boot start timestamp. This is required to calculate
    -- remaining boot time.
    --------------------------------------------------------

    if computer.bootState ==
        KIPN.Shared.BootStates.BOOTING
        and computer.bootStartedAtMs ==
            nil
    then

        local timestamp =
            0

        if type(getTimestampMs) ==
            "function"
        then

            local okTimestamp,
                timestampResult =
                pcall(
                    getTimestampMs
                )

            if okTimestamp
                and timestampResult ~= nil
            then

                timestamp =
                    timestampResult
            end
        end

        computer.bootStartedAtMs =
            timestamp

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- CLEAR BOOT START TIME WHEN OFF
    --------------------------------------------------------

    if computer.power ~= true
        and computer.bootState ==
            KIPN.Shared.BootStates.OFF
        and computer.bootStartedAtMs ~=
            nil
    then

        computer.bootStartedAtMs =
            nil

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- BOOT DURATION
    --------------------------------------------------------

    if computer.bootDurationMs ==
        nil
    then

        computer.bootDurationMs =
            calculateBootDurationMs(
                computer.baudRate
            )

        dataChanged =
            true


    else

        local originalBootDuration =
            computer.bootDurationMs

        local normalizedBootDuration =
            tonumber(
                computer.bootDurationMs
            )

        if not normalizedBootDuration then

            normalizedBootDuration =
                calculateBootDurationMs(
                    computer.baudRate
                )

        else

            normalizedBootDuration =
                math.floor(
                    normalizedBootDuration
                )

            if normalizedBootDuration <
                MIN_BOOT_DURATION_MS
            then

                normalizedBootDuration =
                    MIN_BOOT_DURATION_MS

            elseif normalizedBootDuration >
                MAX_BOOT_DURATION_MS
            then

                normalizedBootDuration =
                    MAX_BOOT_DURATION_MS
            end
        end

        if originalBootDuration ~=
            normalizedBootDuration
        then

            computer.bootDurationMs =
                normalizedBootDuration

            dataChanged =
                true

        end
    end

    --------------------------------------------------------
    -- BOOT DIAGNOSTICS
    --------------------------------------------------------

    if type(
        computer.bootDiagnostics
    ) ~= "table"
    then

        computer.bootDiagnostics =
            {}

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- CAPABILITIES
    --------------------------------------------------------

    if type(
        computer.capabilities
    ) ~= "table"
    then

        computer.capabilities =
            {}

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- REGISTERED WORLD TIME
    --------------------------------------------------------

    if computer.registeredAtWorldHours ==
        nil
    then

        if type(getGameTime) ==
            "function"
        then

            local okTime,
                gameTime =
                pcall(
                    getGameTime
                )

            if okTime
                and gameTime
                and type(
                    gameTime.getWorldAgeHours
                ) == "function"
            then

                local okWorldAge,
                    worldAgeResult =
                    pcall(
                        function()

                            return gameTime
                                :getWorldAgeHours()
                        end
                    )

                if okWorldAge then

                    computer.registeredAtWorldHours =
                        worldAgeResult

                    dataChanged =
                        true

                end
            end
        end
    end

    --------------------------------------------------------
    -- HARDWARE CONDITION PROFILE
    --------------------------------------------------------

    local _profile,
        profileLinkChanged =
        getComputerProfile(
            computerId,
            computer,
            data
        )

    if profileLinkChanged then

        dataChanged =
            true

    end

    --------------------------------------------------------
    -- PERSIST ONLY IF STATE CHANGED
    --------------------------------------------------------

    local saveOk =
        true

    if dataChanged then

        saveOk =
            saveKIPNData()

        if not saveOk then

            logError(
                "GetOrCreateComputer changed persistent state " ..
                "but saveKIPNData() failed. " ..
                "computerId=" ..
                tostring(computerId)
            )
        end
    end

    --------------------------------------------------------
    -- FINAL RESULT
    --------------------------------------------------------



    return computer
end

------------------------------------------------------------
-- COMPUTER CONDITION PROFILE (PUBLIC ACCESSOR)
------------------------------------------------------------
--
-- Returns the Computer Condition profile table for a computer
-- (condition, useCount, useDegradationRemainder,
-- lastConditionCheckWorldHours), creating/linking it if necessary
-- via GetOrCreateComputer(). Callers may mutate the returned table
-- directly (it is the same table stored in
-- data.computerProfiles[...]) but MUST call saveKIPNData()
-- themselves afterward to persist changes.
------------------------------------------------------------

function KIPN.Server.GetComputerProfile(
    computerId
)

    if not computerId then

        return nil
    end

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        return nil
    end

    local data =
        KIPN.Server.GetData()

    if not data
        or type(data.computerProfiles) ~= "table"
    then

        return nil
    end

    return data.computerProfiles[
        computer.hardwareProfileId
    ]
end

------------------------------------------------------------
-- COMPUTER POWER
------------------------------------------------------------

function KIPN.Server.GetComputerPower(
    computerId
)



    if not computerId then

        logError(
            "GetComputerPower failed: computerId is nil."
        )


        return false
    end

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerPower failed: computer not found: " ..
            tostring(computerId)
        )


        return false
    end

    local result =
        computer.power == true



    return result
end

------------------------------------------------------------
-- COMPUTER BOOT DURATION
------------------------------------------------------------

function KIPN.Server.GetComputerBootDurationMs(
    computerId
)



    if not computerId then

        logError(
            "GetComputerBootDurationMs failed: " ..
            "computerId is nil."
        )


        return nil
    end

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerBootDurationMs: computer not found: " ..
            tostring(computerId)
        )


        return nil
    end

    local duration =
        tonumber(
            computer.bootDurationMs
        )

    --------------------------------------------------------
    -- REPAIR MISSING / INVALID DURATION
    --------------------------------------------------------

    if not duration then

        local baudRate =
            normalizeBaudRate(
                computer.baudRate
                or DEFAULT_BAUD_RATE
            )

        duration =
            calculateBootDurationMs(
                baudRate
            )

        computer.baudRate =
            baudRate

        computer.bootDurationMs =
            duration


        local saved =
            saveKIPNData()

        if not saved then

            logError(
                "GetComputerBootDurationMs: failed to persist " ..
                "repaired boot duration for computer " ..
                tostring(computerId)
            )


            return nil
        end
    end

    --------------------------------------------------------
    -- NORMALIZE EXISTING DURATION
    --------------------------------------------------------

    local normalizedDuration =
        math.floor(
            duration
        )

    if normalizedDuration <
        MIN_BOOT_DURATION_MS
    then

        normalizedDuration =
            MIN_BOOT_DURATION_MS

    elseif normalizedDuration >
        MAX_BOOT_DURATION_MS
    then

        normalizedDuration =
            MAX_BOOT_DURATION_MS
    end

    if duration ~=
        normalizedDuration
    then

        computer.bootDurationMs =
            normalizedDuration

        duration =
            normalizedDuration


        local saved =
            saveKIPNData()

        if not saved then

            logError(
                "GetComputerBootDurationMs: failed to persist " ..
                "normalized boot duration for computer " ..
                tostring(computerId)
            )


            return nil
        end

    else

        duration =
            normalizedDuration
    end



    return duration
end

------------------------------------------------------------
-- COMPUTER BOOT STATE
------------------------------------------------------------

function KIPN.Server.GetComputerBootState(
    computerId
)



    if not computerId then

        logError(
            "GetComputerBootState failed: computerId is nil."
        )


        return KIPN.Shared.BootStates.OFF
    end

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerBootState failed: computer not found: " ..
            tostring(computerId)
        )


        return KIPN.Shared.BootStates.OFF
    end

    --------------------------------------------------------
    -- POWERED OFF
    --------------------------------------------------------

    if computer.power ~= true then

        if computer.bootState ~=
            KIPN.Shared.BootStates.OFF
        then


            computer.bootState =
                KIPN.Shared.BootStates.OFF

            computer.bootStartedAtMs =
                nil

            saveKIPNData("computers")
        end


        return KIPN.Shared.BootStates.OFF
    end

    --------------------------------------------------------
    -- POWERED ON / ON
    --------------------------------------------------------

    if computer.bootState ==
        KIPN.Shared.BootStates.ON
    then


        return computer.bootState
    end

    --------------------------------------------------------
    -- POWERED ON / BOOTING
    --------------------------------------------------------

    if computer.bootState ==
        KIPN.Shared.BootStates.BOOTING
    then

        local dataChanged =
            false

        ----------------------------------------------------
        -- BOOT START TIME
        ----------------------------------------------------

        local bootStartedAtMs =
            tonumber(
                computer.bootStartedAtMs
            )

        if not bootStartedAtMs then

            logError(
                "Computer " ..
                tostring(computerId) ..
                " is BOOTING without bootStartedAtMs. " ..
                "Repairing boot timestamp."
            )

            if type(getTimestampMs) ==
                "function"
            then

                local okTimestamp,
                    timestampResult =
                    pcall(
                        getTimestampMs
                    )

                if okTimestamp
                    and timestampResult ~= nil
                then

                    bootStartedAtMs =
                        tonumber(
                            timestampResult
                        )
                end
            end

            if not bootStartedAtMs then

                logError(
                    "Unable to establish boot timestamp for " ..
                    "computer " ..
                    tostring(computerId) ..
                    "."
                )


                return KIPN.Shared.BootStates.BOOTING
            end

            computer.bootStartedAtMs =
                bootStartedAtMs

            dataChanged =
                true
        end

        ----------------------------------------------------
        -- BOOT DURATION
        ----------------------------------------------------

        local bootDurationMs =
            tonumber(
                computer.bootDurationMs
            )

        if not bootDurationMs then


            bootDurationMs =
                calculateBootDurationMs(
                    computer.baudRate
                    or DEFAULT_BAUD_RATE
                )

            computer.bootDurationMs =
                bootDurationMs

            dataChanged =
                true

        else

            bootDurationMs =
                math.floor(
                    bootDurationMs
                )

            if bootDurationMs <
                MIN_BOOT_DURATION_MS
            then

                bootDurationMs =
                    MIN_BOOT_DURATION_MS

                computer.bootDurationMs =
                    bootDurationMs

                dataChanged =
                    true

            elseif bootDurationMs >
                MAX_BOOT_DURATION_MS
            then

                bootDurationMs =
                    MAX_BOOT_DURATION_MS

                computer.bootDurationMs =
                    bootDurationMs

                dataChanged =
                    true
            end
        end

        ----------------------------------------------------
        -- CURRENT TIME
        ----------------------------------------------------

        local now =
            nil

        if type(getTimestampMs) ==
            "function"
        then

            local okTimestamp,
                timestampResult =
                pcall(
                    getTimestampMs
                )

            if okTimestamp then

                now =
                    tonumber(
                        timestampResult
                    )
            end
        end

        if not now then

            logError(
                "Unable to obtain current timestamp while " ..
                "checking boot state for computer " ..
                tostring(computerId)
            )

            if dataChanged then

                saveKIPNData("computers")
            end


            return KIPN.Shared.BootStates.BOOTING
        end

        ----------------------------------------------------
        -- ELAPSED TIME
        ----------------------------------------------------

        local elapsed =
            now -
            bootStartedAtMs

        if elapsed < 0 then


            elapsed =
                0
        end

        ----------------------------------------------------
        -- BOOT COMPLETE
        ----------------------------------------------------

        if elapsed >=
            bootDurationMs
        then


            computer.bootState =
                KIPN.Shared.BootStates.ON

            computer.bootStartedAtMs =
                nil

            dataChanged =
                true

        end

        ----------------------------------------------------
        -- PERSIST STATE CHANGES
        ----------------------------------------------------

        if dataChanged then

            local saved =
                saveKIPNData("computers")

            if not saved then

                logError(
                    "Failed to persist boot state changes for " ..
                    "computer " ..
                    tostring(computerId)
                )


                if computer.bootState ==
                    KIPN.Shared.BootStates.ON
                then

                    return KIPN.Shared.BootStates.ON
                end

                return KIPN.Shared.BootStates.BOOTING
            end
        end

        ----------------------------------------------------
        -- RETURN CURRENT STATE
        ----------------------------------------------------


        return computer.bootState
    end

    --------------------------------------------------------
    -- INVALID STATE
    --------------------------------------------------------

    logError(
        "Computer " ..
        tostring(computerId) ..
        " is powered on with invalid boot state: " ..
        tostring(computer.bootState)
    )

    --------------------------------------------------------
    -- IMPORTANT:
    --
    -- Do NOT claim the machine is OFF.
    --
    -- The server knows it is powered but the boot state is
    -- corrupt/unknown. Return nil so callers cannot mistake
    -- the condition for a legitimate OFF state.
    --------------------------------------------------------


    return nil
end

------------------------------------------------------------
-- COMPUTER BOOT INFORMATION
------------------------------------------------------------

function KIPN.Server.GetComputerBootInfo(
    computerId
)



    if not computerId then

        logError(
            "GetComputerBootInfo rejected: " ..
            "computerId is nil."
        )


        return nil
    end

    --------------------------------------------------------
    -- INITIAL COMPUTER LOOKUP
    --------------------------------------------------------

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerBootInfo failed: computer not found: " ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- RECONCILE BOOT STATE
    --------------------------------------------------------
    --
    -- GetComputerBootState() may:
    --
    --   * transition BOOTING -> ON
    --   * repair a missing boot timestamp
    --   * repair a missing boot duration
    --   * normalize an OFF state
    --
    -- Therefore the computer record is re-fetched afterward.
    --------------------------------------------------------

    local bootState =
        KIPN.Server.GetComputerBootState(
            computerId
        )

    if not bootState then

        logError(
            "GetComputerBootInfo failed: invalid boot state for " ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- RE-FETCH AFTER POSSIBLE STATE TRANSITION
    --------------------------------------------------------

    computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerBootInfo failed after boot-state " ..
            "reconciliation for computer " ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- BAUD RATE
    --------------------------------------------------------

    local baudRate =
        KIPN.Server.GetComputerBaudRate(
            computerId
        )

    if not baudRate then

        baudRate =
            normalizeBaudRate(
                computer.baudRate
                or DEFAULT_BAUD_RATE
            )

    end

    --------------------------------------------------------
    -- BOOT DURATION
    --------------------------------------------------------
    --
    -- Use the public accessor so missing/invalid persisted
    -- duration values are repaired consistently.
    --------------------------------------------------------

    local bootDurationMs =
        KIPN.Server.GetComputerBootDurationMs(
            computerId
        )

    if not bootDurationMs then

        logError(
            "GetComputerBootInfo failed: unable to resolve boot " ..
            "duration for computer " ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- RE-FETCH AFTER POSSIBLE DURATION REPAIR
    --------------------------------------------------------

    computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "GetComputerBootInfo failed after boot-duration " ..
            "resolution for computer " ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- BOOT TIMING
    --------------------------------------------------------

    local bootStartedAtMs =
        tonumber(
            computer.bootStartedAtMs
        )

    local bootRemainingMs =
        0

    if bootState ==
        KIPN.Shared.BootStates.BOOTING
    then

        ----------------------------------------------------
        -- CURRENT TIMESTAMP
        ----------------------------------------------------

        local now =
            nil

        if type(getTimestampMs) ==
            "function"
        then

            local okTimestamp,
                timestampResult =
                pcall(
                    getTimestampMs
                )

            if okTimestamp then

                now =
                    tonumber(
                        timestampResult
                    )
            else

                logError(
                    "GetComputerBootInfo: getTimestampMs() failed: " ..
                    tostring(timestampResult)
                )
            end
        end

        ----------------------------------------------------
        -- CALCULATE REMAINING TIME
        ----------------------------------------------------

        if now
            and bootStartedAtMs
        then

            local elapsed =
                now -
                bootStartedAtMs

            if elapsed < 0 then


                elapsed =
                    0
            end

            bootRemainingMs =
                bootDurationMs -
                elapsed

            if bootRemainingMs < 0 then

                bootRemainingMs =
                    0
            end

        elseif not bootStartedAtMs then

            logError(
                "GetComputerBootInfo: computer " ..
                tostring(computerId) ..
                " is BOOTING without bootStartedAtMs."
            )

        else

            logError(
                "GetComputerBootInfo: unable to determine current " ..
                "timestamp for computer " ..
                tostring(computerId)
            )
        end
    end

    --------------------------------------------------------
    -- DIAGNOSTICS
    --------------------------------------------------------

    local bootDiagnostics =
        computer.bootDiagnostics

    if type(bootDiagnostics) ~=
        "table"
    then

        bootDiagnostics =
            {}
    end

    --------------------------------------------------------
    -- BUILD PUBLIC BOOT INFORMATION
    --------------------------------------------------------

    local info = {

        computerId =
            computerId,

        powered =
            computer.power == true,

        bootState =
            bootState,

        baudRate =
            baudRate,

        bootStartedAtMs =
            bootStartedAtMs,

        bootDurationMs =
            bootDurationMs,

        bootRemainingMs =
            bootRemainingMs,

        bootDiagnostics =
            bootDiagnostics,
    }

    --------------------------------------------------------
    -- LOG RESULT
    --------------------------------------------------------



    return info
end

------------------------------------------------------------
-- COMPUTER POWER / BOOT TRANSITION
------------------------------------------------------------
--
-- This function controls the KIPN computer's logical power
-- state and boot lifecycle.
--
-- IMPORTANT:
--
-- computer.power represents the computer's own power state.
--
-- Building electrical availability is determined separately
-- by:
--
--     KIPN.Server.CheckBuildingPower()
--
-- Therefore:
--
--   buildingPower == true
--       allows the computer to power on.
--
--   computer.power == true
--       means the computer is logically powered on.
--
-- These are intentionally separate concepts.
------------------------------------------------------------

function KIPN.Server.SetComputerPower(
    computerId,
    isOn
)



    --------------------------------------------------------
    -- VALIDATE ARGUMENTS
    --------------------------------------------------------

    if computerId == nil
        or isOn == nil
    then

        logError(
            "SetComputerPower failed: invalid arguments. " ..
            "computerId=" ..
            tostring(computerId) ..
            " isOn=" ..
            tostring(isOn)
        )


        return false
    end

    computerId =
        tostring(computerId)

    local requestedPower =
        isOn == true

    --------------------------------------------------------
    -- RESOLVE COMPUTER
    --------------------------------------------------------

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        logError(
            "SetComputerPower failed: unable to resolve " ..
            "computer " ..
            computerId
        )


        return false
    end

    --------------------------------------------------------
    -- POWERING ON
    --------------------------------------------------------

    if requestedPower then

        ----------------------------------------------------
        -- ALREADY FULLY ON
        ----------------------------------------------------
        --
        -- Do this before checking building power.
        --
        -- An already-running computer does not need to be
        -- "powered on" again.
        ----------------------------------------------------

        if computer.power == true
            and computer.bootState ==
                KIPN.Shared.BootStates.ON
        then



            return true
        end

        ----------------------------------------------------
        -- ALREADY BOOTING
        ----------------------------------------------------
        --
        -- Never restart the boot timer when a second power-on
        -- request arrives while the machine is already booting.
        ----------------------------------------------------

        if computer.power == true
            and computer.bootState ==
                KIPN.Shared.BootStates.BOOTING
        then



            return true
        end

        ----------------------------------------------------
        -- HARDWARE CONDITION GATE
        --
        -- Below CONDITION_POWER_OFF_REFUSAL_THRESHOLD, a
        -- computer refuses to power on at all, even with
        -- confirmed building electricity. This check is
        -- independent of, and precedes, CheckBuildingPower.
        ----------------------------------------------------

        local conditionProfile =
            KIPN.Server.GetComputerProfile(
                computerId
            )

        local currentCondition =
            (
                conditionProfile
                and conditionProfile.condition
            )
            or 100

        if currentCondition <
            CONDITION_POWER_OFF_REFUSAL_THRESHOLD
        then

            logInfo(
                "SetComputerPower refused: computer " ..
                computerId ..
                " condition too low (" ..
                tostring(currentCondition) ..
                "%)."
            )



            return false
        end

        ----------------------------------------------------
        -- AUTHORITATIVE BUILDING POWER CHECK
        ----------------------------------------------------
        --
        -- This checks the actual world square.
        --
        -- Do not use computer.power for this check.
        ----------------------------------------------------

        local squarePower =
            KIPN.Server.CheckBuildingPower(
                computerId
            )

        if squarePower == nil then

            logError(
                "SetComputerPower failed: unable to determine " ..
                "building electricity for computer " ..
                computerId
            )


            return false
        end

        if squarePower ~= true then


            ------------------------------------------------
            -- Ensure persisted state agrees with the fact
            -- that the computer cannot currently operate.
            ------------------------------------------------

            local stateChanged =
                false

            if computer.power ~= false then

                computer.power =
                    false

                stateChanged =
                    true
            end

            if computer.bootState ~=
                KIPN.Shared.BootStates.OFF
            then

                computer.bootState =
                    KIPN.Shared.BootStates.OFF

                stateChanged =
                    true
            end

            if computer.bootStartedAtMs ~=
                nil
            then

                computer.bootStartedAtMs =
                    nil

                stateChanged =
                    true
            end

            if type(
                computer.bootDiagnostics
            ) ~= "table"
                or #computer.bootDiagnostics > 0
            then

                computer.bootDiagnostics =
                    {}

                stateChanged =
                    true
            end

            ------------------------------------------------
            -- Preserve hardware configuration.
            ------------------------------------------------

            local normalizedBaud =
                normalizeBaudRate(
                    computer.baudRate
                    or DEFAULT_BAUD_RATE
                )

            if computer.baudRate ~=
                normalizedBaud
            then

                computer.baudRate =
                    normalizedBaud

                stateChanged =
                    true
            end

            local expectedDuration =
                calculateBootDurationMs(
                    normalizedBaud
                )

            if computer.bootDurationMs ~=
                expectedDuration
            then

                computer.bootDurationMs =
                    expectedDuration

                stateChanged =
                    true
            end

            ------------------------------------------------
            -- Persist only if the record actually changed.
            ------------------------------------------------

            if stateChanged then

                local saved =
                    saveKIPNData()

                if not saved then

                    logError(
                        "SetComputerPower failed to persist " ..
                        "power-off state after failed building " ..
                        "power check for computer " ..
                        computerId
                    )


                    return false
                end
            end


            return false
        end

        ----------------------------------------------------
        -- NORMALIZE HARDWARE CONFIGURATION
        ----------------------------------------------------

        computer.baudRate =
            normalizeBaudRate(
                computer.baudRate
                or DEFAULT_BAUD_RATE
            )

        computer.bootDurationMs =
            calculateBootDurationMs(
                computer.baudRate
            )

        ----------------------------------------------------
        -- RESOLVE BOOT START TIME
        ----------------------------------------------------

        local bootStartedAtMs =
            nil

        if type(getTimestampMs) ==
            "function"
        then

            local okTimestamp,
                timestampResult =
                pcall(
                    getTimestampMs
                )

            if okTimestamp then

                bootStartedAtMs =
                    tonumber(
                        timestampResult
                    )
            else

                logError(
                    "SetComputerPower failed: " ..
                    "getTimestampMs() raised an error: " ..
                    tostring(timestampResult)
                )
            end
        end

        if not bootStartedAtMs then

            logError(
                "SetComputerPower failed: unable to resolve " ..
                "boot start timestamp for computer " ..
                computerId
            )


            return false
        end

        ----------------------------------------------------
        -- START NEW BOOT
        ----------------------------------------------------

        computer.power =
            true

        computer.bootStartedAtMs =
            bootStartedAtMs

        computer.bootState =
            KIPN.Shared.BootStates.BOOTING

        computer.bootDiagnostics =
            {}

        ----------------------------------------------------
        -- USE COUNTING + USE-BASED DEGRADATION
        --
        -- One "use" = one newly-initiated boot. The two
        -- early-return paths above ("ALREADY FULLY ON" /
        -- "ALREADY BOOTING") both return before this point, so
        -- re-entrant power-on requests are never double-counted.
        ----------------------------------------------------

        if conditionProfile then

            conditionProfile.useCount =
                (conditionProfile.useCount or 0) + 1

            local useMultiplier =
                (
                    KIPN.Server.ComputerConfig
                    and KIPN.Server.ComputerConfig.ComputerConditionUseDegradationMultiplier
                    or 0
                ) / 10.0

            if useMultiplier > 0 then

                local degradationPer100Uses =
                    10 * useMultiplier

                local remainder =
                    (conditionProfile.useDegradationRemainder or 0) + 1

                while remainder >= 100 do

                    conditionProfile.condition =
                        math.max(
                            0,
                            (conditionProfile.condition or 100)
                                - degradationPer100Uses
                        )

                    remainder =
                        remainder - 100
                end

                conditionProfile.useDegradationRemainder =
                    remainder

            end

            saveKIPNData()
        end


        ----------------------------------------------------
        -- SERVER-SIDE BOOT DIAGNOSTICS
        ----------------------------------------------------
        --
        -- Diagnostics describe the boot process. They do not
        -- determine whether the computer is allowed to enter
        -- BOOTING.
        ----------------------------------------------------

        local diagnostics,
            diagnosticsOk =
            buildBootDiagnostics(
                computerId
            )

        if type(diagnostics) ==
            "table"
        then

            computer.bootDiagnostics =
                diagnostics

        else

            computer.bootDiagnostics =
                {}
        end

        if diagnosticsOk then


        else

        end

    --------------------------------------------------------
    -- POWERING OFF
    --------------------------------------------------------

    else

        ----------------------------------------------------
        -- Already OFF
        ----------------------------------------------------

        if computer.power ~= true
            and computer.bootState ==
                KIPN.Shared.BootStates.OFF
        then



            return true
        end

        ----------------------------------------------------
        -- POWER OFF
        ----------------------------------------------------

        computer.power =
            false

        computer.bootState =
            KIPN.Shared.BootStates.OFF

        computer.bootStartedAtMs =
            nil

        ----------------------------------------------------
        -- Preserve hardware configuration.
        --
        -- bootDurationMs is derived from baud rate and is
        -- configuration, not transient boot state.
        ----------------------------------------------------

        computer.baudRate =
            normalizeBaudRate(
                computer.baudRate
                or DEFAULT_BAUD_RATE
            )

        computer.bootDurationMs =
            calculateBootDurationMs(
                computer.baudRate
            )

        ----------------------------------------------------
        -- Clear transient diagnostics.
        ----------------------------------------------------

        computer.bootDiagnostics =
            {}

    end

    --------------------------------------------------------
    -- PERSIST STATE
    --------------------------------------------------------

    local saved =
        saveKIPNData()

    if saved then


    else

        logError(
            "SetComputerPower failed to persist state for " ..
            computerId
        )
    end


    return saved
end

------------------------------------------------------------
-- ACCOUNT FOUNDATION
------------------------------------------------------------

function KIPN.Server.GetAccount(
    accountId
)



    --------------------------------------------------------
    -- VALIDATE ACCOUNT ID
    --------------------------------------------------------

    if accountId == nil then

        logError(
            "GetAccount failed: accountId is nil."
        )


        return nil
    end

    accountId =
        tostring(accountId)

    --------------------------------------------------------
    -- LOAD AUTHORITATIVE DATA
    --------------------------------------------------------

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "GetAccount failed: KIPN server data unavailable."
        )


        return nil
    end

    if type(data.accounts) ~=
        "table"
    then

        logError(
            "GetAccount failed: account registry unavailable."
        )


        return nil
    end

    --------------------------------------------------------
    -- RESOLVE ACCOUNT
    --------------------------------------------------------

    local account =
        data.accounts[
            accountId
        ]

    if account then


    else

    end


    return account
end

------------------------------------------------------------
-- GET ACCOUNTS FOR STEAM ID
------------------------------------------------------------

function KIPN.Server.GetAccountsForSteamId(
    steamId
)



    --------------------------------------------------------
    -- VALIDATE STEAM ID
    --------------------------------------------------------

    if steamId == nil then

        logError(
            "GetAccountsForSteamId failed: steamId is nil."
        )


        return {}
    end

    steamId =
        tostring(steamId)

    --------------------------------------------------------
    -- LOAD AUTHORITATIVE DATA
    --------------------------------------------------------

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "GetAccountsForSteamId failed: " ..
            "KIPN server data unavailable."
        )


        return {}
    end

    if type(
        data.accountsBySteamId
    ) ~= "table"
    then

        logError(
            "GetAccountsForSteamId failed: " ..
            "accountsBySteamId registry unavailable."
        )


        return {}
    end

    --------------------------------------------------------
    -- RESOLVE ACCOUNT INDEX
    --------------------------------------------------------

    local storedAccountIds =
        data.accountsBySteamId[
            steamId
        ]

    if type(storedAccountIds) ~=
        "table"
    then



        return {}
    end

    --------------------------------------------------------
    -- RETURN COPY
    --------------------------------------------------------
    --
    -- Do not expose the authoritative index table itself.
    -- Callers receive a separate list they can safely inspect
    -- or modify without corrupting server state.
    --------------------------------------------------------

    local accountIds =
        {}

    for index,
        accountId in ipairs(
            storedAccountIds
        )
    do

        accountIds[index] =
            accountId
    end



    return accountIds
end

------------------------------------------------------------
-- GENERIC RECORD FOUNDATION
------------------------------------------------------------

function KIPN.Server.GetRecordCollection(
    collectionName
)



    --------------------------------------------------------
    -- VALIDATE COLLECTION NAME
    --------------------------------------------------------

    if collectionName == nil then

        logError(
            "GetRecordCollection failed: " ..
            "collectionName is nil."
        )


        return nil
    end

    collectionName =
        tostring(collectionName)

    if collectionName == "" then

        logError(
            "GetRecordCollection failed: " ..
            "collectionName is empty."
        )


        return nil
    end

    --------------------------------------------------------
    -- LOAD AUTHORITATIVE DATA
    --------------------------------------------------------

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "GetRecordCollection failed: " ..
            "KIPN server data unavailable."
        )


        return nil
    end

    --------------------------------------------------------
    -- ENSURE RECORD REGISTRY
    --------------------------------------------------------

    if type(data.records) ~=
        "table"
    then


        data.records =
            {}

        local saved =
            saveKIPNData()

        if not saved then

            logError(
                "GetRecordCollection failed: unable to persist " ..
                "new record registry."
            )


            return nil
        end
    end

    --------------------------------------------------------
    -- RESOLVE COLLECTION
    --------------------------------------------------------

    local collection =
        data.records[
            collectionName
        ]

    if type(collection) ~=
        "table"
    then

        collection =
            {}

        data.records[
            collectionName
        ] =
            collection


        local saved =
            saveKIPNData()

        if not saved then

            logError(
                "GetRecordCollection failed: unable to persist " ..
                "record collection " ..
                collectionName
            )


            return nil
        end
    end


    return collection
end

------------------------------------------------------------
-- CLAIM FOUNDATION
------------------------------------------------------------

function KIPN.Server.GetClaim(
    claimId
)



    --------------------------------------------------------
    -- VALIDATE CLAIM ID
    --------------------------------------------------------

    if claimId == nil then

        logError(
            "GetClaim failed: claimId is nil."
        )


        return nil
    end

    claimId =
        tostring(claimId)

    --------------------------------------------------------
    -- LOAD AUTHORITATIVE DATA
    --------------------------------------------------------

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "GetClaim failed: KIPN server data unavailable."
        )


        return nil
    end

    if type(data.claims) ~=
        "table"
    then

        logError(
            "GetClaim failed: claim registry unavailable."
        )


        return nil
    end

    --------------------------------------------------------
    -- RESOLVE CLAIM
    --------------------------------------------------------

    local claim =
        data.claims[
            claimId
        ]

    if claim then


    else

    end


    return claim
end

------------------------------------------------------------
-- VALIDATION KEY FOUNDATION
------------------------------------------------------------

function KIPN.Server.GetValidationKey(
    tokenId
)



    --------------------------------------------------------
    -- VALIDATE TOKEN ID
    --------------------------------------------------------

    if tokenId == nil then

        logError(
            "GetValidationKey failed: tokenId is nil."
        )


        return nil
    end

    tokenId =
        tostring(tokenId)

    --------------------------------------------------------
    -- LOAD AUTHORITATIVE DATA
    --------------------------------------------------------

    local data =
        KIPN.Server.GetData()

    if not data then

        logError(
            "GetValidationKey failed: " ..
            "KIPN server data unavailable."
        )


        return nil
    end

    if type(
        data.validationKeys
    ) ~= "table"
    then

        logError(
            "GetValidationKey failed: " ..
            "validation key registry unavailable."
        )


        return nil
    end

    --------------------------------------------------------
    -- RESOLVE VALIDATION KEY
    --------------------------------------------------------

    local token =
        data.validationKeys[
            tokenId
        ]

    if token then


    else

    end


    return token
end

------------------------------------------------------------
-- CLIENT RESPONSE
------------------------------------------------------------

function KIPN.Server.SendToPlayer(
    player,
    event,
    payload
)



    --------------------------------------------------------
    -- VALIDATE PLAYER
    --------------------------------------------------------

    if player == nil then

        logError(
            "SendToPlayer failed: player is nil."
        )


        return false
    end

    --------------------------------------------------------
    -- VALIDATE EVENT
    --------------------------------------------------------

    if event == nil then

        logError(
            "SendToPlayer failed: event is nil."
        )


        return false
    end

    event =
        tostring(event)

    if event == "" then

        logError(
            "SendToPlayer failed: event is empty."
        )


        return false
    end

    --------------------------------------------------------
    -- VALIDATE TRANSPORT
    --------------------------------------------------------

    if type(sendServerCommand) ~=
        "function"
    then

        logError(
            "SendToPlayer failed: " ..
            "sendServerCommand() unavailable."
        )


        return false
    end

    --------------------------------------------------------
    -- SEND RESPONSE
    --------------------------------------------------------

    local ok,
        err =
        pcall(
            function()

                sendServerCommand(
                    player,
                    "KIPN",
                    KIPN.Shared.Commands.SERVER_RESPONSE,
                    {
                        event = event,
                        data = payload
                    }
                )

            end
        )

    if not ok then

        logError(
            "SendToPlayer failed for event " ..
            event ..
            ": " ..
            tostring(err)
        )


        return false
    end



    return true
end

------------------------------------------------------------
-- BROADCAST TO ALL ONLINE PLAYERS
--
-- Same transport as SendToPlayer(), fanned out to every currently
-- connected player via getOnlinePlayers(). Used for state that is
-- world-wide/ambient rather than scoped to whoever asked for it -
-- see the COMPUTER_SOUND_ON/OFF/SYNC broadcasts below, which every
-- nearby player should hear, not just the one who flipped the
-- switch.
------------------------------------------------------------

------------------------------------------------------------
-- BroadcastToAll() previously fanned out one sendServerCommand()
-- call per online player (KIPN.Server.SendToPlayer() in a loop
-- over getOnlinePlayers()). PZ's sendServerCommand() has a 3-arg
-- form -- sendServerCommand(module, command, args), omitting the
-- player -- that the engine itself broadcasts to every connected
-- client in one call, instead of KIPN doing the fan-out. On a
-- 100+ player server that turns an O(players) loop of individual
-- sends into a single send, for every caller of BroadcastToAll
-- (computer sound sync, safehouse projection updates, ...).
------------------------------------------------------------

function KIPN.Server.BroadcastToAll(
    event,
    payload
)



    if event == nil then

        logError(
            "BroadcastToAll failed: event is nil."
        )


        return 0
    end

    if type(sendServerCommand) ~=
        "function"
    then

        logError(
            "BroadcastToAll failed: " ..
            "sendServerCommand() unavailable."
        )


        return 0
    end

    local ok,
        err =
        pcall(
            function()

                sendServerCommand(
                    "KIPN",
                    KIPN.Shared.Commands.SERVER_RESPONSE,
                    {
                        event =
                            tostring(event),

                        data =
                            payload
                    }
                )
            end
        )

    if not ok then

        logError(
            "BroadcastToAll failed for event " ..
            tostring(event) ..
            ": " ..
            tostring(err)
        )


        return 0
    end

    local playerCount =
        0

    if type(getOnlinePlayers) ==
        "function"
    then

        local okPlayers,
            onlinePlayers =
            pcall(
                getOnlinePlayers
            )

        if okPlayers
            and onlinePlayers
            and type(
                onlinePlayers.size
            ) == "function"
        then

            playerCount =
                onlinePlayers:size()

        end
    end



    return playerCount
end

------------------------------------------------------------
-- CORE SERVER STATS
------------------------------------------------------------

local function handleGetServerStats(
    player,
    args
)



    local data =
        KIPN.Server.GetData()

    if not data then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "SERVER_DATA_UNAVAILABLE",

                    message =
                        "Server data is unavailable."
                }
            )


        return sent
    end

    local computerCount =
        0

    local accountCount =
        0

    local claimCount =
        0

    local recordCount =
        0

    --------------------------------------------------------
    -- COMPUTERS
    --------------------------------------------------------

    if type(data.computers) ==
        "table"
    then

        for _ in pairs(
            data.computers
        ) do

            computerCount =
                computerCount + 1
        end
    end

    --------------------------------------------------------
    -- ACCOUNTS
    --------------------------------------------------------

    if type(data.accounts) ==
        "table"
    then

        for _ in pairs(
            data.accounts
        ) do

            accountCount =
                accountCount + 1
        end
    end

    --------------------------------------------------------
    -- CLAIMS
    --------------------------------------------------------

    if type(data.claims) ==
        "table"
    then

        for _ in pairs(
            data.claims
        ) do

            claimCount =
                claimCount + 1
        end
    end

    --------------------------------------------------------
    -- RECORDS
    --------------------------------------------------------

    if type(data.records) ==
        "table"
    then

        for _, collection in pairs(
            data.records
        ) do

            if type(collection) ==
                "table"
            then

                for _ in pairs(
                    collection
                ) do

                    recordCount =
                        recordCount + 1
                end
            end
        end
    end

    --------------------------------------------------------
    -- RESPONSE
    --------------------------------------------------------

    local payload = {

        schemaVersion =
            data.schemaVersion,

        computerCount =
            computerCount,

        accountCount =
            accountCount,

        claimCount =
            claimCount,

        recordCount =
            recordCount,

        starlitAvailable =
            starlitAvailable == true,
    }

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.SERVER_STATS,
            payload
        )


    return sent
end

------------------------------------------------------------
-- ONLINE PLAYERS
------------------------------------------------------------

local function handleGetOnlinePlayers(
    player,
    args
)



    local onlinePlayers =
        nil

    --------------------------------------------------------
    -- RESOLVE ONLINE PLAYERS
    --------------------------------------------------------

    if type(getOnlinePlayers) ==
        "function"
    then

        local okPlayers,
            playersResult =
            pcall(
                getOnlinePlayers
            )

        if okPlayers then

            onlinePlayers =
                playersResult

        else

            logError(
                "handleGetOnlinePlayers failed to resolve " ..
                "online players: " ..
                tostring(playersResult)
            )
        end

    else

        logError(
            "handleGetOnlinePlayers failed: " ..
            "getOnlinePlayers() unavailable."
        )
    end

    local players =
        {}

    --------------------------------------------------------
    -- BUILD PLAYER LIST
    --------------------------------------------------------

    if onlinePlayers
        and type(
            onlinePlayers.size
        ) == "function"
    then

        local playerCount =
            onlinePlayers:size()

        for i = 0,
            playerCount - 1
        do

            local okPlayer,
                p =
                pcall(
                    function()

                        return onlinePlayers:get(i)
                    end
                )

            if okPlayer
                and p
            then

                local username =
                    nil

                ------------------------------------------------
                -- USERNAME
                ------------------------------------------------

                if type(
                    p.getUsername
                ) == "function"
                then

                    local okUsername,
                        usernameResult =
                        pcall(
                            function()

                                return p:getUsername()
                            end
                        )

                    if okUsername then

                        username =
                            usernameResult
                    end
                end

                ------------------------------------------------
                -- DISPLAY NAME FALLBACK
                ------------------------------------------------

                if not username
                    or username == ""
                then

                    if type(
                        p.getDisplayName
                    ) == "function"
                    then

                        local okDisplayName,
                            displayNameResult =
                            pcall(
                                function()

                                    return p:getDisplayName()
                                end
                            )

                        if okDisplayName then

                            username =
                                displayNameResult
                        end
                    end
                end

                if not username then

                    username =
                        tostring(p)
                end

                ------------------------------------------------
                -- STEAM ID
                ------------------------------------------------

                local steamId =
                    nil

                if type(
                    p.getSteamID
                ) == "function"
                then

                    local okSteamId,
                        steamIdResult =
                        pcall(
                            function()

                                return p:getSteamID()
                            end
                        )

                    if okSteamId
                        and steamIdResult ~= nil
                    then

                        steamId =
                            tostring(
                                steamIdResult
                            )
                    end
                end

                players[
                    #players + 1
                ] = {

                    username =
                        username,

                    steamId =
                        steamId,
                }
            elseif not okPlayer then

                logError(
                    "handleGetOnlinePlayers: " ..
                    "failed to resolve player index " ..
                    tostring(i) ..
                    "."
                )
            end
        end
    end

    --------------------------------------------------------
    -- RESPONSE
    --------------------------------------------------------

    local payload = {

        players =
            players,

        totalPlayers =
            #players,
    }

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ONLINE_PLAYERS,
            payload
        )


    return sent
end

------------------------------------------------------------
-- FORECAST SERVICE RESOLUTION
------------------------------------------------------------
--
-- KIPN_Server does not implement forecasting.
--
-- The ForecastService owns forecast retrieval.
--
-- Resolution order:
--
--   1. KIPN.Server.ForecastService
--   2. KIPN.ForecastService
--   3. Legacy global KIPNForecastService
--
-- The legacy global is retained only as a compatibility
-- fallback.
------------------------------------------------------------

local function getForecastService()



    --------------------------------------------------------
    -- PRIMARY KIPN SERVER NAMESPACE
    --------------------------------------------------------

    local service =
        KIPN.Server.ForecastService

    if service then

    end

    --------------------------------------------------------
    -- SECONDARY KIPN NAMESPACE
    --------------------------------------------------------

    if not service then

        service =
            KIPN.ForecastService

        if service then

        end
    end

    --------------------------------------------------------
    -- LEGACY GLOBAL FALLBACK
    --------------------------------------------------------

    if not service then

        service =
            rawget(
                _G,
                "KIPNForecastService"
            )

        if service then

        end
    end

    --------------------------------------------------------
    -- VALIDATE SERVICE CONTRACT
    --------------------------------------------------------

    if type(service) ~= "table" then

        logError(
            "getForecastService failed: " ..
            "forecast service is not a table."
        )


        return nil
    end

    if type(
        service.GetCurrentForecast
    ) ~= "function"
    then

        logError(
            "getForecastService failed: " ..
            "GetCurrentForecast() is unavailable."
        )


        return nil
    end



    return service
end

------------------------------------------------------------
-- INTERNAL FORECAST RETRIEVAL
------------------------------------------------------------
--
-- Shared by normal forecast and login forecast commands.
--
-- Returns:
--
--   forecast = forecast table
--   nil      = retrieval failed
--
-- The service is invoked with itself as the first argument
-- so both colon-style and explicitly self-aware service
-- implementations are supported.
------------------------------------------------------------

local function getCurrentForecast()



    local service =
        getForecastService()

    if not service then

        logError(
            "getCurrentForecast failed: " ..
            "forecast service unavailable."
        )


        return nil
    end

    local ok,
        forecast =
        pcall(
            service.GetCurrentForecast,
            service
        )

    if not ok then

        logError(
            "getCurrentForecast failed: " ..
            tostring(forecast)
        )


        return nil
    end

    if forecast == nil then



        return nil
    end



    return forecast
end

------------------------------------------------------------
-- FORECAST COMMAND HANDLER
------------------------------------------------------------

local function handleGetForecast(
    player,
    args
)



    local forecast =
        getCurrentForecast()

    if not forecast then

        logError(
            "handleGetForecast: unable to obtain forecast."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "FORECAST_UNAVAILABLE",

                    message =
                        "Unable to obtain weather forecast."
                }
            )


        return true
    end

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.FORECAST_DATA,
            forecast
        )

    if not sent then

        logError(
            "handleGetForecast: failed to send forecast " ..
            "to player."
        )
    else

    end


    return true
end

------------------------------------------------------------
-- LOGIN FORECAST COMMAND HANDLER
------------------------------------------------------------

local function handleGetLoginForecast(
    player,
    args
)



    local forecast =
        getCurrentForecast()

    if not forecast then

        logError(
            "handleGetLoginForecast: unable to obtain forecast."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "FORECAST_UNAVAILABLE",

                    message =
                        "Unable to obtain weather forecast."
                }
            )


        return true
    end

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.LOGIN_FORECAST,
            forecast
        )

    if not sent then

        logError(
            "handleGetLoginForecast: failed to send " ..
            "login forecast to player."
        )
    else

    end


    return true
end

------------------------------------------------------------
-- CHECK BUILDING POWER
--
-- WORLD AUTHORITY
--
-- This function checks the actual IsoGridSquare occupied by
-- the KIPN computer.
--
-- Return values:
--
--   true  = square currently has electricity
--   false = square currently has no electricity
--   nil   = square could not be resolved / checked
--
-- IMPORTANT:
--
-- Do not use KIPN computer.power here.
-- computer.power is KIPN's virtual hardware state.
--
-- KIPN.Shared.HasSquareElectricity() (generator OR grid
-- power) is the world/environmental authority - see the
-- CHECK ELECTRICITY section below for why grid power must be
-- included.
------------------------------------------------------------

function KIPN.Server.CheckBuildingPower(
    computerId
)



    if not computerId then

        logError(
            "CheckBuildingPower failed: computerId is nil."
        )


        return nil
    end

    --------------------------------------------------------
    -- RESOLVE COMPUTER RECORD
    --------------------------------------------------------

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "CheckBuildingPower failed: computer record not found: " ..
            tostring(computerId)
        )


        return nil
    end

    --------------------------------------------------------
    -- RESOLVE WORLD COORDINATES
    --
    -- Primary source:
    --   computer.locationKey
    --
    -- The current KIPN convention is:
    --
    --   comp_X_Y_Z
    --
    -- Keep computerId as the fallback for compatibility with
    -- existing records.
    --------------------------------------------------------

    local locationKey =
        computer.locationKey

    if not locationKey then

        locationKey =
            tostring(computerId)

    end

    local x,
        y,
        z =
        string.match(
            tostring(locationKey),
            "^comp_(%-?%d+)_(%-?%d+)_(%-?%d+)$"
        )

    if not x
        or not y
        or not z
    then

        logError(
            "CheckBuildingPower failed: unable to parse " ..
            "coordinates from locationKey=" ..
            tostring(locationKey) ..
            " for computerId=" ..
            tostring(computerId) ..
            ". Expected comp_X_Y_Z."
        )


        return nil
    end

    x =
        tonumber(x)

    y =
        tonumber(y)

    z =
        tonumber(z)

    if not x
        or not y
        or not z
    then

        logError(
            "CheckBuildingPower failed: invalid coordinates " ..
            "for computerId=" ..
            tostring(computerId)
        )


        return nil
    end


    --------------------------------------------------------
    -- RESOLVE CELL
    --------------------------------------------------------

    if type(getCell) ~=
        "function"
    then

        logError(
            "CheckBuildingPower failed: getCell() unavailable."
        )


        return nil
    end

    local okCell,
        cell =
        pcall(
            function()

                return getCell()
            end
        )

    if not okCell
        or not cell
    then

        logError(
            "CheckBuildingPower failed: unable to resolve " ..
            "IsoCell. error=" ..
            tostring(cell)
        )


        return nil
    end

    --------------------------------------------------------
    -- RESOLVE GRID SQUARE
    --------------------------------------------------------

    if type(
        cell.getGridSquare
    ) ~= "function"
    then

        logError(
            "CheckBuildingPower failed: IsoCell:getGridSquare() " ..
            "is unavailable."
        )


        return nil
    end

    local okSquare,
        square =
        pcall(
            function()

                return cell:getGridSquare(
                    x,
                    y,
                    z
                )
            end
        )

    if not okSquare then

        logError(
            "CheckBuildingPower failed: getGridSquare() " ..
            "raised an error. computerId=" ..
            tostring(computerId) ..
            " error=" ..
            tostring(square)
        )


        return nil
    end

    if not square then



        return nil
    end

    --------------------------------------------------------
    -- CHECK ELECTRICITY
    --
    -- Both local/generator power (haveElectricity()) and
    -- ordinary grid power (hasGridPower()) count as building
    -- power here. hasGridPower() is what's active for most of
    -- early game, before SandboxVars.ElecShutModifier turns
    -- the grid off - checking haveElectricity() alone reports
    -- "no power" for any square without its own generator,
    -- even on day one. This must match the client's own gate
    -- (KIPN_Interaction.lua's hasWorldElectricity()) or a
    -- grid-powered computer with no generator never persists
    -- past bootState=OFF and re-shows the boot screen on every
    -- visit. KIPN.Shared.HasSquareElectricity() is the shared
    -- implementation both sides use.
    --------------------------------------------------------

    if not KIPN.Shared
        or not KIPN.Shared.HasSquareElectricity
    then

        logError(
            "CheckBuildingPower failed: " ..
            "KIPN.Shared.HasSquareElectricity() unavailable."
        )


        return nil
    end

    local okPower,
        powerResult =
        pcall(
            function()

                return KIPN.Shared.HasSquareElectricity(
                    square
                )
            end
        )

    if not okPower then

        logError(
            "CheckBuildingPower failed: " ..
            "HasSquareElectricity() raised an error. " ..
            "computerId=" ..
            tostring(computerId) ..
            " error=" ..
            tostring(powerResult)
        )


        return nil
    end

    local hasPower =
        powerResult == true



    return hasPower
end


------------------------------------------------------------
-- CHECK POWER COMMAND
------------------------------------------------------------

local function handleCheckPower(
    player,
    args
)



    args =
        args
        or {}

    local computerId =
        args.computerId

    if not computerId
        or tostring(computerId) == ""
    then

        logError(
            "CHECK_POWER rejected: missing computerId."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "No valid computer was identified."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- VERIFY COMPUTER EXISTS
    --
    -- CHECK_POWER is the first message the client sends for a
    -- given computer (fired whenever the context menu opens).
    -- It must auto-register a record on first contact, or a
    -- freshly placed/never-touched computer can never receive
    -- a POWER_STATUS response and the player gets stuck with a
    -- permanently "checking power" menu.
    --------------------------------------------------------

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        logError(
            "CHECK_POWER rejected: computer not found: " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "The requested computer does not exist."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- WORLD ELECTRICITY (SOURCE OF TRUTH)
    --------------------------------------------------------

    local buildingPowered =
        KIPN.Server.CheckBuildingPower(
            computerId
        )

    if buildingPowered == nil then

        logError(
            "CHECK_POWER failed: unable to determine " ..
            "building electricity for computer " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "POWER_STATUS_UNAVAILABLE",

                    message =
                        "Unable to determine building power."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- AUTO-RECONCILE KIPN POWER STATE WITH REAL ELECTRICITY
    --
    -- CHECK_POWER is the point where KIPN's persisted power/boot
    -- state gets brought in line with reality, reusing
    -- SetComputerPower()'s existing OFF->ON (triggers BOOTING)
    -- and ON->OFF transition logic.
    --
    -- The OFF->ON direction is skipped when computer.manualOff is
    -- true: a player explicitly chose "Power Off Computer" (see
    -- handleSetPower), and that choice must stick even though the
    -- building still has real electricity. Only another explicit
    -- "Power On Computer" request (handleSetPower, isOn=true)
    -- clears manualOff and lets this reconciliation resume.
    --
    -- The ON->OFF direction is intentionally NOT gated on
    -- manualOff: a genuine power outage should still take a
    -- computer offline regardless of manual state, and since that
    -- path never touches manualOff, the computer auto-recovers
    -- when real power returns (unless it was also manually turned
    -- off).
    --------------------------------------------------------

    local currentComputerPower =
        KIPN.Server.GetComputerPower(
            computerId
        )

    if buildingPowered == true
        and currentComputerPower ~= true
        and computer.manualOff ~= true
    then

        KIPN.Server.SetComputerPower(
            computerId,
            true
        )

    elseif buildingPowered ~= true
        and currentComputerPower == true
    then

        local reconciled =
            KIPN.Server.SetComputerPower(
            computerId,
            false
        )

        if reconciled then
            local soundX,
                soundY,
                soundZ =
                KIPN.Shared.ParseComputerIdCoords(
                    computerId
                )

            KIPN.Server._knownOnComputers =
                KIPN.Server._knownOnComputers or {}

            KIPN.Server._knownOnComputers[computerId] = nil

            KIPN.Server.BroadcastToAll(
                KIPN.Shared.ResponseEvents.COMPUTER_SOUND_OFF,
                {
                    computerId = computerId,
                    x = soundX,
                    y = soundY,
                    z = soundZ,
                    bootState = KIPN.Shared.BootStates.OFF,
                }
            )
        end
    end

    --------------------------------------------------------
    -- KIPN COMPUTER STATE (re-read after reconciliation)
    --------------------------------------------------------

    local computerPower =
        KIPN.Server.GetComputerPower(
            computerId
        )

    --------------------------------------------------------
    -- EFFECTIVE POWER
    --
    -- computerPowered:
    --   KIPN's virtual computer state.
    --
    -- buildingPowered:
    --   Actual world electricity.
    --
    -- isOn:
    --   Computer is actually usable.
    --------------------------------------------------------

    local effectivePower =
        computerPower == true
        and buildingPowered == true

    local bootState =
        KIPN.Server.GetComputerBootState(
            computerId
        )

    --------------------------------------------------------
    -- BOOT TIMING
    --
    -- See handleSetPower()'s identical use of
    -- GetComputerBootInfo(): the standalone Boot Screen needs
    -- bootStartedAtMs/bootDurationMs/bootRemainingMs whenever it
    -- (re)opens via "Access KIP Network" on a BOOTING computer,
    -- not just bootState.
    --------------------------------------------------------

    local bootInfo =
        KIPN.Server.GetComputerBootInfo(
            computerId
        )

    --------------------------------------------------------
    -- RESPONSE
    --------------------------------------------------------

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.POWER_STATUS,
            {
                computerId =
                    computerId,

                computerPowered =
                    computerPower == true,

                buildingPowered =
                    buildingPowered == true,

                isOn =
                    effectivePower,

                bootState =
                    bootState,

                bootStartedAtMs =
                    bootInfo and bootInfo.bootStartedAtMs,

                bootDurationMs =
                    bootInfo and bootInfo.bootDurationMs,

                bootRemainingMs =
                    bootInfo and bootInfo.bootRemainingMs,

                baudRate =
                    bootInfo and bootInfo.baudRate,

                condition =
                    (function()

                        local profile =
                            KIPN.Server.GetComputerProfile(
                                computerId
                            )

                        if profile
                            and profile.condition ~= nil
                        then

                            return math.floor(profile.condition + 0.5)
                        end

                        return nil
                    end)(),
            }
        )


    return true
end


------------------------------------------------------------
-- SERVER STATUS COMMAND
--
-- Confirms the server is reachable for a given computer, and
-- reports its boot timing (baudRate/bootDurationMs). Used by
-- the Boot Screen's "network" diagnostic line -- a genuine
-- request/reply round trip, unlike the purely local power
-- check.
------------------------------------------------------------

local function handleGetServerStatus(
    player,
    args
)



    args =
        args
        or {}

    local computerId =
        args.computerId

    if not computerId
        or tostring(computerId) == ""
    then

        logError(
            "GET_SERVER_STATUS rejected: missing computerId."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "No valid computer was identified."
                }
            )


        return true
    end

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        logError(
            "GET_SERVER_STATUS rejected: computer not found: " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "The requested computer does not exist."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- BOOT TIMING
    --
    -- Reuse GetComputerBootInfo() (also used by
    -- handleSetPower()/handleCheckPower()) instead of reading
    -- computer.baudRate/bootDurationMs directly -- this is the
    -- one source of truth for boot timing, and also lets the
    -- Boot Screen's "network" line resync its remaining-time
    -- estimate against a fresh bootRemainingMs on this round
    -- trip.
    --------------------------------------------------------

    local bootInfo =
        KIPN.Server.GetComputerBootInfo(
            computerId
        )

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.SERVER_STATUS,
            {
                computerId =
                    computerId,

                online =
                    true,

                baudRate =
                    bootInfo and bootInfo.baudRate
                    or computer.baudRate,

                bootDurationMs =
                    bootInfo and bootInfo.bootDurationMs
                    or computer.bootDurationMs,

                bootState =
                    bootInfo and bootInfo.bootState,

                bootStartedAtMs =
                    bootInfo and bootInfo.bootStartedAtMs,

                bootRemainingMs =
                    bootInfo and bootInfo.bootRemainingMs,
            }
        )


    return true
end


------------------------------------------------------------
-- SET POWER COMMAND
------------------------------------------------------------

-- Player audio and zombie hearing are separate systems. Emit once on
-- the server, using the physical computer as the source, so multiplayer
-- listeners cannot multiply the noise. Missing/unloaded objects are silent.
local function emitComputerNoise(computerId)
    local object = resolveComputerWorldObject(computerId)
    if not object then return end

    local square = object:getSquare()
    if not square then return end

    addSound(object, square:getX(), square:getY(), square:getZ(), 5, 20)
end

local function handleSetPower(
    player,
    args
)



    args =
        args
        or {}

    local computerId =
        args.computerId

    local isOn =
        args.isOn

    if not computerId
        or tostring(computerId) == ""
    then

        logError(
            "SET_POWER rejected: missing computerId."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "No valid computer was identified."
                }
            )


        return true
    end

    if type(isOn) ~=
        "boolean"
    then

        logError(
            "SET_POWER rejected: isOn must be boolean."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_POWER_STATE",

                    message =
                        "Power state must be true or false."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- VERIFY COMPUTER
    --
    -- Auto-register on first contact for the same reason as
    -- handleCheckPower: this may be the very first message the
    -- server has ever seen for this computer, and there is no
    -- other server-side path that creates the record.
    --------------------------------------------------------

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        logError(
            "SET_POWER rejected: computer not found: " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "The requested computer does not exist."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- MANUAL OVERRIDE FLAG
    --
    -- New computers start with manualOff=true until first powered on.
    -- This is the place player requests update that flag. It records
    -- that this transition came from an explicit player request,
    -- not from handleCheckPower's automatic electricity
    -- reconciliation, so a manual "Power Off" sticks even while
    -- the building still has real power. Persisted immediately -
    -- some of SetComputerPower()'s own early-return paths (e.g.
    -- "already off") never call saveKIPNData().
    --------------------------------------------------------

    computer.manualOff =
        (isOn ~= true)

    local manualOffSaved =
        saveKIPNData()

    if not manualOffSaved then

        logError(
            "handleSetPower: failed to persist manualOff for " ..
            tostring(computerId)
        )
    end

    --------------------------------------------------------
    -- TURNING ON
    --
    -- SetComputerPower() performs the authoritative
    -- electricity check itself.
    --------------------------------------------------------

    if isOn == true then

        local buildingPowered =
            KIPN.Server.CheckBuildingPower(
                computerId
            )

        if buildingPowered == nil then

            logError(
                "SET_POWER failed: unable to determine " ..
                "building electricity for " ..
                tostring(computerId)
            )

            local sent =
                KIPN.Server.SendToPlayer(
                    player,
                    KIPN.Shared.ResponseEvents.ERROR,
                    {
                        code =
                            "POWER_STATUS_UNAVAILABLE",

                        message =
                            "Unable to determine building power."
                    }
                )


            return true
        end

        if buildingPowered ~= true then


            local sent =
                KIPN.Server.SendToPlayer(
                    player,
                    KIPN.Shared.ResponseEvents.ERROR,
                    {
                        code =
                            "NO_POWER",

                        message =
                            "There's no power in this building."
                    }
                )


            return true
        end

        --------------------------------------------------
        -- HARDWARE CONDITION GATE
        --
        -- Gives the client a specific, actionable error
        -- instead of the generic POWER_CHANGE_FAILED that
        -- SetComputerPower()'s own refusal below would
        -- otherwise surface.
        --------------------------------------------------

        local conditionProfile =
            KIPN.Server.GetComputerProfile(
                computerId
            )

        if conditionProfile
            and (conditionProfile.condition or 100) <
                CONDITION_POWER_OFF_REFUSAL_THRESHOLD
        then

            local sent =
                KIPN.Server.SendToPlayer(
                    player,
                    KIPN.Shared.ResponseEvents.ERROR,
                    {
                        code =
                            "CONDITION_TOO_LOW",

                        message =
                            "This computer's hardware is too " ..
                            "damaged to power on."
                    }
                )


            return true
        end
    end

    --------------------------------------------------------
    -- AUTHORITATIVE KIPN POWER TRANSITION
    --------------------------------------------------------
    --
    -- Capture the boot state BEFORE the transition so the ambient
    -- broadcast below can tell a genuine fresh power-on (OFF -> BOOTING,
    -- which should replay the dial-up one-shot) from a redundant
    -- request against a computer that was already BOOTING/ON --
    -- SetComputerPower() is idempotent and returns true for both, so
    -- without this a second "Power On Computer" click would replay the
    -- modem tone over an already-running machine.

    local priorBootState =
        KIPN.Server.GetComputerBootState(
            computerId
        )

    local changed =
        KIPN.Server.SetComputerPower(
            computerId,
            isOn
        )

    if not changed then

        logError(
            "SET_POWER failed: SetComputerPower() rejected " ..
            "the transition for " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "POWER_CHANGE_FAILED",

                    message =
                        "Unable to change computer power state."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- RE-FETCH AUTHORITATIVE STATE
    --------------------------------------------------------

    local computerPower =
        KIPN.Server.GetComputerPower(
            computerId
        )

    local bootState =
        KIPN.Server.GetComputerBootState(
            computerId
        )

    --------------------------------------------------------
    -- WORLD POWER AFTER TRANSITION
    --
    -- For OFF, world power is informational only.
    -- For ON, verify it before reporting usable power.
    --------------------------------------------------------

    local buildingPowered =
        KIPN.Server.CheckBuildingPower(
            computerId
        )

    if isOn == true
        and buildingPowered == nil
    then

        logError(
            "SET_POWER completed but building electricity " ..
            "could not be verified for " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "POWER_STATUS_UNAVAILABLE",

                    message =
                        "Computer state changed, but building power " ..
                        "could not be verified."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- EFFECTIVE POWER
    --------------------------------------------------------

    local effectivePower =
        computerPower == true
        and buildingPowered == true

    --------------------------------------------------------
    -- BOOT TIMING
    --
    -- The standalone Boot Screen (client/KIPN_BootScreen.lua)
    -- needs bootStartedAtMs/bootDurationMs/bootRemainingMs to
    -- size its own progress timeline, not just bootState. Reuse
    -- GetComputerBootInfo() rather than duplicating its elapsed-
    -- time math here.
    --------------------------------------------------------

    local bootInfo =
        KIPN.Server.GetComputerBootInfo(
            computerId
        )

    --------------------------------------------------------
    -- RESPONSE
    --------------------------------------------------------

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.POWER_STATUS,
            {
                computerId =
                    computerId,

                computerPowered =
                    computerPower == true,

                buildingPowered =
                    buildingPowered == true,

                isOn =
                    effectivePower,

                bootState =
                    bootState,

                bootStartedAtMs =
                    bootInfo and bootInfo.bootStartedAtMs,

                bootDurationMs =
                    bootInfo and bootInfo.bootDurationMs,

                bootRemainingMs =
                    bootInfo and bootInfo.bootRemainingMs,

                baudRate =
                    bootInfo and bootInfo.baudRate,

                condition =
                    (function()

                        local profile =
                            KIPN.Server.GetComputerProfile(
                                computerId
                            )

                        if profile
                            and profile.condition ~= nil
                        then

                            return math.floor(profile.condition + 0.5)
                        end

                        return nil
                    end)(),
            }
        )

    --------------------------------------------------------
    -- BROADCAST AMBIENT SOUND STATE
    --
    -- Every online player, not just the requester, should hear
    -- the dial-up tone caused by this explicit power-on, the
    -- power-off tone, and the "on" hum -- see KIPN_Interaction.lua's
    -- COMPUTER_SOUND_ON/OFF handling. Periodic reconciliation also
    -- emits COMPUTER_SOUND_ON, but does not carry playDialUp=true.
    -- Coordinates are parsed from computerId itself
    -- (KIPN.Shared.ParseComputerIdCoords()); if that fails, the
    -- state-cache/loop-stop side of the broadcast still happens,
    -- it just carries no position, so the one-shot tone quietly
    -- has nothing to play from rather than blocking the power
    -- transition that already succeeded above.
    --------------------------------------------------------

    local soundX,
        soundY,
        soundZ =
        KIPN.Shared.ParseComputerIdCoords(
            computerId
        )

    if not soundX then

        logWarn(
            "SET_POWER: could not parse coordinates from " ..
            "computerId " ..
            tostring(computerId) ..
            "; COMPUTER_SOUND_* broadcast will carry no position."
        )
    end

    --------------------------------------------------------
    -- KEEP THE PERIODIC SYNC TICK'S "ALREADY KNOWN" STATE
    -- IN SYNC WITH THIS IMMEDIATE BROADCAST
    --
    -- runComputerSoundSyncTick() (below) maintains its own
    -- "computers I already told everyone are on" table so a
    -- steady-state server doesn't replay the one-shot dial-up
    -- tone every sync interval. That table is only ever
    -- updated from inside the tick itself, so without this it
    -- has no way to know THIS broadcast already happened --
    -- the next tick (up to COMPUTER_SOUND_SYNC_INTERVAL_MS
    -- later) would see the computer as "newly on/off" and
    -- broadcast COMPUTER_SOUND_ON/OFF a second time, playing
    -- the modem/power-off tone twice for one power toggle.
    -- KIPN.Server._knownOnComputers is the single shared table
    -- both places read and write to prevent that.
    --------------------------------------------------------

    KIPN.Server._knownOnComputers =
        KIPN.Server._knownOnComputers or {}

    if bootState ==
        KIPN.Shared.BootStates.OFF
    then

        if priorBootState ~= KIPN.Shared.BootStates.OFF then
            emitComputerNoise(computerId)
        end

        KIPN.Server._knownOnComputers[computerId] =
            nil

        KIPN.Server.BroadcastToAll(
            KIPN.Shared.ResponseEvents.COMPUTER_SOUND_OFF,
            {
                computerId =
                    computerId,

                x =
                    soundX,

                y =
                    soundY,

                z =
                    soundZ,

                -- Lets clients seed KIPN._bootStateCache from the same
                -- broadcast that drives the ambient loop, so the
                -- right-click menu ("Power On Computer" vs. "Access KIP
                -- Network") is correct on the very first interaction
                -- after a reconnect, not just the second.
                bootState =
                    KIPN.Shared.BootStates.OFF,
            }
        )

    else

        if soundX then

            if priorBootState == KIPN.Shared.BootStates.OFF then
                emitComputerNoise(computerId)
            end

            KIPN.Server._knownOnComputers[computerId] = {
                x = soundX,
                y = soundY,
                z = soundZ,
            }

            KIPN.Server.BroadcastToAll(
                KIPN.Shared.ResponseEvents.COMPUTER_SOUND_ON,
                {
                    computerId =
                        computerId,

                    x =
                        soundX,

                    y =
                        soundY,

                    z =
                        soundZ,

                    -- See the COMPUTER_SOUND_OFF note above -- carries
                    -- the authoritative BOOTING/ON state so a
                    -- reconnecting client's menu doesn't fall back to
                    -- "Power On Computer" for an already-on computer.
                    bootState =
                        bootState,

                    -- Only handleSetPower() adds this flag, and only
                    -- for a genuine fresh power-on -- a redundant
                    -- request against an already BOOTING/ON computer
                    -- (e.g. a stale "Power On Computer" menu entry
                    -- clicked right after a reconnect) must not replay
                    -- the modem tone. login/periodic reconciliation
                    -- never sets it at all.
                    playDialUp =
                        priorBootState ~=
                            KIPN.Shared.BootStates.BOOTING
                        and priorBootState ~=
                            KIPN.Shared.BootStates.ON,
                }
            )
        end
    end


    return true
end

------------------------------------------------------------
-- DISASSEMBLE COMPUTER COMMAND
--
-- Degrades (never destroys) a computer's Hardware Condition.
-- Everything is re-validated server-side -- the computer must be
-- OFF, the player must actually carry a screwdriver, and the
-- Electrical skill level used for scaling is read from the
-- player object the server itself has, never from client-supplied
-- data.
------------------------------------------------------------

local function handleDisassembleComputer(
    player,
    args
)



    args =
        args
        or {}

    local computerId =
        args.computerId

    if not computerId
        or tostring(computerId) == ""
    then

        logError(
            "DISASSEMBLE_COMPUTER rejected: missing computerId."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "No valid computer was identified."
                }
            )


        return true
    end

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        logError(
            "DISASSEMBLE_COMPUTER rejected: computer not found: " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "The requested computer does not exist."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- MUST BE POWERED OFF
    --------------------------------------------------------

    local bootState =
        KIPN.Server.GetComputerBootState(
            computerId
        )

    if bootState ~= KIPN.Shared.BootStates.OFF then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "COMPUTER_NOT_OFF",

                    message =
                        "The computer must be powered off before " ..
                        "it can be disassembled."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- MUST HAVE A SCREWDRIVER
    --------------------------------------------------------

    local inventory =
        player
        and player.getInventory
        and player:getInventory()

    local hasScrewdriver =
        inventory
        and type(inventory.contains) == "function"
        and (
            inventory:contains("Base.Screwdriver")
            or inventory:contains("Base.Screwdriver_Improvised")
            or inventory:contains("Base.Screwdriver_Old")
        )

    if not hasScrewdriver then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "MISSING_TOOL",

                    message =
                        "A screwdriver is required to disassemble " ..
                        "this computer."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- ELECTRICAL LEVEL (server-trusted, never client-supplied)
    --------------------------------------------------------

    local electricalLevel =
        0

    if player
        and player.getPerkLevel
        and Perks
        and Perks.Electrical
    then

        local okLevel,
            levelResult =
            pcall(
                function()

                    return player:getPerkLevel(
                        Perks.Electrical
                    )
                end
            )

        if okLevel
            and type(levelResult) == "number"
        then

            electricalLevel =
                levelResult
        end
    end

    if electricalLevel > 10 then

        electricalLevel =
            10
    end

    --------------------------------------------------------
    -- APPLY DEGRADATION
    --
    -- base = random(2, 8)
    -- degradation = min(75, base * (1 + (level/10)*(multiplier-1)))
    --
    -- At the default sandbox multiplier (10 = 1.0x), the scaling
    -- factor collapses to 1 regardless of level -- degradation
    -- stays a flat 2-8%. Admins raise the multiplier above 1.0x to
    -- make higher Electrical levels cause more damage.
    --------------------------------------------------------

    local profile =
        KIPN.Server.GetComputerProfile(
            computerId
        )

    if not profile then

        logError(
            "DISASSEMBLE_COMPUTER failed: unable to resolve " ..
            "condition profile for " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "Unable to resolve this computer's hardware " ..
                        "state."
                }
            )


        return true
    end

    local cc =
        KIPN.Server.ComputerConfig

    local disassembleMultiplier =
        (
            cc
            and cc.ComputerConditionElectricalLevelDisassembleMultiplier
            or 10
        ) / 10.0

    local baseDegradation

    if type(ZombRand) == "function" then

        baseDegradation =
            2 + ZombRand(7)

    else

        baseDegradation =
            math.random(2, 8)
    end

    local scaledDegradation =
        baseDegradation
        * (
            1 +
            (electricalLevel / 10) * (disassembleMultiplier - 1)
        )

    if scaledDegradation > 75 then

        scaledDegradation =
            75
    end

    if scaledDegradation < 0 then

        scaledDegradation =
            0
    end

    profile.condition =
        math.max(
            0,
            (profile.condition or 100) - scaledDegradation
        )

    local saved =
        saveKIPNData()

    if not saved then

        logError(
            "DISASSEMBLE_COMPUTER: failed to persist condition " ..
            "change for " ..
            tostring(computerId)
        )
    end

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.COMPUTER_CONDITION_UPDATED,
            {
                computerId =
                    computerId,

                condition =
                    math.floor(profile.condition + 0.5),

                degradationApplied =
                    scaledDegradation,
            }
        )


    return saved
end

------------------------------------------------------------
-- REPAIR COMPUTER COMMAND
--
-- Restores (never destroys or overheals past 100%) a computer's
-- Hardware Condition. Everything is re-validated server-side -- the
-- computer must be OFF, must not already be at 100% condition, the
-- player must actually carry both a required repair tool (default:
-- a screwdriver -- admin-configurable, see
-- CraftingRequirementsConfig.RegistrationTypes.COMPUTER_REPAIR_TOOL)
-- and a Computer Repair Kit, and the Electrical skill level used
-- for scaling is read from the player object the server itself
-- has, never from client-supplied data. Mirrors
-- handleDisassembleComputer's formula in reverse -- see
-- KIPN_ComputerConfig.lua's "COMPUTER CONDITION: REPAIR" section
-- for the sandbox settings involved.
--
-- On success, the Computer Repair Kit is CONSUMED -- unlike the
-- repair tool (kept, like the screwdriver required to disassemble
-- a computer).
------------------------------------------------------------

local function handleRepairComputer(
    player,
    args
)



    args =
        args
        or {}

    local computerId =
        args.computerId

    if not computerId
        or tostring(computerId) == ""
    then

        logError(
            "REPAIR_COMPUTER rejected: missing computerId."
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "No valid computer was identified."
                }
            )


        return true
    end

    local computer =
        KIPN.Server.GetOrCreateComputer(
            computerId
        )

    if not computer then

        logError(
            "REPAIR_COMPUTER rejected: computer not found: " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "The requested computer does not exist."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- MUST BE POWERED OFF
    --------------------------------------------------------

    local bootState =
        KIPN.Server.GetComputerBootState(
            computerId
        )

    if bootState ~= KIPN.Shared.BootStates.OFF then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "COMPUTER_NOT_OFF",

                    message =
                        "The computer must be powered off before " ..
                        "it can be repaired."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- REPAIR MUST BE ENABLED (0 = off)
    --------------------------------------------------------

    local cc =
        KIPN.Server.ComputerConfig

    local percentageMultiplier =
        (
            cc
            and cc.ComputerConditionRepairPercentage
            or 10
        ) / 10.0

    if percentageMultiplier <= 0 then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "REPAIR_DISABLED",

                    message =
                        "Computer repair is disabled on this server."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- COMPUTER PROFILE / MUST NOT ALREADY BE AT MAX CONDITION
    --
    -- Resolved early (rather than immediately before applying the
    -- repair math, as handleDisassembleComputer resolves its own
    -- profile) so a computer already at 100% condition is rejected
    -- BEFORE the tool/kit checks below -- the Computer Repair Kit
    -- is consumed on success, and there is nothing to restore.
    --------------------------------------------------------

    local profile =
        KIPN.Server.GetComputerProfile(
            computerId
        )

    if not profile then

        logError(
            "REPAIR_COMPUTER failed: unable to resolve " ..
            "condition profile for " ..
            tostring(computerId)
        )

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMPUTER",

                    message =
                        "Unable to resolve this computer's hardware " ..
                        "state."
                }
            )


        return true
    end

    if (profile.condition or 100) >= 100 then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "COMPUTER_ALREADY_REPAIRED",

                    message =
                        "This computer is already at 100% Hardware " ..
                        "Condition."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- MUST HAVE A REQUIRED REPAIR TOOL
    --
    -- Default: any one of the three screwdriver FullTypes (same
    -- tool handleDisassembleComputer requires) -- admin-configurable
    -- via CraftingRequirementsConfig.RegistrationTypes.
    -- COMPUTER_REPAIR_TOOL. Kept, never consumed.
    --------------------------------------------------------

    if not KIPN.Server.CraftingRequirementsConfig
        or type(KIPN.Server.CraftingRequirementsConfig.PlayerHasComputerRepairTool)
            ~= "function"
        or not KIPN.Server.CraftingRequirementsConfig.PlayerHasComputerRepairTool(
            player
        )
    then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "MISSING_TOOL",

                    message =
                        "A repair tool (e.g. a screwdriver) is required " ..
                        "to repair this computer."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- MUST HAVE A COMPUTER REPAIR KIT
    --
    -- Unlike the repair tool above, the Computer Repair Kit itself
    -- IS consumed on success -- see "CONSUME COMPUTER REPAIR KIT"
    -- below. The actual inventory item (not just a boolean contains()
    -- check) is resolved here so it can be removed later.
    --------------------------------------------------------

    local inventory =
        player
        and player.getInventory
        and player:getInventory()

    local repairKitItem =
        inventory
        and type(inventory.getFirstTypeRecurse) == "function"
        and inventory:getFirstTypeRecurse("Base.KIPNComputerRepairKit")

    if not repairKitItem then

        local sent =
            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "MISSING_REPAIR_KIT",

                    message =
                        "A Computer Repair Kit is required to " ..
                        "repair this computer."
                }
            )


        return true
    end

    --------------------------------------------------------
    -- ELECTRICAL LEVEL (server-trusted, never client-supplied)
    --------------------------------------------------------

    local electricalLevel =
        0

    if player
        and player.getPerkLevel
        and Perks
        and Perks.Electrical
    then

        local okLevel,
            levelResult =
            pcall(
                function()

                    return player:getPerkLevel(
                        Perks.Electrical
                    )
                end
            )

        if okLevel
            and type(levelResult) == "number"
        then

            electricalLevel =
                levelResult
        end
    end

    if electricalLevel > 10 then

        electricalLevel =
            10
    end

    --------------------------------------------------------
    -- APPLY REPAIR
    --
    -- base = random(2, 8)
    -- repair = min(75, base * percentageMultiplier *
    --     (1 + (level/10)*(xpMultiplier-1)))
    --
    -- At the default sandbox settings (percentageMultiplier =
    -- 1.0x, xpMultiplier = 10.0x), a level-0 Electrical player
    -- restores a flat 2-8%, and a level-10 Electrical player's
    -- best possible roll reaches the 75% hard cap.
    --
    -- "profile" was already resolved above (see "COMPUTER PROFILE /
    -- MUST NOT ALREADY BE AT MAX CONDITION").
    --------------------------------------------------------

    local xpMultiplier =
        (
            cc
            and cc.ComputerConditionRepairElectricalXPMultiplier
            or 100
        ) / 10.0

    local baseRepair

    if type(ZombRand) == "function" then

        baseRepair =
            2 + ZombRand(7)

    else

        baseRepair =
            math.random(2, 8)
    end

    local scaledRepair =
        baseRepair
        * percentageMultiplier
        * (
            1 +
            (electricalLevel / 10) * (xpMultiplier - 1)
        )

    if scaledRepair > 75 then

        scaledRepair =
            75
    end

    if scaledRepair < 0 then

        scaledRepair =
            0
    end

    profile.condition =
        math.min(
            100,
            (profile.condition or 100) + scaledRepair
        )

    local saved =
        saveKIPNData()

    if not saved then

        logError(
            "REPAIR_COMPUTER: failed to persist condition " ..
            "change for " ..
            tostring(computerId)
        )
    end

    --------------------------------------------------------
    -- CONSUME COMPUTER REPAIR KIT
    --
    -- Unlike the repair tool checked above, the kit itself is spent
    -- on every successful repair -- it is not reusable like the
    -- screwdriver required to disassemble a computer. Consumed here
    -- (after the condition change/save above) rather than up front,
    -- so the kit is only ever removed once the repair has actually
    -- been applied.
    --------------------------------------------------------

    local kitRemoved,
        kitRemoveError =
        pcall(
            function()

                inventory:Remove(
                    repairKitItem
                )
            end
        )

    if not kitRemoved then

        logError(
            "REPAIR_COMPUTER: failed to consume Computer Repair Kit " ..
            "for " ..
            tostring(computerId) ..
            ": " ..
            tostring(kitRemoveError)
        )
    end

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.COMPUTER_CONDITION_UPDATED,
            {
                computerId =
                    computerId,

                condition =
                    math.floor(profile.condition + 0.5),

                repairApplied =
                    scaledRepair,

                repairKitConsumed =
                    kitRemoved == true,
            }
        )


    return saved
end

------------------------------------------------------------
-- OPEN BBS COMMAND
------------------------------------------------------------

local function handleOpenBBS(
    player,
    args
)



    args =
        args or {}

    --------------------------------------------------------
    -- VALIDATE PLAYER
    --------------------------------------------------------

    if not player then

        logError(
            "OPEN_BBS rejected: no player supplied."
        )


        return true
    end

    --------------------------------------------------------
    -- VALIDATE COMPUTER ID
    --------------------------------------------------------

    local computerId =
        args.computerId

    if not computerId
        or tostring(computerId) == ""
    then

        logError(
            "OPEN_BBS rejected: missing computerId."
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "INVALID_COMPUTER",

                message =
                    "No valid computer was identified."
            }
        )


        return true
    end

    computerId =
        tostring(computerId)

    --------------------------------------------------------
    -- COMPUTER RECORD
    --------------------------------------------------------

    local computer =
        KIPN.Server.GetComputer(
            computerId
        )

    if not computer then

        logError(
            "OPEN_BBS rejected: computer not found: " ..
            computerId
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "INVALID_COMPUTER",

                message =
                    "This computer is not registered."
            }
        )


        return true
    end

    --------------------------------------------------------
    -- AUTHORITATIVE COMPUTER POWER
    --------------------------------------------------------

    local computerPowered =
        KIPN.Server.GetComputerPower(
            computerId
        )

    if computerPowered ~= true then


        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "COMPUTER_OFF",

                message =
                    "This computer is powered off."
            }
        )


        return true
    end

    --------------------------------------------------------
    -- AUTHORITATIVE WORLD POWER
    --------------------------------------------------------
    --
    -- This checks the actual world square.
    --
    -- Do NOT convert nil to false here. Nil means the server
    -- could not resolve the world power state.

    local buildingPowered =
        KIPN.Server.CheckBuildingPower(
            computerId
        )

    if buildingPowered == nil then

        logError(
            "OPEN_BBS failed for " ..
            computerId ..
            ": unable to determine building power."
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "POWER_STATUS_UNAVAILABLE",

                message =
                    "Unable to determine building power."
            }
        )


        return true
    end

    if buildingPowered ~= true then


        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "NO_POWER",

                message =
                    "There's no power in this building."
            }
        )


        return true
    end

    --------------------------------------------------------
    -- RECONCILE BOOT STATE
    --------------------------------------------------------
    --
    -- GetComputerBootInfo() is authoritative for the current
    -- boot state and may transition BOOTING -> ON.

    local bootInfo =
        KIPN.Server.GetComputerBootInfo(
            computerId
        )

    if not bootInfo then

        logError(
            "OPEN_BBS failed: unable to build boot information " ..
            "for computer " ..
            computerId
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "BOOT_INFO_UNAVAILABLE",

                message =
                    "Unable to determine computer boot state."
            }
        )


        return true
    end

    --------------------------------------------------------
    -- FINAL POWER CONSISTENCY CHECK
    --------------------------------------------------------

    if bootInfo.powered ~= true then

        logError(
            "OPEN_BBS rejected after boot reconciliation: " ..
            "computer " ..
            computerId ..
            " is no longer powered."
        )

        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.ERROR,
            {
                code =
                    "COMPUTER_OFF",

                message =
                    "This computer is powered off."
            }
        )


        return true
    end

    --------------------------------------------------------
    -- APPROVED
    --------------------------------------------------------
    --
    -- IMPORTANT:
    --
    -- BOOTING is a valid response.
    --
    -- The client should receive BBS_AVAILABLE and display the
    -- boot sequence using bootState / boot timing information.
    --
    -- Do NOT reject BOOTING here unless the client is explicitly
    -- forbidden from opening the terminal until boot completes.


    --------------------------------------------------------
    -- SEND AUTHORITATIVE BBS STATE
    --------------------------------------------------------

    local sent =
        KIPN.Server.SendToPlayer(
            player,
            KIPN.Shared.ResponseEvents.BBS_AVAILABLE,
            {
                computerId =
                    computerId,

                powered =
                    bootInfo.powered,

                buildingPowered =
                    buildingPowered,

                bootState =
                    bootInfo.bootState,

                baudRate =
                    bootInfo.baudRate,

                bootStartedAtMs =
                    bootInfo.bootStartedAtMs,

                bootDurationMs =
                    bootInfo.bootDurationMs,

                bootRemainingMs =
                    bootInfo.bootRemainingMs,

                bootDiagnostics =
                    bootInfo.bootDiagnostics
                    or {},
            }
        )

    if not sent then

        logError(
            "OPEN_BBS failed: unable to send BBS_AVAILABLE " ..
            "response for computer " ..
            computerId
        )


        return true
    end

    --------------------------------------------------------
    -- COMPLETE
    --------------------------------------------------------



    return true
end

------------------------------------------------------------
-- COMMAND REGISTRATION
------------------------------------------------------------
--
-- Core commands belong here.
--
-- Feature/service commands should be registered by their own
-- service during Initialize().
--
-- IMPORTANT:
--
-- Every command listed here is part of the KIPN core contract.
-- If its Shared command identifier is missing, registration
-- fails rather than allowing the server to boot partially.
------------------------------------------------------------

local function registerCoreServiceCommands()



    local success =
        true

    local registrations = {

        {
            name =
                "GET_SERVER_STATS",

            command =
                KIPN.Shared.Commands.GET_SERVER_STATS,

            handler =
                handleGetServerStats,
        },

        {
            name =
                "GET_ONLINE_PLAYERS",

            command =
                KIPN.Shared.Commands.GET_ONLINE_PLAYERS,

            handler =
                handleGetOnlinePlayers,
        },

        {
            name =
                "GET_FORECAST",

            command =
                KIPN.Shared.Commands.GET_FORECAST,

            handler =
                handleGetForecast,
        },

        {
            name =
                "GET_LOGIN_FORECAST",

            command =
                KIPN.Shared.Commands.GET_LOGIN_FORECAST,

            handler =
                handleGetLoginForecast,
        },

        {
            name =
                "CHECK_POWER",

            command =
                KIPN.Shared.Commands.CHECK_POWER,

            handler =
                handleCheckPower,
        },

        {
            name =
                "SET_POWER",

            command =
                KIPN.Shared.Commands.SET_POWER,

            handler =
                handleSetPower,
        },

        {
            name =
                "DISASSEMBLE_COMPUTER",

            command =
                KIPN.Shared.Commands.DISASSEMBLE_COMPUTER,

            handler =
                handleDisassembleComputer,
        },

        {
            name =
                "REPAIR_COMPUTER",

            command =
                KIPN.Shared.Commands.REPAIR_COMPUTER,

            handler =
                handleRepairComputer,
        },

        {
            name =
                "GET_SERVER_STATUS",

            command =
                KIPN.Shared.Commands.GET_SERVER_STATUS,

            handler =
                handleGetServerStatus,
        },

        {
            name =
                "OPEN_BBS",

            command =
                KIPN.Shared.Commands.OPEN_BBS,

            handler =
                handleOpenBBS,
        },
    }

    --------------------------------------------------------
    -- REGISTER CORE COMMANDS
    --------------------------------------------------------

    for _, registration in ipairs(
        registrations
    ) do

        local name =
            registration.name

        local command =
            registration.command

        local handler =
            registration.handler

        ----------------------------------------------------
        -- VALIDATE COMMAND IDENTIFIER
        ----------------------------------------------------

        if not command
            or command == ""
        then

            logError(
                "Core command registration failed: " ..
                "Shared command identifier is missing for " ..
                tostring(name)
            )

            success =
                false

        ----------------------------------------------------
        -- VALIDATE HANDLER
        ----------------------------------------------------

        elseif type(handler) ~= "function" then

            logError(
                "Core command registration failed: " ..
                "handler is not a function for " ..
                tostring(name)
            )

            success =
                false

        ----------------------------------------------------
        -- REGISTER
        ----------------------------------------------------

        else

            local registered =
                KIPN.Server.RegisterCommandHandler(
                    command,
                    handler
                )

            if not registered then

                logError(
                    "Failed to register core command: " ..
                    tostring(name) ..
                    " (" ..
                    tostring(command) ..
                    ")"
                )

                success =
                    false

            else

            end
        end
    end

    --------------------------------------------------------
    -- RESULT
    --------------------------------------------------------

    if success then


    else

        logError(
            "Core command registration completed with errors."
        )
    end


    return success
end

------------------------------------------------------------
-- SAFE SANDBOX OVERRIDE ADAPTER
------------------------------------------------------------
--
-- Sandbox implementation does not belong in KIPN_Server.
--
-- The server orchestrator only asks the Settings/configuration
-- service to apply sandbox values.
--
-- IMPORTANT:
--
-- KIPN_Server does not read SandboxVars directly.
-- KIPN_Server does not own sandbox configuration.
-- The Settings service owns the sandbox/configuration boundary.
--
-- ApplySandboxOverrides() is the preferred service contract.
------------------------------------------------------------

local function applySandboxOverrides()



    --------------------------------------------------------
    -- RESOLVE SETTINGS SERVICE
    --------------------------------------------------------

    local settings =
        KIPN.Server.Settings

    if not settings then

        logError(
            "applySandboxOverrides failed: " ..
            "KIPN.Server.Settings is unavailable."
        )


        return false
    end

    if type(settings) ~= "table" then

        logError(
            "applySandboxOverrides failed: " ..
            "KIPN.Server.Settings is not a table."
        )


        return false
    end

    --------------------------------------------------------
    -- REQUIRED SETTINGS CONTRACT
    --------------------------------------------------------

    local applyOverrides =
        settings.ApplySandboxOverrides

    if type(applyOverrides) ~= "function" then

        logError(
            "applySandboxOverrides failed: " ..
            "Settings.ApplySandboxOverrides() is unavailable."
        )


        return false
    end

    --------------------------------------------------------
    -- APPLY SANDBOX OVERRIDES
    --------------------------------------------------------
    --
    -- KIPN Settings services are expected to expose this as
    -- a plain function:
    --
    --     function Settings.ApplySandboxOverrides()
    --
    -- Therefore no implicit self parameter is supplied here.
    --
    -- If the Settings implementation uses ':' instead, this
    -- call must be changed to:
    --
    --     settings:ApplySandboxOverrides()
    --
    -- The service contract should use one convention only.
    --------------------------------------------------------

    local ok,
        result =
        pcall(
            applyOverrides
        )

    if not ok then

        logError(
            "Settings.ApplySandboxOverrides() failed: " ..
            tostring(result)
        )


        return false
    end

    --------------------------------------------------------
    -- NORMALIZE SERVICE RESULT
    --------------------------------------------------------

    if result == false then

        logError(
            "Settings.ApplySandboxOverrides() reported failure."
        )


        return false
    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------



    return true
end

------------------------------------------------------------
-- SERVICE INITIALIZATION
------------------------------------------------------------
--
-- KIPN_Server is the orchestrator.
--
-- Loading a Lua module and initializing a service are two
-- separate operations.
--
-- require():
--
--     Loads the module file.
--
-- initializeService():
--
--     Calls the service's initialization method, if one exists.
--
-- This keeps module loading separate from service lifecycle.
--
-- IMPORTANT:
--
-- Services should expose their lifecycle methods as plain
-- functions on their service namespace:
--
--     function KIPN.SomeService.Initialize()
--
-- NOT:
--
--     function KIPN.SomeService:Initialize()
--
-- The initializer is therefore invoked without an implicit
-- self argument.
--
-- Meta Time Run logging is emitted once for the complete
-- initializeService() operation.
------------------------------------------------------------

local function initializeService(
    serviceName,
    service,
    methodName
)

    local success =
        false

    local resultState =
        "UNKNOWN"


    --------------------------------------------------------
    -- VALIDATE SERVICE
    --------------------------------------------------------

    if type(service) ~= "table" then

        logError(
            "Service unavailable: " ..
            tostring(serviceName)
        )

        resultState =
            "SERVICE_UNAVAILABLE"

    else

        ----------------------------------------------------
        -- RESOLVE INITIALIZATION METHOD
        ----------------------------------------------------

        local initialize =
            service[
                methodName
            ]

        if type(initialize) ~= "function" then

            ------------------------------------------------
            -- A service may legitimately have no explicit
            -- initializer.
            ------------------------------------------------


            success =
                true

            resultState =
                "NO_INITIALIZER"

        else

            ------------------------------------------------
            -- CALL INITIALIZER
            ------------------------------------------------
            --
            -- The KIPN service contract uses plain functions,
            -- so do not pass service as an implicit self value.
            ------------------------------------------------

            local ok,
                result =
                pcall(
                    initialize
                )

            if not ok then

                logError(
                    "Service initialization failed for " ..
                    tostring(serviceName) ..
                    ": " ..
                    tostring(result)
                )

                success =
                    false

                resultState =
                    "INITIALIZATION_ERROR"

            else

                ------------------------------------------------
                -- FALSE EXPLICITLY MEANS FAILURE.
                -- NIL / TRUE / OTHER VALUES mean success.
                ------------------------------------------------

                success =
                    result ~= false

                if success then

                    resultState =
                        "INITIALIZED"


                else

                    resultState =
                        "INITIALIZATION_REJECTED"

                    logError(
                        "Service rejected initialization: " ..
                        tostring(serviceName)
                    )
                end
            end
        end
    end

    return success
end

------------------------------------------------------------
-- CLIENT COMMAND ROUTER
------------------------------------------------------------
--
-- This is intentionally small.
--
-- Services register handlers through:
--
--     KIPN.Server.RegisterCommandHandler()
--
-- The orchestrator does not contain feature-specific command
-- branches.
--
-- Command flow:
--
--     OnClientCommand
--          |
--          v
--     validate module
--          |
--          v
--     validate command
--          |
--          v
--     resolve registered handler
--          |
--          v
--     execute handler
--          |
--          v
--     evaluate handler result
--
-- A handler returning false explicitly declines the command.
-- Any other return value is considered handled.
------------------------------------------------------------

local function onClientCommand(
    module,
    command,
    player,
    args
)

    local success =
        false


    repeat
    --------------------------------------------------------
    -- MODULE VALIDATION
    --------------------------------------------------------

    if module ~= "KIPN" then


        success =
            true

        break
    end

    --------------------------------------------------------
    -- COMMAND VALIDATION
    --------------------------------------------------------

    if not command
        or command == ""
    then

        logError(
            "Received KIPN command without command name."
        )

        if player then

            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "INVALID_COMMAND",

                    message =
                        "No command was supplied."
                }
            )
        end

        break
    end

    --------------------------------------------------------
    -- NORMALIZE ARGUMENTS
    --------------------------------------------------------

    if type(args) ~= "table" then


        args =
            {}
    end

    --------------------------------------------------------
    -- RESOLVE REGISTERED HANDLER
    --------------------------------------------------------

    local handlerOk,
        handler =
        pcall(
            KIPN.Server.GetCommandHandler,
            command
        )

    if not handlerOk then

        logError(
            "Unable to resolve command handler for " ..
            tostring(command) ..
            ": " ..
            tostring(handler)
        )

        if player then

            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "COMMAND_ROUTER_ERROR",

                    command =
                        command,

                    message =
                        "Unable to resolve the command handler."
                }
            )
        end

        break
    end

    if type(handler) ~= "function" then

        logError(
            "Unknown KIPN client command: " ..
            tostring(command)
        )

        if player then

            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "UNKNOWN_COMMAND",

                    command =
                        command,

                    message =
                        "Unknown KIPN command."
                }
            )
        end

        break
    end

    --------------------------------------------------------
    -- EXECUTE REGISTERED HANDLER
    --------------------------------------------------------


    local handlerOk,
        handled,
        reason =
        pcall(
            handler,
            player,
            args
        )

    if not handlerOk then

        logError(
            "Command handler error for " ..
            tostring(command) ..
            ": " ..
            tostring(handled)
        )

        if player then

            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "SERVER_HANDLER_ERROR",

                    command =
                        command,

                    message =
                        "Server command handler failed."
                }
            )
        end

        break
    end

    --------------------------------------------------------
    -- HANDLER CONTRACT
    --------------------------------------------------------
    --
    -- false = explicitly declined
    -- nil   = handled
    -- true  = handled
    -- other = handled
    --------------------------------------------------------

    if handled == false then


        if player then

            KIPN.Server.SendToPlayer(
                player,
                KIPN.Shared.ResponseEvents.ERROR,
                {
                    code =
                        "COMMAND_DECLINED",

                    command =
                        command,

                    reason =
                        reason
                }
            )
        end

        break
    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------


    success =
        true

    until true
end

------------------------------------------------------------
-- PER-PLAYER COMMAND FLOOD PROTECTION
------------------------------------------------------------
--
-- Every sendClientCommand("KIPN", ...) reaches the router and some
-- commands trigger authoritative saves. A buggy or hostile client
-- could otherwise drive that as fast as it can loop. This is a
-- coarse sliding-window limiter: generous enough that no legitimate
-- terminal interaction (which bursts a dozen-ish commands on open)
-- is ever affected, tight enough to stop a spin loop.
--
-- Exceeding the cap silently drops the command; the client is told
-- once per window and one WARN is logged per window per player.
------------------------------------------------------------

local KIPN_COMMAND_RATE_WINDOW_MS =
    3000

local KIPN_COMMAND_RATE_MAX =
    60

-- Entries whose window ended longer ago than this are pruned
-- opportunistically (covers disconnects without a dedicated hook).
local KIPN_COMMAND_RATE_STALE_MS =
    30000

local commandRateState =
    {}

local function commandRateNowMs()

    if type(getTimestampMs) ~= "function" then
        return 0
    end

    local ok, value =
        pcall(getTimestampMs)

    if ok and type(value) == "number" then
        return value
    end

    return 0
end

local function commandRateKeyFor(player)

    if not player then
        return nil
    end

    if type(player.getOnlineID) == "function" then

        local ok, id = pcall(function()
            return player:getOnlineID()
        end)

        if ok and id ~= nil then
            return "id:" .. tostring(id)
        end
    end

    if type(player.getUsername) == "function" then

        local ok, name = pcall(function()
            return player:getUsername()
        end)

        if ok and name ~= nil and name ~= "" then
            return "user:" .. tostring(name)
        end
    end

    return nil
end

-- Returns true if the command is allowed, false if it should be
-- dropped. The second return is true exactly once per window when a
-- drop first happens, so the caller can notify/log without spam.
local function commandRateAllow(player)

    local key =
        commandRateKeyFor(player)

    -- Can't identify the caller -- don't gamble on dropping a real
    -- command; let it through (still inside the pcall boundary).
    if not key then
        return true, false
    end

    local now =
        commandRateNowMs()

    local state =
        commandRateState[key]

    if not state
        or (now - (state.windowStart or 0)) >= KIPN_COMMAND_RATE_WINDOW_MS
    then

        -- Opportunistic prune of stale peers.
        for otherKey, otherState in pairs(commandRateState) do
            if (now - (otherState.windowStart or 0))
                >= KIPN_COMMAND_RATE_STALE_MS
            then
                commandRateState[otherKey] = nil
            end
        end

        commandRateState[key] = {
            windowStart = now,
            count = 1,
            notified = false,
        }

        return true, false
    end

    state.count =
        (state.count or 0) + 1

    if state.count <= KIPN_COMMAND_RATE_MAX then
        return true, false
    end

    local firstTrip =
        not state.notified

    state.notified =
        true

    return false, firstTrip
end

------------------------------------------------------------
-- SAFE COMMAND WRAPPER
------------------------------------------------------------
--
-- Final exception boundary for the KIPN client-command event.
--
-- onClientCommand() handles command validation, routing, and
-- handler execution.
--
-- This wrapper exists so an unexpected error escaping the
-- router cannot propagate through the Project Zomboid event
-- callback.
------------------------------------------------------------

local function safeOnClientCommand(
    module,
    command,
    player,
    args
)

    local success =
        false

    --------------------------------------------------------
    -- FLOOD PROTECTION (KIPN commands only)
    --------------------------------------------------------

    if module == "KIPN" then

        local allowed,
            firstTrip =
            commandRateAllow(player)

        if not allowed then

            if firstTrip then

                logWarn(
                    "Command flood protection: dropping KIPN commands "
                    .. "from a client exceeding "
                    .. tostring(KIPN_COMMAND_RATE_MAX)
                    .. "/"
                    .. tostring(KIPN_COMMAND_RATE_WINDOW_MS)
                    .. "ms (command="
                    .. tostring(command)
                    .. ")."
                )

                if player then

                    pcall(
                        KIPN.Server.SendToPlayer,
                        player,
                        KIPN.Shared.ResponseEvents.ERROR,
                        {
                            code =
                                "RATE_LIMITED",

                            message =
                                "Too many requests. Slow down."
                        }
                    )
                end
            end

            return
        end
    end

    --------------------------------------------------------
    -- PROTECTED COMMAND ROUTING
    --------------------------------------------------------

    local ok,
        err =
        pcall(
            onClientCommand,
            module,
            command,
            player,
            args
        )

    if not ok then

        logError(
            "Unhandled KIPN command-router error: " ..
            tostring(err)
        )

        ----------------------------------------------------
        -- Attempt to notify the client.
        --
        -- Do not allow an error while sending the error
        -- response to escape this final safety boundary.
        ----------------------------------------------------

        if player then

            local sendOk,
                sendErr =
                pcall(
                    KIPN.Server.SendToPlayer,
                    player,
                    KIPN.Shared.ResponseEvents.ERROR,
                    {
                        code =
                            "SERVER_COMMAND_ERROR",

                        command =
                            command,

                        message =
                            "KIPN server command processing failed."
                    }
                )

            if not sendOk then

                logError(
                    "Unable to send command-router error response: " ..
                    tostring(sendErr)
                )
            end
        end

        success =
            false

    else

        success =
            true
    end
end

------------------------------------------------------------
-- SERVER INITIALIZATION
------------------------------------------------------------
--
-- KIPN_Server is the server-side orchestrator.
--
-- Initialization is deliberately separated into two phases:
--
--   1. Load persistent data.
--   2. Load service modules.
--
-- Loading a module does NOT necessarily initialize it.
-- Explicit service initialization occurs after all required
-- modules have been loaded.
--
-- Initialization is guarded against:
--
--   * duplicate initialization
--   * re-entrant initialization
--
-- Current logging architecture:
--
--   KIPN.Logger.Log()
--   KIPN.Logger.Create()
------------------------------------------------------------

------------------------------------------------------------
-- SERVER INITIALIZATION
------------------------------------------------------------
local function initServer()

    local success =
        false



    --------------------------------------------------------
    -- DUPLICATE INITIALIZATION GUARD
    --------------------------------------------------------

    if KIPN.Server._initialized then


        success =
            true

    --------------------------------------------------------
    -- RE-ENTRANT INITIALIZATION GUARD
    --------------------------------------------------------

    elseif KIPN.Server._initializing then


        success =
            true

    else

        ----------------------------------------------------
        -- MARK INITIALIZATION IN PROGRESS
        ----------------------------------------------------

        KIPN.Server._initializing =
            true

        ----------------------------------------------------
        -- LOAD PERSISTENT DATA
        ----------------------------------------------------

        local data =
            loadKIPNData()

        if not data then

            logError(
                "KIPN server initialization failed: " ..
                "persistent data unavailable."
            )

        else


            ------------------------------------------------
            -- MODULE LOADING
            ------------------------------------------------

            local modulesLoaded =
                true

            local function requireServerModule(
                moduleName
            )


                local ok,
                    result =
                    pcall(
                        require,
                        moduleName
                    )

                if not ok then

                    logError(
                        "Failed to load server module " ..
                        tostring(moduleName) ..
                        ": " ..
                        tostring(result)
                    )

                    return false
                end


                return true
            end

            ------------------------------------------------
            -- CORE / REGISTRIES
            --
            -- NOTE: KIPN_UI.lua is a CLIENT-ONLY module. It must
            -- NOT be required here. Requiring it on the server
            -- always fails (no server/KIPN_UI.lua exists), which
            -- previously forced modulesLoaded=false and silently
            -- skipped registerCoreServiceCommands() entirely -
            -- every client command (including CHECK_POWER and
            -- SET_POWER) was rejected as "Unknown KIPN client
            -- command" as a result.
            ------------------------------------------------

            modulesLoaded =
                requireServerModule(
                    "KIPN_WorldRegistry"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_Permissions"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_ApplicationRegistry"
                )
                and modulesLoaded

            ------------------------------------------------
            -- CONFIGURATION
            ------------------------------------------------

            modulesLoaded =
                requireServerModule(
                    "/config/KIPN_AccountConfig"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "/config/KIPN_ComputerConfig"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "/config/KIPN_ArtifactConfig"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "/config/KIPN_CraftingRequirementsConfig"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "/config/KIPN_ClaimConfig"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_Config"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_Settings"
                )
                and modulesLoaded

            ------------------------------------------------
            -- DOMAIN SERVICES
            ------------------------------------------------

            modulesLoaded =
                requireServerModule(
                    "KIPN_ForecastService"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_TokenServer"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_Wallet"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_ClaimService"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_ClaimPermissions"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_AuthService"
                )
                and modulesLoaded

            modulesLoaded =
                requireServerModule(
                    "KIPN_AdminService"
                )
                and modulesLoaded

            ------------------------------------------------
            -- STOP IF MODULE LOAD FAILED
            ------------------------------------------------

            if not modulesLoaded then

                logError(
                    "KIPN server initialization failed: " ..
                    "one or more modules could not be loaded."
                )

            else


                ------------------------------------------------
                -- CORE COMMAND REGISTRATION
                ------------------------------------------------

                local coreCommandsOk =
                    registerCoreServiceCommands()

                ------------------------------------------------
                -- SERVICE INITIALIZATION
                ------------------------------------------------

                local worldRegistryOk =
                    initializeService(
                        "WorldRegistry",
                        KIPN.Server.WorldRegistry,
                        "Initialize"
                    )

                local permissionsOk =
                    initializeService(
                        "Permissions",
                        KIPN.Server.Permissions,
                        "Initialize"
                    )

                local applicationRegistryOk =
                    initializeService(
                        "ApplicationRegistry",
                        KIPN.Server.ApplicationRegistry,
                        "Initialize"
                    )

                -- Account policy / session limits from the KIPN sandbox
                -- page. (Historically this slot referenced a
                -- KIPN.Server.Config module that never existed, which
                -- forced initServer() to always report failure; the real
                -- orphaned initializer is AccountConfig's.)
                local accountConfigOk =
                    initializeService(
                        "AccountConfig",
                        KIPN.Server.AccountConfig,
                        "Initialize"
                    )

                local computerConfigOk =
                    initializeService(
                        "ComputerConfig",
                        KIPN.Server.ComputerConfig,
                        "Initialize"
                    )

                local claimConfigOk =
                    initializeService(
                        "ClaimConfig",
                        KIPN.Server.ClaimConfig,
                        "Initialize"
                    )

                local artifactConfigOk =
                    initializeService(
                        "ArtifactConfig",
                        KIPN.Server.ArtifactConfig,
                        "Initialize"
                    )

                local craftingRequirementsConfigOk =
                    initializeService(
                        "CraftingRequirementsConfig",
                        KIPN.Server.CraftingRequirementsConfig,
                        "Initialize"
                    )

                local settingsOk =
                    initializeService(
                        "Settings",
                        KIPN.Server.Settings,
                        "Initialize"
                    )

                ------------------------------------------------
                -- APPLY EFFECTIVE CONFIGURATION
                ------------------------------------------------

                local accountOk =
                    true

                local claimOk =
                    true

                local artifactOk =
                    true

                local computerOk =
                    true

                --------------------------------------------------------
                -- IMPORTANT -- EACH CALL IS INDIVIDUALLY PCALL-GUARDED.
                --
                -- Unlike the initializeService() calls around this
                -- block (each already exception-safe internally),
                -- these four ApplyToConfig() calls previously ran as
                -- plain, un-pcall'd statements. If any ONE of them
                -- threw (e.g. a config table not yet in the expected
                -- shape), the exception would propagate up and abort
                -- the REST of initServer() -- silently skipping every
                -- service registered after this point in the
                -- sequence (AdminService, ArtifactService,
                -- ClaimService, etc. further down), with no
                -- error surfaced anywhere except a bare stack trace
                -- in the server console. This is the same failure
                -- class already fixed once for
                -- AnnouncementService/SafehouseService's OnGameStart
                -- wiring -- one unguarded step upstream silently
                -- starving everything downstream.
                --------------------------------------------------------

                if KIPN.Server.Settings
                    and type(
                        KIPN.Server.Settings.ApplyToConfig
                    ) == "function"
                then

                    local accountApplyOk, accountApplyResult =
                        pcall(
                            KIPN.Server.Settings.ApplyToConfig,
                            "Account",
                            KIPN.Server.AccountConfig
                        )

                    accountOk =
                        accountApplyOk
                        and accountApplyResult ~= false

                    if not accountApplyOk then

                        logError(
                            "ApplyToConfig(\"Account\") threw: "
                            .. tostring(accountApplyResult)
                        )
                    end

                    local claimApplyOk, claimApplyResult =
                        pcall(
                            KIPN.Server.Settings.ApplyToConfig,
                            "Claim",
                            KIPN.Server.ClaimConfig
                        )

                    claimOk =
                        claimApplyOk
                        and claimApplyResult ~= false

                    if not claimApplyOk then

                        logError(
                            "ApplyToConfig(\"Claim\") threw: "
                            .. tostring(claimApplyResult)
                        )
                    end

                    local artifactApplyOk, artifactApplyResult =
                        pcall(
                            KIPN.Server.Settings.ApplyToConfig,
                            "Artifact",
                            KIPN.Server.ArtifactConfig
                        )

                    artifactOk =
                        artifactApplyOk
                        and artifactApplyResult ~= false

                    if not artifactApplyOk then

                        logError(
                            "ApplyToConfig(\"Artifact\") threw: "
                            .. tostring(artifactApplyResult)
                        )
                    end

                    local computerApplyOk, computerApplyResult =
                        pcall(
                            KIPN.Server.Settings.ApplyToConfig,
                            "Computer",
                            KIPN.Server.ComputerConfig
                        )

                    computerOk =
                        computerApplyOk
                        and computerApplyResult ~= false

                    if not computerApplyOk then

                        logError(
                            "ApplyToConfig(\"Computer\") threw: "
                            .. tostring(computerApplyResult)
                        )
                    end

                else

                end

                ------------------------------------------------
                -- PERSIST EFFECTIVE CONFIGURATION
                ------------------------------------------------

                data.configuration =
                    data.configuration
                    or {}

                data.configuration.account =
                    data.configuration.account
                    or {}

                data.configuration.claims =
                    data.configuration.claims
                    or {}

                data.configuration.artifacts =
                    data.configuration.artifacts
                    or {}

                data.configuration.computers =
                    data.configuration.computers
                    or {}

                for key, value in pairs(
                    KIPN.Server.AccountConfig
                    or {}
                ) do

                    data.configuration.account[
                        key
                    ] =
                        value
                end

                for key, value in pairs(
                    KIPN.Server.ClaimConfig
                    or {}
                ) do

                    data.configuration.claims[
                        key
                    ] =
                        value
                end

                for key, value in pairs(
                    KIPN.Server.ArtifactConfig
                    or {}
                ) do

                    data.configuration.artifacts[
                        key
                    ] =
                        value
                end

                for key, value in pairs(
                    KIPN.Server.ComputerConfig
                    or {}
                ) do

                    data.configuration.computers[
                        key
                    ] =
                        value
                end

                ------------------------------------------------
                -- LOG EFFECTIVE CONFIGURATION
                ------------------------------------------------

                if KIPN.Server.Settings
                    and type(
                        KIPN.Server.Settings.LogEffective
                    ) == "function"
                then

                    local okLog,
                        logResult =
                        pcall(
                            KIPN.Server.Settings.LogEffective
                        )

                    if not okLog then

                        logError(
                            "Settings.LogEffective() failed: " ..
                            tostring(logResult)
                        )
                    end
                end

                ------------------------------------------------
                -- DOMAIN SERVICE INITIALIZATION
                ------------------------------------------------

                local artifactServiceOk =
                    initializeService(
                        "ArtifactService",
                        KIPN.Server.ArtifactService,
                        "Initialize"
                    )

                local claimServiceOk =
                    initializeService(
                        "ClaimService",
                        KIPN.Server.ClaimService,
                        "Initialize"
                    )

                -- Depends on ClaimService (ClaimService.GetClaimAt/
                -- GetPlayerSteamId) and ClaimConfig (the per-service
                -- AllowNonOwner* fields) both being ready, so it is
                -- initialized immediately after ClaimService.
                local claimPermissionsOk =
                    initializeService(
                        "ClaimPermissions",
                        KIPN.Server.ClaimPermissions,
                        "Initialize"
                    )

                -- Materializes and persists the data.tokens domain up
                -- front. (Historically this slot referenced a
                -- KIPN.Server.TokenServer table that never existed -- the
                -- token API is the flat KIPN.Server.Token* functions, and
                -- its real initializer is InitializeTokenService.)
                local tokenServiceOk =
                    initializeService(
                        "TokenService",
                        { Initialize = KIPN.Server.InitializeTokenService },
                        "Initialize"
                    )

                local authServiceOk =
                    initializeService(
                        "AuthService",
                        KIPN.Server.AuthService,
                        "Initialize"
                    )

                local adminServiceOk =
                    initializeService(
                        "AdminService",
                        KIPN.Server.AdminService,
                        "Initialize"
                    )

                -- AnnouncementService.Initialize() was already
                -- required in the "SERVER SERVICES" module-loading
                -- section above (that section's own header comment
                -- documents that loading and initializing are meant
                -- to be separate steps), but was missing the
                -- initializeService() call every sibling service
                -- gets here -- its only wiring was a self-registered
                -- Events.OnGameStart.Add(), which -- like
                -- ApplicationRegistry's and SafehouseService's old
                -- wiring -- never fires server-side. That silently
                -- skipped command handler registration for
                -- GET_ANNOUNCEMENTS/ANNOUNCEMENT_SYNC, the
                -- ANNOUNCEMENT_ADMIN permission registration, and the
                -- Discord bridge OnTick poll hook, for the life of
                -- every server.
                local announcementServiceOk =
                    initializeService(
                        "AnnouncementService",
                        KIPN.Server.AnnouncementService,
                        "Initialize"
                    )

                local combatZoneServiceOk =
                    initializeService(
                        "CombatZoneService",
                        KIPN.Server.CombatZoneService,
                        "Initialize"
                    )

                -- SafehouseService moved to KIPN: Government Services
                -- (KIPN_SafehouseService.lua). Its Initialize() is now
                -- driven by that module's RegisterService entry.

                local leaderboardServiceOk =
                    initializeService(
                        "LeaderboardService",
                        KIPN.Server.LeaderboardService,
                        "Initialize"
                    )

                local statsServiceOk =
                    initializeService(
                        "StatsService",
                        KIPN.Server.StatsService,
                        "Initialize"
                    )

                local maintenanceServiceOk =
                    initializeService(
                        "MaintenanceService",
                        KIPN.Server.MaintenanceService,
                        "Initialize"
                    )

                ------------------------------------------------
                -- ADD-ON SERVICE MODULES
                --
                -- Companion mods (Government Services, Vehicle
                -- Services, ...) registered via
                -- KIPN.Server.RegisterService() at require() time.
                -- Initialized now, after every built-in service is
                -- ready, in their declared dependency order.
                ------------------------------------------------

                local registeredServicesOk =
                    KIPN.Server.RunRegisteredServices()

                ------------------------------------------------
                -- PERSIST FINAL SERVER STATE
                ------------------------------------------------

                local configurationSaved =
                    KIPN.Server.Save()

                ------------------------------------------------
                -- FINAL RESULT
                ------------------------------------------------

                success =
                    coreCommandsOk
                    and worldRegistryOk
                    and permissionsOk
                    and applicationRegistryOk
                    and accountConfigOk
                    and computerConfigOk
                    and claimConfigOk
                    and artifactConfigOk
                    and craftingRequirementsConfigOk
                    and settingsOk
                    and accountOk
                    and claimOk
                    and artifactOk
                    and computerOk
                    and artifactServiceOk
                    and claimServiceOk
                    and claimPermissionsOk
                    and tokenServiceOk
                    and authServiceOk
                    and adminServiceOk
                    and announcementServiceOk
                    and combatZoneServiceOk
                    and leaderboardServiceOk
                    and statsServiceOk
                    and maintenanceServiceOk
                    and registeredServicesOk
                    and configurationSaved

                ------------------------------------------------
                -- STARTUP DIAGNOSTICS
                ------------------------------------------------

                if KIPN.Server.Diagnostics
                    and type(
                        KIPN.Server.Diagnostics.ReportStartup
                    ) == "function"
                then

                    local diagnosticsOk,
                        diagnosticsResult =
                        pcall(
                            KIPN.Server.Diagnostics.ReportStartup,
                            {
                                persistentData =
                                    true,

                                accountConfig =
                                    accountOk,

                                claimConfig =
                                    claimOk,

                                artifactConfig =
                                    artifactOk,

                                computerConfig =
                                    computerOk,

                                settings =
                                    settingsOk,

                                artifactService =
                                    artifactServiceOk,

                                claimService =
                                    claimServiceOk,

                                tokenService =
                                    tokenServiceOk,

                                authService =
                                    authServiceOk,

                                adminService =
                                    adminServiceOk,

                                coreCommands =
                                    coreCommandsOk,

                                configurationPersisted =
                                    configurationSaved,

                                success =
                                    success,
                            }
                        )

                    if not diagnosticsOk then

                        logError(
                            "Startup diagnostics failed: " ..
                            tostring(diagnosticsResult)
                        )
                    end
                end

                ------------------------------------------------
                -- SERVER READY
                ------------------------------------------------

                if success then

                    KIPN.Server._initialized =
                        true


                else

                    KIPN.Server._initialized =
                        false

                    logError(
                        "KIPN server initialization failed: " ..
                        "one or more services/configuration steps failed."
                    )
                end
            end

            KIPN.Server._initializing =
                nil
        end
    end

    --------------------------------------------------------
    -- COMPLETE RUN
    --------------------------------------------------------


    return success
end

------------------------------------------------------------
-- COMPUTER AMBIENT SOUND SYNC (PERIODIC BROADCAST)
--
-- Runs on a timer, independent of any player interaction, so the
-- ambient "on" sound state is never tied to whoever happened to
-- flip the switch -- it is re-derived from persisted
-- computer.bootState on every tick and re-broadcast to everyone
-- currently online. This is what lets a player who joins
-- mid-session (or reconnects) pick up an already-on computer's
-- sound without walking up and interacting with it first, and
-- what catches an automatic power loss (a real electricity
-- outage) that no one explicitly requested -- this tick's
-- GetComputerBootState() calls exercise that function's own
-- OFF-reconciliation for every persisted computer, not just ones
-- a player happens to poll via the context menu.
--
-- COMPUTER_SOUND_SYNC carries the full current ON/BOOTING list,
-- every tick, so a client that missed a transition always
-- converges. COMPUTER_SOUND_ON/OFF are also fired here, but only
-- for computerIds whose effective state actually changed since
-- the last tick. Reconciliation ON events intentionally omit
-- playDialUp, because only the explicit context-menu power-on may
-- trigger that one-shot.
------------------------------------------------------------

local COMPUTER_SOUND_SYNC_INTERVAL_MS =
    15000

local lastComputerSoundSyncMs =
    0

local function runComputerSoundSyncTick()

    --------------------------------------------------------
    -- SHARED "ALREADY KNOWN ON" STATE
    --
    -- KIPN.Server._knownOnComputers is the SAME table
    -- handleSetPower() updates the moment it broadcasts
    -- COMPUTER_SOUND_ON/OFF for an explicit player-driven
    -- power toggle. Reading/writing that shared table here
    -- (instead of a tick-local one) is what stops this tick
    -- from re-broadcasting the same ON/OFF event a second time
    -- for a transition handleSetPower already announced.
    --------------------------------------------------------

    local lastKnownOnComputers =
        KIPN.Server._knownOnComputers or {}

    if type(getOnlinePlayers) ~=
        "function"
    then

        return
    end

    local okPlayers,
        onlinePlayers =
        pcall(
            getOnlinePlayers
        )

    if not okPlayers
        or not onlinePlayers
        or type(
            onlinePlayers.size
        ) ~= "function"
        or onlinePlayers:size() == 0
    then

        return
    end

    local data =
        KIPN.Server.GetData()

    if type(data) ~= "table"
        or type(data.computers) ~= "table"
    then

        return
    end

    local currentOnComputers =
        {}

    local syncList =
        {}

    -- Current Hardware Condition (0-100) for a computer, or nil if it
    -- cannot be resolved. Carried in the sound broadcasts so every
    -- nearby client can pick the clean vs. degraded ambient loop from
    -- live condition instead of only from its own last interaction.
    local function conditionForSound(computerId)

        local okProfile, profile =
            pcall(
                KIPN.Server.GetComputerProfile,
                computerId
            )

        if okProfile
            and type(profile) == "table"
            and type(profile.condition) == "number"
        then

            return profile.condition
        end

        return nil
    end

    for computerId, _ in pairs(
        data.computers
    ) do

        local bootState =
            KIPN.Server.GetComputerBootState(
                computerId
            )

        if bootState ==
                KIPN.Shared.BootStates.BOOTING
            or bootState ==
                KIPN.Shared.BootStates.ON
        then

            local x,
                y,
                z =
                KIPN.Shared.ParseComputerIdCoords(
                    computerId
                )

            currentOnComputers[
                computerId
            ] = {

                x = x,
                y = y,
                z = z,
            }

            if x then

                local condition =
                    conditionForSound(computerId)

                syncList[
                    #syncList + 1
                ] = {

                    computerId =
                        computerId,

                    x =
                        x,

                    y =
                        y,

                    z =
                        z,

                    -- Carried so a reconnecting client can seed
                    -- KIPN._bootStateCache from the periodic sync
                    -- snapshot and offer "Access KIP Network" on the
                    -- first right-click of an already-on computer.
                    bootState =
                        bootState,

                    -- Carried so the client's ambient loop tracks the
                    -- clean / degraded (<50%) sound tier from live
                    -- condition rather than only from a prior
                    -- interaction with this computer.
                    condition =
                        condition,
                }

                if not lastKnownOnComputers[
                    computerId
                ] then

                    KIPN.Server.BroadcastToAll(
                        KIPN.Shared.ResponseEvents.COMPUTER_SOUND_ON,
                        {
                            computerId =
                                computerId,

                            x =
                                x,

                            y =
                                y,

                            z =
                                z,

                            bootState =
                                bootState,

                            condition =
                                condition,
                        }
                    )
                end
            end
        end
    end

    for computerId, lastInfo in pairs(
        lastKnownOnComputers
    ) do

        if not currentOnComputers[
            computerId
        ] then

            emitComputerNoise(computerId)

            KIPN.Server.BroadcastToAll(
                KIPN.Shared.ResponseEvents.COMPUTER_SOUND_OFF,
                {
                    computerId =
                        computerId,

                    x =
                        lastInfo and lastInfo.x,

                    y =
                        lastInfo and lastInfo.y,

                    z =
                        lastInfo and lastInfo.z,

                    bootState =
                        KIPN.Shared.BootStates.OFF,
                }
            )
        end
    end

    KIPN.Server._knownOnComputers =
        currentOnComputers

    KIPN.Server.BroadcastToAll(
        KIPN.Shared.ResponseEvents.COMPUTER_SOUND_SYNC,
        {
            computers =
                syncList,
        }
    )
end

local lastComputerNoiseMs = 0

local function runComputerNoiseTick()
    local data = KIPN.Server.GetData()
    if not data or type(data.computers) ~= "table" then return end

    for computerId, computer in pairs(data.computers) do
        if computer.power == true
            and KIPN.Server.CheckBuildingPower(computerId) == true
        then
            local state = KIPN.Server.GetComputerBootState(computerId)
            if state == KIPN.Shared.BootStates.BOOTING
                or state == KIPN.Shared.BootStates.ON
            then
                emitComputerNoise(computerId)
            end
        end
    end
end

local function onComputerSoundSyncTick()

    if not _G.getTimestampMs then

        return
    end

    local now =
        getTimestampMs()

    -- Refresh the operating hum's zombie noise independently of the
    -- slower multiplayer audio snapshot. No terminal user is required.
    if now - lastComputerNoiseMs >= 2000 then
        lastComputerNoiseMs = now
        local ok, err = pcall(runComputerNoiseTick)
        if not ok then
            logError("Computer zombie noise failed: " .. tostring(err))
        end
    end

    if now - lastComputerSoundSyncMs <
        COMPUTER_SOUND_SYNC_INTERVAL_MS
    then

        return
    end

    lastComputerSoundSyncMs =
        now

    local ok, err =
        pcall(
            runComputerSoundSyncTick
        )

    if not ok then

        logError(
            "onComputerSoundSyncTick failed: " ..
            tostring(err)
        )
    end
end

------------------------------------------------------------
-- COMPUTER CONDITION TICK
--
-- Applies natural (time-based) Computer Condition degradation to
-- every registered computer, regardless of power state, and rolls
-- tiered random power-off events for computers that are currently
-- ON. Runs on its own throttle, kept separate from the ambient
-- sound-sync tick above -- degradation is measured in in-game
-- hours, so a coarser real-time cadence is sufficient here.
------------------------------------------------------------

local COMPUTER_CONDITION_TICK_INTERVAL_MS =
    60000

local lastComputerConditionTickMs =
    0

-- Base chance-per-check (per COMPUTER_CONDITION_TICK_INTERVAL_MS
-- tick) at sandbox multiplier = 1.0x (raw sandbox value 10). Tier 4
-- is fixed and not sandbox-adjustable.
local CONDITION_TIER1_BASE_CHANCE =
    0.0005

local CONDITION_TIER2_BASE_CHANCE =
    0.004

local CONDITION_TIER3_BASE_CHANCE =
    0.03

local CONDITION_TIER4_BASE_CHANCE =
    0.08

local function resolveConditionTier(
    condition
)

    if condition >= 60 then

        return 1,
            CONDITION_TIER1_BASE_CHANCE
    end

    if condition >= 50 then

        return 2,
            CONDITION_TIER2_BASE_CHANCE
    end

    if condition >= 30 then

        return 3,
            CONDITION_TIER3_BASE_CHANCE
    end

    if condition >= CONDITION_POWER_OFF_REFUSAL_THRESHOLD then

        return 4,
            CONDITION_TIER4_BASE_CHANCE
    end

    return nil,
        0
end

local function getConditionTierMultiplier(
    tier
)

    local cc =
        KIPN.Server.ComputerConfig

    if not cc then

        return 0
    end

    if tier == 1 then

        return (cc.ComputerConditionPowerOffTier1Multiplier or 0) / 10.0
    end

    if tier == 2 then

        return (cc.ComputerConditionPowerOffTier2Multiplier or 0) / 10.0
    end

    if tier == 3 then

        return (cc.ComputerConditionPowerOffTier3Multiplier or 0) / 10.0
    end

    -- Tier 4: always full chance, not sandbox-adjustable.
    return 1.0
end

local function rollConditionChance(
    chance
)

    if chance <= 0 then

        return false
    end

    local roll

    if type(ZombRand) == "function" then

        roll = ZombRand(1000000)

    else

        roll = math.random(0, 999999)
    end

    return roll < math.floor(chance * 1000000)
end

local function runComputerConditionTick()

    local data =
        KIPN.Server.GetData()

    if type(data) ~= "table"
        or type(data.computers) ~= "table"
        or type(data.computerProfiles) ~= "table"
    then

        return
    end

    local cc =
        KIPN.Server.ComputerConfig

    if not cc then

        return
    end

    local nowWorldHours =
        nil

    if type(getGameTime) == "function" then

        local okTime,
            gameTime =
            pcall(getGameTime)

        if okTime
            and gameTime
            and type(gameTime.getWorldAgeHours) == "function"
        then

            local okAge,
                age =
                pcall(
                    function()

                        return gameTime:getWorldAgeHours()
                    end
                )

            if okAge then

                nowWorldHours =
                    age
            end
        end
    end

    local naturalMultiplierPercent =
        cc.ComputerConditionNaturalDegradationMultiplier or 0

    local timeFrameKey =
        KIPN.Shared.ComputerConditionTimeFrameOrder
        and KIPN.Shared.ComputerConditionTimeFrameOrder[
            cc.ComputerConditionNaturalDegradationTimeFrame or 2
        ]

    local timeFrameHours =
        (
            timeFrameKey
            and KIPN.Shared.ComputerConditionTimeFrameHours
            and KIPN.Shared.ComputerConditionTimeFrameHours[timeFrameKey]
        )
        or (365 * 24)

    local anyChanged =
        false

    for computerId, computer in pairs(data.computers) do

        if type(computer) == "table" then

            local profile =
                computer.hardwareProfileId
                and data.computerProfiles[computer.hardwareProfileId]

            if type(profile) == "table" then

                ------------------------------------------------
                -- NATURAL DEGRADATION (power-independent)
                ------------------------------------------------

                if naturalMultiplierPercent > 0
                    and nowWorldHours ~= nil
                then

                    local lastCheck =
                        profile.lastConditionCheckWorldHours
                        or nowWorldHours

                    local elapsedHours =
                        nowWorldHours - lastCheck

                    if elapsedHours > 0 then

                        local degradation =
                            (elapsedHours / timeFrameHours)
                            * naturalMultiplierPercent

                        profile.condition =
                            math.max(
                                0,
                                (profile.condition or 100) - degradation
                            )

                        profile.lastConditionCheckWorldHours =
                            nowWorldHours

                        anyChanged =
                            true
                    end

                elseif nowWorldHours ~= nil
                    and profile.lastConditionCheckWorldHours == nil
                then

                    -- Keep the watermark advancing even while
                    -- natural degradation is disabled, so enabling
                    -- it later doesn't apply one huge retroactive
                    -- lump sum for time it was off.
                    profile.lastConditionCheckWorldHours =
                        nowWorldHours

                    anyChanged =
                        true
                end

                ------------------------------------------------
                -- TIERED RANDOM POWER-OFF (only while ON)
                ------------------------------------------------

                local bootState =
                    KIPN.Server.GetComputerBootState(
                        computerId
                    )

                if bootState == KIPN.Shared.BootStates.ON then

                    local tier,
                        baseChance =
                        resolveConditionTier(
                            profile.condition or 100
                        )

                    if tier then

                        local effectiveChance =
                            baseChance
                            * getConditionTierMultiplier(tier)

                        if rollConditionChance(effectiveChance) then

                            KIPN.Server.SetComputerPower(
                                computerId,
                                false
                            )
                        end
                    end
                end
            end
        end
    end

    if anyChanged then

        saveKIPNData()
    end
end

local function onComputerConditionTick()

    if not _G.getTimestampMs then

        return
    end

    local now =
        getTimestampMs()

    if now - lastComputerConditionTickMs <
        COMPUTER_CONDITION_TICK_INTERVAL_MS
    then

        return
    end

    lastComputerConditionTickMs =
        now

    local ok, err =
        pcall(
            runComputerConditionTick
        )

    if not ok then

        logError(
            "onComputerConditionTick failed: " ..
            tostring(err)
        )
    end
end

------------------------------------------------------------
-- MODULE STATE
------------------------------------------------------------

KIPN.Server._loaded =
    true

------------------------------------------------------------
-- EVENT REGISTRATION
------------------------------------------------------------

if Events
    and Events.OnClientCommand
    and type(
        Events.OnClientCommand.Add
    ) == "function"
then

    Events.OnClientCommand.Add(
        safeOnClientCommand
    )


else

    logError(
        "Unable to register OnClientCommand handler."
    )
end

if Events
    and Events.OnTick
    and type(
        Events.OnTick.Add
    ) == "function"
then

    Events.OnTick.Add(
        onComputerSoundSyncTick
    )

    Events.OnTick.Add(
        onComputerConditionTick
    )


else

    logError(
        "Unable to register OnTick handler for " ..
        "computer sound sync."
    )
end

if Events
    and Events.OnGameStart
    and type(
        Events.OnGameStart.Add
    ) == "function"
then

    Events.OnGameStart.Add(
        initServer
    )


else

    logError(
        "Unable to register OnGameStart handler."
    )
end

------------------------------------------------------------
-- GLOBAL MOD DATA INITIALIZATION
--
-- Events.OnInitGlobalModData is the vanilla server-side event
-- that fires once the engine's global ModData store is actually
-- ready to be read/written for the current save -- it is the
-- officially-safe point to call ModData.getOrCreate() for global
-- (non-object-bound) persistent data. Vanilla's own
-- ProfessionVehicles.lua loads its global ModData from this exact
-- event for this exact reason.
--
-- Previously KIPN only initialized via the unconditional
-- "isServer() then initServer() end" call below, which runs at
-- raw Lua chunk-load time -- i.e. during mod script loading,
-- BEFORE the engine's global ModData store for the save is
-- confirmed ready. Calling ModData.getOrCreate(DATA_TAG) that
-- early can bind KIPN.Server.Data to a table that is never
-- correctly attached to the save being loaded: every read/write
-- for the rest of that server process stays internally
-- consistent (it's all hitting the same in-memory table), so
-- everything appears to work, but none of it is actually
-- persisted. That is what was causing registered accounts (and
-- all other KIPN state) to disappear on the next server restart.
------------------------------------------------------------

local registeredOnInitGlobalModData = false

if Events
    and Events.OnInitGlobalModData
    and type(
        Events.OnInitGlobalModData.Add
    ) == "function"
then

    Events.OnInitGlobalModData.Add(
        initServer
    )

    registeredOnInitGlobalModData = true


else

    logError(
        "Unable to register OnInitGlobalModData handler."
    )

end

------------------------------------------------------------
-- FALLBACK DIRECT SERVER INITIALIZATION
--
-- Events.OnGameStart is a CLIENT lifecycle event. It does not
-- fire in the server Lua context (single-player's embedded
-- server included), so the OnGameStart registration above never
-- actually calls initServer() there. Confirmed empirically: no
-- initServer/registerCoreServiceCommands/RegisterCommandHandler
-- entry ever appears in the server debug log for an entire play
-- session, even though every client command handler
-- (CHECK_POWER, SET_POWER, everything) depends on it having run.
--
-- initServer() is idempotent (guarded by KIPN.Server._initialized
-- / KIPN.Server._initializing above), so calling it here
-- unconditionally at server-chunk-load time would normally be
-- safe even if some server variant DOES fire OnGameStart later.
--
-- BUT: if OnInitGlobalModData registered successfully above,
-- initServer() must be left to run from THAT event instead, so
-- KIPN.Server.Data binds to the engine's actual persistent
-- ModData store rather than a premature, disconnected one. Since
-- initServer() is guarded against re-entry, calling it here too
-- early would set KIPN.Server._initialized and permanently block
-- the correctly-timed OnInitGlobalModData call from ever running.
-- This is therefore only a last resort for the (currently
-- theoretical) case where OnInitGlobalModData itself is
-- unavailable.
------------------------------------------------------------

if isServer()
    and not registeredOnInitGlobalModData
then

    initServer()

end

------------------------------------------------------------
-- MODULE LOAD COMPLETE
------------------------------------------------------------


print(
    "[KIPN] Server loaded"
)
