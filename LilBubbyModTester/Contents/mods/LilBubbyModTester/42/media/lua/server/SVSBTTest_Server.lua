require "LilBubbyPacer"
require "SVSBTTest_Traps"

-- Multiplayer half of the Spy vs Spy trap tests: the server gives the
-- ingredients, places the car or mailbox, checks the crafted trap and cleans
-- up. Open to every player.
local T = SVSBTTest.Traps

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= T.MODULE or not player or not T.OPS[command] then return end
    args = type(args) == "table" and args or {}
    local reply = { op = command, id = args.id, playerID = player:getOnlineID() }
    -- Queued behind this player's previous request, never refused for speed.
    LilBubbyPacer.Run(player, T.MODULE, 50, function()
        local ok, result = pcall(T.OPS[command], player, args)
        if ok then
            for key, value in pairs(result or {}) do reply[key] = value end
        else
            reply.error = tostring(result)
        end
        print("[" .. T.MODULE .. "] " .. command .. " " .. player:getUsername() .. (reply.error and (" error: " .. reply.error) or ""))
        sendServerCommand(player, T.MODULE, "reply", reply)
    end)
end)
