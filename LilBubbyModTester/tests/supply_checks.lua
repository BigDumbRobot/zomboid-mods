-- Offline checks for LilBubbySupply: what the depot stocks is read from the
-- enabled mods' recipes, the crates go on free outdoor squares by the spawn
-- point, and a crate is topped up again after items are taken.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local minute = {}
Events = { EveryOneMinute = { Add = function(fn) minute[#minute + 1] = fn end }, OnClientCommand = { Add = function() end } }
function isServer() return true end
function isClient() return false end
local log = {}
print = function(text) log[#log + 1] = tostring(text) end
local function list(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end

-- Mods and recipes ---------------------------------------------------------
local mods = { "\\SVSBoobyTraps", "TheWhisperers", "SomeoneElsesMod" }
function getActivatedMods() return list(mods) end
ResourceType = { Fluid = "Fluid", Item = "Item" }
local WATER = { getFluidTypeString = function() return "Water" end }
local function script(name) return { getFullName = function() return name end } end
local function input(names, amount, opts)
    opts = opts or {}
    local items = {}
    for _, n in ipairs(names) do items[#items + 1] = script(n) end
    return {
        getPossibleInputItems = function() return list(items) end,
        getIntAmount = function() return amount end,
        isKeep = function() return opts.keep == true end,
        isTool = function() return opts.tool == true end,
        hasConsumeFromItem = function() return opts.fluid ~= nil end,
        getConsumeFromItemScript = function()
            return { getResourceType = function() return ResourceType.Fluid end,
                getPossibleInputFluids = function() return list({ opts.fluid }) end }
        end,
    }
end
local function recipe(mod, inputs) return { getModID = function() return mod end, getInputs = function() return list(inputs) end } end
local recipes = {
    recipe("SVSBoobyTraps", { input({ "Base.Nails" }, 4), input({ "Base.Plank" }, 2), input({ "Base.Hammer", "Base.ClubHammer" }, 1, { keep = true }) }),
    recipe("\\TheWhisperers", { input({ "Base.Twine", "Base.Nails" }, 3), input({ "Base.BucketEmpty" }, 1, { fluid = WATER }),
        input({ "Base.ClubHammer", "Base.Hammer" }, 1, { tool = true }), input({}, 1) }),
    recipe("SomeoneElsesMod", { input({ "Base.Gold" }, 50) }),
    recipe("NotEnabled", { input({ "Base.Silver" }, 50) }),
}
function getScriptManager() return { getAllCraftRecipes = function() return list(recipes) end } end

-- World ---------------------------------------------------------------------
local spawn = "12067,6801,0"
function getServerOptions() return { getOption = function(_, name) return name == "SpawnPoint" and spawn or "Muldraugh, KY" end } end
local store = {}
ModData = { getOrCreate = function(tag) store[tag] = store[tag] or {}; return store[tag] end }
local squares, loaded, blocked = {}, true, {}
local function square(x, y, z)
    local key = x .. "," .. y .. "," .. z
    if not squares[key] then
        local objects = {}
        squares[key] = {
            x = x, y = y, objects = objects,
            isFree = function() return not blocked[key] end,
            isOutside = function() return x < 12080 end, -- everything east of 12080 is indoors
            getMovingObjects = function() return list({}) end,
            getVehicleContainer = function() return nil end,
            getObjects = function() return list(objects) end,
            AddTileObject = function(_, object) objects[#objects + 1] = object end,
        }
    end
    return squares[key]
end
function getCell() return { getGridSquare = function(_, x, y, z) return loaded and square(x, y, z) or nil end } end
local sent, transmitted = 0, 0
function sendAddItemToContainer() sent = sent + 1 end
ItemContainer = { new = function(kind)
    local items = {}
    return { kind = kind, items = items, getItems = function() return list(items) end,
        AddItem = function(_, item) items[#items + 1] = item; return item end,
        setCapacity = function(self, n) self.capacity = n end, setExplored = function(self, b) self.explored = b end }
end }
IsoObject = { new = function(sq, sprite, name)
    local object = { sq = sq, sprite = sprite, name = name, modData = {} }
    function object:getContainer() return self.container end
    function object:setContainer(c) self.container = c end
    function object:createContainersFromSpriteProperties() end -- this sprite carries no container of its own
    function object:getModData() return self.modData end
    function object:hasModData() for _ in pairs(self.modData) do return true end return false end
    function object:transmitCompleteItemToClients() transmitted = transmitted + 1 end
    return object
end }
local unmakeable = {}
function instanceItem(fullType)
    if unmakeable[fullType] then error("no such item") end
    local fluids = { amount = 0, holds = nil }
    function fluids:getCapacity() return 10 end
    function fluids:getAmount() return self.amount end
    function fluids:addFluid(fluid, amount) self.holds = fluid; self.amount = self.amount + amount end
    function fluids:contains(fluid) return self.holds == fluid end
    return { getFullType = function() return fullType end, getFluidContainer = function() return fluids end }
end

dofile(root .. "shared/LilBubbySupply.lua")
local S = LilBubbySupply
assert(#minute == 1, "the server restocks on the game's minute tick")

-- What is stocked -----------------------------------------------------------
assert(#S.Recipes() == 2, "only recipes of enabled mods on the list count, with or without the leading backslash")
local needs, by = S.Needs(), {}
for _, need in ipairs(needs) do by[need.key] = need end
assert(by["Base.Nails"].count == (4 + 3) * S.CRAFTS, "an input that accepts an item already stocked reuses it, and amounts add up")
assert(by["Base.Twine"] == nil, "so the alternative is not stocked as well")
assert(by["Base.Plank"].count == 2 * S.CRAFTS)
assert(by["Base.Hammer"].count == S.TOOLS and by["Base.ClubHammer"] == nil, "a kept tool is stocked a couple of times, once per kind")
assert(by["Base.BucketEmpty|Water"].count == S.FLUIDS and by["Base.BucketEmpty|Water"].fluid == WATER, "a fluid input is stocked as full containers")
assert(by["Base.Gold"] == nil and by["Base.Silver"] == nil, "other mods' recipes are ignored")
assert(#needs == 4)
S.MAX = 30
assert(S.Needs()[3].key == "Base.Nails" and S.Needs()[3].count == 30, "one item type never exceeds MAX")
S.MAX = 60

-- Where ---------------------------------------------------------------------
local anchor = S.Anchor()
assert(anchor.x == 12067 and anchor.y == 6801 and anchor.z == 0, "the anchor is the server's SpawnPoint")
spawn = "0,0,0"
assert(S.Anchor() == S.DEFAULTS["Muldraugh, KY"], "no SpawnPoint: this map's default")
spawn = "12067,6801,0"

loaded = false
local crates, why = S.Crates()
assert(crates == nil and why:find("not loaded"), "nothing is placed while the ground is not loaded")
local added, failed = S.Restock()
assert(added == 0 and #failed == 1 and #store[S.TAG].crates == 0)
loaded = true
blocked["12069,6799,0"] = true
crates = S.Crates()
assert(#crates == S.CRATES and #store[S.TAG].crates == S.CRATES and transmitted == S.CRATES, "the depot is laid out once the ground loads")
for _, spot in ipairs(store[S.TAG].crates) do
    assert(spot.x < 12080, "never indoors")
    assert(not (spot.x == 12069 and spot.y == 6799), "never on a blocked square")
    assert((spot.x - 12067) % 2 == 0 and (spot.y - 6801) % 2 == 0 and not (spot.x == 12067 and spot.y == 6801), "every other tile, never the spawn square")
    assert(math.abs(spot.x - 12067) <= S.RADIUS and math.abs(spot.y - 6801) <= S.RADIUS)
end
local first = crates[1].object
assert(first.sprite == S.SPRITE and first.container.kind == S.CONTAINER and first.container.capacity == S.CAPACITY and first.container.explored == true)
assert(#S.Crates() == S.CRATES and transmitted == S.CRATES, "asking again places nothing new")

-- Stocking --------------------------------------------------------------------
local function count(index, fullType)
    local n = 0
    for _, item in ipairs(S.Crates()[index].object.container.items) do if item.getFullType() == fullType then n = n + 1 end end
    return n
end
added, failed = S.Restock(1000)
local expected = 0
for _, need in ipairs(needs) do expected = expected + need.count end
assert(added == expected and sent == expected and #failed == 0, "a first fill stocks every need and tells the clients")
-- Needs sorted by key: bucket|Water, Hammer, Nails, Plank -> crates 1 to 4.
assert(count(1, "Base.BucketEmpty") == S.FLUIDS and count(2, "Base.Hammer") == S.TOOLS and count(3, "Base.Nails") == 35 and count(4, "Base.Plank") == 10)
assert(S.Crates()[1].object.container.items[1].getFluidContainer():contains(WATER), "fluid containers arrive full")
assert(S.Restock(1000) == 0, "a full depot is left alone")

local nails = S.Crates()[3].object.container.items
for _ = 1, 9 do table.remove(nails) end
S.Crates()[1].object.container.items[1].getFluidContainer().amount = 2 -- a player poured most of a bucket out
assert(S.Restock(1000) == 10 and count(3, "Base.Nails") == 35, "what was taken is replaced, a part-used fluid container with a full one")

for _ = 1, 20 do table.remove(nails) end
assert(S.Restock(6) == 6 and count(3, "Base.Nails") == 21, "one pass adds no more than its limit")
minute[1]()
assert(count(3, "Base.Nails") == 35, "the minute tick finishes the job")

-- A crate that vanishes comes back, and is filled again.
local gone = store[S.TAG].crates[4]
local sq = square(gone.x, gone.y, gone.z)
table.remove(sq.objects)
assert(#S.Crates() == S.CRATES and transmitted == S.CRATES + 1, "a missing crate is put back on its own square")
assert(count(4, "Base.Plank") == 0)
minute[1]()
assert(count(4, "Base.Plank") == 10)

-- An item the game cannot make is reported once, and the rest still arrive.
unmakeable["Base.Plank"] = true
table.remove(S.Crates()[4].object.container.items)
table.remove(S.Crates()[3].object.container.items)
log = {}
minute[1](); minute[1]()
local reports = 0
for _, line in ipairs(log) do if line:find("not stocked: Base.Plank", 1, true) then reports = reports + 1 end end
assert(reports == 1 and count(3, "Base.Nails") == 35 and count(4, "Base.Plank") == 9)

-- Where, for the showcase.
local where = S.Where()
assert(where.anchor.x == 12067 and #where.crates == S.CRATES)

-- A client only asks; it never places or stocks anything.
minute = {}
function isServer() return false end
function isClient() return true end
LilBubbySupply = nil
dofile(root .. "shared/LilBubbySupply.lua")
assert(#minute == 0, "a multiplayer client runs no depot of its own")

io.stdout:write("supply_checks: ok\n")
