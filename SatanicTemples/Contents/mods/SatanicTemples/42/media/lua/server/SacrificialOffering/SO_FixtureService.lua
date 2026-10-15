if isClient() then return end

require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_Storage"
require "Camping/SCampfireSystem"

local SO = SacrificialOffering
SO.Fixtures = SO.Fixtures or {}
local Fixtures = SO.Fixtures

-- The vanilla "Dumpster" is a two-tile, multi-sprite object: the front half
-- (grid position 0,1, carries the offering container) sits on the altar square
-- and the back half (grid position 0,0) sits one tile north of it. Both halves
-- are solid, so both squares must be reserved and protected.
local ALTAR_FRONT_SPRITE = "trashcontainers_01_8"
local ALTAR_BACK_SPRITE = "trashcontainers_01_9"

local function altarBackPosition(altar)
    return { x = altar.x, y = altar.y - 1, z = altar.z }
end

-- Temple mannequins are the vanilla "Plastic Skeleton" display: the same
-- shop-mall tile as a regular mannequin, switched to the skeleton mannequin
-- script. The skeleton has a single vanilla pose and wears nothing.
local MANNEQUIN_SPRITE = "location_shop_mall_01_68"
local MANNEQUIN_SCRIPT = "MannequinSkeleton01"
-- Each skeleton holds a pair of katanas in its protected container: visible in
-- the loot window as a tease, never takeable.
local DISPLAY_ITEM = "Base.Katana"
local DISPLAY_COUNT = 2
local OUTFIT_VERSION_KEY = "SO_OutfitVersion"
local OUTFIT_VERSION = 4

-- Lit jack-o'-lanterns ring the fixture block. Offsets are from the altar front
-- tile: the four corners, one behind the altar and one in front of it. The
-- pumpkin is a world item; clients add the glow (SO_JackOLanterns.lua).
local LANTERN_ITEM = "Base.HalloweenPumpkin"
local LANTERN_OFFSETS = { { -3, -2 }, { 3, -2 }, { -3, 2 }, { 3, 2 }, { 0, -3 }, { 0, 2 } }

