-- KIPN_Shared.lua
--
-- Shared KIPN contracts and lightweight helpers.
--
-- DEPENDENCY:
--
--   KIPN_Logger.lua
--       ↓
--   KIPN_Shared.lua
--
-- KIPN_Logger establishes the KIPN namespace and KIPN.Logger.
--
-- KIPN_Shared then defines the contracts that are shared by
-- client and server systems.
--
-- IMPORTANT:
--
-- This file does NOT load KIPN_Logger.lua itself.
--
-- The bootstrap/orchestrator is responsible for loading dependencies
-- in the correct order using require().
--
-- KIPN_Shared is responsible ONLY for definitions and helpers that
-- are legitimately shared by client and server.
--
-- Shared owns:
--   * KIPN command identifiers
--   * KIPN response identifiers
--   * permissions
--   * capabilities
--   * application identifiers
--   * domain constants
--   * protocol constants
--   * lightweight context/identifier helpers
--
-- Shared does NOT own:
--   * persistent server data
--   * server database/schema
--   * migrations
--   * authentication
--   * authorization evaluation
--   * sessions
--   * computer registry
--   * player registry
--   * server configuration
--   * server lifecycle
--   * generic event infrastructure
--   * KIPN's internal event implementation
--
-- IMPORTANT:
--
-- Persistent/authoritative data belongs in KIPN_Server.lua and its
-- service modules.
--
-- This file must remain safe to load on both client and server.

--------------------------------------------------------------------
-- CORE DEPENDENCY CHECK
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_SHARED] "
        .. "KIPN core is not initialized."
    )
end

--------------------------------------------------------------------
-- LOGGER DEPENDENCY CHECK
--
-- KIPN_Shared uses KIPN.Logger for its own diagnostics.
--
-- Logger MUST therefore have been loaded before Shared.
--
-- We intentionally do NOT call require() here.
--
-- Dependency ordering belongs to the bootstrap layer, not to the
-- shared contract layer.
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN_SHARED] "
        .. "KIPN.Logger is not initialized. "
        .. "KIPN_Logger.lua must be loaded before "
        .. "KIPN_Shared.lua."
    )
end

--------------------------------------------------------------------
-- SHARED NAMESPACE
--------------------------------------------------------------------

KIPN.Shared =
    KIPN.Shared or {}

--------------------------------------------------------------------
-- COMMAND CONSTANTS
--
-- These are KIPN's client/server protocol identifiers.
--
-- They are intentionally NOT generic Starlit events.
--
-- Client -> server:
--     sendClientCommand(...)
--
-- Server -> client:
--     sendServerCommand(...)
--
-- The actual routing/authority remains outside this file.
--------------------------------------------------------------------

