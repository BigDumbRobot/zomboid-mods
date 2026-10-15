-- KIPN_DisassembleComputerAction.lua
--
-- Timed action performed when a player confirms "Disassemble
-- Computer" from the right-click context menu (see
-- client/KIPN_Interaction.lua).
--
-- IMPORTANT:
--
-- This action does NOT degrade Computer Condition itself.
--
-- On completion it only SENDS the disassemble request
-- (KIPN.Shared.Commands.DISASSEMBLE_COMPUTER) to the server.
--
-- KIPN_Server.lua's handleDisassembleComputer command handler
-- independently re-validates everything (the computer must be
-- powered off, the player must actually carry a screwdriver, and
-- the Electrical skill level used for scaling is read from the
-- player object the server itself has) before applying any
-- condition change. This action, and the context menu that queues
-- it, are hints only.
--
-- Disassembling a computer never removes it from the world -- the
-- world object is untouched, only its Hardware Condition drops.

if isServer() then
    return
end

require "TimedActions/ISBaseTimedAction"

---@class KIPN_DisassembleComputerAction : ISBaseTimedAction
---@field character IsoGameCharacter
---@field computerObject IsoObject
---@field computerId string
KIPN_DisassembleComputerAction =
    ISBaseTimedAction:derive("KIPN_DisassembleComputerAction")

local DISASSEMBLE_TOOL_TYPES = {
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

function KIPN_DisassembleComputerAction.CanStart(character, shouldNotify)
    local inventory = character and character.getInventory
        and character:getInventory() or nil

    for _, itemType in ipairs(DISASSEMBLE_TOOL_TYPES) do
        if inventoryContains(inventory, itemType) then
            return true
        end
    end

    if shouldNotify then
        notifyMissing(character, "A screwdriver is required to disassemble this computer.")
    end
    return false
end

--------------------------------------------------------------------
-- RESOLVE DISMANTLE DURATION
--
-- KIPN.ComputerConditionDismantleTime (sandbox) is the base
-- duration at Electrical level 0. It scales down for skilled
-- players using the SAME multiplier that governs how Electrical
-- level scales Hardware Condition loss on disassemble
-- (KIPN.ComputerConditionElectricalLevelDisassembleMultiplier) --
-- at the default multiplier (10 = 1.0x) that scaling factor
-- collapses to 1, so Electrical level has no effect on either stat
-- by default, matching KIPN_Server.lua's handleDisassembleComputer
-- degradation formula.
--
-- This is purely a client-side UX duration, matching this file's
-- existing "maxTime is a hint only" design: the server never reads
-- or validates it -- handleDisassembleComputer applies its own
-- condition change independently of how long the local timed
-- action ran.
--------------------------------------------------------------------

local KIPN_DISASSEMBLE_MIN_MAX_TIME =
    20

local function resolveDismantleMaxTime(
    character
)

    local baseTime =
        200

    if SandboxVars
        and SandboxVars.KIPN
        and SandboxVars.KIPN.ComputerConditionDismantleTime ~= nil
    then

        baseTime =
            SandboxVars.KIPN.ComputerConditionDismantleTime
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
        and SandboxVars.KIPN.ComputerConditionElectricalLevelDisassembleMultiplier ~= nil
    then

        multiplier =
            SandboxVars.KIPN.ComputerConditionElectricalLevelDisassembleMultiplier / 10.0
    end

    local scale =
        1 + (electricalLevel / 10) * (multiplier - 1)

    if scale <= 0 then

        scale =
            1
    end

    local result =
        math.floor(baseTime / scale)

    if result < KIPN_DISASSEMBLE_MIN_MAX_TIME then

        result =
            KIPN_DISASSEMBLE_MIN_MAX_TIME
    end

    return result
end

function KIPN_DisassembleComputerAction:isValid()

    return self.computerObject ~= nil

end

function KIPN_DisassembleComputerAction:waitToStart()

    self.character:faceThisObject(self.computerObject)

    return self.character:shouldBeTurning()

end

function KIPN_DisassembleComputerAction:update()

    self.character:faceThisObject(self.computerObject)

end

function KIPN_DisassembleComputerAction:start()

    if not KIPN_DisassembleComputerAction.CanStart(self.character, true) then
        self:forceStop()
        return
    end

    self:setActionAnim("Loot")

end

function KIPN_DisassembleComputerAction:stop()

    ISBaseTimedAction.stop(self)

end

function KIPN_DisassembleComputerAction:perform()

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.DISASSEMBLE_COMPUTER

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
                "KIPN_DisassembleComputerAction:perform(): "
                .. "DISASSEMBLE_COMPUTER command unavailable"
            )

        end

    end

    ISBaseTimedAction.perform(self)

end

function KIPN_DisassembleComputerAction:new(
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

    o.maxTime = resolveDismantleMaxTime(character)

    if character:isTimedActionInstant() then
        o.maxTime = 1
    end

    return o

end
