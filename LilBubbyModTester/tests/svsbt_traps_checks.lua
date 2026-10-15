-- Offline checks for the Spy vs Spy trap tests (shared/SVSBTTest_Traps.lua):
-- one entry per recipe, the magazine chosen for each, the server topping up
-- the inventory (with a full water bucket), placing a car with its key and a
-- full tank or a mailbox, confirming the craft and cleaning everything up.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
isServer = function() return false end
isClient = function() return false end

local function list(t)
    return { size = function() return #t end, get = function(_, i) return t[i + 1] end }
end

-- Inventory
local items = {}
-- Skill books: "Base.BookCooking3" trains Cooking levels 5-6 (vanilla's ranges).
local BOOK_RANGE = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 }, { 9, 10 } }
local function item(fullType)
    local data = {}
    local fluid = { amount = 0, capacity = 10 }
    local skill, volume = fullType:match("^Base%.Book(%a+)(%d)$")
    local range = volume and BOOK_RANGE[tonumber(volume)]
    return { fullType = fullType,
        getSkillTrained = range and function() return skill end or nil,
        getLvlSkillTrained = range and function() return range[1] end or nil,
        getMaxLevelTrained = range and function() return range[2] end or nil,
        getFullType = function() return fullType end,
        getModData = function() return data end, hasModData = function() return next(data) ~= nil end,
        getDisplayName = function() return fullType end,
        getFluidContainer = function() return {
            addFluid = function(_, f, n) fluid.kind = f; fluid.amount = fluid.amount + n end,
            getCapacity = function() return fluid.capacity end, getAmount = function() return fluid.amount end,
            contains = function(_, f) return fluid.kind == f end } end,
        fluid = fluid }