KIPN.Shared.Commands = {

    ------------------------------------------------------------
    -- PROPERTY
    ------------------------------------------------------------

    GET_PROPERTIES = "getProperties",
    GET_SERVER_STATS = "getServerStats",

    CLAIM_PROPERTY = "claimProperty",

    ISSUE_VEHICLE_CLAIM = "issueVehicleClaim",
    CLAIM_VEHICLE = "claimVehicle",

    ------------------------------------------------------------
    -- OWNERSHIP RECORDS
    --
    -- GET_MY_CLAIMS is the caller-scoped replacement for the
    -- never-implemented GET_PROPERTIES: it returns the requesting
    -- player's own property, excavation, and vehicle claim
    -- records together (PROPERTIES_DATA is left defined above but
    -- unused rather than deleted).
    --
    -- CLAIM_EXCAVATION mirrors CLAIM_PROPERTY: the player presents
    -- a consumed Excavation Claim artifact at the target location
    -- and asks the server to establish an excavation ownership
    -- record.
    ------------------------------------------------------------

    GET_MY_CLAIMS = "getMyClaims",
    CLAIM_EXCAVATION = "claimExcavation",

    -- RELEASE_CLAIM lets a player voluntarily give up one of
    -- their own active claims (see KIPN_PropertyRecords.lua's
    -- "RELEASE" row action) -- self-service only; identity is
    -- always resolved server-side and a player may only ever
    -- release a claim they themselves own. This is the only
    -- release path in KIPN: KIPN_ClaimService.ReleaseClaim() was
    -- previously reachable only via lazy ownership-expiry checks,
    -- with no player-facing way to free up a claim slot early.
    RELEASE_CLAIM = "releaseClaim",

    -- Legacy Build 42 client-release handshake names. Retained so an older
    -- client fails compatibly during a rolling update, but current KIPN does
    -- not authorize sendSafehouseRelease(); safehouse lifecycle is committed
    -- directly by the authoritative server.
    SAFEHOUSE_RELEASE_AUTHORIZED = "safehouseReleaseAuthorized",
    CONFIRM_SAFEHOUSE_RELEASE = "confirmSafehouseRelease",
    RECONCILE_SAFEHOUSE_CLAIMS = "reconcileSafehouseClaims",

    -- KIPN-owned safehouse lifecycle. RELEASE_SAFEHOUSE is used by the
    -- vanilla safehouse panel wrapper and names the exact engine rectangle.
    -- SAFEHOUSE_PROJECTION_SYNC explicitly mirrors authoritative add/remove
    -- changes into connected clients' local Java SafeHouse lists.
    RELEASE_SAFEHOUSE = "releaseSafehouse",
    SAFEHOUSE_PROJECTION_SYNC = "safehouseProjectionSync",

    ------------------------------------------------------------
    -- GOVERNMENT SERVICES
    --
    -- ISSUE_PROPERTY_CLAIM / ISSUE_EXCAVATION_CLAIM mirror
    -- ISSUE_VEHICLE_CLAIM: the player presents a Registration
    -- item at a Government Building computer and asks the
    -- server to convert it into a claim artifact (Safehouse
    -- Deed / Excavation Permit).
    --
    -- GET_CRAFTING_REQUIREMENTS is a public, read-only request for
    -- the "items required to craft a Registration Form" reference
    -- list shown on the Government Services desk. (Served by KIPN:
    -- Government Services; the recipes themselves live in that mod's
    -- media/scripts and are not runtime-configurable.)
    ------------------------------------------------------------

    ISSUE_PROPERTY_CLAIM = "issuePropertyClaim",
    ISSUE_EXCAVATION_CLAIM = "issueExcavationClaim",

    GET_CRAFTING_REQUIREMENTS = "getCraftingRequirements",

    ------------------------------------------------------------
    -- EXCAVATION SIZE TIERS
    --
    -- GET_EXCAVATION_SIZE_TIERS is a public, read-only request for
    -- the Sandbox-configured list of purchasable excavation claim
    -- sizes (label/widthTiles/heightTiles/price). Served by KIPN:
    -- Government Services.
    ------------------------------------------------------------

    GET_EXCAVATION_SIZE_TIERS = "getExcavationSizeTiers",

    ------------------------------------------------------------
    -- ANNOUNCEMENTS
    --
    -- GET_ANNOUNCEMENTS:
    --     Client -> server. Fetch the current merged announcement
    --     list (Discord bridge + admin-posted). Any authenticated
    --     player may call this; it is read-only.
    --
    -- ANNOUNCEMENT_SYNC:
    --     Client -> server. Admin-only mutation. Payload carries
    --     { action = "post", text = "..." } or { action = "clear" }.
    --
    --     This identifier is ALSO used as the server -> client
    --     response event (KIPN.Shared.ResponseEvents.ANNOUNCEMENT_SYNC)
    --     carrying the current announcement list. Commands and
    --     response events are separate dispatch tables, so reusing
    --     the string is unambiguous, but do not confuse the two
    --     directions when reading call sites.
    ------------------------------------------------------------

    GET_ANNOUNCEMENTS = "getAnnouncements",

    ANNOUNCEMENT_SYNC = "announcementSync",

    ------------------------------------------------------------
    -- COMPUTER / POWER
    ------------------------------------------------------------

    CHECK_POWER = "checkPower",
    SET_POWER = "setPower",
    GET_COMPUTER_INFO = "getComputerInfo",
    DISASSEMBLE_COMPUTER = "disassembleComputer",
    REPAIR_COMPUTER = "repairComputer",

    ------------------------------------------------------------
    -- BBS MENU
    --
    -- The main menu is server-driven: GET_APPLICATIONS asks the
    -- ApplicationRegistry which programs this player should see at
    -- this computer; APPLICATIONS_DATA carries the answer.
    ------------------------------------------------------------

    GET_APPLICATIONS = "getApplications",

    ------------------------------------------------------------
    -- TOKEN SYSTEM
    ------------------------------------------------------------

    TOKEN_INSPECT = "inspectToken",

    ------------------------------------------------------------
    -- PLAYER DATA
    ------------------------------------------------------------

    GET_PLAYER_DATA = "getPlayerData",
    SAVE_PLAYER_DATA = "savePlayerData",

    ------------------------------------------------------------
    -- ONLINE PLAYERS
    ------------------------------------------------------------

    GET_ONLINE_PLAYERS = "getOnlinePlayers",
    ONLINE_PLAYERS = "onlinePlayers",

    ------------------------------------------------------------
    -- LEADERBOARD
    ------------------------------------------------------------

    GET_LEADERBOARD = "getLeaderboard",

    ------------------------------------------------------------
    -- STATS
    --
    -- GET_MY_STATS is the caller-scoped counterpart to
    -- GET_LEADERBOARD: it returns the requesting player's own
    -- full stat row (see KIPN.Shared.StatsCatalog), combining
    -- Tier A fields read live off the player object with the
    -- persisted Tier B fields from KIPN.Server.GetData().playerStats.
    --
    -- SUBMIT_STATS_DELTA is sent periodically by
    -- KIPN_StatsTracker.lua (client) to flush accumulated Tier B
    -- stat deltas/peaks for merging into the same persisted row.
    ------------------------------------------------------------

    GET_MY_STATS = "getMyStats",
    SUBMIT_STATS_DELTA = "submitStatsDelta",

    ------------------------------------------------------------
    -- WEATHER
    ------------------------------------------------------------

    GET_FORECAST = "getForecast",
    GET_LOGIN_FORECAST = "getLoginForecast",

    ------------------------------------------------------------
    -- SERVER MODE
    ------------------------------------------------------------

    GET_MODE = "getMode",
    SET_MODE = "setMode",

    GET_PLAYER_MODE = "getPlayerMode",
    SET_PLAYER_MODE = "setPlayerMode",

    ------------------------------------------------------------
    -- BBS
    ------------------------------------------------------------

    OPEN_BBS = "openBBS",

    ------------------------------------------------------------
    -- SERVER STATISTICS
    ------------------------------------------------------------

    SERVER_STATS = "serverStats",

    ------------------------------------------------------------
    -- SERVER STATUS
    --
    -- Returns comprehensive service availability and computer
    -- boot timing (baudRate, bootDurationMs). The boot screen
    -- uses this for each diagnostic stage.
    ------------------------------------------------------------

    GET_SERVER_STATUS = "getServerStatus",

    ------------------------------------------------------------
    -- SERVER RESPONSE TRANSPORT
    --
    -- This is the actual PZ network command used by KIPN's
    -- server -> client response transport.
    --
    -- It is NOT a Starlit LuaEvent.
    ------------------------------------------------------------

    SERVER_RESPONSE = "serverResponse",
}

--------------------------------------------------------------------
-- RESPONSE IDENTIFIERS
--
-- These are protocol identifiers carried through KIPN's response
-- transport.
--
-- They are NOT events themselves.
--
-- Server responses are transported through:
--
--     KIPN.Shared.Commands.SERVER_RESPONSE
--
-- The response identifier is carried inside the response payload.
--
-- These identifiers are contracts only.
-- They do NOT perform routing, authorization, or state changes.
--------------------------------------------------------------------

