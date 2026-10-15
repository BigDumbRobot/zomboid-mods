require "Items/ProceduralDistributions"
require "Items/Distributions"
require "SVSBT_Config"

if type(isClient) == "function" and isClient() and not isServer() then
    return
end

SVSBT.Server = SVSBT.Server or {}
SVSBT.Server.Loot = SVSBT.Server.Loot or {}

local Loot = SVSBT.Server.Loot
local Config = SVSBT.Config
local Logger = SVSBT.Logger

Loot.Injected = Loot.Injected == true

local function addItem(distributionName, fullType, weight)
    local run = Logger.Begin("Loot.addItem", distributionName .. ":" .. fullType)
    local distribution = ProceduralDistributions
        and ProceduralDistributions.list
        and ProceduralDistributions.list[distributionName]

    if not distribution or type(distribution.items) ~= "table" or weight <= 0 then
        Logger.Finish(run, true, "skipped")
        return false
    end

    table.insert(distribution.items, fullType)
    table.insert(distribution.items, weight)
    Logger.Finish(run, true, "weight=" .. tostring(weight))
    return true
end

local function addMagazines(distributionName, weight)
    local added = 0
    local seen = {}

    -- Shared.Magazine can map more than one kind to the same physical issue
    -- (trip wire teaches from the water bucket's magazine) -- inject each
    -- real item once, not once per kind that happens to share it.
    for _, fullType in pairs(SVSBT.Shared.Magazine) do
        if not seen[fullType] then
            seen[fullType] = true
            if addItem(distributionName, fullType, weight) then
                added = added + 1
            end
        end
    end

    return added
end

-- Vanilla lists a sledgehammer at 0.01 per variant in ordinary tool crates,
-- so "as rare as a sledgehammer" is 0.01 per item; household traps get a
-- touch more. TrapLootMultiplier scales both (0 disables finished-trap loot).
local RARE_WEIGHT = 0.01
local HOUSEHOLD_WEIGHT = 0.02

-- Finished traps only. Everything not listed here must be crafted.
local function trapPlacements()
    local Item = SVSBT.Shared.Item
    local biological = { Item.AnthraxAgent, Item.SealedBiologicalSample }
    return {
        -- Obscure labs and military sites (basements are handled separately).
        { lists = { "TestingLab", "ArmyBunkerStorage", "ArmyBunkerLockers", "ArmyStorageMedical" },
          items = biological, weight = RARE_WEIGHT },
        -- Barricaded survivor houses: vanilla rolls this list only there.
        { lists = { "SafehouseTraps" }, items = { Item.ExplosiveParcel }, weight = RARE_WEIGHT },
        -- Regular homes: closet shelves and garage/shed tool storage.
        { lists = { "ClosetShelfGeneric", "GarageTools" },
          items = { Item.WaterBucketTrap, Item.NailBoard }, weight = HOUSEHOLD_WEIGHT },
        { lists = { "HuntingLockers" }, items = { Item.BearTrap }, weight = RARE_WEIGHT },
    }, biological
end

-- Basements use vanilla's generic "storage" room, whose crates only draw
-- from lists shared with ordinary closets and sheds. Rather than salt those,
-- point the basement's CrateTools pick at a private copy carrying the
-- biological items, so basement crates otherwise roll exactly as before.
local BASEMENT_LIST = "SVSBT_BasementCrateTools"

local function injectBasement(items, weight)
    local run = Logger.Begin("Loot.injectBasement")
    local lists = ProceduralDistributions and ProceduralDistributions.list
    local source = lists and lists.CrateTools
    local room = SuburbsDistributions and SuburbsDistributions.storage
    local procList = room and room.other and room.other.procList

    if weight <= 0 or type(source) ~= "table" or type(source.items) ~= "table" or type(procList) ~= "table" then
        Logger.Finish(run, true, "skipped")
        return 0
    end

    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    copy.items = {}
    for _, entry in ipairs(source.items) do copy.items[#copy.items + 1] = entry end
    lists[BASEMENT_LIST] = copy

    local added = 0
    for _, fullType in ipairs(items) do
        if addItem(BASEMENT_LIST, fullType, weight) then added = added + 1 end
    end

    for _, entry in ipairs(procList) do
        if entry.name == "CrateTools" then entry.name = BASEMENT_LIST end
    end

    Logger.Finish(run, true, "entries=" .. tostring(added))
    return added
end

function Loot.Inject()
    local run = Logger.Begin("Loot.Inject")

    if Loot.Injected then
        Logger.Finish(run, true, "already injected")
        return true
    end

    local multiplier = Config.Get("TrapLootMultiplier") or 1.0
    local magazinePlacements = {
        BookstoreMisc = 1.0,
        LibraryMagazines = 0.5,
        CrateMagazines = 0.5,
        ClassroomShelves = 0.25,
        CrateBooksSchool = 0.15,
        LivingRoomShelf = 0.05,
    }
    local added = 0
    local placements, biological = trapPlacements()

    for _, placement in ipairs(placements) do
        for _, distribution in ipairs(placement.lists) do
            for _, fullType in ipairs(placement.items) do
                if addItem(distribution, fullType, placement.weight * multiplier) then added = added + 1 end
            end
        end
    end
    added = added + injectBasement(biological, RARE_WEIGHT * multiplier)

    for distribution, weight in pairs(magazinePlacements) do
        added = added + addMagazines(distribution, weight)
    end

    Loot.Injected = true
    Logger.Info("Loot.Inject", "trap loot and recipe magazines injected | entries=" .. tostring(added))
    Logger.Finish(run, true, "entries=" .. tostring(added))
    return true
end

if Events and Events.OnPreDistributionMerge then
    Events.OnPreDistributionMerge.Add(Loot.Inject)
else
    Logger.Warn("SVSBT_Loot.load", "OnPreDistributionMerge unavailable; injecting immediately")
    Loot.Inject()
end

Logger.Info("SVSBT_Loot.load", "trap loot distribution module loaded")

return Loot
