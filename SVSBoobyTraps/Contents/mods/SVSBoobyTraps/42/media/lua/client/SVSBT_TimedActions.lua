require "TimedActions/ISBaseTimedAction"
require "SVSBT_Client"

local Logger = SVSBT.Logger

SVSBTDeviceAction = ISBaseTimedAction:derive("SVSBTDeviceAction")

local function itemById(character, itemId)
    return SVSBT.Client
        and SVSBT.Client.FindItemById
        and SVSBT.Client.FindItemById(character, itemId)
        or nil
end

local function itemIs(character, itemId, expectedType)
    local item = itemById(character, itemId)
    return item and item:getFullType() == expectedType and item or nil
end

local function firstItem(character, fullTypes)
    for _, fullType in ipairs(fullTypes) do
        local item = SVSBT.Client.FindItem(character, fullType)
        if item then return item end
    end
    return nil
end

local function failRequirement(shouldNotify, message)
    if shouldNotify then SVSBT.Client.Notify(message, true) end
    return false, message
end

-- InventoryItem:setJobDelta/setJobType (used by vanilla ISLightFromKindle/
-- ISAddFuelAction) draws a progress fill and label directly on an item's
-- own row in the inventory list -- the same feedback as reading a book,
-- applied to whichever item this action is working on.
local JobLabels = {
    PLACE_FLOOR = "Setting Trap",
    RIG_MAILBOX = "Concealing Parcel",
    PLACE_TRIP_WIRE = "Connecting Wire",
    INSTALL_VEHICLE = "Installing Device",
}

local function trackedItemFor(character, command, args)
    if not args or not args.itemId then return nil end
    local item = itemById(character, args.itemId)
    if item and type(item.setJobDelta) == "function" and type(item.setJobType) == "function" then
        return item
    end
    return nil
end

