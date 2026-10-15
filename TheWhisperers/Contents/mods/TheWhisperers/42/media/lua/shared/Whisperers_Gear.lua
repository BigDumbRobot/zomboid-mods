-- The Whisperers: corpse, weapon, material, guts and worn-gear helpers.
-- Shared so timed actions can use them on the server in MP.
require "Whisperers_Shared"

local W = Whisperers
W.Gear = W.Gear or {}
local G = W.Gear

G.Types = {
    Guts = "Whisperers.Guts",
    Head = "Whisperers.CorpseHead",
    FacelessHead = "Whisperers.CorpseHeadFaceless",
    Face = "Whisperers.CorpseFace",
    Brain = "Whisperers.CorpseBrain",
    Mask = "Whisperers.FaceMask",
    Suit = "Whisperers.SkinSuit",
    Stake = "Whisperers.HeadStake",
    Stump = "Whisperers.NeckStump",
    StakeStick = "Whisperers.StakeStick",
    StakeFaceless = "Whisperers.StakeFaceless",
}

-- Swords and katanas take a head in one blow.
G.RareLongBlades = {
    ["Base.Katana"] = true,
    ["Base.Sword"] = true,
    ["Base.ShortSword"] = true,
}

-- Clasp materials, cheapest first, with the uses one face mask needs.
G.Clasps = {
    { type = "Base.Thread", uses = 2 },
    { type = "Base.Twine", uses = 2 },
    { type = "Base.FishingLine", uses = 2 },
    { type = "Base.DentalFloss", uses = 4 },
    { type = "Base.Wire", uses = 1 },
}

-- Needles first: they never damage the work. A nail is a last resort.
G.SewingTools = { "Base.Needle", "Base.SutureNeedle", "Base.Nails" }

G.NameKey = "WhispName"          -- player modData, copied onto their corpse
G.LegacyNameKey = "SO_CorpsePlayerName" -- Satanic Temples' tag, if present

function G.authoritative()
    return not isClient()
end

function G.hours()
    return getGameTime():getWorldAgeHours()
end

local function text(key, arg, fallback)
    local t = arg ~= nil and getText(key, arg) or getText(key)
    if not t or t == key then return fallback end
    return t
end
G.text = text

function G.setItemName(item, name)
    if not item or not name then return end
    item:setName(name)
    item:setCustomName(true)
end

-- Names ---------------------------------------------------------------

function G.playerDisplayName(player)
    if W.isMultiplayer() then
        local u = player:getUsername()
        if u and u ~= "" then return u end
    end
    local d = player:getDescriptor()
    if d then
        local n = (d:getForename() or "") .. " " .. (d:getSurname() or "")
        n = n:gsub("^%s+", ""):gsub("%s+$", "")
        if n ~= "" then return n end
    end
    return player:getUsername()
end

-- B42 copies a character's modData onto their corpse, so stamping the live
-- player is enough to name the body later.
function G.stampPlayerName(player)
    if not player or player:isDead() then return end
    local name = G.playerDisplayName(player)
    local md = player:getModData()
    if name and md[G.NameKey] ~= name then md[G.NameKey] = name end
    G.stampSkills(player)
end

-- Skill levels ride along the same way, for a brain eaten later:
-- { [perk name] = level } for every skill above 0.
G.SkillsKey = "WhispSkills"

function G.stampSkills(player)
    if not player or player:isDead() or not Perks or not PerkFactory then return end
    local skills, n = {}, 0
    for i = 0, Perks.getMaxIndex() - 1 do
        local perk = Perks.fromIndex(i)
        local info = perk and PerkFactory.getPerk(perk)
        if info and info:getParent() ~= Perks.None then
            local level = player:getPerkLevel(perk)
            if level and level > 0 then
                skills[tostring(info:getType())] = level
                n = n + 1
            end
        end
    end
    player:getModData()[G.SkillsKey] = n > 0 and skills or nil
end

-- A copy of the skills table on one modData, for another.
function G.copySkills(from)
    local src = from and from[G.SkillsKey]
    if type(src) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(src) do out[k] = v end
    return out
end

