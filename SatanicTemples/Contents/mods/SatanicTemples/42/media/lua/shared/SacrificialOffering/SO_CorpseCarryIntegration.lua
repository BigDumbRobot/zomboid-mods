require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "TimedActions/ISBaseTimedAction"
require "TimedActions/ISGrabCorpseAction"
require "TimedActions/ISGrabCorpseItem"

local SO = SacrificialOffering
SO.CorpseCarryIntegration = SO.CorpseCarryIntegration or {}
local Integration = SO.CorpseCarryIntegration

-- Equipped items receive B42's worn/equipped encumbrance discount. A vanilla
-- human corpse weighs only 20. At 90 the two-handed carry pushes an ordinary
-- survivor near or past their carry limit, so vanilla forces the slow,
-- heavy-breathing overburdened walk: the body can always be hauled, but never
-- comfortably. A strong survivor still manages it with room to spare.
-- The override is temporary -- the instant the corpse leaves both hands its
-- weight is restored to vanilla so it stays honest for containers and other mods.
local CARRIED_HUMAN_CORPSE_WEIGHT = 90
local VANILLA_HUMAN_CORPSE_WEIGHT = 20

-- Extra endurance bleed per real second while actually walking with a body in
-- hand, on top of whatever the overburdened state already costs.
local CARRY_ENDURANCE_DRAIN_PER_SEC = 0.02
local CARRYING_VARIABLE = "SO_CarryingCorpse"

if Integration.Installed then return Integration end
Integration.Installed = true

-- Weight is authoritative on the dedicated server, and on the local machine in
-- single-player. An MP client leaves the weight alone -- the server owns it.
local WEIGHT_AUTHORITY = isServer() or not isClient()

local function isHumanCorpseItem(item)
    if not item then return false end
    local fullType = item:getFullType()
    return fullType == "Base.CorpseMale" or fullType == "Base.CorpseFemale"
end

local function markCarried(item)
    if not isHumanCorpseItem(item) then return false end
    item:getModData()[SO.MOD_DATA.CARRIED_CORPSE] = true
    if item:getActualWeight() < CARRIED_HUMAN_CORPSE_WEIGHT then
        item:setWeight(CARRIED_HUMAN_CORPSE_WEIGHT)
        item:setActualWeight(CARRIED_HUMAN_CORPSE_WEIGHT)
        item:setCustomWeight(true)
    end
    return true
end

-- Undo markCarried: drop the flag and return the item to its script weight.
local function restoreCorpseWeight(item)
    if not isHumanCorpseItem(item) then return end
    pcall(function()
        item:getModData()[SO.MOD_DATA.CARRIED_CORPSE] = nil
        local base = VANILLA_HUMAN_CORPSE_WEIGHT
        local script = item.getScriptItem and item:getScriptItem()
        if script and script.getActualWeight then
            local scripted = tonumber(script:getActualWeight())
            if scripted and scripted > 0 then base = scripted end
        end
        item:setActualWeight(base)
        item:setWeight(base)
        item:setCustomWeight(false)
    end)
end

-- Public: used by SO_DropCorpseIntoAltarAction to un-weight a corpse before it
-- is thrown into the altar, so the fit check and transfer never reject it.
Integration.RestoreCorpseWeight = restoreCorpseWeight
Integration.IsHumanCorpseItem = isHumanCorpseItem

-- Pure read: does this corpse item still carry the "being hauled" flag.
function Integration.IsCarriedHumanCorpse(item)
    if not isHumanCorpseItem(item) then return false end
    local md = item:getModData()
    return md ~= nil and md[SO.MOD_DATA.CARRIED_CORPSE] == true
end

local function setCarryingFlag(character, carrying)
    if not character or not character.SetVariable then return end
    character:SetVariable(CARRYING_VARIABLE, carrying and "true" or "false")
end

local function equipCorpseItem(character, item)
    markCarried(item)
    character:getInventory():AddItem(item)
    sendAddItemToContainer(character:getInventory(), item)
    character:setPrimaryHandItem(item)
    character:setSecondaryHandItem(item)
    setCarryingFlag(character, true)
    if isServer() then sendEquip(character) end
end

-- ---------------------------------------------------------------------------
-- Pickup: B42 normally grapples human corpses but converts animal bodies into
-- inventory items held in both hands. Use that proven animal path for human
-- corpses too.
--
-- ONLY :complete is overridden. Do NOT wrap :new / :start / :getDuration or
-- touch maxTime / stopOnWalk on ISGrabCorpseAction / ISGrabCorpseItem -- every
-- attempt to do so has broken corpse pickup entirely.
-- ---------------------------------------------------------------------------


