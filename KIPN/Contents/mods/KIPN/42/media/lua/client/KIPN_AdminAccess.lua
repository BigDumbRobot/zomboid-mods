-- KIPN_AdminAccess.lua
--
-- Shared client-side view of KIPN's server-authoritative access level.
-- Native PZ access is available immediately as a UI hint, but only the
-- server can apply KIPN.AdminAccounts. GET_PLAYER_DATA is therefore
-- requested once after the local player exists and the resolved level
-- is cached for every KIPN admin entry point to consume.
--
-- This cache controls presentation only. Every privileged command must
-- continue to re-authorize the player on the server.

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}
KIPN.Client.AdminAccess = KIPN.Client.AdminAccess or {}

local AdminAccess = KIPN.Client.AdminAccess

local PZ_ACCESS_TO_KIPN = {
    admin = "ADMIN",
    moderator = "MODERATOR",
    overseer = "STAFF",
    gm = "GM",
    observer = "OBSERVER",
}

local function getLocalAccessLevel(playerNum)
    local adminOk, adminResult = pcall(function()
        return type(isAdmin) == "function" and isAdmin() == true
    end)

    if adminOk and adminResult then
        return "ADMIN"
    end

    local player = getSpecificPlayer(playerNum or 0)

    if not player then
        return "USER"
    end

    -- Build 42's admin UI and privileged tools are authorized through
    -- the player's Role.  A role may have admin power even when the
    -- legacy access-level APIs report "None", so check the same role
    -- signal vanilla uses before consulting getAccessLevel().
    local roleOk, roleIsAdmin = pcall(function()
        local role = player.getRole and player:getRole() or nil
        return role
            and role.hasAdminPower
            and role:hasAdminPower() == true
    end)

    if roleOk and roleIsAdmin then
        return "ADMIN"
    end

    if not player.getAccessLevel then
        return "USER"
    end

    local ok, level = pcall(function()
        return player:getAccessLevel()
    end)

    if not ok or level == nil then
        return "USER"
    end

    return PZ_ACCESS_TO_KIPN[string.lower(tostring(level))] or "USER"
end

function AdminAccess.GetAccessLevel(playerNum)
    local localAccessLevel = getLocalAccessLevel(playerNum)

    -- The server result is authoritative for KIPN-only grants such as
    -- AdminAccounts, but it must not erase a native Build 42 admin role
    -- from presentation if an older/partially initialized server reports
    -- USER. Privileged commands are still re-authorized server-side.
    if localAccessLevel == "ADMIN" then
        return "ADMIN"
    end

    if AdminAccess.resolvedAccessLevel ~= nil then
        return AdminAccess.resolvedAccessLevel
    end

    return localAccessLevel
end

function AdminAccess.IsResolved()
    return AdminAccess.resolvedAccessLevel ~= nil
end

function AdminAccess.IsAdmin(playerNum)
    return AdminAccess.GetAccessLevel(playerNum) == "ADMIN"
end

function AdminAccess.AddListener(listener)
    if type(listener) ~= "function" then
        return false
    end

    AdminAccess.listeners = AdminAccess.listeners or {}
    AdminAccess.listeners[#AdminAccess.listeners + 1] = listener
    return true
end

function AdminAccess.Request()
    if AdminAccess.resolvedAccessLevel ~= nil
        or type(sendClientCommand) ~= "function"
        or not KIPN.Shared.Commands.GET_PLAYER_DATA then
        return AdminAccess.resolvedAccessLevel ~= nil
    end

    local ok = pcall(function()
        sendClientCommand(
            "KIPN",
            KIPN.Shared.Commands.GET_PLAYER_DATA,
            {}
        )
    end)

    return ok
end

local requestOnTick

local function onServerResponse(module, command, args)
    if module ~= "KIPN"
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
        or not args
        or args.event ~= KIPN.Shared.ResponseEvents.PLAYER_DATA then
        return
    end

    local data = args.data

    if type(data) ~= "table" or data.accessLevel == nil then
        return
    end

    local resolvedAccessLevel =
        string.upper(tostring(data.accessLevel))

    if AdminAccess.resolvedAccessLevel == resolvedAccessLevel then
        return
    end

    AdminAccess.resolvedAccessLevel = resolvedAccessLevel

    Events.OnTick.Remove(requestOnTick)

    for _, listener in ipairs(AdminAccess.listeners or {}) do
        pcall(listener, resolvedAccessLevel)
    end
end

local ticksUntilRequest = 0
requestOnTick = function()
    if AdminAccess.resolvedAccessLevel ~= nil then
        Events.OnTick.Remove(requestOnTick)
        return
    end

    if not getSpecificPlayer(0) then
        return
    end

    -- A local player can exist shortly before the multiplayer command
    -- channel is ready.  Retry at a modest interval until the response
    -- is actually received instead of treating a non-throwing send as
    -- proof that the server handled it.
    if ticksUntilRequest > 0 then
        ticksUntilRequest = ticksUntilRequest - 1
        return
    end

    AdminAccess.Request()
    ticksUntilRequest = 60
end

if not AdminAccess._initialized then
    AdminAccess._initialized = true
    Events.OnServerCommand.Add(onServerResponse)
    Events.OnTick.Add(requestOnTick)
end

print("[KIPN] Client admin access loaded")

return AdminAccess
