-- KIPN_SafehouseService.lua
-- Server-side safehouse engine/projection service for COMPUTER Safehouse
-- and Land Claims.
--
-- KIPN owns safehouse policy.  Vanilla SafeHouse objects are retained as the
-- engine-level protection/compatibility projection only.
--
-- Initialize() is driven by KIPN_GovServicesInit.lua's RegisterService
-- entry.

if isClient() then return end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_ClaimService"
require "KIPN_SafehouseBridge"
require "KIPN_PropertyClaimService"

KIPN.Server.SafehouseService = KIPN.Server.SafehouseService or {}
local SafehouseService = KIPN.Server.SafehouseService
local SafehouseBridge = KIPN.Bridges and KIPN.Bridges.Safehouse

local function log(message)
    print("[KIPN SAFEHOUSE] " .. tostring(message))
end

local function logError(message)
    print("[KIPN SAFEHOUSE] ERROR: " .. tostring(message))
end

local function hasSafehouseAdminAccess(player)
    if KIPN.Server.AdminService
        and type(KIPN.Server.AdminService.HasPermission) == "function"
        and KIPN.Server.AdminService.HasPermission(
            player,
            KIPN.Shared.Permissions.SYSOP_CONFIGURATION
        )
    then
        return true
    end

    -- Match vanilla's own safehouse-admin capability as a fallback.
    if player and type(player.getRole) == "function" and Capability then
        local ok, allowed = pcall(function()
            local role = player:getRole()
            return role and role:hasCapability(Capability.CanSetupSafehouses)
        end)
        if ok and allowed == true then return true end
    end

    if not (KIPN.Shared
        and type(KIPN.Shared.GetPlayerId) == "function"
        and type(KIPN.Server.GetAccountsForSteamId) == "function"
        and type(KIPN.Server.GetAccount) == "function"
        and KIPN.Server.Permissions
        and type(KIPN.Server.Permissions.HasPermission) == "function")
    then
        return false
    end

    local steamId = KIPN.Shared.GetPlayerId(player)
    if not steamId then return false end

    for _, accountId in ipairs(KIPN.Server.GetAccountsForSteamId(steamId) or {}) do
        local account = KIPN.Server.GetAccount(accountId)
        if account and KIPN.Server.Permissions.HasPermission(account, "safehouse.admin") then
            return true
        end
    end

    return false
end

SafehouseService.HasAdminAccess = hasSafehouseAdminAccess

------------------------------------------------------------
-- ADMIN SAFEHOUSE MAP OVERLAY
------------------------------------------------------------
--
-- Passive, admin-only "see every Safehouse and Excavation claim on
-- the world map" feature. Uses the same general ADMIN access-level bar as the
-- Zone Admin Tool (KIPN.Server.Permissions.ResolveAccessLevel ==
-- "ADMIN"), not the narrower "safehouse.admin" permission used for
-- safehouse MANAGEMENT actions above -- this is a map view
-- capability, not a management one.
------------------------------------------------------------

local function isRequestingPlayerMapAdmin(player)
    if not player then return false end

    if not (KIPN.Server.Permissions
        and type(KIPN.Server.Permissions.ResolveAccessLevel) == "function")
    then
        return false
    end

    local accessLevel = KIPN.Server.Permissions.ResolveAccessLevel(player)
    return accessLevel == KIPN.Shared.AccessLevels.ADMIN
end

local function buildSafehouseOverlayPayload()
    local result = {}

    if not (KIPN.Server.ClaimService
        and type(KIPN.Server.ClaimService.GetClaims) == "function"
        and KIPN.Server.ClaimService.Types)
    then
        logError("buildSafehouseOverlayPayload() FAILED: ClaimService unavailable.")
        return result
    end

    local claims = KIPN.Server.ClaimService.GetClaims(KIPN.Server.ClaimService.Types.PROPERTY)

    for claimId, claim in pairs(claims) do
        if type(claim) == "table" then
            result[#result + 1] = {
                id = claimId,
                ownerSteamId = claim.ownerSteamId,
                ownerUsername = claim.ownerUsername,
                x1 = claim.rectX1,
                y1 = claim.rectY1,
                x2 = claim.rectX2,
                y2 = claim.rectY2,
            }
        end
    end

    return result
end

