-- Offline checks for LilBubbyCraft: ingredients go straight into the
-- inventory, and a craft finishes without ever being queued twice.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local ticks = {}
Events = { OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end } }
local clock = 0
function getTimestampMs() return clock end
function isServer() return false end
print = function() end

-- Inventory with counts by full type; items carry modData.
local contents = {}
local function list(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
local inventory = {}
function inventory:getCountTypeRecurse(fullType)
    local n = 0
    for _, item in ipairs(contents) do if item.fullType == fullType then n = n + 1 end end
    return n
end
function inventory:AddItem(fullType)
    local item = { fullType = fullType, modData = {} }
    function item:getModData() return self.modData end
    function item:hasModData() for _ in pairs(self.modData) do return true end return false end
    contents[#contents + 1] = item
    return item
end
function inventory:getItems() return list(contents) end
function inventory:Remove(item) for i, x in ipairs(contents) do if x == item then table.remove(contents, i) return end end end
local player = { getInventory = function() return inventory end }

-- A recipe: 3 paper, 1 pen (either kind), and a fluid.
local function script(name) return { getFullName = function() return name end } end
local function input(names, amount, fluid)
    local items = {}
    for _, n in ipairs(names) do items[#items + 1] = script(n) end
    return { getPossibleInputItems = function() return list(items) end, getIntAmount = function() return amount end,
        getPossibleInputFluids = function() return list(fluid and { "Water" } or {}) end }
end
local recipe = { getInputs = function() return list({ input({ "Base.Paper" }, 3), input({ "Base.Pen", "Base.RedPen" }, 1),
    input({}, 1, true) }) end }
function getScriptManager() return { getCraftRecipe = function(_, name) return name == "Test.Form" and recipe or nil end } end

-- The craft: HandcraftStart queues an action that takes 5 ticks, unless interrupted.
local queued, busy, starts, interruptNext = 0, false, 0, false
arrived = true -- whether the given ingredients have reached this client
ISTimedActionQueue = { isPlayerDoingAction = function() return busy end }
local actionTicks = 0
ISEntityUI = { HandcraftStart = function() starts = starts + 1; queued = queued + 1 end }
HandcraftLogic = { new = function()
    return { setManualSelectInputs = function() end, setContainers = function() end, setRecipe = function() end, refresh = function() end,
        canPerformCurrentRecipe = function() return arrived end, areAllInputItemsSatisfied = function() return arrived end }
end }
ArrayList = { new = function() return { add = function() end } end }

dofile(root .. "shared/LilBubbyCraft.lua")
local C = LilBubbyCraft

inventory:AddItem("Base.Paper")
inventory:AddItem("Base.RedPen")
local given, notes = C.GiveInputs(player, recipe)
assert(#given == 2 and inventory:getCountTypeRecurse("Base.Paper") == 3, "only the 2 missing sheets are given")
assert(inventory:getCountTypeRecurse("Base.Pen") == 0, "a pen of another kind already satisfies the input")
assert(#notes == 1 and notes[1]:find("fluid"), "a fluid input is reported, not faked")
assert(C.TakeGiven(player) == 2 and inventory:getCountTypeRecurse("Base.Paper") == 1, "exactly the given items are taken back")

local function tick()
    clock = clock + 100
    -- The engine: a queued action starts on the next tick, runs 5 ticks, then yields the form.
    if queued > 0 and not busy then queued = queued - 1; busy = true; actionTicks = 0
    elseif busy then
        actionTicks = actionTicks + 1
        if interruptNext and actionTicks == 2 then busy = false; interruptNext = false
        elseif actionTicks >= 5 then busy = false; inventory:AddItem("Test.Output") end
    end
    for _, fn in ipairs(ticks) do fn() end
end

local result
C.Craft(player, "Test.Form", "Test.Output", function(ok, detail) result = { ok = ok, detail = detail } end)
for _ = 1, 40 do tick(); if result then break end end
assert(result and result.ok, "the craft finishes when the form appears: " .. tostring(result and result.detail))
assert(starts == 1, "a craft that runs normally is started once, not re-queued each tick (" .. starts .. ")")

result, starts, interruptNext = nil, 0, true
C.Craft(player, "Test.Form", "Test.Output", function(ok, detail) result = { ok = ok, detail = detail } end)
for _ = 1, 80 do tick(); if result then break end end
assert(result and result.ok and starts == 2, "an interrupted craft is restarted once and then finishes (" .. starts .. " starts)")
assert(result.detail:find("2 attempts"), "the report says it took 2 attempts")

result = nil
C.Craft(player, "Missing.Recipe", "Test.Output", function(ok, detail) result = { ok = ok, detail = detail } end)
assert(result and not result.ok and result.detail:find("not registered"), "an unknown recipe fails at once")

-- Ingredients the server just gave reach the client a second later: the
-- craft waits for them instead of giving up, then starts exactly once.
result, starts, arrived = nil, 0, false
C.Craft(player, "Test.Form", "Test.Output", function(ok, detail) result = { ok = ok, detail = detail } end)
for _ = 1, 10 do tick() end
assert(result == nil and starts == 0, "still waiting for the ingredients, nothing queued yet")
arrived = true
for _ = 1, 40 do tick(); if result then break end end
assert(result and result.ok and starts == 1, "the craft starts once the ingredients arrive and finishes (" .. starts .. " starts)")

-- Ingredients that never arrive fail after the wait, naming what is missing.
result, starts, arrived = nil, 0, false
C.Craft(player, "Test.Form", "Test.Output", function(ok, detail) result = { ok = ok, detail = detail } end)
for _ = 1, 200 do tick(); if result then break end end
assert(result and not result.ok and result.detail:find("did not arrive") and result.detail:find("need 3 x Base.Paper"),
    "a craft whose ingredients never come fails with what is missing: " .. tostring(result and result.detail))
arrived = true

-- Diagnose says what blocks a craft as the game's craft logic sees it.
local knowsForm, paperOk = false, false
player.getKnownRecipes = function() return { contains = function(_, r) return r == "Form" and knowsForm end } end
player.getPerkLevel = function() return 2 end
recipe.getName = function() return "Form" end
recipe.needToBeLearn = function() return true end
recipe.getRequiredSkillCount = function() return 1 end
recipe.getRequiredSkill = function() return { getLevel = function() return 4 end,
    getPerk = function() return { getName = function() return "Carpentry" end } end } end
local newLogic = HandcraftLogic.new
HandcraftLogic.new = function()
    local logic = newLogic()
    logic.isInputSatisfied = function(_, i) return paperOk or i:getIntAmount() ~= 3 end
    logic.canPerformCurrentRecipe = function() return knowsForm and paperOk end
    return logic
end
local d = C.Diagnose(player, "Test.Form")
local why = table.concat(d.reasons, "; ")
assert(not d.ready and why:find("does not know the recipe", 1, true) and why:find("needs Carpentry 4 (you have 2)", 1, true)
    and why:find("missing 3 x", 1, true), why)
knowsForm, paperOk = true, true
recipe.getRequiredSkillCount = function() return 0 end
d = C.Diagnose(player, "Test.Form")
assert(d.ready and #d.reasons == 0, table.concat(d.reasons, "; "))
recipe.needToBeLearn = function() return false end
knowsForm = false
assert(C.Diagnose(player, "Test.Form").reasons[1] ~= "your character does not know the recipe", "a recipe that needs no learning is never 'unknown'")
io.write("PASS: crafting gives only missing ingredients, reports fluids, takes back exactly what it gave, crafts once, waits for late ingredients, names missing ones, restarts only an interrupted craft, and diagnoses what blocks a craft\n")
