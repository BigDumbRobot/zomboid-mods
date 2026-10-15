-- The Whisperers: head stakes are mannequins. A vanilla body model shows the
-- head; the hidden StakeStick clothing masks everything below the neck and
-- puts a stick there, and StakeFaceless flays the face of a faceless head.
-- Like vanilla's scarecrow, the look is built on a throwaway mannequin and
-- saved into the Head Stake item's byte data. Placing restores it and picking
-- up saves it again (ISMoveableSpriteProps), so a stake keeps its head.
require "Whisperers_Gear"
require "Moveables/ISMoveableSpriteProps"

local W = Whisperers
local G = W.Gear
W.Stake = W.Stake or {}
local S = W.Stake

S.Sprite = "whisperers_headstake_01_0"
S.ScriptPrefix = "Whisp_Stake_"
S.LookKey = "WhispLook"

-- Skins with a mannequin script (Whisperers_Mannequins.txt).
S.Skins = { male = { human = {}, zombie = {} }, female = { human = {}, zombie = {} } }
for i = 1, 5 do
    table.insert(S.Skins.male.human, "MaleBody0" .. i)
    table.insert(S.Skins.male.human, "MaleBody0" .. i .. "a")
    table.insert(S.Skins.female.human, "FemaleBody0" .. i)
end
for i = 1, 4 do
    for gender, prefix in pairs({ male = "M", female = "F" }) do
        local base = prefix .. "_ZedBody0" .. i
        table.insert(S.Skins[gender].zombie, base)
        for level = 1, 3 do table.insert(S.Skins[gender].zombie, base .. "_level" .. level) end
    end
end

-- Every skin a face mask can wear, in the order of Whisp_FaceMask.xml's
-- textureChoices (tools/gen_face_mask_xml.py writes that list from this one).
-- Zombie skins come first, so masks made before faces were kept show a dead face.
S.MaskSkins = {}
for _, kind in ipairs({ "zombie", "human" }) do
    for _, gender in ipairs({ "male", "female" }) do
        for _, skin in ipairs(S.Skins[gender][kind]) do table.insert(S.MaskSkins, skin) end
    end
end

local HairColors = {
    { 0.10, 0.08, 0.06 }, { 0.22, 0.15, 0.09 }, { 0.35, 0.22, 0.12 }, { 0.52, 0.38, 0.20 },
    { 0.70, 0.58, 0.35 }, { 0.42, 0.16, 0.06 }, { 0.45, 0.45, 0.45 }, { 0.75, 0.75, 0.72 },
}

