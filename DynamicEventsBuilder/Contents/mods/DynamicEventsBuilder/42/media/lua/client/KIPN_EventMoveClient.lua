-- KIPN_EventMoveClient.lua
--
-- The player's half of a move (server/KIPN_EventMoveService.lua). In
-- multiplayer the client owns its position, so the server asks and the
-- client moves itself. With a hop size the move is made in hops of that
-- many tiles, one a second, so the speed anti-cheat does not reject it.

if isServer() and not isClient() then return end

require "DynamicEvents_Shared"

KIPN_EventMoveClient = KIPN_EventMoveClient or {}
local C = KIPN_EventMoveClient

C.HOP_MS = 1000

local pending

local function place(player, x, y, z)
    pcall(function()
        if player:getVehicle() then player:getVehicle():exit(player) end
    end)
    local ok = pcall(function() player:teleportTo(x, y, z) end)
    if not ok then
        pcall(function()
            player:setX(x); player:setY(y); player:setZ(z)
            player:setLx(x); player:setLy(y); player:setLz(z)
        end)
    end
end

-- Moves the local player to {x, y, z}, in hops of `hop` tiles if given.
function C.Move(data)
    local player = getPlayer()
    if not player or not data or not data.x or not data.y then return end
    local z = data.z or 0
    if not data.hop or data.hop <= 0 then
        pending = nil
        place(player, data.x, data.y, z)
        return
    end
    pending = { x = data.x, y = data.y, z = z, hop = data.hop, next = 0 }
end

function C.Pending() return pending end

local function onTick()
    if not pending then return end
    local now = getTimestampMs()
    if now < pending.next then return end
    pending.next = now + C.HOP_MS
    local player = getPlayer()
    if not player then pending = nil; return end
    local dx, dy = pending.x - player:getX(), pending.y - player:getY()
    local distance = math.sqrt(dx * dx + dy * dy)
    if distance <= pending.hop then
        place(player, pending.x, pending.y, pending.z)
        pending = nil
        return
    end
    local step = pending.hop / distance
    place(player, player:getX() + dx * step, player:getY() + dy * step, pending.z)
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN" or not args then return end
    local Shared = KIPN and KIPN.Shared
    if not Shared or command ~= Shared.Commands.SERVER_RESPONSE then return end
    if args.event ~= Shared.ResponseEvents.EVENT_MOVE_PLAYER then return end
    C.Move(args.data)
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
