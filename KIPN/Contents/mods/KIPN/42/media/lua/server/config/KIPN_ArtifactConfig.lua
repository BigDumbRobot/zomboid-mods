-- KIPN_ArtifactConfig.lua
--
-- Server-authoritative KIPN artifact configuration.
--
-- Location:
--   media/lua/server/config/KIPN_ArtifactConfig.lua
--
-- Responsibilities:
--   * Define registration artifact policy.
--   * Define claim artifact policy.
--   * Define artifact item identifiers.
--   * Define artifact lifecycle defaults.
--   * Expose an Initialize() method so KIPN_Server's
--     initializeService() can load it cleanly.
--
-- IMPORTANT:
--
-- Registration artifacts and claim artifacts are physical
-- inventory items.
--
-- They are NOT account credentials.
-- They are NOT authentication tokens.
-- They do NOT identify the account that crafted them.
--
-- Registration artifact lifecycle:
--
--   materials
--       ↓
--   registration artifact
--       ↓
--   authorized KIPN computer
--       +
--   appropriate WorldRegistry zone
--       ↓
--   claim artifact
--
-- Claim artifact lifecycle:
--
--   claim artifact
--       ↓
--   player carries artifact
--       +
--   appropriate WorldRegistry zone
--       +
--   valid claim target
--       ↓
--   ownership established
--       ↓
--   claim artifact consumed
--
-- Actual artifact validation / consumption belongs to the
-- artifact/token/claim services, not this configuration file.

if isClient() and not isServer() then
    return
end

require "KIPN/KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ArtifactConfig =
    KIPN.Server.ArtifactConfig or {}

local ArtifactConfig =
    KIPN.Server.ArtifactConfig

------------------------------------------------------------
-- ARTIFACT ITEM IDENTIFIERS
------------------------------------------------------------
--
-- These are the inventory item types used by KIPN.
--
-- The actual item definitions belong in the appropriate
-- media/scripts item files.
------------------------------------------------------------

-- Per-service registration + claim item types. No longer a fixed
-- table: a companion service mod registers its own via
-- ArtifactConfig.RegisterArtifactType() (exposed as
-- KIPN.Server.ArtifactService.RegisterArtifactType) at module load.
-- The generic artifact engine (CreateArtifact / ValidateArtifact /
-- ConsumeArtifactItem) never needs to know the item names -- it is
-- handed them by the caller.
ArtifactConfig.RegistrationItems = {}
ArtifactConfig.ClaimItems = {}

-- serviceKey -> def (registrationItem, claimItem, zoneClassification, ...)
ArtifactConfig.ArtifactTypeDefs = {}

function ArtifactConfig.RegisterArtifactType(serviceKey, def)

    if type(serviceKey) ~= "string"
        or serviceKey == ""
    then
        print("[KIPN ARTIFACT CONFIG] RegisterArtifactType rejected: invalid key.")
        return false
    end

    def = def or {}

    if ArtifactConfig.ArtifactTypeDefs[serviceKey] then
        return true
    end

    def.serviceKey = serviceKey
    ArtifactConfig.ArtifactTypeDefs[serviceKey] = def

    if type(def.registrationItem) == "string" then
        ArtifactConfig.RegistrationItems[serviceKey] = def.registrationItem
    end

    if type(def.claimItem) == "string" then
        ArtifactConfig.ClaimItems[serviceKey] = def.claimItem
    end

    return true
end

-- Terminal registers no artifact types. Each service module registers
-- the type(s) it owns: KIPN: Government Services -> Property / Excavation
-- (KIPN_GovArtifactService.lua); KIPN: Vehicle Services -> Vehicle
-- (KIPN_VehicleArtifactService.lua).

------------------------------------------------------------
-- ARTIFACT TYPES
------------------------------------------------------------
--
-- These identifiers are internal KIPN policy identifiers.
--
-- They are deliberately separate from the item type names.
------------------------------------------------------------

ArtifactConfig.Types = {

    Registration =
        "registration",

    Claim =
        "claim",

}

------------------------------------------------------------
-- REGISTRATION ARTIFACT POLICY
------------------------------------------------------------
--
-- Registration artifacts are temporary bearer artifacts
-- carried by the player to an authorized KIPN computer.
--
-- Possessing one does NOT establish ownership.
-- Possessing one does NOT authenticate an account.
------------------------------------------------------------

ArtifactConfig.Registration = {

    Enabled = true,

    VehicleEnabled = true,

    PropertyEnabled = true,

    ExcavationEnabled = true,

}

------------------------------------------------------------
-- CLAIM ARTIFACT POLICY
------------------------------------------------------------
--
-- Claim artifacts authorize a single claim operation.
--
-- The artifact is only valid when:
--
--   1. The player possesses the artifact.
--   2. The player is inside the appropriate registered zone.
--   3. The target is valid for the artifact.
--   4. The artifact has not already been consumed/invalidated.
--
------------------------------------------------------------