KIPN.Shared.ResponseEvents = {

    ------------------------------------------------------------
    -- PLAYER
    ------------------------------------------------------------

    PLAYER_DATA =
        "playerData",

    ------------------------------------------------------------
    -- MODE
    ------------------------------------------------------------

    MODE_DATA =
        "modeData",

    ------------------------------------------------------------
    -- ERRORS
    ------------------------------------------------------------

    ERROR =
        "error",

    ------------------------------------------------------------
    -- COMPUTER / POWER
    ------------------------------------------------------------

    POWER_STATUS =
        "powerStatus",

    COMPUTER_CONDITION_UPDATED =
        "computerConditionUpdated",

    ------------------------------------------------------------
    -- COMPUTER AMBIENT SOUND (SERVER-BROADCAST)
    --
    -- Unlike POWER_STATUS (sent only to the requesting player),
    -- these are fanned out to EVERY online player via
    -- KIPN.Server.BroadcastToAll() so the looping "on" hum and a
    -- dial-up tone caused by an explicit context-menu power-on are
    -- heard by anyone nearby, not just whoever flipped the switch.
    -- See KIPN_Interaction.lua's COMPUTER_SOUND_* handling in
    -- onComputerSoundResponse().
    --
    -- COMPUTER_SOUND_ON / COMPUTER_SOUND_OFF fire immediately on a
    -- genuine transition (data: computerId, x, y, z for ON, plus
    -- playDialUp=true only for explicit SET_POWER on requests;
    -- computerId for OFF).
    --
    -- COMPUTER_SOUND_SYNC is a periodic full snapshot of every
    -- currently ON/BOOTING computer (data: computers = array of
    -- {computerId, x, y, z}), broadcast on a timer so a client that
    -- missed a transition -- because it joined after the fact, or
    -- dropped the packet -- still converges on the correct ambient
    -- state without needing a fresh manual interaction. This is
    -- what makes the sound "persist with the life of the server"
    -- rather than with any one player's session.
    ------------------------------------------------------------

    COMPUTER_SOUND_ON =
        "computerSoundOn",

    COMPUTER_SOUND_OFF =
        "computerSoundOff",

    COMPUTER_SOUND_SYNC =
        "computerSoundSync",

    BBS_AVAILABLE =
        "bbsAvailable",

    COMPUTER_INFO =
        "computerInfo",

    -- Server-driven main menu: reply to GET_APPLICATIONS.
    APPLICATIONS_DATA =
        "applicationsData",

    ------------------------------------------------------------
    -- TOKEN SYSTEM
    --
    -- Token operations remain server authoritative.
    --
    -- These identifiers describe responses transported back
    -- through the standard KIPN response channel.
    ------------------------------------------------------------

    TOKEN_DATA =
        "tokenData",

    TOKEN_VALID =
        "tokenValid",

    TOKEN_INVALID =
        "tokenInvalid",

    TOKEN_ISSUED =
        "tokenIssued",

    TOKEN_CONSUMED =
        "tokenConsumed",

    TOKEN_INVALIDATED =
        "tokenInvalidated",

    TOKEN_EXPIRED =
        "tokenExpired",

    TOKEN_ERROR =
        "tokenError",

    TOKEN_INSPECTION =
        "tokenInspection",

    ------------------------------------------------------------
    -- WEATHER
    ------------------------------------------------------------

    FORECAST_DATA =
        "forecastData",

    LOGIN_FORECAST =
        "loginForecast",

    ------------------------------------------------------------
    -- SERVER
    ------------------------------------------------------------

    SERVER_STATS =
        "serverStats",

    ------------------------------------------------------------
    -- SERVER STATUS
    --
    -- Carried through KIPN's standard response transport.
    -- Contains per-service availability and computer boot timing.
    ------------------------------------------------------------

    SERVER_STATUS =
        "serverStatus",

    ------------------------------------------------------------
    -- PLAYERS
    ------------------------------------------------------------

    ONLINE_PLAYERS =
        "onlinePlayers",

    ------------------------------------------------------------
    -- LEADERBOARD
    ------------------------------------------------------------

    LEADERBOARD_DATA =
        "leaderboardData",

    ------------------------------------------------------------
    -- STATS
    ------------------------------------------------------------

    MY_STATS_DATA =
        "myStatsData",

    ------------------------------------------------------------
    -- PROPERTIES
    ------------------------------------------------------------

    PROPERTIES_DATA =
        "propertiesData",

    ------------------------------------------------------------
    -- OWNERSHIP RECORDS
    --
    -- See KIPN.Shared.Commands.GET_MY_CLAIMS / CLAIM_EXCAVATION
    -- for the request-side documentation.
    ------------------------------------------------------------

    MY_CLAIMS_DATA =
        "myClaimsData",

    EXCAVATION_CLAIM_SUCCESSFUL =
        "excavationClaimSuccessful",

    ------------------------------------------------------------
    -- VEHICLE CLAIMS
    ------------------------------------------------------------

    VEHICLE_CLAIM_ARTIFACT_ISSUED =
        "vehicleClaimArtifactIssued",

    VEHICLE_CLAIM_SUCCESSFUL =
        "vehicleClaimSuccessful",

    ------------------------------------------------------------
    -- GOVERNMENT SERVICES
    ------------------------------------------------------------

    PROPERTY_CLAIM_ARTIFACT_ISSUED =
        "propertyClaimArtifactIssued",

    PROPERTY_CLAIM_SUCCESSFUL =
        "propertyClaimSuccessful",

    EXCAVATION_CLAIM_ARTIFACT_ISSUED =
        "excavationClaimArtifactIssued",

    CRAFTING_REQUIREMENTS_DATA =
        "craftingRequirementsData",

    EXCAVATION_SIZE_TIERS_DATA =
        "excavationSizeTiersData",

    ------------------------------------------------------------
    -- ANNOUNCEMENTS
    ------------------------------------------------------------

    ANNOUNCEMENT_SYNC =
        "announcementSync",
}

--------------------------------------------------------------------
-- SERVER-AUTHORITATIVE COMPUTER BOOT STATES
--
-- These are state identifiers only.
--
-- The server decides which state a computer is actually in.
--
-- This table does NOT perform state transitions.
--------------------------------------------------------------------

KIPN.Shared.BootStates = {

    OFF =
        "OFF",

    BOOTING =
        "BOOTING",

    ON =
        "ON",
}

--------------------------------------------------------------------
-- COMPUTER CONDITION
--
-- Index -> meaning lookups for the two KIPN.ComputerCondition*
-- sandbox enums (ComputerConditionInitial, ComputerConditionNatural-
-- DegradationTimeFrame). Convention: sandbox index N -> Order[N].
--------------------------------------------------------------------

KIPN.Shared.ComputerConditionPresetOrder = {
    "GOOD", "NORMAL", "BAD",
}

KIPN.Shared.ComputerConditionTimeFrameOrder = {
    "1_MONTH", "1_YEAR", "5_YEARS",
}

-- In-game hours represented by each ComputerConditionTimeFrameOrder entry.
KIPN.Shared.ComputerConditionTimeFrameHours = {
    ["1_MONTH"] = 30 * 24,
    ["1_YEAR"] = 365 * 24,
    ["5_YEARS"] = 5 * 365 * 24,
}

