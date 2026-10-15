-- KIPN_EventAccessService.lua
--
-- Who may use the Event Studio and who may be invited into simulations,
-- by KIPN access level and this server's sandbox options (see "STAFF
-- ACCESS" in DynamicEvents_Shared.lua). Admins always may. Every Studio
-- command (definitions, hotspots, teams, prizes, the prepared-event
-- actions, simulations, past events) is gated here, on the server.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventAccessService = KIPN.Server.EventAccessService or {}

local Access = KIPN.Server.EventAccessService

-- The player's KIPN access level ("ADMIN", "MODERATOR", ..., "USER").
function Access.Level(player)
    local permissions = KIPN.Server.Permissions
    if not player or not permissions or type(permissions.ResolveAccessLevel) ~= "function" then return "USER" end
    local ok, level = pcall(permissions.ResolveAccessLevel, player)
    return ok and level or "USER"
end

-- May this player be invited into a simulation?
function Access.CanJoinSimulations(player)
    return KIPN.Shared.EventAccessAllows("Simulation", Access.Level(player))
end

-- Gate for every Studio command. Staff levels the sandbox allows pass;
-- everyone else goes through KIPN's admin check, which also tells the
-- player why they were refused.
function Access.RequireStudio(player)
    local level = Access.Level(player)
    if level ~= "ADMIN" and KIPN.Shared.EventAccessAllows("Studio", level) then return true end
    return KIPN.Server.AdminService.RequirePermission(player, KIPN.Shared.Permissions.SYSOP_CONFIGURATION)
end

return Access
