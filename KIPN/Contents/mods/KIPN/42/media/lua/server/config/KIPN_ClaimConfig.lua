-- KIPN_ClaimConfig.lua
--
-- Server-authoritative KIPN claim configuration.
--
-- Responsibilities:
--   * Define claim / property policy.
--   * Define per-service claim quotas and expiry rules.
--   * Expose an Initialize() method so KIPN_Server's
--     initializeService() can load it cleanly.
--
-- This module intentionally contains configuration only.
-- Actual claim logic lives in KIPN_ClaimService.lua.
--
-- IMPORTANT:
--
-- Quotas and expiry are defined PER SERVICE (Vehicle / House /
-- Excavation) rather than as one global value, because each
-- service has very different real-world semantics (a car decays
-- on its own and can reasonably be owned forever; a house should
-- lapse if nobody renews it).
--
-- "House" is the sandbox-facing/admin-facing name for what the
-- rest of the codebase calls the "property" claim type
-- (ClaimService.Types.PROPERTY, the "property.claim" WorldRegistry
-- capability, etc). That internal name is left as-is; only the
-- sandbox option names/labels use "House". ServiceKeyByClaimType
-- below is the single place that maps between the two.
--
-- Fields, per service:
--   MaxClaimsPerPlayer     - active-claim cap per player for that
--                            service.
--   RegistrationExpiryDays - lifetime of the registration
--                            artifact/token for that service.
--                            0 = never expires.
--   ClaimTokenExpiryDays   - lifetime of the issued claim
--                            artifact/token for that service.
--                            0 = never expires.
--   OwnershipExpiryDays    - lifetime of an ESTABLISHED claim
--                            before it lapses without renewal.
--                            0 = ownership never expires.
--   ClaimCraftSeconds      - how long the client makes the player
--                            wait (a real-time countdown shown in
--                            the requesting screen -- see
--                            KIPN_GovernmentServices.lua /
--                            KIPN_VehicleRegistration.lua) before
--                            sending the Registration -> Claim
--                            artifact exchange command. 0 = instant
--                            (previous behavior). This is a
--                            client-side UX duration ONLY, the same
--                            "hint, not enforced" model already used
--                            by KIPN_RepairComputerAction.lua's
--                            maxTime -- the server accepts the
--                            exchange command whenever it arrives
--                            regardless of how long the client
--                            waited.

if isClient() then return end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ClaimConfig = KIPN.Server.ClaimConfig or {}

local ClaimConfig = KIPN.Server.ClaimConfig

------------------------------------------------------------
-- PER-SERVICE POLICY
------------------------------------------------------------
--
-- Terminal owns no per-service claim policy. Each service mod
-- registers its own at config load via ClaimConfig.RegisterService --
-- KIPN: Government Services registers "House" + "Excavation";
-- KIPN: Vehicle Services registers "Vehicle".
------------------------------------------------------------

ClaimConfig.Services = {}

------------------------------------------------------------
-- SERVICE REGISTRATION  (companion service mods)
------------------------------------------------------------
--
-- Registers a per-service claim policy block into ClaimConfig.Services
-- and its claimType -> serviceKey mapping. Called at config load,
-- before ClaimConfig.Initialize() applies the sandbox overrides, so
-- the registered defaults get "<Service><Field>" sandbox treatment.
------------------------------------------------------------

function ClaimConfig.RegisterService(serviceKey, defaults, claimType)

    if type(serviceKey) ~= "string" or serviceKey == "" then
        print("[KIPN CLAIM CONFIG] RegisterService rejected: invalid key.")
        return false
    end

    if ClaimConfig.Services[serviceKey] then
        return true
    end

    ClaimConfig.Services[serviceKey] =
        type(defaults) == "table" and defaults or {}

    if type(claimType) == "string" and claimType ~= "" then
        ClaimConfig.ServiceKeyByClaimType[claimType] = serviceKey
    end

    return true
end