-- Player name for a corpse, or nil for a zombie.
function G.corpseOwnerName(body)
    local md = body:getModData()
    local name = md[G.NameKey] or md[G.LegacyNameKey]
    if type(name) == "string" and name ~= "" then return name end
    local ok, isPlayer = pcall(function() return body:isPlayer() end)
    if ok and isPlayer then
        local d = body:getDescriptor()
        if d then
            local n = ((d:getForename() or "") .. " " .. (d:getSurname() or "")):gsub("^%s+", ""):gsub("%s+$", "")
            if n ~= "" then return n end
        end
    end
    return nil
end

function G.headName(owner)
    if owner then return text("IGUI_Whisp_PlayerHead", owner, owner .. "'s Head") end
    return text("IGUI_Whisp_ZombieHead", nil, "Zombie Head")
end

function G.faceName(owner)
    if owner then return text("IGUI_Whisp_PlayerFace", owner, owner .. "'s Face") end
    return text("IGUI_Whisp_ZombieFace", nil, "Zombie Face")
end

function G.brainName(owner)
    if owner then return text("IGUI_Whisp_PlayerBrain", owner, owner .. "'s Brain") end
    return text("IGUI_Whisp_ZombieBrain", nil, "Zombie Brain")
end

function G.maskName(owner)
    if owner then return text("IGUI_Whisp_PlayerMask", owner, owner .. "'s Face Mask") end
    return text("IGUI_Whisp_ZombieMask", nil, "Zombie Face Mask")
end

function G.suitName(owner)
    if owner then return text("IGUI_Whisp_PlayerSuit", owner, owner .. "'s Skin Suit") end
    return text("IGUI_Whisp_ZombieSuit", nil, "Zombie Skin Suit")
end

function G.stakeName(owner)
    if owner then return text("IGUI_Whisp_PlayerStake", owner, owner .. "'s Head Stake") end
    return text("IGUI_Whisp_ZombieStake", nil, "Zombie Head Stake")
end

-- Corpses -------------------------------------------------------------

function G.isHumanCorpse(body)
    if not body or not instanceof(body, "IsoDeadBody") then return false end
    local ok, animal = pcall(function() return body:isAnimal() end)
    if ok and animal then return false end
    return body:getSquare() ~= nil
end

function G.isSkinned(body)
    if body:getModData().WhispSkinned then return true end
    local ok, skel = pcall(function() return body:isSkeleton() end)
    return ok and skel == true
end

function G.canButcher(body)
    return G.isHumanCorpse(body) and not G.isSkinned(body) and not body:getModData().WhispGutted
end

function G.canBehead(body)
    return G.isHumanCorpse(body) and not G.isSkinned(body) and not body:getModData().WhispHeadless
end

function G.canSkin(body)
    return G.isHumanCorpse(body) and not G.isSkinned(body)
end

function G.transmitBody(body)
    if isServer() then pcall(function() body:transmitModData() end) end
end

-- Visuals are local to each machine; clients re-apply them from modData.
-- A beheaded corpse wears the neck stump, whose clothing mask hides the head
-- mesh; hair, beard and head gear would otherwise float over the neck. A
-- corpse's model comes from its worn items, and each worn item must also be
-- in its container (saves store worn items by container index), so the
-- stump goes in both. It is a hidden ZedDmg item, so nobody sees it there.
function G.isStump(item)
    return item ~= nil and item:getFullType() == G.Types.Stump
end

-- Hidden items that only exist to change a model: the neck stump on corpses,
-- and the stick and flayed face on head stakes. Nobody may move or wear them.
local VisualOnly = {
    [G.Types.Stump] = true,
    [G.Types.StakeStick] = true,
    [G.Types.StakeFaceless] = true,
}

function G.isVisualOnly(item)
    return item ~= nil and VisualOnly[item:getFullType()] == true
end

local function isHeadGear(item)
    if G.isStump(item) or not G.isHeadLocation(item) then return false end
    local loc = string.lower(tostring(item:getBodyLocation()))
    return not loc:find("underwear", 1, true) and not loc:find("zeddmg", 1, true)
end

local function makeHeadless(body)
    local worn = body:getWornItems()
    if not worn then return false end
    for i = 0, worn:size() - 1 do
        if G.isStump(worn:getItemByIndex(i)) then return false end
    end
    -- Head gear comes off the model but stays in the corpse to loot.
    for i = worn:size() - 1, 0, -1 do
        local item = worn:getItemByIndex(i)
        if isHeadGear(item) then worn:remove(item) end
    end
    local stump = instanceItem(G.Types.Stump)
    body:getContainer():AddItem(stump)
    worn:setItem(stump:getScriptItem():getBodyLocation(), stump)
    local hv = body:getHumanVisual()
    hv:setHairModel("Bald")
    hv:setBeardModel("")
    hv:setBlood(BloodBodyPartType.Neck, 1)
    hv:setBlood(BloodBodyPartType.Torso_Upper, 1)
    return true
