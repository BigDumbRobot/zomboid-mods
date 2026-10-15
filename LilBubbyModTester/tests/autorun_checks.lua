-- Offline checks for Run every test and character preparation, with stand-in
-- suites, skills, literature and a reading queue. Run from this project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local report = print
print = function() end
-- Kahlua, unlike stock Lua 5.4, cannot yield across pcall. Reproduce that so
-- a runner step that waits inside pcall fails here as it does in the game.
local rawPcall, rawYield, depth = pcall, coroutine.yield, {}
pcall = function(fn, ...)
    local co = coroutine.running()
    depth[co] = (depth[co] or 0) + 1
    local results = table.pack(rawPcall(fn, ...))
    depth[co] = depth[co] - 1
    return table.unpack(results, 1, results.n)
end
coroutine.yield = function(...)
    if (depth[coroutine.running()] or 0) > 0 then error("Can not yield outside of a coroutine") end
    return rawYield(...)
end
local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end }
    rawset(t, name, e)
    return e
end })
require = function() end
local clock = 0
function getTimestampMs() return clock end
isClient = function() return false end
isServer = function() return false end
getActivatedMods = function() return { contains = function(_, id) return id == "SVSBoobyTraps" end } end
HaloTextHelper = { addText = function() end }

-- Skills: level = floor(xp / 100).
local function perk(name) return { name = name, getTotalXpForLevel = function(_, level) return level * 100 end } end
Perks = {}
for _, name in ipairs({ "Electricity", "Mechanics", "Maintenance", "Doctor", "Woodwork", "Aiming", "Trapping", "MetalWelding" }) do
    Perks[name] = perk(name)
end
local xp = { Electricity = 250 }
function addXpNoMultiplier(_, p, amount) xp[p.name] = (xp[p.name] or 0) + amount end

-- Literature: each magazine teaches one recipe.
local function list(values) return { size = function() return #values end, get = function(_, i) return values[i + 1] end,
    contains = function(_, v) for _, x in ipairs(values) do if x == v then return true end end return false end } end
local teaches = {}
for i = 1, 10 do teaches["SVSBoobyTraps.MadMagazine" .. i] = "SVSBT_Recipe" .. i end
function getScriptManager() return { FindItem = function(_, fullType)
    return teaches[fullType] and { getLearnedRecipes = function() return list({ teaches[fullType] }) end } or nil
end } end

