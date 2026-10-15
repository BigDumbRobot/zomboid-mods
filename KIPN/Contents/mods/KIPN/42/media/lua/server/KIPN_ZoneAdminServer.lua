-- KIPN_ZoneAdminServer.lua
--
-- Server-side command handler backing the in-game KIPN zone admin
-- tool (KIPN_ZoneAdminUI.lua on the client).
--
-- This file intentionally contains NO map/UI logic. Its only job is:
--   1. Verify the requesting player is actually an admin.
--   2. Validate the request shape.
--   3. Delegate to KIPN.Server.WorldRegistry.
--   4. Send a result back to the requesting client.
--
-- Module name used for client<->server messages: "KIPN_ZoneAdmin"

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_WorldRegistry"
require "KIPN/KIPN_Permissions"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}

local MODULE_NAME = "KIPN_ZoneAdmin"
local MAX_ZONE_LABEL_LENGTH = 128

local logger =
    (KIPN.Logger and KIPN.Logger.Create)
    and KIPN.Logger.Create("ZoneAdminServer")
    or nil

local function logError(message)
    if logger then
        logger:Error(message)
    else
        print("[KIPN ZONE ADMIN] ERROR: " .. tostring(message))
    end
end

------------------------------------------------------------
-- ADMIN CHECK
------------------------------------------------------------
--
-- World-shaping actions (creating/removing zones) are restricted
-- to the KIPN "ADMIN" access level. This is resolved from the
-- player's native PZ access level (player:getAccessLevel()), or
-- from the KIPN.AdminAccounts sandbox override -- see
-- KIPN.Server.Permissions.ResolveAccessLevel. Adjust here if your
-- server wants to also allow Moderator/Staff/GM.
------------------------------------------------------------

local ALLOWED_ACCESS_LEVELS = {
    ADMIN = true,
}

local function isRequestingPlayerAdmin(player)
    if not player then
        return false
    end

    local permissions = KIPN.Server.Permissions

    if not permissions or not permissions.ResolveAccessLevel then
        return false
    end

    local accessLevel = permissions.ResolveAccessLevel(player)

    return ALLOWED_ACCESS_LEVELS[accessLevel] == true
end

------------------------------------------------------------
-- REQUEST VALIDATION
------------------------------------------------------------

local function validatePoint(point)
    if type(point) ~= "table" then
        return false
    end

    if tonumber(point.x) == nil or tonumber(point.y) == nil then
        return false
    end

    return true
end

local function validateRectangleGeometry(geometry)
    if type(geometry) ~= "table" then
        return false
    end

    local x1 = tonumber(geometry.x1)
    local y1 = tonumber(geometry.y1)
    local x2 = tonumber(geometry.x2)
    local y2 = tonumber(geometry.y2)

    return x1 ~= nil and y1 ~= nil and x2 ~= nil and y2 ~= nil
        and x1 ~= x2 and y1 ~= y2
end

------------------------------------------------------------
-- WORLD MAP SYNC
--
-- Pushes active zones to every connected player so KIPN zones show
-- up on the real World Map (F11), not just inside this admin tool.
-- Unlike ListZones (admin-only, used by the "Zones At My Position"
-- panel), this payload is intentionally readable by every player --
-- knowing a zone's boundary, type, and label isn't privileged
-- information. metadata is deliberately NOT sent wholesale: fields
-- like metadata.createdBy are for admin use (see handleCreateZone)
-- and have no business going to every client, so only label is
-- pulled out of it here.
------------------------------------------------------------

local function buildZoneSyncPayload()
    local zones = KIPN.Server.WorldRegistry.GetZones()
    local list = {}

    for zoneId, zone in pairs(zones) do
        if zone.active ~= false then
            list[#list + 1] = {
                id = zoneId,
                type = zone.type,
                geometry = zone.geometry,
                label = zone.metadata and zone.metadata.label or nil,
                combatPolicy = zone.combatPolicy,
            }
        end
    end

    return list
end

