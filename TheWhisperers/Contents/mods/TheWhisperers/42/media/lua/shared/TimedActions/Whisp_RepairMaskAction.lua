-- Re-sew a face mask. Needs Tailoring 5 (MaskRepairTailoring) and the same
-- clasp material and sewing tool as making one. Timed like repairing a
-- garment. A needle restores the mask fully; a nail leaves it torn.
require "TimedActions/ISBaseTimedAction"
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

Whisp_RepairMaskAction = ISBaseTimedAction:derive("Whisp_RepairMaskAction")

function Whisp_RepairMaskAction.canRepair(character, mask)
    return mask ~= nil and mask:getFullType() == G.Types.Mask
        and mask:getCondition() < mask:getConditionMax()
        and character:getPerkLevel(Perks.Tailoring) >= W.Get("MaskRepairTailoring")
end

function Whisp_RepairMaskAction:isValid()
    local inv = self.character:getInventory()
    return Whisp_RepairMaskAction.canRepair(self.character, self.mask)
        and inv:containsRecursive(self.mask)
        and self.tool ~= nil and inv:containsRecursive(self.tool)
        and G.totalUses(self.character, self.claspType) >= (G.claspNeed(self.claspType, 1) or 999)
end

function Whisp_RepairMaskAction:start()
    self:setActionAnim("SewingCloth")
    self:setOverrideHandModels(self.tool, self.mask)
end

function Whisp_RepairMaskAction:complete()
    local need = G.claspNeed(self.claspType, 1)
    if not need or not G.consumeUses(self.character, self.claspType, need) then return false end

    local max = self.mask:getConditionMax()
    local target = G.isNail(self.tool) and max * (1 - W.Get("NailDamage") / 100) or max
    local md = self.mask:getModData()
    if (md.WhispCond or self.mask:getCondition()) < target then
        md.WhispCond = target
        self.mask:setCondition(math.floor(target + 0.5))
        G.setItemName(self.mask, G.maskName(md.WhispOwner))
        if isServer() then
            syncItemModData(self.character, self.mask)
            syncItemFields(self.character, self.mask)
        end
    end

    addXp(self.character, Perks.Tailoring, 5)
    return true
end

function Whisp_RepairMaskAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 150 - (self.character:getPerkLevel(Perks.Tailoring) * 6)
end

function Whisp_RepairMaskAction:new(character, mask, tool, claspType)
    local o = ISBaseTimedAction.new(self, character)
    o.mask = mask
    o.tool = tool
    o.claspType = claspType
    o.maxTime = o:getDuration()
    return o
end
