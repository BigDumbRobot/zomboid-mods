-- KIPN_Permissions.lua
--
-- KIPN account permissions and role system.
--
-- Responsibilities:
--   * Define KIPN roles.
--   * Define reusable permissions/capabilities.
--   * Determine whether an account may perform an action.
--   * Support configurable role permissions.
--   * Provide server-authoritative permission checks.
--
-- IMPORTANT:
--   This file does NOT determine what a physical computer can do.
--
-- Physical/world capability belongs to:
--   KIPN_WorldRegistry.lua
--
-- Account authorization belongs here.
--
-- Example:
--
--   A dealership computer may have:
--
--       vehicle.claim
--       vehicle.lookup
--
--   But the account may still require:
--
--       vehicle.claim
--
--   Both must pass before the application is allowed to process
--   the transaction.
--
-- This gives us:
--
--   WORLD CAPABILITY
--          +
--   ACCOUNT PERMISSION
--          +
--   ACTIVE SESSION
--          +
--   CLAIM TOKEN
--          =
--   AUTHORIZED TRANSACTION
--
-- The server is always authoritative.

if isClient() then return end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
require "KIPN_Shared"
require "KIPN_Server"

------------------------------------------------------------
-- LOGGING
------------------------------------------------------------

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("Permissions")
    or nil

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN PERMISSIONS] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- PERMISSIONS SERVICE
------------------------------------------------------------

KIPN.Server.Permissions =
    KIPN.Server.Permissions or {}

local Permissions = KIPN.Server.Permissions

------------------------------------------------------------
-- BUILT-IN PERMISSIONS
------------------------------------------------------------
--
-- These are intentionally granular.
--
-- Applications can require one or more of these permissions.
--
-- The permission system does not care what application uses them.
------------------------------------------------------------

Permissions.Definitions = Permissions.Definitions or {

    --------------------------------------------------------
    -- GENERAL ACCOUNT
    --------------------------------------------------------

    ["account.view"] = {
        name = "View Account",
        description = "View account information.",
    },

    ["account.edit"] = {
        name = "Edit Account",
        description = "Modify account settings.",
    },

    -- Claim-type permissions (vehicle.* / property.* / excavation.* /
    -- safehouse.*) are registered by their service modules via
    -- Permissions.RegisterPermission at init.

    --------------------------------------------------------
    -- ADMINISTRATION
    --------------------------------------------------------

    ["admin.view"] = {
        name = "View Administration",
        description = "Access the KIPN administrative interface.",
    },

    ["admin.configure"] = {
        name = "Configure KIPN",
        description = "Modify KIPN configuration.",
    },

    ["admin.accounts"] = {
        name = "Manage Accounts",
        description = "Manage KIPN accounts.",
    },

    ["admin.computers"] = {
        name = "Manage Computers",
        description = "Manage registered KIPN computers.",
    },

    ["admin.world"] = {
        name = "Manage World Registry",
        description = "Manage KIPN world locations and zones.",
    },

    ["admin.claims"] = {
        name = "Manage Claims",
        description = "Inspect, revoke, and manage claim tokens.",
    },

    ["admin.audit"] = {
        name = "View Audit Log",
        description = "View KIPN administrative and transaction logs.",
    },

}

------------------------------------------------------------
-- BUILT-IN ROLES
------------------------------------------------------------
--
-- Roles are collections of permissions.
--
-- These are defaults only.
--
-- Server configuration can later override or extend them.
------------------------------------------------------------

Permissions.DefaultRoles = Permissions.DefaultRoles or {

    --------------------------------------------------------
    -- PLAYER
    --------------------------------------------------------

    PLAYER = {
        name = "Player",

        permissions = {
            ["account.view"] = true,
            -- Claim-type grants come from the service modules
            -- (Permissions.RegisterPermission grantToRoles).
        },
    },

    --------------------------------------------------------
    -- ADMIN
    --------------------------------------------------------

    ADMIN = {
        name = "Administrator",

        permissions = {
            ["account.view"] = true,
            ["account.edit"] = true,
            -- Claim-type grants come from the service modules
            -- (Permissions.RegisterPermission grantToRoles).

            ["admin.view"] = true,
            ["admin.configure"] = true,
            ["admin.accounts"] = true,
            ["admin.computers"] = true,
            ["admin.world"] = true,
            ["admin.claims"] = true,
            ["admin.audit"] = true,
        },
    },

}