local function sendZoneSync(player)
    sendServerCommand(player, MODULE_NAME, "ZoneSync", {
        zones = buildZoneSyncPayload(),
    })
end

local function broadcastZoneSync()
    local players = getOnlinePlayers()

    for i = 0, players:size() - 1 do
        sendZoneSync(players:get(i))
    end
end

-- For server code that changes zones through WorldRegistry directly
-- rather than through these admin commands.
KIPN.Server.BroadcastZoneSync = broadcastZoneSync

------------------------------------------------------------
-- COMMAND: RequestZoneSync
------------------------------------------------------------
--
-- Open to every player (no admin check) -- fired once by
-- KIPN_ZoneMapRenderer.lua on load so a client's World Map has zone
-- data even before any admin mutates a zone during that session.
------------------------------------------------------------

local function handleRequestZoneSync(player, args)
    sendZoneSync(player)
end

------------------------------------------------------------
-- COMMAND: CreateZone
------------------------------------------------------------
--
-- Expected args:
--   {
--       zoneType = "government" | "dealership" | "custom"
--                  | "do_not_claim",
--       cornerA  = { x = <num>, y = <num>, z = <num> },
--       cornerB  = { x = <num>, y = <num>, z = <num> },
--       label    = <optional string, stored as metadata.label>,
--       combatPolicy = <optional string, see WorldRegistry.CombatPolicies>,
--   }
------------------------------------------------------------

local function handleCreateZone(player, args)
    if not isRequestingPlayerAdmin(player) then
        logError(
            "CreateZone rejected: requesting player is not an admin."
        )

        sendServerCommand(player, MODULE_NAME, "CreateZoneResult", {
            success = false,
            reason = "NOT_AUTHORIZED",
        })

        return
    end

    if type(args) ~= "table" then
        sendServerCommand(player, MODULE_NAME, "CreateZoneResult", {
            success = false,
            reason = "INVALID_REQUEST",
        })

        return
    end

    if not validatePoint(args.cornerA) or not validatePoint(args.cornerB) then
        sendServerCommand(player, MODULE_NAME, "CreateZoneResult", {
            success = false,
            reason = "CORNERS_REQUIRED",
        })

        return
    end

    local metadata = {}

    if type(args.label) == "string" and args.label ~= "" then
        metadata.label = args.label
    end

    if player.getUsername then
        local ok, username = pcall(function() return player:getUsername() end)
        if ok and username then
            metadata.createdBy = username
        end
    end

    if args.combatPolicy ~= nil and
       type(args.combatPolicy) ~= "string" then

        sendServerCommand(player, MODULE_NAME, "CreateZoneResult", {
            success = false,
            reason = "INVALID_COMBAT_POLICY",
        })

        return
    end

    local zone, reason = KIPN.Server.WorldRegistry.CreateZoneFromCorners(
        args.zoneType,
        args.cornerA,
        args.cornerB,
        metadata,
        nil,
        args.combatPolicy
    )

    if not zone then
        logError("CreateZone failed: " .. tostring(reason))

        sendServerCommand(player, MODULE_NAME, "CreateZoneResult", {
            success = false,
            reason = reason,
        })

        return
    end

    sendServerCommand(player, MODULE_NAME, "CreateZoneResult", {
        success = true,
        zoneId = zone.id,
        zoneType = zone.type,
    })

    broadcastZoneSync()
end

------------------------------------------------------------
-- COMMAND: ListZones
------------------------------------------------------------

local function handleListZones(player, args)
    if not isRequestingPlayerAdmin(player) then
        sendServerCommand(player, MODULE_NAME, "ListZonesResult", {
            success = false,
            reason = "NOT_AUTHORIZED",
        })

        return
    end

    local zones = KIPN.Server.WorldRegistry.GetZones()

    -- Flatten into an array; Lua maps keyed by zoneId don't transmit
    -- as cleanly over the network layer as a plain array.
    local list = {}

    for zoneId, zone in pairs(zones) do
        list[#list + 1] = {
            id = zoneId,
            type = zone.type,
            geometry = zone.geometry,
            metadata = zone.metadata,
            combatPolicy = zone.combatPolicy,
            active = zone.active ~= false,
        }
    end

    sendServerCommand(player, MODULE_NAME, "ListZonesResult", {
        success = true,
        zones = list,
    })