end

-- A stump only belongs on a corpse, a stick or flayed face on a stake. One
-- that reaches a player (a mod, a debug spawn, a missed transfer) is taken
-- off and destroyed.
function G.removeStumps(player)
    for fullType in pairs(VisualOnly) do
        local found = player:getInventory():getAllTypeRecurse(fullType)
        for i = found:size() - 1, 0, -1 do
            G.removeItem(player, found:get(i))
        end
    end
end

function G.applyCorpseVisuals(body)
    if not body:getModData().WhispHeadless then return end
    local ok, changed = pcall(makeHeadless, body)
    if ok and changed then
        pcall(function() body:invalidateCorpse() end)
    end
end

-- Server/SP: take a flayed corpse off the ground. Anything it was carrying
-- or wearing is left on the square.
function G.removeCorpse(body)
    local sq = body:getSquare()
    if not sq then return end
    pcall(function()
        local items = body:getContainer():getItems()
        for i = items:size() - 1, 0, -1 do
            local item = items:get(i)
            if not G.isStump(item) then
                sq:AddWorldInventoryItem(item, ZombRandFloat(0.2, 0.8), ZombRandFloat(0.2, 0.8), 0)
            end
        end
    end)
    sq:removeCorpse(body, false)
end

-- Weapons -------------------------------------------------------------

-- "rare" | "long" | "axe" | "short" | nil
function G.bladeClass(item)
    if not item or not instanceof(item, "HandWeapon") or item:isBroken() then return nil end
    local script = item:getScriptItem()
    if not script then return nil end
    if G.RareLongBlades[item:getFullType()] then return "rare" end
    if script:containsWeaponCategory(WeaponCategory.LONG_BLADE) then return "long" end
    if script:containsWeaponCategory(WeaponCategory.AXE) then return "axe" end
    if script:containsWeaponCategory(WeaponCategory.SMALL_BLADE) then return "short" end
    return nil
end

G.ClassRank = { rare = 1, long = 2, axe = 3, short = 4 }