------------------------------------------------------------
-- PERMISSION REGISTRATION  (companion service mods)
------------------------------------------------------------
--
-- A companion service registers the permissions it owns at init,
-- instead of them living in the static Definitions / DefaultRoles
-- tables above. Re-registering an existing id with the same shape is
-- a no-op. grantToRoles is a list of DefaultRole ids that should be
-- granted the permission (typically {"PLAYER", "ADMIN"}).
------------------------------------------------------------

function Permissions.RegisterPermission(permissionId, def)

    if type(permissionId) ~= "string" or permissionId == "" then
        print("[KIPN PERMISSIONS] RegisterPermission rejected: invalid id.")
        return false
    end

    def = type(def) == "table" and def or {}

    if not Permissions.Definitions[permissionId] then
        Permissions.Definitions[permissionId] = {
            name = def.name or permissionId,
            description = def.description or "",
        }
    end

    local grantToRoles = def.grantToRoles
    if type(grantToRoles) == "table" then
        for _, roleId in ipairs(grantToRoles) do
            local role = Permissions.DefaultRoles[roleId]
            if type(role) == "table" and type(role.permissions) == "table" then
                role.permissions[permissionId] = true
            end
        end
    end

    return true
end

------------------------------------------------------------
-- CONFIGURATION
------------------------------------------------------------

local function getPermissionConfiguration()
    local data = KIPN.Server.GetData()

    if not data then
        logError("Unable to retrieve KIPN data.")
        return nil
    end

    if type(data.configuration) ~= "table" then
        data.configuration = {}
    end

    if type(data.configuration.permissions) ~= "table" then
        data.configuration.permissions = {}
    end

    local configuration = data.configuration.permissions

    if type(configuration.roles) ~= "table" then
        configuration.roles = {}
    end

    if type(configuration.accountOverrides) ~= "table" then
        configuration.accountOverrides = {}
    end

    return configuration
end

------------------------------------------------------------
-- ROLE LOOKUP
------------------------------------------------------------

function Permissions.GetRole(roleId)
    if not roleId then
        return nil
    end

    local configuration = getPermissionConfiguration()

    if not configuration then
        return nil
    end

    --------------------------------------------------------
    -- SERVER CONFIGURED ROLE
    --------------------------------------------------------

    if configuration.roles[roleId] then
        return configuration.roles[roleId]
    end

    --------------------------------------------------------
    -- BUILT-IN ROLE
    --------------------------------------------------------

    local defaultRole =
        Permissions.DefaultRoles[roleId]

    return defaultRole
end

------------------------------------------------------------
-- ROLE PERMISSIONS
------------------------------------------------------------

function Permissions.GetRolePermissions(roleId)
    local role = Permissions.GetRole(roleId)

    if not role then
        return {}
    end

    local permissions = role.permissions

    if type(permissions) ~= "table" then
        permissions = {}
    end

    return permissions
end

------------------------------------------------------------
-- PERMISSION DEFINITION
------------------------------------------------------------

function Permissions.GetDefinition(permissionId)
    if not permissionId then
        return nil
    end

    local definition =
        Permissions.Definitions[permissionId]

    return definition
end

------------------------------------------------------------
-- ACCOUNT ROLES
------------------------------------------------------------
--
-- Account records will eventually contain:
--
--     roles = {
--         "PLAYER"
--     }
--
-- This function safely handles accounts that have not yet
-- received an explicit role.
------------------------------------------------------------

function Permissions.GetAccountRoles(account)
    if type(account) ~= "table" then
        return {}
    end

    if type(account.roles) ~= "table" then
        return {"PLAYER"}
    end

    if #account.roles == 0 then
        return {"PLAYER"}
    end

    return account.roles
end

