-- KIPNCareers_ThreatsClient.lua  (framework core)
--
-- Display only. The server (KIPNCareers_Threats.lua) decides everything about
-- a threat; this file just draws the speech line it sends over the matching
-- body's head.

require "KIPNCareers_Shared"

local Shared = KIPNCareers.Shared

local function findZombie(onlineId)
    local cell = type(getCell) == "function" and getCell() or nil
    local zombies = cell and cell:getZombieList() or nil
    for index = 0, (zombies and zombies:size() or 0) - 1 do
        local zombie = zombies:get(index)
        if zombie and zombie:getOnlineID() == onlineId then return zombie end
    end
    return nil
end

local function onServerCommand(module, command, arguments)
    if module ~= Shared.MODULE or type(arguments) ~= "table" then return end
    if not KIPN or not KIPN.Shared or not KIPN.Shared.Commands or command ~= KIPN.Shared.Commands.SERVER_RESPONSE then return end
    if arguments.event ~= Shared.ThreatEvents.SAY then return end
    local data = type(arguments.data) == "table" and arguments.data or {}
    local zombie = findZombie(tonumber(data.id))
    if zombie and data.text then
        pcall(zombie.addLineChatElement, zombie, tostring(data.text), tonumber(data.r) or 1, tonumber(data.g) or 1, tonumber(data.b) or 1)
    end
end

if Events.OnServerCommand then Events.OnServerCommand.Add(onServerCommand) end
