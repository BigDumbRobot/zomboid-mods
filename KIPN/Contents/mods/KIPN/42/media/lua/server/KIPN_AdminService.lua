-- KIPN_AdminService.lua

-- KIPN server-side administration service.

-- Responsibilities:
--   * Provide a secure server-authoritative administration API.
--   * Verify that the requesting player has appropriate SYSOP permissions.
--   * Expose controlled administrative data to the future Admin UI.
--   * Provide administrative operations for:
--       - accounts
--       - sessions
--       - computers
--       - applications
--       - claims
--       - world locations
--       - configuration
--       - audit information
--   * Keep all administrative mutations server-authoritative.
--------------------------------------------------------------

-- IMPORTANT:
-- The future Admin UI is ONLY a client-side interface.
-------------------------------------------------------

-- The client must NEVER be trusted to determine:
--   * whether a player is an administrator
--   * which permissions they have
--   * which records they may modify
--   * which configuration values are valid
--   * whether an administrative operation succeeded
----------------------------------------------------

-- The server validates every request.

-- This service intentionally does NOT implement UI behavior.
-- It provides the secure API that the Admin UI will consume.

if isClient() then return end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
require "KIPN_Shared"
require "KIPN_Permissions"

---

-- LOGGING

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("AdminService")
    or nil

local function log(message)
    if logger then
        logger:Info(message)
    else
        print("[KIPN ADMIN SERVICE] " .. tostring(message))
    end
end

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN ADMIN SERVICE] ERROR: " .. tostring(message))
    end
end

---

-- INTERNAL REGISTRY

KIPN.Server.AdminService =
KIPN.Server.AdminService or {}

local AdminService = KIPN.Server.AdminService

--------------------------------------------------------------------
-- SERVER STATS DISPLAY SETTINGS
--
-- Presentation-only policy formerly stored as 28 Sandbox booleans.
-- This now lives in KIPN persistent data under:
--
--     data.statsDisplaySettings.visible[fieldName]
--
-- Every player may read the policy so the Server Stats UI renders
-- consistently. Only SYSOP_CONFIGURATION may mutate it.
--------------------------------------------------------------------

local STATS_DISPLAY_FIELDS = {
    "StatZombieKillsVisible",
    "StatPvpKillsVisible",
    "StatHoursSurvivedVisible",
    "StatDeathsVisible",
    "StatRecipesKnownVisible",
    "StatBooksReadVisible",
    "StatMagazinesReadVisible",
    "StatHighestSkillVisible",
    "StatTotalSkillLevelsVisible",
    "StatBodyWeightVisible",
    "StatCarryWeightVisible",
    "StatDistanceTravelledVisible",
    "StatVehicleDistanceVisible",
    "StatCaloriesConsumedVisible",
    "StatHeaviestWeightVisible",
    "StatMostKillsInDayVisible",
    "StatBulletsFiredVisible",
    "StatItemsCraftedVisible",
    "StatWeaponsRepairedVisible",
    "StatWeaponsDestroyedVisible",
    "StatTreesChoppedVisible",
    "StatFiresLitVisible",
    "StatForageFindsVisible",
    "StatPlantsHarvestedVisible",
    "StatFishCaughtVisible",
    "StatTrapsCaughtVisible",
    "StatThingsBuiltVisible",
    "StatFavoriteWeaponVisible",
}

local STATS_DISPLAY_FIELD_SET = {}

for _, fieldName in ipairs(STATS_DISPLAY_FIELDS) do
    STATS_DISPLAY_FIELD_SET[fieldName] = true
end

local function getStatsDisplayStore()

    if not KIPN.Server.GetData then
        return nil, false
    end

    local data =
        KIPN.Server.GetData()

    if type(data) ~= "table" then
        return nil, false
    end

    local created = false

    if type(data.statsDisplaySettings) ~= "table" then

        data.statsDisplaySettings = {
            version = 1,
            visible = {},
        }

        created = true
    end

    local store =
        data.statsDisplaySettings

    store.version = 1

    if type(store.visible) ~= "table" then
        store.visible = {}
        created = true
    end

    ------------------------------------------------------------
    -- ONE-TIME SANDBOX MIGRATION
    --
    -- Old saves may still expose the retired Stat*Visible custom
    -- sandbox keys even after the options are removed from the mod's
    -- sandbox-options.txt. Seed the new feature-owned store from them
    -- once, otherwise default every stat to visible.
    ------------------------------------------------------------

    if created then

        local oldSandbox =
            SandboxVars
            and SandboxVars.KIPN
            or nil

        for _, fieldName in ipairs(STATS_DISPLAY_FIELDS) do

            local oldValue =
                oldSandbox
                and oldSandbox[fieldName]

            if type(oldValue) == "boolean" then
                store.visible[fieldName] = oldValue
            else
                store.visible[fieldName] = true
            end
        end

        store.migratedFromSandbox = true
    end

    return store, created