------------------------------------------------------------
-- ACCOUNT PERMISSION OVERRIDES
------------------------------------------------------------
--
-- Overrides allow the server to grant/revoke individual
-- permissions without creating a new role.
--
-- Example:
--
-- accountOverrides["account-123"] = {
--     ["vehicle.claim"] = true,
--     ["vehicle.transfer"] = false,
-- }
--
-- true  = explicitly grant
-- false = explicitly deny
------------------------------------------------------------

function Permissions.GetAccountOverrides(accountId)
    if not accountId then
        return {}
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return {}
    end

    local overrides =
        configuration.accountOverrides[tostring(accountId)]

    if type(overrides) ~= "table" then
        overrides = {}
    end

    return overrides
end

------------------------------------------------------------
-- CHECK PERMISSION
------------------------------------------------------------
--
-- Permission evaluation order:
--
--   1. Explicit account DENY
--   2. Explicit account GRANT
--   3. Role GRANT
--   4. Deny
--
-- This means an explicit account override wins over a role.
------------------------------------------------------------

function Permissions.HasPermission(account, permissionId)
    if type(account) ~= "table" then
        return false
    end

    if not permissionId then
        return false
    end

    --------------------------------------------------------
    -- ENSURE PERMISSION EXISTS
    --------------------------------------------------------

    local definition =
        Permissions.GetDefinition(permissionId)

    if not definition then
        logError(
            "Permission does not exist: " ..
            tostring(permissionId)
        )

        return false
    end

    --------------------------------------------------------
    -- ACCOUNT OVERRIDE
    --------------------------------------------------------

    local accountId = account.id

    if accountId then
        local overrides =
            Permissions.GetAccountOverrides(accountId)

        if overrides[permissionId] == false then
            return false
        end

        if overrides[permissionId] == true then
            return true
        end
    end

    --------------------------------------------------------
    -- ROLE CHECK
    --------------------------------------------------------

    local roles =
        Permissions.GetAccountRoles(account)

    for _, roleId in ipairs(roles) do

        local rolePermissions =
            Permissions.GetRolePermissions(roleId)

        if rolePermissions[permissionId] == true then

            return true
        end
    end

    --------------------------------------------------------
    -- DEFAULT DENY
    --------------------------------------------------------

    return false
end

------------------------------------------------------------
-- REQUIRE PERMISSION
------------------------------------------------------------
--
-- Convenience wrapper for server-side application code.
--
-- Returns:
--
--     true
--
-- or:
--
--     false, "PERMISSION_DENIED"
------------------------------------------------------------

function Permissions.RequirePermission(account, permissionId)
    if not Permissions.HasPermission(
        account,
        permissionId
    ) then

        return false, "PERMISSION_DENIED"
    end

    return true, "PERMISSION_GRANTED"
end

------------------------------------------------------------
-- GRANT ACCOUNT PERMISSION
------------------------------------------------------------

function Permissions.GrantPermission(accountId, permissionId)
    if not accountId or not permissionId then
        return false
    end

    if not Permissions.GetDefinition(permissionId) then
        logError(
            "Cannot grant unknown permission: " ..
            tostring(permissionId)
        )

        return false
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return false
    end

    accountId = tostring(accountId)

    if type(configuration.accountOverrides[accountId]) ~= "table" then
        configuration.accountOverrides[accountId] = {}
    end

    configuration.accountOverrides[accountId][permissionId] = true

    local saved = KIPN.Server.Save()

    return saved
end

------------------------------------------------------------
-- REVOKE ACCOUNT PERMISSION
------------------------------------------------------------

function Permissions.RevokePermission(accountId, permissionId)
    if not accountId or not permissionId then
        return false
    end

    if not Permissions.GetDefinition(permissionId) then
        logError(
            "Cannot revoke unknown permission: " ..
            tostring(permissionId)
        )

        return false
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return false
    end

    accountId = tostring(accountId)

    if type(configuration.accountOverrides[accountId]) ~= "table" then
        configuration.accountOverrides[accountId] = {}
    end

    configuration.accountOverrides[accountId][permissionId] = false

    local saved = KIPN.Server.Save()

    return saved
end

------------------------------------------------------------
-- CLEAR ACCOUNT OVERRIDE
------------------------------------------------------------
--
-- Removes an explicit grant/deny and returns the account to
-- normal role-based permission evaluation.
------------------------------------------------------------