end

------------------------------------------------------------
-- COMMAND: DeactivateZone
------------------------------------------------------------

local function handleDeactivateZone(player, args)
    if not isRequestingPlayerAdmin(player) then
        sendServerCommand(player, MODULE_NAME, "DeactivateZoneResult", {
            success = false,
            reason = "NOT_AUTHORIZED",
        })

        return
    end

    if type(args) ~= "table" or not args.zoneId then
        sendServerCommand(player, MODULE_NAME, "DeactivateZoneResult", {
            success = false,
            reason = "ZONE_ID_REQUIRED",
        })

        return
    end

    local ok, reason = KIPN.Server.WorldRegistry.DeactivateZone(args.zoneId)

    sendServerCommand(player, MODULE_NAME, "DeactivateZoneResult", {
        success = ok,
        reason = reason,
        zoneId = args.zoneId,
    })

    if ok then
        broadcastZoneSync()
    end
end

------------------------------------------------------------
-- COMMAND: SetZoneCombatPolicy
------------------------------------------------------------
--
-- Expected args:
--   {
--       zoneId       = <string>,
--       combatPolicy = <string, see WorldRegistry.CombatPolicies>
--                       | false to clear,
--   }
------------------------------------------------------------

local function handleSetZoneCombatPolicy(player, args)
    if not isRequestingPlayerAdmin(player) then
        sendServerCommand(player, MODULE_NAME, "SetZoneCombatPolicyResult", {
            success = false,
            reason = "NOT_AUTHORIZED",
        })

        return
    end

    if type(args) ~= "table" or not args.zoneId then
        sendServerCommand(player, MODULE_NAME, "SetZoneCombatPolicyResult", {
            success = false,
            reason = "ZONE_ID_REQUIRED",
        })

        return
    end

    if args.combatPolicy ~= false and
       type(args.combatPolicy) ~= "string" then

        sendServerCommand(player, MODULE_NAME, "SetZoneCombatPolicyResult", {
            success = false,
            reason = "INVALID_COMBAT_POLICY",
        })

        return
    end

    local ok, reason = KIPN.Server.WorldRegistry.SetZoneCombatPolicy(
        args.zoneId,
        args.combatPolicy
    )

    if not ok then
        logError("SetZoneCombatPolicy failed: " .. tostring(reason))
    end

    sendServerCommand(player, MODULE_NAME, "SetZoneCombatPolicyResult", {
        success = ok,
        reason = reason,
        zoneId = args.zoneId,
        combatPolicy = args.combatPolicy,
    })

    if ok then
        broadcastZoneSync()
    end
end

------------------------------------------------------------
-- COMMAND: SetZoneType
------------------------------------------------------------
--
-- Reclassifies an existing zone (e.g. Government Building ->
-- Custom) without having to delete and redraw it. Used by the
-- KIPN mode inside Project Zomboid's built-in admin Zone Editor
-- (KIPN_ZoneEditorIntegration.lua) so an admin can change a
-- zone's classification the same way they'd change a Non-PVP
-- zone's title.
--
-- Expected args:
--   {
--       zoneId   = <string>,
--       zoneType = "government" | "dealership" | "custom"
--                  | "do_not_claim",
--   }
------------------------------------------------------------

