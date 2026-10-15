-- KIPN_ApplicationRegistry.lua
--
-- KIPN application discovery and registration system.
--
-- Responsibilities:
--   * Register KIPN applications.
--   * Define application metadata.
--   * Define application requirements.
--   * Determine whether an application is available to a player/session.
--   * Determine whether an application is available on a computer.
--   * Provide the future BBS UI with a clean application registry.
--
-- IMPORTANT:
--
-- This registry does NOT implement application functionality.
--
-- It describes applications and their requirements.
--
-- Actual application logic belongs in separate modules.
--
-- Example:
--
--   Vehicle Registration
--       |
--       +-- requires session
--       +-- requires permission: vehicle.claim
--       +-- requires computer capability: vehicle.claim
--       +-- requires classification: DEALERSHIP
--       +-- may require claim token
--
-- The registry can determine whether the application SHOULD be
-- available.
--
-- The application service must still perform authoritative validation
-- when an operation is actually executed.
--
-- This is intentionally a discovery layer, not a security boundary.
--
-- Architecture:
--
--   Terminal
--       |
--       v
--   Session
--       |
--       v
--   Application Registry
--       |
--       +--> Account Permission
--       +--> Computer Classification
--       +--> Computer Capability
--       +--> Session Requirement
--       |
--       v
--   Application UI
--       |
--       v
--   Application Service
--       |
--       v
--   Server-authoritative transaction
--
-- Future applications:
--
--   weather
--   vehicle_registration
--   vehicle_records
--   property_records
--   excavation
--   administration
--   messaging
--   banking
--   licenses
--   contracts
--   custom host applications

if isClient() then return end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_Permissions"
require "KIPN_WorldRegistry"

-- The client main menu is server-driven: it asks
-- KIPN.Shared.Commands.GET_APPLICATIONS and renders whatever comes
-- back in KIPN.Shared.ResponseEvents.APPLICATIONS_DATA (both defined
-- in KIPN_Shared.lua so the client -- which never loads this
-- server-only file -- has them too).

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("ApplicationRegistry")
    or nil

local function log(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN APPLICATION REGISTRY] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN APPLICATION REGISTRY] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- REGISTRY
------------------------------------------------------------

KIPN.Server.ApplicationRegistry =
    KIPN.Server.ApplicationRegistry or {}

local Registry =
    KIPN.Server.ApplicationRegistry

Registry.Applications =
    Registry.Applications or {}

------------------------------------------------------------
-- APPLICATION REGISTRATION
------------------------------------------------------------

function Registry.Register(applicationId, definition)
    if not applicationId or applicationId == "" then
        logError(
            "Application registration rejected: missing application ID."
        )

        return false
    end

    if type(definition) ~= "table" then
        logError(
            "Application registration rejected: definition is not a table."
        )

        return false
    end

    if Registry.Applications[applicationId] then
        logError(
            "Application already registered: " ..
            tostring(applicationId)
        )

        return false
    end

    definition.id = tostring(applicationId)

    if not definition.name then
        definition.name = tostring(applicationId)
    end

    if definition.enabled == nil then
        definition.enabled = true
    end

    if definition.visible == nil then
        definition.visible = true
    end

    if definition.requiresSession == nil then
        definition.requiresSession = true
    end

    if type(definition.permissions) ~= "table" then
        definition.permissions = {}
    end

    if type(definition.capabilities) ~= "table" then
        definition.capabilities = {}
    end

    if type(definition.classifications) ~= "table" then
        definition.classifications = {}
    end

    Registry.Applications[applicationId] = definition

    return true
end

------------------------------------------------------------
-- APPLICATION LOOKUP
------------------------------------------------------------

function Registry.Get(applicationId)
    if not applicationId then
        return nil
    end

    local application =
        Registry.Applications[applicationId]

    return application
end

------------------------------------------------------------
-- APPLICATION LIST
------------------------------------------------------------

function Registry.GetAll()
    local result = {}

    for applicationId, definition in pairs(
        Registry.Applications
    ) do
        result[applicationId] = definition
    end

    return result
end

------------------------------------------------------------
-- COUNT
------------------------------------------------------------
--
-- Registry.Applications is keyed by application id, so `#` on it is
-- always 0. Use this.
------------------------------------------------------------

function Registry.Count()
    local n = 0

    for _ in pairs(Registry.Applications) do
        n = n + 1
    end

    return n
end

------------------------------------------------------------
-- ENABLE / DISABLE
------------------------------------------------------------

function Registry.SetEnabled(applicationId, enabled)
    local application =
        Registry.Get(applicationId)

    if not application then
        return false
    end

    application.enabled = enabled and true or false

    return true
end

