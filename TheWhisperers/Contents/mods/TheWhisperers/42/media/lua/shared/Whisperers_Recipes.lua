-- The Whisperers: craft recipe callbacks (see scripts/Whisperers_Recipes.txt).
require "Whisperers_Gear"
require "Whisperers_Stake"

local W = Whisperers
local G = W.Gear
W.Recipes = W.Recipes or {}
local R = W.Recipes

local function collect(list, out)
    if not list then return end
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
end

local function inputs(data)
    local items = {}
    pcall(function() collect(data:getAllInputItems(), items) end)
    pcall(function() collect(data:getAllConsumedItems(), items) end)
    pcall(function() collect(data:getAllKeepInputItems(), items) end)
    return items
end

local function findType(items, fullType)
    for _, it in ipairs(items) do
        if it and it:getFullType() == fullType then return it end
    end
    return nil
end

local function created(data, fullType)
    local list = {}
    pcall(function() collect(data:getAllCreatedItems(), list) end)
    return findType(list, fullType)
end

-- The mask keeps the face's owner and damage; a nail tears it further.
function R.OnCreateFaceMask(craftRecipeData, character)
    local items = inputs(craftRecipeData)
    local mask = created(craftRecipeData, G.Types.Mask)
    if not mask then return end
    local face = findType(items, G.Types.Face)
    local owner = face and face:getModData().WhispOwner or nil
    local quality = face and face:getModData().WhispQuality or 1
    local nail = findType(items, "Base.Nails") ~= nil
        and findType(items, "Base.Needle") == nil
        and findType(items, "Base.SutureNeedle") == nil

    local cond = mask:getConditionMax() * quality
    if nail then cond = cond * (1 - W.Get("NailDamage") / 100) end
    local md = mask:getModData()
    md.WhispOwner = owner
    md.WhispCond = cond
    W.Stake.applyMaskFace(mask, face and face:getModData()[W.Stake.LookKey])
    md.WhispDried = G.hours()
    mask:setCondition(math.max(1, math.floor(cond + 0.5)))
    G.setItemName(mask, G.maskName(owner))
end

function R.OnCreateHeadStake(craftRecipeData, character)
    local items = inputs(craftRecipeData)
    local head = findType(items, G.Types.Head) or findType(items, G.Types.FacelessHead)
    local stake = created(craftRecipeData, G.Types.Stake)
    if not stake then return end
    local owner = head and head:getModData().WhispOwner or nil
    local md = stake:getModData()
    md.WhispOwner = owner
    md[G.SkillsKey] = head and G.copySkills(head:getModData()) or nil
    md.WhispFaceless = head ~= nil and head:getFullType() == G.Types.FacelessHead or nil
    local look = head and head:getModData()[W.Stake.LookKey]
    md[W.Stake.LookKey] = type(look) == "table" and look or nil
    G.setItemName(stake, G.stakeName(owner))
    W.Stake.dressFromModData(stake)
end

-- The brain is named for the head it came from.
function R.OnCreateBrain(craftRecipeData, character)
    local items = inputs(craftRecipeData)
    local head = findType(items, G.Types.Head) or findType(items, G.Types.FacelessHead)
    local brain = created(craftRecipeData, G.Types.Brain)
    if not brain then return end
    local owner = head and head:getModData().WhispOwner or nil
    brain:getModData().WhispOwner = owner
    brain:getModData()[G.SkillsKey] = head and G.copySkills(head:getModData()) or nil
    G.setItemName(brain, G.brainName(owner))
end

-- Brain tan keeps a face mask or skin suit from drying out.
function R.OnCreateTreatGear(craftRecipeData, character)
    for _, it in ipairs(inputs(craftRecipeData)) do
        if G.isGear(it) then
            G.treatGear(character, it)
            G.announce(character, "IGUI_Whisp_GearTreated", true)
            return
        end
    end
end

local function resolvePerk(name)
    local perk = Perks and Perks[name]
    if perk then return perk end
    local ok, found = pcall(function() return Perks.FromString(name) end)
    return ok and found or nil
end

-- Raises perk by `levels` (never past 10) without sandbox XP multipliers.
local function giveLevels(player, perk, levels)
    local target = math.min(10, player:getPerkLevel(perk) + levels)
    if target <= player:getPerkLevel(perk) then return false end
    local need = PerkFactory.getPerk(perk):getTotalXpForLevel(target) - player:getXp():getXP(perk)
    if need <= 0 then return false end
    addXpNoMultiplier(player, perk, need + 0.01)
    return true
end

-- Food OnEat (see Whisperers_Items.txt). A zombie's brain carries the Knox
-- virus; a player's carries a little of what they knew.
function W.OnEatBrain(food, character, percent)
    if isClient() or not food or not character then return end
    local md = food:getModData()
    if md.WhispOwner then
        local skills = md[G.SkillsKey]
        md[G.SkillsKey] = nil -- one helping of knowledge per brain
        local learned = false
        if type(skills) == "table" then
            for name, level in pairs(skills) do
                local perk = resolvePerk(name)
                if perk and level >= W.Get("PlayerBrainMinSkill")
                    and giveLevels(character, perk, W.Get("PlayerBrainLevels")) then
                    learned = true
                end
            end
        end
        if learned then G.announce(character, "IGUI_Whisp_BrainLearned", true) end
        return
    end

    pcall(function()
        character:getBodyDamage():getBodyPart(BodyPartType.Head):generateZombieInfection(100)
    end)
    local stats = character:getStats()
    local stat = CharacterStat.FOOD_SICKNESS
    local max = stat:getMaximumValue()
    stats:set(stat, math.min(max, stats:get(stat) + max * W.Get("ZombieBrainSickness") / 100))
    W.syncStats(character, { stat })
end

-- Pulling a stake apart: the head and the stick each break at
-- HeadStakeBreakChance percent. A surviving head keeps its owner and face.
function R.OnCreateDisassembleHeadStake(craftRecipeData, character)
    local stake = findType(inputs(craftRecipeData), G.Types.Stake)
    local md = stake and stake:getModData() or {}
    local owner, faceless = md.WhispOwner, md.WhispFaceless == true
    local chance = W.Get("HeadStakeBreakChance")

    if ZombRand(100) < chance then
        G.announce(character, "IGUI_Whisp_StakeHeadBroke", false)
    else
        G.addToInventory(character, faceless and G.Types.FacelessHead or G.Types.Head, function(head)
            local hmd = head:getModData()
            hmd.WhispOwner = owner
            hmd[G.SkillsKey] = G.copySkills(md)
            hmd[W.Stake.LookKey] = md[W.Stake.LookKey]
            local name = G.headName(owner)
            if faceless then
                hmd.WhispFaceless = true
                name = name .. " " .. G.text("IGUI_Whisp_FacelessSuffix", nil, "(Faceless)")
            end
            G.setItemName(head, name)
        end)
    end

    if ZombRand(100) < chance then
        G.announce(character, "IGUI_Whisp_StakeStickBroke", false)
    else
        G.addToInventory(character, "Base.LongStick")
    end
end

return R