local vanillaGrabCorpseComplete = ISGrabCorpseAction.complete
function ISGrabCorpseAction:complete()
    if not isHumanCorpseItem(self.corpse) then
        return vanillaGrabCorpseComplete(self)
    end
    if not self.corpseBody then return false end

    -- Copy the corpse's authoritative owner/name into the item before the world
    -- body is removed.
    if SO.PlayerLedger and SO.PlayerLedger.TagPlayerCorpse then
        SO.PlayerLedger.TagPlayerCorpse(self.corpseBody, "carried-pickup")
        self.corpse = self.corpseBody:getItem()
    end

    equipCorpseItem(self.character, self.corpse)
    self.corpseBody:getSquare():removeCorpse(self.corpseBody, false)
    return true
end

-- Corpses retrieved from a dumpster or another container must use the same
-- two-handed inventory representation instead of re-entering grapple mode.
local vanillaGrabCorpseItemComplete = ISGrabCorpseItem.complete
function ISGrabCorpseItem:complete()
    if not isHumanCorpseItem(self.item) then
        return vanillaGrabCorpseItemComplete(self)
    end

    forceDropHeavyItems(self.character)
    local source = self.item:getContainer()
    if not source or not source:contains(self.item) then return false end
    source:DoRemoveItem(self.item)
    sendRemoveItemFromContainer(source, self.item)

    if source:getParent() and instanceof(source:getParent(), "BaseVehicle")
        and source:getParent():getPartById(source:getType()) then
        local part = source:getParent():getPartById(source:getType())
        part:setContainerContentAmount(part:getItemContainer():getCapacityWeight())
    end

    equipCorpseItem(self.character, self.item)
    return true
end

-- ---------------------------------------------------------------------------
-- Carry: restore the corpse's weight the moment it leaves both hands, keep the
-- animation flag in sync, and bleed endurance while lugging it. Over-encumbrance
-- from the weight above already forces the slow, no-sprint, panting walk.
-- ---------------------------------------------------------------------------

-- A carried corpse is the same item in both hands (equipCorpseItem sets both).
local function currentCarriedCorpse(player)
    if not player or not player.getPrimaryHandItem then return nil end
    local primary = player:getPrimaryHandItem()
    if primary and isHumanCorpseItem(primary) and primary == player:getSecondaryHandItem() then
        return primary
    end
    return nil
end

-- The human corpse a character is hauling in both hands right now, or nil.
function Integration.CarriedCorpse(character)
    return currentCarriedCorpse(character)
end

local lastDrainMs = nil
local heldCorpseBy = {}

local function playerKey(player)
    return (player.getOnlineID and player:getOnlineID()) or "sp"
end

local function updateCarrier(player, localSide)
    if not player then return end
    local held = currentCarriedCorpse(player)
    local carrying = held ~= nil

    if WEIGHT_AUTHORITY then
        local key = playerKey(player)
        if held then
            markCarried(held)
            heldCorpseBy[key] = held
        elseif heldCorpseBy[key] then
            restoreCorpseWeight(heldCorpseBy[key])
            heldCorpseBy[key] = nil
        end
    end

    local flagged = player.getVariableString and player:getVariableString(CARRYING_VARIABLE) == "true"
    if carrying ~= flagged then setCarryingFlag(player, carrying) end
    if not carrying or not localSide then
        lastDrainMs = nil
        return
    end

    local now = SO.Util.NowMs()
    local elapsed = lastDrainMs and math.min((now - lastDrainMs) / 1000, 0.5) or 0
    lastDrainMs = now

    local moving = true
    if player.isPlayerMoving then moving = player:isPlayerMoving() end
    local stats = player.getStats and player:getStats()
    if moving and elapsed > 0 and stats and stats.setEndurance then
        pcall(function()
            stats:setEndurance(math.max(0,
                (stats:getEndurance() or 1) - CARRY_ENDURANCE_DRAIN_PER_SEC * elapsed))
        end)
    end
end

local CARRY_TICK_MS = 250
local nextCarryTickAt = 0

local function onTick()
    local now = SO.Util.NowMs()
    if now < nextCarryTickAt then return end
    nextCarryTickAt = now + CARRY_TICK_MS
    if isServer() then
        local players = getOnlinePlayers()
        if not players then return end
        local online = {}
        for index = 0, players:size() - 1 do
            local player = players:get(index)
            online[playerKey(player)] = true
            updateCarrier(player, false)
        end
        for key, item in pairs(heldCorpseBy) do
            if not online[key] then
                restoreCorpseWeight(item)
                heldCorpseBy[key] = nil
            end
        end
    else
        updateCarrier(getPlayer(), true)
    end
end

Events.OnTick.Add(onTick)

return Integration
