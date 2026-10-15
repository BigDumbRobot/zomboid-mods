-- The Whisperers: MP server. Applies misery to player stats and relays each
-- player's meter to every client, because zombies are simulated by whichever
-- client owns them and that client needs to know how loud the target is.
require "Whisperers_Shared"
require "Whisperers_Gear"

if not isServer() then return end

local W = Whisperers

local function onClientCommand(module, command, player, args)
    if module ~= W.Module or command ~= "State" or not player or type(args) ~= "table" then return end

    local meter = W.clamp(tonumber(args.m) or 0, 0, W.FullMeter)
    local strength = W.clamp(tonumber(args.s) or 0, 0, 1)
    local disguise = W.clamp(tonumber(args.l) or 0, 0, 1)
    local gore = W.clamp(tonumber(args.g) or 0, 0, 100)
    local active = args.a == true and W.isCamouflaged(gore)

    -- Keep the player's name on them so their corpse can be named later.
    W.Gear.stampPlayerName(player)
    W.applyMisery(player, gore, args.d == true)

    sendServerCommand(W.Module, "State", {
        id = player:getOnlineID(),
        m = meter,
        s = strength,
        l = disguise,
        a = active,
    })
end

Events.OnClientCommand.Add(onClientCommand)
