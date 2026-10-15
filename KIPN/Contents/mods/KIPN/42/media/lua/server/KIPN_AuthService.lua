-- KIPN_AuthService.lua
--
-- Server-authoritative KIPN player-data service.
--
-- RESPONSIBILITIES:
--   * Answer the lightweight "who am I" query (GET_PLAYER_DATA)
--     used by Main Menu and other client screens.
--   * Command handler registration for that query.
--
-- IMPORTANT:
--   * This file MUST only execute on the server.
--   * KIPN does not maintain a username/password account system.
--     A connected player's identity is their native Steam ID
--     (see KIPN.Shared.GetPlayerId), and their KIPN access level
--     is resolved from Project Zomboid's own server-authoritative
--     player:getAccessLevel() (see
--     KIPN.Server.Permissions.ResolveAccessLevel), plus the
--     KIPN.AdminAccounts sandbox override. There is no login step
--     and nothing here is client-trusted.
--
-- Server folder:
--   media/lua/server/KIPN_AuthService.lua
--------------------------------------------------------------------------------

if isClient() then return end

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_Permissions"

KIPN.Server.AuthService = KIPN.Server.AuthService or {}

local AuthService = KIPN.Server.AuthService

--------------------------------------------------------------------------------
-- GET PLAYER DATA
--------------------------------------------------------------------------------
--
-- Lightweight "who am I" query used by several client screens
-- (Main Menu, etc.) that only need the current player's display
-- name and KIPN access level.
--
-- accessLevel is resolved via KIPN.Server.Permissions.ResolveAccessLevel,
-- which defers to Project Zomboid's own server-authoritative access
-- level (player:getAccessLevel()) -- KIPN does not maintain a
-- second, KIPN-specific notion of "admin" here -- plus the
-- KIPN.AdminAccounts sandbox override, which grants KIPN ADMIN
-- access to a configured server account regardless of PZ access level.
--------------------------------------------------------------------------------

local function handleGetPlayerData(player, args)
    if not player then
        return false
    end

    --------------------------------------------------------
    -- KIPN ACCESS LEVEL
    --------------------------------------------------------

    local accessLevel = "USER"

    local permissions = KIPN.Server.Permissions

    local levelOk, levelResult =
        pcall(function()
            if not (permissions and permissions.ResolveAccessLevel) then
                return "USER"
            end

            return permissions.ResolveAccessLevel(player)
        end)

    if levelOk and levelResult then
        accessLevel = levelResult
    end

    --------------------------------------------------------
    -- DISPLAY NAME
    --------------------------------------------------------

    local username = nil

    pcall(function()
        if player.getUsername then
            username = player:getUsername()
        end
    end)

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.PLAYER_DATA,
        {
            username = username,
            accessLevel = accessLevel,
        }
    )

    return true
end

--------------------------------------------------------------------------------
-- INITIALIZATION
--------------------------------------------------------------------------------

local initialized = false

function AuthService.Initialize()
    if initialized then
        return true
    end

    if type(KIPN.Server.RegisterCommandHandler) ~= "function" then
        return false
    end

    KIPN.Server.RegisterCommandHandler(
        KIPN.Shared.Commands.GET_PLAYER_DATA,
        handleGetPlayerData
    )

    initialized = true

    return true
end

--------------------------------------------------------------------------------
-- MODULE LOAD
--------------------------------------------------------------------------------

-- AuthService.Initialize() must be explicitly hooked into the server
-- lifecycle. Defining the function alone does not execute it.
--
-- This registration ensures the GET_PLAYER_DATA command handler is
-- installed before clients attempt to use it.
--
-- AuthService remains server-only.

print("[KIPN] AUTH SERVICE MODULE LOADED")
print("[KIPN] AuthService loaded; initialization delegated to KIPN_Server.")
