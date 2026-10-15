require "SVSBT_Config"

SVSBT.Recipes = SVSBT.Recipes or {}
local Recipes = SVSBT.Recipes
local Config = SVSBT.Config
local Logger = SVSBT.Logger

-- Skill gating is done natively via SkillRequired in the recipe script so the
-- crafting UI can show it. These OnTest hooks only apply the per-trap Sandbox
-- feature toggles plus the "full container" ingredient checks.

local function enabled(kind)
    return SVSBT.Shared.FeatureEnabledForKind(kind)
end

local function advancedEnabled()
    return Config.Get("Enabled") and Config.Get("AdvancedTrapsEnabled")
end

local function isFullContainer(item)
    if type(item.isFullUses) == "function" then
        return item:isFullUses() == true
    end
    if type(item.getCurrentUsesFloat) == "function" and type(item.getMaxUses) == "function" then
        return item:getCurrentUsesFloat() >= (item:getMaxUses() - 0.001)
    end
    return true
end

function Recipes.TestWaterBucket(item, _character)
    local run = Logger.Begin("Recipes.TestWaterBucket")
    local result = enabled(SVSBT.Shared.Kind.WaterBucket) == true

    if result and item and item:getFullType() == "Base.Bucket" then
        local fluid = type(item.getFluidContainer) == "function" and item:getFluidContainer() or nil
        result = fluid ~= nil and fluid:contains(Fluid.Water)
            and fluid:getAmount() >= (fluid:getCapacity() - 0.001)
    end

    Logger.Finish(run, result, "available=" .. tostring(result))
    return result
end

function Recipes.TestNailBoard(_item, _character)
    local run = Logger.Begin("Recipes.TestNailBoard")
    local result = enabled(SVSBT.Shared.Kind.NailBoard) == true
    Logger.Finish(run, result, "available=" .. tostring(result))
    return result
end

function Recipes.TestShotgunDoorTrap(_item, _character)
    local run = Logger.Begin("Recipes.TestShotgunDoorTrap")
    local result = enabled(SVSBT.Shared.Kind.ShotgunDoor) == true
    Logger.Finish(run, result, "available=" .. tostring(result))
    return result
end

function Recipes.TestTripWire(_item, _character)
    local run = Logger.Begin("Recipes.TestTripWire")
    local result = enabled(SVSBT.Shared.Kind.TripWire) == true
    Logger.Finish(run, result, "available=" .. tostring(result))
    return result
end

function Recipes.TestBearTrap(item, _character)
    local run = Logger.Begin("Recipes.TestBearTrap")
    local result = enabled(SVSBT.Shared.Kind.BearTrap) == true

    if result and item and item:getFullType() == "Base.BlowTorch" then
        result = isFullContainer(item)
    end

    Logger.Finish(run, result, "available=" .. tostring(result))
    return result
end

function Recipes.TestExplosiveParcel(_item, _character)
    local run = Logger.Begin("Recipes.TestExplosiveParcel")
    local result = advancedEnabled() and Config.Get("ExplosiveMailboxEnabled") == true
    Logger.Finish(run, result, "available=" .. tostring(result))
    return result == true
end

function Recipes.TestVehicleDevice(_item, _character)
    local run = Logger.Begin("Recipes.TestVehicleDevice")
    local result = advancedEnabled() and Config.Get("VehicleDevicesEnabled") == true
    Logger.Finish(run, result, "available=" .. tostring(result))
    return result == true
end

function Recipes.TestBiological(_item, _character)
    local run = Logger.Begin("Recipes.TestBiological")
    local result = advancedEnabled() and Config.Get("AnthraxEnabled") == true
    Logger.Finish(run, result, "available=" .. tostring(result))
    return result == true
end

-- OnCreate: keep only side effects that native crafting can't express.
local function noop() return true end
Recipes.OnCreateWaterBucket = noop
Recipes.OnCreateNailBoard = noop
Recipes.OnCreateExplosiveParcel = noop
Recipes.OnCreateBiologicalAgent = noop
Recipes.OnCreateIgnitionCharge = noop
Recipes.OnCreateDriverSeatDye = noop
Recipes.OnCreateTamperAlarm = noop
Recipes.OnCreateRemoteImmobilizer = noop

function Recipes.OnCreateBearTrap(craftRecipeData, character)
    local run = Logger.Begin("Recipes.OnCreateBearTrap")
    local drained = false

    local items = craftRecipeData and type(craftRecipeData.getAllInputItems) == "function"
        and craftRecipeData:getAllInputItems() or nil

    if items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)

            if item and item:getFullType() == "Base.BlowTorch" then
                if type(item.setUsedDelta) == "function" then
                    item:setUsedDelta(0)
                elseif type(item.setCurrentUses) == "function" then
                    item:setCurrentUses(0)
                end

                drained = true
                break
            end
        end
    end

    Logger.Audit("CRAFT_BEAR_TRAP", SVSBT.Shared.Username(character), "fullTorchDrained=" .. tostring(drained))
    Logger.Finish(run, true, "torch capacity consumed=" .. tostring(drained))
    return true
end

Logger.Info("SVSBT_RecipeCallbacks.load", "recipe feature-toggle gates initialized")

return Recipes