local function handleSetZoneType(player, args)
    if not isRequestingPlayerAdmin(player) then
        sendServerCommand(player, MODULE_NAME, "SetZoneTypeResult", {
            success = false,
            reason = "NOT_AUTHORIZED",
        })

        return
    end

    if type(args) ~= "table" or not args.zoneId then
        sendServerCommand(player, MODULE_NAME, "SetZoneTypeResult", {
            success = false,
            reason = "ZONE_ID_REQUIRED",
        })

        return
    end

    if type(args.zoneType) ~= "string" then
        sendServerCommand(player, MODULE_NAME, "SetZoneTypeResult", {
            success = false,
            reason = "ZONE_TYPE_REQUIRED",
        })

        return
    end

    local ok, reason = KIPN.Server.WorldRegistry.UpdateZone(args.zoneId, {
        type = args.zoneType,
    })

    if not ok then
        logError("SetZoneType failed: " .. tostring(reason))
    end

    sendServerCommand(player, MODULE_NAME, "SetZoneTypeResult", {
        success = ok,
        reason = reason,
        zoneId = args.zoneId,
        zoneType = args.zoneType,
    })

    if ok then
        broadcastZoneSync()
    end
end

------------------------------------------------------------
-- COMMAND: UpdateZone
------------------------------------------------------------
--
-- Renames and/or resizes an existing zone from the standalone map
-- editor. The display name is metadata.label; all other metadata
-- (including createdBy) is preserved. A blank label clears the name.
------------------------------------------------------------

local function handleUpdateZone(player, args)
    if not isRequestingPlayerAdmin(player) then
        sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
            success = false,
            reason = "NOT_AUTHORIZED",
        })
        return
    end

    if type(args) ~= "table" or not args.zoneId then
        sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
            success = false,
            reason = "ZONE_ID_REQUIRED",
        })
        return
    end

    if type(args.label) ~= "string" then
        sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
            success = false,
            reason = "LABEL_REQUIRED",
        })
        return
    end

    if not validateRectangleGeometry(args.geometry) then
        sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
            success = false,
            reason = "RECTANGLE_COORDINATES_INVALID",
        })
        return
    end

    local zone = KIPN.Server.WorldRegistry.GetZone(args.zoneId)

    if not zone then
        sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
            success = false,
            reason = "ZONE_NOT_FOUND",
            zoneId = args.zoneId,
        })
        return
    end

    local metadata = {}
    for key, value in pairs(zone.metadata or {}) do
        metadata[key] = value
    end

    local label = args.label:match("^%s*(.-)%s*$")

    if #label > MAX_ZONE_LABEL_LENGTH then
        sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
            success = false,
            reason = "LABEL_TOO_LONG",
            zoneId = args.zoneId,
        })
        return
    end

    metadata.label = label ~= "" and label or nil

    local previousMetadata = zone.metadata
    local previousGeometry = zone.geometry
    local previousUpdatedAtWorldDays = zone.updatedAtWorldDays

    local ok, reason = KIPN.Server.WorldRegistry.UpdateZone(args.zoneId, {
        metadata = metadata,
        geometry = args.geometry,
    })

    if not ok then
        -- UpdateZone applies fields before persistence. Restore the
        -- in-memory object when validation/save fails so a rejected
        -- admin request never leaks a partial rename or resize.
        zone.metadata = previousMetadata
        zone.geometry = previousGeometry
        zone.updatedAtWorldDays = previousUpdatedAtWorldDays
        logError("UpdateZone failed: " .. tostring(reason))
    end

    sendServerCommand(player, MODULE_NAME, "UpdateZoneResult", {
        success = ok,
        reason = reason,
        zoneId = args.zoneId,
        label = metadata.label,
    })

    if ok then
        broadcastZoneSync()
    end
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------

local function onClientCommand(module, command, player, args)
    if module ~= MODULE_NAME then
        return
    end

    if command == "CreateZone" then
        handleCreateZone(player, args)
    elseif command == "ListZones" then
        handleListZones(player, args)
    elseif command == "DeactivateZone" then
        handleDeactivateZone(player, args)
    elseif command == "SetZoneCombatPolicy" then
        handleSetZoneCombatPolicy(player, args)
    elseif command == "SetZoneType" then
        handleSetZoneType(player, args)
    elseif command == "UpdateZone" then
        handleUpdateZone(player, args)
    elseif command == "RequestZoneSync" then
        handleRequestZoneSync(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)

print("[KIPN] Zone Admin server handler loaded")
