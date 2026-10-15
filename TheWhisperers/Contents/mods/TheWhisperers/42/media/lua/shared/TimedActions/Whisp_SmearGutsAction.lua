-- Smear guts over yourself. GutsSmearEfficiency percent of what is left in
-- the guts is spread evenly over the body and every worn garment; the rest
-- is lost. Smeared guts start the corpse sickness process. Queued with
-- untilFull (Smear All), the queue stops once the gore gives full
-- camouflage (FullGorePercent).
require "TimedActions/ISBaseTimedAction"
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

Whisp_SmearGutsAction = ISBaseTimedAction:derive("Whisp_SmearGutsAction")

function Whisp_SmearGutsAction:isValid()
    return self.guts ~= nil and self.character:getInventory():containsRecursive(self.guts)
end

function Whisp_SmearGutsAction:isFull()
    return self.untilFull and W.camoStrength(W.measureGore(self.character)) >= 1
end

function Whisp_SmearGutsAction:isValidStart()
    return not self:isFull()
end

function Whisp_SmearGutsAction:start()
    self:setActionAnim("WashFace")
    self:setOverrideHandModels(nil, self.guts)
    self.sound = self.character:playSound("ButcheringGatherMeatSmall")
end

function Whisp_SmearGutsAction:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopOrTriggerSound(self.sound)
    end
end

function Whisp_SmearGutsAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function Whisp_SmearGutsAction:perform()
    self:stopSound()
    ISBaseTimedAction.perform(self)
end

function Whisp_SmearGutsAction:complete()
    if not self.guts or not self.guts:getContainer() then return false end
    -- Already fully camouflaged by the time this one lands: keep the guts.
    if self:isFull() then return true end

    local capacity = G.gutsCapacity(self.guts)
    local spread = capacity * W.Get("GutsSmearEfficiency") / 100 * W.Get("GutsCoveragePerItem") / 100
    G.addBloodEverywhere(self.character, spread)

    local md = self.character:getModData()
    md.WhispGutsPct = W.clamp((md.WhispGutsPct or 0) + spread * 100, 0, 100)

    G.removeItem(self.character, self.guts)
    return true
end

function Whisp_SmearGutsAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return 150
end

function Whisp_SmearGutsAction:new(character, guts, untilFull)
    local o = ISBaseTimedAction.new(self, character)
    o.guts = guts
    o.untilFull = untilFull == true
    o.stopOnWalk = false
    o.maxTime = o:getDuration()
    return o
end