------------------------------------------------------------
-- DO NOT CLAIM ZONES
------------------------------------------------------------
--
-- Distance (in tiles) a Property or Excavation claim must stay
-- away from any active Do Not Claim zone's drawn boundary -- not
-- merely avoid overlapping it. Read by KIPN_ClaimService.lua's
-- findDoNotClaimZone(). A flat (non-per-service) field, unlike
-- ClaimConfig.Services above, since the same buffer applies
-- identically to both House and Excavation claims; picked up by
-- the generic ApplyToConfig("Claim", ClaimConfig) sandbox
-- override in KIPN_Settings.lua, so the field name must match its
-- sandbox option suffix (KIPN.DoNotClaimZoneBufferTiles) exactly.
------------------------------------------------------------

ClaimConfig.DoNotClaimZoneBufferTiles = 5


------------------------------------------------------------
-- CLAIM TYPE -> SERVICE CONFIG KEY
------------------------------------------------------------
--
-- ClaimService.Types uses lowercase internal identifiers
-- ("vehicle", "property", "excavation"). This maps those to the
-- ClaimConfig.Services key (and sandbox-facing name) for that
-- service.
------------------------------------------------------------

-- Terminal maps only the built-in Vehicle type. Companion services
-- add their own mapping via ClaimConfig.RegisterService(key, defaults,
-- claimType) -- KIPN: Government Services maps property -> House and
-- excavation -> Excavation.
-- Populated by ClaimConfig.RegisterService(key, defaults, claimType).
-- Terminal maps nothing itself.
ClaimConfig.ServiceKeyByClaimType = {}

------------------------------------------------------------
-- SERVICE CONFIG LOOKUP
------------------------------------------------------------

function ClaimConfig.GetServiceConfig(claimType)

    local serviceKey =
        ClaimConfig.ServiceKeyByClaimType[claimType]

    if not serviceKey then
        return nil
    end

    return ClaimConfig.Services[serviceKey]
end

------------------------------------------------------------
-- SANDBOX OVERRIDES
------------------------------------------------------------
--
-- Admin-editable fields, defined in sandbox-options.txt under the
-- "KIPN" page. Field names are "<Service><Field>", e.g.
-- "VehicleMaxClaimsPerPlayer", "HouseOwnershipExpiryDays".
--
-- ClaimConfig.Services is nested, so (like KIPN_ArtifactConfig.lua)
-- it resolves its own sandbox/admin overrides here instead of
-- relying on the generic flat-field KIPN.Server.Settings.ApplyToConfig().
------------------------------------------------------------

local SERVICE_FIELDS = {
    "MaxClaimsPerPlayer",
    "RegistrationExpiryDays",
    "ClaimTokenExpiryDays",
    "OwnershipExpiryDays",
    "AllowNonOwnerEnter",
    "AllowNonOwnerBuild",
    "AllowNonOwnerLoot",
    "AllowNonOwnerExcavate",
    "AllowNonOwnerMechanics",
    "AllowNonOwnerOpenUnlockedDoors",
    "AllowNonOwnerTow",
    "NonOwnerNoAccess",
    "ClaimCraftSeconds",
    "AllowClaimsInKIPNZones",
}

local function applyOverrideSource(source)

    if not source then
        return
    end

    for serviceKey, serviceConfig in pairs(ClaimConfig.Services) do

        for _, fieldName in ipairs(SERVICE_FIELDS) do

            local sandboxKey =
                serviceKey .. fieldName

            local propertyPermissionField =
                serviceKey == "House"
                and string.sub(fieldName, 1, 13)
                    == "AllowNonOwner"

            if not propertyPermissionField
                and source[sandboxKey] ~= nil
            then
                serviceConfig[fieldName] = source[sandboxKey]
            end

        end

    end

end

local function applySandboxOverrides()
    local sv = SandboxVars and SandboxVars.KIPN

    if not sv then
        print(
            "[KIPN CLAIM CONFIG] SandboxVars.KIPN not available " ..
            "yet; keeping hardcoded defaults."
        )
    else
        applyOverrideSource(sv)
    end

    -- Normal claim policy is Sandbox-owned. Runtime Admin Settings
    -- overrides are intentionally not layered over Sandbox values.
end

------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function ClaimConfig.Initialize()
    applySandboxOverrides()

    -- The excavation size-tier config + its GET_EXCAVATION_SIZE_TIERS
    -- handler moved to KIPN: Government Services
    -- (server/config/KIPN_GovClaimConfig.lua).

    print("[KIPN CLAIM CONFIG] Initialized.")
    return true
end
