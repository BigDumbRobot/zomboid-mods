-- Take a corpse's head. Counted in blows, like chopping a tree:
--   swords / katanas   one blow
--   long blades, axes  a handful of downward chops (fewer with Butchering)
--   short blades       many downward stabs, each one tiring
-- Each blow is an animation event on the client; the server emulates the
-- same events on a timer and decides when the head comes off.
require "TimedActions/ISBaseTimedAction"
require "Whisperers_Gear"
require "Whisperers_Stake"

local W = Whisperers
local G = W.Gear

Whisp_RemoveHeadAction = ISBaseTimedAction:derive("Whisp_RemoveHeadAction")

-- Server-side blow interval per animation, roughly matching the clips.
local BLOW_MS = {
    Whisp_ChopFloor2H = 1500,
    Whisp_ChopFloor1H = 1100,
    Whisp_StabFloor = 900,
}

function Whisp_RemoveHeadAction:anim()
    if self.class == "short" then return "Whisp_StabFloor" end
    if self.weapon:isTwoHandWeapon() then return "Whisp_ChopFloor2H" end
    return "Whisp_ChopFloor1H"
end

function Whisp_RemoveHeadAction:isValid()
    if not self.body or not G.canBehead(self.body) then return false end
    if not self.weapon or self.weapon:isBroken() then return false end
    if self.character:getPrimaryHandItem() ~= self.weapon then return false end
    if self.class == "short" and not self.character:isEnduranceSufficientForAction() then return false end
    return true
end

function Whisp_RemoveHeadAction:waitToStart()
    self.character:faceThisObject(self.body)
    return self.character:shouldBeTurning()
end

function Whisp_RemoveHeadAction:update()
    self.character:faceThisObject(self.body)
    if self.action then self:setJobDelta(math.min(1, self.blows / self.needed)) end
    if instanceof(self.character, "IsoPlayer") then
        self.character:setMetabolicTarget(Metabolics.HeavyWork)
    end
end

function Whisp_RemoveHeadAction:start()
    self:setActionAnim(self:anim())
    if self.weapon:isTwoHandWeapon() then
        self:setOverrideHandModels(self.weapon, self.weapon)
    else
        self:setOverrideHandModels(self.weapon, nil)
    end
end

function Whisp_RemoveHeadAction:serverStart()
    emulateAnimEvent(self.netAction, BLOW_MS[self:anim()] or 1200, "WhispBlow", nil)
end

function Whisp_RemoveHeadAction:playBlowSound()
    local ok, snd = pcall(function() return self.weapon:getZombieHitSound() end)
    if ok and snd and snd ~= "" then
        self.character:playSound(snd)
    else
        self.character:playSound("ButcheringGatherMeatSmall")
    end
end

function Whisp_RemoveHeadAction:animEvent(event, parameter)
    if event ~= "WhispBlow" then return end
    self.blows = self.blows + 1

    if isClient() then
        self:playBlowSound()
        return
    end

    if not isServer() then self:playBlowSound() end

    -- Sawing through a neck with a knife is exhausting.
    if self.class == "short" then
        self.character:getStats():remove(CharacterStat.ENDURANCE, W.Get("ShortBladeEndurancePerStab"))
    else
        self.character:getStats():remove(CharacterStat.ENDURANCE, W.Get("ShortBladeEndurancePerStab") * 0.25)
    end

    if self.blows >= self.needed then
        if isServer() then
            self.netAction:forceComplete()
        else
            self:forceComplete()
        end
    end
end

function Whisp_RemoveHeadAction:stop()
    ISBaseTimedAction.stop(self)
end

function Whisp_RemoveHeadAction:perform()
    ISBaseTimedAction.perform(self)
end

function Whisp_RemoveHeadAction:complete()
    if not self.body or not G.canBehead(self.body) then return false end

    local owner = G.corpseOwnerName(self.body)
    local skills = owner and G.copySkills(self.body:getModData()) or nil
    -- The head keeps its face (for stakes and masks): read it before the corpse is shaved.
    local look = W.Stake.captureLook(self.body, owner ~= nil)
    G.addToInventory(self.character, G.Types.Head, function(head)
        head:getModData().WhispOwner = owner
        head:getModData()[G.SkillsKey] = skills
        head:getModData()[W.Stake.LookKey] = look
        G.setItemName(head, G.headName(owner))
    end)

    self.body:getModData().WhispHeadless = true
    G.transmitBody(self.body)
    G.applyCorpseVisuals(self.body)

    addXp(self.character, Perks.Butchering, self.class == "short" and 6 or 3)
    return true
end

function Whisp_RemoveHeadAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return -1
end

function Whisp_RemoveHeadAction:new(character, body, weapon)
    local o = ISBaseTimedAction.new(self, character)
    o.body = body
    o.weapon = weapon
    o.class = G.bladeClass(weapon)
    o.needed = G.headBlows(character, weapon)
    o.blows = 0
    o.forceProgressBar = true
    o.caloriesModifier = o.class == "short" and 6 or 4
    o.maxTime = o:getDuration()
    return o
end
