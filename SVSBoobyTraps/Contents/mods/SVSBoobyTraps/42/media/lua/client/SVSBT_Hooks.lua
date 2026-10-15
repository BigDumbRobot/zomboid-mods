require "SVSBT_Client"
require "TimedActions/ISReadABook"
require "ISUI/ISInventoryPage"
require "TimedActions/ISGrabItemAction"

local Client = SVSBT.Client
local Shared = SVSBT.Shared
local Config = SVSBT.Config
local Logger = SVSBT.Logger

SVSBT.Hooks = SVSBT.Hooks or { Patched = false }
local Hooks = SVSBT.Hooks

-- The whole premise of a booby trap: it must not be possible to just walk up
-- and grab it off the ground for free. ISGrabItemAction is the vanilla
-- timed action behind both the direct-interact and right-click "Grab" world
-- item pickup -- veto it at :start(),
-- before createItemTransaction ever runs, so nothing gets added to
-- inventory either way. The server re-validates everything from the
-- reported trapId; this is only ever a fast local skip so an ordinary,
-- non-trap item pickup never even notices the check.
local function patchGrabItem()
    local run = Logger.Begin("Hooks.patchGrabItem")

    if not ISGrabItemAction then
        Logger.Audit("HOOKS_PATCH_GRAB", "client", "ISGrabItemAction global does not exist -- cannot patch.")
        Logger.Finish(run, true, "unavailable")
        return false
    end

    if ISGrabItemAction.SVSBT_OriginalStart then
        Logger.Finish(run, true, "already patched")
        return false
    end

    ISGrabItemAction.SVSBT_OriginalStart = ISGrabItemAction.start

    function ISGrabItemAction:start()
        local actionRun = Logger.Begin("Hooks.ISGrabItemAction.start")
        local worldItem = self.item
        local carriedItem = worldItem and type(worldItem.getItem) == "function" and worldItem:getItem() or nil
        local data = carriedItem and type(carriedItem.getModData) == "function" and carriedItem:getModData() or nil
        -- Live updates arrive on the existing world object. Item ModData is
        -- only the initial snapshot (and fallback for older saved objects).
        local worldData = worldItem and type(worldItem.getModData) == "function" and worldItem:getModData() or nil
        if worldData and worldData.SVSBT_TrapId then data = worldData end
        local kind = carriedItem and Shared.ItemToKind[carriedItem:getFullType()]
        local live = data and data.SVSBT_TrapId
            and kind and Shared.FloorKinds[kind]
            and (data.SVSBT_State == Shared.State.Armed or data.SVSBT_State == Shared.State.Sprung)
            and data.SVSBT_ArmPending ~= true

        if live then
            Logger.Audit("HOOKS_GRAB_BLOCKED", Shared.Username(self.character), "trapId=" .. tostring(data.SVSBT_TrapId))
            Client.SendCommand("TRAP_GRABBED", { trapId = data.SVSBT_TrapId }, self.character)
            self:forceStop()
            Logger.Finish(actionRun, true, "blocked")
            return
        end

        local result = ISGrabItemAction.SVSBT_OriginalStart(self)
        Logger.Finish(actionRun, true, "allowed")
        return result
    end

    Logger.Audit("HOOKS_PATCH_GRAB", "client", "patched successfully.")
    Logger.Finish(run, true, "patched")
    return true
end