function Permissions.ClearOverride(accountId, permissionId)
    if not accountId or not permissionId then
        return false
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return false
    end

    accountId = tostring(accountId)

    local overrides =
        configuration.accountOverrides[accountId]

    if type(overrides) ~= "table" then
        return true
    end

    overrides[permissionId] = nil

    local saved = KIPN.Server.Save()

    return saved
end

------------------------------------------------------------
-- SET CUSTOM ROLE
------------------------------------------------------------
--
-- Used by the future administration interface.
--
-- Example:
--
-- Permissions.SetRole("DEALER", {
--     name = "Dealer",
--     permissions = {
--         ["vehicle.lookup"] = true,
--         ["vehicle.claim"] = true,
--     }
-- })
------------------------------------------------------------

function Permissions.SetRole(roleId, definition)
    if not roleId or roleId == "" then
        return false
    end

    if type(definition) ~= "table" then
        return false
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return false
    end

    definition.id = tostring(roleId)

    if not definition.name then
        definition.name = tostring(roleId)
    end

    if type(definition.permissions) ~= "table" then
        definition.permissions = {}
    end

    configuration.roles[tostring(roleId)] = definition

    local saved = KIPN.Server.Save()

    return saved
end

------------------------------------------------------------
-- DELETE CUSTOM ROLE
------------------------------------------------------------

function Permissions.DeleteRole(roleId)
    if not roleId then
        return false
    end

    --------------------------------------------------------
    -- NEVER DELETE BUILT-IN ROLES HERE
    --------------------------------------------------------

    if Permissions.DefaultRoles[roleId] then
        logError(
            "Cannot delete built-in role: " ..
            tostring(roleId)
        )

        return false
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return false
    end

    configuration.roles[roleId] = nil

    local saved = KIPN.Server.Save()

    return saved
end

------------------------------------------------------------
-- ROLE ASSIGNMENT
------------------------------------------------------------

function Permissions.AssignRole(accountId, roleId)
    if not accountId or not roleId then
        return false
    end

    local role =
        Permissions.GetRole(roleId)

    if not role then
        logError(
            "Cannot assign unknown role: " ..
            tostring(roleId)
        )

        return false
    end

    local account =
        KIPN.Server.GetAccount(accountId)

    if not account then
        logError(
            "Cannot assign role: account not found: " ..
            tostring(accountId)
        )

        return false
    end

    if type(account.roles) ~= "table" then
        account.roles = {}
    end

    --------------------------------------------------------
    -- AVOID DUPLICATES
    --------------------------------------------------------

    for _, existingRole in ipairs(account.roles) do
        if existingRole == roleId then
            return true
        end
    end

    table.insert(account.roles, roleId)

    local saved = KIPN.Server.Save()

    return saved
end

------------------------------------------------------------
-- ROLE REMOVAL
------------------------------------------------------------

function Permissions.RemoveRole(accountId, roleId)
    if not accountId or not roleId then
        return false
    end

    local account =
        KIPN.Server.GetAccount(accountId)

    if not account or type(account.roles) ~= "table" then
        return false
    end

    for index, existingRole in ipairs(account.roles) do

        if existingRole == roleId then

            table.remove(account.roles, index)

            local saved = KIPN.Server.Save()

            return saved
        end
    end

    return true
end

------------------------------------------------------------
-- PERMISSION SNAPSHOT
------------------------------------------------------------
--
-- Useful to the future admin UI.
--
-- Returns the effective permissions for an account after
-- roles and account-specific overrides have been evaluated.
------------------------------------------------------------

function Permissions.GetEffectivePermissions(account)
    local result = {}

    if type(account) ~= "table" then
        return result
    end

    --------------------------------------------------------
    -- ROLE PERMISSIONS
    --------------------------------------------------------

    local roles =
        Permissions.GetAccountRoles(account)

    for _, roleId in ipairs(roles) do

        local rolePermissions =
            Permissions.GetRolePermissions(roleId)

        for permissionId, enabled in pairs(rolePermissions) do

            if enabled == true then
                result[permissionId] = true
            end
        end
    end

    --------------------------------------------------------
    -- ACCOUNT OVERRIDES
    --------------------------------------------------------

    local accountId = account.id

    if accountId then

        local overrides =
            Permissions.GetAccountOverrides(accountId)

        for permissionId, enabled in pairs(overrides) do
            result[permissionId] = enabled
        end
    end

    return result