-- Returns true only when a modData value actually changed, so periodic callers
-- can skip a redundant network broadcast (an unconditional transmitModData on a
-- fixture whose square has streamed out spams "ObjectModDataPacket.parse:
-- object is null" once per integrity pass).
local function tagObject(object, zone, kind)
    local md = object:getModData()
    local changed = false
    local function put(key, value)
        if md[key] ~= value then md[key] = value changed = true end
    end
    put(SO.MOD_DATA.PROTECTED, true)
    put(SO.MOD_DATA.FIXTURE_KIND, kind)
    put(SO.MOD_DATA.ZONE_ID, zone.id)
    put(SO.MOD_DATA.ALTAR_ID, "altar-" .. tostring(zone.id))
    if zone.fixtures and zone.fixtures.campfire then
        put(SO.MOD_DATA.CAMPFIRE_X, zone.fixtures.campfire.x)
        put(SO.MOD_DATA.CAMPFIRE_Y, zone.fixtures.campfire.y)
        put(SO.MOD_DATA.CAMPFIRE_Z, zone.fixtures.campfire.z)
    end
    return changed
end

function Fixtures.FindTaggedObject(x, y, z, kind)
    local square = getCell():getGridSquare(x, y, z)
    if not square then return nil end
    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        local md = object and object:getModData()
        if md and md[SO.MOD_DATA.PROTECTED] and (not kind or md[SO.MOD_DATA.FIXTURE_KIND] == kind) then return object end
    end
    return nil
end

local function isCandidateSquare(square)
    if not square or not square:getFloor() then return false end
    if square.isWater and square:isWater() then return false end
    local ok, free = pcall(function() return square:isFree(false) end)
    return not ok or free == true
end

local function layoutAt(zone, centerX, centerY)
    local z = tonumber(zone.z) or 0
    local layout = {
        altar = { x = centerX, y = centerY, z = z },
        altarBack = { x = centerX, y = centerY - 1, z = z },
        campfire = { x = centerX + 2, y = centerY, z = z },
        mannequins = {
            { x = centerX - 2, y = centerY - 1, z = z, dir = "E" },
            { x = centerX - 2, y = centerY, z = z, dir = "E" },
            { x = centerX - 2, y = centerY + 1, z = z, dir = "E" },
        },
    }
    local positions = {
        layout.altar, layout.altarBack, layout.campfire,
        layout.mannequins[1], layout.mannequins[2], layout.mannequins[3],
    }
    for _, position in ipairs(positions) do
        if not SO.Util.RectContains(zone, position.x, position.y) then return nil end
        if not isCandidateSquare(getCell():getGridSquare(position.x, position.y, position.z)) then return nil end
    end
    return layout
end

function Fixtures.ChooseLayout(zone)
    if zone.fixtures and zone.fixtures.altar and zone.fixtures.campfire and zone.fixtures.mannequins then
        zone.fixtures.altarBack = zone.fixtures.altarBack or altarBackPosition(zone.fixtures.altar)
        zone.fixtures.pentagram = nil
        return zone.fixtures
    end
    local centerX = math.floor((zone.x1 + zone.x2 - 1) / 2)
    local centerY = math.floor((zone.y1 + zone.y2 - 1) / 2)
    local maxRadius = math.max(zone.x2 - zone.x1, zone.y2 - zone.y1)
    for radius = 0, maxRadius do
        for dx = -radius, radius do
            for _, dy in ipairs({ -radius, radius }) do
                local layout = layoutAt(zone, centerX + dx, centerY + dy)
                if layout then return layout end
            end
        end
        for dy = -radius + 1, radius - 1 do
            for _, dx in ipairs({ -radius, radius }) do
                local layout = layoutAt(zone, centerX + dx, centerY + dy)
                if layout then return layout end
            end
        end
    end
    return nil
end

-- The pentagram fixture was removed. Strip any pentagram object an earlier build
-- placed near the altar (on its own tile or the south-east diagonal).
local function removeStrayPentagrams(zone)
    zone.fixtures.pentagram = nil
    local altar = zone.fixtures.altar
    if not altar then return end
    local spots = {
        { altar.x, altar.y, altar.z },
        { altar.x + 1, altar.y + 1, altar.z },
    }
    for _, spot in ipairs(spots) do
        local orphan = Fixtures.FindTaggedObject(spot[1], spot[2], spot[3], SO.FIXTURE.PENTAGRAM)
        if orphan and orphan:getSquare() then
            pcall(function() orphan:getSquare():transmitRemoveItemFromSquare(orphan) end)
        end
    end
end

local function spawnAltarBack(zone)
    local position = zone.fixtures.altarBack or altarBackPosition(zone.fixtures.altar)
    zone.fixtures.altarBack = position
    local existing = Fixtures.FindTaggedObject(position.x, position.y, position.z, SO.FIXTURE.ALTAR_BACK)
    if existing then return existing end
    local square = getCell():getGridSquare(position.x, position.y, position.z)
    if not square then return nil end
    local back = IsoObject.new(square, ALTAR_BACK_SPRITE, SO.ALTAR_NAME)
    back:setOutlineOnMouseover(true)
    tagObject(back, zone, SO.FIXTURE.ALTAR_BACK)
    square:AddTileObject(back)
    back:transmitCompleteItemToClients()
    return back
end

-- Each dumpster half (front and back) is one linked offering container. The
-- dumpster sprite's "container" property already makes AddTileObject give the
-- object a stock "dumpster"-type container -- which is exactly SO.ALTAR_CONTAINER_TYPE
-- -- so this never needs a second ItemContainer. Adding one is what previously
-- multiplied containers on every integrity pass. Only ever build one when the
-- object genuinely has none; otherwise resize the existing primary in place.
-- PZ's ItemContainer hard-caps capacity at 100 (setCapacity logs
-- "over maximum capacity of 100" and refuses anything higher). Each altar has
-- two linked halves, so 100 per half is 200 of usable altar space. Asking for
-- more just made every integrity pass see the container as "not yet at target",
-- re-call setCapacity, re-flag the fixture changed, and re-broadcast the altar
-- -- a ~3 s loop that spammed the server log.
local ALTAR_CONTAINER_MAX_CAPACITY = 100

local function altarCapacity()
    local wanted = SO.Util.Round(SO.Sandbox.Number("AltarCapacity", 100, 1000))
    return math.min(wanted, ALTAR_CONTAINER_MAX_CAPACITY)
end