------------------------------------------------------------
-- PERMISSION REQUIREMENT
------------------------------------------------------------

local function hasRequiredPermissions(
    account,
    application
)
    if type(application.permissions) ~= "table" then
        return true
    end

    for _, permissionId in ipairs(
        application.permissions
    ) do

        local allowed =
            KIPN.Server.Permissions.HasPermission(
                account,
                permissionId
            )

        if not allowed then
            return false
        end
    end

    return true
end

------------------------------------------------------------
-- COMPUTER CAPABILITY REQUIREMENT
------------------------------------------------------------

local function hasRequiredCapabilities(
    computerId,
    application
)
    if type(application.capabilities) ~= "table" then
        return true
    end

    if not computerId then
        return false
    end

    local capabilities =
        KIPN.Server.WorldRegistry.GetComputerCapabilities(
            computerId
        )

    for _, capability in ipairs(
        application.capabilities
    ) do

        local allowed =
            capabilities
            and capabilities[capability] == true

        if not allowed then
            return false
        end
    end

    return true
end

------------------------------------------------------------
-- COMPUTER CLASSIFICATION REQUIREMENT
------------------------------------------------------------

local function hasRequiredClassification(
    computerId,
    application
)
    if type(application.classifications) ~= "table" then
        return true
    end

    if #application.classifications == 0 then
        return true
    end

    if not computerId then
        return false
    end

    --------------------------------------------------------
    -- Classification is resolved dynamically from the
    -- computer's CURRENT world position (WorldRegistry does
    -- not persist a classification flag on the computer
    -- record itself, so moving the computer automatically
    -- changes what it's classified as).
    --------------------------------------------------------

    local classification =
        KIPN.Server.WorldRegistry.GetComputerClassification(
            computerId
        )

    if not classification then
        return false
    end

    -- Zone-type name -> classification field is owned by
    -- WorldRegistry (populated as each zone type is registered),
    -- so a companion service's zone type works here with no edit
    -- to this file. Fallback map covers the built-ins in case a
    -- caller runs before any RegisterZoneType.
    local fieldByName =
        KIPN.Server.WorldRegistry
        and KIPN.Server.WorldRegistry.ClassificationFieldByTypeName
        or {
            GOVERNMENT = "government",
            DEALERSHIP = "dealership",
            CUSTOM = "custom",
        }

    for _, requiredClassification in ipairs(
        application.classifications
    ) do

        local field =
            fieldByName[requiredClassification]

        if field
            and classification[field] == true
        then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- IDENTITY REQUIREMENT
------------------------------------------------------------
--
-- KIPN has no login/session concept: a connected player's
-- identity is their native Steam ID (KIPN.Shared.GetPlayerId).
-- "requiresSession" therefore means "requires a resolvable
-- player identity" -- true for effectively every real,
-- connected player, false only for applications explicitly
-- opened up to anonymous/unidentified use.
--
-- The registry intentionally does not implement identity
-- resolution itself -- it simply checks the context supplied
-- by the caller.
------------------------------------------------------------

local function hasRequiredSession(
    application,
    context
)
    if application.requiresSession == false then
        return true
    end

    if type(context) ~= "table" then
        return false
    end

    if not context.steamId then
        return false
    end

    return true
end

------------------------------------------------------------
-- APPLICATION AVAILABILITY
------------------------------------------------------------
--
-- This determines whether an application SHOULD be shown or
-- made accessible from the current BBS context.
--
-- It does NOT authorize the actual transaction.
--
-- Every application service must repeat its own server-side
-- authorization checks when executing an operation.
------------------------------------------------------------

function Registry.IsAvailable(
    applicationId,
    context
)
    local application =
        Registry.Get(applicationId)

    if not application then
        return false, "APPLICATION_NOT_FOUND"
    end

    if application.enabled ~= true then
        return false, "APPLICATION_DISABLED"
    end

    context = context or {}

    --------------------------------------------------------
    -- IDENTITY
    --------------------------------------------------------

    if not hasRequiredSession(
        application,
        context
    ) then

        return false, "SESSION_REQUIRED"
    end

    --------------------------------------------------------
    -- ACCOUNT
    --
    -- KIPN has no login/account system; a resolvable Steam ID
    -- stands in for the "PLAYER" role so the existing
    -- role/permission checks below (KIPN.Server.Permissions)
    -- continue to work unchanged. Callers may still pass an
    -- explicit context.account to override this.
    --------------------------------------------------------

    local account = context.account

    if not account and context.steamId then
        account = {
            id = context.steamId,
            roles = { "PLAYER" },
        }
    end

    if application.requiresSession ~= false and
       not account then

        return false, "ACCOUNT_REQUIRED"
    end

    --------------------------------------------------------
    -- ACCOUNT PERMISSIONS
    --------------------------------------------------------

    if not hasRequiredPermissions(
        account,
        application
    ) then

        return false, "PERMISSION_DENIED"
    end

    --------------------------------------------------------
    -- COMPUTER CAPABILITIES
    --------------------------------------------------------

    if not hasRequiredCapabilities(
        context.computerId,
        application
    ) then

        return false, "COMPUTER_CAPABILITY_REQUIRED"
    end

    --------------------------------------------------------
    -- COMPUTER CLASSIFICATION
    --------------------------------------------------------

    if not hasRequiredClassification(
        context.computerId,
        application
    ) then

        return false, "COMPUTER_CLASSIFICATION_REQUIRED"
    end

    --------------------------------------------------------
    -- SUCCESS
    --------------------------------------------------------

    return true, "AVAILABLE"