local known = { "SVSBT_Recipe1" }
local items, nextId = {}, 1
local inventory = {
    AddItem = function(_, fullType)
        local item = { id = nextId, fullType = fullType, modData = {} }
        function item:getID() return self.id end
        function item:getModData() return self.modData end
        function item:hasModData() for _ in pairs(self.modData) do return true end return false end
        function item:getDisplayName() return self.fullType end
        nextId = nextId + 1
        items[#items + 1] = item
        return item
    end,
    getItemWithID = function(_, id) for _, item in ipairs(items) do if item.id == id then return item end end end,
    getItems = function() return list(items) end,
    Remove = function(_, item) for i, x in ipairs(items) do if x == item then table.remove(items, i) return end end end,
}
local dark, illiterate = false, false
local player = {}
function player:getPlayerNum() return 0 end
function player:getOnlineID() return 1 end
function player:getInventory() return inventory end
function player:getPerkLevel(p) return math.floor((xp[p.name] or 0) / 100) end
function player:getXp() return { getXP = function(_, p) return xp[p.name] or 0 end } end
function player:getKnownRecipes() return list(known) end
function player:learnRecipe(recipe) known[#known + 1] = recipe end
function player:tooDarkToRead() return dark end
function getSpecificPlayer() return player end

-- Reading: one queued read finishes per tick and teaches its magazine's recipe.
local queue = { queue = {} }
ISTimedActionQueue = { add = function(action) table.insert(queue.queue, action) end,
    getTimedActionQueue = function() return queue end, clear = function() queue.queue = {} end }
ISReadABook = { new = function(_, _, item) return { item = item } end }
local reads = 0
local function readTick()
    local action = table.remove(queue.queue, 1)
    if action then
        reads = reads + 1
        if not illiterate then player:learnRecipe(teaches[action.item.fullType]) end
    end
end

dofile(root .. "client/LilBubbyShowcase.lua")
dofile(root .. "shared/LilBubbyTeleport.lua")
dofile(root .. "shared/LilBubbyPrep.lua")
dofile(root .. "client/LilBubbyAutoRun.lua")
local S, R, P = LilBubbyShowcase, LilBubbyAutoRun, LilBubbyPrep
R.DEFAULT_MS = 5000

-- Stand-in suites.
local pending = {}
local calls = {}
S.Register("compat", function(_, menu)
    menu:addOption("Run every automatic check", player, function() error("aggregate must be skipped") end)
    menu:addOption("Clean up my stuff", player, function(p)
        calls[#calls + 1] = "cleanup"; S.Report(p, "compat", "PASS: cleaned")
    end)
    menu:addOption("Check A", player, function(p) calls[#calls + 1] = "A"; S.Report(p, "compat", "Check A | PASSED\nPASS: fine") end)
    menu:addOption("Check B", player, function(p)
        calls[#calls + 1] = "B"
        pending[#pending + 1] = { at = clock + 300, fn = function() S.Report(p, "compat", "Working...", true) end }
        pending[#pending + 1] = { at = clock + 600, fn = function() S.Report(p, "compat", "Check B | FAILED\nPASS: one\nFAIL: broken thing") end }
    end)
    menu:addOption("Show last result", player, function() error("show must be skipped") end)
end)
S.Register("spy", function(_, menu)
    local disarm = menu:addOption("Disarm a trap", player, function() error("unavailable must be skipped") end)
    disarm.notAvailable = true
    disarm.unavailableReason = "Set a trap first"
    menu:addOption("Hang forever", player, function() calls[#calls + 1] = "hang" end)
end)

local function drive(limit)
    for _ = 1, limit or 5000 do
        clock = clock + 50
        readTick()
        for i = #pending, 1, -1 do
            if clock >= pending[i].at then local item = table.remove(pending, i); item.fn() end
        end
        for _, fn in ipairs(handlers.OnTickEvenPaused or {}) do fn() end
        if not R.Running() then return end
    end
end

-- The Run every test suite is listed first when any suite is.
assert(S.InstalledMods()[1].id == "all", "Run every test is listed first")
local entries = S.Build(player, "all")
assert(#entries == 4, "four run options")

R.Start(player, { prepare = true })
drive()
assert(not R.Running(), "run finished")
for name in pairs(Perks) do assert(player:getPerkLevel(Perks[name]) >= P.LEVEL, name .. " raised to " .. P.LEVEL) end
assert(reads == 9, "the 9 unread magazines were read with the read action, got " .. reads)
for i = 1, 10 do assert(P.Knows(player, "SVSBT_Recipe" .. i), "recipe " .. i .. " known") end
assert(#items == 0, "handed-out magazines removed afterwards")
assert(table.concat(calls, ",") == "A,B,cleanup,hang", "order: features, then cleanup, then next suite: " .. table.concat(calls, ","))
local summary = S.Session(player, "all").history[1]
assert(summary:find("^Run every test | FINISHED"), summary)
assert(summary:find("FAIL: Mod Compatibility / Check B -- FAIL: broken thing", 1, true), summary)
assert(summary:find("SKIP: Spy vs Spy / Disarm a trap -- Set a trap first", 1, true), summary)
assert(summary:find("FAIL: Spy vs Spy / Hang forever -- no result in 5 s", 1, true), summary)
assert(summary:find("PASS 3", 1, true), "preparation, Check A and cleanup pass: " .. summary)
assert(R.Classify("x | PASSED\nPASS: a") == "PASS" and R.Classify("BLOCKED: need a key") == "BLOCKED"
    and R.Classify("ATTEMPT FAILED: rolled low") == "FAIL" and R.Classify("SKIP: elsewhere") == "SKIP", "classification")

-- Too dark to read: recipes are taught directly instead.
known, xp, calls = {}, {}, {}
dark = true
R.Start(player, { prepareOnly = true })
drive()
assert(reads == 9, "nothing read in the dark")
for i = 1, 10 do assert(P.Knows(player, "SVSBT_Recipe" .. i), "recipe " .. i .. " taught in the dark") end
assert(#calls == 0, "prepare only runs no suites")
summary = S.Session(player, "all").history[1]
assert(summary:find("PASS 1", 1, true) and not summary:find("FAIL", 1, true), summary)

-- Reading that teaches nothing (illiterate) falls back to teaching too.
known = {}
dark, illiterate = false, true
R.Start(player, { prepareOnly = true })
drive()
for i = 1, 10 do assert(P.Knows(player, "SVSBT_Recipe" .. i), "recipe " .. i .. " taught after failed reading") end

-- Teach refuses recipes no enabled mod's literature teaches.
known = {}
P.Teach(player, { "SVSBT_Recipe2", "Base.MakeNuke" })
assert(P.Knows(player, "SVSBT_Recipe2") and not P.Knows(player, "Base.MakeNuke"), "teach is limited to the mods' recipes")

-- Stop ends the run after the current feature.
dark, illiterate = false, false
calls = {}
R.Start(player, { prepare = false })
R.Stop(player)
drive()
assert(not R.Running() and S.Session(player, "all").history[1]:find("STOPPED", 1, true), "stopped")
report("PASS: Run every test prepares skills and literature (read, taught when dark or unread, tidied), runs every feature in order with cleanup last, skips unavailable ones with reasons, times out silent ones, classifies results and stops on request")
