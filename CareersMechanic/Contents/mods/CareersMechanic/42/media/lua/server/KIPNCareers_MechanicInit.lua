-- KIPNCareers_MechanicInit.lua
--
-- Entry point that attaches the Mechanic profession to the Careers
-- framework and the KIP Network Terminal host the supported way (the
-- Government / Vehicle Services pattern):
--   * registers the careers.mechanic.owner permission,
--   * registers the MECHANIC SERVICES and MECHANIC SHOP menu programs,
--   * registers a "CareersMechanic" add-on service whose initialize() brings
--     up KIPNCareers_MechanicServer after every KIPN built-in.
--
-- The "career_services" zone type itself (used for license purchases) is
-- registered once by the Careers Framework's own Init
-- (KIPNCareers_Init.lua), which this mod requires.

if isClient() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_MechanicShared"
require "KIPNCareers_Economy"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_MechanicServer"

local Shared = KIPNCareers.Shared
local Mechanic = KIPNCareers.Mechanic

local function log(message)
    print("[KIPN CAREERS][Mechanic] " .. tostring(message))
end

------------------------------------------------------------
-- PERMISSIONS  (additive)
------------------------------------------------------------

if KIPN and KIPN.Server and KIPN.Server.Permissions
    and type(KIPN.Server.Permissions.RegisterPermission) == "function"
then
    -- Granted to no role: handed out per-identity by
    -- KIPNCareers_MechanicServer when a mechanic shop is established.
    KIPN.Server.Permissions.RegisterPermission(Mechanic.Permissions.OWNER, {
        name = "Mechanic Shop Owner",
        description = "Operate an established mechanic shop.",
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

    R(Mechanic.Applications.SERVICES, {
        name = "Mechanic Services",
        description = "Buy a mechanic license, fill work orders, and read shop messages.",
        order = 72,
        screen = "KIPN_MechanicServices",
        requiresSession = true,
        permissions = {},
        capabilities = { Shared.Capabilities.CAREER_SERVICES },
        classifications = {},
    })

    R(Mechanic.Applications.SHOP, {
        name = "Mechanic Shop",
        description = "Your shop: profile, business containers, work queue, and Work Order Complete.",
        order = 73,
        screen = "KIPN_MechanicShop",
        requiresSession = true,
        permissions = { Mechanic.Permissions.OWNER },
        capabilities = { Mechanic.Capabilities.SHOP },
        classifications = {},
    })
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
------------------------------------------------------------

if KIPN and KIPN.Server and type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("CareersMechanic", {
        apiVersion = 1,
        dependsOn = {
            "WorldRegistry",
            "ApplicationRegistry",
            "Permissions",
            "AuthService",
        },
        order = 700,
        initialize = function()
            local mechanic = KIPNCareers.MechanicServer
            if not mechanic or type(mechanic.Initialize) ~= "function" then
                log("ERROR: KIPNCareers.MechanicServer.Initialize unavailable.")
                return false
            end
            local ok = mechanic.Initialize()
            log("Mechanic profession " .. (ok and "initialized." or "initialization deferred."))
            return ok
        end,
    })
else
    log("ERROR: KIPN.Server.RegisterService unavailable; Mechanic will fall back to event bootstrap.")
end

print("[KIPN] Careers Mechanic init module loaded")