end

------------------------------------------------------------
-- HAS ANY PERMISSION
------------------------------------------------------------
--
-- True if the account holds at least one of the given
-- permissions.
------------------------------------------------------------

function Permissions.HasAnyPermission(account, permissionIds)
    if type(account) ~= "table" then
        return false
    end

    if type(permissionIds) ~= "table" then
        return false
    end

    for _, permissionId in ipairs(permissionIds) do

        if Permissions.HasPermission(account, permissionId) then

            return true
        end
    end

    return false
end

------------------------------------------------------------
-- HAS ALL PERMISSIONS
------------------------------------------------------------
--
-- True only if the account holds every given permission.
------------------------------------------------------------

function Permissions.HasAllPermissions(account, permissionIds)
    if type(account) ~= "table" then
        return false
    end

    if type(permissionIds) ~= "table" then
        return false
    end

    for _, permissionId in ipairs(permissionIds) do

        if not Permissions.HasPermission(account, permissionId) then

            return false
        end
    end

    return true
end

------------------------------------------------------------
-- COMPUTER CAPABILITY
------------------------------------------------------------
--
-- Intentionally separate from account permissions.
--
-- A computer's capabilities describe what physical
-- functionality it exposes (see KIPN_WorldRegistry.lua).
-- An account's permissions describe what that account is
-- allowed to do. Both must pass for a real transaction --
-- see the header of this file.
------------------------------------------------------------

function Permissions.HasComputerCapability(computerId, capability)
    if not computerId then
        return false
    end

    if not capability then
        return false
    end

    if not KIPN.Server.GetComputer then
        logError("KIPN.Server.GetComputer is unavailable.")
        return false
    end

    local computer = KIPN.Server.GetComputer(computerId)

    if not computer then
        return false
    end

    if type(computer.capabilities) ~= "table" then
        return false
    end

    --------------------------------------------------------
    -- Support both:
    --
    -- capabilities = { vehicleRegistry = true }
    --
    -- and:
    --
    -- capabilities = { "vehicleRegistry" }
    --------------------------------------------------------

    if computer.capabilities[capability] == true then
        return true
    end

    for _, value in ipairs(computer.capabilities) do
        if value == capability then
            return true
        end
    end

    return false
end

------------------------------------------------------------
-- COMBINED AUTHORIZATION
------------------------------------------------------------
--
-- Checks account permission + computer capability together.
--
-- This does NOT validate:
--   * session
--   * physical location
--   * resource ownership
--   * claim tokens
--
-- Those remain separate responsibilities.
------------------------------------------------------------

function Permissions.Authorize(account, computerId, permissionId, capability)
    if type(account) ~= "table" then
        return false, "ACCOUNT_REQUIRED"
    end

    if not computerId then
        return false, "COMPUTER_REQUIRED"
    end

    if not permissionId then
        return false, "PERMISSION_REQUIRED"
    end

    if not capability then
        return false, "CAPABILITY_REQUIRED"
    end

    --------------------------------------------------------
    -- Account permission.
    --------------------------------------------------------

    if not Permissions.HasPermission(account, permissionId) then
        return false, "PERMISSION_DENIED"
    end

    --------------------------------------------------------
    -- Computer capability.
    --------------------------------------------------------

    if not Permissions.HasComputerCapability(computerId, capability) then

        return false, "CAPABILITY_UNAVAILABLE"
    end

    return true, "AUTHORIZED"
end

------------------------------------------------------------
-- SESSION AUTHORIZATION
------------------------------------------------------------
--
-- The preferred helper for application code. Validates:
--
--   1. Player exists.
--   2. Session exists (the player's own active session --
--      if a sessionId is also given, it must match).
--   3. Session is authenticated and not invalidated.
--   4. Account has the required permission.
--   5. Computer has the required capability.
--
-- Physical world validation remains outside this function.
------------------------------------------------------------

