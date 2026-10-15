require "LilBubbyPacer"
require "WhisperersTest_World"

-- Multiplayer half of The Whisperers suite: every world change the test needs
-- (tools, skills, corpses, a zombie, a weapon hit, guts age, washing, cleanup)
-- is made here, for any player; every argument is checked.
local MODULE = WhisperersTest.MODULE
local World = WhisperersTest.World
local OPS = { setup = true, give = true, corpse = true, zombie = true, removeZombies = true, hit = true,
    ageGuts = true, wash = true, cleanup = true, stakeKit = true, placeStakes = true, gaitKit = true }

local function valid(command, args)
    if command == "corpse" or command == "zombie" then
        return (args.dx == nil or type(args.dx) == "number") and (args.dy == nil or type(args.dy) == "number")
            and math.abs(args.dx or 0) <= 10 and math.abs(args.dy or 0) <= 10
    elseif command == "hit" then
        return type(args.damage) == "number" and args.damage > 0 and args.damage <= 100
    elseif command == "give" then
        return type(args.type) == "string"
    elseif command == "stakeKit" then
        return type(args.kind) == "number" and WhisperersTest.STAKE_KINDS[args.kind] ~= nil
    elseif command == "placeStakes" then
        return type(args.ids) == "table" and #args.ids <= 10
    elseif command == "ageGuts" then
        return type(args.hours) == "number" and args.hours >= 0 and args.hours <= 10000
    end
    return true
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player or not OPS[command] then return end
    args = type(args) == "table" and args or {}
    local reply = { op = command, id = args.id }
    if not WhisperersTest.available() then
        reply.error = "The Whisperers is not enabled on this server."
    elseif not valid(command, args) then
        reply.error = "Invalid " .. command .. " request."
    else
        -- Queued behind this player's previous request, never refused for speed.
        LilBubbyPacer.Run(player, MODULE, 50, function()
            local ok, result = pcall(World[command], player, args)
            if ok then
                for key, value in pairs(result or {}) do reply[key] = value end
            else
                reply.error = tostring(result)
            end
            print("[" .. MODULE .. "] " .. command .. " " .. player:getUsername() .. (reply.error and (" error: " .. reply.error) or ""))
            sendServerCommand(player, MODULE, "reply", reply)
        end)
        return
    end
    print("[" .. MODULE .. "] " .. command .. " " .. player:getUsername() .. " refused: " .. tostring(reply.error))
    sendServerCommand(player, MODULE, "reply", reply)
end)
