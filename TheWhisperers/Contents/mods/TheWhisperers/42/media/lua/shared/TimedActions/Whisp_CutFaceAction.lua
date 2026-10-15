-- Cut the face off a corpse head with a short blade. Butchering skill and
-- blade sharpness both make it faster and cleaner; a master with a keen
-- edge takes the face off quickly and whole.
require "TimedActions/ISBaseTimedAction"
require "Whisperers_Gear"
require "Whisperers_Stake"

local W = Whisperers
local G = W.Gear

Whisp_CutFaceAction = ISBaseTimedAction:derive("Whisp_CutFaceAction")

-- 0 (clean) .. 1 (ruined), before a little randomness.
function Whisp_CutFaceAction.baseDamage(character, knife)
    local skill = character:getPerkLevel(Perks.Butchering) / 10
    local sharp = G.sharpness(knife)
    return W.clamp((1 - skill) * 0.6 + (1 - sharp) * 0.4, 0, 1)
end

function Whisp_CutFaceAction:isValid()
    local inv = self.character:getInventory()
    return self.head ~= nil and not self.head:getModData().WhispFaceless
        and inv:containsRecursive(self.head)
        and self.knife ~= nil and inv:containsRecursive(self.knife)
        and G.bladeClass(self.knife) == "short"
end

function Whisp_CutFaceAction:start()
    self:setActionAnim("SlicingFood")
    self:setOverrideHandModels(self.knife, self.head)
    self.sound = self.character:playSound("ButcheringGatherMeatSmall")
end

function Whisp_CutFaceAction:stopSound()
    if self.sound and self.character:getEmitter():isPlaying(self.sound) then
        self.character:getEmitter():stopOrTriggerSound(self.sound)
    end
end

function Whisp_CutFaceAction:stop()
    self:stopSound()
    ISBaseTimedAction.stop(self)
end

function Whisp_CutFaceAction:perform()
    self:stopSound()
    ISBaseTimedAction.perform(self)
end

function Whisp_CutFaceAction:complete()
    if not self.head or self.head:getModData().WhispFaceless then return false end

    local damage = Whisp_CutFaceAction.baseDamage(self.character, self.knife)
    -- A little luck either way, but a perfect cut stays perfect.
    damage = W.clamp(damage * ZombRandFloat(0.8, 1.2), 0, 0.95)
    local quality = 1 - damage
    local owner = self.head:getModData().WhispOwner

    G.addToInventory(self.character, G.Types.Face, function(face)
        local md = face:getModData()
        md.WhispOwner = owner
        md.WhispQuality = quality
        md[W.Stake.LookKey] = self.head:getModData()[W.Stake.LookKey]
        local name = G.faceName(owner)
        if damage >= 0.05 then
            name = name .. " (" .. math.floor(quality * 100 + 0.5) .. "%)"
        end
        G.setItemName(face, name)
    end)

    -- Swap in the faceless head item (its own icon and ground image),
    -- carrying the old head's modData across.
    local oldMd = self.head:getModData()
    G.removeItem(self.character, self.head)
    G.addToInventory(self.character, G.Types.FacelessHead, function(head)
        local md = head:getModData()
        for k, v in pairs(oldMd) do md[k] = v end
        md.WhispFaceless = true
        G.setItemName(head, G.headName(owner) .. " " .. G.text("IGUI_Whisp_FacelessSuffix", nil, "(Faceless)"))
    end)

    addXp(self.character, Perks.Butchering, 5)
    return true
end

function Whisp_CutFaceAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    local skill = self.character:getPerkLevel(Perks.Butchering)
    local sharp = G.sharpness(self.knife)
    local t = W.Get("FaceCutBaseTime") * (1 - 0.07 * skill) * (1.6 - 0.6 * sharp)
    return math.max(60, math.floor(t))
end

function Whisp_CutFaceAction:new(character, head, knife)
    local o = ISBaseTimedAction.new(self, character)
    o.head = head
    o.knife = knife
    o.maxTime = o:getDuration()
    return o
end