function Permissions.AuthorizeSession(player, sessionId, permissionId, capability)
    if not player then
        return false, "PLAYER_REQUIRED", nil
    end

    if not KIPN.SessionManager then

        logError("KIPN.SessionManager is unavailable.")

        return false, "SESSION_SERVICE_UNAVAILABLE", nil
    end

    --------------------------------------------------------
    -- Resolve the session. The player's own active session
    -- is the source of truth; if an explicit sessionId was
    -- also passed in, it must match it.
    --------------------------------------------------------

    local session = KIPN.SessionManager.GetPlayerSession(player)

    if not session then
        return false, "SESSION_INVALID", nil
    end

    if sessionId and session.sessionId ~= sessionId then

        logError(
            "Session does not belong to player: " ..
            tostring(sessionId)
        )

        return false, "SESSION_INVALID", nil
    end

    if not KIPN.SessionManager.IsValid(session.sessionId) then

        return false, "SESSION_INVALID", session
    end

    --------------------------------------------------------
    -- Account permission
    --------------------------------------------------------

    local account = KIPN.Server.GetAccount(session.accountId)

    if not account then

        logError(
            "AuthorizeSession: account not found for session: " ..
            tostring(session.accountId)
        )

        return false, "ACCOUNT_NOT_FOUND", session
    end

    if not Permissions.HasPermission(account, permissionId) then

        return false, "PERMISSION_DENIED", session
    end

    --------------------------------------------------------
    -- Computer capability
    --------------------------------------------------------

    if not Permissions.HasComputerCapability(session.computerId, capability) then

        return false, "CAPABILITY_UNAVAILABLE", session
    end

    return true, "AUTHORIZED", session
end

------------------------------------------------------------
-- CLIENT-SAFE ACCOUNT PERMISSION DATA
------------------------------------------------------------
--
-- Returns a plain-data snapshot safe to send to the client:
-- resolved roles + the effective permission list. For UI use
-- (what to show/hide) only -- never as an authorization
-- source on its own; the server-side checks above remain
-- authoritative.
------------------------------------------------------------

function Permissions.GetClientPermissionData(accountId)
    if not accountId then
        return nil
    end

    local account = KIPN.Server.GetAccount(accountId)

    if not account then
        return nil
    end

    local roles = Permissions.GetAccountRoles(account)

    local effective = Permissions.GetEffectivePermissions(account)

    local permissions = {}

    for permissionId, enabled in pairs(effective) do
        if enabled then
            table.insert(permissions, permissionId)
        end
    end

    local result = {
        accountId = tostring(accountId),
        roles = roles,
        permissions = permissions,
    }

    return result
end

------------------------------------------------------------
-- ACCESS LEVEL RESOLUTION (PZ -> KIPN)
--
-- This is separate from the account role system above: it
-- reflects the player's native, server-authoritative PZ
-- moderation rank (player:getAccessLevel()), not any KIPN
-- account/role assignment.
--
-- KIPN.AdminAccounts is a sandbox-configured override: any server
-- account (the username the player logs in to the server with) in
-- that comma-separated whitelist always resolves to ADMIN,
-- regardless of PZ access level. The server authenticates the
-- account, and its name is an exact string.
--
-- KIPN.AdminSteamIDs no longer grants anything by itself. A
-- SteamID64 reaches Lua already rounded to a double, so IDs a few
-- apart are indistinguishable (see KIPN.Shared.GetPlayerId) and an
-- ID match alone could admit the wrong account. It is kept as a
-- soft second confirmation of a whitelisted account: the result is
-- logged, never enforced.
------------------------------------------------------------

local PZ_ACCESS_TO_KIPN = {
    admin     = "ADMIN",
    moderator = "MODERATOR",
    overseer  = "STAFF",
    gm        = "GM",
    observer  = "OBSERVER",
}

local function getPlayerSteamId(player)
    if not player then
        return nil
    end

    if not (KIPN.Shared and KIPN.Shared.GetPlayerSteamId) then
        return nil
    end

    -- Best attempt only: the rounded Steam ID, for the confirmation log.
    return KIPN.Shared.GetPlayerSteamId(player)
end