--------------------------------------------------------------------
-- PERSISTENT DATA SCHEMA VERSION
--
-- This is the version identifier shared by the server's
-- persistence system and any code that needs to know the current
-- contract.
--
-- The actual schema remains owned by KIPN_Server.
--------------------------------------------------------------------

KIPN.Shared.SCHEMA_VERSION =
    1

--------------------------------------------------------------------
-- SERVICE-MODULE API VERSION
--------------------------------------------------------------------
--
-- The contract version for the third-party service-module API
-- (RegisterService, RegisterClaimType, RegisterZoneType,
-- RegisterArtifactType, RegisterDataDomain, RegisterPermission, the
-- KIPN.Shared.RegisterX wire helpers, ApplicationRegistry.Register,
-- the KIPN_Wallet calls, KIPN.UI.CreateScreen). This is NOT the
-- persistent-data schema version above and NOT the Workshop mod
-- version -- it moves only when the shape of one of those APIs
-- changes in a way a companion mod could notice.
--
--   API_VERSION     -- the contract this KIPN build implements.
--   API_MIN_COMPAT  -- the oldest contract this build still accepts
--                      from a companion mod. Raise it only when
--                      support for an old contract is actually
--                      removed.
--
-- Companion mods: declare the version you were built against as
-- `apiVersion` on your RegisterService{} def, and/or gate your init
-- file with KIPN.API.Require(n). See README-SERVICE-API.md.
--------------------------------------------------------------------

KIPN.Shared.API_VERSION = 1
KIPN.Shared.API_MIN_COMPAT = 1

--------------------------------------------------------------------
-- KIPN.API  --  stable façade for companion service mods
--------------------------------------------------------------------
--
-- Loaded with KIPN_Shared (before any service module, both realms),
-- so a companion mod's very first line can call KIPN.API.Require().
--
--   KIPN.API.Version           -> number   (== API_VERSION)
--   KIPN.API.MinCompat         -> number   (== API_MIN_COMPAT)
--   KIPN.API.Require(minVer)   -> true | (false, reason)
--       "I need at least contract minVer". false if this KIPN is
--       older than minVer, or if minVer is below this build's compat
--       floor. A companion mod typically `return`s early on false.
--   KIPN.API.IsCompatible(ver) -> true | (false, reason)
--       non-fatal variant used by RegisterService; same checks,
--       returns the reason string for logging.
--   KIPN.API.Has(feature)      -> boolean
--       static capability probe -- feature-detect instead of
--       version-sniff so the API can grow without a version bump for
--       every addition.
--------------------------------------------------------------------

KIPN = KIPN or {}
KIPN.API = KIPN.API or {}

KIPN.API.Version = KIPN.Shared.API_VERSION
KIPN.API.MinCompat = KIPN.Shared.API_MIN_COMPAT

-- Capabilities this KIPN build exposes to companion mods. Add a key
-- here when a new registration surface ships; a companion can then
-- KIPN.API.Has("thatKey") without caring about version numbers.
KIPN.API._features = {
    services            = true,   -- KIPN.Server.RegisterService
    dataDomains         = true,   -- KIPN.Server.RegisterDataDomain
    commandHandlers     = true,   -- KIPN.Server.RegisterCommandHandler
    wireNames           = true,   -- KIPN.Shared.RegisterCommand / ...
    zoneTypes           = true,   -- WorldRegistry.RegisterZoneType
    claimTypes          = true,   -- ClaimService.RegisterClaimType
    claimConfig         = true,   -- ClaimConfig.RegisterService
    artifactTypes       = true,   -- ArtifactService.RegisterArtifactType
    permissions         = true,   -- Permissions.RegisterPermission
    applications        = true,   -- ApplicationRegistry.Register
    wallet              = true,   -- KIPN_Wallet charge/refund
    screens             = true,   -- KIPN.UI.CreateScreen (client)
    externalClaimChecker = true,  -- KIPN.Shared.RegisterExternalClaimChecker
}

local function normalizeVersion(v)
    v = tonumber(v)
    if not v then
        return nil
    end
    return math.floor(v)
end

function KIPN.API.IsCompatible(wantVersion)

    local want = normalizeVersion(wantVersion)

    if not want then
        return false, "no API version declared"
    end

    if want > KIPN.API.Version then
        return false,
            "built for KIPN service API v" .. tostring(want) ..
            " but this KIPN provides v" .. tostring(KIPN.API.Version) ..
            " (update the KIP Network Terminal mod)"
    end

    if want < KIPN.API.MinCompat then
        return false,
            "built for KIPN service API v" .. tostring(want) ..
            " which this KIPN (v" .. tostring(KIPN.API.Version) ..
            ", minimum v" .. tostring(KIPN.API.MinCompat) ..
            ") no longer guarantees"
    end

    return true
end

function KIPN.API.Require(minVersion)

    local ok, reason = KIPN.API.IsCompatible(minVersion)

    if ok then
        return true
    end

    return false,
        "KIPN service API mismatch: " .. tostring(reason) .. "."
end

function KIPN.API.Has(feature)
    return KIPN.API._features[tostring(feature or "")] == true
end

--------------------------------------------------------------------
-- REFERENCE BOOT DURATION
--
-- Shared reference value only.
--
-- This is NOT authoritative.
--
-- KIPN_Server determines actual boot timing.
--------------------------------------------------------------------

KIPN.Shared.DEFAULT_BOOT_DURATION_MS =
    8000

--------------------------------------------------------------------
-- SERVER-AUTHORITATIVE PERMISSION IDENTIFIERS
--
-- These strings define the permission contract.
--
-- They do NOT grant permission.
--
-- Permission evaluation belongs to the server.
--------------------------------------------------------------------

KIPN.Shared.Permissions = {

    SYSOP_VIEW =
        "sysop.view",

    SYSOP_USERS =
        "sysop.users",

    SYSOP_COMPUTERS =
        "sysop.computers",

    SYSOP_CONFIGURATION =
        "sysop.configuration",

    VEHICLE_TITLE_ADMIN =
        "vehicle.title.admin",

    ANNOUNCEMENT_ADMIN =
        "announcement.admin",
}

