-- KIPN_PostOfficeInit.lua
--
-- Entry point for The Post Office add-on module. Attaches to KIP
-- Network Terminal's host framework:
--
--   * registers the "post_office" and "marketplace" zone types, the
--     PO Box / marketplace permissions, the persisted PO Box registry
--     data domain, and the Postal Services / Marketplace menu programs,
--   * registers a "PostOffice" add-on service whose initialize() runs
--     (after every Terminal built-in) the Initialize() of the Post
--     Office server modules.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "KIPN_PostOfficeShared"
require "KIPN_Server"
require "KIPN_WorldRegistry"
require "KIPN_Permissions"
require "KIPN_ClaimService"
require "KIPN_ArtifactService"
require "KIPN_POBoxConfig"
require "KIPN_POBoxService"
require "KIPN_MarketplaceService"
require "KIPN_POBoxClaimService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

local function log(message)
    print("[KIPN POST OFFICE] " .. tostring(message))
end

------------------------------------------------------------
-- DATA DOMAIN
------------------------------------------------------------
--
-- GetData().poBoxes is the physical PO Box registry owned by
-- KIPN_POBoxService.lua. Must be registered at module load, before
-- Terminal loads its persisted data.
------------------------------------------------------------

if type(KIPN.Server.RegisterDataDomain) == "function" then
    KIPN.Server.RegisterDataDomain("poBoxes", {})
else
    log("ERROR: KIPN.Server.RegisterDataDomain unavailable; " ..
        "the PO Box registry will not persist.")
end

------------------------------------------------------------
-- ZONE TYPES
------------------------------------------------------------

if KIPN.Server.WorldRegistry
    and type(KIPN.Server.WorldRegistry.RegisterZoneType) == "function"
then
    KIPN.Server.WorldRegistry.RegisterZoneType("post_office", {
        label = "Post Office",
        defaultCapabilities = {
            ["po_box.lookup"] = true,
            ["po_box.claim"] = true,
        },
        classificationField = "postOffice",
    })

    KIPN.Server.WorldRegistry.RegisterZoneType("marketplace", {
        label = "KIPN Marketplace",
        defaultCapabilities = {
            ["marketplace.purchase"] = true,
        },
        classificationField = "marketplace",
    })
end

------------------------------------------------------------
-- PERMISSIONS
------------------------------------------------------------

if KIPN.Server.Permissions
    and type(KIPN.Server.Permissions.RegisterPermission) == "function"
then
    local P = KIPN.Server.Permissions
    local PLAYER_ADMIN = { "PLAYER", "ADMIN" }

    P.RegisterPermission("po_box.lookup", {
        name = "PO Box Lookup",
        description = "Look up postal box information.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("po_box.claim", {
        name = "PO Box Claim",
        description = "Register a postal box.",
        grantToRoles = PLAYER_ADMIN,
    })
    P.RegisterPermission("marketplace.purchase", {
        name = "Marketplace Purchase",
        description = "Buy items from the KIPN Marketplace.",
        grantToRoles = PLAYER_ADMIN,
    })
end

------------------------------------------------------------
-- MENU PROGRAMS
------------------------------------------------------------

if KIPN.Server.ApplicationRegistry
    and type(KIPN.Server.ApplicationRegistry.Register) == "function"
then
    local R = KIPN.Server.ApplicationRegistry.Register

    -- KIPN's admin-supplied internal shop is independent of any
    -- external provider and of zones (purchases are zone-gated by the
    -- server, browsing is not), so Marketplace shows on every terminal.
    R("marketplace", {
        name = "Marketplace",
        description = "Browse and buy from the KIPN Marketplace.",
        order = 55,
        screen = "KIPN_Marketplace",
        requiresSession = true,
        permissions = {},
        capabilities = {},
        classifications = {},
    })

    R("po_box", {
        name = "Postal Services",
        description = "Manage postal boxes and mail services.",
        order = 60,
        screen = "KIPN_PostalServices",
        requiresSession = true,
        permissions = { "po_box.claim" },
        capabilities = { "po_box.claim" },
        classifications = { "POST_OFFICE" },
    })
end

------------------------------------------------------------
-- ADD-ON SERVICE REGISTRATION
------------------------------------------------------------

if type(KIPN.Server.RegisterService) == "function" then

    KIPN.Server.RegisterService("PostOffice", {

        dependsOn = {
            "WorldRegistry",
            "ClaimService",
            "ArtifactService",
            "Permissions",
            "ApplicationRegistry",
        },

        order = 620,

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

            local config = KIPN.Server.POBoxConfig
            local poBoxes = KIPN.Server.POBoxService
            local marketplace = KIPN.Server.MarketplaceService
            local poBoxClaims = KIPN.Server.POBoxClaimService

            run("POBoxConfig.Initialize",
                config and config.Initialize)
            run("POBoxService.Initialize",
                poBoxes and poBoxes.Initialize)
            run("MarketplaceService.Initialize",
                marketplace and marketplace.Initialize)
            run("POBoxClaimService.Initialize",
                poBoxClaims and poBoxClaims.Initialize)

            log("The Post Office " ..
                (ok and "initialized." or "initialized WITH ERRORS."))
            return ok
        end,
    })

else
    log("ERROR: KIPN.Server.RegisterService unavailable; " ..
        "The Post Office will not initialize.")
end

print("[KIPN] Post Office init module loaded")
