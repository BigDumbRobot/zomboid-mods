-- KIPN_Settings.lua
--
-- KIPN configuration resolver.
--
-- Responsibilities:
--   * Resolve KIPN sandbox configuration.
--   * Apply sandbox values to KIPN configuration tables.
--   * Provide configuration diagnostics.
--
-- IMPORTANT:
--
-- This module reads vanilla Project Zomboid SandboxVars directly.
-- There is no external library dependency here.
--
-- Sandbox option script names use the fixed page namespace:
--
--     Sandbox_KIPN_<Option>
--
-- but vanilla SandboxVars exposes them at runtime as plain fields
-- on the SandboxVars.KIPN table, keyed by <Option> only:
--
--     SandboxVars.KIPN.MaxAccountsPerSteamId
--
-- This is the same table every other KIPN config module
-- (KIPN_AccountConfig, KIPN_ComputerConfig, KIPN_ArtifactConfig,
-- KIPN_ClaimConfig) already reads directly.
-- KIPN_Settings does the same thing through a shared, generic
-- entry point so services that don't own a config table (e.g.
-- KIPN_AuthService) can still resolve individual options.

KIPN =
    KIPN or {}

KIPN.Server =
    KIPN.Server or {}

KIPN.Server.Settings =
    KIPN.Server.Settings or {}

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local settingsLoggerObj =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("Settings")
    or nil

local function logError(
    message
)

    if settingsLoggerObj then
        settingsLoggerObj:Error(message)
    else
        print(
            "[KIPN SETTINGS] ERROR: " ..
            tostring(message)
        )
    end
end

------------------------------------------------------------
-- RESOLVE SANDBOX FIELD KEY
------------------------------------------------------------
--
-- Converts:
--
--     optionName = "MaxAccountsPerSteamId"
--
-- or the fully-qualified script name:
--
--     optionName = "Sandbox_KIPN_MaxAccountsPerSteamId"
--
-- into the field key SandboxVars.KIPN is actually indexed by
-- at runtime:
--
--     MaxAccountsPerSteamId
--
-- groupName is accepted for logging/diagnostics only. Vanilla
-- SandboxVars.KIPN is a single flat table, so it does not
-- factor into the lookup key itself.
------------------------------------------------------------

local function resolveSandboxFieldKey(
    groupName,
    optionName
)

    if type(
        optionName
    ) ~= "string"
        or optionName == ""
    then

        logError(
            "Cannot resolve sandbox field key: " ..
            "optionName is missing."
        )

        return nil
    end

    --------------------------------------------------------
    -- Strip the page namespace if it's already qualified
    --------------------------------------------------------

    if string.sub(
        optionName,
        1,
        13
    ) == "Sandbox_KIPN_"
    then

        local fieldKey =
            string.sub(
                optionName,
                14
            )

        return fieldKey
    end

    return optionName
end

------------------------------------------------------------
-- SANDBOXVARS ACCESS
------------------------------------------------------------
--
-- Vanilla Project Zomboid global. Populated by the engine from
-- the active sandbox preset before mods finish loading.
------------------------------------------------------------

local function getSandboxTable()

    if type(
        SandboxVars
    ) ~= "table"
    then

        return nil
    end

    return SandboxVars.KIPN
end

------------------------------------------------------------
-- ADMIN RUNTIME OVERRIDES
------------------------------------------------------------
--
-- Sandbox options are fixed for the life of a save (they are
-- only re-rolled when a new server/save is created). The
-- Admin Settings screen needs to be able to change KIPN
-- policy without restarting the server.
--
-- Admin overrides are layered ON TOP of sandbox values:
--
--     hardcoded default
--         < sandbox option
--             < admin runtime override
--
-- They are stored in the persistent KIPN data file under
-- data.adminConfigOverrides[groupName][key], independently of
-- the read-only data.configuration snapshot that the rest of
-- the server already maintains for diagnostics.
------------------------------------------------------------