ArtifactConfig.Claim = {

    Enabled = true,

    VehicleEnabled = true,

    PropertyEnabled = true,

    ExcavationEnabled = true,

    ConsumeOnSuccessfulClaim = true,

}

------------------------------------------------------------
-- ARTIFACT EXPIRATION
------------------------------------------------------------
--
-- Registration/claim artifact expiration is per-service policy
-- and lives in KIPN_ClaimConfig.lua (ClaimConfig.Services.*),
-- not here, so a single place answers "how long does a Vehicle
-- vs. House vs. Excavation artifact last."
--
-- See KIPN_ClaimConfig.lua's ServiceKeyByClaimType for the
-- artifact/claim-type -> service-config mapping.
------------------------------------------------------------

------------------------------------------------------------
-- ZONE VALIDATION
------------------------------------------------------------
--
-- Artifacts are not globally valid.
--
-- The artifact type determines which WorldRegistry zone
-- is permitted to create or consume it.
--
-- WorldRegistry remains responsible for identifying the
-- actual world zone.
--
-- ArtifactConfig only defines whether zone validation is
-- required.
------------------------------------------------------------

ArtifactConfig.ZoneValidation = {

    RegistrationRequiresZone = true,

    ClaimRequiresZone = true,

}

------------------------------------------------------------
-- COMPUTER VALIDATION
------------------------------------------------------------
--
-- Registration artifacts must be processed through an
-- authorized KIPN computer.
--
-- Claim artifacts are NOT required to be used at a computer.
--
-- The player instead takes the claim artifact to the target
-- object inside the appropriate zone.
------------------------------------------------------------

ArtifactConfig.ComputerValidation = {

    RegistrationRequiresComputer = true,

    ClaimRequiresComputer = false,

}

------------------------------------------------------------
-- TARGET VALIDATION
------------------------------------------------------------
--
-- Claim artifacts must correspond to a compatible target.
--
-- For example:
--
--   VehicleClaimToken
--       → vehicle
--
--   PropertyClaimToken
--       → property
--
------------------------------------------------------------

ArtifactConfig.TargetValidation = {

    VehicleClaimRequiresVehicle = true,

    PropertyClaimRequiresProperty = true,

}

------------------------------------------------------------
-- BEARER POLICY
------------------------------------------------------------
--
-- Artifacts are physical inventory objects.
--
-- They are not permanently bound to the account that created
-- them.
--
-- This allows the artifact to function as a bearer credential.
--
-- Server-side validation remains authoritative.
------------------------------------------------------------

ArtifactConfig.Bearer = {

    RegistrationArtifactIsBearer = true,

    ClaimArtifactIsBearer = true,

    BindRegistrationToAccount = false,

    BindClaimToAccount = false,

}

------------------------------------------------------------
-- CONSUMPTION POLICY
------------------------------------------------------------
--
-- Consumption must happen only after the server has
-- successfully validated the complete operation.
--
-- Never consume an artifact merely because the player
-- attempted an operation.
--
-- Registration Forms are always consumed after a claim artifact
-- is created successfully. That lifecycle rule is enforced by
-- ArtifactService and is intentionally not configurable.
------------------------------------------------------------

ArtifactConfig.Consumption = {

    ConsumeClaimAfterSuccessfulClaim = true,

    ConsumeOnValidationFailure = false,

}

------------------------------------------------------------
-- DUPLICATION POLICY
------------------------------------------------------------
--
-- Artifact duplication must never be trusted to the client.
--
-- The actual anti-duplication implementation belongs to the
-- authoritative artifact/token service.
------------------------------------------------------------

ArtifactConfig.Duplication = {

    ServerAuthoritative = true,

    RejectInvalidArtifacts = true,

    RejectConsumedArtifacts = true,

    RejectExpiredArtifacts = true,

}

------------------------------------------------------------
-- SANDBOX OVERRIDES
------------------------------------------------------------
--
-- These values may later be exposed through
-- sandbox-options.txt.
--
-- For now the configuration provides stable defaults.
--
-- We intentionally do not assume sandbox fields exist until
-- they are actually added to the sandbox definition.
------------------------------------------------------------

