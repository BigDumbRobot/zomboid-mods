-- Supply depot: a row of crates beside the spawn point, kept stocked with more
-- than enough of every ingredient and tool that the tested mods' recipes use.
-- Players spawn next to it, take what they need and craft; nothing is handed
-- out by teleporting anyone anywhere.
--
-- * What is stocked is read from the game itself: every craft recipe that
--   belongs to one of Supply.MODS, so a new recipe is covered without a list
--   to maintain here.
-- * The server owns the crates. It places them on free outdoor squares around
--   the anchor the first time that ground is loaded, puts one back if it goes
--   missing, and tops every crate up again as items are taken.
-- * The anchor is the server's SpawnPoint when one is set, else this map's
--   default (Supply.DEFAULTS).
LilBubbySupply = LilBubbySupply or {}
local Supply = LilBubbySupply

Supply.MODULE = "LilBubbySupply"
Supply.TAG = "LilBubbySupply"
-- Mods whose recipes are stocked for (mod IDs, as in mod.info).
Supply.MODS = { "KIPN", "KIPNGovernmentServices", "KIPNVehicleServices", "KIPNlord", "ThePostOffice", "DeadMansMap",
    "SkylightsProbe", "TheWhisperers", "SatanicTemples", "SVSBoobyTraps", "SpyVsSpySignalTracker", "BonkZone",
    "CareersFramework", "CareersBlacksmith", "CareersDrugDealer", "CareersMechanic", "DynamicEvents" }
Supply.CRAFTS = 5        -- every recipe can be crafted this many times from a full depot
Supply.MAX = 60          -- most of one item type kept in stock
Supply.TOOLS = 2         -- of each tool or other item a recipe keeps
Supply.FLUIDS = 3        -- full containers of each fluid a recipe draws from
Supply.CRATES = 8
Supply.SPRITE = "carpentry_01_16" -- the wooden crate
Supply.CONTAINER = "crate"
Supply.CAPACITY = 1000   -- the server fills past any weight limit; this keeps the crate usable for players
Supply.RADIUS = 20       -- how far from the anchor a crate may stand
Supply.ADDS_PER_TICK = 150 -- items added per restock pass, so a first fill does not flood the network
-- Where the depot goes when the server has no SpawnPoint: where players spawn
-- in the one test site on the vanilla map (LilBubbySites.FIELD).
Supply.DEFAULTS = { ["Muldraugh, KY"] = { x = 12001, y = 6661, z = 0 } }

local function server() return type(isServer) == "function" and isServer() end
local function client() return type(isClient) == "function" and isClient() end

------------------------------------------------------------
-- WHAT TO STOCK
------------------------------------------------------------

local function bare(id) return (tostring(id or ""):gsub("^\\", "")) end

local function activeMods()
    local wanted, active = {}, {}
    for _, id in ipairs(Supply.MODS) do wanted[id] = true end
    local ok, mods = pcall(getActivatedMods)
    if ok and mods then
        for i = 0, mods:size() - 1 do
            local id = bare(mods:get(i))
            if wanted[id] then active[id] = true end
        end
    end
    return active
end

