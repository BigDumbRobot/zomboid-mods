-- The Whisperers: a head stake is a mannequin, but only its head is real.
-- Hats and masks can go on it; nothing else. The loot window's outfit
-- buttons (wear all, switch outfit) are hidden, since the stake's only
-- "clothes" are its hidden stick and flayed face.
require "TimedActions/ISInventoryTransferAction"
require "ISUI/LootWindow/Handlers/MannequinSwitchOutfit"
require "ISUI/LootWindow/Handlers/MannequinWearAll"
require "Whisperers_Stake"

local G = Whisperers.Gear
local S = Whisperers.Stake

for _, handler in ipairs({
    ISLootWindowObjectControlHandler_MannequinSwitchOutfit,
    ISLootWindowObjectControlHandler_MannequinWearAll,
}) do
    local orig = handler.shouldBeVisible
    handler.shouldBeVisible = function(self)
        if S.isStake(self.object) then return false end
        return orig(self)
    end
end

local origIsValid = ISInventoryTransferAction.isValid
function ISInventoryTransferAction:isValid()
    local dest = self.destContainer and self.destContainer:getParent()
    if S.isStake(dest) and not G.isHeadLocation(self.item) then return false end
    return origIsValid(self)
end
