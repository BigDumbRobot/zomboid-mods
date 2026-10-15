-- Prevent KIPN-owned Build 42 craft recipes from entering (or remaining in)
-- the timed-action queue when their material inputs are unavailable.  The
-- server/engine recipe logic still performs the authoritative craft.

if isServer() then
    return
end

local actionAvailable = pcall(require, "Entity/TimedActions/ISHandcraftAction")
local uiAvailable = pcall(require, "Entity/ISEntityUI")

if not actionAvailable or not ISHandcraftAction then
    return
end

local function recipeName(recipe)
    if not recipe then return "" end
    if type(recipe.getName) == "function" then
        return tostring(recipe:getName() or "")
    end
    if type(recipe.getOriginalname) == "function" then
        return tostring(recipe:getOriginalname() or "")
    end
    return ""
end

local function isKIPNRecipe(recipe)
    local name = recipeName(recipe)
    return string.sub(name, 1, 5) == "KIPN."
        or string.sub(name, 1, 12) == "KIPNCareers."
end

local function canPerform(logic)
    if not logic or type(logic.canPerformCurrentRecipe) ~= "function" then
        return false
    end
    local ok, result = pcall(function()
        return logic:canPerformCurrentRecipe()
    end)
    return ok and result == true
end

local function canPerformMultiple(logic, quantity)
    if not logic or type(logic.getPossibleCraftCount) ~= "function" then
        return canPerform(logic)
    end
    local ok, count = pcall(function()
        return logic:getPossibleCraftCount(true)
    end)
    return ok and (tonumber(count) or 0) >= math.max(1, tonumber(quantity) or 1)
end

local function notify(player, action)
    if action and action.KIPN_MissingMaterialsNotified then return end
    if action then action.KIPN_MissingMaterialsNotified = true end

    local message = "You do not have all the materials required to craft this item."
    player = player or (type(getPlayer) == "function" and getPlayer() or nil)
    if player and type(player.setHaloNote) == "function" then
        player:setHaloNote(message, 255, 80, 80, 300)
    elseif player and type(player.Say) == "function" then
        player:Say(message)
    end
end


if uiAvailable and ISEntityUI
    and ISEntityUI.HandcraftStartMultiple
    and not ISEntityUI.KIPN_OriginalHandcraftStartMultiple
then
    ISEntityUI.KIPN_OriginalHandcraftStartMultiple =
        ISEntityUI.HandcraftStartMultiple

    function ISEntityUI.HandcraftStartMultiple(player, logic, force, qty, addToQueue)
        local recipe = logic and type(logic.getRecipe) == "function"
            and logic:getRecipe() or nil

        if isKIPNRecipe(recipe) and not canPerformMultiple(logic, qty) then
            notify(player)
            return nil
        end

        return ISEntityUI.KIPN_OriginalHandcraftStartMultiple(
            player, logic, force, qty, addToQueue)
    end
end

-- This wrapper is deliberately recipe-scoped and delegates every unrelated
-- recipe unchanged, allowing it to compose with other mods that wrap the same
-- vanilla entry point.
if uiAvailable and ISEntityUI and not ISEntityUI.KIPN_OriginalHandcraftStart then
    ISEntityUI.KIPN_OriginalHandcraftStart = ISEntityUI.HandcraftStart

    function ISEntityUI.HandcraftStart(player, logic, force, addToQueue, eatPercentage)
        local recipe = logic and type(logic.getRecipe) == "function"
            and logic:getRecipe() or nil

        if isKIPNRecipe(recipe) and not canPerform(logic) then
            notify(player)
            return nil
        end

        return ISEntityUI.KIPN_OriginalHandcraftStart(
            player, logic, force, addToQueue, eatPercentage)
    end
end

-- Inputs may disappear while this action waits behind another action.  Build
-- 42 does not consistently recheck automatically selected inputs at start.
-- Manually selected inputs (the craft window's) are rechecked by vanilla
-- start() itself; checking its logic again afterwards reports them missing
-- and cancelled every KIPN craft.
if not ISHandcraftAction.KIPN_OriginalStart then
    ISHandcraftAction.KIPN_OriginalStart = ISHandcraftAction.start

    function ISHandcraftAction:start()
        local result = ISHandcraftAction.KIPN_OriginalStart(self)

        if isKIPNRecipe(self.craftRecipe) and not self.manualInputs
            and not canPerform(self.logic) then
            notify(self.character, self)
            self:forceStop()
        end

        return result
    end
end

return true
