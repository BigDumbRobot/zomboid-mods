require "TimedActions/ISTimedActionQueue"
require "ISUI/ISWorldObjectContextMenu"
require "luautils"
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_DropCorpseIntoAltarAction"

local SO = SacrificialOffering
SO.AnimalCorpseIntegration = SO.AnimalCorpseIntegration or {}
local Integration = SO.AnimalCorpseIntegration

local function isCarriableCorpse(item)
    if not item then return false end
    local fullType = item:getFullType()
    if fullType == "Base.CorpseMale" or fullType == "Base.CorpseFemale" then
        local ok, body = pcall(function() return item:getDeadBodyObject() end)
        return ok and body ~= nil and not body:isAnimal()
    end
    if fullType ~= "Base.CorpseAnimal" then return false end
    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    if not ok or not body or not body:isAnimal() then return false end
    local skeletonOk, isSkeleton = pcall(function() return body:isAnimalSkeleton() end)
    return not skeletonOk or not isSkeleton
end

function Integration.FindCarriedCorpse(player)
    if not player then return nil end
    local primary = player:getPrimaryHandItem()
    if isCarriableCorpse(primary) then return primary end
    local secondary = player:getSecondaryHandItem()
    if secondary ~= primary and isCarriableCorpse(secondary) then return secondary end
    return nil
end

local function isAltar(object)
    if not object then return false end
    local md = object:getModData()
    local container = object:getContainer()
    if not md or not container or container:getType() ~= SO.ALTAR_CONTAINER_TYPE then return false end
    if md[SO.MOD_DATA.PROTECTED] ~= true then return false end
    local kind = md[SO.MOD_DATA.FIXTURE_KIND]
    return kind == SO.FIXTURE.ALTAR or kind == SO.FIXTURE.ALTAR_BACK
end

local function altarOnSquare(square)
    if not square then return nil end
    local objects = square:getObjects()
    for index = 0, objects:size() - 1 do
        local object = objects:get(index)
        if isAltar(object) then return object end
    end
    return nil
end

function Integration.FindAltar(worldobjects)
    local seenSquares = {}
    for _, object in ipairs(worldobjects or {}) do
        if isAltar(object) then return object end
        local square = object and object:getSquare()
        if square and not seenSquares[square] then
            seenSquares[square] = true
            local altar = altarOnSquare(square)
            if altar then return altar end
        end
    end
    return nil
end

function Integration.DropCorpse(player, altar, corpse)
    if not player or player:getVehicle() or not isCarriableCorpse(corpse) or not isAltar(altar) then return end
    if corpse ~= player:getPrimaryHandItem() and corpse ~= player:getSecondaryHandItem() then return end

    local source = corpse:getContainer()
    local destination = altar:getContainer()
    local square = altar:getSquare()
    if not source or not destination or not square or not source:contains(corpse) then return end
    -- No room check: the altar always accepts a sacrifice.

    if luautils.walkAdj(player, square) then
        ISTimedActionQueue.add(SO_DropCorpseIntoAltarAction:new(player, altar, corpse))
    end
end

function Integration.OnFillWorldObjectContextMenu(playerIndex, context, worldobjects, test)
    local player = getSpecificPlayer(playerIndex)
    if not player or player:getVehicle() then return false end

    local corpse = Integration.FindCarriedCorpse(player)
    if not corpse then return false end
    local altar = Integration.FindAltar(worldobjects)
    if not altar then return false end
    if test then return ISWorldObjectContextMenu.setTest() end

    context:addOptionOnTop(
        getText("IGUI_Option_DropCorpseIntoContainerName") .. getText("IGUI_ContainerTitle_sacrificialoffering"),
        player,
        Integration.DropCorpse,
        altar,
        corpse
    )
    return true
end

Events.OnFillWorldObjectContextMenu.Add(Integration.OnFillWorldObjectContextMenu)

return Integration
