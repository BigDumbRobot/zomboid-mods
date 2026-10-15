require "LilBubbyPacer"
require "LilBubbyPrep"

-- Multiplayer half of character preparation. Every command acts on its
-- authenticated sender only; Teach accepts only the enabled mods' recipes.
local P = LilBubbyPrep
local COMMANDS = { grant = P.Grant, teach = function(player, args) return P.Teach(player, args.recipes) end, tidy = P.Tidy }

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= P.MODULE or not player or not COMMANDS[command] then return end
    args = type(args) == "table" and args or {}
    -- Queued behind this player's previous request, never refused for speed.
    LilBubbyPacer.Run(player, P.MODULE, 50, function()
        local ok, result = pcall(COMMANDS[command], player, args)
        local reply = ok and result or { error = tostring(result) }
        reply.op = command
        reply.playerID = player:getOnlineID()
        print("[" .. P.MODULE .. "] " .. command .. " " .. player:getUsername() .. (reply.error and (" error: " .. reply.error) or ""))
        sendServerCommand(player, P.MODULE, "reply", reply)
    end)
end)
