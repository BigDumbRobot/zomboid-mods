-- KIPNCareers_Init.lua  (framework core)
--
-- Registers what every Careers Framework career shares before any career
-- add-on loads: the "career_services" zone type that authorizes license
-- purchases, and the framework's own commands (KIPNCareers_Services.lua).
-- A career add-on (CareersDrugDealer, CareersMechanic, or a third-party one)
-- registers its own permissions, menu programs, and RegisterService callback
-- in its own Init file -- see KIPNCareers_MechanicInit.lua for the pattern.

if isClient() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_Services"

local Shared = KIPNCareers.Shared

KIPNCareers.ZoneBridge.RegisterZoneType(Shared.ZoneTypes.CAREER_SERVICES, {
    label = "Career Services",
    capabilities = { [Shared.Capabilities.CAREER_SERVICES] = true },
    classificationField = "careerServices",
})

-- Ahead of the careers (order 700), so the inbox and zone commands are the
-- framework's own whichever careers are installed.
if KIPN and KIPN.Server and type(KIPN.Server.RegisterService) == "function" then
    KIPN.Server.RegisterService("CareersFramework", {
        apiVersion = 1,
        dependsOn = { "WorldRegistry", "Permissions", "AuthService" },
        order = 690,
        initialize = function() return KIPNCareers.Services.Initialize() end,
    })
end

print("[KIPN] Careers framework loaded")