end

local function getStatsDisplaySnapshot()

    local store =
        getStatsDisplayStore()

    local snapshot = {}

    for _, fieldName in ipairs(STATS_DISPLAY_FIELDS) do

        local value =
            store
            and store.visible
            and store.visible[fieldName]

        snapshot[fieldName] =
            value ~= false
    end

    return snapshot
end

function AdminService.GetStatsDisplaySettings(player)

    local store, created =
        getStatsDisplayStore()

    if not store then
        return nil, false, "DATA_UNAVAILABLE"
    end

    if created
        and KIPN.Server.Save then

        KIPN.Server.Save()
    end

    local canEdit =
        AdminService.HasPermission(
            player,
            KIPN.Shared.Permissions.SYSOP_CONFIGURATION
        ) == true

    return getStatsDisplaySnapshot(),
        canEdit,
        "SUCCESS"
end

function AdminService.SaveStatsDisplaySettings(
    player,
    visible
)

    if not AdminService.RequirePermission(
        player,
        KIPN.Shared.Permissions.SYSOP_CONFIGURATION
    ) then

        return false,
            "PERMISSION_DENIED",
            getStatsDisplaySnapshot()
    end

    if type(visible) ~= "table" then

        return false,
            "VISIBLE_TABLE_REQUIRED",
            getStatsDisplaySnapshot()
    end

    for fieldName, rawValue in pairs(visible) do

        if not STATS_DISPLAY_FIELD_SET[fieldName] then

            return false,
                "UNKNOWN_STATS_DISPLAY_FIELD",
                getStatsDisplaySnapshot()
        end

        if type(rawValue) ~= "boolean" then

            return false,
                "INVALID_STATS_DISPLAY_VALUE",
                getStatsDisplaySnapshot()
        end
    end

    local store =
        getStatsDisplayStore()

    if not store then

        return false,
            "DATA_UNAVAILABLE",
            getStatsDisplaySnapshot()
    end

    for _, fieldName in ipairs(STATS_DISPLAY_FIELDS) do

        if visible[fieldName] ~= nil then

            store.visible[fieldName] =
                visible[fieldName] == true
        end
    end

    if not KIPN.Server.Save
        or not KIPN.Server.Save() then

        return false,
            "PERSISTENCE_FAILED",
            getStatsDisplaySnapshot()
    end

    if AdminService.WriteAudit then

        AdminService.WriteAudit(
            player,
            "SAVE_STATS_DISPLAY_SETTINGS",
            "SERVER_STATS",
            "visibility",
            getStatsDisplaySnapshot()
        )
    end

    return true,
        "SUCCESS",
        getStatsDisplaySnapshot()
end

---

-- DEPENDENCY HELPERS

local function getAccountService()

local service = KIPN.Server.AccountService

if not service then
    logError("Account Service is unavailable.")
    return nil
end

return service

end

local function getSessionManager()

local service = KIPN.Server.SessionManager

if not service then
    logError("Session Manager is unavailable.")
    return nil
end

return service

end

---

-- PLAYER IDENTIFICATION

local function getPlayerSteamId(player)

if not player then
    return nil
end

local ok, steamId = pcall(function()
    if player.getSteamID then
        return player:getSteamID()
    end

    return nil
end)

if not ok or steamId == nil then
    return nil
end

steamId = tostring(steamId)

return steamId

end

---

-- ADMIN AUTHORIZATION

--
-- This is the critical security boundary.
------------------------------------------

-- The client can REQUEST administrative data.
-- The client cannot declare itself an administrator.
-----------------------------------------------------

-- KIPN's sysop.* permissions are intentionally coarse: they gate
-- the KIPN Admin Settings surface as a whole, not individual
-- in-game actions. Rather than maintain a second, KIPN-specific
-- notion of "admin" alongside Project Zomboid's own, this defers
-- to KIPN.Server.Permissions.ResolveAccessLevel, which is itself
-- derived from the server-authoritative player:getAccessLevel()
-- flag -- the same rank PZ's own moderator tooling relies on --
-- plus the KIPN.AdminAccounts sandbox override, which grants KIPN
-- ADMIN access to a configured server account regardless of PZ
-- access level.

function AdminService.HasPermission(player, permission)

if not player then
    return false
end

if not permission then
    return false
end