local function attachAltarContainer(altar)
    if not altar then return false end
    local wanted = altarCapacity()
    local container = altar:getContainer()

    if not container then
        pcall(function() altar:removeAllContainers() end)
        -- Build 42 dropped the trailing width/height args from this constructor.
        container = ItemContainer.new(SO.ALTAR_CONTAINER_TYPE, altar:getSquare(), altar)
        altar:setContainer(container)
        container:setExplored(true)
        container:setCapacity(wanted)
        return true
    end

    local changed = false
    if container:getType() ~= SO.ALTAR_CONTAINER_TYPE then
        pcall(function() container:setType(SO.ALTAR_CONTAINER_TYPE) end)
        changed = true
    end
    if math.abs((container:getCapacity() or 0) - wanted) > 0.5 then
        local before = container:getCapacity() or 0
        container:setCapacity(wanted)
        -- Only a capacity the engine actually accepted counts as a change;
        -- otherwise we would re-broadcast on every pass forever.
        if math.abs((container:getCapacity() or 0) - before) > 0.5 then changed = true end
    end
    if container.isExplored and not container:isExplored() then
        container:setExplored(true)
        changed = true
    end
    return changed
end

local function spawnAltar(zone)
    local position = zone.fixtures.altar
    local back = spawnAltarBack(zone)
    local existing = Fixtures.FindTaggedObject(position.x, position.y, position.z, SO.FIXTURE.ALTAR)
    if existing then
        if attachAltarContainer(existing) then existing:transmitCompleteItemToClients() end
        if back and attachAltarContainer(back) then back:transmitCompleteItemToClients() end
        return back and existing or nil
    end
    local square = getCell():getGridSquare(position.x, position.y, position.z)
    if not square or not back then return nil end
    local altar = IsoObject.new(square, ALTAR_FRONT_SPRITE, SO.ALTAR_NAME)
    altar:setOutlineOnMouseover(true)
    tagObject(altar, zone, SO.FIXTURE.ALTAR)
    square:AddTileObject(altar)
    attachAltarContainer(altar)
    attachAltarContainer(back)
    back:transmitCompleteItemToClients()
    altar:transmitCompleteItemToClients()
    return altar
end

local function spawnCampfire(zone)
    local position = zone.fixtures.campfire
    local existing = SCampfireSystem.instance:getLuaObjectAt(position.x, position.y, position.z)
    if not existing then
        local square = getCell():getGridSquare(position.x, position.y, position.z)
        if not square then return nil end
        existing = SCampfireSystem.instance:addCampfire(square)
    end
    if existing and existing:getIsoObject() then
        local fire = existing:getIsoObject()
        local changed = tagObject(fire, zone, SO.FIXTURE.CAMPFIRE)
        -- Only broadcast a real change, and only while the fire's square is
        -- loaded -- otherwise remote clients cannot resolve the object and log
        -- "ObjectModDataPacket.parse: object is null" every integrity pass.
        if changed and fire.transmitModData and fire:getSquare()
            and (not fire:getSquare().getChunk or fire:getSquare():getChunk()) then
            pcall(function() fire:transmitModData() end)
        end
    end
    return existing
end

local function clearMannequin(mannequin)
    local wornItems = mannequin:getWornItems()
    if wornItems then wornItems:clear() end
    local container = mannequin:getContainer()
    if container then
        while container:getItems():size() > 0 do
            container:DoRemoveItem(container:getItems():get(0))
        end
    end
end

-- True when the container holds exactly the display contents and nothing is
-- worn, so the integrity pass can restock a skeleton that was tampered with.
local function hasDisplayContents(mannequin)
    local wornItems = mannequin:getWornItems()
    if wornItems and wornItems:size() > 0 then return false end
    local container = mannequin:getContainer()
    if not container then return true end
    local items = container:getItems()
    if items:size() ~= DISPLAY_COUNT then return false end
    for index = 0, items:size() - 1 do
        if items:get(index):getFullType() ~= DISPLAY_ITEM then return false end
    end
    return true
end

local function applyMannequinSetup(mannequin)
    mannequin:setMannequinScriptName(MANNEQUIN_SCRIPT)
    clearMannequin(mannequin)
    local container = mannequin:getContainer()
    if container then
        for _ = 1, DISPLAY_COUNT do container:AddItem(DISPLAY_ITEM) end
    end
    mannequin:getModData()[OUTFIT_VERSION_KEY] = OUTFIT_VERSION