local function getPlayerAccount(player)
    local ok, username = pcall(function()
        return player and player.getUsername and player:getUsername()
    end)

    if ok and type(username) == "string" and username ~= "" then
        return username
    end

    return nil
end

local function getAdminAccountSet()
    local sv = SandboxVars and SandboxVars.KIPN
    local raw = sv and sv.AdminAccounts

    if type(raw) ~= "string" or raw == "" then
        return nil
    end

    local set = nil

    for rawName in string.gmatch(raw, "[^,]+") do
        local name = rawName:match("^%s*(.-)%s*$")

        if name ~= "" then
            set = set or {}
            set[name] = true
        end
    end

    return set
end

local function getAdminSteamIdSet()
    local sv = SandboxVars and SandboxVars.KIPN
    local raw = sv and sv.AdminSteamIDs

    if type(raw) ~= "string" or raw == "" then
        return nil
    end

    local set = {}

    for rawId in string.gmatch(raw, "[^,]+") do
        local id = rawId:match("^%s*(.-)%s*$")

        if id ~= "" then

            ------------------------------------------------------------
            -- STEAM64 PRECISION
            --
            -- Steam IDs entered here are exact (typed/pasted as text),
            -- but KIPN.Shared.GetPlayerId() can only ever report the
            -- player's ID as it comes back from getSteamID() -- a
            -- Java `long` that Kahlua has already rounded to the
            -- nearest double, since Kahlua has no 64-bit integer type.
            -- A 17-digit SteamID64 exceeds a double's exact integer
            -- range (2^53), so an exact string here would never equal
            -- the rounded value GetPlayerId() produces for the same
            -- real account.
            --
            -- Round-tripping this configured ID through the same
            -- tonumber() -> double -> "%.0f" path reproduces the same
            -- rounding GetPlayerId() applies, so the comparison in
            -- ResolveAccessLevel() below actually matches.
            ------------------------------------------------------------

            local numericId = tonumber(id)

            if numericId then
                id = string.format("%.0f", numericId)
            end

            set[id] = true
        end
    end

    return set
end

local function getPlayerLabelForLog(player)
    local ok, name = pcall(function()
        return player and player.getUsername and player:getUsername()
    end)

    if ok and name then
        return name
    end

    return "?"
end

