-- KIPN_VehicleServicesInit.lua
--
-- Entry point for the KIPN: Vehicle Services add-on module. Attaches to
-- KIP Network Terminal's host framework:
--
--   * registers the "dealership" zone type, the vehicle permissions,
--     and the Vehicle Registration / Vehicle Records menu programs
--     (additive -- Terminal still carries in-tree copies until its
--     Phase D cleanup; RegisterX dedupes),
--   * registers a "VehicleServices" add-on service whose initialize()
--     runs (after every Terminal built-in) the Initialize() of the
--     carved Vehicle Services server modules.

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_Server"
require "KIPN_ClaimService"
require "KIPN_ArtifactService"
require "KIPN_VehClaimConfig"
require "KIPN_VehicleClaimService"
require "KIPN_VehicleArtifactService"
require "KIPN_VehicleEnforcement"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

local function log(message)
    print("[KIPN VEHICLE SERVICES] " .. tostring(message))
end

------------------------------------------------------------
-- ZONE TYPE  (additive)
------------------------------------------------------------

if KIPN.Server.WorldRegistry
    and type(KIPN.Server.WorldRegistry.RegisterZoneType) == "function"
then
    KIPN.Server.WorldRegistry.RegisterZoneType("dealership", {
        label = "Car Dealership",
        defaultCapabilities = {
            ["vehicle.lookup"] = true,
            ["vehicle.claim"] = true,
            ["vehicle.transfer"] = true,
        },
        classificationField = "dealership",
    })
end

------------------------------------------------------------
-- PERMISSIONS  (additive)
------------------------------------------------------------

if KIPN.Server.Permissions
    and type(KIPN.Server.Permissions.RegisterPermission) == "function"
then
    local P = KIPN.Server.Permissions
    local PLAYER_ADMIN = { "PLAYER", "ADMIN" }

    P.RegisterPermission("vehicle.lookup", {
        name = "Vehicle Lookup",
        description = "Look up vehicle registration records.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("vehicle.claim", {
        name = "Vehicle Claim",
        description = "Register a vehicle to an account.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("vehicle.transfer", {
        name = "Vehicle Transfer",
        description = "Transfer a registered vehicle.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("vehicle.revoke", {
        name = "Vehicle Revoke",
        description = "Revoke a vehicle registration.",
        grantToRoles = { "ADMIN" },
    })
end

------------------------------------------------------------
-- MENU PROGRAMS  (additive)
------------------------------------------------------------

if KIPN.Server.ApplicationRegistry
    and type(KIPN.Server.ApplicationRegistry.Register) == "function"
then
    local R = KIPN.Server.ApplicationRegistry.Register

    R("vehicle_registration", {
        name = "Vehicle Registration",
        description = "Register and manage vehicle ownership.",
        order = 30,
        screen = "KIPN_VehicleRegistration",
        requiresSession = true,
        permissions = { "vehicle.claim" },
        capabilities = { "vehicle.claim" },
        classifications = { "DEALERSHIP" },
    })

    R("vehicle_records", {
        name = "Vehicle Records",
        description = "Review your registered vehicle ownership claims.",
        order = 35,
        screen = "KIPN_VehicleRecords",
        requiresSession = true,
        permissions = { "vehicle.lookup" },
        capabilities = {},
        classifications = {},
    })
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
------------------------------------------------------------

if type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("VehicleServices", {

        dependsOn = {
            "WorldRegistry",
            "ClaimService",
            "ArtifactService",
            "Permissions",
            "ApplicationRegistry",
        },

        order = 610,

        initialize = function()

            local ok = true

            local function run(label, fn)
                if type(fn) ~= "function" then
                    log("ERROR: " .. label .. " unavailable.")
                    ok = false
                    return
                end
                local success, result = pcall(fn)
                if not success then
                    log("ERROR: " .. label .. " raised: " .. tostring(result))
                    ok = false
                elseif result == false then
                    log("ERROR: " .. label .. " returned false.")
                    ok = false
                end
            end

            local vehClaim = KIPN.Server.VehClaimService
            local vehArtifact = KIPN.Server.VehArtifactService
            local vehEnforce = KIPN.Server.VehEnforcement

            run("VehClaimService.Initialize",
                vehClaim and vehClaim.Initialize)
            run("VehArtifactService.Initialize",
                vehArtifact and vehArtifact.Initialize)
            run("VehEnforcement.Initialize",
                vehEnforce and vehEnforce.Initialize)

            log("Vehicle Services " ..
                (ok and "initialized." or "initialized WITH ERRORS."))
            return ok
        end,
    })

else
    log("ERROR: KIPN.Server.RegisterService unavailable; " ..
        "Vehicle Services will not initialize.")
end

print("[KIPN] Vehicle Services init module loaded")