--------------------------------------------------------
-- KIPN ACCESS LEVEL CHECK
--------------------------------------------------------

local permissions = KIPN.Server.Permissions

local ok, result = pcall(function()
    if not (permissions and permissions.ResolveAccessLevel) then
        return false
    end

    return permissions.ResolveAccessLevel(player) == "ADMIN"
end)

if ok then
    result = result and true or false

    return result
end

--------------------------------------------------------
-- FAIL CLOSED
--------------------------------------------------------

logError(
    "Unable to verify administrative permission: " ..
    tostring(result) ..
    ". Failing closed."
)

return false

end

---

-- REQUIRE PERMISSION

function AdminService.RequirePermission(player, permission)

local allowed =
    AdminService.HasPermission(
        player,
        permission
    )

if not allowed then
    return false
end

return true

end

---

-- AUDIT LOGGING

-- Hard cap on retained audit entries. The audit table is write-only
-- (nothing reads individual rows -- only counts.audit in the admin
-- snapshot), and it is serialized + transmitted on every audit-
-- triggering save, so an uncapped table makes every later save
-- progressively heavier for the life of the world. Keep the most
-- recent MAX_AUDIT_ENTRIES; drop the oldest.
local MAX_AUDIT_ENTRIES = 2000

-- Number of extra entries to let accumulate before a prune pass, so
-- pruning is amortized instead of running on every single write.
local AUDIT_PRUNE_SLACK = 200

-- Epoch-millisecond ordering key for an audit row. Prefers the
-- explicit field, falls back to the millis embedded in the id
-- ("ADMIN-<ms>-<rand>"), and finally 0 (sorts as oldest).
local function auditEntryOrderKey(entry)

    if type(entry) ~= "table" then
        return 0
    end

    local ms = tonumber(entry.writtenAtMs)

    if ms then
        return ms
    end

    if type(entry.id) == "string" then
        ms = tonumber(string.match(entry.id, "^ADMIN%-(%d+)%-"))

        if ms then
            return ms
        end
    end

    return 0
end

local function pruneAuditTable(audit)

    local count = 0

    for _ in pairs(audit) do
        count = count + 1
    end

    if count <= MAX_AUDIT_ENTRIES + AUDIT_PRUNE_SLACK then
        return
    end

    local ordered = {}

    for id, entry in pairs(audit) do
        ordered[#ordered + 1] = {
            id = id,
            key = auditEntryOrderKey(entry),
        }
    end

    table.sort(
        ordered,
        function(a, b)
            if a.key == b.key then
                return tostring(a.id) < tostring(b.id)
            end
            return a.key < b.key
        end
    )

    local removeCount = #ordered - MAX_AUDIT_ENTRIES

    for i = 1, removeCount do
        audit[ordered[i].id] = nil
    end
end

function AdminService.WriteAudit(
player,
action,
targetType,
targetId,
details
)

local data = KIPN.Server.GetData()

if not data then
    return false
end

data.audit = data.audit or {}

local steamId = getPlayerSteamId(player)

local timestamp =
    getGameTime and
    getGameTime():getWorldAgeHours() or
    nil

local nowMs =
    getTimestampMs and getTimestampMs() or 0

local auditId =
    "ADMIN-" ..
    tostring(nowMs) ..
    "-" ..
    tostring(
        ZombRand and
        ZombRand(100000, 999999) or
        math.random(100000, 999999)
    )

data.audit[auditId] = {
    id = auditId,

    category = "ADMIN",

    action = action,

    targetType = targetType,

    targetId = targetId,

    account = KIPN.Shared.GetPlayerId(player),

    steamId = steamId,

    worldAgeHours = timestamp,

    writtenAtMs = nowMs,

    details = details or {},
}

pruneAuditTable(data.audit)

-- Domain-scoped: only the audit slice is persisted + transmitted,
-- instead of re-broadcasting every subsystem tag (computers,
-- accounts, stats, claims, ...) to every client on each admin action.
local saved = KIPN.Server.Save("audit")

return saved

end

---

-- ADMIN DATA SNAPSHOT

--
-- This intentionally returns a sanitized snapshot.
---------------------------------------------------

-- The Admin UI does NOT need the entire persistent database.
-- Never blindly transmit KIPN.Server.Data to a client.
-------------------------------------------------------

function AdminService.GetAdminData(player)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.SYSOP_VIEW
) then

    return nil, "PERMISSION_DENIED"
end

local data = KIPN.Server.GetData()

if not data then
    return nil, "DATA_UNAVAILABLE"
end