-- One weapon per type that can take a head, fastest class first.
function G.headTools(player)
    local found, seen = {}, {}
    local items = player:getInventory():getAllEvalRecurse(function(it) return G.bladeClass(it) ~= nil end)
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        local t = it:getFullType()
        if not seen[t] then
            seen[t] = true
            found[#found + 1] = it
        end
    end
    table.sort(found, function(a, b) return G.ClassRank[G.bladeClass(a)] < G.ClassRank[G.bladeClass(b)] end)
    return found
end

function G.shortBlades(player)
    local list, seen = {}, {}
    local items = player:getInventory():getAllEvalRecurse(function(it) return G.bladeClass(it) == "short" end)
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if not seen[it:getFullType()] then
            seen[it:getFullType()] = true
            list[#list + 1] = it
        end
    end
    return list
end

function G.butcherKnife(player)
    return player:getInventory():getFirstTagEvalRecurse(ItemTag.BUTCHER_ANIMAL, function(it) return not it:isBroken() end)
end

-- 0..1; weapons without sharpness count as sharp.
function G.sharpness(item)
    local ok, has = pcall(function() return item:hasSharpness() end)
    if not ok or not has then return 1 end
    local ok2, s = pcall(function() return item:getSharpness() end)
    if not ok2 or not s then return 1 end
    if s > 1 then s = s / 100 end
    return W.clamp(s, 0, 1)
end

-- Blows (or stabs) needed to take a head.
function G.headBlows(player, weapon)
    local cls = G.bladeClass(weapon)
    if cls == "rare" then return 1 end
    local skill = player:getPerkLevel(Perks.Butchering)
    if cls == "short" then
        return math.max(8, W.Get("HeadStabsShortBlade") - skill)
    end
    local base = cls == "axe" and W.Get("HeadBlowsAxe") or W.Get("HeadBlowsLongBlade")
    return math.max(2, base - math.floor(skill / 3))
end

-- Materials ------------------------------------------------------------

local function usesOf(item)
    local ok, uses = pcall(function() return item:getCurrentUses() end)
    if ok and uses then return uses end
    return 1
end

function G.totalUses(player, fullType)
    local items = player:getInventory():getAllTypeRecurse(fullType)
    local total = 0
    for i = 0, items:size() - 1 do total = total + usesOf(items:get(i)) end
    return total
end

-- First clasp material the player has enough of, for `sets` face masks' worth.
function G.findClasp(player, sets)
    for _, c in ipairs(G.Clasps) do
        local need = c.uses * sets
        if G.totalUses(player, c.type) >= need then
            return c.type, need
        end
    end
    return nil
end

function G.findSewingTool(player)
    local inv = player:getInventory()
    for _, t in ipairs(G.SewingTools) do
        local it = inv:getFirstTypeRecurse(t)
        if it then return it end
    end
    return nil
end

function G.isNail(item)
    return item and item:getFullType() == "Base.Nails"
end

function G.claspNeed(claspType, sets)
    for _, c in ipairs(G.Clasps) do
        if c.type == claspType then return c.uses * sets end
    end
    return nil
end

-- Server/SP only: consume `need` uses of `fullType` across the inventory.
function G.consumeUses(player, fullType, need)
    local items = player:getInventory():getAllTypeRecurse(fullType)
    local left = need
    for i = 0, items:size() - 1 do
        if left <= 0 then break end
        local it = items:get(i)
        while left > 0 and it and usesOf(it) > 0 do
            it:UseAndSync()
            left = left - 1
            if not it:getContainer() then break end
        end
    end
    return left <= 0
end

-- Server/SP: create an item, let `configure` name it and fill its modData,
-- then add it so the client receives it fully set up.
function G.addToInventory(player, fullType, configure)
    local item = instanceItem(fullType)
    if not item then return nil end
    if configure then configure(item) end
    local inv = player:getInventory()
    inv:AddItem(item)
    if isServer() then sendAddItemToContainer(inv, item) end
    return item
end

function G.removeItem(player, item)
    local c = item:getContainer()
    if not c then return end
    if player:isEquipped(item) then player:removeWornItem(item) end
    c:Remove(item)
    if isServer() then sendRemoveItemFromContainer(c, item) end
end

-- Guts -----------------------------------------------------------------

function G.gutsBorn(item)
    local md = item:getModData()
    if not md.WhispBorn then md.WhispBorn = G.hours() end
    return md.WhispBorn
end

function G.carriedGutsKg(player)
    local items = player:getInventory():getAllTypeRecurse(G.Types.Guts)
    local total = 0
    for i = 0, items:size() - 1 do total = total + items:get(i):getActualWeight() end
    return total
end

-- Carrying more than GutsCarryThresholdKg of guts holds discomfort up.
function G.holdGutsDiscomfort(player, kg)
    kg = kg or G.carriedGutsKg(player)
    local over = kg > W.Get("GutsCarryThresholdKg")
    W.setHold(player, "guts", over and W.Get("GutsCarryDiscomfort") or nil)
end

-- Fraction of a fresh gut's capacity left: halves every GutsHalfLifeHours.
function G.gutsCapacity(item)
    local age = math.max(0, G.hours() - G.gutsBorn(item))
    local half = math.max(1, W.Get("GutsHalfLifeHours"))
    return 0.5 ^ (age / half)
end

function G.refreshGuts(item)
    local cap = G.gutsCapacity(item)
    item:setActualWeight(W.Get("GutsWeight") * cap)
    item:setCustomWeight(true)
    local pct = math.floor(cap * 100 + 0.5)
    if item:getModData().WhispPct ~= pct then
        item:getModData().WhispPct = pct
        G.setItemName(item, text("IGUI_Whisp_GutsName", pct, "Guts (" .. pct .. "%)"))
    end
    return cap
end

-- Worn gear ------------------------------------------------------------

function G.isGear(item)
    if not item then return false end
    local t = item:getFullType()
    return t == G.Types.Mask or t == G.Types.Suit
end

function G.isWorking(item)
    return item and item:getCondition() > 0
end

function G.multiplierFor(item)
    if not G.isWorking(item) then return 1 end
    if item:getFullType() == G.Types.Mask then return W.Get("MaskStealthMultiplier") end
    if item:getFullType() == G.Types.Suit then return W.Get("SuitStealthMultiplier") end
    return 1
end

-- 0-1 share of the full disguise this worn piece gives.
function G.coverFor(item)
    if not G.isWorking(item) then return 0 end
    if item:getFullType() == G.Types.Mask then return W.Get("MaskCover") / 100 end
    if item:getFullType() == G.Types.Suit then return W.Get("SuitCover") / 100 end
    return 0
end

-- Damage as a percent of max condition. Returns true if it just broke.
function G.damageGear(player, item, pct)
    if not item or pct <= 0 then return false end
    local md = item:getModData()
    local max = item:getConditionMax()
    local exact = (md.WhispCond or item:getCondition()) - max * pct / 100
    exact = math.max(0, exact)
    md.WhispCond = exact
    local before = item:getCondition()
    local after = math.max(0, math.ceil(exact - 0.0001))
    if after ~= before then
        item:setCondition(after)
        if isServer() then syncItemFields(player, item) end
    end
    return before > 0 and after <= 0
end

-- Drying -----------------------------------------------------------------
-- Dead skin dries out like guts rot: condition halves every
-- GearDryHalfLifeHours and the piece crumbles below GEAR_CRUMBLE. Brain tan
-- stops it for GearTreatHours. Worked out from timestamps, so gear left in
-- a container catches up the next time someone carries it.
local GEAR_CRUMBLE = 0.05

function G.isTreated(item, now)
    local untilH = item:getModData().WhispTreatedUntil
    return untilH ~= nil and (now or G.hours()) < untilH
end

function G.gearBaseName(item)
    local owner = item:getModData().WhispOwner
    if item:getFullType() == G.Types.Suit then return G.suitName(owner) end
    return G.maskName(owner)
end

function G.refreshGearName(item)
    local name = G.gearBaseName(item)
    if G.isTreated(item) then name = name .. " " .. text("IGUI_Whisp_TreatedSuffix", nil, "(Treated)") end
    if item:getName() ~= name then
        G.setItemName(item, name)
        return true
    end
    return false
end

-- Untreated hours between the last check and now. Returns true if it just crumbled.
function G.dryGear(player, item)
    if not G.isGear(item) then return false end
    local md = item:getModData()
    local now = G.hours()
    local last = md.WhispDried or now
    md.WhispDried = now
    local renamed = G.refreshGearName(item)
    local elapsed = now - last
    if elapsed <= 0 or not G.isWorking(item) then
        if renamed and isServer() then syncItemFields(player, item) end
        return false
    end
    local covered = math.max(0, math.min(now, md.WhispTreatedUntil or 0) - last)
    local dry = elapsed - covered
    if dry <= 0 then
        if renamed and isServer() then syncItemFields(player, item) end
        return false
    end
    local max = item:getConditionMax()
    local exact = md.WhispCond or item:getCondition()
    local left = exact * 0.5 ^ (dry / math.max(1, W.Get("GearDryHalfLifeHours")))
    local pct = left < max * GEAR_CRUMBLE and 100 or (exact - left) / max * 100
    local broke = G.damageGear(player, item, pct)
    if renamed and not broke and isServer() then syncItemFields(player, item) end
    return broke
end

-- Brain tan keeps skin supple for GearTreatHours from now.
function G.treatGear(player, item)
    G.dryGear(player, item)
    item:getModData().WhispTreatedUntil = G.hours() + W.Get("GearTreatHours")
    G.refreshGearName(item)
    if isServer() then syncItemFields(player, item) end
end

function G.announce(player, key, good)
    if isServer() then
        sendServerCommand(player, W.Module, "Halo", { key = key, good = good == true })
    elseif HaloTextHelper then
        if good then HaloTextHelper.addGoodText(player, getText(key))
        else HaloTextHelper.addBadText(player, getText(key)) end
    end
end

function G.onBroken(player, item, dried)
    local suit = item:getFullType() == G.Types.Suit
    local key
    if dried then
        key = suit and "IGUI_Whisp_SuitDried" or "IGUI_Whisp_MaskDried"
    else
        key = suit and "IGUI_Whisp_SuitBroke" or "IGUI_Whisp_MaskBroke"
    end
    G.announce(player, key, false)
end

-- Taking gear on or off costs WearToggleDamage percent.
function G.onWearToggle(player, item, wearing)
    if not G.authoritative() or not G.isGear(item) then return end
    local md = item:getModData()
    if (md.WhispWorn == true) == wearing then return end
    md.WhispWorn = wearing
    if G.damageGear(player, item, W.Get("WearToggleDamage")) then G.onBroken(player, item) end
end

-- Locations a skin suit leaves alone.
local HEAD_WORDS = { "hat", "mask", "eye", "ear", "nose", "makeup", "make_up", "head", "neck" }

local FEET_WORDS = { "shoe", "sock" }

local function locationMatches(item, words)
    local ok, loc = pcall(function() return tostring(item:getBodyLocation()) end)
    if not ok or not loc then return false end
    loc = string.lower(loc)
    for _, w in ipairs(words) do
        if loc:find(w, 1, true) then return true end
    end
    return false
end

function G.isHeadLocation(item)
    return locationMatches(item, HEAD_WORDS)
end

function G.isFeetLocation(item)
    return locationMatches(item, FEET_WORDS)
end

-- Allowed alongside a skin suit: head gear, shoes and socks, bags and the
-- suit itself.
function G.allowedWithSuit(item)
    if not item then return true end
    if item:getFullType() == G.Types.Suit then return true end
    if instanceof(item, "InventoryContainer") then return true end
    return G.isHeadLocation(item) or G.isFeetLocation(item)
end

function G.wornMask(player)
    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and it:getFullType() == G.Types.Mask then return it end
    end
    return nil
end

function G.wornSuit(player)
    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and it:getFullType() == G.Types.Suit then return it end
    end
    return nil
end

-- True while the player should move like a zombie: an intact face mask and
-- skin suit both worn, on foot and alive. Either piece alone, or a broken
-- one, leaves them moving as a human.
function G.wantsZombieGait(player)
    if not player or player:isDead() or player:getVehicle() then return false end
    if not W.Get("Enabled") or not W.Get("ZombieMannerisms") then return false end
    local mask, suit = G.wornMask(player), G.wornSuit(player)
    return G.isWorking(mask) == true and G.isWorking(suit) == true
end

-- Server/SP: strip everything the suit replaces into the main inventory.
function G.stripForSuit(player)
    local worn = player:getWornItems()
    local strip = {}
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and not G.allowedWithSuit(it) then strip[#strip + 1] = it end
    end
    for _, it in ipairs(strip) do
        player:removeWornItem(it)
        if G.isGear(it) then G.onWearToggle(player, it, false) end
    end
    if #strip > 0 then
        if isServer() then sendEquip(player) end
        triggerEvent("OnClothingUpdated", player)
    end
end

-- Percent of the body still smeared with blood (skin or ordinary clothing,
-- not the dead-skin gear itself). Smeared guts can't outlast the blood.
function G.smearedPct(player)
    local count = BloodBodyPartType.MAX:index()
    local perPart = {}
    local hv = player:getHumanVisual()
    for i = 0, count - 1 do perPart[i] = hv:getBlood(BloodBodyPartType.FromIndex(i)) or 0 end
    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and instanceof(it, "Clothing") and not G.isGear(it) then
            local covered = BloodClothingType.getCoveredParts(it:getBloodClothingType())
            if covered then
                for j = 0, covered:size() - 1 do
                    local part = covered:get(j)
                    local b = it:getBlood(part) or 0
                    if b > (perPart[part:index()] or 0) then perPart[part:index()] = b end
                end
            end
        end
    end
    local sum = 0
    for i = 0, count - 1 do sum = sum + (perPart[i] or 0) end
    return count > 0 and sum / count * 100 or 0
end

-- Adds blood to every body part and every worn garment's covered parts.
function G.addBloodEverywhere(player, amount)
    if amount <= 0 then return end
    local hv = player:getHumanVisual()
    local count = BloodBodyPartType.MAX:index()
    for i = 0, count - 1 do
        local part = BloodBodyPartType.FromIndex(i)
        hv:setBlood(part, math.min(1, hv:getBlood(part) + amount))
    end
    local worn = player:getWornItems()
    for i = 0, worn:size() - 1 do
        local it = worn:get(i):getItem()
        if it and instanceof(it, "Clothing") then
            local covered = BloodClothingType.getCoveredParts(it:getBloodClothingType())
            if covered then
                for j = 0, covered:size() - 1 do
                    local part = covered:get(j)
                    it:setBlood(part, math.min(1, it:getBlood(part) + amount))
                end
            end
            if isServer() then syncItemFields(player, it) end
        end
    end
    if isServer() then
        sendHumanVisual(player)
        syncVisuals(player)
    end
    pcall(function() player:resetModelNextFrame() end)
end