function SVSBTDeviceAction.CanStart(character, command, args, shouldNotify)
    args = args or {}

    local record
    if args.trapId then
        for _, candidate in ipairs(SVSBT.Client.Visible or {}) do
            if tostring(candidate.trapId) == tostring(args.trapId) then record = candidate; break end
        end
        record = record or (SVSBT.Client.KnownTraps or {})[tostring(args.trapId)]
    end
    if record then
        if record.occupied and (command == "DISARM" or command == "RESET_BEAR" or command == "REPAIR_BEAR") then
            return failRequirement(shouldNotify, "Release the victim before working on this bear trap.")
        end
        if command == "RESET_BEAR" and record.state ~= SVSBT.Shared.State.Sprung then
            return failRequirement(shouldNotify, "This bear trap is not sprung.")
        end
        if command == "REPAIR_BEAR" and tonumber(record.condition) and tonumber(record.maxCondition)
            and record.condition >= record.maxCondition then
            return failRequirement(shouldNotify, "This bear trap is already at its maximum condition.")
        end
        if command == "DISARM" and not SVSBT.Shared.IsAdmin(character) then
            if args.operation ~= "salvage" and record.state ~= SVSBT.Shared.State.Armed then
                return failRequirement(shouldNotify, "This trap is not armed.")
            end
            local gap = SVSBT.Shared.RequirementGap(character, record.kind, "disarm")
                or SVSBT.Shared.RecipeGap(character, record.kind)
            if gap then return failRequirement(shouldNotify, gap) end
        end
    end
    if command == "FREE_BEAR" then
        if record and not record.occupied then
            return failRequirement(shouldNotify, "There is no victim in this bear trap.")
        end
        local heldId = character and character:getModData().SVSBT_BearTrapHeldId
        local freeingSelf = (heldId and tostring(heldId) == tostring(args.trapId)) or (record and record.holdsYou)
        if freeingSelf and not SVSBT.Shared.HeldWeapon(character) then
            return failRequirement(shouldNotify, "Equip a usable weapon in either hand before releasing yourself.")
        end
    end

    if command == "PLACE_FLOOR" then
        -- The item may be carried, or already a loose item lying on the
        -- target square (spotted on the ground and set without picking it
        -- up first).
        local item = itemById(character, args.itemId)
        if not item and type(SVSBT.Shared.WorldItemAt) == "function" then
            local ground = SVSBT.Shared.WorldItemAt(args.x, args.y, args.z, args.itemId)
            item = ground and ground:getItem() or nil
        end
        local kind = item and SVSBT.Shared.ItemToKind[item:getFullType()] or nil
        if not kind then
            return failRequirement(shouldNotify, "The booby trap to place is no longer available.")
        end
        if not SVSBT.Shared.IsAdmin(character) then
            local recipeGap = SVSBT.Shared.RecipeGap(character, kind)
            if recipeGap then return failRequirement(shouldNotify, recipeGap) end
            local gap = SVSBT.Shared.RequirementGap(character, kind)
            if gap then return failRequirement(shouldNotify, gap) end
        end
    elseif command == "PLACE_TRIP_WIRE" then
        if not itemIs(character, args.itemId, SVSBT.Shared.Item.TripWireKit) then
            return failRequirement(shouldNotify, "A Trip Wire Kit is required.")
        end
        if not SVSBT.Shared.IsAdmin(character) then
            local gap = SVSBT.Shared.RecipeGap(character, SVSBT.Shared.Kind.TripWire)
            if gap then return failRequirement(shouldNotify, gap) end
        end
    elseif command == "RIG_MAILBOX" then
        if not itemIs(character, args.itemId, SVSBT.Shared.Item.ExplosiveParcel) then
            return failRequirement(shouldNotify, "An Explosive Parcel is required.")
        end
        if not SVSBT.Shared.IsAdmin(character) then
            local gap = SVSBT.Shared.RecipeGap(character, SVSBT.Shared.Kind.ExplosiveMailbox)
            if gap then return failRequirement(shouldNotify, gap) end
        end
    elseif command == "INSTALL_VEHICLE" then
        -- Everything Service.InstallVehicleDevice would reject for a reason
        -- the CLIENT can already see -- check it here so the timed action
        -- never even starts, instead of running the full animation just to
        -- fail at the end. Server-only state (safehouse ownership, the exact
        -- per-vehicle device cap) still gets the final, authoritative say.
        local item = itemById(character, args.itemId)
        local kind = item and SVSBT.Shared.ItemToKind[item:getFullType()] or nil
        if not kind or not SVSBT.Shared.VehicleKinds[kind] then
            return failRequirement(shouldNotify, "The vehicle booby trap is no longer in your inventory.")
        end
        if not SVSBT.Shared.FeatureEnabledForKind(kind) then
            return failRequirement(shouldNotify, "This device is currently disabled on this server.")
        end
        if not SVSBT.Shared.IsAdmin(character) then
            if character and type(character.getHoursSurvived) == "function"
                and tonumber(character:getHoursSurvived()) < SVSBT.Config.Get("MinimumOwnerSurvivalHours") then
                return failRequirement(shouldNotify, "You haven't survived long enough to set up covert devices yet.")
            end
            local recipeGap = SVSBT.Shared.RecipeGap(character, kind)
            if recipeGap then return failRequirement(shouldNotify, recipeGap) end
            local gap = SVSBT.Shared.RequirementGap(character, kind)
            if gap then return failRequirement(shouldNotify, gap) end
        end
        local vehicle = type(getVehicleById) == "function" and getVehicleById(args.vehicleId) or nil
        if not vehicle then
            return failRequirement(shouldNotify, "That vehicle is no longer available.")
        end
        if vehicle:getCurrentSpeedKmHour() and math.abs(vehicle:getCurrentSpeedKmHour()) > 0.1 then
            return failRequirement(shouldNotify, "The vehicle must be stationary to install this.")
        end
        if kind == SVSBT.Shared.Kind.IgnitionCharge and vehicle:isEngineRunning() then
            return failRequirement(shouldNotify, "The engine must be off to install an ignition charge.")
        end
        local uid = SVSBT.Shared.VehicleUID(vehicle, false)
        local function alreadyInstalled(record)
            return record.vehicleUid == uid and record.kind == kind
                and record.state ~= "destroyed" and record.state ~= "spent"
        end
        for _, record in pairs(SVSBT.Client.KnownTraps or {}) do
            if alreadyInstalled(record) then
                return failRequirement(shouldNotify, "This vehicle already has that device installed.")
            end
        end
        for _, record in ipairs(SVSBT.Client.Visible or {}) do
            if alreadyInstalled(record) then
                return failRequirement(shouldNotify, "This vehicle already has that device installed.")
            end
        end
    elseif command == "CONTAMINATE_DOCUMENT" then
        if not itemIs(character, args.agentItemId, SVSBT.Shared.Item.AnthraxAgent) then
            return failRequirement(shouldNotify, "A prepared biological agent is required.")
        end
        if not itemById(character, args.documentItemId) then
            return failRequirement(shouldNotify, "The document to contaminate is no longer in your inventory.")
        end
        if not SVSBT.Shared.IsAdmin(character) then
            local gap = SVSBT.Shared.RecipeGap(character, SVSBT.Shared.Kind.AnthraxDocument)
            if gap then return failRequirement(shouldNotify, gap) end
        end
    elseif command == "RESET_BEAR" then
        if not SVSBT.Shared.BearTrapResetTool(character) then
            return failRequirement(shouldNotify, "Hold a usable tool or weapon to reset the bear trap.")
        end
    elseif command == "REPAIR_BEAR" then
        if not SVSBT.Client.FindItem(character, "Base.WeldingRods") then
            return failRequirement(shouldNotify, "Welding rods are required to repair this bear trap.")
        end
        if not firstItem(character, { "Base.WeldingMask", "Base.Glasses_OldWeldingGoggles" }) then
            return failRequirement(shouldNotify, "A welding mask or welding goggles are required.")
        end
        local torch = SVSBT.Client.FindItem(character, "Base.BlowTorch")
        local torchEmpty = torch and (
            (torch.isEmptyUses and torch:isEmptyUses())
            or (torch.getCurrentUsesFloat and torch:getCurrentUsesFloat() <= 0))
        if not torch or torchEmpty then
            return failRequirement(shouldNotify, "A blowtorch with fuel is required to repair this bear trap.")
        end
    elseif command == "RF_SCAN" then
        if not itemIs(character, args.detectorItemId, "GPSMod.RF_SignalDetector") then
            return failRequirement(shouldNotify, "An RF Signal Detector is required.")
        end
    end

    return true