local snapshot = {
    schemaVersion = data.schemaVersion,

    metadata = {
        createdAt = data.metadata and data.metadata.createdAt,
        lastLoadedAt = data.metadata and data.metadata.lastLoadedAt,
        lastSavedAt = data.metadata and data.metadata.lastSavedAt,
    },

    ----------------------------------------------------
    -- COUNTS
    ----------------------------------------------------

    counts = {
        accounts = 0,
        computers = 0,
        sessions = 0,
        claims = 0,
        validationKeys = 0,
        audit = 0,
    },

    ----------------------------------------------------
    -- CONFIGURATION
    ----------------------------------------------------

    configuration = data.configuration or {},

    ----------------------------------------------------
    -- REGISTRY INFORMATION
    ----------------------------------------------------

    applications = {},

    ----------------------------------------------------
    -- WORLD INFORMATION
    ----------------------------------------------------

    locations = {},

    ----------------------------------------------------
    -- SYSTEM STATUS
    ----------------------------------------------------

    system = {
        service = "KIPN Admin Service",
        status = "ONLINE",
    },
}

--------------------------------------------------------
-- COUNT TABLE ENTRIES
--------------------------------------------------------

local function countEntries(tbl)
    local count = 0

    if type(tbl) ~= "table" then
        return count
    end

    for _ in pairs(tbl) do
        count = count + 1
    end

    return count
end

snapshot.counts.accounts =
    countEntries(data.accounts)

snapshot.counts.computers =
    countEntries(data.computers)

snapshot.counts.sessions =
    countEntries(data.sessions)

snapshot.counts.claims =
    countEntries(data.claims)

snapshot.counts.validationKeys =
    countEntries(data.validationKeys)

snapshot.counts.audit =
    countEntries(data.audit)

--------------------------------------------------------
-- APPLICATION REGISTRY
--------------------------------------------------------

if KIPN.Server.ApplicationRegistry then

    local registry =
        KIPN.Server.ApplicationRegistry

    if type(registry.GetAll) == "function" then

        local ok, applications =
            pcall(registry.GetAll)

        if ok and type(applications) == "table" then
            snapshot.applications =
                applications
        end
    end
end

--------------------------------------------------------
-- WORLD REGISTRY
--------------------------------------------------------

if KIPN.Server.WorldRegistry then

    local registry =
        KIPN.Server.WorldRegistry

    if type(registry.GetAll) == "function" then

        local ok, locations =
            pcall(registry.GetAll)

        if ok and type(locations) == "table" then
            snapshot.locations =
                locations
        end
    end
end

--------------------------------------------------------
-- AUDIT
--------------------------------------------------------

AdminService.WriteAudit(
    player,
    "VIEW_ADMIN_DATA",
    "SYSTEM",
    nil,
    {}
)

return snapshot, "SUCCESS"

end

---

-- ACCOUNT ADMINISTRATION

function AdminService.GetAccount(player, accountId)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.SYSOP_USERS
) then

    return nil, "PERMISSION_DENIED"
end

if not accountId then
    return nil, "ACCOUNT_ID_REQUIRED"
end

local accountService = getAccountService()

if not accountService then
    return nil, "ACCOUNT_SERVICE_UNAVAILABLE"
end

local account

if type(accountService.GetAccount) == "function" then
    account = accountService.GetAccount(accountId)
end

if not account then
    return nil, "ACCOUNT_NOT_FOUND"
end

AdminService.WriteAudit(
    player,
    "VIEW_ACCOUNT",
    "ACCOUNT",
    accountId,
    {}
)

return account, "SUCCESS"

end

---

-- COMPUTER ADMINISTRATION

function AdminService.GetComputer(player, computerId)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.SYSOP_COMPUTERS
) then

    return nil, "PERMISSION_DENIED"
end

if not computerId then
    return nil, "COMPUTER_ID_REQUIRED"
end

if not KIPN.Server.GetComputer then
    return nil, "COMPUTER_REGISTRY_UNAVAILABLE"
end

local computer =
    KIPN.Server.GetComputer(computerId)

if not computer then
    return nil, "COMPUTER_NOT_FOUND"
end

AdminService.WriteAudit(
    player,
    "VIEW_COMPUTER",
    "COMPUTER",
    computerId,
    {}
)

return computer, "SUCCESS"

end

---

-- CLAIM ADMINISTRATION

function AdminService.GetClaim(player, tokenId)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.VEHICLE_TITLE_ADMIN
) then

    return nil, "PERMISSION_DENIED"
end

if not tokenId then
    return nil, "TOKEN_ID_REQUIRED"
end

local claimService =
    KIPN.Server.ClaimService

if not claimService then
    return nil, "CLAIM_SERVICE_UNAVAILABLE"
