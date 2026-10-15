-- Flay a corpse and sew its skin into a suit. Needs Tailoring and Butchering,
-- a butchering blade, a sewing tool and three face masks' worth of clasp
-- material. Nothing of the body is left behind.
require "TimedActions/ISBaseTimedAction"
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

Whisp_SkinCorpseAction = ISBaseTimedAction:derive("Whisp_SkinCorpseAction")

Whisp_SkinCorpseAction.Sets = 3

function Whisp_SkinCorpseAction.meetsSkills(character)
    return character:getPerkLevel(Perks.Tailoring) >= W.Get("SuitTailoring")
        and character:getPerkLevel(Perks.Butchering) >= W.Get("SuitButchering")
end

function Whisp_SkinCorpseAction:isValid()
    local inv = self.character:getInventory()
    return self.body ~= nil and G.canSkin(self.body)
        and Whisp_SkinCorpseAction.meetsSkills(self.character)
        and self.knife ~= nil and inv:containsRecursive(self.knife) and not self.knife:isBroken()
        and self.tool ~= nil and inv:containsRecursive(self.tool)
        and G.totalUses(self.character, self.claspType) >= (G.claspNeed(self.claspType, Whisp_SkinCorpseAction.Sets) or 999)
end

function Whisp_SkinCorpseAction:waitToStart()
    self.character:faceThisObject(self.body)
    return self.character:shouldBeTurning()
end

function Whisp_SkinCorpseAction:update()
    self.character:faceThisObject(self.body)
end

function Whisp_SkinCorpseAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")
    self:setOverrideHandModels(self.knife, nil)
    self.sound = self.character:playSound("ButcheringGatherMeatLarge")
end

function Whisp_SkinCorpseAction:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopOrTriggerSound(self.sound)
    end
end

function Whisp_SkinCorpseAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function Whisp_SkinCorpseAction:perform()
    self:stopSound()
    ISBaseTimedAction.perform(self)
end

function Whisp_SkinCorpseAction:complete()
    if not self.body or not G.canSkin(self.body) then return false end
    local need = G.claspNeed(self.claspType, Whisp_SkinCorpseAction.Sets)
    if not need or not G.consumeUses(self.character, self.claspType, need) then return false end

    local owner = G.corpseOwnerName(self.body)
    local damage = G.isNail(self.tool) and W.Get("NailDamage") or 0
    G.addToInventory(self.character, G.Types.Suit, function(suit)
        local md = suit:getModData()
        md.WhispOwner = owner
        local cond = suit:getConditionMax() * (1 - damage / 100)
        md.WhispCond = cond
        md.WhispDried = G.hours()
        suit:setCondition(math.max(1, math.floor(cond + 0.5)))
        G.setItemName(suit, G.suitName(owner))
    end)

    self.body:getModData().WhispSkinned = true
    G.removeCorpse(self.body)

    G.addBloodEverywhere(self.character, 0.15)
    addXp(self.character, Perks.Tailoring, 20)
    addXp(self.character, Perks.Butchering, 15)
    return true
end

function Whisp_SkinCorpseAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    local t = 1500 - self.character:getPerkLevel(Perks.Tailoring) * 40 - self.character:getPerkLevel(Perks.Butchering) * 40
    return math.max(600, t)
end

function Whisp_SkinCorpseAction:new(character, body, knife, tool, claspType)
    local o = ISBaseTimedAction.new(self, character)
    o.body = body
    o.knife = knife
    o.tool = tool
    o.claspType = claspType
    o.maxTime = o:getDuration()
    return o
end
