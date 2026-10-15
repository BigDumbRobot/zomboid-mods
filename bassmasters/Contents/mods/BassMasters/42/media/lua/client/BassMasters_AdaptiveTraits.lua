-- Bass Masters and Adaptive Traits. Bass Masters doesn't need Adaptive Traits. When it's loaded,
-- this adds a "BassMaster" entry to its registry, the same shape as its own entries: Adaptive
-- Traits calls update(player) every in-game minute, and when every requirement in BM.MASTER
-- (BassMasters_Shared.lua) is met, it grants the Bass Master trait through its own Manager, which
-- handles multiplayer and the "Gained Bass Master" notification. Without Adaptive Traits, nothing
-- here runs and the Bass Master page stays out of the logbook.

require "BassMasters_Shared"

local BM = BassMasters

local function adaptiveTraitsActive()
    local mods = getActivatedMods()
    return mods ~= nil and (mods:contains("AdaptiveTraits") or mods:contains("\\AdaptiveTraits"))
end

BM.adaptiveTraits = false

if adaptiveTraitsActive() and BM.TRAIT then
    local Registry = require("AdaptiveTraits/Registry")
    local Manager = require("AdaptiveTraits/Manager")
    if Registry and Registry.getEntries and Manager and Manager.addTrait then
        BM.adaptiveTraits = true
        Registry.getEntries().BassMaster = {
            update = function(player)
                if not player or not BM.sandbox("BassMasterCanGain", true) then return end
                if player:hasTrait(BM.TRAIT) or not BM.data then return end
                local _, all = BM.masterProgress(BM.data(player))
                if all then
                    Manager.addTrait(player, BM.TRAIT, true)
                end
            end,
        }
    end
end
