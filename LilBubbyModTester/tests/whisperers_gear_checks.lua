#!/usr/bin/env lua
-- tests/whisperers_gear_checks.lua
--
-- The Whisperers' corpse work and gear, run against the mod's real timed
-- actions, recipe callbacks and per-minute tick with stand-in players, corpses,
-- items and inventories: butchering yield and timing, blow counts per blade,
-- face damage, nail vs needle masks, wear/unwear damage, repair, skin suits
-- (materials, corpse removal, clothing strip, hit tearing), smearing, guts rot and
-- corpse sickness. Run from this project directory:
--   lua tests/whisperers_gear_checks.lua
-- Exits 0 if every assertion passes.
-- Loads The Whisperers' real code: its Steam Workshop subscription when one
-- exists (steamapps/workshop/content/108600/<id>/mods/TheWhisperers), otherwise
-- the local Workshop project ~/Zomboid/Workshop/TheWhisperers.
local HOME = os.getenv("HOME") or ""
local function exists(path) local f = io.open(path, "r"); if f then f:close() return true end return false end
local function whisperersLua()
    local workshop = HOME .. "/Library/Application Support/Steam/steamapps/workshop/content/108600/"
    local p = io.popen('ls "' .. workshop .. '" 2>/dev/null')
    for id in (p and p:read("*a") or ""):gmatch("[^\n]+") do
        local root = workshop .. id .. "/mods/TheWhisperers/42/media/lua/"
        if exists(root .. "shared/Whisperers_Shared.lua") then p:close() return root end
    end
    if p then p:close() end
    local root = HOME .. "/Zomboid/Workshop/TheWhisperers/Contents/mods/TheWhisperers/42/media/lua/"
    assert(exists(root .. "shared/Whisperers_Shared.lua"), "The Whisperers is neither subscribed nor in ~/Zomboid/Workshop")
    return root
