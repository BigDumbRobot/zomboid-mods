#!/usr/bin/env lua
-- tests/whisperers_gait_checks.lua
--
-- The Whisperers' zombie mannerisms, offline:
--   * the rule (G.wantsZombieGait): intact mask AND suit, alive, on foot,
--     enabled in sandbox; either piece alone, or a torn one, stays human;
--   * the tick (Whisperers_ZombieGait.lua): sets WhispZombieGait on every
--     local player in single player and every online player in multiplayer,
--     only when it changes, at most every 250 ms;
--   * the animation nodes (media/AnimSets/player/*/Whisp_Zombie*.xml),
--     cross-checked against the game install: each sits in a real vanilla
--     state, outranks every vanilla node there, plays a real zombie clip,
--     matches the tester's GAIT_CLIPS table, keeps footsteps (quiet ones when
--     crouched), and leaves turning, timed actions and fidgets to vanilla;
--   * the sandbox option, its default and its translation.
-- Run from this project directory:
--   lua -e "next=nil" tests/whisperers_gait_checks.lua
-- Loads The Whisperers' real code: its Steam Workshop subscription when that
-- has the zombie gait, otherwise ~/Zomboid/Workshop/TheWhisperers (so it runs
-- before the gait is published, and against local edits until it is).
local HOME = os.getenv("HOME") or ""
local function exists(path) local f = io.open(path, "r"); if f then f:close() return true end return false end
local function read(path) local f = assert(io.open(path, "r"), path); local s = f:read("a"); f:close(); return s end
local function ls(dir)
    local out, p = {}, io.popen('ls "' .. dir .. '" 2>/dev/null')
    for name in (p and p:read("a") or ""):gmatch("[^\n]+") do out[#out + 1] = name end
    if p then p:close() end
    return out
end
local GAIT = "media/lua/client/Whisperers_ZombieGait.lua"
local function modRoot()
    local workshop = HOME .. "/Library/Application Support/Steam/steamapps/workshop/content/108600/"
    for _, id in ipairs(ls(workshop)) do
        local root = workshop .. id .. "/mods/TheWhisperers/42/"
        if exists(root .. "media/lua/shared/Whisperers_Shared.lua") then
            if exists(root .. GAIT) then return root end
            print("INFO | Workshop subscription " .. id .. " has no zombie gait yet; using ~/Zomboid/Workshop")
        end
    end
    local root = HOME .. "/Zomboid/Workshop/TheWhisperers/Contents/mods/TheWhisperers/42/"
    assert(exists(root .. GAIT), "The Whisperers with the zombie gait is neither subscribed nor in ~/Zomboid/Workshop")
    return root
end
local ROOT = modRoot()
local L = ROOT .. "media/lua"
local GAME = HOME .. "/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents/Java/media/"
package.path = L .. "/shared/?.lua;" .. L .. "/client/?.lua;" .. package.path
print("Loading The Whisperers from " .. ROOT)

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else failed = failed + 1 end
    print((ok and "PASS" or "FAIL") .. " | " .. name .. (detail ~= nil and (" | " .. tostring(detail)) or ""))
end

-- ===== engine stand-ins =====
local now, client = 0, false
function getTimestampMs() return now end
function isClient() return client end
function isServer() return false end
function getText(k) return k end
SandboxVars = { TheWhisperers = {} }
local handlers = {}
Events = setmetatable({}, { __index = function(t, k)
    local e = { Add = function(f) handlers[k] = handlers[k] or {}; table.insert(handlers[k], f) end }
    rawset(t, k, e); return e end })
local function List(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end

local function item(fullType, cond)
    return { getFullType = function() return fullType end, getCondition = function() return cond end }
end
local function Player(name)
    local p = { name = name, worn = {}, vars = {}, sets = 0, dead = false, vehicle = nil }
    function p:getWornItems()
        local slots = {}
        for _, it in ipairs(self.worn) do slots[#slots + 1] = { getItem = function() return it end } end
        return List(slots)
    end
    function p:isDead() return self.dead end
    function p:getVehicle() return self.vehicle end
    function p:getVariableBoolean(k) return self.vars[k] == true end
    function p:setVariable(k, v) self.vars[k] = v; self.sets = self.sets + 1 end
    return p
end
local locals, online = {}, {}
function getSpecificPlayer(n) return locals[n] end
function getOnlinePlayers() return List(online) end

require "Whisperers_Shared"
require "Whisperers_Gear"
require "Whisperers_ZombieGait"
local W, G = Whisperers, Whisperers.Gear
local MASK, SUIT = G.Types.Mask, G.Types.Suit

-- ===== the rule =====
local p = Player("a")
local function wearing(...) p.worn = { ... }; return G.wantsZombieGait(p) end
check("nothing worn: human", wearing() == false)
check("mask only: human", wearing(item(MASK, 80)) == false)
check("suit only: human", wearing(item(SUIT, 80)) == false)
check("mask and suit: zombie", wearing(item(MASK, 80), item(SUIT, 80)) == true)
check("other clothes don't matter", wearing(item("Base.Shoes_Black", 5), item(MASK, 1), item(SUIT, 1)) == true)
check("torn mask with a suit: human", wearing(item(MASK, 0), item(SUIT, 80)) == false)
check("torn suit with a mask: human", wearing(item(MASK, 80), item(SUIT, 0)) == false)
p.worn = { item(MASK, 80), item(SUIT, 80) }
p.dead = true; check("dead: no gait", G.wantsZombieGait(p) == false); p.dead = false
p.vehicle = {}; check("in a vehicle: no gait", G.wantsZombieGait(p) == false); p.vehicle = nil
SandboxVars.TheWhisperers.ZombieMannerisms = false
check("ZombieMannerisms off: no gait", G.wantsZombieGait(p) == false)
SandboxVars.TheWhisperers.ZombieMannerisms = nil
check("ZombieMannerisms defaults on", W.Get("ZombieMannerisms") == true and G.wantsZombieGait(p) == true)
SandboxVars.TheWhisperers.Enabled = false
check("mod disabled: no gait", G.wantsZombieGait(p) == false)
SandboxVars.TheWhisperers.Enabled = nil
check("no player: no gait", G.wantsZombieGait(nil) == false)

-- ===== the tick =====
local tick = handlers.OnTick and handlers.OnTick[1]
check("gait tick registered on OnTick", tick ~= nil)
local sp, split = Player("sp"), Player("split-screen")
locals = { [0] = sp, [1] = split }
sp.worn = { item(MASK, 80), item(SUIT, 80) }
now = 1000; tick()
check("single player: flag on in full disguise", sp.vars.WhispZombieGait == true)
check("single player: split-screen player stays human", split.vars.WhispZombieGait ~= true)
local sets = sp.sets
now = 1100; sp.worn = {}; tick()
check("throttled to 250 ms", sp.vars.WhispZombieGait == true)
now = 1300; tick()
check("flag off once the gear comes off", sp.vars.WhispZombieGait == false)
now = 1600; tick(); now = 1900; tick()
check("flag only written when it changes", sp.sets == sets + 1, sp.sets - sets .. " writes")

client = true
local me, other = Player("me"), Player("remote")
online = { me, other }
other.worn = { item(SUIT, 50), item(MASK, 50) }
now = 5000; tick()
check("multiplayer: remote players in full disguise shamble too", other.vars.WhispZombieGait == true)
check("multiplayer: a player in nothing stays human", me.vars.WhispZombieGait ~= true)
client = false

-- ===== the animation nodes =====
local function tag(xml, name) return xml:match("<" .. name .. ">%s*(.-)%s*</" .. name .. ">") end
local function conditions(xml)
    local out = {}
    for body in xml:gmatch("<m_Conditions[^>]*>(.-)</m_Conditions>") do
        out[#out + 1] = { name = tag(body, "m_Name"), type = tag(body, "m_Type"), value = tag(body, "m_Value") }
    end
    return out
end
local function cond(conds, name)
    for _, c in ipairs(conds) do if c.name and c.name:lower() == name:lower() then return c end end
end
local function footsteps(xml)
    local out = {}
    for body in xml:gmatch("<m_Events>(.-)</m_Events>") do
        if tag(body, "m_EventName") == "Footstep" then out[#out + 1] = tag(body, "m_ParameterValue") end
    end
    return out
end
-- Only top-level conditions count for node selection; transitions carry their own.
local function topLevel(xml) return (xml:gsub("<m_Transitions>.-</m_Transitions>", "")) end

dofile(HOME .. "/Zomboid/Workshop/LilBubbyModTester/Contents/mods/LilBubbyModTester/42/media/lua/shared/WhisperersTest_Checks.lua")
local CLIPS = WhisperersTest.GAIT_CLIPS
-- Which tester movement each node stands for, and the footstep it must make.
local EXPECT = {
    Whisp_ZombieIdle = { state = "idle", key = "idle" },
    Whisp_ZombieWalk = { state = "movement", key = "walk", sneaking = "false", step = "walk" },
    Whisp_ZombieSneakWalk = { state = "movement", key = "sneakWalk", sneaking = "true", step = "sneak_walk" },
    Whisp_ZombieRun = { state = "run", key = "run", sneaking = "false", step = "run" },
    Whisp_ZombieSneakRun = { state = "run", key = "sneakRun", sneaking = "true", step = "sneak_run" },
    Whisp_ZombieSprint = { state = "sprint", key = "sprint", step = "sprint" },
    Whisp_ZombieSit = { state = "sitonground-sitting", key = "sit" },
}
local haveGame = exists(GAME .. "AnimSets/player.xml")
if not haveGame then print("INFO | game install not found; skipping cross-checks against vanilla files") end

local found = {}
local ANIM = ROOT .. "media/AnimSets/player/"
for _, state in ipairs(ls(ANIM)) do
    for _, file in ipairs(ls(ANIM .. state)) do
        if file:match("^Whisp_Zombie.*%.xml$") then
            local xml = read(ANIM .. state .. "/" .. file)
            local top = topLevel(xml)
            local name, clip = tag(xml, "m_Name"), tag(xml, "m_AnimName")
            local e = EXPECT[name]
            found[name] = true
            check(name .. ": file named after the node", file == name .. ".xml", file)
            check(name .. ": expected node", e ~= nil)
            if e then
                check(name .. ": in the " .. e.state .. " state", state == e.state, state)
                check(name .. ": plays " .. CLIPS[e.key], clip == CLIPS[e.key], clip)
                local conds = conditions(top)
                local gait = cond(conds, "WhispZombieGait")
                check(name .. ": needs WhispZombieGait", gait and gait.type == "BOOL" and gait.value == "true")
                if e.sneaking then
                    local s = cond(conds, "sneaking")
                    check(name .. ": sneaking = " .. e.sneaking, s and s.value == e.sneaking, s and s.value)
                end
                if state == "movement" or state == "run" then
                    local t = cond(conds, "isTurningAround")
                    check(name .. ": leaves 180-degree turns to vanilla", t and t.value == "false")
                end
                if state == "idle" then
                    check(name .. ": leaves turning on the spot to vanilla",
                        (cond(conds, "isTurning90") or {}).value == "false" and (cond(conds, "isTurningAround") or {}).value == "false")
                end
                if state == "sitonground-sitting" then
                    check(name .. ": timed actions stay human", (cond(conds, "hasTimedActions") or {}).value == "false")
                    check(name .. ": idle fidgets stay human", (cond(conds, "ExtPlaying") or {}).value == "false")
                end
                local steps = footsteps(xml)
                if e.step then
                    local ok = #steps >= 2
                    for _, s in ipairs(steps) do ok = ok and s == e.step end
                    check(name .. ": footsteps are '" .. e.step .. "'", ok, table.concat(steps, ","))
                else
                    check(name .. ": no footsteps standing or sitting", #steps == 0, table.concat(steps, ","))
                end
                local prio = tonumber(tag(xml, "m_ConditionPriority") or "0")
                if haveGame then
                    local vdir = GAME .. "AnimSets/player/" .. state .. "/"
                    local vfiles = ls(vdir)
                    check(name .. ": " .. state .. " is a vanilla player state", #vfiles > 0)
                    local maxPrio, clash = 0, nil
                    for _, vf in ipairs(vfiles) do
                        local vxml = read(vdir .. vf)
                        maxPrio = math.max(maxPrio, tonumber(tag(vxml, "m_ConditionPriority") or "0"))
                        if tag(vxml, "m_Name") == name then clash = vf end
                    end
                    check(name .. ": outranks every vanilla node in " .. state, prio > maxPrio, prio .. " vs " .. maxPrio)
                    check(name .. ": name not used by vanilla", clash == nil, clash)
                    check(name .. ": clip " .. tostring(clip) .. " ships with the game", exists(GAME .. "anims_X/Zombie/" .. tostring(clip) .. ".x"))
                else
                    check(name .. ": has a condition priority", prio > 0, prio)
                end
            end
        end
    end
end
for name in pairs(EXPECT) do check("node " .. name .. " present", found[name] == true) end
if haveGame then
    local mesh = read(GAME .. "scripts/generated/animations_meshes.txt")
    local human = mesh:match("animationsMesh Human%s*(%b{})") or ""
    check("the player's Human mesh loads the Zombie clip folder", human:find("animationDirectory = Zombie", 1, true) ~= nil)
end

-- ===== sandbox option and text =====
local options = read(ROOT .. "media/sandbox-options.txt")
check("sandbox option ZombieMannerisms, default true",
    options:find("option TheWhisperers.ZombieMannerisms { type = boolean, default = true", 1, true) ~= nil)
local text = read(L .. "/shared/Translate/EN/Sandbox.json")
check("sandbox option translated", text:find('"Sandbox_TheWhisperers_ZombieMannerisms"', 1, true) ~= nil
    and text:find('"Sandbox_TheWhisperers_ZombieMannerisms_tooltip"', 1, true) ~= nil)
check("default in W.Defaults", W.Defaults.ZombieMannerisms == true)

print(string.format("whisperers_gait_checks: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