local DYNAMIC_OVERRIDE_GROUPS = {
    Crafting = true,
    CraftingTime = true,
}

local function isDynamicOverrideGroup(groupName)
    return groupName ~= nil
        and DYNAMIC_OVERRIDE_GROUPS[tostring(groupName)] == true
end

local function getAdminOverrideStore(
    groupName
)

    if not KIPN.Server.GetData then
        return nil
    end

    local data =
        KIPN.Server.GetData()

    if not data then
        return nil
    end

    data.adminConfigOverrides =
        data.adminConfigOverrides
        or {}

    if not groupName then
        return data.adminConfigOverrides
    end

    data.adminConfigOverrides[groupName] =
        data.adminConfigOverrides[groupName]
        or {}

    return data.adminConfigOverrides[groupName]
end

function KIPN.Server.Settings.GetAdminOverrides(
    groupName
)

    -- Only truly dynamic data remains eligible for persistent runtime
    -- overrides. Normal scalar gameplay/server policy is Sandbox-owned.
    if not isDynamicOverrideGroup(groupName) then
        return {}
    end

    local store =
        getAdminOverrideStore(
            groupName
        )

    return store or {}
end

function KIPN.Server.Settings.SetAdminOverride(
    groupName,
    key,
    value
)

    if not groupName
        or not key
    then

        return false
    end

    if not isDynamicOverrideGroup(groupName) then
        logError(
            "SetAdminOverride rejected for Sandbox-owned group: " ..
            tostring(groupName)
        )
        return false
    end

    local store =
        getAdminOverrideStore(
            groupName
        )

    if not store then

        logError(
            "SetAdminOverride: KIPN data unavailable."
        )

        return false
    end

    store[key] =
        value

    local saved =
        KIPN.Server.Save
        and KIPN.Server.Save()
        or false

    return saved
end

function KIPN.Server.Settings.ClearAdminOverride(
    groupName,
    key
)

    if not groupName
        or not key
    then

        return false
    end

    if not isDynamicOverrideGroup(groupName) then
        return false
    end

    local store =
        getAdminOverrideStore(
            groupName
        )

    if not store then
        return false
    end

    store[key] =
        nil

    local saved =
        KIPN.Server.Save
        and KIPN.Server.Save()
        or false

    return saved
end

------------------------------------------------------------
-- GET SANDBOX VALUE
------------------------------------------------------------

function KIPN.Server.Settings.Get(
    groupName,
    optionName,
    default
)

    local fieldKey =
        resolveSandboxFieldKey(
            groupName,
            optionName
        )

    if not fieldKey then

        return default
    end

    --------------------------------------------------------
    -- READ SANDBOXVARS
    --------------------------------------------------------

    local sandboxTable =
        getSandboxTable()

    if not sandboxTable then

        logError(
            "SandboxVars.KIPN unavailable."
        )

        return default
    end

    local value =
        sandboxTable[fieldKey]

    --------------------------------------------------------
    -- DEFAULT FALLBACK
    --------------------------------------------------------

    if value == nil then

        value =
            default
    end

    return value
end

------------------------------------------------------------
-- APPLY SANDBOX VALUES TO CONFIGURATION
------------------------------------------------------------
--
-- target contains the KIPN configuration defaults.
--
-- Each existing key is checked against the sandbox namespace.
--
-- Example:
--
--     target.MaxAccountsPerSteamId
--
-- is looked up as:
--
--     SandboxVars.KIPN.MaxAccountsPerSteamId
--
-- Only values that actually exist in SandboxVars replace the
-- existing configuration value.
------------------------------------------------------------

