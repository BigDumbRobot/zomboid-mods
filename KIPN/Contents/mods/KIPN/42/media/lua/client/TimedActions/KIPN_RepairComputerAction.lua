-- KIPN_RepairComputerAction.lua
--
-- Timed action performed when a player confirms "Repair Computer"
-- from the right-click context menu (see client/KIPN_Interaction.lua).
--
-- IMPORTANT:
--
-- This action does NOT restore Computer Condition itself.
--
-- On completion it only SENDS the repair request
-- (KIPN.Shared.Commands.REPAIR_COMPUTER) to the server.
--
-- KIPN_Server.lua's handleRepairComputer command handler
-- independently re-validates everything (the computer must be
-- powered off and not already at 100% condition, the player must
-- actually carry a required repair tool -- default: a screwdriver
-- -- and a Computer Repair Kit, computer repair must not be
-- disabled via sandbox settings, and the Electrical skill level
-- used for scaling is read from the player object the server itself
-- has) before applying any condition change. This action, and the
-- context menu that queues it, are hints only.
--
-- Repairing a computer never removes it from the world. The
-- Computer Repair Kit IS consumed on a successful repair -- the
-- repair tool (screwdriver) is not, same as the one required to
-- disassemble a computer.

if isServer() then
    return
end

require "TimedActions/ISBaseTimedAction"

---@class KIPN_RepairComputerAction : ISBaseTimedAction
---@field character IsoGameCharacter
---@field computerObject IsoObject
---@field computerId string
KIPN_RepairComputerAction =
    ISBaseTimedAction:derive("KIPN_RepairComputerAction")

local REPAIR_TOOL_TYPES = {
    "Base.Screwdriver",
    "Base.Screwdriver_Improvised",
    "Base.Screwdriver_Old",
}

local function inventoryContains(inventory, itemType)
    if not inventory then return false end
    if inventory.containsTypeRecurse then
        return inventory:containsTypeRecurse(itemType)
    end
    return inventory.contains and inventory:contains(itemType) or false
end

local function notifyMissing(character, message)
    if character and character.setHaloNote then
        character:setHaloNote(message, 255, 80, 80, 300)
    elseif character and character.Say then
        character:Say(message)
    end
end

function KIPN_RepairComputerAction.CanStart(character, shouldNotify)
    local inventory = character and character.getInventory
        and character:getInventory() or nil
    local hasTool = false

    for _, itemType in ipairs(REPAIR_TOOL_TYPES) do
        if inventoryContains(inventory, itemType) then
            hasTool = true
            break
        end
    end

    if not hasTool then
        if shouldNotify then
            notifyMissing(character, "A screwdriver is required to repair this computer.")
        end
        return false
    end

    if not inventoryContains(inventory, "Base.KIPNComputerRepairKit") then
        if shouldNotify then
            notifyMissing(character, "A Computer Repair Kit is required to repair this computer.")
        end
        return false
    end

    return true
end

--------------------------------------------------------------------
-- RESOLVE REPAIR DURATION
--
-- KIPN.ComputerConditionRepairTime (sandbox) is the base duration
-- at Electrical level 0. It scales down for skilled players using
-- the SAME multiplier that governs how Electrical level scales
-- Hardware Condition restored on repair
-- (KIPN.ComputerConditionRepairElectricalXPMultiplier) -- at the
-- default multiplier (100 = 10.0x), a level-10 Electrical player
-- repairs much faster than a level-0 player, matching
-- KIPN_Server.lua's handleRepairComputer restoration formula.
--
-- This is purely a client-side UX duration, matching this file's
-- existing "maxTime is a hint only" design: the server never reads
-- or validates it -- handleRepairComputer applies its own condition
-- change independently of how long the local timed action ran.
--------------------------------------------------------------------

local KIPN_REPAIR_MIN_MAX_TIME =
    20

local function resolveRepairMaxTime(
    character
)

    local baseTime =
        200

    if SandboxVars
        and SandboxVars.KIPN
        and SandboxVars.KIPN.ComputerConditionRepairTime ~= nil
    then

        baseTime =
            SandboxVars.KIPN.ComputerConditionRepairTime
    end

    local electricalLevel =
        0

    if character
        and character.getPerkLevel
        and Perks
        and Perks.Electrical
    then

        local ok,
            level =
            pcall(
                function()

                    return character:getPerkLevel(
                        Perks.Electrical
                    )
                end
            )

        if ok
            and type(level) == "number"
        then

            electricalLevel =
                level
        end
    end

    if electricalLevel > 10 then

        electricalLevel =
            10
    end

    local multiplier =
        1.0

    if SandboxVars
        and SandboxVars.KIPN
        and SandboxVars.KIPN.ComputerConditionRepairElectricalXPMultiplier ~= nil
    then

        multiplier =
            SandboxVars.KIPN.ComputerConditionRepairElectricalXPMultiplier / 10.0
    end

    local scale =
        1 + (electricalLevel / 10) * (multiplier - 1)

    if scale <= 0 then

        scale =
            1
    end

    local result =
        math.floor(baseTime / scale)

    if result < KIPN_REPAIR_MIN_MAX_TIME then

        result =
            KIPN_REPAIR_MIN_MAX_TIME
    end

    return result
end

function KIPN_RepairComputerAction:isValid()

    return self.computerObject ~= nil

end

function KIPN_RepairComputerAction:waitToStart()

    self.character:faceThisObject(self.computerObject)

    return self.character:shouldBeTurning()

end

function KIPN_RepairComputerAction:update()

    self.character:faceThisObject(self.computerObject)

end

function KIPN_RepairComputerAction:start()

    if not KIPN_RepairComputerAction.CanStart(self.character, true) then
        self:forceStop()
        return
    end

    self:setActionAnim("Loot")

end

function KIPN_RepairComputerAction:stop()

    ISBaseTimedAction.stop(self)

end

function KIPN_RepairComputerAction:perform()

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.REPAIR_COMPUTER

    if command then

        sendClientCommand(
            self.character,
            "KIPN",
            command,
            {
                computerId = self.computerId,
            }
        )

    else

        if KIPN and KIPN.Logger then

            KIPN.Logger.Error(
                "KIPN_RepairComputerAction:perform(): "
                .. "REPAIR_COMPUTER command unavailable"
            )

        end

    end

    ISBaseTimedAction.perform(self)

end

function KIPN_RepairComputerAction:new(
    character,
    computerObject,
    computerId
)

    local o =
        ISBaseTimedAction.new(
            self,
            character
        )

    o.character = character

    o.computerObject = computerObject

    o.computerId = computerId

    o.stopOnWalk = true

    o.stopOnRun = true

    o.maxTime = resolveRepairMaxTime(character)

    if character:isTimedActionInstant() then
        o.maxTime = 1
    end

    return o

end
