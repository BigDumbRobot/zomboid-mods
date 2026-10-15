require "TimedActions/ISBaseTimedAction"
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"

-- Build 42 auto-loads this shared file before client Lua is on the require
-- path. Presentation dependencies are loaded by SO_ClientInit before a player
-- can start this action; requiring them here produces false startup warnings.

-- The skill-recovery ritual is a long channel, not an instant transaction. The
-- server commits its verdict when the channel starts but reveals and applies it
-- only when the channel ends; drifting more than ~2 tiles from a valid offering
-- breaks the ritual with nothing recovered.

local SO = SacrificialOffering

-- Ritual channel length. Timed-action "maxTime" units run at ~16 per second, so
-- 47.5 == 760 units. The audio bed (STemple_SatanThinks ~5s + the
-- STemple_SacrificeAccepted / denied second beat) is intentionally shorter than
-- the full channel; the remaining time is the commitment window during which the
-- player must stay by the altar for a valid offering to redeem.
local RITUAL_SECONDS = SO.RITUAL_SECONDS
local MAXTIME_UNITS_PER_SECOND = 16

-- Euclidean distance (tiles) from the altar square the player may drift before
-- the ritual collapses.
local RITUAL_LEASH_TILES = 2.0

-- A result can arrive before this timed action completes (for example "altar
-- busy" when the ritual starts). Remember the transaction so isValid() ends the
-- action without also claiming the player merely broke a valid ritual.
local resolvedTransactions = {}
local activeTransactions = {}

SO_OfferingRitualAction = ISBaseTimedAction:derive("SO_OfferingRitualAction")

function SO_OfferingRitualAction:withinRange()
    local square = self.altar and self.altar:getSquare()
    if not square then return false end
    local ax, ay = square:getX() + 0.5, square:getY() + 0.5
    local dx, dy = self.character:getX() - ax, self.character:getY() - ay
    return (dx * dx + dy * dy) <= (RITUAL_LEASH_TILES * RITUAL_LEASH_TILES)
end

function SO_OfferingRitualAction:isValidStart()
    return self.altar and self.altar:getObjectIndex() ~= -1 and self:withinRange()
end

function SO_OfferingRitualAction:isValid()
    local tx = self.args and self.args.tx
    return not resolvedTransactions[tostring(tx)]
        and self.altar and self.altar:getObjectIndex() ~= -1 and self:withinRange()
end

function SO_OfferingRitualAction:waitToStart()
    self.character:faceThisObject(self.altar)
    return self.character:shouldBeTurning()
end

function SO_OfferingRitualAction:start()
    self:setActionAnim("Loot")
    -- "High" = arms raised toward the underworld. Switch to "Low" for a kneeling
    -- supplication pose instead.
    self.character:SetVariable("LootPosition", "High")
    -- Replicated flag every client watches to render the trance glow/smoke on
    -- this player (the pose already networks with the timed action).
    self.character:SetVariable("SO_InRitual", "true")
    self.action:setUseProgressBar(true)
    SO.Sound.BeginRitual(self.args and self.args.tx)
    -- Commit the attempt while the player is still beside the altar. The server
    -- starts the same smoke omen for every offering and locks in its verdict,
    -- revealing nothing until the channel ends; walking away cannot escape a
    -- verdict of wrath.
    local tx = tostring(self.args and self.args.tx)
    activeTransactions[tx] = self
    SO.Client.SendCommand(SO.COMMAND.BEGIN_OFFERING, self.args)
end

function SO_OfferingRitualAction:stop()
    local tx = tostring(self.args and self.args.tx)
    local wasResolved = resolvedTransactions[tx] == true
    resolvedTransactions[tx] = nil
    activeTransactions[tx] = nil
    if self.character then self.character:SetVariable("SO_InRitual", "false") end
    if not wasResolved then
        SO.Sound.CancelRitual()
        if self.character and not self.character:isDead() then
            SO.Announce.Show(getText("IGUI_SO_RitualBroken"), "bad")
        end
    end
    ISBaseTimedAction.stop(self)
end

function SO_OfferingRitualAction:complete()
    -- Build 42 executes this callback on the server for networked timed actions.
    -- Adjudicate here so completion cannot depend on a second client request.
    -- In single-player there is no mirrored server action, so use the existing
    -- local command bridge instead.
    if isServer() then
        SO.OfferingService.Make(self.character, self.args)
    elseif not isClient() then
        SO.Client.SendCommand(SO.COMMAND.MAKE_OFFERING, self.args)
    end
    return true
end

function SO_OfferingRitualAction:perform()
    -- needed to remove from queue / start next.
    activeTransactions[tostring(self.args and self.args.tx)] = nil
    if self.character then self.character:SetVariable("SO_InRitual", "false") end
    ISBaseTimedAction.perform(self)
end

function SO_OfferingRitualAction:getDuration()
    if self.character:isTimedActionInstant() then return 1 end
    return RITUAL_SECONDS * MAXTIME_UNITS_PER_SECOND
end

function SO_OfferingRitualAction:new(character, altar, args)
    local o = ISBaseTimedAction.new(self, character)
    o.altar = altar
    o.args = args
    -- Distance is the only thing that breaks the channel: drifting within the
    -- leash (and fighting, aiming) must not.
    o.stopOnWalk = false
    o.stopOnRun = false
    o.stopOnAim = false
    -- Keep hand wounds from stretching the ritual well past the intended window.
    o.ignoreHandsWounds = true
    o.useProgressBar = true
    o.maxTime = o:getDuration()
    return o
end

-- True when this player already has a recovery ritual queued or running.
function SO_OfferingRitualAction.IsActive(character)
    local queue = ISTimedActionQueue.getTimedActionQueue(character)
    return queue and queue:indexOfType("SO_OfferingRitualAction") ~= -1
end

-- Called by the result handler when the server adjudicates an offering during
-- the channel rather than at its normal completion.
function SO_OfferingRitualAction.Resolve(tx)
    local key = tx ~= nil and tostring(tx) or nil
    if key and activeTransactions[key] then resolvedTransactions[key] = true end
end

return SO_OfferingRitualAction
