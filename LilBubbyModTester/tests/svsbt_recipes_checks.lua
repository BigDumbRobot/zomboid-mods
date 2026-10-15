-- Offline checks for the Spy vs Spy "what each trap costs" panel: it reads
-- the recipes and the player's inventory only, and never changes either.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
require = function() end
print = function() end

local function list(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end
local function script(name) return { getFullName = function() return name end } end
local function input(names, amount)
    local items = {}
    for _, n in ipairs(names) do items[#items + 1] = script(n) end
    return { getPossibleInputItems = function() return list(items) end, getIntAmount = function() return amount end,
        getPossibleInputFluids = function() return list({}) end }
end

local carried = { ["Base.Nails"] = 4, ["Base.Plank"] = 1 }
local removed = false
local player = { getInventory = function() return {
    getCountTypeRecurse = function(_, fullType) return carried[fullType] or 0 end,
    Remove = function() removed = true end,
    AddItem = function() removed = true end,
} end, getKnownRecipes = function() return { contains = function(_, name) return name == "CraftNailBoard" end } end }

local recipes = {
    ["SVSBT.CraftNailBoard"] = { getInputs = function() return list({ input({ "Base.Plank" }, 1),
        input({ "Base.Nails", "Base.Screws" }, 4) }) end,
        characterHasRequiredSkills = function() return true end },
    ["SVSBT.CraftTripwire"] = { getInputs = function() return list({ input({ "Base.Twine" }, 2) }) end,
        characterHasRequiredSkills = function() return false end },
}
ScriptManager = { instance = { getCraftRecipe = function(_, name) return recipes[name] end } }
function getScriptManager() return { FindItem = function(_, fullType)
    return { getDisplayName = function() return fullType:gsub("^Base%.", "") end, getIcon = function() return "Icon" end }
end } end
SVSBT = { Shared = { Module = "SVSBT", KindRecipe = { nailboard = "CraftNailBoard", tripwire = "CraftTripwire",
    missing = "CraftGone" } },
    Client = { KindName = function(kind) return kind:upper() end } }

dofile(root .. "client/SVSBTRecipeUI.lua")
local U = SVSBTRecipeUI
assert(U.Window == nil, "no game UI offline, but the data still loads")

local traps = U.Data(player)
assert(#traps == 3, "every trap kind is listed")
local byKind = {}
for _, trap in ipairs(traps) do byKind[trap.kind] = trap end

local board = byKind.nailboard
assert(board.name == "NAILBOARD" and board.known and board.skills, "the trap's own name, recipe knowledge and skills")
assert(#board.inputs == 2, "every ingredient line is listed")
assert(board.inputs[1].name == "Plank" and board.inputs[1].need == 1 and board.inputs[1].have == 1, "plank line")
local nails = board.inputs[2]
assert(nails.need == 4 and nails.have == 4 and nails.alternatives[1] == "Screws",
    "alternatives are named on one line, and both kinds count towards what you carry")
assert(board.ready, "with items, knowledge and skills the trap is ready to craft")

local tripwire = byKind.tripwire
assert(tripwire.known == false and tripwire.skills == false and tripwire.hasItems == false and not tripwire.ready,
    "an unknown recipe with no twine and low skills is not ready")
assert(byKind.missing.problem:find("not registered"), "a recipe this build does not have is reported, not an error")

local text = U.Text(player)
assert(text:find("READY: NAILBOARD") and text:find("4/4 Nails") and text:find("0/2 Twine"),
    "the report says the same as the panel: " .. text)
assert(not removed, "nothing is added to or taken from the inventory")
io.write("PASS: the trap cost panel reads every recipe's ingredients, counts what you carry, names alternatives, reports unknown recipes and changes nothing\n")