end

------------------------------------------------------------
-- GET AVAILABLE APPLICATIONS
------------------------------------------------------------
--
-- This is the function the future BBS main menu will love.
--
-- It can ask:
--
--     Registry.GetAvailableApplications({
--         steamId = steamId,
--         computerId = computerId
--     })
--
-- and receive only the applications that should appear.
------------------------------------------------------------

function Registry.GetAvailableApplications(context)
    context = context or {}

    local result = {}

    for applicationId, application in pairs(
        Registry.Applications
    ) do

        local available =
            Registry.IsAvailable(
                applicationId,
                context
            )

        if available then
            table.insert(
                result,
                application
            )
        end
    end

    --------------------------------------------------------
    -- SORT BY APPLICATION ORDER
    --------------------------------------------------------

    table.sort(
        result,
        function(a, b)

            local orderA =
                tonumber(a.order) or 9999

            local orderB =
                tonumber(b.order) or 9999

            if orderA == orderB then
                return tostring(a.name) <
                    tostring(b.name)
            end

            return orderA < orderB
        end
    )

    return result
end

------------------------------------------------------------
-- APPLICATION REQUIREMENT SNAPSHOT
------------------------------------------------------------
--
-- Useful for the future administration interface.
--
-- Returns a clean description of what an application requires.
------------------------------------------------------------

function Registry.GetRequirements(applicationId)
    local application =
        Registry.Get(applicationId)

    if not application then
        return nil
    end

    local result = {
        applicationId = application.id,

        requiresSession =
            application.requiresSession ~= false,

        permissions = {},

        capabilities = {},

        classifications = {},
    }

    if type(application.permissions) == "table" then
        for _, permissionId in ipairs(
            application.permissions
        ) do
            table.insert(
                result.permissions,
                permissionId
            )
        end
    end

    if type(application.capabilities) == "table" then
        for _, capability in ipairs(
            application.capabilities
        ) do
            table.insert(
                result.capabilities,
                capability
            )
        end
    end

    if type(application.classifications) == "table" then
        for _, classification in ipairs(
            application.classifications
        ) do
            table.insert(
                result.classifications,
                classification
            )
        end
    end

    return result
end

------------------------------------------------------------
-- BUILT-IN APPLICATIONS
------------------------------------------------------------
--
-- These are deliberately definitions only.
--
-- Actual application functionality will be implemented in
-- separate services later.
------------------------------------------------------------

local function registerBuiltInApplications()
    --------------------------------------------------------
    -- WEATHER
    --------------------------------------------------------

    Registry.Register("weather", {

        name = "Weather",

        description =
            "Current weather and forecast information.",

        order = 10,

        requiresSession = false,

        permissions = {},

        capabilities = {
            "weather",
        },

        classifications = {},

    })

    --------------------------------------------------------
    -- SERVER STATISTICS (menu program)
    --------------------------------------------------------

    Registry.Register("server_stats", {

        name = "Server Statistics",

        description =
            "Tracked player and server statistics.",

        order = 60,

        screen = "KIPN_ServerStats",

        requiresSession = false,

        permissions = {},
        capabilities = {},
        classifications = {},

    })

    --------------------------------------------------------
    -- ANNOUNCEMENTS (menu program)
    --------------------------------------------------------

    Registry.Register("announcements", {

        name = "Announcements",

        description =
            "Server announcements (and optional Discord feed).",

        order = 70,

        screen = "KIPN_Announcement",

        requiresSession = false,

        permissions = {},
        capabilities = {},
        classifications = {},

    })

    --------------------------------------------------------
    -- USER PREFERENCES (menu program)
    --
    -- Open to everyone. The server only decides that the menu
    -- entry appears; the preferences themselves are stored and
    -- applied entirely client-side (KIPN_Preferences.lua).
    --------------------------------------------------------

    Registry.Register("user_preferences", {

        name = "User Preferences",

        description =
            "Temperature, measurement, clock and date display.",

        order = 90,

        screen = "KIPN_UserPreferences",

        requiresSession = false,

        permissions = {},
        capabilities = {},
        classifications = {},

    })

    --------------------------------------------------------
    -- ADMINISTRATION
    --------------------------------------------------------

    Registry.Register("administration", {

        name = "KIPN Administration",

        description =
            "Administrative configuration and system management.",

        order = 900,

        requiresSession = true,

        permissions = {
            "admin.view",
        },

        capabilities = {
            "admin",
        },

        classifications = {},

    })
