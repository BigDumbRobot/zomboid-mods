-- KIPNCareers_DealerInit.lua
--
-- Entry point that attaches the Drug Dealer profession to the Careers
-- framework and the KIP Network Terminal host the supported way (the
-- Government / Vehicle Services pattern):
--   * registers the careers.dealer / careers.business.owner permissions,
--   * registers the CAREER SERVICES and BUSINESS PROFILE menu programs,
--   * registers a "CareersDealer" add-on service whose initialize() brings
--     up KIPNCareers_DealerServer after every KIPN built-in.
--
-- The "career_services" zone type itself is registered once by the
-- Careers Framework's own Init (KIPNCareers_Init.lua), which this mod
-- requires.

if isClient() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_DealerShared"
require "KIPNCareers_Economy"
require "KIPNCareers_NarcoticsAdapter"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_DealerServer"

local Shared = KIPNCareers.Shared
local Dealer = KIPNCareers.Dealer

local function log(message)
    print("[KIPN CAREERS][Dealer] " .. tostring(message))
end

------------------------------------------------------------
-- PERMISSIONS  (additive)
------------------------------------------------------------

if KIPN and KIPN.Server and KIPN.Server.Permissions
    and type(KIPN.Server.Permissions.RegisterPermission) == "function"
then
    local P = KIPN.Server.Permissions
    P.RegisterPermission(Dealer.Permissions.DEALER, {
        name = "Drug Dealer",
        description = "Hold a Drug Dealer business license.",
        grantToRoles = { "PLAYER", "ADMIN" },
    })
    -- Deliberately granted to no role: handed out per-identity by
    -- KIPNCareers_DealerServer when a storefront is established, revoked if it closes.
    P.RegisterPermission(Dealer.Permissions.BUSINESS_OWNER, {
        name = "Drug Dealer Business Owner",
        description = "Operate an established Drug Dealer storefront.",
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

    R(Dealer.Applications.CAREER_SERVICES, {
        name = "Career Services",
        description = "Buy a license, run your business, and take work orders.",
        order = 70,
        screen = "KIPN_CareerServices",
        requiresSession = true,
        permissions = {},
        capabilities = { Shared.Capabilities.CAREER_SERVICES },
        classifications = {},
    })

    R(Dealer.Applications.BUSINESS_PROFILE, {
        name = "Business Profile",
        description = "Your storefront: details, work orders, and order completion.",
        order = 71,
        screen = "KIPN_CareersBusinessProfile",
        requiresSession = true,
        permissions = { Dealer.Permissions.BUSINESS_OWNER },
        capabilities = { Dealer.Capabilities.BUSINESS },
        classifications = {},
    })
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
------------------------------------------------------------

if KIPN and KIPN.Server and type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("CareersDealer", {
        apiVersion = 1,
        dependsOn = {
            "WorldRegistry",
            "ApplicationRegistry",
            "Permissions",
            "AuthService",
        },
        order = 700,
        initialize = function()
            local server = KIPNCareers.DealerServer
            if not server or type(server.Initialize) ~= "function" then
                log("ERROR: KIPNCareers.DealerServer.Initialize unavailable.")
                return false
            end
            local ok = server.Initialize()
            log("Drug Dealer " .. (ok and "initialized." or "initialization deferred."))
            return ok
        end,
    })
else
    log("ERROR: KIPN.Server.RegisterService unavailable; Drug Dealer will fall back to event bootstrap.")
end

print("[KIPN] Careers Drug Dealer init module loaded")
