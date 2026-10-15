-- KIPN_EventBanditClient.lua
--
-- Display only. The server (server/KIPN_EventBanditService.lua) decides
-- everything about bandits; this draws the line it sends over the
-- matching bandit's head, in the careers threats' hostile red.

if isServer() and not isClient() then return end

require "DynamicEvents_Shared"

local function findZombie(onlineId)
    local cell = getCell()
    local zombies = cell and cell:getZombieList() or nil
    for i = 0, (zombies and zombies:size() or 0) - 1 do
        local zombie = zombies:get(i)
        if zombie and zombie:getOnlineID() == onlineId then return zombie end
    end
    return nil
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN" or type(args) ~= "table" then return end
    local Shared = KIPN and KIPN.Shared
    if not Shared or command ~= Shared.Commands.SERVER_RESPONSE then return end
    if args.event ~= Shared.ResponseEvents.EVENT_BANDIT_SAY then return end
    local data = type(args.data) == "table" and args.data or {}
    local zombie = findZombie(tonumber(data.id))
    if zombie and data.text then
        pcall(function() zombie:addLineChatElement(tostring(data.text), 1.0, 0.45, 0.4) end)
    end
end

Events.OnServerCommand.Add(onServerCommand)
