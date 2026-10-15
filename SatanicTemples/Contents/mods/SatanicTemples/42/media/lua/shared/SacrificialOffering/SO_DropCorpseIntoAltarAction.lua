require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISTransferAction"
require "SacrificialOffering/SO_Constants"

local SO = SacrificialOffering

-- Bob_ThrowBody_OutOFWindow is 11,200 ticks at 4,800 ticks/second. B42's
-- throw-into-container state plays it at 0.8 speed: 2.9167 seconds total.
local ACTION_TIME = 47

SO_DropCorpseIntoAltarAction = ISBaseTimedAction:derive("SO_DropCorpseIntoAltarAction")

local function isCorpseItem(item)
    if not item then return false end
    local fullType = item:getFullType()
    if fullType ~= "Base.CorpseMale"
        and fullType ~= "Base.CorpseFemale"
        and fullType ~= "Base.CorpseAnimal" then
        return false
    end

    local ok, body = pcall(function() return item:getDeadBodyObject() end)
    if not ok or not body then return false end
    if fullType ~= "Base.CorpseAnimal" then return not body:isAnimal() end
    if not body:isAnimal() then return false end

    local skeletonOk, isSkeleton = pcall(function() return body:isAnimalSkeleton() end)
    return not skeletonOk or not isSkeleton
end

local function isAltar(altar)
    if not altar or altar:getObjectIndex() == -1 then return false end
    local md = altar:getModData()
    local container = altar:getContainer()
    if not md or not container or container:getType() ~= SO.ALTAR_CONTAINER_TYPE then return false end
    if md[SO.MOD_DATA.PROTECTED] ~= true then return false end
    local kind = md[SO.MOD_DATA.FIXTURE_KIND]
    return kind == SO.FIXTURE.ALTAR or kind == SO.FIXTURE.ALTAR_BACK
end

function SO_DropCorpseIntoAltarAction:getContainers()
    return self.item and self.item:getContainer(), self.altar and self.altar:getContainer()
end

function SO_DropCorpseIntoAltarAction:isValid()
    if not isCorpseItem(self.item) or not isAltar(self.altar) then return false end
    local source, destination = self:getContainers()
    if not source or not destination then return false end
    if isClient() then
        if not source:containsID(self.item:getID()) then return false end
    elseif not source:contains(self.item) then
        return false
    end
    -- No room check: the altar is a ritual vessel that consumes whatever is laid
    -- on it, and a carried human corpse is deliberately over-weight while held.
    return true
end

function SO_DropCorpseIntoAltarAction:isValidStart()
    return self:isValid()
end

function SO_DropCorpseIntoAltarAction:waitToStart()
    self.character:faceThisObject(self.altar)
    return self.character:shouldBeTurning()
end

function SO_DropCorpseIntoAltarAction:update()
    self.character:faceThisObject(self.altar)
    self.item:setJobDelta(self:getJobDelta())
end

function SO_DropCorpseIntoAltarAction:start()
    -- Resolve the client's current item instance after network reconstruction.
    if isClient() and self.item then
        local current = self.character:getInventory():getItemById(self.item:getID())
        if current then self.item = current end
    end
    self.item:setJobType(getText("IGUI_JobType_Dropping"))
    self.item:setJobDelta(0.0)
    self:setActionAnim("SO_DumpCorpseIntoAltar")
    self.action:setUseProgressBar(false)
end

function SO_DropCorpseIntoAltarAction:stop()
    if self.item then self.item:setJobDelta(0.0) end
    ISBaseTimedAction.stop(self)
end

function SO_DropCorpseIntoAltarAction:complete()
    -- Networked B42 timed actions complete on the server. Single-player runs
    -- the same authoritative mutation locally.
    if isClient() then return true end
    if not self:isValid() then return false end

    local source, destination = self:getContainers()
    local item = self.item

    -- Un-weight the corpse before it lands so it never fights a container check
    -- and does not sit in the altar lying about its mass.
    if SO.CorpseCarryIntegration and SO.CorpseCarryIntegration.RestoreCorpseWeight then
        SO.CorpseCarryIntegration.RestoreCorpseWeight(item)
    end

    -- Direct move, bypassing hasRoomFor entirely.
    self.character:setPrimaryHandItem(nil)
    self.character:setSecondaryHandItem(nil)
    source:DoRemoveItem(item)
    if sendRemoveItemFromContainer then sendRemoveItemFromContainer(source, item) end
    destination:AddItem(item)
    if sendAddItemToContainer then sendAddItemToContainer(destination, item) end
    if isServer() then sendEquip(self.character) end
    self.item = item

    source:setDrawDirty(true)
    source:setHasBeenLooted(true)
    destination:setDrawDirty(true)
    return true
end

function SO_DropCorpseIntoAltarAction:perform()
    if self.item then self.item:setJobDelta(0.0) end
    ISBaseTimedAction.perform(self)
end

function SO_DropCorpseIntoAltarAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return ACTION_TIME
end

function SO_DropCorpseIntoAltarAction:new(character, altar, item)
    local o = ISBaseTimedAction.new(self, character)
    o.altar = altar
    o.item = item
    o.stopOnWalk = true
    o.stopOnRun = true
    o.stopOnAim = true
    o.ignoreHandsWounds = true
    o.useProgressBar = false
    o.maxTime = o:getDuration()
    return o
end

return SO_DropCorpseIntoAltarAction