end
local L = whisperersLua():gsub("/$", "")
package.path = L.."/shared/?.lua;"..L.."/client/?.lua;"..package.path
-- ===== engine stubs (SP) =====
local hours = 100
function isClient() return false end
function isServer() return false end
function getText(k, a) return k end
function getTimestampMs() return 0 end
function getGameTime() return { getWorldAgeHours = function() return hours end, getMultiplier = function() return 1 end } end
ZomboidGlobals = { FoodSicknessDecrease = 0.0015 }
function ZombRandFloat(a, b) return (a + b) / 2 end
local nextRand = 0
function ZombRand(n) return nextRand end
local halos = {}
HaloTextHelper = { addGoodText = function(_, t) halos[#halos+1] = t end, addBadText = function(_, t) halos[#halos+1] = t end }
function addXp(p, perk, n) p.xp[perk] = (p.xp[perk] or 0) + n end
SandboxVars = {}
Perks = { Butchering = "Butchering", Tailoring = "Tailoring" }
WeaponCategory = { LONG_BLADE = "long", AXE = "axe", SMALL_BLADE = "small" }
ItemTag = { BUTCHER_ANIMAL = "butcher" }
local handlers = {}
Events = setmetatable({}, {__index=function(t,k) local e={Add=function(f) handlers[k]=handlers[k] or {}; table.insert(handlers[k], f) end}; rawset(t,k,e); return e end})
local function fire(k, ...) for _,f in ipairs(handlers[k] or {}) do f(...) end end
function triggerEvent(k, ...) fire(k, ...) end
local function List(t) t = t or {}; return { size=function() return #t end, get=function(_, i) return t[i+1] end, add=function(_, v) t[#t+1]=v end, remove=function(_, i) return table.remove(t, i+1) end, raw=t } end
local PARTS = 4
BloodBodyPartType = { MAX = { index = function() return PARTS end }, Head = 0, Neck = 1,
  FromIndex = function(i) return { index = function() return i end, _i = i } end }
local covered = List({ BloodBodyPartType.FromIndex(0), BloodBodyPartType.FromIndex(1), BloodBodyPartType.FromIndex(2), BloodBodyPartType.FromIndex(3) })
BloodClothingType = { getCoveredParts = function() return covered end }
local function stat(n) return { n = n, getMaximumValue = function() return 100 end } end
CharacterStat = { UNHAPPINESS=stat"U", STRESS=stat"S", DISCOMFORT=stat"D", SICKNESS=stat"K", ENDURANCE=stat"E", FOOD_SICKNESS=stat"F", POISON=stat"P" }
function instanceof(o, c) return type(o) == "table" and o._cls ~= nil and (o._cls == c or (o._isa and o._isa[c])) end
-- timed action base
ISBaseTimedAction = {}
function ISBaseTimedAction:derive(n) local c = setmetatable({}, { __index = self }); c.Type = n; return c end
function ISBaseTimedAction.new(cls, ch) local o = setmetatable({}, { __index = cls }); o.character = ch; return o end
function ISBaseTimedAction:stop() end
function ISBaseTimedAction:perform() end
function ISBaseTimedAction:forceComplete() self.forced = true; self:complete() end
package.loaded["TimedActions/ISBaseTimedAction"] = true
ISWearClothing = { isValid = function() return true end, complete = function() return true end }
ISUnequipAction = { complete = function() return true end }
package.loaded["TimedActions/ISWearClothing"] = true
package.loaded["TimedActions/ISUnequipAction"] = true
-- items
local nextId = 0
local ITEMDEF = {
  ["Whisperers.Guts"] = { weight = 2.5 }, ["Whisperers.CorpseHead"] = {}, ["Whisperers.CorpseFace"] = {},
  ["Whisperers.FaceMask"] = { cond = 100, clothing = true, loc = "base:maskeyes" },
  ["Whisperers.SkinSuit"] = { cond = 100, clothing = true, loc = "base:fullsuit" },
  ["Whisperers.HeadStake"] = {}, ["Whisperers.CorpseHeadFaceless"] = {}, ["Base.LongStick"] = {}, ["Whisperers.CorpseBrain"] = {},
  ["Whisperers.NeckStump"] = { clothing = true, loc = "base:zeddmg" },
  ["Whisperers.StakeStick"] = { clothing = true, loc = "base:zeddmg" },
  ["Whisperers.StakeFaceless"] = { clothing = true, loc = "base:zeddmg" },
}
function instanceItem(t)
  nextId = nextId + 1
  local def = ITEMDEF[t] or {}
  local it = { _cls = def.clothing and "Clothing" or "InventoryItem", _t = t, md = {}, name = t, cond = def.cond or 10, condMax = def.cond or 10, weight = def.weight or 1, blood = {}, uses = def.uses, loc = def.loc }
  function it:getFullType() return self._t end
  function it:getModData() return self.md end
  function it:setName(n) self.name = n end
  function it:getName() return self.name end
  function it:setCustomName() end
  function it:getCondition() return self.cond end
  function it:setCondition(c) self.cond = c end
  function it:getConditionMax() return self.condMax end
  function it:setActualWeight(w) self.weight = w end
  function it:getActualWeight() return self.weight end
  function it:setCustomWeight() end
  function it:getContainer() return self.container end
  function it:isBroken() return false end
  function it:getBloodClothingType() return "x" end
  function it:getBlood(p) return self.blood[p._i] or 0 end
  function it:setBlood(p, v) self.blood[p._i] = v end
  function it:getBodyLocation() return self.loc end
  function it:getCurrentUses() return self.uses or 1 end
  function it:UseAndSync() self.uses = self.uses - 1; if self.uses <= 0 then self.container:Remove(self) end end
  function it:getDisplayName() return self.name end
  function it:getScriptItem() local item = self; return { getBodyLocation = function() return item.loc end } end
  function it:getByteData() return self.byteData end
  function it:getVisual() local item = self; return { setTextureChoice = function(_, i) item.textureChoice = i end,
    getTextureChoice = function() return item.textureChoice end } end
  function it:setWorldSprite(s) self.worldSprite = s end
  return it
end
local function Inventory()
  local inv = { items = {} }
  function inv:AddItem(it) if type(it) == "string" then it = instanceItem(it) end; it.container = self; table.insert(self.items, it); return it end
  function inv:Remove(it) for i, v in ipairs(self.items) do if v == it then table.remove(self.items, i); it.container = nil; return end end end
  function inv:containsRecursive(it) for _, v in ipairs(self.items) do if v == it then return true end end return false end
  function inv:getAllTypeRecurse(t) local r = {}; for _, v in ipairs(self.items) do if v._t == t then r[#r+1] = v end end; return List(r) end
  function inv:getAllEvalRecurse(f) local r = {}; for _, v in ipairs(self.items) do if f(v) then r[#r+1] = v end end; return List(r) end
  function inv:getFirstTypeRecurse(t) for _, v in ipairs(self.items) do if v._t == t then return v end end end
  function inv:getFirstTagEvalRecurse(tag, f) for _, v in ipairs(self.items) do if v.tags and v.tags[tag] and f(v) then return v end end end
  function inv:getItems() return List(self.items) end
  return inv
end
local function weapon(t, cat, twoHand)
  local w = instanceItem(t); w._cls = "HandWeapon"; w.tags = { butcher = (cat == "small") }
  function w:getScriptItem() return { containsWeaponCategory = function(_, c) return c == cat end } end
  function w:isTwoHandWeapon() return twoHand end
  function w:getBloodLevel() return 0 end
  function w:hasSharpness() return true end
  function w:getSharpness() return self.sharp or 1 end
  return w
end
local function drain(t, uses) local d = instanceItem(t); d.uses = uses; return d end
-- player
local stats = { v = {}, get = function(s, st) return s.v[st] or 0 end, set = function(s, st, v) s.v[st] = v end, remove = function(s, st, v) s.v[st] = (s.v[st] or 0) - v end,
  isAtMinimum = function(s, st) return (s.v[st] or 0) <= 0 end }
local hv = { b = {} }
function hv:getBlood(p) return self.b[p._i or p] or 0 end
function hv:setBlood(p, v) self.b[type(p) == "table" and p._i or p] = v end
local P = { _cls = "IsoPlayer", md = {}, xp = {}, worn = {}, perks = { Butchering = 3, Tailoring = 5 } }
P.inv = Inventory()
function P:getInventory() return self.inv end
function P:getPerkLevel(p) return self.perks[p] end
function P:getModData() return self.md end
function P:getHumanVisual() return hv end
function P:getWornItems() local r = {}; for _, it in ipairs(self.worn) do r[#r+1] = { getItem = function() return it end } end; return List(r) end
function P:getPrimaryHandItem() return self.primary end
function P:getStats() return stats end
function P:isDead() return false end
function P:isEquipped(it) for _, w in ipairs(self.worn) do if w == it then return true end end return false end
function P:removeWornItem(it) for i, w in ipairs(self.worn) do if w == it then table.remove(self.worn, i) end end end
function P:isTimedActionInstant() return false end
function P:getDescriptor() return { getForename = function() return "Mira" end, getSurname = function() return "Lane" end } end
function P:getUsername() return "mira" end
function P:getPlayerNum() return 0 end
function P:isEnduranceSufficientForAction() return true end
function P:hasTrait() return false end
function P:playSound() end
function P:getBodyDamage() return { getCorpseSicknessDefense = function() return 0 end } end
function P:getOnlineID() return 0 end
function getNumActivePlayers() return 1 end
function getSpecificPlayer() return P end
-- Corpses live on stand-in squares; skinning takes the body off its square
-- and leaves its belongings on the ground.
local function Square()
  local sq = { bodies = {}, floor = {} }
  function sq:getX() return 10 end
  function sq:getY() return 20 end
  function sq:getZ() return 0 end
  function sq:getDeadBodys() return List(self.bodies) end
  function sq:removeCorpse(b) for i, v in ipairs(self.bodies) do if v == b then table.remove(self.bodies, i) end end end
  function sq:AddWorldInventoryItem(it) table.insert(self.floor, it); return it end
  return sq
end
-- A corpse's worn items, as B42's WornItems: the model is built from these,
-- and each must also be in the corpse's container.
local function WornItems(items)
  local w = { items = items }
  function w:size() return #self.items end
  function w:getItemByIndex(i) return self.items[i + 1] end
  function w:remove(it) for i, v in ipairs(self.items) do if v == it then table.remove(self.items, i) return end end end
  function w:setItem(loc, it) it.wornAt = loc; table.insert(self.items, it) end
  return w
end
local function wornType(b, fullType)
  local n = 0
  for _, it in ipairs(b.worn.items) do if it._t == fullType then n = n + 1 end end
  return n
end
local function corpse(owner)
  local sq = Square()
  local b = { _cls = "IsoDeadBody", md = { WhispName = owner }, skel = false, sq = sq,
    hv = { visuals = List(), b = {}, hair = "Messy", beard = "Full", skin = "MaleBody03" }, inv = Inventory() }
  local clothes = {}
  for t, loc in pairs({ ["Base.Hat_Baseball"] = "base:hat", ["Base.Briefs"] = "base:underwearbottom", ["Base.Tshirt"] = "base:tshirt" }) do
    local it = b.inv:AddItem(t); it.loc = loc; clothes[#clothes + 1] = it
  end
  b.worn = WornItems(clothes)
  table.insert(sq.bodies, b)
  function b:getModData() return self.md end
  function b:isAnimal() return false end
  function b:getSquare() return self.sq end
  function b:getX() return 10.5 end
  function b:getY() return 20.5 end
  function b:getDir() return 0 end
  function b:isSkeleton() return self.skel end
  function b:setSkeleton(v) self.skel = v end
  function b:isPlayer() return false end
  function b:getWornItems() return self.worn end
  function b:getItemVisuals(out) assert(out, "IsoDeadBody:getItemVisuals needs a list to fill") end
  function b:getContainer() return self.inv end
  function b:isFemale() return false end
  function b:getHumanVisual() local h = self.hv
    local brown = { getRedFloat = function() return 0.3 end, getGreenFloat = function() return 0.2 end, getBlueFloat = function() return 0.1 end }
    return { getBodyVisuals = function() return h.visuals end,
      setHairModel = function(_, m) h.hair = m end, setBeardModel = function(_, m) h.beard = m end,
      getHairModel = function() return h.hair end, getBeardModel = function() return h.beard end,
      getSkinTexture = function() return h.skin end,
      getHairColor = function() return brown end, getBeardColor = function() return brown end,
      setBlood = function() end } end
  function b:invalidateCorpse() end
  function b:invalidateBodyTexture() end
  return b
end
-- Head stakes are mannequins (Whisperers_Stake.lua). A stand-in mannequin
-- records its script, look and worn items and saves them into the item, as
-- IsoMannequin:setCustomSettingsToItem does. Scripts come from the mod's own
-- Whisperers_Mannequins.txt, so the Lua skin list is checked against it.
local MANNEQUINS, mannequinCount = {}, 0
do
  local f = io.open(L .. "/../scripts/Whisperers_Mannequins.txt", "r")
  if f then
    for line in f:lines() do
      local name = line:match("^%s*mannequin%s+([%w_]+)%s*$")
      if name then MANNEQUINS[name] = true; mannequinCount = mannequinCount + 1 end
    end
    f:close()
  end
end
function getScriptManager() return { getMannequinScript = function(_, n) return MANNEQUINS[n] end } end
function getSprite(n) return n == "whisperers_headstake_01_0" and { name = n } or nil end
function getCell() return {} end
ImmutableColor = { new = function(r, g, b) return { r = r, g = g, b = b } end }
local function Styles(list)
  local out = {}
  for _, n in ipairs(list) do out[#out + 1] = { getName = function() return n end, isNoChoose = function() return false end } end
  return List(out)
end
function getHairStylesInstance() return { getAllMaleStyles = function() return Styles({ "Messy", "Short" }) end,
  getAllFemaleStyles = function() return Styles({ "Long", "Bob" }) end } end
-- Beard styles have no isNoChoose, unlike hair styles.
function getBeardStylesInstance() return { getAllStyles = function()
  return List({ { getName = function() return "Full" end } })
end } end
IsoMannequin = { new = function()
  local m = { _cls = "IsoMannequin", inv = Inventory(), worn = WornItems({}), md = {}, hv = { blood = {}, dirt = {} } }
  function m:setMannequinScriptName(n) self.script = n end
  function m:getMannequinScriptName() return self.script end
  function m:getContainer() return self.inv end
  function m:getWornItems() return self.worn end
  function m:getModData() return self.md end
  function m:getHumanVisual() local h = self.hv
    return { setHairModel = function(_, v) h.hair = v end, setBeardModel = function(_, v) h.beard = v end,
      setHairColor = function(_, c) h.hairColor = c end, setNaturalHairColor = function() end,
      setBeardColor = function(_, c) h.beardColor = c end, setNaturalBeardColor = function() end,
      setBlood = function(_, p, v) h.blood[p] = v end, setDirt = function(_, p, v) h.dirt[p] = v end } end
  function m:setCustomSettingsToItem(it)
    local types = {}
    for _, w in ipairs(self.worn.items) do types[#types + 1] = w._t end
    it.byteData = { script = self.script, hv = self.hv, worn = types, inContainer = #self.inv.items }
  end
  return m
end }
-- The vanilla moveables code the stake wraps: picking up makes the item
-- through instanceItem; placing takes the item and the sprite to place.
ISMoveableSpriteProps = {
  instanceItem = function(self) return instanceItem(self.customItem) end,
  pickUpMoveableInternal = function(self) return self:instanceItem() end,
  placeMoveableInternal = function(self, sq, item, spriteName) self.placed = { item = item, sprite = spriteName } return true end,
}
package.loaded["Moveables/ISMoveableSpriteProps"] = true
-- ===== load mod =====
require "Whisperers_Shared"; require "Whisperers_Gear"; require "Whisperers_Recipes"; require "Whisperers_GearTick"
dofile(L .. "/shared/TimedActions/Whisp_ButcherCorpseAction.lua")
dofile(L .. "/shared/TimedActions/Whisp_RemoveHeadAction.lua")
dofile(L .. "/shared/TimedActions/Whisp_CutFaceAction.lua")
dofile(L .. "/shared/TimedActions/Whisp_SmearGutsAction.lua")
dofile(L .. "/shared/TimedActions/Whisp_SkinCorpseAction.lua")
dofile(L .. "/shared/TimedActions/Whisp_RepairMaskAction.lua")
local W, G = Whisperers, Whisperers.Gear
local function names(t) local r = {}; for _, it in ipairs(P.inv.items) do if it._t == t then r[#r+1] = it.name end end; return table.concat(r, ", ") end
local function check(label, cond) if not cond then print("FAIL " .. label); FAILED = true end end

local knife = weapon("Base.HuntingKnife", "small", false); knife.sharp = 1
local katana = weapon("Base.Katana", "long", true)
local machete = weapon("Base.Machete", "long", false)
local axe = weapon("Base.Axe", "axe", true)
P.inv:AddItem(knife); P.inv:AddItem(katana); P.inv:AddItem(machete); P.inv:AddItem(axe)

-- Butcher
local zb = corpse(nil)
local a = Whisp_ButcherCorpseAction:new(P, zb, knife)
check("butcher duration 900-3*20=840", a.maxTime == 840)
check("butcher valid", a:isValid())
a:complete()
local guts = P.inv:getAllTypeRecurse(G.Types.Guts)
check("guts yield 2+3*0.5(+0.5 rand) floor = 4 -> got " .. guts:size(), guts:size() == 4)
check("corpse gutted, can't rebutcher", not G.canButcher(zb))

-- Head blows
check("katana 1 blow", G.headBlows(P, katana) == 1)
check("machete 6-1=5 blows", G.headBlows(P, machete) == 5)
check("axe 5-1=4 blows", G.headBlows(P, axe) == 4)
check("knife 24-3=21 stabs", G.headBlows(P, knife) == 21)
local tools = G.headTools(P)
check("head tools sorted rare first", G.bladeClass(tools[1]) == "rare" and G.bladeClass(tools[#tools]) == "short")

-- Remove head with a knife: blows via animEvent
P.primary = knife
local pb = corpse("Rick Grimes")
local rh = Whisp_RemoveHeadAction:new(P, pb, knife)
check("remove head valid", rh:isValid())
local e0 = stats:get(CharacterStat.ENDURANCE)
for i = 1, 21 do rh:animEvent("WhispBlow") end
check("forced complete after 21 stabs", rh.forced == true)
check("endurance drained 21*0.02", math.abs((e0 - stats:get(CharacterStat.ENDURANCE)) - 0.42) < 1e-6)
check("player head named", names(G.Types.Head) == "Rick Grimes's Head")
local look = P.inv:getFirstTypeRecurse(G.Types.Head).md.WhispLook
check("player head keeps its owner's face (read before shaving)", look and look.skin == "MaleBody03"
  and look.hair == "Messy" and look.beard == "Full" and look.female == false and look.human == true)
local function stumps(b) return wornType(b, G.Types.Stump) end
local function inCorpse(b, t) return b.inv:getFirstTypeRecurse(t) ~= nil end
check("beheaded corpse wears the neck stump", stumps(pb) == 1)
check("stump is in the corpse's container too (saves need it)", inCorpse(pb, G.Types.Stump))
check("stump worn at the multi-item zeddmg slot", pb.inv:getFirstTypeRecurse(G.Types.Stump).wornAt == "base:zeddmg")
check("head gear taken off the corpse model", wornType(pb, "Base.Hat_Baseball") == 0)
check("head gear still in the corpse to loot", inCorpse(pb, "Base.Hat_Baseball"))
check("body clothing and underwear stay on", wornType(pb, "Base.Tshirt") == 1 and wornType(pb, "Base.Briefs") == 1)
check("hair and beard gone", pb.hv.hair == "Bald" and pb.hv.beard == "")
G.applyCorpseVisuals(pb)
check("stump not duplicated", stumps(pb) == 1)
check("headless corpse can still be butchered", G.canButcher(pb))
check("headless corpse can still be skinned", G.canSkin(pb))
check("can't behead twice", not G.canBehead(pb))

-- The stump can't leave the corpse: transfers refuse it, wearing refuses it,
-- and one that reaches a player anyway is destroyed.
ISInventoryTransferAction = { isValid = function() return true end, transferItem = function(self, it) self.moved = it end }
package.loaded["TimedActions/ISInventoryTransferAction"] = true
dofile(L .. "/client/Whisperers_Stump.lua")
local stumpItem = pb.inv:getFirstTypeRecurse(G.Types.Stump)
local shirt0 = pb.inv:getFirstTypeRecurse("Base.Tshirt")
check("taking the stump is refused", not ISInventoryTransferAction.isValid({ item = stumpItem }))
check("other corpse items still transfer", ISInventoryTransferAction.isValid({ item = shirt0 }))
local queued = {}
ISInventoryTransferAction.transferItem(queued, stumpItem)
check("a queued stump is skipped", queued.moved == nil)
ISInventoryTransferAction.transferItem(queued, shirt0)
check("queued clothing still moves", queued.moved == shirt0)
check("wearing the stump is refused", not ISWearClothing.isValid({ item = stumpItem, character = P }))
local stray = P.inv:AddItem(G.Types.Stump); P.worn = { stray }
G.removeStumps(P)
check("a stump on a player is taken off and destroyed", P.inv:getFirstTypeRecurse(G.Types.Stump) == nil and #P.worn == 0)
check("taking a stake's stick is refused", not ISInventoryTransferAction.isValid({ item = instanceItem(G.Types.StakeStick) }))
check("wearing a stake's flayed face is refused", not ISWearClothing.isValid({ item = instanceItem(G.Types.StakeFaceless), character = P }))
P.inv:AddItem(G.Types.StakeStick); P.inv:AddItem(G.Types.StakeFaceless)
G.removeStumps(P)
check("stake visuals on a player are destroyed", P.inv:getFirstTypeRecurse(G.Types.StakeStick) == nil and P.inv:getFirstTypeRecurse(G.Types.StakeFaceless) == nil)

-- A zombie's head keeps the zombie's own face (not a player's: human is unset).
do
  local zc = corpse(nil); zc.hv.skin = "F_ZedBody02_level3"; function zc:isFemale() return true end
  local zh = Whisp_RemoveHeadAction:new(P, zc, knife)
  local before = #P.inv.items
  for _ = 1, G.headBlows(P, knife) do zh:animEvent("WhispBlow") end
  local zhead
  for i = before + 1, #P.inv.items do if P.inv.items[i]._t == G.Types.Head then zhead = P.inv.items[i] end end
  local zl = zhead and zhead.md.WhispLook
  check("a zombie head keeps the zombie's own face", zl and zl.skin == "F_ZedBody02_level3" and zl.female == true
    and zl.human == nil and zl.hair == "Messy")
  check("a zombie head's stake shows that zombie", W.Stake.scriptFor(zl) == "Whisp_Stake_F_ZedBody02_level3")
  check("an unknown zombie skin falls back to a zombie face",
    W.Stake.scriptFor({ female = true, skin = "SomeModZed" }) == "Whisp_Stake_F_ZedBody01")
  P.inv:Remove(zhead)
end

-- Every mask texture choice is a skin, in the code's order (the XML is generated).
do
  local f = io.open(L .. "/../clothing/clothingItems/Whisp_FaceMask.xml", "r")
  if f then
    local xml, choices = f:read("*a"), {}
    f:close()
    for skin in xml:gmatch("<textureChoices>WhispMask\\([%w_]+)</textureChoices>") do choices[#choices + 1] = skin end
    local same = #choices == #W.Stake.MaskSkins
    for i, skin in ipairs(choices) do same = same and W.Stake.MaskSkins[i] == skin end
    check("mask texture choices match the code's skin order (" .. #choices .. ")", same)
    local missing = {}
    for _, skin in ipairs(choices) do
      local png = io.open(L .. "/../textures/WhispMask/" .. skin .. ".png", "r")
      if png then png:close() else missing[#missing + 1] = skin end
    end
    check("every mask texture exists (missing: " .. table.concat(missing, ", ") .. ")", #missing == 0)
  end
end
check("a mask from an old face with no look keeps choice 0", W.Stake.maskTextureIndex(nil) == 0)

-- Cut face
local head = P.inv:getFirstTypeRecurse(G.Types.Head)
local cf = Whisp_CutFaceAction:new(P, head, knife)
cf:complete()
local face = P.inv:getFirstTypeRecurse(G.Types.Face)
check("face created & named", face and face.name:find("Rick Grimes's Face") == 1)
check("the face keeps its head's look", face.md.WhispLook == look)
P.perks.Butchering = 10
check("master + sharp blade = no damage", Whisp_CutFaceAction.baseDamage(P, knife) == 0)
knife.sharp = 0.2; P.perks.Butchering = 0
P.perks.Butchering = 3; knife.sharp = 1

-- Head stake from a faceless head, then taken apart
local fh = instanceItem(G.Types.FacelessHead); fh.md.WhispOwner = "Rick Grimes"
local function makeStake()
  local st = instanceItem(G.Types.Stake)
  W.Recipes.OnCreateHeadStake({ getAllInputItems = function() return List({ fh, instanceItem("Base.LongStick") }) end,
    getAllCreatedItems = function() return List({ st }) end }, P)
  return st
end
local stake = makeStake()
check("stake named from head owner", stake.name == "Rick Grimes's Head Stake")
check("stake remembers a faceless head", stake.md.WhispFaceless == true)

-- The stake is a mannequin, built at crafting and saved into the item.
local S = W.Stake
local function wears(st, fullType)
  for _, t in ipairs(st.byteData and st.byteData.worn or {}) do if t == fullType then return true end end
  return false
end
if mannequinCount > 0 then
  local skins, missing = 0, {}
  for _, gender in pairs(S.Skins) do
    for _, kind in pairs(gender) do
      for _, skin in ipairs(kind) do skins = skins + 1; if not MANNEQUINS[S.ScriptPrefix .. skin] then missing[#missing + 1] = skin end end
    end
  end
  check("every stake skin has a mannequin script (missing: " .. table.concat(missing, ", ") .. ")", #missing == 0)
  check("every stake mannequin script is a stake skin", skins == mannequinCount)
end
check("a crafted stake carries its mannequin", stake.byteData ~= nil)
check("an uncaptured player head still gets a human face", stake.byteData.script == "Whisp_Stake_FemaleBody01" and stake.md.WhispLook.human == true)
check("the stake wears the stick and the flayed face", wears(stake, G.Types.StakeStick) and wears(stake, G.Types.StakeFaceless))
check("stake visuals are in the mannequin too (saves need it)", stake.byteData.inContainer == 2)
check("a stake head is bloody at the neck", stake.byteData.hv.blood[BloodBodyPartType.Neck] == 1)

local function stakeFrom(head)
  local st = instanceItem(G.Types.Stake)
  W.Recipes.OnCreateHeadStake({ getAllInputItems = function() return List({ head, instanceItem("Base.LongStick") }) end,
    getAllCreatedItems = function() return List({ st }) end }, P)
  return st
end
local owned = instanceItem(G.Types.Head); owned.md.WhispOwner = "Rick Grimes"; owned.md.WhispLook = look
local ownStake = stakeFrom(owned)
check("a player's stake shows their own skin, hair and beard", ownStake.byteData.script == "Whisp_Stake_MaleBody03"
  and ownStake.byteData.hv.hair == "Messy" and ownStake.byteData.hv.beard == "Full")
check("a player's stake with a face has no flayed face", wears(ownStake, G.Types.StakeStick) and not wears(ownStake, G.Types.StakeFaceless))
local zr = ZombRand
ZombRand = function(n) return n - 1 end
local zombieStake = stakeFrom(instanceItem(G.Types.Head))
ZombRand = zr
ZombRand = function(n) return n == 100 and 0 or n - 1 end
local bearded = stakeFrom(instanceItem(G.Types.Head))
ZombRand = zr
check("a stranger's male head can have a beard", bearded.byteData.hv.beard == "Full", bearded.byteData.hv.beard)
check("a stranger's head gets a random look, rotten ones included", zombieStake.byteData.script == "Whisp_Stake_M_ZedBody04_level3"
  and zombieStake.byteData.hv.hair == "Short" and zombieStake.md.WhispLook.human == nil)
check("a player's head never shows a rotten or unknown skin",
  S.scriptFor({ female = false, skin = "M_ZedBody01_level3", human = true }) == "Whisp_Stake_MaleBody01"
  and S.scriptFor({ female = true, skin = "SomeModSkin", human = true }) == "Whisp_Stake_FemaleBody01")

-- Picking a placed stake up keeps who it was; placing an old stake dresses it.
local props = setmetatable({ customItem = G.Types.Stake }, { __index = ISMoveableSpriteProps })
local placed = { md = { WhispOwner = "Rick Grimes", WhispFaceless = true, WhispLook = look, WhispSkills = { Butchering = 7 } } }
function placed:getModData() return self.md end
local picked = props:pickUpMoveableInternal(P, nil, placed)
check("a picked-up stake keeps owner, face and skills", picked.md.WhispOwner == "Rick Grimes" and picked.md.WhispFaceless == true
  and picked.md.WhispLook == look and picked.md.WhispSkills.Butchering == 7)
check("a picked-up stake is named again", picked.name == "Rick Grimes's Head Stake")
check("a picked-up stake places on the mannequin tile", picked.worldSprite == S.Sprite)
check("stake items made outside a pickup carry nothing", props:instanceItem().md.WhispOwner == nil)
local old = instanceItem(G.Types.Stake); old.md.WhispOwner = "Rick Grimes"
props:placeMoveableInternal(nil, old, "whisperers_headstake_01_2")
check("an old flat stake is placed as a mannequin", props.placed.sprite == S.Sprite and old.worldSprite == S.Sprite)
check("an old stake is dressed when placed", old.byteData ~= nil and old.byteData.script:find(S.ScriptPrefix, 1, true) == 1)
local dressed = old.byteData
props:placeMoveableInternal(nil, old, S.Sprite)
check("a dressed stake is not dressed again", old.byteData == dressed)
local function takeApart(st, roll)
  nextRand = roll; halos = {}
  local before = #P.inv.items
  W.Recipes.OnCreateDisassembleHeadStake({ getAllInputItems = function() return List({ st }) end }, P)
  local got = {}; for i = before + 1, #P.inv.items do got[#got+1] = P.inv.items[i] end
  return got
end
check("break chance defaults to 75%", W.Get("HeadStakeBreakChance") == 75)
local got = takeApart(stake, 75)
check("rolls of 75+ keep head and stick", #got == 2 and got[1]._t == G.Types.FacelessHead and got[2]._t == "Base.LongStick")
check("returned head keeps owner and stays faceless", got[1].name == "Rick Grimes's Head (Faceless)" and got[1].md.WhispFaceless == true and got[1].md.WhispOwner == "Rick Grimes")
got = takeApart(makeStake(), 74)
check("rolls under 75 break both parts", #got == 0 and #halos == 2)
for i = #P.inv.items, 1, -1 do local t = P.inv.items[i]._t; if t == G.Types.FacelessHead or t == "Base.LongStick" then table.remove(P.inv.items, i) end end

-- Brain from either head, named for its owner
local function brainFrom(head)
  local br = instanceItem(G.Types.Brain)
  W.Recipes.OnCreateBrain({ getAllInputItems = function() return List({ knife, head }) end,
    getAllCreatedItems = function() return List({ br }) end }, P)
  return br
end
local fb = brainFrom(fh)
check("faceless head gives a named brain", fb.name == "Rick Grimes's Brain" and fb.md.WhispOwner == "Rick Grimes")
check("zombie head gives a zombie brain", brainFrom(instanceItem(G.Types.Head)).name == "Zombie Brain")

-- Recipe: face mask with a nail
local nail = instanceItem("Base.Nails")
local mask = instanceItem(G.Types.Mask)
local data = { getAllInputItems = function() return List({ face, nail }) end, getAllCreatedItems = function() return List({ mask }) end }
W.Recipes.OnCreateFaceMask(data, P)
local expect = math.floor(100 * face.md.WhispQuality * 0.7 + 0.5)
check("mask named from face owner", mask.name == "Rick Grimes's Face Mask")
check("the mask keeps the face's look", mask.md.WhispLook == look)
check("the mask wears the face's skin", mask.textureChoice ~= nil
  and W.Stake.MaskSkins[mask.textureChoice + 1] == "MaleBody03", tostring(mask.textureChoice))
check("mask condition = quality * 70% (nail) = " .. expect .. " got " .. mask.cond, mask.cond == expect)

-- Gear multiplier
hv.b = { [0] = 0.1, 0.1, 0.1, 0.1 }
local g0, any0, raw0, m0 = W.measureGore(P)
P.worn = { mask }
local g1, any1, raw1, m1 = W.measureGore(P)
check("mask multiplies x5", m1 == 5 and g1 > g0 * 4.9)
check("mask counts as gore for misery", any1)

-- Wear toggle damage
P.worn = {}
mask.md.WhispWorn = nil
local c0 = mask.cond
G.onWearToggle(P, mask, true)
check("put on costs 10% -> " .. mask.cond, mask.cond == c0 - 10)
G.onWearToggle(P, mask, true)
check("no double charge", mask.cond == c0 - 10)
G.onWearToggle(P, mask, false)
check("take off costs 10%", mask.cond == c0 - 20)

-- Repair (needle) back to 100
P.inv:AddItem(mask)
local needle = instanceItem("Base.Needle"); P.inv:AddItem(needle)
local thread = drain("Base.Thread", 5); P.inv:AddItem(thread)
check("find clasp thread", G.findClasp(P, 1) == "Base.Thread")
check("find needle before nail", G.findSewingTool(P) == needle)
local rp = Whisp_RepairMaskAction:new(P, mask, needle, "Base.Thread")
check("repair valid at Tailoring 5", rp:isValid())
check("repair duration 150-5*6=120", rp.maxTime == 120)
rp:complete()
check("repaired to 100", mask.cond == 100)
check("thread used 2 -> 3 left", thread.uses == 3)

-- Skin suit: needs 6 thread; have 3 -> invalid; add more
local sb = corpse(nil)
sb.md.WhispHeadless = true
G.applyCorpseVisuals(sb)
local sk = Whisp_SkinCorpseAction:new(P, sb, knife, needle, "Base.Thread")
P.perks.Tailoring = 4
check("skin invalid without 6 thread", not sk:isValid())
local thread2 = drain("Base.Thread", 10); P.inv:AddItem(thread2)
check("skin valid", sk:isValid())
sk:complete()
local suit = P.inv:getFirstTypeRecurse(G.Types.Suit)
check("zombie skin suit named", suit and suit.name == "Zombie Skin Suit")
check("suit full condition w/ needle", suit.cond == 100)
check("headless corpse skinned", suit ~= nil)
check("flayed body disappears", #sb.sq.bodies == 0)
local dropped = {}; for _, it in ipairs(sb.sq.floor) do dropped[it._t] = true end
check("its belongings are left on the ground", #sb.sq.floor == 3 and dropped["Base.Hat_Baseball"] and dropped["Base.Tshirt"] and dropped["Base.Briefs"])
check("the stump is not left on the ground", not dropped[G.Types.Stump])
check("6 thread consumed (13 -> 7)", G.totalUses(P, "Base.Thread") == 7)

-- Suit strips everything but head gear, shoes and socks
local shirt = instanceItem("Whisperers.Guts"); shirt.loc = "base:tshirt"; shirt._cls = "Clothing"
local hat = instanceItem("Whisperers.Guts"); hat.loc = "base:hat"; hat._cls = "Clothing"
local shoes = instanceItem("Whisperers.Guts"); shoes.loc = "base:shoes"; shoes._cls = "Clothing"
local socks = instanceItem("Whisperers.Guts"); socks.loc = "base:socks"; socks._cls = "Clothing"
P.worn = { shirt, hat, shoes, socks, suit, mask }
G.stripForSuit(P)
local left = {}; for _, w in ipairs(P.worn) do left[#left+1] = w.loc end
check("suit strips shirt, keeps hat/shoes/socks/mask: " .. table.concat(left, ","), #P.worn == 5 and not P:isEquipped(shirt))
check("wear blocked over suit", not G.allowedWithSuit(shirt) and G.allowedWithSuit(hat))
check("shoes and socks allowed with suit", G.allowedWithSuit(shoes) and G.allowedWithSuit(socks))
check("wornMask finds the mask", G.wornMask(P) == mask)
local _, _, _, m2, c2 = W.measureGore(P)
check("mask x suit = x50", m2 == 50)
check("mask + suit give full cover", math.abs(c2 - 1) < 1e-9)
check("cover hierarchy: mask 0.35 < suit 0.65", G.coverFor(mask) == 0.35 and G.coverFor(suit) == 0.65)

-- Suit destroyed by a big hit
suit.md.WhispCond = nil
fire("OnPlayerGetDamage", P, "WEAPONHIT", 5)
check("small hit wears suit 5*2=10%", suit.cond == 90)
fire("OnPlayerGetDamage", P, "WEAPONHIT", 25)
check("big hit tears suit", suit.cond == 0)
local _, _, _, m3, c3 = W.measureGore(P)
check("torn suit loses multiplier", m3 == 5)
check("torn suit loses its cover", math.abs(c3 - 0.35) < 1e-9)

-- Smear guts: capacity, blood, pct
P.worn = {}
hv.b = {}
local gut = P.inv:getFirstTypeRecurse(G.Types.Guts)
check("fresh gut capacity 1", math.abs(G.gutsCapacity(gut) - 1) < 1e-9)
local sm = Whisp_SmearGutsAction:new(P, gut)
sm:complete()
check("smear adds 0.75*0.5 = 0.375 blood per part", math.abs(hv.b[0] - 0.375) < 1e-9)
check("guts pct 37.5", math.abs(P.md.WhispGutsPct - 37.5) < 1e-9)
check("gut consumed", P.inv:getAllTypeRecurse(G.Types.Guts):size() == 3)

-- Smear All keeps going until camouflage is full (FullGorePercent), not 100% gore
local gutA = P.inv:getFirstTypeRecurse(G.Types.Guts)
local sa = Whisp_SmearGutsAction:new(P, gutA, true)
check("smear all continues below full camo (33.75% gore)", sa:isValidStart())
check("single smear never stops on gore", Whisp_SmearGutsAction:new(P, gutA):isValidStart())
local saved = hv.b
hv.b = {}; for i = 0, BloodBodyPartType.MAX:index() - 1 do hv.b[i] = 0.8 end
check("smear all stops at full camo (72% gore)", not sa:isValidStart())
sa:complete()
check("gut kept once camo is full", P.inv:getAllTypeRecurse(G.Types.Guts):size() == 3)
hv.b = saved

-- Decay: 72h -> 50%
hours = hours + 72
local g2 = P.inv:getFirstTypeRecurse(G.Types.Guts)
check("after 72h capacity 50%", math.abs(G.gutsCapacity(g2) - 0.5) < 1e-9)
G.refreshGuts(g2)
check("weight 1.25 & name", math.abs(g2.weight - 1.25) < 1e-9 and g2.name == "Guts (50%)")

-- Minute tick records corpse sickness and carried-guts discomfort; every tick
-- applies them the way vanilla corpse sickness is applied.
stats.v = { [CharacterStat.SICKNESS] = 0.6 }
for _ = 1, 2 do local fresh = P.inv:AddItem(G.Types.Guts); fresh.md.WhispBorn = hours end -- 3.75 kg aged + 5 kg fresh
fire("EveryOneMinute")
check("old SICKNESS left by earlier versions is cleared once", stats:get(CharacterStat.SICKNESS) == 0)
check("sickness rate 12*0.375 smeared + 10*3.75/10 carried = 8.25/h", math.abs(W.getHold(P, "sickRate") - 8.25) < 1e-9)
check("minute tick itself adds no sickness", stats:get(CharacterStat.FOOD_SICKNESS) == 0)
check("8.75 kg of guts holds discomfort at 60", W.getHold(P, "guts") == 60)
fire("OnTick")
hours = hours + 0.1
fire("OnTick")
local fs = stats:get(CharacterStat.FOOD_SICKNESS)
check(string.format("0.1 h adds 0.825 food sickness plus vanilla's drain for 2 ticks: got %.5f", fs), math.abs(fs - (0.825 + 2 * 0.0015)) < 1e-9)
check("carried guts discomfort held one over the floor", stats:get(CharacterStat.DISCOMFORT) == 61)
stats.v[CharacterStat.DISCOMFORT] = 30
fire("OnTick")
check("every tick restores discomfort", stats:get(CharacterStat.DISCOMFORT) == 61)
stats.v[CharacterStat.FOOD_SICKNESS] = 79.9
hours = hours + 0.2
fire("OnTick")
check("corpse sickness stops at the cap", stats:get(CharacterStat.FOOD_SICKNESS) == 80)
stats.v[CharacterStat.FOOD_SICKNESS] = 10; stats.v[CharacterStat.POISON] = 5
hours = hours + 0.1
fire("OnTick")
check("no drain compensation while poisoned", math.abs(stats:get(CharacterStat.FOOD_SICKNESS) - 10.825) < 1e-9)
stats.v[CharacterStat.POISON] = nil
-- wash -> guts pct clears
hv.b = {}
fire("EveryOneMinute")
check("washing clears smeared guts", P.md.WhispGutsPct == nil)
check("washing stops corpse sickness from smeared guts", math.abs(W.getHold(P, "sickRate") - 10 * (G.carriedGutsKg(P) - 5) / 10) < 1e-9)
check("name stamped on player", P.md.WhispName == "Mira Lane")
-- rot away at < 5%: 72h * log2(20) ~ 311h
hours = hours + 400
fire("EveryOneMinute")
check("rotted guts removed", P.inv:getAllTypeRecurse(G.Types.Guts):size() == 0)
-- Drying: skin gear halves every GearDryHalfLifeHours; brain tan pauses it
local dm = instanceItem(G.Types.Mask); dm.condMax = 100; dm.cond = 100
dm.md.WhispOwner = "Rick Grimes"; dm.md.WhispCond = 100; dm.md.WhispDried = hours
hours = hours + 168
check("untreated mask halves in 168 h", not G.dryGear(P, dm) and dm.cond == 50)
local tan = instanceItem("Base.BrainTan")
W.Recipes.OnCreateTreatGear({ getAllInputItems = function() return List({ dm, tan }) end }, P)
check("brain tan treats for 336 h", dm.md.WhispTreatedUntil == hours + 336)
check("treated gear is named so", dm.name == "Rick Grimes's Face Mask (Treated)")
hours = hours + 336
G.dryGear(P, dm)
check("no drying while treated", dm.cond == 50)
check("treatment wears off", dm.name == "Rick Grimes's Face Mask")
hours = hours + 168
G.dryGear(P, dm)
check("drying resumes after treatment", dm.cond == 25)
dm.md.WhispTreatedUntil = hours + 84
hours = hours + 168
G.dryGear(P, dm)
check(string.format("half treated, half not: 25 * 0.5^0.5 = %.2f", 25 * 0.5 ^ 0.5), math.abs(dm.md.WhispCond - 25 * 0.5 ^ 0.5) < 1e-6)
dm.md.WhispCond = 8; dm.cond = 8
hours = hours + 168
check("below 5% it crumbles", G.dryGear(P, dm) and dm.cond == 0)
local ds = instanceItem(G.Types.Suit); ds.condMax = 100; ds.cond = 100; ds.md.WhispCond = 100; ds.md.WhispDried = hours
P.inv:AddItem(ds)
hours = hours + 168
fire("EveryOneMinute")
check("a carried suit dries on the minute tick", ds.cond == 50)
P.inv:Remove(ds)

-- Brains: skills recorded on the living, carried to the brain, taught once
Perks.None = "None"
local PERKS = { "Butchering", "Tailoring", "Woodwork" }
Perks.getMaxIndex = function() return #PERKS end
Perks.fromIndex = function(i) return PERKS[i + 1] end
Perks.Woodwork = "Woodwork"
PerkFactory = { getPerk = function(perk) return { getParent = function() return "Parent" end, getType = function() return perk end,
  getTotalXpForLevel = function(_, lvl) return lvl * 100 end } end }
local xp = {}
function P:getXp() return { getXP = function(_, perk) return xp[perk] or 0 end } end
function addXpNoMultiplier(pl, perk, n) xp[perk] = (xp[perk] or 0) + n; pl.perks[perk] = math.min(10, math.floor(xp[perk] / 100)) end
local dead = { perks = { Butchering = 7, Tailoring = 5, Woodwork = 0 }, md = {} }
function dead:getPerkLevel(perk) return self.perks[perk] end
function dead:getModData() return self.md end
function dead:isDead() return false end
G.stampSkills(dead)
check("skills above 0 recorded", dead.md.WhispSkills.Butchering == 7 and dead.md.WhispSkills.Tailoring == 5 and dead.md.WhispSkills.Woodwork == nil)
local ph = instanceItem(G.Types.Head); ph.md.WhispOwner = "Rick Grimes"; ph.md.WhispSkills = G.copySkills(dead.md)
local pbrain = brainFrom(ph)
check("brain carries the skills", pbrain.md.WhispSkills.Butchering == 7)
P.perks.Butchering = 3; P.perks.Tailoring = 4; xp.Butchering = 300; xp.Tailoring = 400
W.OnEatBrain(pbrain, P, 1)
check("level 6+ skill taught one level", P.perks.Butchering == 4)
check("skills under 6 not taught", P.perks.Tailoring == 4)
check("knowledge taken once", pbrain.md.WhispSkills == nil)
W.OnEatBrain(pbrain, P, 1)
check("second bite teaches nothing", P.perks.Butchering == 4)

BodyPartType = { Head = "Head" }
local infected = 0
local bd = P:getBodyDamage()
function P:getBodyDamage() bd.getBodyPart = function(_, part) return { generateZombieInfection = function(_, c) if part == "Head" then infected = c end end } end; return bd end
stats.v[CharacterStat.FOOD_SICKNESS] = 0
W.OnEatBrain(brainFrom(instanceItem(G.Types.Head)), P, 1)
check("zombie brain infects (vanilla roll at 100%)", infected == 100)
check("zombie brain adds 40% food sickness", stats:get(CharacterStat.FOOD_SICKNESS) == 40)
check("zombie brain teaches nothing", P.perks.Butchering == 4)

-- On a placed stake only head gear goes on, and the outfit buttons are hidden.
local visible = function() return true end
ISLootWindowObjectControlHandler_MannequinSwitchOutfit = { shouldBeVisible = visible }
ISLootWindowObjectControlHandler_MannequinWearAll = { shouldBeVisible = visible }
package.loaded["ISUI/LootWindow/Handlers/MannequinSwitchOutfit"] = true
package.loaded["ISUI/LootWindow/Handlers/MannequinWearAll"] = true
dofile(L .. "/client/Whisperers_StakeUI.lua")
local stakeObj = IsoMannequin.new(); stakeObj:setMannequinScriptName("Whisp_Stake_MaleBody01")
local shopObj = IsoMannequin.new(); shopObj:setMannequinScriptName("MaleWhite01")
local function into(obj, item) return ISInventoryTransferAction.isValid({ item = item, destContainer = { getParent = function() return obj end } }) end
local hat = instanceItem("Base.Hat_Baseball"); hat.loc = "base:hat"
local tee = instanceItem("Base.Tshirt"); tee.loc = "base:tshirt"
check("a hat can go on a stake", into(stakeObj, hat))
check("a shirt can't go on a stake", not into(stakeObj, tee))
check("a shop mannequin still takes a shirt", into(shopObj, tee))
check("a stake hides the outfit buttons", not ISLootWindowObjectControlHandler_MannequinSwitchOutfit.shouldBeVisible({ object = stakeObj })
  and not ISLootWindowObjectControlHandler_MannequinWearAll.shouldBeVisible({ object = stakeObj }))
check("a shop mannequin keeps the outfit buttons", ISLootWindowObjectControlHandler_MannequinWearAll.shouldBeVisible({ object = shopObj }))

if FAILED then print("whisperers_gear_checks: FAILED") os.exit(1) end
print("whisperers_gear_checks: all passed")
