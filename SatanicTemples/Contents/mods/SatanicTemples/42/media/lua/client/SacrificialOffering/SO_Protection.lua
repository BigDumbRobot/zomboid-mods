require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_ClientState"
require "Moveables/ISMoveablesAction"
require "TimedActions/ISDestroyStuffAction"
require "Camping/TimedActions/ISRemoveCampfireAction"
require "TimedActions/ISInventoryTransferAction"
require "TimedActions/ISGrabItemAction"
require "TimedActions/ISExtendedPlacementAction"
require "ISUI/LootWindow/Handlers/RemoveCampfire"
require "ISUI/LootWindow/Handlers/MannequinWearAll"
require "ISUI/LootWindow/Handlers/MannequinSwitchOutfit"
require "ISUI/LootWindow/Handlers/TakeAll"
require "ISUI/LootWindow/Handlers/TakeSameType"
require "ISUI/LootWindow/Handlers/MoveToFloor"

local SO = SacrificialOffering
SO.Protection = SO.Protection or {}
local Protection = SO.Protection

function Protection.IsProtectedObject(object, kind)
    if not object or not object.getModData then return false end
    local md = object:getModData()
    if not md or md[SO.MOD_DATA.PROTECTED] ~= true then return false end
    return kind == nil or md[SO.MOD_DATA.FIXTURE_KIND] == kind
end

function Protection.IsProtectedContainer(container, kind)
    return container and Protection.IsProtectedObject(container:getParent(), kind)
end

-- Temple jack-o'-lanterns are world items; the tag lives on the item itself.
function Protection.IsLanternItem(item)
    local md = item and item.getModData and item:getModData()
    return md ~= nil and md[SO.MOD_DATA.PROTECTED] == true and md[SO.MOD_DATA.FIXTURE_KIND] == SO.FIXTURE.LANTERN
end

-- Taking from a temple skeleton is refused here, then reported so the server
-- can verify the attempt and punish it (SO_RelicService). The throttle only
-- stops one multi-item drag from sending a burst; the server has its own.
local THEFT_REPORT_INTERVAL_MS = 2000
local nextTheftReportAt = 0

local function reportRelicTheft(container)
    local now = SO.Util.NowMs()
    if now < nextTheftReportAt then return end
    local square = container:getParent() and container:getParent():getSquare()
    if not square then return end
    nextTheftReportAt = now + THEFT_REPORT_INTERVAL_MS
    SO.Client.SendCommand(SO.COMMAND.RELIC_THEFT, { x = square:getX(), y = square:getY(), z = square:getZ() })
end

if not Protection.Patched then
    Protection.Patched = true

    local oldMoveIsValid = ISMoveablesAction.isValid
    function ISMoveablesAction:isValid()
        local object = self.moveProps and self.moveProps.object or self.object
        if Protection.IsProtectedObject(object) then return false end
        return oldMoveIsValid(self)
    end

    local oldDestroyIsValid = ISDestroyStuffAction.isValid
    function ISDestroyStuffAction:isValid()
        if Protection.IsProtectedObject(self.item) then return false end
        return oldDestroyIsValid(self)
    end

    local oldRemoveCampfireIsValid = ISRemoveCampfireAction.isValid
    function ISRemoveCampfireAction:isValid()
        local object = self.campfire and self.campfire:getObject()
        if Protection.IsProtectedObject(object, SO.FIXTURE.CAMPFIRE) then return false end
        return oldRemoveCampfireIsValid(self)
    end

    local oldTransferIsValid = ISInventoryTransferAction.isValid
    function ISInventoryTransferAction:isValid()
        if Protection.IsProtectedContainer(self.srcContainer, SO.FIXTURE.MANNEQUIN) then
            if self.character == getPlayer() then reportRelicTheft(self.srcContainer) end
            return false
        end
        if Protection.IsProtectedContainer(self.destContainer, SO.FIXTURE.MANNEQUIN) then return false end
        if Protection.IsLanternItem(self.item) then return false end
        -- A carried human corpse is over-weight on purpose; let it into an altar
        -- half regardless of the capacity check.
        local ft = self.item and self.item:getFullType()
        if (ft == "Base.CorpseMale" or ft == "Base.CorpseFemale")
            and (Protection.IsProtectedContainer(self.destContainer, SO.FIXTURE.ALTAR)
                or Protection.IsProtectedContainer(self.destContainer, SO.FIXTURE.ALTAR_BACK))
            and self.srcContainer and self.srcContainer:contains(self.item) then
            return true
        end
        return oldTransferIsValid(self)
    end

    local oldGrabIsValid = ISGrabItemAction.isValid
    function ISGrabItemAction:isValid()
        if self.item and self.item.getItem and Protection.IsLanternItem(self.item:getItem()) then return false end
        return oldGrabIsValid(self)
    end

    local oldPlacementIsValid = ISExtendedPlacementAction.isValid
    function ISExtendedPlacementAction:isValid()
        if Protection.IsLanternItem(self.item) then return false end
        return oldPlacementIsValid(self)
    end

    local oldRemoveVisible = ISLootWindowObjectControlHandler_RemoveCampfire.shouldBeVisible
    function ISLootWindowObjectControlHandler_RemoveCampfire:shouldBeVisible()
        if Protection.IsProtectedObject(self.object, SO.FIXTURE.CAMPFIRE) then return false end
        return oldRemoveVisible(self)
    end

    local oldWearVisible = ISLootWindowObjectControlHandler_MannequinWearAll.shouldBeVisible
    function ISLootWindowObjectControlHandler_MannequinWearAll:shouldBeVisible()
        if Protection.IsProtectedObject(self.object, SO.FIXTURE.MANNEQUIN) then return false end
        return oldWearVisible(self)
    end

    local oldSwitchVisible = ISLootWindowObjectControlHandler_MannequinSwitchOutfit.shouldBeVisible
    function ISLootWindowObjectControlHandler_MannequinSwitchOutfit:shouldBeVisible()
        if Protection.IsProtectedObject(self.object, SO.FIXTURE.MANNEQUIN) then return false end
        return oldSwitchVisible(self)
    end

    local oldTakeAllVisible = ISLootWindowObjectControlHandler_TakeAll.shouldBeVisible
    function ISLootWindowObjectControlHandler_TakeAll:shouldBeVisible()
        if Protection.IsProtectedObject(self.object, SO.FIXTURE.MANNEQUIN) then return false end
        return oldTakeAllVisible(self)
    end

    local oldTakeSameVisible = ISLootWindowObjectControlHandler_TakeSameType.shouldBeVisible
    function ISLootWindowObjectControlHandler_TakeSameType:shouldBeVisible()
        if Protection.IsProtectedObject(self.object, SO.FIXTURE.MANNEQUIN) then return false end
        return oldTakeSameVisible(self)
    end

    local oldMoveToFloorVisible = ISLootWindowObjectControlHandler_MoveToFloor.shouldBeVisible
    function ISLootWindowObjectControlHandler_MoveToFloor:shouldBeVisible()
        if Protection.IsProtectedObject(self.object, SO.FIXTURE.MANNEQUIN) then return false end
        return oldMoveToFloorVisible(self)
    end

    SO.Logger.Debug("Protected-fixture action guards installed")
end

return Protection
