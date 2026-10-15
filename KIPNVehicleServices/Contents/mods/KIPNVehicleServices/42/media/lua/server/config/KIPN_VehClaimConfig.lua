-- KIPN_VehClaimConfig.lua
--
-- Vehicle Services claim policy: registers the "Vehicle" per-service
-- claim config block into KIP Network Terminal's ClaimConfig.
-- Carved from Terminal's server/config/KIPN_ClaimConfig.lua.

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_Server"
require "KIPN/KIPN_ClaimConfig"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ClaimConfig = KIPN.Server.ClaimConfig or {}

local ClaimConfig = KIPN.Server.ClaimConfig

if type(ClaimConfig.RegisterService) == "function" then

    ClaimConfig.RegisterService("Vehicle", {
        MaxClaimsPerPlayer = 5,
        RegistrationExpiryDays = 14,
        ClaimTokenExpiryDays = 14,
        OwnershipExpiryDays = 0,
        ClaimCraftSeconds = 10,

        -- Non-owner vehicle permissions. NonOwnerNoAccess overrides
        -- the other three regardless of their individual values.
        NonOwnerNoAccess = false,
        AllowNonOwnerMechanics = false,
        AllowNonOwnerOpenUnlockedDoors = false,
        AllowNonOwnerTow = false,
    }, "vehicle")

else
    print("[KIPN VEH CLAIM CONFIG] ERROR: ClaimConfig.RegisterService " ..
        "unavailable; Vehicle claim policy not registered.")
end

print("[KIPN] Vehicle Services Claim Config loaded")