end

------------------------------------------------------------
-- GET_APPLICATIONS HANDLER
------------------------------------------------------------

local function handleGetApplications(player, args)

    if not player then
        return false, "Player unavailable."
    end

    local steamId = KIPN.Shared.GetPlayerId
        and KIPN.Shared.GetPlayerId(player)
        or nil

    local computerId = args and args.computerId

    local available =
        Registry.GetAvailableApplications({
            steamId = steamId,
            computerId = computerId,
        })

    local rows = {}

    for _, application in ipairs(available) do

        -- Only applications that own a terminal screen appear as a
        -- menu row. Capability-only markers (e.g. "weather") are
        -- resolved by other code paths, not the menu.
        if type(application.screen) == "string"
            and application.screen ~= ""
        then

            rows[#rows + 1] = {
                id = application.id,
                name = application.name or application.id,
                order = tonumber(application.order) or 500,
                screen = application.screen,
            }
        end
    end

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.APPLICATIONS_DATA,
        {
            applications = rows,
        }
    )

    return true
end

------------------------------------------------------------
-- INITIALIZATION
--
-- Exposed as Registry.Initialize so KIPN_Server.lua's
-- initServer() picks it up via its generic
-- initializeService("ApplicationRegistry", ..., "Initialize")
-- call, made once KIPN.Server.Data/GetData is already bound.
--
-- IMPORTANT: this must NOT be wired up via
-- Events.OnGameStart.Add(). OnGameStart is a CLIENT lifecycle
-- event -- it does not fire in the server Lua context (see the
-- matching note in KIPN_Server.lua). A previous version of this
-- function self-registered that way, which meant
-- registerBuiltInApplications() silently never ran on a live
-- server: every built-in application (property_claim,
-- excavation, vehicle_registration, etc.) stayed unregistered
-- for the life of the server, and every command handler that
-- gates on registry.IsAvailable() for one of them failed with
-- "APPLICATION_NOT_FOUND". initializeService() treats a missing
-- Initialize method as "no initializer" rather than an error, so
-- this failed silently with no error logged.
------------------------------------------------------------

function Registry.Initialize()
    if not KIPN
        or not KIPN.Server
        or not KIPN.Server.GetData then

        logError(
            "Application Registry initialization deferred: " ..
            "KIPN.Server is not ready yet."
        )

        return
    end

    local data =
        KIPN.Server.GetData()

    if not data then
        logError(
            "Application Registry initialization failed: " ..
            "KIPN data unavailable."
        )

        return
    end

    registerBuiltInApplications()

    ----------------------------------------------------------
    -- GET_APPLICATIONS COMMAND
    --
    -- The client main menu asks for the list of applications it
    -- should show, given the requesting player's identity and the
    -- computer they are using. All permission / capability / zone /
    -- powered-computer gating happens in GetAvailableApplications();
    -- the client renders the result as-is.
    ----------------------------------------------------------

    if type(KIPN.Server.RegisterCommandHandler) == "function"
        and KIPN.Shared.Commands.GET_APPLICATIONS
    then

        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_APPLICATIONS,
            handleGetApplications
        )
    end

    ----------------------------------------------------------
    -- INSTALLED KIPN MODULES
    --
    -- The KIP Network Terminal host plus every companion service mod
    -- that registered itself (Government Services, Vehicle Services,
    -- ...). Add-ons call RegisterService() at module load, so the
    -- registry is already populated by the time this runs.
    ----------------------------------------------------------

    local moduleCount = 1  -- the KIPN Terminal host itself
    local moduleNames = { "KIPN Terminal" }

    for serviceName in pairs(KIPN.Server._registeredServices or {}) do
        moduleCount = moduleCount + 1
        moduleNames[#moduleNames + 1] = tostring(serviceName)
    end

    table.sort(moduleNames)

    Registry.InstalledModuleCount = moduleCount

    log(
        "Application Registry initialized. " ..
        "Installed KIPN modules=" .. tostring(moduleCount) ..
        " (" .. table.concat(moduleNames, ", ") .. "); " ..
        "menu programs registered=" .. tostring(Registry.Count())
    )
end

print("[KIPN] Application Registry loaded")
