#!/usr/bin/env lua
-- tests/whisperers_meter_checks.lua
--
-- The Whisperers' noise meter and zombie awareness, run against the mod's real
-- client code with a stand-in player, zombie and clock. It drives the meter
-- through sneaking, standing, walking, crouching, a gunshot and silence, and
-- checks the zombie is fooled, notices, and loses interest gradually; that
-- the meter ignores you with no zombie close by; and the stealth hierarchy
-- guts < face mask < skin suit for fall speed, meter levels and noticing.
-- Run from this project directory:  lua tests/whisperers_meter_checks.lua
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
local clock = 0
function getTimestampMs() return clock end
function isClient() return false end
function isServer() return false end
function getText(k) return k end
function instanceof(o, c) return o and o._cls == c end
math.randomseed(42)
function ZombRandFloat(a,b) return a + (b-a)*math.random() end
SandboxVars = {}
local handlers = {}
Events = setmetatable({}, {__index=function(t,k) local e={Add=function(f) handlers[k]=handlers[k] or {}; table.insert(handlers[k], f) end}; rawset(t,k,e); return e end})
local function fire(k, ...) for _,f in ipairs(handlers[k] or {}) do f(...) end end
BloodBodyPartType = { MAX = {index=function() return 4 end}, FromIndex=function(i) return {index=function() return i end} end }
BloodClothingType = { getCoveredParts=function() return nil end }
local blood = 0.8
local stats = {v={}, get=function(self,s) return self.v[s] or 0 end, set=function(self,s,v) self.v[s]=v end}
local function stat(n) return {n=n, getMaximumValue=function() return 100 end} end
CharacterStat = {UNHAPPINESS=stat"U", STRESS=stat"S", DISCOMFORT=stat"D"}
local hours = 0
function getGameTime() return {getWorldAgeHours=function() return hours end} end
local list = function(t) return {size=function() return #t end, get=function(_,i) return t[i+1] end} end
local posture = {sneak=true, moving=false}
local P = {_cls="IsoPlayer", x=0,y=0,z=0,
  isLocalPlayer=function() return true end, getPlayerNum=function() return 0 end, isDead=function() return false end,
  getHumanVisual=function() return {getBlood=function() return blood end} end,
  getWornItems=function() return list{} end, getPrimaryHandItem=function() return nil end,
  getInventory=function() return {getItems=function() return list{} end} end,
  getVehicle=function() return nil end, isPlayerMoving=function() return posture.moving end,
  isSneaking=function() return posture.sneak end, isSprinting=function() return false end, isRunning=function() return false end,
  getStats=function() return stats end, hasTrait=function() return false end,
  getX=function(s) return s.x end, getY=function(s) return s.y end, getZ=function(s) return s.z end,
  getModData=function() return {} end}
function getNumActivePlayers() return 1 end
function getSpecificPlayer() return P end
local Z = {_cls="IsoZombie", md={}, target=nil, x=5, y=0, z=0}
function Z:isRemoteZombie() return false end
function Z:isDead() return false end
function Z:getTarget() return self.target end
function Z:setTarget(t) self.target = t end
function Z:getModData() return self.md end
function Z:getX() return self.x end function Z:getY() return self.y end function Z:getZ() return self.z end
function Z:pathToCharacter() end
function Z:setUseless(b) self.useless = b end
function Z:isUseless() return self.useless == true end
function Z:setVariable() end
function Z:setPath2() end
function getCell() return {getZombieList=function() return list{Z} end} end
require "Whisperers_Client"; require "Whisperers_Zombies"
local W = Whisperers
local function run(sec) for _ = 1, sec * 10 do clock = clock + 100; hours = hours + 0.001; fire("OnTick"); fire("OnZombieUpdate", Z) end end
local function st() return W.Client.States[0] end
local function aware() return Z.md.Whisp and Z.md.Whisp.aware.l0 == true end
local function near(a, b) return math.abs(a - b) < 0.5 end

run(2)
assert(st().active and near(st().gore, 72), "camouflaged at 72% gore: " .. st().gore)
assert(st().meter == 0, "sneaking still keeps the meter at 0")
Z.target = P; run(1)
assert(Z.target == nil and not aware(), "a zombie that spots you at a low meter is fooled")
assert(Z.useless, "the fooled zombie is held so vanilla can't re-spot you")
posture.sneak = false; run(5)
assert(near(st().meter, 25), "standing upright rises at 5%/s: " .. st().meter)
run(10)
assert(near(st().meter, 55), "standing upright settles at 55%: " .. st().meter)
posture.moving = true; run(10)
assert(near(st().meter, 70), "walking upright settles at 70%: " .. st().meter)
assert(Z.target == P and aware(), "a zombie within range notices you above half")
assert(not Z.useless, "above half the held zombie is released")
posture.sneak = true; posture.moving = false; run(1)
assert(st().meter > 65, "the fall waits 2 s after activity: " .. st().meter)
run(60)
assert(st().meter == 0 and Z.target == nil and not aware() and Z.useless, "crouched and quiet, the zombie loses interest: " .. st().meter)

-- No zombie within MeterZombieRadius (8 tiles): upright and noisy is fine.
Z.x = 20
posture.sneak = false; posture.moving = true; run(10)
assert(st().meter == 0, "with no zombie near, walking upright leaves the meter at 0: " .. st().meter)
fire("OnWeaponSwing", P, { isRanged = function() return false end })
run(3)
assert(st().meter == 0, "with no zombie near, noise is ignored: " .. st().meter)
Z.x = 5; run(4)
assert(st().meter > 10, "a zombie wandering within 8 tiles starts the meter rising: " .. st().meter)
posture.sneak = true; posture.moving = false; run(30)
assert(st().meter == 0, "crouched again, back to 0")

-- Loss of interest is exponential, not a hard cut: with a crowd of aware
-- zombies and the meter at 0% (half-life 10 s x 0.25 = 2.5 s), about half
-- give up per 2.5 s.
local crowd = {}
for i = 1, 400 do
    local z = setmetatable({md={Whisp={aware={l0=true}}}, target=P, x=3, y=0, z=0}, {__index=Z})
    crowd[i] = z
end
local realCell = getCell
function getCell() return {getZombieList=function() return list(crowd) end} end
local function stillAware() local n = 0 for _, z in ipairs(crowd) do if z.md.Whisp.aware.l0 then n = n + 1 end end return n end
run(0.5)
assert(stillAware() > 330, "one scan in, most aware zombies are still after you: " .. stillAware())
run(2)
assert(stillAware() > 150 and stillAware() < 250, "after one half-life about half remain: " .. stillAware())
run(2.5)
assert(stillAware() > 60 and stillAware() < 140, "after two half-lives about a quarter remain: " .. stillAware())
run(60)
assert(stillAware() == 0, "given time, every zombie loses interest")
local lost = true
for _, z in ipairs(crowd) do if z.target ~= nil or not z.useless then lost = false end end
assert(lost, "each zombie that loses interest stops pursuing and is held")
getCell = realCell

-- Zombies walking toward a hidden player without a target (following their
-- footsteps, or heading for where they last saw them) are stopped and held.
local function walker(tx)
    local w = setmetatable({md={}, target=nil, useless=false, x=15, y=0, z=0, state="PathFindState", tx=tx}, {__index=Z})
    function w:getCurrentStateName() return self.state end
    function w:getPathTargetX() return self.tx end
    function w:getPathTargetY() return 0 end
    function w:getPathTargetZ() return 0 end
    return w
end
local toPlayer, elsewhere = walker(2), walker(30)
function getCell() return {getZombieList=function() return list{Z, toPlayer, elsewhere} end} end
run(1)
assert(toPlayer.useless, "a zombie following a hidden player's sounds is held")
assert(not elsewhere.useless, "a zombie walking somewhere else is left alone")
getCell = realCell

-- Dead-skin disguise: guts < face mask < skin suit
assert(W.disguise(1, 0) == 0, "gore alone adds no disguise")
assert(W.disguise(1, 1) == 1, "full camouflage in mask and suit is a full disguise")
assert(W.disguise(0.5, 1) == 0.5, "the disguise scales with camouflage strength")
assert(W.noticeAt(0) == 50 and W.noticeAt(0.35) == 64 and W.noticeAt(0.65) == 76 and W.noticeAt(1) == 90,
    "zombies notice guts at 50%, a mask at 64%, a suit at 76%, both at 90%")
local realDisguise = W.disguise
local function wearing(level) W.disguise = function() return level end; run(0.5) end
-- Time for the meter to fall from 70 to 0 once crouched, per tier.
local function settleTime(level)
    wearing(level)
    st().meter = 70; st().lastActivityMs = clock
    local t = 0
    while st().meter > 0 and t < 60 do run(0.1); t = t + 0.1 end
    return t
end
local tGuts, tMask, tSuit, tBoth = settleTime(0), settleTime(0.35), settleTime(0.65), settleTime(1)
assert(tGuts > 15, "guts alone settle at the base rate: " .. tGuts)
assert(tMask < 5 and tMask < tGuts, "a mask settles much faster: " .. tMask)
assert(tSuit < 2 and tSuit < tMask, "a suit settles almost at once: " .. tSuit)
assert(tBoth <= 0.6, "mask and suit settle instantly: " .. tBoth)
wearing(1)
posture.sneak = false; posture.moving = true; run(20)
assert(near(st().meter, 30) and Z.target == nil, "fully disguised, walking upright settles at 30%: " .. st().meter)
posture.moving = false; run(15)
assert(near(st().meter, 10), "fully disguised, standing upright settles at 10%: " .. st().meter)
P.isRunning = function() return true end; posture.moving = true; run(15)
assert(near(st().meter, 35) and Z.target == nil, "fully disguised, running settles at 35% unnoticed: " .. st().meter)
P.isRunning = function() return false end
P.isSprinting = function() return true end; run(20)
assert(near(st().meter, 60) and Z.target == nil, "fully disguised, even sprinting (60%) goes unnoticed: " .. st().meter)
P.isSprinting = function() return false end
for _ = 1, 2 do fire("OnWeaponSwing", P, { isRanged = function() return false end }); run(1) end
run(10)
assert(st().meter < 90 and Z.target == nil, "fully disguised, a couple of melee swings still pass: " .. st().meter)
fire("OnWeaponSwing", P, { isRanged = function() return true end, getSoundRadius = function() return 80 end })
run(20)
assert(st().meter >= 90 and Z.target == P and aware(), "fully disguised, a gunshot gives you away: " .. st().meter)
run(15)
assert(st().meter <= 30, "full cover drains the meter fast once the noise is spent: " .. st().meter)
wearing(0.35)
P.isSprinting = function() return true end; run(20)
assert(st().meter > W.noticeAt(0.35) and Z.target == P, "in a mask alone, sprinting gets you noticed: " .. st().meter)
P.isSprinting = function() return false end
W.disguise = realDisguise
posture.sneak = true; posture.moving = false; run(40)
assert(st().meter < 10 and Z.target == nil, "crouched again, you're one of them")
fire("OnWeaponSwing", P, { isRanged = function() return true end, getSoundRadius = function() return 80 end })
run(1)
assert(st().meter < 50, "a gunshot pushes the meter up slowly, not at once: " .. st().meter)
run(20)
assert(st().meter == 100 and Z.target == P, "a gunshot fills the meter and every zombie comes")
run(10)
assert(st().meter < 100 and st().meter > 50, "quiet again, the meter falls gradually: " .. st().meter)
run(70)
assert(st().meter == 0 and Z.target == nil and not aware(), "quiet long enough, every zombie loses interest: " .. st().meter)
assert(Whisperers.getHold(P, "gore") == 80, "bloodied, discomfort is held at DiscomfortLevel")
Whisperers.applyHolds(P, true)
assert(stats.v[CharacterStat.DISCOMFORT] == 81, "the hold sets discomfort one point over the floor")
stats.v[CharacterStat.DISCOMFORT] = 40
Whisperers.applyHolds(P, true)
assert(stats.v[CharacterStat.DISCOMFORT] == 81, "every tick restores it after vanilla eases it down")
-- Washing ends every stealth effect on zombies: held zombies are released
-- and no zombie stays fooled or keeps a stale awareness of you.
posture.sneak = true; posture.moving = false; run(20)
Z.target = P; run(1)
assert(Z.useless and Z.target == nil, "hidden again, a zombie that spots you is held")
Z.md.Whisp.aware.l0 = true
blood = 0; run(2)
assert(not st().active, "washed clean, the camouflage ends")
assert(not Z.useless, "washed clean, the held zombie is released to vanilla")
assert(not aware(), "washed clean, no zombie keeps stale awareness of you")
Z.target = P; run(1)
assert(Z.target == P and not Z.useless, "washed clean, a zombie that spots you keeps you as its target")
assert(stats.v[CharacterStat.UNHAPPINESS] > 0 and stats.v[CharacterStat.STRESS] > 0, "misery built while bloodied")
assert(Whisperers.getHold(P, "gore") == nil, "washing releases the discomfort hold")
print("whisperers_meter_checks: all passed")