local function applySandboxOverrides()

    print(
        "[KIPN ARTIFACT CONFIG] " ..
        "Applying sandbox overrides."
    )

    local sv =
        SandboxVars
        and SandboxVars.KIPN

    if not sv then

        print(
            "[KIPN ARTIFACT CONFIG] " ..
            "SandboxVars.KIPN not available; " ..
            "keeping configured defaults."
        )

        return true
    end

    --------------------------------------------------------
    -- GLOBAL ENABLE/DISABLE
    --------------------------------------------------------

    if sv.ArtifactsEnabled ~= nil then

        ArtifactConfig.Registration.Enabled =
            sv.ArtifactsEnabled

        ArtifactConfig.Claim.Enabled =
            sv.ArtifactsEnabled
    end

    --------------------------------------------------------
    -- REGISTRATION ARTIFACTS
    --------------------------------------------------------

    if sv.VehicleRegistrationEnabled ~= nil then

        ArtifactConfig.Registration.VehicleEnabled =
            sv.VehicleRegistrationEnabled
    end

    if sv.PropertyRegistrationEnabled ~= nil then

        ArtifactConfig.Registration.PropertyEnabled =
            sv.PropertyRegistrationEnabled
    end

    if sv.ExcavationRegistrationEnabled ~= nil then

        ArtifactConfig.Registration.ExcavationEnabled =
            sv.ExcavationRegistrationEnabled
    end

    --------------------------------------------------------
    -- CLAIM ARTIFACTS
    --------------------------------------------------------

    if sv.VehicleClaimsEnabled ~= nil then

        ArtifactConfig.Claim.VehicleEnabled =
            sv.VehicleClaimsEnabled
    end

    if sv.SafehouseClaimsEnabled ~= nil then

        ArtifactConfig.Claim.PropertyEnabled =
            sv.SafehouseClaimsEnabled
    end

    if sv.ExcavationClaimsEnabled ~= nil then

        ArtifactConfig.Claim.ExcavationEnabled =
            sv.ExcavationClaimsEnabled
    end

    --------------------------------------------------------
    -- ADMIN RUNTIME OVERRIDES (win over sandbox)
    --------------------------------------------------------
    --
    -- ArtifactConfig manages its own sandbox resolution (its
    -- fields are nested, unlike the flat configs handled by
    -- KIPN.Server.Settings.ApplyToConfig), so it also applies
    -- its own admin overrides here instead of relying on the
    -- generic ApplyToConfig() admin-override step.
    --------------------------------------------------------

    local admin =
        KIPN.Server.Settings
        and KIPN.Server.Settings.GetAdminOverrides
        and KIPN.Server.Settings.GetAdminOverrides("Artifact")
        or {}

    if admin.ArtifactsEnabled ~= nil then

        ArtifactConfig.Registration.Enabled =
            admin.ArtifactsEnabled

        ArtifactConfig.Claim.Enabled =
            admin.ArtifactsEnabled
    end

    if admin.VehicleRegistrationEnabled ~= nil then

        ArtifactConfig.Registration.VehicleEnabled =
            admin.VehicleRegistrationEnabled
    end

    if admin.PropertyRegistrationEnabled ~= nil then

        ArtifactConfig.Registration.PropertyEnabled =
            admin.PropertyRegistrationEnabled
    end

    if admin.ExcavationRegistrationEnabled ~= nil then

        ArtifactConfig.Registration.ExcavationEnabled =
            admin.ExcavationRegistrationEnabled
    end

    if admin.VehicleClaimsEnabled ~= nil then

        ArtifactConfig.Claim.VehicleEnabled =
            admin.VehicleClaimsEnabled
    end

    if admin.SafehouseClaimsEnabled ~= nil then

        ArtifactConfig.Claim.PropertyEnabled =
            admin.SafehouseClaimsEnabled
    end

    if admin.ExcavationClaimsEnabled ~= nil then

        ArtifactConfig.Claim.ExcavationEnabled =
            admin.ExcavationClaimsEnabled
    end

    return true
end

------------------------------------------------------------
-- VALIDATE CONFIGURATION
------------------------------------------------------------

local function validateConfiguration()

    print(
        "[KIPN ARTIFACT CONFIG] " ..
        "Validating configuration."
    )

    local valid = true

    if type(
        ArtifactConfig.RegistrationItems
    ) ~= "table"
    then

        logError(
            "[KIPN ARTIFACT CONFIG] " ..
            "RegistrationItems is invalid."
        )

        valid = false
    end

    if type(
        ArtifactConfig.ClaimItems
    ) ~= "table"
    then

        logError(
            "[KIPN ARTIFACT CONFIG] " ..
            "ClaimItems is invalid."
        )

        valid = false
    end

    if type(
        ArtifactConfig.Types
    ) ~= "table"
    then

        logError(
            "[KIPN ARTIFACT CONFIG] " ..
            "Types is invalid."
        )

        valid = false
    end

    return valid
end

------------------------------------------------------------
-- INITIALIZE
------------------------------------------------------------

function ArtifactConfig.Initialize()

    print(
        "[KIPN ARTIFACT CONFIG] " ..
        "Initializing."
    )

    local sandboxOk =
        applySandboxOverrides()

    local valid =
        validateConfiguration()

    local success =
        sandboxOk
        and valid

    print(
        "[KIPN ARTIFACT CONFIG] " ..
        "Initialized. success=" ..
        tostring(success)
    )

    return success
end

------------------------------------------------------------
-- MODULE READY
------------------------------------------------------------

print(
    "[KIPN ARTIFACT CONFIG] " ..
    "Module loaded."
)
