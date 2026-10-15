-- KIPNCareers_BlacksmithInit.lua
--
-- Entry point that attaches the Blacksmith profession to the Careers
-- framework and the KIP Network Terminal host the supported way (the
-- Government / Vehicle Services pattern):
--   * registers the careers.blacksmith.owner permission,
--   * registers the BLACKSMITH SERVICES and BLACKSMITH SHOP menu programs,
--   * registers a "CareersBlacksmith" add-on service whose initialize() brings
--     up KIPNCareers_BlacksmithServer after every KIPN built-in.
--
-- The "career_services" zone type itself (used for license purchases) is
-- registered once by the Careers Framework's own Init
-- (KIPNCareers_Init.lua), which this mod requires.

if isClient() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_BlacksmithShared"
require "KIPNCareers_Economy"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_BlacksmithServer"

local Shared = KIPNCareers.Shared
local Blacksmith = KIPNCareers.Blacksmith

local function log(message)
    print("[KIPN CAREERS][Blacksmith] " .. tostring(message))
end

------------------------------------------------------------
-- PERMISSIONS  (additive)
------------------------------------------------------------

if KIPN and KIPN.Server and KIPN.Server.Permissions
    and type(KIPN.Server.Permissions.RegisterPermission) == "function"
then
    -- Granted to no role: handed out per-identity by
    -- KIPNCareers_BlacksmithServer when a shop is established.
    KIPN.Server.Permissions.RegisterPermission(Blacksmith.Permissions.OWNER, {
        name = "Blacksmith Shop Owner",
        description = "Operate an established blacksmith shop.",
        grantToRoles = {},
    })
end

------------------------------------------------------------
-- MENU PROGRAMS  (additive)
------------------------------------------------------------

if KIPN and KIPN.Server and KIPN.Server.ApplicationRegistry
    and type(KIPN.Server.ApplicationRegistry.Register) == "function"
then
    local R = KIPN.Server.ApplicationRegistry.Register

    R(Blacksmith.Applications.SERVICES, {
        name = "Blacksmith Services",
        description = "Buy a blacksmith license, submit forge orders, and read shop messages.",
        order = 74,
        screen = "KIPN_BlacksmithServices",
        requiresSession = true,
        permissions = {},
        capabilities = { Shared.Capabilities.CAREER_SERVICES },
        classifications = {},
    })

    R(Blacksmith.Applications.SHOP, {
        name = "Blacksmith Shop",
        description = "Your shop: profile, business containers, work queue, and Work Order Complete.",
        order = 75,
        screen = "KIPN_BlacksmithShop",
        requiresSession = true,
        permissions = { Blacksmith.Permissions.OWNER },
        capabilities = { Blacksmith.Capabilities.SHOP },
        classifications = {},
    })
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
------------------------------------------------------------

if KIPN and KIPN.Server and type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("CareersBlacksmith", {
        apiVersion = 1,
        dependsOn = {
            "WorldRegistry",
            "ApplicationRegistry",
            "Permissions",
            "AuthService",
        },
        order = 700,
        initialize = function()
            local blacksmith = KIPNCareers.BlacksmithServer
            if not blacksmith or type(blacksmith.Initialize) ~= "function" then
                log("ERROR: KIPNCareers.BlacksmithServer.Initialize unavailable.")
                return false
            end
            local ok = blacksmith.Initialize()
            log("Blacksmith profession " .. (ok and "initialized." or "initialization deferred."))
            return ok
        end,
    })
else
    log("ERROR: KIPN.Server.RegisterService unavailable; Blacksmith will fall back to event bootstrap.")
end

print("[KIPN] Careers Blacksmith init module loaded")