--------------------------------------------------------------------
-- KIPN ACCESS LEVELS
--
-- Derived from Project Zomboid's own server-authoritative access
-- level (player:getAccessLevel()). See
-- KIPN.Server.Permissions.ResolveAccessLevel (KIPN_Permissions.lua)
-- for the PZ -> KIPN mapping and the KIPN.AdminAccounts sandbox
-- override.
--------------------------------------------------------------------

KIPN.Shared.AccessLevels = {

    ADMIN =
        "ADMIN",

    MODERATOR =
        "MODERATOR",

    STAFF =
        "STAFF",

    GM =
        "GM",

    OBSERVER =
        "OBSERVER",

    USER =
        "USER",
}

--------------------------------------------------------------------
-- GAME MODES
--
-- These are domain identifiers.
--
-- The server remains authoritative over the active mode.
--------------------------------------------------------------------

KIPN.Shared.Modes = {

    SINGLEPLAYER =
        "singleplayer",

    MULTIPLAYER_PVE =
        "pve",

    MULTIPLAYER_PVP =
        "pvp",

    MULTIPLAYER_HYBRID =
        "hybrid",
}

--------------------------------------------------------------------
-- APPLICATION IDENTIFIERS
--
-- Shared identifiers for KIPN applications.
--
-- These are contracts only.
--
-- Application implementation belongs to the appropriate
-- client/server modules.
--------------------------------------------------------------------

KIPN.Shared.Applications = {

    BBS =
        "bbs",

    LOGIN =
        "login",

    MAIN_MENU =
        "mainMenu",

    WEATHER =
        "weather",

    TERMINAL =
        "terminal",
}

--------------------------------------------------------------------
-- CAPABILITY IDENTIFIERS
--
-- These describe KIPN capabilities.
--
-- Capability checks and authorization remain server
-- responsibilities.
--------------------------------------------------------------------

KIPN.Shared.Capabilities = {

    COMPUTER =
        "computer",

    POWER =
        "power",

    BBS =
        "bbs",

    WEATHER =
        "weather",

    PROPERTY =
        "property",

    ADMIN =
        "admin",
}

--------------------------------------------------------------------
-- ADD-ON REGISTRATION HELPERS
--------------------------------------------------------------------
--
-- A companion service mod (Government Services, Vehicle Services, ...)
-- extends KIPN's shared enums with its own command / response-event
-- wire names, application ids, and capability ids WITHOUT editing this
-- file. Both realms (client + server) load KIPN_Shared before any
-- service module, so a service registering here at module-load time is
-- visible to every later KIPN_Shared.X[...] lookup on both sides.
--
-- Contract:
--   * key   -- the KIPN.Shared.<Table>.<KEY> name the service will use
--              in its own code (a stable Lua identifier).
--   * value -- the wire string actually sent on the network.
--
-- Re-registering the same key with the same value is a no-op.
-- Re-registering a key with a DIFFERENT value is rejected (logged) so
-- two mods cannot silently collide on a wire name.
--------------------------------------------------------------------

local function registerSharedEnum(realmTable, tableLabel, key, value)

    if type(key) ~= "string"
        or key == ""
        or type(value) ~= "string"
        or value == ""
    then

        print(
            "[KIPN SHARED] Register" .. tableLabel ..
            " rejected: key/value must be non-empty strings."
        )

        return false
    end

    local existing = realmTable[key]

    if existing ~= nil then

        if existing == value then
            return true
        end

        print(
            "[KIPN SHARED] Register" .. tableLabel ..
            " rejected: '" .. key .. "' already registered as '" ..
            tostring(existing) .. "' (attempted '" .. value .. "')."
        )

        return false
    end

    realmTable[key] = value

    return true
end

function KIPN.Shared.RegisterCommand(key, wireName)
    return registerSharedEnum(
        KIPN.Shared.Commands, "Command", key, wireName
    )
end

function KIPN.Shared.RegisterResponseEvent(key, wireName)
    return registerSharedEnum(
        KIPN.Shared.ResponseEvents, "ResponseEvent", key, wireName
    )
end

function KIPN.Shared.RegisterApplication(key, id)
    return registerSharedEnum(
        KIPN.Shared.Applications, "Application", key, id
    )
end

function KIPN.Shared.RegisterCapability(key, id)
    return registerSharedEnum(
        KIPN.Shared.Capabilities, "Capability", key, id
    )
end

--------------------------------------------------------------------
-- GET PLAYER IDENTIFIER
--
-- Resolves a stable engine-level player identifier.
--
-- This function:
--
--   * does NOT authenticate
--   * does NOT authorize
--   * does NOT create player records
--   * does NOT save data
--
-- It only resolves the identifier available from the player
-- object.
--------------------------------------------------------------------

----------------------------------------------------------------
-- SINGLE PLAYER
--
-- Build 42 has no isSinglePlayer() global (it is used only when a
-- build provides it). Single player is the session that is neither a
-- multiplayer client nor a server.
----------------------------------------------------------------

function KIPN.Shared.IsSinglePlayer()
    if type(isSinglePlayer) == "function" then
        local ok, result = pcall(isSinglePlayer)
        if ok and result == true then return true end
    end
    local client = type(isClient) == "function" and isClient()
    local server = type(isServer) == "function" and isServer()
    return not client and not server
end

----------------------------------------------------------------
-- VEHICLE LOOKUP
--
-- getVehicleById() asks VehicleManager.instance, which only exists
-- in multiplayer, so in single player it never finds a vehicle.
-- This falls back to the vehicles loaded in the cell. The cell's
-- list is a HashSet in Build 42, so it is walked with an iterator
-- (get(i) is unavailable).
----------------------------------------------------------------

function KIPN.Shared.GetVehicleById(vehicleId)
    local wanted = tonumber(vehicleId)
    if not wanted then return nil end
    if type(getVehicleById) == "function" then
        local ok, vehicle = pcall(getVehicleById, wanted)
        if ok and vehicle then return vehicle end
    end
    local found = nil
    pcall(function()
        local vehicles = getCell() and getCell():getVehicles()
        if not vehicles then return end
        local iterator = vehicles:iterator()
        while iterator:hasNext() do
            local vehicle = iterator:next()
            if vehicle and vehicle:getId() == wanted then
                found = vehicle
                return
            end
        end
    end)
    return found
end

