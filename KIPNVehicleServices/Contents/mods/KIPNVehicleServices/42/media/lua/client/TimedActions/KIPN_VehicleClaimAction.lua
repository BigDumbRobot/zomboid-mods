-- KIPN_VehicleClaimAction.lua
--
-- Timed action performed when a player confirms "Claim Vehicle"
-- from the right-click context menu (see
-- client/KIPN_VehicleClaimMenu.lua).
--
-- IMPORTANT:
--
-- This action does NOT establish ownership itself.
--
-- On completion it only SENDS the claim request
-- (KIPN.Shared.Commands.CLAIM_VEHICLE) to the server.
--
-- KIPN_ClaimService.lua's command handler independently
-- re-validates everything (the player's claim artifact, the
-- vehicle's current claim status, the artifact's zone scope)
-- before establishing ownership. This action, and the context
-- menu that queues it, are hints only.

if isServer() then
    return
end

require "TimedActions/ISBaseTimedAction"

---@class KIPN_VehicleClaimAction : ISBaseTimedAction
---@field character IsoGameCharacter
---@field vehicle BaseVehicle
KIPN_VehicleClaimAction =
    ISBaseTimedAction:derive("KIPN_VehicleClaimAction")

local CLAIM_ARTIFACT_TYPES = {
    "Base.KIPNVehicleClaimArtifact",
    "KIPNVehicleClaimArtifact",
}

local function notifyMissing(character)
    local message = "A Vehicle Title is required to claim this vehicle."
    if character and character.setHaloNote then
        character:setHaloNote(message, 255, 80, 80, 300)
    elseif character and character.Say then
        character:Say(message)
    end
end

function KIPN_VehicleClaimAction.CanStart(character, shouldNotify)
    local inventory = character and character.getInventory
        and character:getInventory() or nil

    if inventory then
        for _, itemType in ipairs(CLAIM_ARTIFACT_TYPES) do
            if inventory.containsTypeRecurse
                and inventory:containsTypeRecurse(itemType)
            then
                return true
            end
            if inventory.contains and inventory:contains(itemType) then
                return true
            end
        end
    end

    if shouldNotify then notifyMissing(character) end
    return false
end

-- The player who last sent CLAIM_VEHICLE, kept outside the timed
-- action (which finishes immediately on perform()) so the server-
-- response listener below still has someone to :Say() the result
-- to. Mirrors client/TimedActions/KIPN_PropertyClaimAction.lua's
-- identical pattern -- before this, CLAIM_VEHICLE had NO response
-- listener anywhere in the client codebase, so both a successful
-- claim and a server-side rejection (wrong zone, artifact already
-- consumed, a genuine handler error, etc.) were completely silent:
-- the player saw no confirmation and no error, indistinguishable
-- from "nothing happened."
local lastClaimPlayer = nil

function KIPN_VehicleClaimAction:isValid()

    return self.vehicle
        and not self.vehicle:isRemovedFromWorld()

end

function KIPN_VehicleClaimAction:waitToStart()

    self.character:faceThisObject(self.vehicle)

    return self.character:shouldBeTurning()

end

function KIPN_VehicleClaimAction:update()

    self.character:faceThisObject(self.vehicle)

end

function KIPN_VehicleClaimAction:start()

    if not KIPN_VehicleClaimAction.CanStart(self.character, true) then
        self:forceStop()
        return
    end

    self:setActionAnim("VehicleWorkOnMid")

end

function KIPN_VehicleClaimAction:stop()

    ISBaseTimedAction.stop(self)

end

function KIPN_VehicleClaimAction:perform()

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.CLAIM_VEHICLE

    if command then

        lastClaimPlayer =
            self.character

        sendClientCommand(
            self.character,
            "KIPN",
            command,
            {
                vehicleId = self.vehicle:getId(),
            }
        )

    else

        if KIPN and KIPN.Logger then

            KIPN.Logger.Error(
                "KIPN_VehicleClaimAction:perform(): "
                .. "CLAIM_VEHICLE command unavailable"
            )

        end

    end

    ISBaseTimedAction.perform(self)

end

function KIPN_VehicleClaimAction:new(
    character,
    vehicle
)

    local o =
        ISBaseTimedAction.new(
            self,
            character
        )

    o.character = character

    o.vehicle = vehicle

    o.stopOnWalk = true

    o.stopOnRun = true

    o.maxTime = 60

    if character:isTimedActionInstant() then
        o.maxTime = 1
    end

    return o

end

--------------------------------------------------------------------
-- SERVER RESPONSE
--
-- perform() above sends CLAIM_VEHICLE and immediately finishes the
-- timed action -- the server independently re-validates everything
-- (see KIPN_ClaimService.lua's handleClaimVehicleCommand) and can
-- still reject it even when this action played out (wrong
-- dealership scope, artifact already consumed, quota reached,
-- etc). Without this listener that rejection -- and even a genuine
-- success -- was completely silent: nothing told the player the
-- claim went through, or why it didn't.
--------------------------------------------------------------------

local function onServerResponse(module, command, args)

    if module ~= "KIPN" then
        return
    end

    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
    then
        return
    end

    if not lastClaimPlayer
        or not lastClaimPlayer.Say
    then
        return
    end

    local event =
        args and args.event

    if event == KIPN.Shared.ResponseEvents.VEHICLE_CLAIM_SUCCESSFUL then

        lastClaimPlayer:Say("Vehicle claim successful.")
        lastClaimPlayer = nil

    elseif event == KIPN.Shared.ResponseEvents.ERROR
        and args.data
        and args.data.command == KIPN.Shared.Commands.CLAIM_VEHICLE
    then

        lastClaimPlayer:Say(
            "Vehicle claim failed: "
            .. tostring(args.data.reason or "unknown reason")
        )
        lastClaimPlayer = nil

    end

end

if Events.OnServerCommand then

    Events.OnServerCommand.Add(onServerResponse)

end
