-- KIPN_PropertyClaimAction.lua
--
-- Timed action performed when a player confirms "Claim This
-- Location" from the right-click context menu (see
-- client/KIPN_PropertyClaimMenu.lua).
--
-- IMPORTANT:
--
-- This action does NOT establish ownership itself.
--
-- On completion it only SENDS the claim request
-- (KIPN.Shared.Commands.CLAIM_PROPERTY) to the server.
--
-- KIPN_PropertyClaimService.lua's command handler independently
-- resolves the player's CURRENT server-side position and re-validates
-- everything (the player's claim artifact, the building, zone
-- restrictions, whether this location is already claimed) before
-- establishing ownership. This action, and the context menu that
-- queues it, are hints only.

if isServer() then
    return
end

require "TimedActions/ISBaseTimedAction"

---@class KIPN_PropertyClaimAction : ISBaseTimedAction
---@field character IsoGameCharacter
KIPN_PropertyClaimAction =
    ISBaseTimedAction:derive("KIPN_PropertyClaimAction")

local CLAIM_ARTIFACT_TYPES = {
    "Base.KIPNPropertyClaimArtifact",
    "KIPNPropertyClaimArtifact",
}

local function notifyMissing(character)
    local message = "A Safehouse Deed is required to claim this location."
    if character and character.setHaloNote then
        character:setHaloNote(message, 255, 80, 80, 300)
    elseif character and character.Say then
        character:Say(message)
    end
end

function KIPN_PropertyClaimAction.CanStart(character, shouldNotify)
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

-- The player who last sent CLAIM_PROPERTY, kept outside the timed
-- action (which finishes immediately on perform()) so the server-
-- response listener below still has someone to :Say() the result
-- to. See the listener at the bottom of this file for why this
-- exists.
local lastClaimPlayer = nil

function KIPN_PropertyClaimAction:isValid()

    return true

end

function KIPN_PropertyClaimAction:waitToStart()

    return false

end

function KIPN_PropertyClaimAction:start()

    if not KIPN_PropertyClaimAction.CanStart(self.character, true) then
        self:forceStop()
        return
    end

end

function KIPN_PropertyClaimAction:stop()

    ISBaseTimedAction.stop(self)

end

function KIPN_PropertyClaimAction:perform()

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.CLAIM_PROPERTY

    if command then

        lastClaimPlayer =
            self.character

        sendClientCommand(
            self.character,
            "KIPN",
            command,
            {}
        )

    else

        if KIPN and KIPN.Logger then

            KIPN.Logger.Error(
                "KIPN_PropertyClaimAction:perform(): "
                .. "CLAIM_PROPERTY command unavailable"
            )

        end

    end

    ISBaseTimedAction.perform(self)

end

function KIPN_PropertyClaimAction:new(
    character
)

    local o =
        ISBaseTimedAction.new(
            self,
            character
        )

    o.character = character

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
-- perform() above sends CLAIM_PROPERTY and immediately finishes the
-- timed action. The server independently re-validates everything
-- (see handleClaimPropertyCommand) and can still reject the claim
-- (not inside a building, restricted zone, already claimed, quota
-- reached, artifact invalid, etc), so the result is reported to the
-- player here.
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

    if event == KIPN.Shared.ResponseEvents.PROPERTY_CLAIM_SUCCESSFUL then

        lastClaimPlayer:Say("Safehouse claim successful.")
        lastClaimPlayer = nil

    elseif event == KIPN.Shared.ResponseEvents.ERROR
        and args.data
        and args.data.command == KIPN.Shared.Commands.CLAIM_PROPERTY
    then

        lastClaimPlayer:Say(
            "Safehouse claim failed: "
            .. tostring(args.data.reason or "unknown reason")
        )
        lastClaimPlayer = nil

    end

end

if Events.OnServerCommand then

    Events.OnServerCommand.Add(onServerResponse)

end
