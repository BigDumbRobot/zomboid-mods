-- KIPN_EventMoveService.lua
--
-- Moving a player: joining an event, being returned to the zone, the
-- Olympics start line, flying out of an extraction, a simulation's next
-- hotspot. In multiplayer a player's own client owns its position, so a
-- server-side setX does not move them; the server asks their client to
-- move instead (client/KIPN_EventMoveClient.lua). In single player the
-- move is made directly.
--
-- Build 42's speed anti-cheat rejects more than about 20 tiles a second
-- unless the server disables it or the player may teleport, and Lua
-- cannot reset it. Long moves are therefore made in hops of HOP tiles a
-- second for everyone else; short ones (up to JUMP_TILES) always jump.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "DynamicEvents_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventMoveService = KIPN.Server.EventMoveService or {}

local Move = KIPN.Server.EventMoveService

Move.HOP = 8
Move.JUMP_TILES = 16
Move.POLICY_DISABLED = 4 -- AntiCheatSpeed "Disabled" in the server INI

-- May this player be moved any distance in one jump?
function Move.CanJump(player)
    if not isServer() then return true end
    local ok, policy = pcall(function() return tonumber(getServerOptions():getOption("AntiCheatSpeed")) end)
    if ok and policy == Move.POLICY_DISABLED then return true end
    local exempt
    ok, exempt = pcall(function()
        local role = player:getRole()
        return role ~= nil and role:hasCapability(Capability.TeleportToCoordinates)
    end)
    return ok and exempt == true
end

-- Moves the player to exactly point {x, y, z} (a remembered position
-- stays exact; callers pick tile centres themselves). Returns true if
-- the move was made or ordered.
function Move.Player(player, point)
    if not player or not point or not tonumber(point.x) or not tonumber(point.y) then return false end
    local x, y, z = tonumber(point.x), tonumber(point.y), math.floor(tonumber(point.z) or 0)
    pcall(function()
        if player.getVehicle and player:getVehicle() then player:setVehicle(nil) end
    end)
    if isServer() then
        local distance = math.sqrt((player:getX() - x) ^ 2 + (player:getY() - y) ^ 2)
        local hop = (distance > Move.JUMP_TILES and not Move.CanJump(player)) and Move.HOP or nil
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.EVENT_MOVE_PLAYER, { x = x, y = y, z = z, hop = hop })
        return true
    end
    return (pcall(function()
        player:setX(x); player:setY(y); player:setZ(z)
        player:setLx(x); player:setLy(y); player:setLz(z)
    end))
end

return Move
