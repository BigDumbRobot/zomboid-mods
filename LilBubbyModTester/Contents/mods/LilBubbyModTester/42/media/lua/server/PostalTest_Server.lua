require "PostalTest_Checks"
require "PostalTest_Guided"
require "LilBubbyPacer"
require "LilBubbyDesk"

local MODULE = "LilBubbyPostalTest"
local allowed = { guards = true }
local function reply(player, text)
    print("[" .. MODULE .. "] " .. player:getUsername() .. " | " .. text)
    sendServerCommand(player, MODULE, "result", { playerID = player:getOnlineID(), text = text })
end

-- The guided test's steps: each answer goes back to the request that asked.
local G = PostalTest.Guided
local function guided(command, player, args)
    local answer = { op = command, id = args.id, playerID = player:getOnlineID() }
    if player:isDead() then
        answer.error = "A living player is required."
        sendServerCommand(player, MODULE, "reply", answer)
        return
    end
    -- Queued behind this player's previous request, never refused for speed.
    LilBubbyPacer.Run(player, MODULE .. ":guided", 50, function()
        local ok, result = pcall(G.OPS[command], player, args)
        if ok then
            for key, value in pairs(result or {}) do answer[key] = value end
        else
            answer.error = tostring(result)
        end
        print("[" .. MODULE .. "] " .. command .. " " .. player:getUsername() .. (answer.error and (" error: " .. answer.error) or ""))
        sendServerCommand(player, MODULE, "reply", answer)
    end)
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player then return end
    if G.OPS[command] then guided(command, player, type(args) == "table" and args or {}); return end
    if command ~= "run" then return end
    if player:isDead() then reply(player, "BLOCKED: A living player is required."); return end
    local suite = type(args) == "table" and (args.suite or "guards") or "guards"
    if type(suite) ~= "string" or not allowed[suite] then reply(player, "ERROR: Unknown postal suite."); return end
    -- Requests are queued behind the previous one, never dropped.
    LilBubbyPacer.Run(player, MODULE, 100, function()
        -- Only the engine-authenticated requester reaches the suite. No target player,
        -- item type, quantity, parcel ID, coordinates or order ID comes from the client.
        local ok, text = pcall(PostalTest.Run, player, suite)
        reply(player, ok and text or ("ERROR: " .. tostring(text)))
    end)
end)