--------------------------------------------------------------------
-- PLAYER IDENTITY
--
-- In multiplayer a player is identified by their SERVER ACCOUNT: the
-- username they log in to the server with, as "user:<username>". The
-- server authenticates it and it is an exact string.
--
-- The Steam ID is not used as an identity. getSteamID() returns a
-- Java `long`; Kahlua has no integer type, so a 17-digit SteamID64
-- (which exceeds 2^53) reaches Lua already rounded to the nearest
-- double. IDs a few apart are then the same value, and two different
-- players can share one "identity". It is kept only as a best-attempt
-- second confirmation (GetPlayerSteamId below).
--
-- Single player has no server account and one player: its identity
-- is always "SINGLEPLAYER".
--
-- Records written before this change carry the old Steam-based keys.
-- GetLegacyPlayerIds() lists the keys a player's records may still
-- be under, and RekeyIdentity() moves them.
--------------------------------------------------------------------

KIPN.Shared.ACCOUNT_ID_PREFIX = "user:"

function KIPN.Shared.AccountId(username)
    if username == nil or tostring(username) == "" then
        return nil
    end

    return KIPN.Shared.ACCOUNT_ID_PREFIX .. tostring(username)
end

function KIPN.Shared.IsAccountId(id)
    return type(id) == "string"
        and string.sub(id, 1, #KIPN.Shared.ACCOUNT_ID_PREFIX)
            == KIPN.Shared.ACCOUNT_ID_PREFIX
end

local function readSteamId(player)
    if not player or not player.getSteamID then
        return nil
    end

    local ok, steamId = pcall(function()
        return player:getSteamID()
    end)

    if not ok or steamId == nil then
        return nil
    end

    return steamId
end

local function readUsername(player)
    if not player or type(player.getUsername) ~= "function" then
        return nil
    end

    local ok, username = pcall(function()
        return player:getUsername()
    end)

    if ok and username ~= nil and tostring(username) ~= "" then
        return tostring(username)
    end

    return nil
end

----------------------------------------------------------------
-- The player's Steam ID as far as Lua can read it: the rounded
-- value, printed without scientific notation. For logging and soft
-- confirmation only; never an identity. nil when there is none.
--
-- Anything compared against it (KIPN_Permissions.lua's
-- AdminSteamIDs confirmation) must pass through the same
-- tonumber() -> "%.0f" round-trip so both sides land on the same
-- rounded digits.
----------------------------------------------------------------
function KIPN.Shared.GetPlayerSteamId(player)
    local steamId = readSteamId(player)

    if type(steamId) ~= "number" then
        return nil
    end

    local id = string.format("%.0f", steamId)

    if id == "" or id == "0" then
        return nil
    end

    return id
end

function KIPN.Shared.GetPlayerId(
    player
)

    if not player then

        return nil
    end

    local username = readUsername(player)

    local okSP, isSP =
        pcall(KIPN.Shared.IsSinglePlayer)

    ----------------------------------------------------------------
    -- MULTIPLAYER: THE SERVER ACCOUNT
    ----------------------------------------------------------------

    if not (okSP and isSP) and username then
        return KIPN.Shared.AccountId(username)
    end

    ----------------------------------------------------------------
    -- SINGLE PLAYER
    ----------------------------------------------------------------

    if okSP and isSP then
        return "SINGLEPLAYER"
    end

    ----------------------------------------------------------------
    -- A multiplayer player without a username, which the game does
    -- not produce: the rounded Steam ID is better than no identity.
    ----------------------------------------------------------------

    return KIPN.Shared.GetPlayerSteamId(player)
end

----------------------------------------------------------------
-- Every key this player's records may have been written under
-- before identities became server accounts. Different services
-- formatted the same rounded Steam ID differently:
--   tostring(steamId)            claims, stats ("7.65E16" style)
--   string.format("%.0f", ...)   the old GetPlayerId
--   "steam:" .. tostring(...)    careers
--   "name:" .. username          stats without a Steam ID
-- The current identity is never in the list.
----------------------------------------------------------------
function KIPN.Shared.GetLegacyPlayerIds(player)
    local current = KIPN.Shared.GetPlayerId(player)
    local ids, seen = {}, {}

    local function add(id)
        if id and id ~= "" and id ~= current and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end

    local steamId = readSteamId(player)

    if steamId ~= nil and tostring(steamId) ~= "0" and tostring(steamId) ~= "" then
        add(tostring(steamId))
        add(KIPN.Shared.GetPlayerSteamId(player))
        add("steam:" .. tostring(steamId))
    end

    local username = readUsername(player)

    if username then
        add("name:" .. username)
    end

    return ids
end

----------------------------------------------------------------
-- Replaces oldId by newId everywhere in a table of saved data:
-- as a key and as a string value, at any depth. A key that would
-- land on an existing entry is left alone and counted as a
-- conflict, so nothing is overwritten. Returns moved, conflicts.
----------------------------------------------------------------
function KIPN.Shared.RekeyIdentity(root, oldId, newId)
    local moved, conflicts = 0, 0

    if type(root) ~= "table" or oldId == nil or newId == nil or oldId == newId then
        return moved, conflicts
    end

    local seen = {}

    local function visit(node)
        if seen[node] then return end
        seen[node] = true

        for key, value in pairs(node) do
            if type(value) == "table" then
                visit(value)
            elseif value == oldId then
                node[key] = newId
                moved = moved + 1
            end
        end

        local held = node[oldId]

        if held ~= nil then
            if node[newId] == nil then
                node[newId] = held
                node[oldId] = nil
                moved = moved + 1
            else
                conflicts = conflicts + 1
            end
        end
    end

    visit(root)

    return moved, conflicts
end

--------------------------------------------------------------------
-- GET PLAYER DISPLAY NAME
--
-- Display information only.
--
-- This must NEVER be used as an authoritative player identifier.
--------------------------------------------------------------------

function KIPN.Shared.GetPlayerName(
    player
)

    if not player then

        return "Unknown"
    end

    if not player.getDisplayName then

        return "Unknown"
    end

    local name =
        player:getDisplayName()

    if name
        and name ~= "" then

        return tostring(name)
    end

    return "Unknown"
end

--------------------------------------------------------------------
-- IS COMPUTER OBJECT SPRITE
--
-- Sprite/name heuristic for "is this IsoObject a KIPN-recognized
-- computer?". Single source of truth for both the client's
-- world-object detection (KIPN_Interaction.lua's isComputerObject())
-- and server-side world-object resolution (KIPN_Server.lua's
-- resolveComputerWorldObject(), used to read/write the Hardware
-- Condition modData tag). Kept intentionally simple/pure -- no
-- pcall wrapping here, callers are responsible for guarding engine
-- API access the way they already do.
--------------------------------------------------------------------

function KIPN.Shared.IsComputerObjectSprite(
    obj
)

    if not obj then

        return false
    end

    ----------------------------------------------------------------
    -- EXTERNAL CLAIM DEFERENCE
    --
    -- KIPN's sprite/name heuristic below is deliberately broad
    -- (e.g. the whole "office_01_" tile sheet), so it can also flag
    -- moveables that another mod has explicitly repurposed -- e.g.
    -- Player Shops lets a player turn ANY moveable, including an
    -- office/computer-sprite one, into a shop kiosk. Without this
    -- check, that single world object would be claimed as "a
    -- computer" by KIPN (context menu, disassemble filtering,
    -- condition tracking) AND by the other mod at the same time.
    --
    -- Deferring here keeps both systems operational side by side:
    -- once an object is claimed elsewhere, KIPN treats it as not a
    -- computer at all rather than fighting over it. See the
    -- EXTERNAL CLAIM REGISTRY section below this function for how
    -- claims get registered.
    ----------------------------------------------------------------

    if KIPN.Shared.IsExternallyClaimed(
        obj
    )
    then

        return false
    end

    local sprite =
        obj.getSprite
        and obj:getSprite()
        or nil

    if sprite
        and sprite.getName
    then

        local spriteName =
            sprite:getName()

        if spriteName then

            local sName =
                string.lower(
                    tostring(spriteName)
                )

            if string.find(sName, "appliances_com_", 1, true)
                or string.find(sName, "computer", 1, true)
                or string.find(sName, "office_01_", 1, true)
            then

                return true
            end
        end
    end

    if obj.getName then

        local objectName =
            obj:getName()

        if objectName then

            local lowerName =
                string.lower(
                    tostring(objectName)
                )

            if string.find(lowerName, "computer", 1, true) then

                return true
            end
        end
    end

    return false
end

--------------------------------------------------------------------
-- EXTERNAL CLAIM REGISTRY
--
-- A world object can only meaningfully belong to one interactive
-- system at a time. Rather than IsComputerObjectSprite() above
-- hardcoding an if-check per compatible mod (PlayerShops, and
-- whatever comes after it), other mods' "is this object mine?"
-- checks are registered here as small functions and consulted
-- generically.
--
-- KIPN ships with a built-in registration for Player Shops at the
-- bottom of this section, guarded so it's a no-op when that mod
-- isn't installed. A third-party mod that wants to coexist with
-- KIPN can register its own checker the same way, from its own
-- Lua, without ever touching this file:
--
--     KIPN.Shared.RegisterExternalClaimChecker(
--         function(obj)
--             return SomeOtherMod.isMine(obj) == true
--         end
--     )
--
-- Checkers run in registration order and short-circuit on the
-- first true; each is pcall-guarded so a broken/unrelated checker
-- (e.g. one written against an older API another mod changed)
-- can't crash KIPN's own computer detection.
--------------------------------------------------------------------

KIPN.Shared._externalClaimCheckers =
    KIPN.Shared._externalClaimCheckers or {}

function KIPN.Shared.RegisterExternalClaimChecker(
    checkerFn
)

    if type(checkerFn) ~= "function" then

        return
    end

    table.insert(
        KIPN.Shared._externalClaimCheckers,
        checkerFn
    )
end

function KIPN.Shared.IsExternallyClaimed(
    obj
)

    if not obj then

        return false
    end

    for _, checkerFn in ipairs(
        KIPN.Shared._externalClaimCheckers
    ) do

        local ok, claimed =
            pcall(
                checkerFn,
                obj
            )

        if ok
            and claimed
        then

            return true
        end
    end

    return false
end

----------------------------------------------------------------
-- BUILT-IN: PLAYER SHOPS
--
-- Player Shops lets a player turn ANY moveable into a shop kiosk
-- via getModData().isPlayerShopKiosk, with no restriction on
-- sprite -- so a kiosk can end up on an office/computer-sprite
-- object that KIPN's heuristic would otherwise claim too.
----------------------------------------------------------------

KIPN.Shared.RegisterExternalClaimChecker(
    function(obj)

        return _G.PlayerShops
            and _G.PlayerShops.isKiosk
            and _G.PlayerShops.isKiosk(obj) == true
    end
)

--------------------------------------------------------------------
-- GET COMPUTER IDENTIFIER
--
-- Resolves an identifier from a computer object.
--
-- Preferred:
--
--   engine object ID
--
-- Fallback:
--
--   world coordinates
--
-- This function does NOT:
--
--   * register the computer
--   * claim ownership
--   * determine power
--   * determine capabilities
--   * modify server data
--
-- Those responsibilities belong to the server.
--------------------------------------------------------------------

function KIPN.Shared.GetComputerId(
    computer
)

    if not computer then

        return nil
    end

    ------------------------------------------------------------
    -- ENGINE OBJECT ID
    ------------------------------------------------------------

    if computer.getID then

        local id =
            computer:getID()

        if id
            and id ~= 0 then

            local computerId =
                tostring(id)

            return computerId
        end
    end

    ------------------------------------------------------------
    -- WORLD COORDINATE FALLBACK
    ------------------------------------------------------------

    if not computer.getSquare then

        return nil
    end

    local square =
        computer:getSquare()

    if not square then

        return nil
    end

    if not square.getX
        or not square.getY
        or not square.getZ then

        return nil
    end

    local x =
        square:getX()

    local y =
        square:getY()

    local z =
        square:getZ()

    if x == nil
        or y == nil
        or z == nil then

        return nil
    end

    local computerId =
        string.format(
            "comp_%d_%d_%d",
            x,
            y,
            z
        )

    return computerId
end

--------------------------------------------------------------------
-- PARSE COMPUTER ID COORDINATES
--
-- Best-effort inverse of the "comp_%d_%d_%d" world-coordinate
-- fallback branch above. Used server-side (KIPN_Server.lua) to
-- resolve broadcast-worthy square coordinates from a bare
-- computerId string, without needing to store x/y/z separately on
-- the persisted computer record.
--
-- Returns x, y, z (numbers) on success, or nil on failure -- e.g.
-- a computerId that was instead resolved via the engine-object-ID
-- branch above. Callers must treat nil as "coordinates unknown"
-- and degrade gracefully rather than assume this always succeeds.
--------------------------------------------------------------------

function KIPN.Shared.ParseComputerIdCoords(
    computerId
)

    if type(computerId) ~= "string" then

        return nil
    end

    local x,
        y,
        z =
        computerId:match(
            "^comp_(%-?%d+)_(%-?%d+)_(%-?%d+)$"
        )

    if not x
        or not y
        or not z
    then

        return nil
    end

    return tonumber(x),
        tonumber(y),
        tonumber(z)
end

--------------------------------------------------------------------
-- HAS SQUARE ELECTRICITY
--
-- Local, client-side, no server round trip - the client already
-- has this information the same way vanilla appliances (lamps,
-- fridges, TVs) read it.
--
-- IMPORTANT: square:haveElectricity() ALONE is not enough, and
-- hasGridPower() ALONE is too permissive. Vanilla itself never uses
-- hasGridPower() by itself for a stationary appliance - see
-- ISWorldObjectContextMenu.lua's car battery charger check (the same
-- family of object as a TV/computer sitting on furniture):
--
--   square:haveElectricity() or
--       (square:hasGridPower() and square:getRoom())
--
-- haveElectricity() reflects LOCAL/generator power specifically, and
-- is valid outdoors (a generator can sit anywhere, so no room check).
-- hasGridPower() reflects ordinary grid power before the world-wide
-- shutoff (SandboxVars.ElecShutModifier) - but it is true for the
-- ENTIRE map, indoors or out, until that shutoff happens. Without
-- also requiring square:getRoom() (i.e. the square is actually part
-- of a building interior), any appliance in the open world - a
-- computer sitting in the woods far from wiring, exactly like a TV
-- can never do - would incorrectly report having power.
--
-- (ISVehicleMenu.lua's fuel-pump check omits the room requirement,
-- but that's specific to vehicle equipment, which is legitimately
-- outdoors - not the pattern for stationary furniture like this.)
--
-- This function does NOT determine whether the computer itself is
-- switched on or its persisted boot state - only whether the world
-- square it sits on has electricity available at all. The computer
-- power/boot state remains server-authoritative.
--------------------------------------------------------------------