end
local inventory = {
    getItems = function() return list(items) end,
    AddItem = function(_, it) items[#items + 1] = it; return it end,
    Remove = function(_, it) for i, v in ipairs(items) do if v == it then table.remove(items, i) return end end end,
    getCountTypeRecurse = function(_, fullType)
        local n = 0
        for _, it in ipairs(items) do if it.fullType == fullType then n = n + 1 end end
        return n
    end,
    getAllTypeRecurse = function(_, fullType)
        local found = {}
        for _, it in ipairs(items) do if it.fullType == fullType then found[#found + 1] = it end end
        return list(found)
    end,
}
instanceItem = item

local known, perks, modData = {}, { Woodwork = 0, Cooking = 4 }, {}
SkillBook = { Cooking = { perk = { name = "Cooking" } } }
Perks = { Farming = { name = "Farming" } }
local player = {
    getInventory = function() return inventory end,
    getModData = function() return modData end,
    getKnownRecipes = function() return { contains = function(_, r) return known[r] == true end } end,
    learnRecipe = function(_, r) known[r] = true end,
    getPerkLevel = function(_, perk) return perks[perk.name] end,
    getXp = function() return { getXP = function() return 0 end } end,
    getX = function() return 10 end, getY = function() return 10 end, getZ = function() return 0 end,
}
local globalData = {}
ModData = { getOrCreate = function(key) globalData[key] = globalData[key] or {}; return globalData[key] end }
addXpNoMultiplier = function(_, perk) perks[perk.name] = perk.target end

-- World
local squares, vehicles, placed = {}, {}, {}
local function square(x, y, z)
    local key = x .. "," .. y
    if not squares[key] then
        local objects = {}
        squares[key] = { x = x, y = y, objects = objects,
            getX = function() return x end, getY = function() return y end,
            isFree = function() return not (x == 12 and y == 10) end, -- one blocked tile beside the player
            getMovingObjects = function() return list({}) end, getVehicleContainer = function() return nil end,
            getObjects = function() return list(objects) end,
            AddTileObject = function(_, o) objects[#objects + 1] = o; placed[#placed + 1] = o end,
            transmitRemoveItemFromSquare = function(_, o)
                for i, v in ipairs(objects) do if v == o then table.remove(objects, i) end end
            end }
    end
    return squares[key]
end
getCell = function() return { getGridSquare = function(_, x, y, z) return square(x, y, z) end,
    getVehicles = function() return list(vehicles) end } end
IsoObject = { new = function(sq, sprite)
    local data = {}
    return { sprite = sprite, getContainer = function() return {} end, getModData = function() return data end,
        hasModData = function() return next(data) ~= nil end }
end }
IsoDirections = { S = "S" }
local removedVehicles = 0
addVehicleDebug = function(script, dir, skin, sq)
    local data, fuel = {}, { amount = 3 }
    local vehicle = { script = script, square = sq,
        repair = function() end, getId = function() return 7 end,
        getModData = function() return data end, transmitModData = function() end,
        getPartById = function(_, id) return id == "GasTank" and {
            getContainerCapacity = function() return 55 end,
            getContainerContentAmount = function() return fuel.amount end,
            setContainerContentAmount = function(_, n) fuel.amount = n end } or nil end,
        transmitPartModData = function() end,
        createVehicleKey = function() return item("Base.CarKey") end,
        permanentlyRemove = function(self)
            removedVehicles = removedVehicles + 1
            for i, v in ipairs(vehicles) do if v == self then table.remove(vehicles, i) end end
        end }
    vehicles[#vehicles + 1] = vehicle
    return vehicle
end
getVehicleById = function(id) return vehicles[1] end

-- Scripts
local Water = { getDisplayName = function() return "Water" end }
local Cleaning = { getDisplayName = function() return "Cleaning Liquid" end,
    getFluidTypeString = function() return "CleaningLiquid" end }
ResourceType = { Fluid = "fluid" }
local function input(names, amount, fluid)
    local scripts = {}
    for _, n in ipairs(names) do scripts[#scripts + 1] = { getFullName = function() return n end } end
    return { getPossibleInputItems = function() return list(scripts) end, getIntAmount = function() return amount end,
        hasConsumeFromItem = function() return fluid ~= nil end,
        getConsumeFromItemScript = function() return { getResourceType = function() return "fluid" end,
            getPossibleInputFluids = function() return list({ fluid }) end } end }
end
local Woodwork = { name = "Woodwork", target = 1, getName = function() return "Carpentry" end,
    getTotalXpForLevel = function() return 75 end }
local recipes = {
    ["SVSBoobyTraps.SVSBT_CraftWaterBucketTrap"] = { inputs = { input({ "Base.Bucket" }, 1, Water),
        input({ "Base.Nails" }, 1), input({ "Base.HammerStone", "Base.Hammer" }, 1) }, skill = Woodwork },
    ["SVSBoobyTraps.SVSBT_CraftNailBoard"] = { inputs = { input({ "Base.Nails" }, 8) } },
    ["SVSBoobyTraps.SVSBT_ForgeBearTrap"] = { inputs = {} },
    ["SVSBoobyTraps.SVSBT_AssembleIgnitionCharge"] = { inputs = { input({ "Base.MetalPipe" }, 1) } },
    ["SVSBoobyTraps.SVSBT_AssembleExplosiveParcel"] = { inputs = { input({ "Base.PaperBag" }, 1) } },
    ["SVSBoobyTraps.SVSBT_PrepareBiologicalAgent"] = { inputs = { input({ "Base.EmptyJar" }, 1) } },
    -- Any container of cleaning liquid: the game lists every item as possible.
    ["SVSBoobyTraps.SVSBT_CultureBiologicalSample"] = { inputs = { input({ "Base.FishGuts" }, 1),
        input({ "Base.Axe", "Base.Pot", "Base.CleaningLiquid2" }, 1, Cleaning) } },
}
for _, r in pairs(recipes) do
    r.getInputs = function() return list(r.inputs) end
    r.getOutputs = function() error("outputs are read from the mod's items offline") end
    r.getRequiredSkillCount = function() return r.skill and 1 or 0 end
    r.getRequiredSkill = function() return { getPerk = function() return r.skill end, getLevel = function() return 1 end } end
end
ScriptManager = { instance = { getCraftRecipe = function(_, name) return recipes[name] end } }
getScriptManager = function() return { FindItem = function(_, t) return { getDisplayName = function() return t end } end } end

SVSBT = { Shared = { Module = "SVSBoobyTraps",
    Kind = { ExplosiveMailbox = "explosive_mailbox", AnthraxDocument = "anthrax_document" },
    VehicleKinds = { ignition_charge = true },
    Item = { WaterBucketTrap = "SVSBoobyTraps.WaterBucketTrap", NailBoard = "SVSBoobyTraps.NailBoard", AnthraxAgent = "SVSBoobyTraps.AnthraxAgent",
        IgnitionCharge = "SVSBoobyTraps.IgnitionCharge", ExplosiveParcel = "SVSBoobyTraps.ExplosiveParcel",
        BearTrap = "SVSBoobyTraps.BearTrap", SealedBiologicalSample = "SVSBoobyTraps.SealedBiologicalSample" },
    KindRecipe = { water_bucket = "SVSBT_CraftWaterBucketTrap", nail_board = "SVSBT_CraftNailBoard",
        bear_trap = "SVSBT_ForgeBearTrap", ignition_charge = "SVSBT_AssembleIgnitionCharge",
        explosive_mailbox = "SVSBT_AssembleExplosiveParcel",
        anthrax_document = "SVSBT_PrepareBiologicalAgent", biological_sample = "SVSBT_PrepareBiologicalAgent" },
    MagazineRecipe = {
        ["SVSBoobyTraps.MadMagazine1"] = { "SVSBT_CraftWaterBucketTrap", "SVSBT_CraftTripWire" },
        ["SVSBoobyTraps.MadMagazine2"] = { "SVSBT_CraftNailBoard", "SVSBT_ForgeBearTrap" },
        ["SVSBoobyTraps.MadMagazine3"] = { "SVSBT_ForgeBearTrap" },
        ["SVSBoobyTraps.MadMagazine5"] = { "SVSBT_PrepareBiologicalAgent", "SVSBT_CultureBiologicalSample" } },
    FeatureEnabledForKind = function(kind) return kind ~= "nail_board" end } }

dofile(root .. "shared/SVSBTTest_Traps.lua")
local T = SVSBTTest.Traps

-- One entry per trap: the sample is cultured by its own recipe, although the
-- mod's KindRecipe names the anthrax recipe for it.
local traps = T.List()
assert(#traps == 7, "one test per trap: " .. #traps)
assert(T.ByRecipe("SVSBT_PrepareBiologicalAgent").kind == "anthrax_document"
    and #T.ByRecipe("SVSBT_PrepareBiologicalAgent").kinds == 1)
assert(T.ByRecipe("SVSBT_CultureBiologicalSample").kind == "biological_sample")
assert(T.Magazine("SVSBT_CultureBiologicalSample") == "SVSBoobyTraps.MadMagazine5")
assert(T.Magazine("SVSBT_ForgeBearTrap") == "SVSBoobyTraps.MadMagazine3", "the issue dedicated to the bear trap")
assert(T.Magazine("SVSBT_CraftWaterBucketTrap") == "SVSBoobyTraps.MadMagazine1")
assert(not T.Enabled(T.ByRecipe("SVSBT_CraftNailBoard")), "sandbox switch is respected")
assert(T.Deposit(player, { recipe = "SVSBT_CraftNailBoard" }).status == "BLOCKED")
assert(T.Deposit(player, { recipe = "Nope" }).error, "unknown recipes are refused")

-- Water bucket: the player carries one nail and an empty bucket.
inventory:AddItem(item("Base.Nails"))
local ownBucket = inventory:AddItem(item("Base.Bucket"))
local reply = T.Deposit(player, { recipe = "SVSBT_CraftWaterBucketTrap" })
assert(not reply.error, tostring(reply.error))
assert(reply.magazine == "SVSBoobyTraps.MadMagazine1", "an unknown recipe comes with its magazine")
assert(reply.known == false)
assert(T.Learned(player).known == false and T.Learned(player).magazine == "SVSBoobyTraps.MadMagazine1", "not read yet")
assert(T.Learned(player, { clientKnows = false }).known == false, "nothing is taught while neither side knows it")
known.SVSBT_CraftWaterBucketTrap = true
assert(T.Learned(player).known == true, "the server sees the recipe once the magazine is read")
known.SVSBT_CraftWaterBucketTrap = nil
-- The client read it but the server's read history has not caught up: the
-- mod's own grant runs first, then the server learns it.
local granted = 0
SVSBT.Server = { Service = { LearnRecipes = function() granted = granted + 1 end } }
assert(T.Learned(player, { clientKnows = true }).known == true and granted == 1, "the server catches up with the client")
-- Known on the server only (the mod's self-heal): the server's list is sent.
local syncs = 0
player.getUsername = function() return "Tester" end
ModData.getOrCreate(T.STATE).Tester = T.State(player)
isServer = function() return true end
sendSyncPlayerFields = function() syncs = syncs + 1 end
sendAddItemToContainer = function() end
assert(T.Learned(player, { clientKnows = false }).synced == true and syncs == 1, "the client is sent the server's recipes")
isServer = function() return false end
ModData.getOrCreate(T.STATE).Tester = nil
SVSBT.Server = nil
known.SVSBT_CraftWaterBucketTrap = nil
assert(reply.raised[1] == "Carpentry 1", "the recipe's skill is raised")
local givenText = table.concat(reply.given, "; ")
assert(givenText:find("1 x Base.Bucket (full of Water)", 1, true), givenText)
assert(not givenText:find("Nails", 1, true), "a carried nail is enough: " .. givenText)
assert(givenText:find("Base.Hammer", 1, true) and not givenText:find("HammerStone", 1, true), "the ordinary tool is given")
local newBucket
for _, it in ipairs(items) do if it.fullType == "Base.Bucket" and it ~= ownBucket then newBucket = it end end
assert(newBucket and newBucket.fluid.amount == 10, "the given bucket is full")
assert(ownBucket.fluid.amount == 0, "the player's own bucket is not touched")
assert(not reply.vehicle and not reply.mailbox, "a floor trap needs no world object")

-- The player crafts: the ingredients are used and the trap appears.
assert(not T.Verify(player).crafted, "not crafted yet")
inventory:Remove(newBucket)
inventory:AddItem(item("SVSBoobyTraps.WaterBucketTrap"))
local check = T.Verify(player)
assert(check.crafted and check.count == 1, "the crafted trap is seen")

-- A new test replaces the last one and cleans it up first.
reply = T.Deposit(player, { recipe = "SVSBT_AssembleIgnitionCharge" })
assert(reply.replaced == "SVSBT_CraftWaterBucketTrap")
assert(inventory:getCountTypeRecurse("SVSBoobyTraps.WaterBucketTrap") == 0, "the earlier crafted trap is removed")
assert(inventory:getCountTypeRecurse("Base.Nails") == 1, "the player's own nail stays")
assert(reply.vehicle and reply.vehicle.key and reply.vehicle.fuel == 55, "a car with its key and a full tank")
assert(#vehicles == 1 and vehicles[1].script == T.VEHICLE)
assert(inventory:getCountTypeRecurse("Base.CarKey") == 1, "the key is in the inventory")

-- Mailbox trap: the car goes, a mailbox appears beside the player.
reply = T.Deposit(player, { recipe = "SVSBT_AssembleExplosiveParcel" })
assert(removedVehicles == 1 and #vehicles == 0, "the test car is removed")
assert(inventory:getCountTypeRecurse("Base.CarKey") == 0, "its key is removed")
assert(reply.mailbox and #placed == 1 and placed[1].sprite == T.MAILBOX_SPRITE, "a mailbox is placed")
local dx, dy = math.abs(reply.mailbox.x - 10), math.abs(reply.mailbox.y - 10)
assert(math.max(dx, dy) == 1 and not (reply.mailbox.x == 12), "right beside the player, on a free square")

-- Cleanup leaves only what the player brought.
local cleaned = T.Cleanup(player)
assert(cleaned.mailbox == 1 and #square(reply.mailbox.x, reply.mailbox.y, 0).objects == 0, "the mailbox is removed")
assert(#items == 2, "only the player's own nail and bucket remain: " .. #items)
assert(T.State(player) == nil and not T.Verify(player).crafted)
assert(T.Learned(player).error, "no test, nothing to have learned")

-- Known already: the magazine still comes, since the client may not know it.
known.SVSBT_CraftWaterBucketTrap = true
reply = T.Deposit(player, { recipe = "SVSBT_CraftWaterBucketTrap" })
assert(reply.known == true and reply.magazine == "SVSBoobyTraps.MadMagazine1", "a known recipe still comes with its magazine")
assert(inventory:getCountTypeRecurse("SVSBoobyTraps.MadMagazine1") == 1)
known.SVSBT_CraftWaterBucketTrap = nil
T.Cleanup(player)
assert(inventory:getCountTypeRecurse("SVSBoobyTraps.MadMagazine1") == 0, "the magazine is cleaned up")

-- Anthrax: a skill book the player can read, not a newspaper. Cooking 4 is
-- past volume 1 and 2 but volume 3 (levels 5-6) is readable.
reply = T.Deposit(player, { recipe = "SVSBT_PrepareBiologicalAgent" })
assert(reply.document == "Base.BookCooking3", "a readable skill book: " .. tostring(reply.document))
assert(inventory:getCountTypeRecurse("Base.BookCooking3") == 1 and #reply.notes == 0, table.concat(reply.notes, "; "))
assert(T.INSTRUCTIONS.anthrax_document.set:find("skill book", 1, true))
T.Cleanup(player)
assert(inventory:getCountTypeRecurse("Base.BookCooking3") == 0, "the book is cleaned up")
perks.Cooking = nil
perks.Farming = 10
SkillBook.Farming = nil
local book = T.SkillBook({ getPerkLevel = function(_, perk) return perk.name == "Farming" and 10 or 0 end })
assert(book.fullType == "Base.BookCooking1", "the first readable volume, by the Perks name when SkillBook lacks it")
perks.Cooking = 4

-- The synopsis: one for every trap, naming the magazine and the trap.
for kind in pairs(T.INSTRUCTIONS) do assert(T.SYNOPSIS[kind], "a synopsis for " .. kind) end
local lines = T.Synopsis(T.ByRecipe("SVSBT_AssembleIgnitionCharge"), "MAD Magazine No. 6", "Ignition Charge")
assert(#lines == 6 and lines[1]:find("ignition", 1, true), lines[1])
assert(lines[2]:find("MAD Magazine No. 6", 1, true) and lines[2]:find("car beside you", 1, true), lines[2])
assert(lines[3]:find("craft the Ignition Charge", 1, true), lines[3])
assert(T.Synopsis(T.ByRecipe("SVSBT_PrepareBiologicalAgent"))[2]:find("skill book", 1, true))

-- Culture Biological Sample: its own ingredients, a full bottle of cleaning liquid.
reply = T.Deposit(player, { recipe = "SVSBT_CultureBiologicalSample" })
givenText = table.concat(reply.given, "; ")
assert(givenText:find("1 x Base.CleaningLiquid2 (full of Cleaning Liquid)", 1, true), givenText)
assert(givenText:find("Base.FishGuts", 1, true) and not givenText:find("Base.Axe", 1, true), givenText)
assert(inventory:getCountTypeRecurse("SVSBoobyTraps.SealedBiologicalSample") == 0, "the sample is crafted, not given")
assert(T.Output("SVSBT_CultureBiologicalSample") == "SVSBoobyTraps.SealedBiologicalSample")
T.Cleanup(player)

-- Setting and setting off: the server follows the mod's own registry.
local registry = { traps = { ["TRAP-1"] = { id = "TRAP-1", kind = "water_bucket", owner = "Tester", state = "armed" } },
    documents = {} }
local worldRemoved = 0
SVSBT.Shared.Username = function() return "Tester" end
SVSBT.Shared.Kind.BearTrap = "bear_trap"
SVSBT.Shared.WorldItemAt = function(x, y, z, id)
    return { getSquare = function() return { transmitRemoveItemFromSquare = function() worldRemoved = worldRemoved + 1 end,
        removeWorldObject = function() end } end }
end
SVSBT.Server = { Registry = { Data = registry, Initialize = function() end,
    RemoveTrap = function(id) registry.traps[id] = nil end,
    RemoveDocument = function(id) registry.documents[id] = nil end } }
T.Deposit(player, { recipe = "SVSBT_CraftWaterBucketTrap" })
assert(T.Status(player).stage == "none", "a trap set before the test is not this test's trap")
registry.traps["TRAP-2"] = { id = "TRAP-2", kind = "water_bucket", owner = "Tester", state = "armed", armPending = true,
    triggerCount = 0, x = 1, y = 1, z = 0, worldItemId = 5 }
assert(T.Status(player).stage == "placed", "placed, waiting for the player to step away")
registry.traps["TRAP-2"].armPending = nil
assert(T.Status(player).stage == "set", "armed")
-- Picked back up rather than set off: back to setting it.
local picked = registry.traps["TRAP-2"]
registry.traps["TRAP-2"] = nil
local back = inventory:AddItem(item("SVSBoobyTraps.WaterBucketTrap"))
assert(T.Status(player).stage == "none", "a trap picked back up is not a detonation")
inventory:Remove(back)
registry.traps["TRAP-3"] = picked
picked.id = "TRAP-3"
assert(T.Status(player).stage == "set")
picked.triggerCount = 1
assert(T.Status(player).stage == "detonated", "a trigger counts as the detonation")
assert(T.Status(player).stage == "detonated", "and stays detonated")
cleaned = T.Cleanup(player)
assert(cleaned.traps == 1 and registry.traps["TRAP-3"] == nil and worldRemoved == 1, "the set trap and its ground item are removed")
assert(registry.traps["TRAP-1"], "a trap set before the test is left alone")
-- Vehicle alarms count their alarms; immobilizers their lock-out.
T.Deposit(player, { recipe = "SVSBT_AssembleIgnitionCharge" })
registry.traps["TRAP-4"] = { id = "TRAP-4", kind = "ignition_charge", owner = "Tester", state = "armed" }
assert(T.Status(player).stage == "set")
registry.traps["TRAP-4"].state = "triggered"
assert(T.Status(player).stage == "detonated", "a scheduled explosion counts")
T.Cleanup(player)
-- A sample: sealed on the floor, opened, then it goes off by exposing someone.
registry.exposures = {}
T.Deposit(player, { recipe = "SVSBT_CultureBiologicalSample" })
registry.traps["TRAP-5"] = { id = "TRAP-5", kind = "biological_sample", owner = "Tester", state = "placed" }
assert(T.Status(player).stage == "sealed", "set but not opened")
registry.traps["TRAP-5"].state, registry.traps["TRAP-5"].armPending = "armed", true
assert(T.Status(player).stage == "placed", "opened, waiting for the player to step away")
registry.traps["TRAP-5"].armPending = nil
assert(T.Status(player).stage == "set")
registry.exposures.Tester = { sourceRecordId = "TRAP-5" }
assert(T.Status(player).stage == "detonated", "an exposure counts as the detonation")
T.Cleanup(player)
assert(T.INSTRUCTIONS.biological_sample.open)
assert(T.INSTRUCTIONS.water_bucket.set:find("2 tiles away", 1, true) and T.INSTRUCTIONS.remote_immobilizer.detonate)

io.write("PASS: one test per trap (the sample by its own recipe), magazine always given and recipe knowledge synced between server and client, readable skill book for anthrax, synopsis for every trap, cleaning liquid bottle, sealed/opened/exposure tracking, dedicated magazine, sandbox switches, top-up with a full water bucket, skills, car with key and full tank, mailbox beside you, verify, set/placed/detonated tracking, replace and cleanup of set traps\n")
