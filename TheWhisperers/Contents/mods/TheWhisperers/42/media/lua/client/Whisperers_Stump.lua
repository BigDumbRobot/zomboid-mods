-- The Whisperers: the neck stump belongs to headless corpses only, the stick
-- and flayed face to head stakes. They are hidden items, so no inventory
-- window lists them; this also stops "loot all", queued transfers and other
-- mods from moving them (the minute tick destroys any that reach a player).
require "TimedActions/ISInventoryTransferAction"
require "Whisperers_Gear"

local G = Whisperers.Gear

local origIsValid = ISInventoryTransferAction.isValid
function ISInventoryTransferAction:isValid()
    if G.isVisualOnly(self.item) then return false end
    return origIsValid(self)
end

local origTransferItem = ISInventoryTransferAction.transferItem
function ISInventoryTransferAction:transferItem(item)
    if G.isVisualOnly(item) then return end
    return origTransferItem(self, item)
end
