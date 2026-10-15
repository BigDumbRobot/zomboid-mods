-- Butcher a human corpse for guts. Same requirement (an animal-butchering
-- blade) and timing as butchering an animal on the ground; the yield scales
-- with Butchering.
require "TimedActions/ISBaseTimedAction"
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

Whisp_ButcherCorpseAction = ISBaseTimedAction:derive("Whisp_ButcherCorpseAction")

function Whisp_ButcherCorpseAction:isValid()
    return self.body ~= nil and G.canButcher(self.body)
        and self.knife ~= nil and self.character:getInventory():containsRecursive(self.knife)
        and not self.knife:isBroken()
end

function Whisp_ButcherCorpseAction:waitToStart()
    self.character:faceThisObject(self.body)
    return self.character:shouldBeTurning()
end

function Whisp_ButcherCorpseAction:update()
    self.character:faceThisObject(self.body)
end

function Whisp_ButcherCorpseAction:start()
    self:setActionAnim("Loot")
    self.character:SetVariable("LootPosition", "Low")
    self.character:reportEvent("EventLootItem")
    self:setOverrideHandModels(self.knife, nil)
    self.sound = self.character:playSound("ButcheringGatherMeatLarge")
end

function Whisp_ButcherCorpseAction:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopOrTriggerSound(self.sound)
    end
end

function Whisp_ButcherCorpseAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function Whisp_ButcherCorpseAction:perform()
    self:stopSound()
    ISBaseTimedAction.perform(self)
end

function Whisp_ButcherCorpseAction:complete()
    if not self.body or not G.canButcher(self.body) then return false end

    local skill = self.character:getPerkLevel(Perks.Butchering)
    local yield = W.Get("GutsBaseYield") + skill * W.Get("GutsYieldPerLevel")
    local count = math.max(1, math.floor(yield + ZombRandFloat(0, 1)))
    local now = G.hours()
    for _ = 1, count do
        G.addToInventory(self.character, G.Types.Guts, function(guts)
            guts:getModData().WhispBorn = now
            G.refreshGuts(guts)
        end)
    end

    self.body:getModData().WhispGutted = true
    G.transmitBody(self.body)

    -- Elbow-deep in a corpse: the butcher comes away bloodied.
    G.addBloodEverywhere(self.character, 0.1)
    addXp(self.character, Perks.Butchering, 4 * count)
    return true
end

function Whisp_ButcherCorpseAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 900 - (self.character:getPerkLevel(Perks.Butchering) * 20)
end

function Whisp_ButcherCorpseAction:new(character, body, knife)
    local o = ISBaseTimedAction.new(self, character)
    o.body = body
    o.knife = knife
    o.maxTime = o:getDuration()
    return o
end
