require "LilBubbyPacer"
require "SkylightsTest_World"

-- Multiplayer half of the Skylights suite: every world change the test needs
-- (structure, materials, cleanup) is made here, and the server tells the
-- player what to do once the materials are theirs. Open to every player.
local MODULE = SkylightsTest.MODULE
local World = SkylightsTest.World
local OPS = { room = true, materials = true, cleanup = true, site = true }

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player or not OPS[command] then return end
    args = type(args) == "table" and args or {}
    local reply = { op = command, id = args.id }
    if not SkylightsTest.available() then
        reply.error = "Skylights is not enabled on this server."
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