function Permissions.ResolveAccessLevel(player)
    if not player then
        return "USER"
    end

    local playerLabel = getPlayerLabelForLog(player)

    --------------------------------------------------------
    -- OVERRIDE: SANDBOX ADMIN ACCOUNT WHITELIST
    --
    -- The server account decides. The Steam ID is only compared
    -- afterwards, as far as its rounded value allows, and the
    -- outcome is logged for the server owner.
    --------------------------------------------------------

    local adminAccounts = getAdminAccountSet()

    if adminAccounts then
        local account = getPlayerAccount(player)

        if account and adminAccounts[account] then
            local adminSteamIds = getAdminSteamIdSet()
            local steamId = getPlayerSteamId(player)
            local confirmation

            if not adminSteamIds then
                confirmation = "no AdminSteamIDs configured to confirm against"
            elseif steamId and adminSteamIds[steamId] then
                confirmation = "Steam ID confirmed as far as it can be read (steamId="
                    .. tostring(steamId) .. ")"
            else
                confirmation = "WARNING: Steam ID NOT confirmed by AdminSteamIDs (steamId="
                    .. tostring(steamId) .. "); access is granted on the account alone"
            end

            print(
                "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
                .. "): ADMIN via AdminAccounts whitelist (account="
                .. account .. "); " .. confirmation .. "."
            )
            return "ADMIN"
        end

        print(
            "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
            .. "): AdminAccounts whitelist configured but did not match "
            .. "(account=" .. tostring(account) .. ")."
        )
    else
        print(
            "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
            .. "): no AdminAccounts whitelist configured."
        )
    end

    --------------------------------------------------------
    -- BUILD 42 ROLE ADMIN POWER
    --
    -- Build 42's admin UI and privileged server commands use the
    -- Role/Capability system. A genuine admin role can therefore have
    -- admin power while the legacy getAccessLevel()/isAdmin() signals
    -- still report None/false. Recognize the same authoritative role
    -- property vanilla uses before falling back to those legacy APIs.
    --------------------------------------------------------

    local roleOk, roleIsAdmin = pcall(function()
        local role = player.getRole and player:getRole() or nil
        return role
            and role.hasAdminPower
            and role:hasAdminPower() == true
    end)

    print(
        "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
        .. "): role:hasAdminPower() check -- pcallOk=" .. tostring(roleOk)
        .. " result=" .. tostring(roleIsAdmin) .. "."
    )

    if roleOk and roleIsAdmin then
        print(
            "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
            .. "): ADMIN via Build 42 role power."
        )
        return "ADMIN"
    end

    --------------------------------------------------------
    -- NATIVE PZ ACCESS LEVEL
    --------------------------------------------------------

    local ok, pzLevel = pcall(function()
        return player.getAccessLevel and player:getAccessLevel() or nil
    end)

    local kipnLevel = "USER"

    if ok and pzLevel ~= nil then
        kipnLevel =
            PZ_ACCESS_TO_KIPN[string.lower(tostring(pzLevel))] or "USER"
    end

    print(
        "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
        .. "): getAccessLevel() check -- pcallOk=" .. tostring(ok)
        .. " rawLevel=" .. tostring(pzLevel)
        .. " mappedTo=" .. tostring(kipnLevel) .. "."
    )

    if kipnLevel == "ADMIN" then
        print(
            "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
            .. "): ADMIN via native getAccessLevel()."
        )
        return "ADMIN"
    end

    --------------------------------------------------------
    -- FALLBACK: NATIVE isAdmin()
    --
    -- getAccessLevel() and isAdmin() have each been observed to
    -- disagree with the other for a genuine admin, in opposite
    -- directions -- e.g. a coop host whose isAdmin() reads false
    -- while getAccessLevel() correctly reads "admin" (see
    -- KIPN_ZoneAdminTrigger.lua), and a singleplayer game where
    -- isAdmin() reads true while getAccessLevel() reads "None"
    -- since no formal access level has ever been assigned. Treat
    -- either signal reporting admin as authoritative, same as the
    -- client-side Zone Admin gating. This function is the single
    -- source of truth for KIPN admin status server-side (AuthService,
    -- AdminService, ZoneAdminServer all resolve through here), so
    -- fixing it here fixes all of them at once.
    --------------------------------------------------------

    local isAdminOk, isAdminResult = pcall(function()
        return player.isAdmin and player:isAdmin() or false
    end)

    print(
        "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
        .. "): isAdmin() check -- pcallOk=" .. tostring(isAdminOk)
        .. " result=" .. tostring(isAdminResult) .. "."
    )

    if isAdminOk and isAdminResult then
        print(
            "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
            .. "): ADMIN via native isAdmin()."
        )
        return "ADMIN"
    end

    print(
        "[KIPN PERMISSIONS] ResolveAccessLevel(" .. playerLabel
        .. "): no signal reported ADMIN; resolved tier=" .. tostring(kipnLevel)
        .. "."
    )

    return kipnLevel
end

------------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------------

local function initPermissions()
    --------------------------------------------------------
    -- GUARD: KIPN.Server may not be ready yet.
    --
    -- During the server require chain, KIPN_Server.lua
    -- requires KIPN_Permissions.lua BEFORE it finishes
    -- defining KIPN.Server.GetData(). If
    -- Events.OnGameStart.Add fires this handler immediately
    -- in that window, GetData() would crash on nil.
    -- Defer; OnGameStart will re-fire after the require chain.
    --------------------------------------------------------
    if not KIPN
        or not KIPN.Server
        or not KIPN.Server.GetData then

        logError(
            "Permissions initialization deferred: " ..
            "KIPN.Server is not ready yet."
        )

        return
    end

    local data = KIPN.Server.GetData()

    if not data then
        logError(
            "Permissions initialization failed: " ..
            "KIPN data unavailable."
        )

        return
    end

    local configuration =
        getPermissionConfiguration()

    if not configuration then
        return
    end

end

Events.OnGameStart.Add(initPermissions)

print("[KIPN] Permissions loaded")