local function pick(list)
    if not list or #list == 0 then return nil end
    return list[ZombRand(#list) + 1]
end

local function isHumanSkin(skin)
    for _, gender in pairs(S.Skins) do
        for _, s in ipairs(gender.human) do
            if s == skin then return true end
        end
    end
    return false
end

local function colorTable(c)
    if not c then return nil end
    return { c:getRedFloat(), c:getGreenFloat(), c:getBlueFloat() }
end

local function toColor(t)
    if type(t) ~= "table" then return nil end
    return ImmutableColor.new(t[1] or 0, t[2] or 0, t[3] or 0, 1)
end

local function randomStyle(list)
    local names = {}
    if list then
        for i = 0, list:size() - 1 do
            local style = list:get(i)
            -- Hair styles have isNoChoose; beard styles don't.
            local ok, hidden = pcall(function() return style:isNoChoose() end)
            hidden = ok and hidden
            if style and not hidden and style:getName() then
                names[#names + 1] = style:getName()
            end
        end
    end
    return pick(names)
end

-- Every head keeps the face it had: skin, hair and beard, read off the corpse
-- before beheading shaves it. human is true for a player's head.
function S.captureLook(body, human)
    local ok, look = pcall(function()
        local hv = body:getHumanVisual()
        return {
            female = body:isFemale(),
            skin = hv:getSkinTexture(),
            hair = hv:getHairModel(),
            beard = hv:getBeardModel(),
            hairColor = colorTable(hv:getHairColor()),
            beardColor = colorTable(hv:getBeardColor()),
            human = human and true or nil,
        }
    end)
    return ok and look or nil
end

-- A head from before faces were kept gets a stranger's look: either sex, any
-- skin, living or rotten. humanOnly is for such a player's head.
function S.randomLook(humanOnly)
    local female = ZombRand(2) == 0
    local skins = S.Skins[female and "female" or "male"]
    local pool = {}
    for _, s in ipairs(skins.human) do pool[#pool + 1] = s end
    if not humanOnly then
        for _, s in ipairs(skins.zombie) do pool[#pool + 1] = s end
    end
    local look = { female = female, skin = pick(pool), human = humanOnly or nil }
    pcall(function()
        local hair = getHairStylesInstance()
        look.hair = randomStyle(female and hair:getAllFemaleStyles() or hair:getAllMaleStyles())
        if not female and ZombRand(100) < 40 then
            look.beard = randomStyle(getBeardStylesInstance():getAllStyles())
        end
    end)
    local color = pick(HairColors)
    look.hairColor = color
    look.beardColor = color
    return look
end

function S.scriptFor(look)
    local gender = look.female and "female" or "male"
    local skin = look.skin
    -- A player's head always looks human; a skin from another mod has no
    -- script of ours, so it falls back to a vanilla one of the same kind.
    if look.human and not isHumanSkin(skin) then skin = nil end
    local name = skin and (S.ScriptPrefix .. skin) or nil
    if not name or not getScriptManager():getMannequinScript(name) then
        name = S.ScriptPrefix .. S.Skins[gender][look.human and "human" or "zombie"][1]
    end
    return name
end

-- The textureChoices index (0-based) a face mask uses for a look.
function S.maskTextureIndex(look)
    if type(look) ~= "table" then return 0 end
    for i, skin in ipairs(S.MaskSkins) do
        if skin == look.skin then return i - 1 end
    end
    local fallback = S.Skins[look.female and "female" or "male"][look.human and "human" or "zombie"][1]
    for i, skin in ipairs(S.MaskSkins) do
        if skin == fallback then return i - 1 end
    end
    return 0
end

-- A face mask shows the face it was cut from.
function S.applyMaskFace(mask, look)
    if not mask or type(look) ~= "table" then return false end
    mask:getModData()[S.LookKey] = look
    local ok = pcall(function() mask:getVisual():setTextureChoice(S.maskTextureIndex(look)) end)
    return ok
end

local function wear(mannequin, fullType)
    local item = instanceItem(fullType)
    if not item then return end
    mannequin:getContainer():AddItem(item)
    mannequin:getWornItems():setItem(item:getScriptItem():getBodyLocation(), item)
end

-- Dead is dead: a bloody neck and a grubby face on every head.
local function bloody(hv)
    hv:setBlood(BloodBodyPartType.Neck, 1)
    hv:setBlood(BloodBodyPartType.Head, 0.3 + ZombRandFloat(0, 0.5))
    hv:setDirt(BloodBodyPartType.Head, ZombRandFloat(0.2, 0.7))
end

-- Builds the mannequin a stake item places, and stores it in the item.
function S.dress(item, look, faceless)
    local sprite = getSprite(S.Sprite)
    if not item or not sprite then return false end
    local ok = pcall(function()
        local mannequin = IsoMannequin.new(getCell(), nil, sprite)
        mannequin:setMannequinScriptName(S.scriptFor(look))
        local hv = mannequin:getHumanVisual()
        hv:setHairModel(look.hair or "Bald")
        hv:setBeardModel(look.female and "" or (look.beard or ""))
        local hairColor = toColor(look.hairColor)
        if hairColor then
            hv:setHairColor(hairColor)
            hv:setNaturalHairColor(hairColor)
        end
        local beardColor = toColor(look.beardColor)
        if beardColor then
            hv:setBeardColor(beardColor)
            hv:setNaturalBeardColor(beardColor)
        end
        bloody(hv)
        wear(mannequin, G.Types.StakeStick)
        if faceless then wear(mannequin, G.Types.StakeFaceless) end
        mannequin:setCustomSettingsToItem(item)
    end)
    return ok
end

-- Dresses a stake from its own modData, inventing a head if it has none.
function S.dressFromModData(item)
    local md = item:getModData()
    -- Without a name of its own a moveable shows its tile's ("Mannequin").
    G.setItemName(item, G.stakeName(md.WhispOwner))
    if type(md[S.LookKey]) ~= "table" then
        md[S.LookKey] = S.randomLook(md.WhispOwner ~= nil)
    end
    return S.dress(item, md[S.LookKey], md.WhispFaceless == true)
end

function S.isStake(object)
    if not object or not instanceof(object, "IsoMannequin") then return false end
    local name = object:getMannequinScriptName()
    return name ~= nil and name:sub(1, #S.ScriptPrefix) == S.ScriptPrefix
end

-- Moveables ------------------------------------------------------------------

-- What a stake remembers across being placed and picked up. Placing copies
-- the item's modData onto the mannequin; picking up only keeps the byte data,
-- so these keys are copied back by hand.
local CarriedKeys = { "WhispOwner", "WhispFaceless", S.LookKey, G.SkillsKey }

local pickingUp = nil

local origPickUp = ISMoveableSpriteProps.pickUpMoveableInternal
function ISMoveableSpriteProps:pickUpMoveableInternal(character, square, object, sprInstance, spriteName, createItem, rotating)
    pickingUp = (object and object.getModData and object:getModData()) or nil
    local item = origPickUp(self, character, square, object, sprInstance, spriteName, createItem, rotating)
    pickingUp = nil
    return item
end

-- The item is made before it is added and sent to the player, so its name
-- and modData go with it.
local origInstance = ISMoveableSpriteProps.instanceItem
function ISMoveableSpriteProps:instanceItem(spriteNameOverride)
    local item = origInstance(self, spriteNameOverride)
    if item and item:getFullType() == G.Types.Stake then
        pcall(function() item:setWorldSprite(S.Sprite) end)
        if pickingUp then
            local md = item:getModData()
            for _, key in ipairs(CarriedKeys) do md[key] = pickingUp[key] end
            G.setItemName(item, G.stakeName(md.WhispOwner))
        end
    end
    return item
end

-- Stakes made before 3D stakes (or spawned) have no mannequin yet, and ones
-- picked up from an old flat tile still point at it.
local origPlace = ISMoveableSpriteProps.placeMoveableInternal
function ISMoveableSpriteProps:placeMoveableInternal(square, item, spriteName)
    if item and item:getFullType() == G.Types.Stake then
        spriteName = S.Sprite
        pcall(function() item:setWorldSprite(S.Sprite) end)
        if not item:getByteData() then S.dressFromModData(item) end
    end
    return origPlace(self, square, item, spriteName)
end

return S
