-- Spy vs Spy trap tests: one per trap recipe. The server puts what the craft
-- needs in the player's inventory (topping up what they already carry), and
-- places the world object the trap is used on beside them: a car (with its
-- key and a full tank) for the vehicle devices, a mailbox for the parcel.
-- The player crafts the trap; the server then confirms it is in their
-- inventory. Cleanup removes everything the test gave or placed.
--
-- Deposit, Verify and Cleanup run where the world is authoritative: on the
-- server in multiplayer (SVSBTTest_Server.lua), directly in single player.
SVSBTTest = SVSBTTest or {}
SVSBTTest.Traps = SVSBTTest.Traps or {}
local T = SVSBTTest.Traps

T.MODULE = "LilBubbySVSBTTest"
T.TAG = "LilBubbySVSBTGiven"   -- on every item, object and vehicle the test created
T.STATE = "LilBubbySVSBTTest"  -- global mod data: the test in progress, per player
T.MAILBOX_SPRITE = "street_decoration_01_8"
T.VEHICLE = "Base.CarNormal"
T.SEARCH = 12                  -- tiles searched for room to place a world object
-- Where a recipe input lists several items, these are the ones given.
T.PREFERRED = { ["Base.Hammer"] = true, ["Base.Saw"] = true, ["Base.Screwdriver"] = true,
    ["Base.WeldingMask"] = true, ["Base.SteelBar"] = true, ["Base.Rope"] = true, ["Base.Nails"] = true }
-- What the anthrax test gives to contaminate: a skill book, since that is
-- what players pick up and read. Skills preparation never raises, so a
-- volume the character can read is nearly always the first one; vanilla
-- refuses a volume too simple or too complicated for their level.
T.SKILL_BOOKS = { "Cooking", "Farming", "Fishing", "Foraging" }
T.BOOK_VOLUMES = 5
-- Where an input is any container holding a fluid, the container given.
T.FLUID_ITEMS = { CleaningLiquid = "Base.CleaningLiquid2" }
-- Trap kinds built by a different recipe than the one the mod's KindRecipe
-- names (that table says who knows the device, for disarming and warnings).
T.CRAFTED_BY = { biological_sample = "SVSBT_CultureBiologicalSample" }

local function shared() return SVSBT and SVSBT.Shared end

function T.Available()
    local S = shared()
    return S ~= nil and S.KindRecipe ~= nil
end

function T.Recipe(recipeName)
    local ok, recipe = pcall(function()
        return ScriptManager.instance:getCraftRecipe(shared().Module .. "." .. recipeName)
    end)
    return ok and recipe or nil
end

-- The recipe that builds this kind of trap.
function T.CraftRecipe(kind)
    return T.CRAFTED_BY[kind] or shared().KindRecipe[kind]
end

