-- The Whisperers: zombie mannerisms. In an intact face mask and skin suit the
-- player stands, walks, runs, sprints and sits on the ground like a zombie.
-- The WhispZombieGait animation variable picks the Whisp_Zombie* nodes in
-- media/AnimSets/player. Every client sets it on every player it can see,
-- since worn items are visible to all, so remote players shamble too.
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

G.GaitVariable = "WhispZombieGait"

local CHECK_MS = 250
local lastMs = 0

function G.updateZombieGait(player)
    local want = G.wantsZombieGait(player)
    if player:getVariableBoolean(G.GaitVariable) ~= want then
        player:setVariable(G.GaitVariable, want)
    end
    return want
end

local function onTick()
    local now = getTimestampMs()
    if now - lastMs < CHECK_MS then return end
    lastMs = now
    if isClient() then
        local players = getOnlinePlayers()
        for i = 0, (players and players:size() or 0) - 1 do
            G.updateZombieGait(players:get(i))
        end
    else
        for playerNum = 0, 3 do
            local player = getSpecificPlayer(playerNum)
            if player then G.updateZombieGait(player) end
        end
    end
end

Events.OnTick.Add(onTick)