function KIPN.Shared.HasSquareElectricity(
    square
)

    if not square then

        return false
    end

    local ok, result =
        pcall(
            function()

                local hasGeneratorMethod =
                    type(square.haveElectricity)
                    == "function"

                local hasGridMethod =
                    type(square.hasGridPower)
                    == "function"

                if not hasGeneratorMethod
                    and not hasGridMethod then

                    return false
                end

                local generatorPowered =
                    hasGeneratorMethod
                    and square:haveElectricity()
                    == true

                local gridPowered =
                    hasGridMethod
                    and square:hasGridPower()
                    == true
                    and type(square.getRoom)
                    == "function"
                    and square:getRoom()
                    ~= nil

                return generatorPowered
                    or gridPowered
            end
        )

    if not ok then

        return false
    end

    return result == true
end

--------------------------------------------------------------------
-- IS PLAYER NEAR SQUARE
--
-- CLIENT-SIDE ONLY proximity check, shared by every KIPN screen
-- that closes itself when the local player wanders off (the
-- terminal, boot screen, splash screen). getPlayer() only resolves
-- to a real player object on the client, so this is not meant to
-- be called server-side.
--
-- Returns false (out of range) whenever the player or square is
-- missing, or player position cannot be resolved - fails closed,
-- same philosophy as KIPN.Shared.HasSquareElectricity().
--------------------------------------------------------------------