function KIPN.Server.Settings.ApplyToConfig(
    groupName,
    target
)

    if type(
        target
    ) ~= "table"
    then

        logError(
            "Configuration target is not a table."
        )

        return false
    end

    local sandboxTable =
        getSandboxTable()

    if not sandboxTable then

        logError(
            "SandboxVars.KIPN unavailable."
        )

        return false
    end

    local success =
        true

    local defaults =
        {}

    --------------------------------------------------------
    -- SNAPSHOT DEFAULTS
    --------------------------------------------------------

    for key, value in pairs(
        target
    ) do

        defaults[key] =
            value
    end

    --------------------------------------------------------
    -- RESOLVE EACH OPTION
    --------------------------------------------------------


    for key, defaultValue in pairs(
        defaults
    ) do

        local fieldKey =
            resolveSandboxFieldKey(
                groupName,
                key
            )

        if fieldKey then

            local value =
                sandboxTable[fieldKey]

            if value ~= nil then

                target[key] =
                    value

            end
        else

            success =
                false
        end

    end

    return success
end

------------------------------------------------------------
-- APPLY ALL KIPN SANDBOX CONFIGURATION
------------------------------------------------------------
--
-- This provides a single service-owned operation for the
-- server orchestrator.
--
-- The orchestrator can call:
--
--     KIPN.Server.Settings.ApplySandboxOverrides()
--
-- without knowing anything about SandboxVars directly.
------------------------------------------------------------

function KIPN.Server.Settings.ApplySandboxOverrides()

    local success =
        true

    --------------------------------------------------------
    -- ACCOUNT
    --------------------------------------------------------

    if KIPN.Server.AccountConfig then

        success =
            KIPN.Server.Settings.ApplyToConfig(
                "Account",
                KIPN.Server.AccountConfig
            )
            and success
    end

    --------------------------------------------------------
    -- CLAIM
    --------------------------------------------------------

    if KIPN.Server.ClaimConfig then

        success =
            KIPN.Server.Settings.ApplyToConfig(
                "Claim",
                KIPN.Server.ClaimConfig
            )
            and success
    end

    --------------------------------------------------------
    -- ARTIFACT
    --------------------------------------------------------

    if KIPN.Server.ArtifactConfig then

        success =
            KIPN.Server.Settings.ApplyToConfig(
                "Artifact",
                KIPN.Server.ArtifactConfig
            )
            and success
    end

    --------------------------------------------------------
    -- COMPUTER
    --------------------------------------------------------

    if KIPN.Server.ComputerConfig then

        success =
            KIPN.Server.Settings.ApplyToConfig(
                "Computer",
                KIPN.Server.ComputerConfig
            )
            and success
    end

    return success
end

------------------------------------------------------------
-- EFFECTIVE CONFIGURATION LOGGING
------------------------------------------------------------

function KIPN.Server.Settings.LogEffective()

    return true
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------
--
-- Confirms SandboxVars.KIPN is populated before the server
-- orchestrator relies on Settings.Get() / ApplyToConfig().
--
-- This function exists so the server orchestrator can maintain
-- a consistent service initialization architecture, even though
-- there is no external dependency left to bring up.
------------------------------------------------------------

local function purgeLegacyScalarAdminOverrides()
    if not KIPN.Server.GetData then
        return false
    end

    local data = KIPN.Server.GetData()
    if not data or type(data.adminConfigOverrides) ~= "table" then
        return false
    end

    local changed = false
    for groupName, _ in pairs(data.adminConfigOverrides) do
        if not isDynamicOverrideGroup(groupName) then
            data.adminConfigOverrides[groupName] = nil
            changed = true
        end
    end

    if changed and KIPN.Server.Save then
        KIPN.Server.Save()
        print("[KIPN SETTINGS] Removed legacy scalar Admin Settings overrides; Sandbox is authoritative.")
    end

    return changed
end

function KIPN.Server.Settings.Initialize()

    if not getSandboxTable() then

        logError(
            "SandboxVars.KIPN unavailable during Settings.Initialize(). " ..
            "Sandbox overrides will fall back to hardcoded defaults " ..
            "until it is populated."
        )

        return false
    end

    purgeLegacyScalarAdminOverrides()

    return true
end
