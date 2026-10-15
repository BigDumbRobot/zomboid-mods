-- KIPN_GovServicesInit.lua
--
-- Entry point for the COMPUTER Safehouse and Land Claims add-on module.
-- Attaches to KIP Network Terminal's host framework:
--
--   * registers the "government" zone type, the property / excavation
--     permissions, and the Government Services / Property Records menu
--     programs (each RegisterX call is idempotent),
--   * registers a "GovernmentServices" add-on service whose initialize()
--     runs (after every Terminal built-in) the Initialize() of this
--     mod's server modules.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_ClaimService"
require "KIPN_ArtifactService"
require "KIPN_GovClaimConfig"
require "KIPN_GovCraftingReference"
require "KIPN_PropertyClaimService"
require "KIPN_GovArtifactService"
require "KIPN_SafehouseService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

local function log(message)
    print("[KIPN GOV SERVICES] " .. tostring(message))
end

------------------------------------------------------------
-- ZONE TYPE  (additive)
------------------------------------------------------------

if KIPN.Server.WorldRegistry
    and type(KIPN.Server.WorldRegistry.RegisterZoneType) == "function"
then
    KIPN.Server.WorldRegistry.RegisterZoneType("government", {
        label = "Government Building",
        defaultCapabilities = {
            ["property.lookup"] = true,
            ["property.claim"] = true,
            ["property.transfer"] = true,
            ["excavation.lookup"] = true,
            ["excavation.claim"] = true,
        },
        classificationField = "government",
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

    P.RegisterPermission("property.lookup", {
        name = "Property Lookup",
        description = "Look up property records.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("property.claim", {
        name = "Property Claim",
        description = "Register a property to an account.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("property.transfer", {
        name = "Property Transfer",
        description = "Transfer property ownership.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("excavation.lookup", {
        name = "Excavation Lookup",
        description = "Look up excavation permits.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("excavation.claim", {
        name = "Excavation Permit",
        description = "Register an excavation permit.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("safehouse.admin", {
        name = "Safehouse Administration",
        description = "Administer KIPN managed safehouses.",
        grantToRoles = { "ADMIN" },
    })
    P.RegisterPermission("safehouse.owner", {
        name = "Safehouse Ownership",
        description = "Own a KIPN managed safehouse.",
        grantToRoles = PLAYER_ADMIN,
    })
end

------------------------------------------------------------
-- MENU PROGRAMS  (additive)
------------------------------------------------------------

if KIPN.Server.ApplicationRegistry
    and type(KIPN.Server.ApplicationRegistry.Register) == "function"
then
    local R = KIPN.Server.ApplicationRegistry.Register

    R("government_services", {
        name = "Government Services",
        description = "Craft Safehouse Deeds and Excavation Permits.",
        order = 20,
        screen = "KIPN_GovernmentServices",
        requiresSession = true,
        permissions = { "property.claim" },
        capabilities = { "property.claim" },
        classifications = { "GOVERNMENT" },
    })

    R("property_records", {
        name = "Property Records",
        description = "Review your Safehouse and Excavation ownership claims.",
        order = 25,
        screen = "KIPN_PropertyRecords",
        requiresSession = true,
        permissions = { "property.lookup" },
        capabilities = {},
        classifications = {},
    })

    R("property_claim", {
        name = "Property Claim",
        description = "Convert a property registration into a safehouse claim artifact.",
        order = 45,
        requiresSession = true,
        permissions = { "property.claim" },
        capabilities = { "property.claim" },
        classifications = { "GOVERNMENT" },
    })

    R("excavation", {
        name = "Excavation Permits",
        description = "Manage excavation permits and registrations.",
        order = 50,
        requiresSession = true,
        permissions = { "excavation.claim" },
        capabilities = { "excavation.claim" },
        classifications = { "GOVERNMENT" },
    })
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
------------------------------------------------------------

if type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("GovernmentServices", {

        dependsOn = {
            "WorldRegistry",
            "ClaimService",
            "ArtifactService",
            "Permissions",
            "ApplicationRegistry",
        },

        order = 600,

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

            local claimConfig = KIPN.Server.ClaimConfig
            local craftingRef = KIPN.Server.GovCraftingReference
            local govClaim = KIPN.Server.GovClaimService
            local govArtifact = KIPN.Server.GovArtifactService
            local safehouse = KIPN.Server.SafehouseService

            run("ClaimConfig.InitializeGovExcavationTiers",
                claimConfig and claimConfig.InitializeGovExcavationTiers)
            run("GovCraftingReference.Initialize",
                craftingRef and craftingRef.Initialize)
            run("GovClaimService.Initialize",
                govClaim and govClaim.Initialize)
            run("GovArtifactService.Initialize",
                govArtifact and govArtifact.Initialize)
            run("SafehouseService.Initialize",
                safehouse and safehouse.Initialize)

            log("Government Services " ..
                (ok and "initialized." or "initialized WITH ERRORS."))
            return ok
        end,
    })

else
    log("ERROR: KIPN.Server.RegisterService unavailable; " ..
        "Government Services will not initialize.")
end

print("[KIPN] Government Services init module loaded")
