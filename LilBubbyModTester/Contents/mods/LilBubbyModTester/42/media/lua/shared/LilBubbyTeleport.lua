-- Native teleport shared by every suite. The server chooses and validates each
-- destination; the requesting player's own client then moves with the
-- engine's IsoPlayer:teleportTo. No admin role, RCON or helper process.
--
-- Build 42's speed anti-cheat samples each client's position about once per
-- second and rejects more than 20 tiles/s. Only the server's native teleport
-- command resets it, and Lua cannot reach that, so unless the server disables
-- AntiCheatSpeed (or the player may teleport anyway) the move is made in hops
-- of HOP tiles every HOP_MS. Two hops can fall in one sample: 16 tiles/s worst case.
LilBubbyTeleport = LilBubbyTeleport or {}
local T = LilBubbyTeleport

T.MODULE = "LilBubbyTeleport"
T.HOP = 8
T.HOP_MS = 1000
T.POLICY_DISABLED = 4 -- AntiCheat policy "Disabled" in the server INI
T.SETTLE_MS = 15000   -- allowance for the destination to load after the last hop

local function distance(ax, ay, bx, by)
    return math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
end

-- Can this player be moved in one jump? Single player always can.
function T.CanJump(player)
    if not isServer() then return true end
    local ok, policy = pcall(function() return tonumber(getServerOptions():getOption("AntiCheatSpeed")) end)
    if ok and policy == T.POLICY_DISABLED then return true end
    local exempt
    ok, exempt = pcall(function()
        local role = player:getRole()
        return role ~= nil and role:hasCapability(Capability.TeleportToCoordinates)
    end)
    return ok and exempt == true
end

-- Time a caller should allow for the move to finish.
function T.ExpectedMs(player, x, y, hop)
    if not hop then return T.SETTLE_MS end
    local tiles = distance(player:getX(), player:getY(), x + 0.5, y + 0.5)
    return math.ceil(tiles / hop) * T.HOP_MS + T.SETTLE_MS
end

-- Orders the move and returns the arrival allowance in milliseconds. Call on
-- the server in multiplayer, or anywhere in single player.
function T.Order(player, x, y, z)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    local hop = not T.CanJump(player) and T.HOP or nil
    local expected = T.ExpectedMs(player, x, y, hop)
    local args = { playerID = player:getOnlineID(), x = x, y = y, z = z, hop = hop }
    if isServer() then
        sendServerCommand(player, T.MODULE, "move", args)
    else
        T.Travel(player, args)
    end
    return expected
end

function T.Arrived(player, x, y, z)
    return math.abs(player:getX() - (x + 0.5)) < 2 and math.abs(player:getY() - (y + 0.5)) < 2
        and math.floor(player:getZ()) == z and player:getCurrentSquare() ~= nil
end

------------------------------------------------------------
-- CLIENT: performs the move
------------------------------------------------------------

T.travels = T.travels or {}

function T.Travelling(player) return T.travels[player] ~= nil end

function T.Step(player, now)
    local travel = T.travels[player]
    if not travel or now < travel.next then return end
    if player:isDead() then T.travels[player] = nil; return end
    local tx, ty = travel.x + 0.5, travel.y + 0.5
    local left = distance(player:getX(), player:getY(), tx, ty)
    if not travel.hop or left <= travel.hop then
        T.travels[player] = nil
        player:teleportTo(tx, ty, travel.z)
        if HaloTextHelper then HaloTextHelper.addText(player, "Arrived") end
        return
    end
    -- Intermediate hops stay on the ground floor; only the last one sets z.
    local step = travel.hop / left
    player:teleportTo(player:getX() + (tx - player:getX()) * step, player:getY() + (ty - player:getY()) * step, 0)
    travel.next = now + T.HOP_MS
end

function T.Travel(player, args)
    if ISTimedActionQueue then ISTimedActionQueue.clear(player) end
    T.travels[player] = { x = args.x, y = args.y, z = args.z, hop = tonumber(args.hop), next = 0 }
    T.Step(player, getTimestampMs())
end

if not isServer() then
    Events.OnTick.Add(function()
        local now -- Kahlua has no next(); only read the clock while someone travels
        for player in pairs(T.travels) do
            now = now or getTimestampMs()
            T.Step(player, now)
        end
    end)
    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= T.MODULE or command ~= "move" or type(args) ~= "table" then return end
        for index = 0, getNumActivePlayers() - 1 do
            local player = getSpecificPlayer(index)
            if player and player:getOnlineID() == args.playerID then T.Travel(player, args) end
        end
    end)
end

return LilBubbyTeleport