-- Every craft recipe that belongs to an enabled mod in Supply.MODS.
function Supply.Recipes()
    local active, list = activeMods(), {}
    local ok, all = pcall(function() return getScriptManager():getAllCraftRecipes() end)
    if not ok or not all then return list end
    for i = 0, all:size() - 1 do
        local recipe = all:get(i)
        local fine, id = pcall(function() return recipe:getModID() end)
        if fine and id and active[bare(id)] then list[#list + 1] = recipe end
    end
    return list
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

local function fluidName(fluid)
    for _, getter in ipairs({ "getFluidTypeString", "getName" }) do
        local ok, name = pcall(function() return fluid[getter](fluid) end)
        if ok and name then return tostring(name) end
    end
    return tostring(fluid)
end

local function kept(input)
    local ok, yes = pcall(function() return input:isKeep() or input:isTool() end)
    return ok and yes == true
end

-- What a full depot holds: { { key, type, count, fluid | nil } }, sorted by
-- key. An input that takes any of several items is stocked as one of them:
-- one already stocked for another recipe where there is one, else the first.
function Supply.Needs(recipes)
    local byKey, order = {}, {}
    local function want(fullType, fluid)
        local key = fluid and (fullType .. "|" .. fluidName(fluid)) or fullType
        if not byKey[key] then
            byKey[key] = { key = key, type = fullType, count = 0, fluid = fluid }
            order[#order + 1] = key
        end
        return byKey[key]
    end
    for _, recipe in ipairs(recipes or Supply.Recipes()) do
        local ok, inputs = pcall(function() return recipe:getInputs() end)
        for i = 0, (ok and inputs and inputs:size() or 0) - 1 do
            local input = inputs:get(i)
            local fine, possible = pcall(function() return input:getPossibleInputItems() end)
            if fine and possible and possible:size() > 0 then
                local fluid = fluidOf(input)
                local fullType = possible:get(0):getFullName()
                if not fluid then
                    for j = 0, possible:size() - 1 do
                        local name = possible:get(j):getFullName()
                        if byKey[name] then fullType = name; break end
                    end
                end
                local need = want(fullType, fluid)
                if fluid then
                    need.count = math.max(need.count, Supply.FLUIDS)
                elseif kept(input) then
                    need.count = math.max(need.count, Supply.TOOLS)
                else
                    local amount = 1
                    pcall(function() amount = math.max(1, input:getIntAmount()) end)
                    need.count = math.min(Supply.MAX, need.count + amount * Supply.CRAFTS)
                end
            end
        end
    end
    table.sort(order)
    local list = {}
    for _, key in ipairs(order) do list[#list + 1] = byKey[key] end
    return list
end

------------------------------------------------------------
-- WHERE
------------------------------------------------------------

local function mapName()
    local ok, name = pcall(function()
        if server() or client() then return getServerOptions():getOption("Map") end
        return getWorld():getMap()
    end)
    return ok and name and tostring(name) or "Muldraugh, KY"
end

-- The server's SpawnPoint ("x,y,z"; 0,0,0 means none), else this map's default, else nil.
function Supply.Anchor()
    local ok, text = pcall(function() return getServerOptions():getOption("SpawnPoint") end)
    if ok and text then
        local x, y, z = tostring(text):match("^%s*(%-?%d+)%s*,%s*(%-?%d+)%s*,%s*(%-?%d+)")
        x, y, z = tonumber(x), tonumber(y), tonumber(z)
        if x and y and (x ~= 0 or y ~= 0) then return { x = x, y = y, z = z or 0 } end
    end
    local map = mapName()
    for name, spot in pairs(Supply.DEFAULTS) do
        if map:find(name, 1, true) then return spot end
    end
end

local function data()
    local stored = ModData.getOrCreate(Supply.TAG)
    stored.crates = stored.crates or {}
    return stored
end

local function freeSquare(sq)
    local ok, free = pcall(function()
        return sq:isFree(false) and sq:isOutside() and sq:getMovingObjects():size() == 0 and not sq:getVehicleContainer()
    end)
    return ok and free == true
end

-- Up to `count` free outdoor squares around the anchor, nearest first, on
-- every other tile so there is room to walk between the crates. nil while
-- the ground there is not loaded.
function Supply.Spots(anchor, count)
    local cell = getCell()
    if not cell or not cell:getGridSquare(anchor.x, anchor.y, anchor.z) then return nil end
    local spots = {}
    for radius = 2, Supply.RADIUS, 2 do
        for dx = -radius, radius, 2 do
            for dy = -radius, radius, 2 do
                if #spots < count and (math.abs(dx) == radius or math.abs(dy) == radius) then
                    local x, y = anchor.x + dx, anchor.y + dy
                    local sq = cell:getGridSquare(x, y, anchor.z)
                    if sq and freeSquare(sq) then spots[#spots + 1] = { x = x, y = y, z = anchor.z } end
                end
            end
        end
    end
    return spots
end

------------------------------------------------------------
-- THE CRATES
------------------------------------------------------------

local function crateAt(sq)
    local objects = sq:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object:hasModData() and object:getModData()[Supply.TAG] and object:getContainer() then return object end
    end
end

local function placeCrate(sq)
    local object = IsoObject.new(sq, Supply.SPRITE, "Supply crate")
    if not object:getContainer() then pcall(function() object:createContainersFromSpriteProperties() end) end
    if not object:getContainer() then
        local container = ItemContainer.new(Supply.CONTAINER, sq, object)
        object:setContainer(container)
    end
    local container = object:getContainer()
    pcall(function() container:setCapacity(Supply.CAPACITY) end)
    pcall(function() container:setExplored(true) end) -- so the game never rolls loot into it
    object:getModData()[Supply.TAG] = true
    sq:AddTileObject(object)
    if server() then pcall(function() object:transmitCompleteItemToClients() end) end
    return object
end

-- The crates whose ground is loaded, in their fixed order ({ index, object }),
-- placing the depot the first time and any crate that has gone missing.
-- Returns nil and why while there is nowhere to put them.
function Supply.Crates()
    local anchor = Supply.Anchor()
    if not anchor then return nil, "this map has no default place and the server has no SpawnPoint" end
    local stored = data()
    if #stored.crates == 0 then
        local spots = Supply.Spots(anchor, Supply.CRATES)
        if not spots then return nil, "the ground at the spawn point is not loaded" end
        if #spots == 0 then return nil, "no free outdoor square within " .. Supply.RADIUS .. " tiles of the spawn point" end
        for i, spot in ipairs(spots) do stored.crates[i] = spot end
        print("[" .. Supply.MODULE .. "] depot of " .. #spots .. " crates laid out around " .. anchor.x .. "," .. anchor.y)
    end
    local cell, loaded = getCell(), {}
    for index, spot in ipairs(stored.crates) do
        local sq = cell and cell:getGridSquare(spot.x, spot.y, spot.z)
        if sq then
            local object = crateAt(sq)
            if not object then
                local ok, made = pcall(placeCrate, sq)
                if ok then object = made else print("[" .. Supply.MODULE .. "] could not place a crate: " .. tostring(made)) end
            end
            if object then loaded[#loaded + 1] = { index = index, object = object } end
        end
    end
    return loaded
end

local function newItem(fullType)
    if instanceItem then
        local ok, item = pcall(instanceItem, fullType)
        if ok and item then return item end
    end
    local ok, item = pcall(function() return InventoryItemFactory.CreateItem(fullType) end)
    return ok and item or nil
end

local function isFullOf(item, fluid)
    local ok, full = pcall(function()
        local container = item:getFluidContainer()
        return container and container:contains(fluid) and container:getAmount() >= container:getCapacity() - 0.001
    end)
    return ok and full == true
end

local function stocked(container, need)
    local n, items = 0, container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getFullType() == need.type and (not need.fluid or isFullOf(item, need.fluid)) then n = n + 1 end
    end
    return n
end

-- Tops the loaded crates up. Each item type lives in one crate (the needs
-- are dealt out over the crates in order), so a player finds it in the same
-- place every time. Returns how many items were added and what could not be made.
function Supply.Restock(limit)
    local crates, why = Supply.Crates()
    if not crates then return 0, { why } end
    local total = #data().crates
    local byIndex = {}
    for _, crate in ipairs(crates) do byIndex[crate.index] = crate.object end
    local added, failed = 0, {}
    limit = limit or Supply.ADDS_PER_TICK
    -- Recipes do not change while the game runs, so the list is worked out once.
    if not Supply.needs or #Supply.needs == 0 then Supply.needs = Supply.Needs() end
    for i, need in ipairs(Supply.needs) do
        local object = byIndex[(i - 1) % total + 1]
        local container = object and object:getContainer()
        if container then
            for _ = stocked(container, need) + 1, need.count do
                if added >= limit then return added, failed end
                local item = newItem(need.type)
                if not item then failed[#failed + 1] = need.type; break end
                if need.fluid then
                    pcall(function()
                        local fluids = item:getFluidContainer()
                        fluids:addFluid(need.fluid, fluids:getCapacity() - fluids:getAmount())
                    end)
                end
                container:AddItem(item)
                if server() then pcall(sendAddItemToContainer, container, item) end
                added = added + 1
            end
        end
    end
    return added, failed
end

-- Where the depot is, for the showcase: { anchor, crates = { { x, y, z } } } or { error }.
function Supply.Where()
    local anchor = Supply.Anchor()
    if not anchor then return { error = "This map has no default place for the supply depot. Set SpawnPoint in the server settings." } end
    return { anchor = anchor, crates = data().crates }
end

------------------------------------------------------------
-- SERVER (and single player): keep it stocked
------------------------------------------------------------

local reported = {}
function Supply.Tick()
    local ok, added, failed = pcall(Supply.Restock)
    if not ok then
        if not reported[tostring(added)] then
            reported[tostring(added)] = true
            print("[" .. Supply.MODULE .. "] restock failed: " .. tostring(added))
        end
        return
    end
    if added > 0 then print("[" .. Supply.MODULE .. "] restocked " .. added .. " items") end
    for _, what in ipairs(failed or {}) do
        if not reported[what] then
            reported[what] = true
            print("[" .. Supply.MODULE .. "] not stocked: " .. tostring(what))
        end
    end
end

if not client() and Events then
    if Events.EveryOneMinute then Events.EveryOneMinute.Add(Supply.Tick) end
    if server() and Events.OnClientCommand then
        Events.OnClientCommand.Add(function(module, command, player)
            if module ~= Supply.MODULE or command ~= "where" or not player then return end
            local reply = Supply.Where()
            reply.playerID = player:getOnlineID()
            sendServerCommand(player, Supply.MODULE, "where", reply)
        end)
    end
end

return LilBubbySupply