local function kindsOf(recipeName)
    local kinds = {}
    for kind in pairs(shared().KindRecipe) do
        if T.CraftRecipe(kind) == recipeName then kinds[#kinds + 1] = kind end
    end
    table.sort(kinds)
    return kinds
end

-- Every trap recipe once, sorted by the trap's name. nameOf(kind) names a
-- kind; the kind itself otherwise.
function T.List(nameOf)
    local S, seen, list = shared(), {}, {}
    if not S or not S.KindRecipe then return list end
    for kind in pairs(S.KindRecipe) do
        local recipeName = T.CraftRecipe(kind)
        if not seen[recipeName] then
            seen[recipeName] = true
            local kinds = kindsOf(recipeName)
            local ok, name = pcall(nameOf or tostring, kinds[1])
            list[#list + 1] = { recipe = recipeName, kinds = kinds, kind = kinds[1],
                name = ok and name or kinds[1] }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

function T.ByRecipe(recipeName)
    for _, trap in ipairs(T.List()) do
        if trap.recipe == recipeName then return trap end
    end
end

-- The issue that teaches this recipe. Where two do (the bear trap), the one
-- dedicated to it, then the lower number.
function T.Magazine(recipeName)
    local S = shared()
    local best, bestCount, bestNumber
    for fullType, recipes in pairs(S and S.MagazineRecipe or {}) do
        for _, name in ipairs(recipes) do
            if name == recipeName then
                local number = tonumber(fullType:match("(%d+)$")) or 99
                if not best or #recipes < bestCount or (#recipes == bestCount and number < bestNumber) then
                    best, bestCount, bestNumber = fullType, #recipes, number
                end
            end
        end
    end
    return best
end

function T.Teaches(magazineType)
    local S = shared()
    return S and S.MagazineRecipe and S.MagazineRecipe[magazineType] or {}
end

-- The item the recipe makes: read from the recipe, else from the mod's items.
local OUTPUT = { SVSBT_CraftWaterBucketTrap = "WaterBucketTrap", SVSBT_RigShotgunTrap = "ShotgunDoorTrap",
    SVSBT_CraftTripWire = "TripWireKit", SVSBT_CraftNailBoard = "NailBoard", SVSBT_ForgeBearTrap = "BearTrap",
    SVSBT_AssembleExplosiveParcel = "ExplosiveParcel", SVSBT_PrepareBiologicalAgent = "AnthraxAgent",
    SVSBT_CultureBiologicalSample = "SealedBiologicalSample",
    SVSBT_AssembleIgnitionCharge = "IgnitionCharge", SVSBT_AssembleDriverSeatDyeTrap = "DriverSeatDyeTrap",
    SVSBT_AssembleVehicleTamperAlarm = "VehicleTamperAlarm", SVSBT_AssembleRemoteImmobilizer = "RemoteImmobilizer" }
function T.Output(recipeName)
    local recipe = T.Recipe(recipeName)
    local ok, fullType = pcall(function()
        return recipe:getOutputs():get(0):getPossibleResultItems():get(0):getFullName()
    end)
    if ok and type(fullType) == "string" then return fullType end
    local item = OUTPUT[recipeName]
    return item and (shared().Item[item] or (shared().Module .. "." .. item)) or nil
end

-- What the trap is used on, if it is not simply placed on the floor.
function T.WorldNeed(trap)
    local S = shared()
    for _, kind in ipairs(trap.kinds or {}) do
        if S.VehicleKinds and S.VehicleKinds[kind] then return "vehicle" end
        if kind == S.Kind.ExplosiveMailbox then return "mailbox" end
        if kind == S.Kind.AnthraxDocument then return "document" end
    end
end

function T.Enabled(trap)
    local S = shared()
    if not S.FeatureEnabledForKind then return true end
    for _, kind in ipairs(trap.kinds) do
        local ok, on = pcall(S.FeatureEnabledForKind, kind)
        if ok and on then return true end
    end
    return false
end

------------------------------------------------------------
-- Inventory
------------------------------------------------------------

local function count(inventory, fullType)
    local ok, n = pcall(function() return inventory:getCountTypeRecurse(fullType) end)
    return ok and n or 0
end

local function newItem(fullType)
    if instanceItem then
        local ok, item = pcall(instanceItem, fullType)
        if ok and item then return item end
    end
    local ok, item = pcall(function() return InventoryItemFactory.CreateItem(fullType) end)
    return ok and item or nil
end

-- Tags, fills (before adding, so the fill travels with the item) and adds.
local function give(inventory, item, fluid)
    item:getModData()[T.TAG] = true
    if fluid then
        pcall(function()
            local container = item:getFluidContainer()
            container:addFluid(fluid, container:getCapacity() - container:getAmount())
        end)
    end
    inventory:AddItem(item)
    if isServer() then sendAddItemToContainer(inventory, item) end
    return item
end

-- The fluid an item input must hold (the water in the water bucket), if any.
local function fluidOf(input)
    local ok, fluid = pcall(function()
        if not input:hasConsumeFromItem() then return nil end
        local consume = input:getConsumeFromItemScript()
        if consume:getResourceType() ~= ResourceType.Fluid then return nil end
        return consume:getPossibleInputFluids():get(0)
    end)
    return ok and fluid or nil
end

-- The container to give for an input that is any container of this fluid.
local function fluidItem(fluid)
    if not fluid then return nil end
    for _, getter in ipairs({ "getFluidTypeString", "getName" }) do
        local ok, name = pcall(function() return fluid[getter](fluid) end)
        if ok and name and T.FLUID_ITEMS[tostring(name)] then return T.FLUID_ITEMS[tostring(name)] end
    end
end

local function isFullOf(item, fluid)
    local ok, full = pcall(function()
        local container = item:getFluidContainer()
        return container and container:contains(fluid) and container:getAmount() >= container:getCapacity() - 0.001
    end)
    return ok and full == true
end

-- How many of these the player carries that the recipe can use.
local function carried(inventory, fullType, fluid)
    if not fluid then return count(inventory, fullType) end
    local n = 0
    pcall(function()
        local items = inventory:getAllTypeRecurse(fullType)
        for i = 0, items:size() - 1 do
            if isFullOf(items:get(i), fluid) then n = n + 1 end
        end
    end)
    return n
end

local function chooseType(possible)
    for i = 0, possible:size() - 1 do
        local fullType = possible:get(i):getFullName()
        if T.PREFERRED[fullType] then return fullType end
    end
    return possible:get(0):getFullName()
end

local function displayName(fullType)
    local ok, name = pcall(function() return getScriptManager():FindItem(fullType):getDisplayName() end)
    return ok and name or fullType
end

-- Tops the inventory up to every input the recipe needs. Returns the lines
-- given ("3 x Nails") and notes about inputs that could not be given.
function T.GiveInputs(player, recipe)
    local inventory, given, notes = player:getInventory(), {}, {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local possible = input:getPossibleInputItems()
        if possible and possible:size() > 0 then
            local need = math.max(1, input:getIntAmount())
            local fluid = fluidOf(input)
            local fullType, have = fluidItem(fluid), 0
            if fullType then
                have = carried(inventory, fullType, fluid)
            else
                for j = 0, possible:size() - 1 do have = have + carried(inventory, possible:get(j):getFullName(), fluid) end
                fullType = chooseType(possible)
            end
            local added = 0
            for _ = have + 1, need do
                local item = newItem(fullType)
                if not item then notes[#notes + 1] = "could not create " .. fullType; break end
                give(inventory, item, fluid)
                added = added + 1
            end
            if added > 0 then
                local line = added .. " x " .. displayName(fullType)
                if fluid then
                    local ok, name = pcall(function() return fluid:getDisplayName() end)
                    line = line .. " (full of " .. tostring(ok and name or "fluid") .. ")"
                end
                given[#given + 1] = line
            end
        end
    end
    return given, notes
end

-- Raises each skill the recipe needs to its level. Returns "Carpentry 4" lines.
function T.RaiseSkills(player, recipe)
    local raised = {}
    local ok, n = pcall(function() return recipe:getRequiredSkillCount() end)
    for i = 0, (ok and n or 0) - 1 do
        pcall(function()
            local skill = recipe:getRequiredSkill(i)
            local perk, level = skill:getPerk(), skill:getLevel()
            if player:getPerkLevel(perk) >= level then return end
            for _ = 1, 12 do
                if player:getPerkLevel(perk) >= level then break end
                local missing = perk:getTotalXpForLevel(level) - player:getXp():getXP(perk)
                addXpNoMultiplier(player, perk, math.max(1, missing + 1))
            end
            local name = perk.getName and perk:getName() or tostring(perk)
            raised[#raised + 1] = name .. " " .. level
        end)
    end
    return raised
end

------------------------------------------------------------
-- World objects
------------------------------------------------------------

local function freeSquare(sq)
    return sq and sq:isFree(false) and sq:getMovingObjects():size() == 0 and not sq:getVehicleContainer()
end

-- The nearest spot beside the player where a w x h block of squares is free.
local function findSpot(player, w, h)
    local cell, px, py, pz = getCell(), math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for r = 1, T.SEARCH do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local ok = true
                    for ox = 0, w - 1 do
                        for oy = 0, h - 1 do
                            local x, y = px + dx + ox, py + dy + oy
                            if ok and ((x == px and y == py) or not freeSquare(cell:getGridSquare(x, y, pz))) then ok = false end
                        end
                    end
                    if ok then return px + dx, py + dy, pz end
                end
            end
        end
    end
end

local function placeMailbox(player)
    local x, y, z = findSpot(player, 1, 1)
    if not x then return nil, "no free square within " .. T.SEARCH .. " tiles for a mailbox" end
    local sq = getCell():getGridSquare(x, y, z)
    local object = IsoObject.new(sq, T.MAILBOX_SPRITE, "Mailbox")
    if not object:getContainer() then pcall(function() object:createContainersFromSpriteProperties() end) end
    object:getModData()[T.TAG] = true
    sq:AddTileObject(object)
    if isServer() then pcall(function() object:transmitCompleteItemToClients() end) end
    return { x = x, y = y, z = z }
end

-- A car beside the player with its key in their inventory and a full tank.
local function placeVehicle(player)
    local x, y, z = findSpot(player, 3, 6)
    if not x then return nil, "no clear 3x6 space within " .. T.SEARCH .. " tiles for a car" end
    local sq = getCell():getGridSquare(x + 1, y + 3, z)
    local vehicle = addVehicleDebug(T.VEHICLE, IsoDirections.S, nil, sq)
    vehicle = vehicle or sq:getVehicleContainer()
    if not vehicle then return nil, "the car could not be spawned" end
    pcall(function() vehicle:repair() end)
    local tank = vehicle:getPartById("GasTank")
    if tank then
        tank:setContainerContentAmount(tank:getContainerCapacity())
        pcall(function() vehicle:transmitPartModData(tank) end)
    end
    vehicle:getModData()[T.TAG] = true
    pcall(function() vehicle:transmitModData() end)
    local key = vehicle:createVehicleKey()
    if key then give(player:getInventory(), key) end
    return { id = vehicle:getId(), x = sq:getX(), y = sq:getY(), z = z,
        fuel = tank and math.floor(tank:getContainerContentAmount() + 0.5) or 0, key = key ~= nil }
end

-- Can the player read this skill book now? Vanilla's Read option is greyed
-- out for a volume more than one level above them or one they have outgrown.
local function readable(player, book)
    local ok, yes = pcall(function()
        local skill = book:getSkillTrained()
        local perk = (SkillBook and SkillBook[skill] and SkillBook[skill].perk) or Perks[skill]
        local level = player:getPerkLevel(perk)
        return book:getLvlSkillTrained() <= level + 1 and book:getMaxLevelTrained() > level
    end)
    return ok and yes == true
end

-- A skill book the player can read, to contaminate: the first readable
-- volume of T.SKILL_BOOKS. Returns the item (not yet given), or nil.
function T.SkillBook(player)
    local fallback
    for _, skill in ipairs(T.SKILL_BOOKS) do
        for volume = 1, T.BOOK_VOLUMES do
            local fullType = "Base.Book" .. skill .. volume
            local book = getScriptManager():FindItem(fullType) and newItem(fullType)
            if book then
                if readable(player, book) then return book end
                fallback = fallback or book
            end
        end
    end
    return fallback
end

local function removeMailbox(place)
    local sq = place and getCell():getGridSquare(place.x, place.y, place.z)
    if not sq then return 0 end
    local removed = 0
    for i = sq:getObjects():size() - 1, 0, -1 do
        local object = sq:getObjects():get(i)
        if object:hasModData() and object:getModData()[T.TAG] then
            sq:transmitRemoveItemFromSquare(object)
            removed = removed + 1
        end
    end
    return removed
end

local function removeVehicle(place)
    if not place then return 0 end
    local vehicle = getVehicleById and getVehicleById(place.id)
    if not (vehicle and vehicle:getModData()[T.TAG]) then
        vehicle = nil
        local vehicles = getCell():getVehicles()
        for i = 0, vehicles:size() - 1 do
            local candidate = vehicles:get(i)
            if candidate:getModData()[T.TAG] then vehicle = candidate end
        end
    end
    if not vehicle then return 0 end
    vehicle:permanentlyRemove()
    return 1
end

------------------------------------------------------------
-- Setting and setting off the trap: what the player is told
------------------------------------------------------------

local AWAY = " Then walk at least 2 tiles away so it arms."
local FLOOR = "Right-click the %s in your inventory and choose Set %s on Current Tile (or right-click a floor tile and choose Set %s Here)." .. AWAY
local VEHICLE = "Stand beside the car the test parked next to you (engine off), right-click the %s in your inventory and choose Install %s."
    .. " You can also press V beside the car to open its radial menu and choose Install %s there."
    .. " Then walk at least 2 tiles away from the car so it arms."
-- set: how to set it. detonate: how to set it off.
T.INSTRUCTIONS = {
    water_bucket = { set = FLOOR:format("Water Bucket Trap", "Water Bucket Trap", "Water Bucket Trap"),
        detonate = "Walk back onto the trap's tile. The bucket tips over and soaks you." },
    nail_board = { set = FLOOR:format("Nail Board", "Nail Board", "Nail Board"),
        detonate = "Walk back onto the trap's tile. The nails wound your feet and damage your shoes." },
    bear_trap = { set = "Right-click the Bear Trap in your inventory and choose Set Bear Trap at Current Tile (or right-click a floor tile and choose Set Bear Trap Here)." .. AWAY,
        detonate = "Walk back onto the trap's tile. The jaws catch you: hold a weapon and right-click the trap for Release Victim, or sprint to tear free (it hurts)." },
    shotgun_door = { set = FLOOR:format("Shotgun Door Trap", "Shotgun Door Trap", "Shotgun Trap"),
        detonate = "Walk back onto the trap's tile. The loaded shotgun fires at you. (A zombie walking or a car driving over it sets it off too.)" },
    trip_wire = { set = "Stand where you want the first stake, then right-click a floor tile a few tiles away and choose Connect Trip Wire Here. Then step at least 2 tiles away from the wire so it arms.",
        detonate = "Walk across the line between the two stakes. It sounds a house alarm (no damage)." },
    explosive_mailbox = { set = "Stand beside the mailbox the test placed next to you, right-click the Explosive Parcel in your inventory and choose Arm Parcel in Mailbox." .. AWAY,
        detonate = "Walk back to the mailbox and open it without inspecting it first. The fuse is very short: run." },
    biological_sample = { set = "Right-click the Sealed Biological Sample in your inventory and choose Set Sealed Biological Sample on Current Tile (or right-click a floor tile and choose Set Biological Sample Here). It stays sealed and harmless until opened.",
        open = "Right-click the sample's tile and choose Open Biological Sample. Then walk at least 2 tiles away so it arms.",
        detonate = "Walk back beside the open jar. The gas sickens you for a long time (a gas mask or half-mask helps)." },
    anthrax_document = { set = "Right-click the Anthrax in your inventory and choose Apply Anthrax on the skill book the test gave you. Then drop the book on the ground and walk at least 2 tiles away so it arms.",
        detonate = "Pick the contaminated skill book back up and read it. You are exposed and fall sick for a long time." },
    ignition_charge = { set = VEHICLE:format("Ignition Charge", "Ignition Charge", "Ignition Charge"),
        detonate = "Get into the driver's seat and start the engine (the key is in your inventory). The charge goes off after a short fuse: get out and run." },
    driver_seat_dye = { set = VEHICLE:format("Rectal Reorganizer", "Rectal Reorganizer", "Rectal Reorganizer"),
        detonate = "Get into the driver's seat. It wounds you and leaves you soaked in blood." },
    tamper_alarm = { set = VEHICLE:format("Vehicle Tamper Alarm", "Vehicle Tamper Alarm", "Vehicle Tamper Alarm"),
        detonate = "Open one of the car's doors from outside, or get into a passenger seat. The alarm sounds. (It ignores its owner in the driver's seat.)" },
    remote_immobilizer = { set = VEHICLE:format("Remote Immobilizer", "Remote Immobilizer", "Remote Immobilizer") .. " You also get a blank Immobilizer Controller.",
        detonate = "Within 2 tiles of the car, right-click the Immobilizer Controller and choose Sync Controller to Immobilizer. Once synced it works from anywhere: right-click it and choose Toggle Paired Device to switch the engine OFF. Try starting the car: it will not run." },
}

-- The synopsis shown under the recipe: what the trap does, then how to set
-- it and set it off, in a few words each.
T.SYNOPSIS = {
    water_bucket = { what = "A bucket of water rigged to tip over whoever steps on its tile.",
        set = "Set it on a floor tile and step away so it arms.", fire = "Walk back onto the tile: you get soaked." },
    nail_board = { what = "A board of upturned nails hidden on a tile.",
        set = "Set it on a floor tile and step away so it arms.", fire = "Walk back onto the tile: the nails wound your feet and damage your shoes." },
    bear_trap = { what = "Steel jaws that catch and hold whoever steps in them.",
        set = "Set it on a floor tile and step away so it arms.", fire = "Walk back onto the tile: the jaws catch you until you free yourself." },
    shotgun_door = { what = "A loaded shotgun rigged to fire at whoever crosses its tile.",
        set = "Set it on a floor tile and step away so it arms.", fire = "Walk back onto the tile: the shotgun fires at you." },
    trip_wire = { what = "A wire strung between two stakes that sounds an alarm when crossed.",
        set = "Connect the wire between two tiles and step away so it arms.", fire = "Walk across the wire: a house alarm sounds (no damage)." },
    explosive_mailbox = { what = "A parcel bomb hidden in a mailbox, set off when it is opened.",
        set = "Arm the parcel in the mailbox the test places beside you, then step away.", fire = "Open the mailbox without inspecting it: the short fuse gives you a moment to run." },
    biological_sample = { what = "A sealed jar of a biological agent that sickens whoever is near it once opened.",
        set = "Set the sealed sample on a floor tile, open it, then step away so it arms.", fire = "Walk back beside the open jar: the gas sickens you." },
    anthrax_document = { what = "Anthrax powder applied to a skill book, which exposes whoever reads it.",
        set = "Apply the anthrax to the skill book the test gives you, drop the book and step away.", fire = "Pick the book up and read it: you are exposed and fall sick." },
    ignition_charge = { what = "An explosive wired to a car's ignition.",
        set = "Install it on the car the test parks beside you, then step away.", fire = "Start the engine: the charge goes off after a short fuse." },
    driver_seat_dye = { what = "A spring-loaded device hidden in a car's driver's seat.",
        set = "Install it on the car the test parks beside you, then step away.", fire = "Get into the driver's seat: it wounds you and soaks you in blood." },
    tamper_alarm = { what = "An alarm that sounds when anyone but its owner tampers with a car.",
        set = "Install it on the car the test parks beside you, then step away.", fire = "Open a door from outside or sit in a passenger seat: the alarm sounds." },
    remote_immobilizer = { what = "A device that cuts a car's engine from a paired controller.",
        set = "Install it on the car the test parks beside you, then step away.", fire = "Sync the controller and switch the engine off: the car will not start." },
}

-- The synopsis as lines: a summary, then the steps of the test in order.
-- magazineName and outputName are display names (nil if unknown).
function T.Synopsis(trap, magazineName, outputName)
    local text = T.SYNOPSIS[trap.kind] or { what = "A Spy vs Spy trap.",
        set = "Set it with its right-click menu and step away so it arms.", fire = "Set it off the way it is meant to be set off." }
    local extra = ({ vehicle = ", parks a car beside you with its key and a full tank",
        mailbox = ", places a mailbox beside you", document = ", gives you a skill book to contaminate" })[T.WorldNeed(trap) or ""] or ""
    return { text.what,
        "1. The server gives you " .. (magazineName or "the MAD Magazine that teaches the recipe")
            .. ", any ingredients you lack and the skills the recipe needs" .. extra .. ".",
        "2. Read the magazine, then craft the " .. (outputName or "trap") .. ". The window shows what still blocks the craft.",
        "3. " .. text.set,
        "4. " .. text.fire .. " The server watches the mod's own records to confirm each step.",
        "5. Clean up removes everything the test gave or placed." }
end

------------------------------------------------------------
-- The test
------------------------------------------------------------

-- The test in progress, per player. Kept in global mod data so it outlives
-- the character (a trap can kill them) and a reconnect.
local function states()
    local data = ModData.getOrCreate(T.STATE)
    return data
end

local function ownerKey(player)
    return isServer() and player:getUsername() or "local"
end

function T.State(player) return states()[ownerKey(player)] end

local function registry()
    local R = SVSBT and SVSBT.Server and SVSBT.Server.Registry
    if R then pcall(R.Initialize) end
    return R and R.Data
end

-- Every trap and contaminated document this player owns, by id.
local function owned(player)
    local found, data = {}, registry()
    if not data then return found end
    local name = shared().Username and shared().Username(player) or player:getUsername()
    for id, record in pairs(data.traps or {}) do
        if record.owner == name then found["trap:" .. tostring(id)] = record end
    end
    for id, record in pairs(data.documents or {}) do
        if record.owner == name then found["doc:" .. tostring(id)] = record end
    end
    return found
end

local function lookup(key)
    local data = registry()
    if not data or not key then return nil end
    local kind, id = key:match("^(%a+):(.+)$")
    return (kind == "doc" and data.documents or data.traps)[id]
end

local GONE = { triggered = true, sprung = true, spent = true, destroyed = true }

-- An open sample has no trigger count: it goes off by exposing someone.
local function exposed(record)
    local data = registry()
    for _, exposure in pairs(data and data.exposures or {}) do
        if exposure.sourceRecordId == record.id then return true end
    end
    return false
end

-- Where the player is with the trap: "none" (not set yet), "sealed" (a
-- sample set but not opened), "placed" (set, waiting for them to step away),
-- "set" (live) or "detonated".
function T.Status(player)
    local state = T.State(player)
    if not state then return { error = "No trap test is in progress." } end
    if state.detonated then return { stage = "detonated", recipe = state.recipe } end
    local kinds = {}
    for _, kind in ipairs(state.kinds or {}) do kinds[kind] = true end
    if state.trapKey and not lookup(state.trapKey) then
        -- Picked back up rather than set off: its item is in the inventory again.
        if state.output and count(player:getInventory(), state.output) > (state.setCount or 0) then
            state.trapKey = nil
        else
            state.detonated = true
            return { stage = "detonated", recipe = state.recipe, removed = true }
        end
    end
    if not state.trapKey then
        for key, record in pairs(owned(player)) do
            if not state.known[key] and kinds[record.kind] then
                state.trapKey = key
                state.triggers = tonumber(record.triggerCount) or 0
                state.alarms = tonumber(record.alarmCount) or 0
                state.setCount = state.output and count(player:getInventory(), state.output) or 0
                break
            end
        end
        if not state.trapKey then return { stage = "none", recipe = state.recipe } end
    end
    local record = lookup(state.trapKey)
    if GONE[tostring(record.state)] or (tonumber(record.triggerCount) or 0) > state.triggers
        or (tonumber(record.alarmCount) or 0) > state.alarms or record.immobilized == true or exposed(record) then
        state.detonated = true
        return { stage = "detonated", recipe = state.recipe }
    end
    if record.state == "placed" then return { stage = "sealed", recipe = state.recipe } end
    return { stage = record.armPending and "placed" or "set", recipe = state.recipe }
end

-- A trap the test's player set: its registry entry and whatever it left in
-- the world (the ground item; a car or mailbox goes with the test's own).
local function removeTrap(key, record)
    local S = shared()
    local R = SVSBT.Server.Registry
    if record.kind == S.Kind.BearTrap and record.occupant then
        pcall(function() SVSBT.Server.Creatures.Release(record) end)
    end
    if record.heldUsername then
        pcall(function()
            SVSBT.Server.Service.HeldPlayers[record.heldUsername] = nil
            local held = getPlayerFromUsername and getPlayerFromUsername(record.heldUsername)
            if held then held:getModData().SVSBT_BearTrapHeldId = nil; held:transmitModData() end
        end)
    end
    if record.worldItemId and record.x then
        pcall(function()
            local object = S.WorldItemAt(record.x, record.y, record.z, record.worldItemId)
            local sq = object and object:getSquare()
            if sq then sq:transmitRemoveItemFromSquare(object); pcall(function() sq:removeWorldObject(object) end) end
        end)
    end
    if key:find("^doc:") then pcall(R.RemoveDocument, record.itemId, "LilBubby test cleanup")
    else pcall(R.RemoveTrap, record.id, "LilBubby test cleanup") end
end

local function removeItems(player, output, extra)
    local removed = 0
    local function sweep(container)
        local items = container:getItems()
        for i = items:size() - 1, 0, -1 do
            local item = items:get(i)
            local tagged = item:hasModData() and item:getModData()[T.TAG]
            local crafted = not tagged and extra > 0 and item:getFullType() == output
            if tagged or crafted then
                if crafted then extra = extra - 1 end
                container:Remove(item)
                if isServer() then sendRemoveItemFromContainer(container, item) end
                removed = removed + 1
            elseif item.getItemContainer and item:getItemContainer() then
                sweep(item:getItemContainer())
            end
        end
    end
    sweep(player:getInventory())
    return removed
end

-- Removes everything the test gave and placed, every trap the player set
-- during it, and the trap crafted from it while it is still in the
-- inventory. Skill raises are kept.
function T.Cleanup(player)
    local state = T.State(player) or {}
    local traps = 0
    if state.known then
        for key, record in pairs(owned(player)) do
            if not state.known[key] then removeTrap(key, record); traps = traps + 1 end
        end
    end
    local extra = state.output and math.max(0, count(player:getInventory(), state.output) - (state.baseline or 0)) or 0
    local reply = { removed = removeItems(player, state.output, extra), crafted = extra, traps = traps,
        mailbox = removeMailbox(state.mailbox), vehicle = removeVehicle(state.vehicle), recipe = state.recipe }
    states()[ownerKey(player)] = nil
    return reply
end

function T.Deposit(player, args)
    if not T.Available() then return { error = "Spy vs Spy Booby Traps is not enabled." } end
    local trap = T.ByRecipe(type(args) == "table" and args.recipe or nil)
    if not trap then return { error = "Unknown trap recipe." } end
    local recipe = T.Recipe(trap.recipe)
    if not recipe then return { error = trap.recipe .. " is not registered in this build." } end
    if not T.Enabled(trap) then return { status = "BLOCKED", error = "This trap is switched off in the server's sandbox settings." } end
    local previous = T.Cleanup(player) -- a new test replaces the last one
    local output = T.Output(trap.recipe)
    local known = {}
    for key in pairs(owned(player)) do known[key] = true end
    local state = { recipe = trap.recipe, kinds = trap.kinds, output = output, known = known,
        baseline = output and count(player:getInventory(), output) or 0 }
    states()[ownerKey(player)] = state
    local reply = { recipe = trap.recipe, output = output, outputName = output and displayName(output),
        replaced = previous.recipe }
    reply.raised = T.RaiseSkills(player, recipe)
    -- The magazine always: the server can know a recipe the client's craft
    -- window does not (the mod re-teaches from read history without telling
    -- the client), so "known here" is no reason to hold it back.
    reply.known = player:getKnownRecipes():contains(trap.recipe) == true
    local magazine = T.Magazine(trap.recipe)
    local item = magazine and newItem(magazine)
    if item then
        give(player:getInventory(), item)
        reply.magazine = item:getDisplayName()
        state.magazine = magazine
    elseif magazine then
        reply.notes = { "could not create " .. magazine }
    end
    local notes
    reply.given, notes = T.GiveInputs(player, recipe)
    for _, note in ipairs(reply.notes or {}) do notes[#notes + 1] = note end
    reply.notes = notes
    local need = T.WorldNeed(trap)
    if need == "vehicle" then
        local placed, why = placeVehicle(player)
        state.vehicle = placed
        reply.vehicle = placed
        if why then reply.notes[#reply.notes + 1] = why end
    elseif need == "mailbox" then
        local placed, why = placeMailbox(player)
        state.mailbox = placed
        reply.mailbox = placed
        if why then reply.notes[#reply.notes + 1] = why end
    elseif need == "document" then
        local book = T.SkillBook(player)
        if book then
            give(player:getInventory(), book)
            reply.document = book:getDisplayName()
            if not readable(player, book) then
                reply.notes[#reply.notes + 1] = "your character's skill is outside every volume tried, so " .. reply.document .. " may not be readable"
            end
        else
            reply.notes[#reply.notes + 1] = "no skill book could be created to contaminate"
        end
    end
    return reply
end

-- Is the trap in the player's inventory now, beyond what they had before?
function T.Verify(player)
    local state = T.State(player)
    if not state or not state.output then return { error = "No trap test is in progress." } end
    local now = count(player:getInventory(), state.output)
    return { crafted = now > (state.baseline or 0), count = now, output = state.output,
        outputName = displayName(state.output), recipe = state.recipe }
end

local function knows(player, recipe)
    local ok, yes = pcall(function() return player:getKnownRecipes():contains(recipe) end)
    return ok and yes == true
end

-- Does the server know the recipe? The craft needs both the client (its
-- craft window) and the server (which checks the craft) to know it, so the
-- two are brought into line here. args.clientKnows is what the client sees.
--   Not known here: the mod grants it from the player's read history; if
--     that has not reached the server yet but the client has learned it by
--     reading, the server learns it too.
--   Known here but not on the client: the server's list is sent to it.
function T.Learned(player, args)
    local state = T.State(player)
    if not state then return { error = "No trap test is in progress." } end
    local clientKnows = type(args) == "table" and args.clientKnows
    local known = knows(player, state.recipe)
    if not known then
        pcall(function() SVSBT.Server.Service.LearnRecipes(player, {}) end)
        known = knows(player, state.recipe)
    end
    if not known and clientKnows == true then
        pcall(function() player:learnRecipe(state.recipe) end)
        known = knows(player, state.recipe)
    end
    local synced = false
    if known and clientKnows == false and isServer() and sendSyncPlayerFields then
        synced = pcall(sendSyncPlayerFields, player, 0x00000007)
    end
    return { known = known, synced = synced, recipe = state.recipe,
        magazine = state.magazine and displayName(state.magazine) }
end

T.OPS = { deposit = T.Deposit, learned = T.Learned, verify = T.Verify, status = T.Status, cleanup = T.Cleanup }

return T
