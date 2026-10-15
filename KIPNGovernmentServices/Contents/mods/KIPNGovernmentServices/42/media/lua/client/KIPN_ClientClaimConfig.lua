-- KIPN_ClientClaimConfig.lua
--
-- Client-side mirror of KIPN_ClaimConfig's excavation size tiers.
--
-- Receives and caches the server-authoritative tier list so the client
-- can accurately preview excavation sizes without needing the full
-- server-side configuration engine.

if isServer() then
    return
end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ClaimConfig = KIPN.Server.ClaimConfig or {}

local ClaimConfig = KIPN.Server.ClaimConfig

ClaimConfig.ExcavationSizeTiers = {

    { id = "small", label = "Small (5x5)", widthTiles = 5, heightTiles = 5, price = 200 },

    { id = "medium", label = "Medium (10x10)", widthTiles = 10, heightTiles = 10, price = 500 },

    { id = "large", label = "Large (20x20)", widthTiles = 20, heightTiles = 20, price = 1000 },

}

ClaimConfig.SyncedTiers = nil

local function copyExcavationSizeTiers(list)

    local copy = {}

    if type(list) ~= "table" then
        return copy
    end

    for _, tier in ipairs(list) do

        if type(tier) == "table" then

            table.insert(copy, {
                id = tier.id,
                label = tier.label,
                widthTiles = tier.widthTiles,
                heightTiles = tier.heightTiles,
                price = tier.price,
            })
        end
    end

    return copy
end

function ClaimConfig.GetExcavationSizeTiers()

    if ClaimConfig.SyncedTiers and #ClaimConfig.SyncedTiers > 0 then
        return copyExcavationSizeTiers(ClaimConfig.SyncedTiers)
    end

    return copyExcavationSizeTiers(ClaimConfig.ExcavationSizeTiers)
end

function ClaimConfig.GetExcavationSizeTierById(tierId)

    if type(tierId) ~= "string" or tierId == "" then
        return nil
    end

    local tiers = ClaimConfig.GetExcavationSizeTiers()

    for _, tier in ipairs(tiers) do

        if string.lower(tier.id) == string.lower(tierId) then
            return tier
        end
    end

    return nil
end

local function onServerCommand(module, command, args)

    if module ~= "KIPN" then
        return
    end

    if command == KIPN.Shared.Commands.SERVER_RESPONSE then

        local event = args and args.event
        local data = args and args.data

        if event == KIPN.Shared.ResponseEvents.EXCAVATION_SIZE_TIERS_DATA then

            ClaimConfig.SyncedTiers =
                type(data) == "table"
                and data.tiers
                or {}

        end

    end

end

local function requestTiers()

    if type(sendClientCommand) == "function" then

        sendClientCommand(
            "KIPN",
            KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS,
            {}
        )

    end

end

if Events and Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerCommand)
end

if Events and Events.OnGameStart then
    Events.OnGameStart.Add(requestTiers)
end
