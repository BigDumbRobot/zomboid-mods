-- KIPN_EventLoadoutClient.lua
--
-- The player's half of a starting loadout (server/KIPN_EventLoadoutService.lua):
-- once the server has handed the items over, put the clothes on, sling
-- the bag, take the weapon in hand, and apply the loadout's condition --
-- hunger, drunkenness, panic, and the patient's splinted fracture or
-- the crashed pilot's cuts and burns. Harder difficulties hurt more,
-- as in Pillow's scenarios.

if isServer() and not isClient() then return end

require "DynamicEvents_Shared"

KIPN_EventLoadoutClient = KIPN_EventLoadoutClient or {}
local C = KIPN_EventLoadoutClient

-- Items arrive a moment after the message; wait this many ticks.
C.WAIT_TICKS = 30

local pending

local function findItem(inventory, fullType, used)
    local found
    local ok, items = pcall(function() return inventory:getItems() end)
    if not ok or not items then return nil end
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item and not used[item] and item:getFullType() == fullType then found = item end
    end
    if found then used[found] = true end
    return found
end

local function setStat(player, name, value)
    local stats = player:getStats()
    local ok = pcall(function() stats:set(CharacterStat[name], value) end)
    if ok then return end
    -- Build 41-style setters, as Pillow's scenarios use.
    local setters = { THIRST = "setThirst", HUNGER = "setHunger", FATIGUE = "setFatigue", PANIC = "setPanic",
        STRESS = "setStress", INTOXICATION = "setDrunkenness" }
    pcall(function() stats[setters[name]](stats, value) end)
end

local LIMBS = { "LowerLeg_R", "LowerLeg_L", "UpperLeg_R", "UpperLeg_L", "UpperArm_L", "LowerArm_L", "UpperArm_R", "LowerArm_R" }
local ANY_PART = { "Hand_L", "Hand_R", "ForeArm_L", "ForeArm_R", "UpperArm_L", "UpperArm_R", "Torso_Upper", "Torso_Lower",
    "UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R", "Foot_L", "Foot_R", "Head", "Neck" }

local function part(player, name)
    local ok, bodyPart = pcall(function() return player:getBodyDamage():getBodyPart(BodyPartType[name]) end)
    return ok and bodyPart or nil
end

-- scale: 1 Normal, 2 Dire, 3 Brutal.
local function injure(player, injuries, scale)
    -- Hospital patient: a broken limb, splinted and bandaged.
    for _ = 1, (injuries.fracture or 0) do
        local limb = part(player, LIMBS[ZombRand(#LIMBS) + 1])
        if limb then
            pcall(function()
                limb:AddDamage(20 + 5 * scale)
                limb:setFractureTime(25 + 10 * scale)
                limb:setSplint(true, 0.8)
                limb:setBandaged(true, 5, true, "Base.AlcoholBandage")
            end)
        end
    end
    -- Crashed pilot: cuts, scratches, deep wounds and burns.
    for _ = 1, (injuries.wounds or 0) + scale - 1 do
        local bodyPart = part(player, ANY_PART[ZombRand(#ANY_PART) + 1])
        if bodyPart then
            local kind = ZombRand(4)
            pcall(function()
                if kind == 0 then
                    bodyPart:setCut(true)
                    bodyPart:setCutTime(10 + 5 * scale)
                    bodyPart:setBleedingTime(5 + 5 * scale)
                elseif kind == 1 then
                    bodyPart:SetScratchedWeapon(true)
                    bodyPart:setBleedingTime(5 + 3 * scale)
                elseif kind == 2 then
                    bodyPart:setDeepWounded(true)
                    bodyPart:setDeepWoundTime(10 + 5 * scale)
                    bodyPart:setBleedingTime(5 + 5 * scale)
                else
                    bodyPart:setBurnTime(10 + 10 * scale)
                end
            end)
        end
    end
end

function C.Apply(data)
    local player = getPlayer()
    if not player then return end
    local inventory = player:getInventory()
    local used = {}

    for _, fullType in ipairs(data.wear or {}) do
        local item = findItem(inventory, fullType, used)
        if item then pcall(function() player:setWornItem(item:getBodyLocation(), item) end) end
    end
    if data.bag then
        local bag = findItem(inventory, data.bag, used)
        if bag then pcall(function() player:setClothingItem_Back(bag) end) end
    end
    if data.hands then
        local weapon = findItem(inventory, data.hands, used)
        if weapon then
            pcall(function()
                player:setPrimaryHandItem(weapon)
                if data.twoHanded then player:setSecondaryHandItem(weapon) end
            end)
        end
    end

    local scale = ((KIPN.Shared.EventDifficulties or {})[data.difficulty or "NORMAL"] or {}).injuries or 1
    for name, value in pairs(data.stats or {}) do
        -- Harder difficulties start hungrier and more tired (Pillow's statmod).
        local adjusted = value
        if name == "THIRST" or name == "HUNGER" or name == "FATIGUE" then adjusted = math.min(1, value + 0.1 * (scale - 1)) end
        if name == "INTOXICATION" then adjusted = math.min(100, value + 25 * (scale - 1)) end
        setStat(player, name, adjusted)
    end
    if data.injuries then injure(player, data.injuries, scale) end
    pcall(function() player:resetModelNextFrame() end)
end

local function onTick()
    if not pending then return end
    pending.wait = pending.wait - 1
    if pending.wait > 0 then return end
    local data = pending.data
    pending = nil
    local ok, err = pcall(C.Apply, data)
    if not ok then print("[Dynamic Events] Loadout could not be applied: " .. tostring(err)) end
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN" or not args then return end
    local Shared = KIPN and KIPN.Shared
    if not Shared or command ~= Shared.Commands.SERVER_RESPONSE then return end
    if args.event ~= Shared.ResponseEvents.EVENT_APPLY_LOADOUT then return end
    pending = { data = args.data or {}, wait = C.WAIT_TICKS }
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