local function patchReading()
    local run = Logger.Begin("Hooks.patchReading")

    if not ISReadABook or ISReadABook.SVSBT_OriginalStart then
        Logger.Finish(run, true, "already patched or unavailable")
        return false
    end

    ISReadABook.SVSBT_OriginalStart = ISReadABook.start

    function ISReadABook:start()
        local actionRun = Logger.Begin("Hooks.ISReadABook.start")
        local result = ISReadABook.SVSBT_OriginalStart(self)

        -- MAD Magazines are contaminable literature too (Anthrax can be
        -- applied to any of them, not just vanilla books), so every read is
        -- reported. Service.DocumentOpened no-ops for anything that was
        -- never contaminated, so it's cheap and correct to always report.
        if self.item and self.character then
            Client.SendCommand("DOCUMENT_OPENED", { itemId = self.item:getID() }, self.character)
        end

        Logger.Finish(actionRun, true, "item=" .. tostring(self.item and self.item:getID() or "none"))
        return result
    end

    -- Guarantee the recipe is learned when a MAD Magazine is finished, regardless
    -- of whether the script's LearnedRecipes linkage resolved. Always confirms
    -- the outcome so a silently-already-known recipe (native path worked) isn't
    -- indistinguishable from nothing having happened.
    local function forceLearnFromMagazine(character, item)
        local recipes = item and SVSBT.Shared.MagazineRecipe[tostring(item:getFullType())] or nil
        if not recipes or not character or type(character.learnRecipe) ~= "function"
            or type(character.getKnownRecipes) ~= "function" then return end
        local learnedAnyNew = false
        local allKnown = true

        -- character:isRecipeKnown(name) (single-arg) is not ground truth here --
        -- see the matching comment on Shared.KnowsRecipe. getKnownRecipes():contains
        -- is the real list, so this always calls learnRecipe when it's actually
        -- needed instead of silently believing it's already known.
        for _, recipe in ipairs(recipes) do
            local wasKnown = character:getKnownRecipes():contains(recipe) == true

            if not wasKnown then
                character:learnRecipe(recipe)
                learnedAnyNew = true
            end

            allKnown = allKnown and character:getKnownRecipes():contains(recipe) == true
        end

        if learnedAnyNew and type(sendSyncPlayerFields) == "function" then
            pcall(sendSyncPlayerFields, character, 0x00000007)
        end

        -- learnRecipe() above only touches this CLIENT's copy of the
        -- character; on a dedicated server the copy that validates crafting
        -- lives server-side (vanilla ISReadABook pairs with a
        -- sendServerCommand for the same reason).
        -- Deliberately sends no recipe list: the server decides what was
        -- earned from its own copy of getAlreadyReadBook(), so this is only
        -- a "check my read history now" nudge that saves waiting for the
        -- next lifecycle pass. Naming recipes here would be ignored anyway.
        if Client and type(Client.SendCommand) == "function" then
            Client.SendCommand("LEARN_RECIPES", {}, character)
        end

        if Client and type(Client.Notify) == "function" then
            if allKnown then
                Client.Notify("You now know " .. (#recipes > 1 and "these recipes" or "this recipe")
                    .. " -- find " .. (#recipes > 1 and "them" or "it") .. " in the crafting menu to build.")
            else
                Client.Notify("Something prevented a recipe from being learned -- please report this.", true)
            end
        end
    end

    local function safeForceLearn(source, character, item)
        local ok, err = pcall(forceLearnFromMagazine, character, item)
        if not ok then
            Logger.Error("Hooks.forceLearnFromMagazine",
                "crashed from " .. tostring(source) .. " | item=" .. tostring(item and item:getFullType() or "none")
                    .. " | error=" .. tostring(err))
            if Client and type(Client.Notify) == "function" then
                Client.Notify("Learning this recipe failed unexpectedly -- please report this.", true)
            end
        end
    end

    ISReadABook.SVSBT_OriginalPerform = ISReadABook.perform
    function ISReadABook:perform()
        local result = ISReadABook.SVSBT_OriginalPerform(self)
        safeForceLearn("perform", self.character, self.item)
        return result
    end

    if ISReadABook.complete then
        ISReadABook.SVSBT_OriginalComplete = ISReadABook.complete
        function ISReadABook:complete()
            local result = ISReadABook.SVSBT_OriginalComplete(self)
            safeForceLearn("complete", self.character, self.item)
            return result
        end
    end

    Logger.Finish(run, true, "patched")
    return true
end

local function patchContainers()
    local run = Logger.Begin("Hooks.patchContainers")

    if not ISInventoryPage or ISInventoryPage.SVSBT_OriginalSelectContainer then
        Logger.Finish(run, true, "already patched or unavailable")
        return false
    end

    ISInventoryPage.SVSBT_OriginalSelectContainer = ISInventoryPage.selectContainer

    function ISInventoryPage:selectContainer(button)
        local actionRun = Logger.Begin("Hooks.ISInventoryPage.selectContainer")
        local inventory = button and button.inventory or nil
        local parent = inventory and inventory:getParent() or nil
        local result = ISInventoryPage.SVSBT_OriginalSelectContainer(self, button)
        local player = getSpecificPlayer(self.player)

        if player and parent and Shared.IsMailbox(parent) and parent:getSquare() then
            local square = parent:getSquare()
            Client.SendCommand("MAILBOX_ACCESSED", {
                x = square:getX(), y = square:getY(), z = square:getZ(),
                objectIndex = Shared.ObjectIndex(parent),
            }, player)
        elseif player and parent and instanceof(parent, "BaseVehicle") then
            Client.SendCommand("VEHICLE_CONTAINER_ACCESSED", {
                vehicleId = parent:getId(),
                containerType = inventory:getType(),
            }, player)
        end

        Logger.Finish(actionRun, true, "reported=" .. tostring(parent ~= nil))
        return result
    end

    Logger.Finish(run, true, "patched")
    return true
end

local function craftRecipeName(recipe)
    if not recipe then return "" end
    if type(recipe.getName) == "function" then
        return tostring(recipe:getName() or "")
    elseif type(recipe.getOriginalname) == "function" then
        return tostring(recipe:getOriginalname() or "")
    end
    return ""
end

local function isSVSBTRecipe(recipe)
    return string.find(craftRecipeName(recipe), "SVSBT_", 1, true) ~= nil
end

-- Reports exactly which input line(s) the engine considers unsatisfied,
-- straight from CraftRecipeData/InputScriptData: HandcraftLogic.getRecipeData()
-- -> CraftRecipeData.getRecipe():getInputs() -> each InputScript's
-- getDataForInputScript():isInputItemsSatisfied()/getInputItemCount(), with
-- InputScript.getOriginalLine() giving the literal script line back.
local function diagnoseInputFailure(logic)
    if not logic or type(logic.getRecipeData) ~= "function" then return nil end
    local ok, recipeData = pcall(function() return logic:getRecipeData() end)
    if not ok or not recipeData or type(recipeData.getRecipe) ~= "function" then return nil end

    local ok2, recipe = pcall(function() return recipeData:getRecipe() end)
    if not ok2 or not recipe or type(recipe.getInputs) ~= "function" then return nil end

    local ok3, inputs = pcall(function() return recipe:getInputs() end)
    if not ok3 or not inputs then return nil end

    -- Named per-item gates InputScript evaluates (passesFavoriteTest/
    -- passesBrokenTest/passesRottenTest/passesFrozenTest/passesSealedTest --
    -- each is "true unless flagged otherwise"). Running them on the candidate
    -- item says exactly which condition is blocking it.
    local gates = {
        { name = "favorite (needs flags[AllowFavorite])", fn = "passesFavoriteTest" },
        { name = "broken (needs flags[AllowDestroyedItem])", fn = "passesBrokenTest" },
        { name = "rotten (needs flags[AllowRottenItem])", fn = "passesRottenTest" },
        { name = "frozen (needs flags[AllowFrozenItem])", fn = "passesFrozenTest" },
        { name = "sealed", fn = "passesSealedTest" },
    }

    local lines = {}
    for i = 0, inputs:size() - 1 do
        local inputScript = inputs:get(i)
        local ok4, data = pcall(function() return recipeData:getDataForInputScript(inputScript) end)
        local satisfied = ok4 and data and data:isInputItemsSatisfied()

        if not satisfied then
            local desc = "?"
            pcall(function() desc = inputScript:getOriginalLine() end)
            local have = "?"
            if ok4 and data then
                pcall(function() have = data:getInputItemCount() end)
            end

            local itemDetail = "no candidate item found"
            local ok5, item = pcall(function() return data and data:getFirstInputItem() end)

            if ok5 and item then
                local failedGates = {}
                for _, gate in ipairs(gates) do
                    local okG, result = pcall(function() return inputScript[gate.fn](inputScript, item) end)
                    if okG and result == false then
                        table.insert(failedGates, gate.name)
                    end
                end

                local fullType = "?"
                pcall(function() fullType = item:getFullType() end)
                local isFav, isBroke = "?", "?"
                pcall(function() isFav = tostring(item:isFavorite()) end)
                pcall(function() isBroke = tostring(item:isBroken()) end)

                if #failedGates > 0 then
                    itemDetail = "item=" .. tostring(fullType) .. " isFavorite=" .. isFav
                        .. " isBroken=" .. isBroke .. " FAILED GATE(S): " .. table.concat(failedGates, ", ")
                else
                    itemDetail = "item=" .. tostring(fullType) .. " isFavorite=" .. isFav
                        .. " isBroken=" .. isBroke .. " -- all named gates pass; refusal is elsewhere (quantity/OnTest/manual-assignment)"
                end
            end

            table.insert(lines, "line " .. (i + 1) .. " unsatisfied (have " .. tostring(have) .. "): "
                .. tostring(desc) .. " [" .. itemDetail .. "]")
        end
    end

    if #lines == 0 then
        return "engine reports every input line satisfied -- refusal is coming from somewhere else (OnTest/skill/recipe-known gate)"
    end

    return table.concat(lines, " || ")
end

-- Vanilla's own gate (CraftRecipeManager.isValidRecipeForCharacter) rejects
-- a craft for exactly two reasons before it even looks at ingredients: an
-- unmet skill requirement, or the recipe not being known -- and reports
-- neither to the player. This reproduces both checks with the same APIs
-- (CraftRecipe.characterHasRequiredSkills/getRequiredSkill,
-- IsoGameCharacter.getKnownRecipes) so the in-game message says exactly
-- which one it is instead of a generic "materials" guess.
local function diagnoseCraftFailure(character, recipe, logic)
    local reasons = {}

    if character and recipe and type(recipe.characterHasRequiredSkills) == "function" then
        local ok, hasSkills = pcall(function() return recipe:characterHasRequiredSkills(character) end)

        if ok and hasSkills == false and type(recipe.getRequiredSkillCount) == "function" then
            local ok2, count = pcall(function() return recipe:getRequiredSkillCount() end)

            if ok2 and type(count) == "number" then
                for i = 0, count - 1 do
                    local ok3, skill = pcall(function() return recipe:getRequiredSkill(i) end)

                    if ok3 and skill then
                        local ok4, perk = pcall(function() return skill:getPerk() end)
                        local ok5, level = pcall(function() return skill:getLevel() end)

                        if ok4 and ok5 and perk and type(character.getPerkLevel) == "function" then
                            local have = character:getPerkLevel(perk)

                            if have < level then
                                local perkName = type(perk.getName) == "function" and perk:getName() or tostring(perk)
                                table.insert(reasons, perkName .. " " .. tostring(level)
                                    .. " required (you have " .. tostring(have) .. ")")
                            end
                        end
                    end
                end
            end
        end
    end

    if character and recipe and type(character.getKnownRecipes) == "function" then
        local recipeName = craftRecipeName(recipe)
        local ok, known = pcall(function() return character:getKnownRecipes():contains(recipeName) end)

        if ok and known ~= true then
            table.insert(reasons, "recipe not known -- read the matching MAD Magazine")
        end
    end

    local inputDiagnosis = diagnoseInputFailure(logic)
    if inputDiagnosis then
        table.insert(reasons, inputDiagnosis)
    end

    if #reasons == 0 then
        return "missing or wrong-condition ingredients or tools (no engine diagnostic available)"
    end

    return table.concat(reasons, "; ")
end

local function notifyMissingCraftMaterials(character, recipe, target, logic)
    if target and target.SVSBT_MissingMaterialsNotified then return end
    if target then target.SVSBT_MissingMaterialsNotified = true end
    local why = diagnoseCraftFailure(character, recipe, logic)
    Client.Notify("Can't craft this -- " .. why .. ".", true)
    Logger.Warn("Hooks.notifyMissingCraftMaterials",
        "recipe=" .. craftRecipeName(recipe) .. " | reason=" .. why)
end

-- canPerformCurrentRecipe() is declared on BaseCraftingLogic and inherited
-- by HandcraftLogic. It reads the
-- currently-loaded recipeData via CraftRecipeData.canPerform(...), which is
-- exactly the recipe this action is about to try to craft, so it's the
-- right check regardless of whether that recipe happens to be present in
-- any pre-built cached browse-list.
local function canPerformHandcraft(logic)
    if not logic or type(logic.canPerformCurrentRecipe) ~= "function" then return false end
    local ok, result = pcall(function() return logic:canPerformCurrentRecipe() end)
    return ok and result == true
end

-- getPossibleCraftCount(boolean) is likewise inherited from
-- BaseCraftingLogic. Every SVSBT recipe allows batch crafting, so this
-- refuses a batch larger than the materials on hand can cover.
local function canPerformHandcraftMultiple(logic, quantity)
    if not logic or type(logic.getPossibleCraftCount) ~= "function" then
        return canPerformHandcraft(logic)
    end
    local ok, count = pcall(function()
        return logic:getPossibleCraftCount(true)
    end)
    return ok and (tonumber(count) or 0) >= math.max(1, tonumber(quantity) or 1)
end

local function patchHandcraft()
    local run = Logger.Begin("Hooks.patchHandcraft")
    local actionAvailable = pcall(require, "Entity/TimedActions/ISHandcraftAction")
    local uiAvailable = pcall(require, "Entity/ISEntityUI")

    if not actionAvailable or not ISHandcraftAction then
        Logger.Finish(run, false, "ISHandcraftAction unavailable")
        return false
    end

    if not ISHandcraftAction.SVSBT_OriginalGetDuration then
        ISHandcraftAction.SVSBT_OriginalGetDuration = ISHandcraftAction.getDuration

        function ISHandcraftAction:getDuration()
            local actionRun = Logger.Begin("Hooks.ISHandcraftAction.getDuration")
            local duration = ISHandcraftAction.SVSBT_OriginalGetDuration(self)
            local recipeName = craftRecipeName(self.craftRecipe)

            if isSVSBTRecipe(self.craftRecipe) then
                duration = math.max(1, duration * Config.Get("CraftingTimeMultiplier"))
            end

            Logger.Finish(actionRun, true, "recipe=" .. recipeName .. " | duration=" .. tostring(duration))
            return duration
        end
    end

    -- Refuse the request before the vanilla UI creates or queues a timed action.
    -- This also covers callers that pass force=true for an SVSBT recipe.
    if uiAvailable and ISEntityUI and not ISEntityUI.SVSBT_OriginalHandcraftStart then
        ISEntityUI.SVSBT_OriginalHandcraftStart = ISEntityUI.HandcraftStart

        function ISEntityUI.HandcraftStart(player, logic, force, addToQueue, eatPercentage)
            local recipe = logic and type(logic.getRecipe) == "function" and logic:getRecipe() or nil
            if isSVSBTRecipe(recipe) and not canPerformHandcraft(logic) then
                notifyMissingCraftMaterials(player, recipe, nil, logic)
                return nil
            end
            return ISEntityUI.SVSBT_OriginalHandcraftStart(
                player, logic, force, addToQueue, eatPercentage)
        end
    end


    if uiAvailable and ISEntityUI
        and ISEntityUI.HandcraftStartMultiple
        and not ISEntityUI.SVSBT_OriginalHandcraftStartMultiple
    then
        ISEntityUI.SVSBT_OriginalHandcraftStartMultiple =
            ISEntityUI.HandcraftStartMultiple

        function ISEntityUI.HandcraftStartMultiple(player, logic, force, qty, addToQueue)
            local recipe = logic and type(logic.getRecipe) == "function"
                and logic:getRecipe() or nil
            if isSVSBTRecipe(recipe)
                and not canPerformHandcraftMultiple(logic, qty)
            then
                notifyMissingCraftMaterials(player, recipe, nil, logic)
                return nil
            end
            return ISEntityUI.SVSBT_OriginalHandcraftStartMultiple(
                player, logic, force, qty, addToQueue)
        end
    end

    -- Leave start-time validation to vanilla. ISHandcraftAction.start sets
    -- craftStarted=true after checking its inputs. A canPerformCurrentRecipe
    -- call after that counts this action's own reserved ingredients as queued
    -- consumption (CraftRecipeManager.itemGetQueuedAmount), falsely rejects
    -- mode:destroy inputs, and cancels an otherwise valid craft.

    Logger.Finish(run, true, "duration and material preflight patched")
    return true
end

-- Not IsoPlayer:setBlockMovement: it blocks movement processing so
-- completely that isSprinting() never becomes true, leaving a held player
-- with no way out. Instead IsoMovingObject:setX/setY snaps the player back to
-- the exact tile they were caught on every tick they're held and NOT
-- sprinting -- so direction keys genuinely do nothing, movement only
-- happens through the sprint yank -- without ever touching blockMovement or
-- whatever internal state isSprinting() depends on.
local bearTrapEscapeSent = {}
local bearTrapAnchor = {}

local function checkBearTrapEscape(player)
    if not player then return end
    local data = type(player.getModData) == "function" and player:getModData() or nil
    local heldId = data and data.SVSBT_BearTrapHeldId

    if not heldId then
        bearTrapEscapeSent[player] = nil
        bearTrapAnchor[player] = nil
        return
    end

    if not bearTrapAnchor[player] and type(player.getX) == "function" then
        bearTrapAnchor[player] = { x = player:getX(), y = player:getY() }
    end

    if type(player.isSprinting) == "function" and player:isSprinting() then
        if type(player.setSprinting) == "function" then player:setSprinting(false) end

        if not bearTrapEscapeSent[player] then
            bearTrapEscapeSent[player] = true
            Client.SendCommand("BEAR_TRAP_ESCAPE_ATTEMPT", {}, player)
        end
    elseif bearTrapAnchor[player] and type(player.setX) == "function" and type(player.setY) == "function" then
        local anchor = bearTrapAnchor[player]
        player:setX(anchor.x)
        player:setY(anchor.y)
    end
end

function Hooks.Apply()
    local run = Logger.Begin("Hooks.Apply")
    patchGrabItem()
    patchReading()
    patchContainers()
    patchHandcraft()
    Hooks.Patched = true
    Logger.Finish(run, true)
    return true
end

Hooks.Apply()
if Events and Events.OnGameStart then Events.OnGameStart.Add(Hooks.Apply) end
if Events and Events.OnPlayerUpdate then Events.OnPlayerUpdate.Add(checkBearTrapEscape) end

Logger.Info("SVSBT_Hooks.load", "door, reading, container, and handcraft hooks initialized")

return Hooks