end

local function spawnMannequin(zone, position)
    local existing = Fixtures.FindTaggedObject(position.x, position.y, position.z, SO.FIXTURE.MANNEQUIN)
    if existing then
        if tonumber(existing:getModData()[OUTFIT_VERSION_KEY]) ~= OUTFIT_VERSION
            or not hasDisplayContents(existing) then
            applyMannequinSetup(existing)
            existing:transmitCompleteItemToClients()
        end
        return existing
    end
    local square = getCell():getGridSquare(position.x, position.y, position.z)
    if not square then return nil end
    local mannequin = IsoMannequin.new(getCell(), square, getSprite(MANNEQUIN_SPRITE))
    mannequin:setSquare(square)
    mannequin:setMannequinScriptName(MANNEQUIN_SCRIPT)
    if IsoDirections and IsoDirections[position.dir or "E"] then mannequin:setDir(IsoDirections[position.dir or "E"]) end
    tagObject(mannequin, zone, SO.FIXTURE.MANNEQUIN)
    if mannequin:getContainerCount() == 0 then mannequin:createContainersFromSpriteProperties() end
    square:AddSpecialObject(mannequin)
    applyMannequinSetup(mannequin)
    mannequin:transmitCompleteItemToClients()
    return mannequin
end

local function lanternPositions(zone)
    local altar = zone.fixtures.altar
    local positions = {}
    for _, offset in ipairs(LANTERN_OFFSETS) do
        local x, y = altar.x + offset[1], altar.y + offset[2]
        if SO.Util.RectContains(zone, x, y) then
            positions[#positions + 1] = { x = x, y = y, z = altar.z }
        end
    end
    return positions
end

function Fixtures.IsLanternItem(item)
    local md = item and item:getModData()
    return md ~= nil and md[SO.MOD_DATA.PROTECTED] == true and md[SO.MOD_DATA.FIXTURE_KIND] == SO.FIXTURE.LANTERN
end

local function findLantern(square)
    local objects = square:getWorldObjects()
    for index = 0, objects:size() - 1 do
        local worldItem = objects:get(index)
        if worldItem and Fixtures.IsLanternItem(worldItem:getItem()) then return worldItem end
    end
    return nil
end

-- Lanterns are decorative: a square that is unloaded or has no floor is simply
-- skipped and retried on the next integrity pass.
local function spawnLantern(zone, position)
    local square = getCell():getGridSquare(position.x, position.y, position.z)
    if not square or not square:getFloor() then return nil end
    local existing = findLantern(square)
    if existing then return existing end
    local item = instanceItem(LANTERN_ITEM)
    if not item then return nil end
    local md = item:getModData()
    md[SO.MOD_DATA.PROTECTED] = true
    md[SO.MOD_DATA.FIXTURE_KIND] = SO.FIXTURE.LANTERN
    md[SO.MOD_DATA.ZONE_ID] = zone.id
    -- A carved pumpkin is food; keep the display one from ever going stale.
    pcall(function()
        item:setAge(0)
        item:setOffAge(1000000)
        item:setOffAgeMax(1000000)
    end)
    return square:AddWorldInventoryItem(item, 0.5, 0.5, 0)
end

local function removeLanternAt(position)
    local square = getCell():getGridSquare(position.x, position.y, position.z)
    if not square then return false end
    local objects = square:getWorldObjects()
    for index = objects:size() - 1, 0, -1 do
        local worldItem = objects:get(index)
        if worldItem and Fixtures.IsLanternItem(worldItem:getItem()) then
            square:transmitRemoveItemFromSquare(worldItem)
            square:removeWorldObject(worldItem)
        end
    end
    return true
end

-- Each fixture is placed independently: a failure or raise while placing one
-- (for example an unloaded square, or an engine hiccup building the two-tile
-- altar) must not stop the others from being placed on this or a later pass.
local function trySpawn(label, zoneId, spawner, ...)
    local ok, result = pcall(spawner, ...)
    if ok then return result end
    SO.Logger.Error("Fixture placement raised", { fixture = label, zoneId = zoneId, error = tostring(result) })
    return nil
end

function Fixtures.Provision(zone)
    if not zone then return false, "missing-zone" end
    if not zone.fixtures then
        local ok, layout = pcall(Fixtures.ChooseLayout, zone)
        zone.fixtures = ok and layout or nil
        if not zone.fixtures then return false, "squares-unavailable" end
    end
    if not zone.fixtures.altar then return false, "squares-unavailable" end
    zone.fixtures.altarBack = zone.fixtures.altarBack or altarBackPosition(zone.fixtures.altar)

    -- Clean up any pentagram object a previous build placed near the altar.
    pcall(removeStrayPentagrams, zone)

    local altar = trySpawn("altar", zone.id, spawnAltar, zone)
    local campfire = trySpawn("campfire", zone.id, spawnCampfire, zone)
    local mannequins = {}
    for index, position in ipairs(zone.fixtures.mannequins) do
        mannequins[index] = trySpawn("mannequin" .. index, zone.id, spawnMannequin, zone, position)
    end
    zone.fixtures.lanterns = zone.fixtures.lanterns or lanternPositions(zone)
    for index, position in ipairs(zone.fixtures.lanterns) do
        trySpawn("lantern" .. index, zone.id, spawnLantern, zone, position)
    end
    local complete = altar ~= nil and campfire ~= nil
        and mannequins[1] ~= nil and mannequins[2] ~= nil and mannequins[3] ~= nil
    zone.pendingFixtures = not complete
    return complete, complete and nil or "partial"
end

local function dropContainerContents(object)
    local container = object and object:getContainer()
    local square = object and object:getSquare()
    if not container or not square then return end
    while container:getItems():size() > 0 do
        local item = container:getItems():get(0)
        container:DoRemoveItem(item)
        square:AddWorldInventoryItem(item, 0.2, 0.2, 0)
    end
end

local function removeTaggedAt(position, kind, preserveContents)
    if not position then return true end
    local square = getCell():getGridSquare(position.x, position.y, position.z)
    if not square then return false end
    local object = Fixtures.FindTaggedObject(position.x, position.y, position.z, kind)
    if object and object:getSquare() then
        if preserveContents then dropContainerContents(object) end
        object:getSquare():transmitRemoveItemFromSquare(object)
    end
    return true
end

function Fixtures.Remove(zone)
    if not zone or not zone.fixtures then return true end
    local complete = true
    local campPos = zone.fixtures.campfire
    if campPos then
        local square = getCell():getGridSquare(campPos.x, campPos.y, campPos.z)
        if not square then
            complete = false
        else
            local campfire = SCampfireSystem.instance:getLuaObjectAt(campPos.x, campPos.y, campPos.z)
            if campfire then SCampfireSystem.instance:removeCampfire(campfire) end
        end
    end
    if not removeTaggedAt(zone.fixtures.altar, SO.FIXTURE.ALTAR, true) then complete = false end
    local backPos = zone.fixtures.altarBack or (zone.fixtures.altar and altarBackPosition(zone.fixtures.altar))
    if not removeTaggedAt(backPos, SO.FIXTURE.ALTAR_BACK, false) then complete = false end
    -- Clean up any pentagram object a previous build left near the altar.
    local altar = zone.fixtures.altar
    if altar then
        removeTaggedAt({ x = altar.x, y = altar.y, z = altar.z }, SO.FIXTURE.PENTAGRAM, false)
        removeTaggedAt({ x = altar.x + 1, y = altar.y + 1, z = altar.z }, SO.FIXTURE.PENTAGRAM, false)
    end
    if zone.fixtures.pentagram then
        removeTaggedAt(zone.fixtures.pentagram, SO.FIXTURE.PENTAGRAM, false)
    end
    for _, position in ipairs(zone.fixtures.mannequins or {}) do
        if not removeTaggedAt(position, SO.FIXTURE.MANNEQUIN, false) then complete = false end
    end
    for _, position in ipairs(zone.fixtures.lanterns or {}) do
        if not removeLanternAt(position) then complete = false end
    end
    return complete
end

function Fixtures.CleanupTombstones()
    local root = SO.Storage and SO.Storage.Get and SO.Storage.Get()
    if not root then return end
    for index = #root.fixtureTombstones, 1, -1 do
        local fixtures = root.fixtureTombstones[index]
        if Fixtures.Remove({ fixtures = fixtures }) then table.remove(root.fixtureTombstones, index) end
    end
end

return Fixtures