end

function SVSBTDeviceAction:isValid()
    local run = Logger.Begin("SVSBTDeviceAction.isValid", self.command)
    local valid = self.character ~= nil and not self.character:isDead()

    if valid and self.startX and self.startY then
        valid = SVSBT.Shared.Distance(self.character:getX(), self.character:getY(), self.startX, self.startY) <= 1.5
    end

    if valid and (self.command == "RESET_BEAR" or self.command == "FREE_BEAR"
        or self.command == "REPAIR_BEAR" or self.command == "DISARM") then
        valid = SVSBTDeviceAction.CanStart(self.character, self.command, self.args, false)
    end

    Logger.Finish(run, valid, "valid=" .. tostring(valid))
    return valid
end

function SVSBTDeviceAction:waitToStart()
    local run = Logger.Begin("SVSBTDeviceAction.waitToStart")
    Logger.Finish(run, true, "ready")
    return false
end

function SVSBTDeviceAction:update()
    local run = Logger.Begin("SVSBTDeviceAction.update", self.command)

    if self.trackedItem and type(self.trackedItem.setJobDelta) == "function" then
        self.trackedItem:setJobDelta(self:getJobDelta())
    end

    Logger.Finish(run, true, "base action owns progress")
end

local function clearTrackedItem(action)
    if action.trackedItem and type(action.trackedItem.setJobDelta) == "function" then
        action.trackedItem:setJobDelta(0.0)
    end
    action.trackedItem = nil
end

function SVSBTDeviceAction:start()
    local run = Logger.Begin("SVSBTDeviceAction.start", self.command)

    if not SVSBTDeviceAction.CanStart(
        self.character, self.command, self.args, true)
    then
        self:forceStop()
        Logger.Finish(run, false, "requirements changed before start")
        return
    end

    self.startX, self.startY = self.character:getX(), self.character:getY()
    self:setActionAnim(self.actionAnim or "Loot")

    if self.immediateCommand then return end
    self.actionId = tostring(type(getTimestampMs) == "function" and getTimestampMs() or 0)
        .. "-" .. tostring(type(ZombRand) == "function" and ZombRand(100000, 999999) or math.random(100000, 999999))
    self.args.actionId = self.actionId

    self.trackedItem = trackedItemFor(self.character, self.command, self.args)
    if self.trackedItem then
        self.trackedItem:setJobType(JobLabels[self.command] or "Working")
        self.trackedItem:setJobDelta(0.0)
    end
    SVSBT.Client.SendCommand("ACTION_BEGIN", {
        actionId = self.actionId,
        command = self.command,
        payload = self.args,
    }, self.character)
    Logger.Finish(run, true)
end

function SVSBTDeviceAction:stop()
    local run = Logger.Begin("SVSBTDeviceAction.stop", self.command)
    clearTrackedItem(self)
    ISBaseTimedAction.stop(self)
    Logger.Finish(run, true)
end

function SVSBTDeviceAction:perform()
    local run = Logger.Begin("SVSBTDeviceAction.perform", self.command)
    clearTrackedItem(self)
    SVSBT.Client.SendCommand(self.command, self.args, self.character)
    ISBaseTimedAction.perform(self)
    Logger.Finish(run, true, "command sent")
end

function SVSBTDeviceAction:new(character, command, args, seconds, actionAnim)
    local run = Logger.Begin("SVSBTDeviceAction.new", command)
    local action = ISBaseTimedAction.new(self, character)
    action.command = command
    action.args = args or {}
    -- ISBaseTimedAction advances by ~GameTime:getMultiplier() per tick; ~90 units
    -- is roughly one real second at normal game speed. The previous *30 finished
    -- in ~a third of the configured time, which the server rejected as too quick.
    if character and type(character.isTimedActionInstant) == "function" and character:isTimedActionInstant() then
        action.maxTime = 1
    else
        action.maxTime = math.max(1, math.floor((tonumber(seconds) or 1) * 90))
    end
    action.actionAnim = actionAnim or "Loot"
    action.stopOnWalk = true
    action.stopOnRun = true
    action.stopOnAim = true
    -- Capture the interaction origin in start(), after queued walking finishes.
    Logger.Finish(run, true, "seconds=" .. tostring(seconds))
    return action
end

Logger.Info("SVSBT_TimedActions.load", "authoritative device action loaded")

return SVSBTDeviceAction