-- Excavation claims live in the same ClaimService store as property
-- claims, keyed by ClaimService.Types.EXCAVATION, and carry the same
-- rectangle fields (rectX1..rectY2). Emitted alongside the safehouse
-- rows so the admin map overlay renders both layers from one snapshot.
local function buildExcavationOverlayPayload()
    local result = {}

    if not (KIPN.Server.ClaimService
        and type(KIPN.Server.ClaimService.GetClaims) == "function"
        and KIPN.Server.ClaimService.Types)
    then
        logError("buildExcavationOverlayPayload() FAILED: ClaimService unavailable.")
        return result
    end

    local claims = KIPN.Server.ClaimService.GetClaims(KIPN.Server.ClaimService.Types.EXCAVATION)

    for claimId, claim in pairs(claims) do
        if type(claim) == "table" then
            result[#result + 1] = {
                id = claimId,
                ownerSteamId = claim.ownerSteamId,
                ownerUsername = claim.ownerUsername,
                x1 = claim.rectX1,
                y1 = claim.rectY1,
                x2 = claim.rectX2,
                y2 = claim.rectY2,
            }
        end
    end

    return result
end

local function broadcastAdminSafehouseOverlay()
    local safehousePayload
    local excavationPayload
    local players = getOnlinePlayers()
    local sentCount = 0

    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if isRequestingPlayerMapAdmin(player) then
            safehousePayload = safehousePayload or buildSafehouseOverlayPayload()
            excavationPayload = excavationPayload or buildExcavationOverlayPayload()
            KIPN.Server.SendToPlayer(player, "SafehouseOverlaySync", {
                safehouses = safehousePayload,
                excavations = excavationPayload,
            })
            sentCount = sentCount + 1
        end
    end

    if sentCount > 0 then
        log("broadcastAdminSafehouseOverlay() | admins=" .. tostring(sentCount) ..
            " | safehouses=" .. tostring(safehousePayload and #safehousePayload or 0) ..
            " | excavations=" .. tostring(excavationPayload and #excavationPayload or 0))
    end
end

-- Excavation claim RECTANGLES + owner Steam ID only (no username / no
-- other detail) sent to ANY player. The boundary overlay already shows
-- excavation plots to everyone, so the rectangles are not secret; the
-- client access-enforcement layer (KIPN_ExcavationAccessEnforcement.lua)
-- needs them to know which plots the local player does not own.
local function buildExcavationAreaPayload()
    local result = {}
    if not (KIPN.Server.ClaimService
        and type(KIPN.Server.ClaimService.GetClaims) == "function"
        and KIPN.Server.ClaimService.Types)
    then
        return result
    end
    local claims = KIPN.Server.ClaimService.GetClaims(KIPN.Server.ClaimService.Types.EXCAVATION)
    for _, claim in pairs(claims) do
        if type(claim) == "table" and claim.rectX1 then
            result[#result + 1] = {
                x1 = claim.rectX1, y1 = claim.rectY1,
                x2 = claim.rectX2, y2 = claim.rectY2,
                z = claim.locationZ or 0,
                ownerSteamId = tostring(claim.ownerSteamId or ""),
            }
        end
    end
    return result
end

local function sendExcavationAreasTo(player)
    KIPN.Server.SendToPlayer(player, "KIPN_ExcavationAreas", {
        areas = buildExcavationAreaPayload(),
    })
end

local function handleRequestExcavationAreas(player, _args)
    sendExcavationAreasTo(player)
    return true
end

local function broadcastExcavationAreas()
    local players = getOnlinePlayers()
    if not players then return end
    local payload = { areas = buildExcavationAreaPayload() }
    for i = 0, players:size() - 1 do
        KIPN.Server.SendToPlayer(players:get(i), "KIPN_ExcavationAreas", payload)
    end
end

SafehouseService.BroadcastExcavationAreas = broadcastExcavationAreas

-- Overlay-only refresh, callable from ClaimService when an excavation
-- claim changes (property/safehouse changes already route through
-- BroadcastSafehouseSync, which calls this). Also pushes the plain
-- excavation-area list to every player for client-side access
-- enforcement (KIPN_ExcavationAccessEnforcement.lua).
SafehouseService.BroadcastAdminClaimOverlay = function()
    broadcastAdminSafehouseOverlay()
    pcall(broadcastExcavationAreas)
end

local function handleRequestSafehouseOverlaySnapshot(player, _args)
    if not isRequestingPlayerMapAdmin(player) then
        logError("RequestSafehouseOverlaySnapshot DENIED | player is not an admin.")
        return true, false, "Permission denied"
    end

    local safehousePayload = buildSafehouseOverlayPayload()
    local excavationPayload = buildExcavationOverlayPayload()
    KIPN.Server.SendToPlayer(player, "SafehouseOverlaySync", {
        safehouses = safehousePayload,
        excavations = excavationPayload,
    })
    log("RequestSafehouseOverlaySnapshot | safehouses=" .. tostring(#safehousePayload) ..
        " | excavations=" .. tostring(#excavationPayload))
    return true, true
end

local function projectionPayload(snapshot, removed)
    if type(snapshot) ~= "table" or type(snapshot.rect) ~= "table" then return nil end
    local rect = snapshot.rect
    local piece = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }

    return {
        owner = snapshot.owner,
        title = snapshot.title,
        members = snapshot.members or {},
        pieces = removed and {} or { piece },
        removed = removed and { piece } or {},
    }
end

local function sendProjection(payload, player)
    if type(payload) ~= "table" then return end
    local command = KIPN.Shared.Commands.SAFEHOUSE_PROJECTION_SYNC
        or "safehouseProjectionSync"
    if player then
        sendServerCommand(player, "KIPN", command, payload)
    else
        sendServerCommand("KIPN", command, payload)
    end
end

function SafehouseService.BroadcastProjectionForSafehouse(safehouse)
    if not SafehouseBridge or type(SafehouseBridge.Snapshot) ~= "function" then return false end
    local snapshot = SafehouseBridge.Snapshot(safehouse)
    if not snapshot then return false end
    sendProjection(projectionPayload(snapshot, false))
    return true
end

function SafehouseService.BroadcastProjectionRemoval(snapshot)
    if type(snapshot) ~= "table" then return false end
    sendProjection(projectionPayload(snapshot, true))
    return true
end

function SafehouseService.SendProjectionToPlayer(player, safehouse)
    if not player or not safehouse or not SafehouseBridge then return false end
    local snapshot = SafehouseBridge.Snapshot(safehouse)
    if not snapshot then return false end
    sendProjection(projectionPayload(snapshot, false), player)
    return true
end

local function broadcastSafehouseSync()
    -- Keep every connected client's local Java SafeHouse list aligned with the
    -- authoritative list.  Exact add/remove projection is handled by the client
    -- adapter and is idempotent if vanilla already delivered the same change.
    if SafeHouse then
        local ok, list = pcall(function()
            return SafeHouse.getSafehouseList()
        end)
        if ok and list then
            for i = 0, list:size() - 1 do
                SafehouseService.BroadcastProjectionForSafehouse(list:get(i))
            end
        end
    end

    broadcastAdminSafehouseOverlay()
end

SafehouseService.BroadcastSafehouseSync = broadcastSafehouseSync

local reconcilingSafehouses = false
local function mutationInProgress()
    return KIPN.Server.GovClaimService
        and type(KIPN.Server.GovClaimService.IsSafehouseMutationInProgress) == "function"
        and KIPN.Server.GovClaimService.IsSafehouseMutationInProgress()
        or false
end

local function reconcileAndBroadcast()
    if KIPN.Server.GovClaimService
        and type(KIPN.Server.GovClaimService.ReconcileManagedSafehouses) == "function"
    then
        KIPN.Server.GovClaimService.ReconcileManagedSafehouses()
    end
    broadcastSafehouseSync()
end

local function handleSafehousesChanged()
    -- addSafeHouse/removeSafeHouse may raise this while a KIPN transaction is only
    -- half committed.  The transaction explicitly projects state after commit.
    if mutationInProgress() or reconcilingSafehouses then return end

    reconcilingSafehouses = true
    local ok, err = pcall(reconcileAndBroadcast)
    reconcilingSafehouses = false
    if not ok then logError("Safehouse reconciliation failed: " .. tostring(err)) end
end

local function handleRequestSafehouseSync(player, _args)
    if SafeHouse then
        local ok, list = pcall(function()
            return SafeHouse.getSafehouseList()
        end)
        if ok and list then
            for i = 0, list:size() - 1 do
                SafehouseService.SendProjectionToPlayer(player, list:get(i))
            end
        end
    end
    return true, true
end

------------------------------------------------------------
-- KIPN SAFEHOUSE PROTECTION ENUM RESOLUTION
--
-- These five KIPN sandbox options are 3-value enums:
--   1 = Unset  -- do not touch the server's existing vanilla value.
--   2 = True
--   3 = False
--
-- Unset is the default so adding these options never silently
-- changes a server's already-configured vanilla ServerOptions value;
-- an admin must deliberately pick True/False to have KIPN take over
-- that option.
------------------------------------------------------------

local SAFEHOUSE_ENUM_UNSET = 1
local SAFEHOUSE_ENUM_TRUE = 2
local SAFEHOUSE_ENUM_FALSE = 3

local function resolveEnumOptionValue(sandboxKey, rawValue)
    local index = tonumber(rawValue)

    if index == nil then
        log(
            "resolveEnumOptionValue() | key=" .. tostring(sandboxKey) ..
            " | rawValue=" .. tostring(rawValue) ..
            " | result=SKIP (missing/invalid; fallback=leave vanilla value untouched)"
        )
        return nil
    end

    if index == SAFEHOUSE_ENUM_TRUE then
        return "true"
    end

    if index == SAFEHOUSE_ENUM_FALSE then
        return "false"
    end

    if index ~= SAFEHOUSE_ENUM_UNSET then
        log(
            "resolveEnumOptionValue() | key=" .. tostring(sandboxKey) ..
            " | rawValue=" .. tostring(rawValue) ..
            " | result=SKIP (unrecognized index; treated as Unset)"
        )
    end

    -- Unset (or any unrecognized index) intentionally resolves to
    -- "do nothing" rather than an error -- Unset is a valid, common
    -- admin choice, not a fallback-worthy condition.
    return nil
end

local function applyKIPNSafehouseProtectionOptions(options)
    local sv = SandboxVars and SandboxVars.KIPN
    if not sv then
        logError(
            "applyKIPNSafehouseProtectionOptions() | SandboxVars.KIPN unavailable; " ..
            "all KIPN safehouse protection options left unresolved this pass."
        )
        return
    end

    local mappings = {
        { "SafehouseAllowTrepass", "SafehouseAllowTrepass" },
        { "SafehouseAllowFire", "SafehouseAllowFire" },
        { "SafehouseAllowLoot", "SafehouseAllowLoot" },
        { "SafehouseAllowRespawn", "SafehouseAllowRespawn" },
        { "DisableSafehouseWhenPlayerConnected", "DisableSafehouseWhenPlayerConnected" },
    }

    for _, mapping in ipairs(mappings) do
        local serverOptionName = mapping[1]
        local sandboxKey = mapping[2]
        local value = resolveEnumOptionValue(sandboxKey, sv[sandboxKey])

        -- Only take control of an option when the admin has explicitly
        -- chosen True/False. Unset (or a world created before these
        -- KIPN options existed) leaves the server's existing vanilla
        -- ServerOptions value completely untouched.
        if value ~= nil then
            options:changeOption(serverOptionName, value)
            log(
                "Applied protection option | " ..
                serverOptionName .. "=" .. value
            )
        else
            log(
                "Protection option left at vanilla value (Unset) | " ..
                serverOptionName
            )
        end
    end
end

local function enforceVanillaSafehouseBypass()
    local enabled = KIPN.Server.ArtifactConfig
        and KIPN.Server.ArtifactConfig.Claim
        and KIPN.Server.ArtifactConfig.Claim.PropertyEnabled
    if enabled ~= true then return end

    local ok, err = pcall(function()
        local options = ServerOptions.getInstance()
        -- Keep the engine SafeHouse subsystem enabled. KIPN suppresses player
        -- self-claiming and creates/removes engine objects itself.
        options:changeOption("PlayerSafehouse", "true")
        options:changeOption("SafehouseDaySurvivedToClaim", "2147483647")

        -- KIPN owns the player-facing configuration for SafeHouse protection
        -- behavior. These map 1:1 to Build 42 ServerOptions and therefore
        -- continue using vanilla engine enforcement for KIPN projections.
        applyKIPNSafehouseProtectionOptions(options)
    end)
    if not ok then logError("Failed to enforce KIPN safehouse options: " .. tostring(err)) end
end

function SafehouseService.Initialize()
    enforceVanillaSafehouseBypass()

    KIPN.Server.RegisterCommandHandler("RequestSafehouseSync", handleRequestSafehouseSync)
    KIPN.Server.RegisterCommandHandler("RequestSafehouseOverlaySnapshot", handleRequestSafehouseOverlaySnapshot)
    KIPN.Server.RegisterCommandHandler("RequestExcavationAreas", handleRequestExcavationAreas)

    Events.OnSafehousesChanged.Add(handleSafehousesChanged)

    -- KIPN owns persisted property state. On boot, repair any missing vanilla
    -- protection projections (for example after an admin manually deleted a
    -- SafeHouse object or when migrating from an earlier KIPN build).
    if KIPN.Server.GovClaimService
        and type(KIPN.Server.GovClaimService.ReconcileManagedSafehouses) == "function"
    then
        local ok, repaired = pcall(
            KIPN.Server.GovClaimService.ReconcileManagedSafehouses
        )
        if ok then
            log("Boot projection reconciliation complete | repaired=" .. tostring(repaired or 0))
        else
            logError("Boot projection reconciliation failed: " .. tostring(repaired))
        end
    end

    log("Safehouse service initialized: KIPN policy / vanilla engine projection.")
    return true
end
print("[KIPN] Safehouse Service loaded")