end

local token =
    claimService.GetToken(tokenId)

if not token then
    return nil, "TOKEN_NOT_FOUND"
end

AdminService.WriteAudit(
    player,
    "VIEW_CLAIM",
    "CLAIM",
    tokenId,
    {}
)

return token, "SUCCESS"

end

---

-- REVOKE CLAIM

function AdminService.RevokeClaim(player, tokenId)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.VEHICLE_TITLE_ADMIN
) then

    return false, "PERMISSION_DENIED"
end

if not tokenId then
    return false, "TOKEN_ID_REQUIRED"
end

local claimService =
    KIPN.Server.ClaimService

if not claimService then
    return false, "CLAIM_SERVICE_UNAVAILABLE"
end

local success =
    claimService.RevokeToken(
        tokenId,
        nil
    )

if not success then
    return false, "REVOKE_FAILED"
end

AdminService.WriteAudit(
    player,
    "REVOKE_CLAIM",
    "CLAIM",
    tokenId,
    {}
)

return true, "SUCCESS"

end
---

-- SESSION ADMINISTRATION

function AdminService.GetSession(player, sessionId)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.SYSOP_USERS
) then

    return nil, "PERMISSION_DENIED"
end

if not sessionId then
    return nil, "SESSION_ID_REQUIRED"
end

local sessionManager =
    getSessionManager()

if not sessionManager then
    return nil, "SESSION_MANAGER_UNAVAILABLE"
end

local session

if type(sessionManager.GetSession) == "function" then
    session =
        sessionManager.GetSession(sessionId)
end

if not session then
    return nil, "SESSION_NOT_FOUND"
end

AdminService.WriteAudit(
    player,
    "VIEW_SESSION",
    "SESSION",
    sessionId,
    {}
)

return session, "SUCCESS"

end

---

-- ADMIN STATUS

function AdminService.GetSystemStatus(player)

if not AdminService.RequirePermission(
    player,
    KIPN.Shared.Permissions.SYSOP_VIEW
) then

    return nil, "PERMISSION_DENIED"
end

local data = KIPN.Server.GetData()

if not data then
    return nil, "DATA_UNAVAILABLE"
end

local status = {
    status = "ONLINE",

    schemaVersion =
        data.schemaVersion,

    services = {
        account =
            KIPN.Server.AccountService ~= nil,

        session =
            KIPN.Server.SessionManager ~= nil,

        computer =
            KIPN.Server.ComputerRegistry ~= nil,

        claim =
            KIPN.Server.ClaimService ~= nil,

        world =
            KIPN.Server.WorldRegistry ~= nil,

        application =
            KIPN.Server.ApplicationRegistry ~= nil,

        permission =
            true, -- native player:isAdmin() check, always available

        admin = true,
    },
}

return status, "SUCCESS"

end

---

-- INITIALIZATION

function AdminService.Initialize()

KIPN.Server.AdminService =
    AdminService

    --------------------------------------------------------
    -- Register server command handlers
    --------------------------------------------------------
    if type(KIPN.Server.RegisterCommandHandler) == "function" then

        --------------------------------------------------------
        -- SERVER STATS DISPLAY POLICY
        --------------------------------------------------------

        local function handleGetStatsDisplaySettings(
            player,
            _args
        )

            local visible,
                canEdit,
                reason =
                AdminService.GetStatsDisplaySettings(
                    player
                )

            KIPN.Server.SendToPlayer(
                player,
                "statsDisplaySettings",
                {
                    visible = visible or {},
                    canEdit = canEdit == true,
                    message = reason,
                }
            )

            return true
        end

        local function handleSaveStatsDisplaySettings(
            player,
            args
        )

            local ok,
                message,
                visible =
                AdminService.SaveStatsDisplaySettings(
                    player,
                    args
                    and args.visible
                    or nil
                )

            KIPN.Server.SendToPlayer(
                player,
                "statsDisplaySettingsSaved",
                {
                    success = ok == true,
                    message = message,
                    visible = visible or {},
                }
            )

            return true
        end

        KIPN.Server.RegisterCommandHandler(
            "GetStatsDisplaySettings",
            handleGetStatsDisplaySettings
        )

        KIPN.Server.RegisterCommandHandler(
            "SaveStatsDisplaySettings",
            handleSaveStatsDisplaySettings
        )

        -- KIPN configuration is Sandbox-managed; there is no runtime
        -- admin-configuration screen and no GET/SAVE_CONFIGURATION
        -- command any more.
    end

log(
    "Admin Service initialized."
)

return true

end

print("[KIPN] Admin Service loaded")