function KIPN.Shared.IsPlayerNearSquare(
    square,
    maxProximity,
    maxZDifference
)

    if not square then

        return false
    end

    local player =
        getPlayer
        and getPlayer()

    if not player then

        return false
    end

    local pX =
        player:getX()

    local pY =
        player:getY()

    local pZ =
        player:getZ()

    if not pX
        or not pY
        or not pZ then

        return false
    end

    local cX =
        square:getX()
        + 0.5

    local cY =
        square:getY()
        + 0.5

    local cZ =
        square:getZ()

    local dx =
        pX - cX

    local dy =
        pY - cY

    local dist =
        math.sqrt(
            (dx * dx)
            + (dy * dy)
        )

    local zDiff =
        math.abs(
            pZ - cZ
        )

    if dist > maxProximity
        or zDiff > maxZDifference then

        return false
    end

    return true
end

--------------------------------------------------------------------
-- DETECT MULTIPLAYER
--
-- This determines execution context only.
--
-- It is NOT an authority or security check.
--------------------------------------------------------------------

function KIPN.Shared.IsMultiplayer()

    if isServer() then

        return true
    end

    if isClient() then

        return true
    end

    return false
end

--------------------------------------------------------------------
-- GET DEFAULT GAME MODE
--
-- Returns the default mode appropriate for the current
-- execution environment.
--
-- This does NOT read or modify server configuration.
--------------------------------------------------------------------

function KIPN.Shared.GetDefaultMode()

    if KIPN.Shared.IsMultiplayer() then

        return KIPN.Shared.Modes.MULTIPLAYER_HYBRID
    end

    return KIPN.Shared.Modes.SINGLEPLAYER
end

--------------------------------------------------------------------
-- VALIDATE COMMAND
--
-- Lightweight shared contract validation.
--
-- This does NOT authorize commands.
--
-- Server-side command handlers must still perform authorization
-- and input validation.
--------------------------------------------------------------------

function KIPN.Shared.IsValidCommand(
    command
)

    if not command then

        return false
    end

    for _, value in pairs(
        KIPN.Shared.Commands
    ) do

        if value == command then

            return true
        end
    end

    return false
end

--------------------------------------------------------------------
-- VALIDATE RESPONSE IDENTIFIER
--------------------------------------------------------------------

function KIPN.Shared.IsValidResponse(
    response
)

    if not response then

        return false
    end

    for _, value in pairs(
        KIPN.Shared.ResponseEvents
    ) do

        if value == response then

            return true
        end
    end

    return false
end

--------------------------------------------------------------------
-- SHARED INITIALIZATION
--------------------------------------------------------------------

return KIPN.Shared
