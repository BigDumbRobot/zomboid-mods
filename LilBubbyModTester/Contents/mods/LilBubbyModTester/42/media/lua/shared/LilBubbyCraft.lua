-- Crafting for every suite, built so a test always finishes:
-- * Ingredients go straight into the player's inventory (never dropped on the
--   ground to be picked up, which races multiplayer transactions and can be
--   interrupted by the player).
-- * The craft itself runs through the game's real ISEntityUI.HandcraftStart
--   timed action, so the tested mods' crafting hooks take part. It is restarted
--   only when a craft that began stops without producing its item, or never
--   begins at all, so it is never queued twice.
LilBubbyCraft = LilBubbyCraft or {}
local C = LilBubbyCraft

C.TAG = "LilBubbyCraftGiven"
C.RETRIES = 10
C.TIMEOUT_MS = 90000

function C.FindRecipe(name)
    local manager = getScriptManager()
    for _, candidate in ipairs({ name, "Base." .. name }) do
        local ok, recipe = pcall(function() return manager:getCraftRecipe(candidate) end)
        if ok and recipe then return recipe end
    end
    -- Recipes in a mod's own module (Whisperers.Whisp_MakeHeadStake) only
    -- resolve by full name, so fall back to matching the bare name.
    local ok, found = pcall(function()
        local all = manager:getAllCraftRecipes()
        for i = 0, all:size() - 1 do
            local recipe = all:get(i)
            if recipe:getName() == name then return recipe end
        end
    end)
    if ok then return found end
end

local function count(inventory, fullType)
    local ok, n = pcall(function() return inventory:getCountTypeRecurse(fullType) end)
    return ok and n or 0
end

------------------------------------------------------------
-- SERVER (or single player): ingredients
------------------------------------------------------------

-- Gives whatever the recipe's inputs need that the player does not already
-- carry. Given items are tagged so Take can remove exactly them again.
-- Returns the given items and notes about inputs that cannot be given.
function C.GiveInputs(player, recipe)
    local inventory, given, notes = player:getInventory(), {}, {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local possible = input:getPossibleInputItems()
        if possible and possible:size() > 0 then
            local need = math.max(1, input:getIntAmount())
            local have = 0
            for j = 0, possible:size() - 1 do have = have + count(inventory, possible:get(j):getFullName()) end
            local fullType = possible:get(0):getFullName()
            for _ = have + 1, need do
                local item = inventory:AddItem(fullType)
                if not item then notes[#notes + 1] = "could not create " .. fullType; break end
                item:getModData()[C.TAG] = true
                if isServer() then sendAddItemToContainer(inventory, item) end
                given[#given + 1] = item
            end
        else
            local fluids = input:getPossibleInputFluids()
            if fluids and fluids:size() > 0 then notes[#notes + 1] = "needs a fluid input, which is not given" end
        end
    end
    return given, notes
end

-- Removes every item GiveInputs handed out that is still in the inventory.
function C.TakeGiven(player)
    local removed = 0
    local function sweep(container)
        local items = container:getItems()
        for i = items:size() - 1, 0, -1 do
            local item = items:get(i)
            if item:hasModData() and item:getModData()[C.TAG] then
                container:Remove(item)
                if isServer() then sendRemoveItemFromContainer(container, item) end
                removed = removed + 1
            elseif item.getItemContainer and item:getItemContainer() then
                sweep(item:getItemContainer())
            end
        end
    end
    sweep(player:getInventory())
    return removed
end

------------------------------------------------------------
-- CLIENT: the craft
------------------------------------------------------------

C.jobs = C.jobs or {}

local function containers(player)
    if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers then
        return ISInventoryPaneContextMenu.getContainers(player)
    end
    local list = ArrayList.new()
    list:add(player:getInventory())
    return list
end

local function newLogic(job)
    local logic = HandcraftLogic.new(job.player, nil, nil)
    -- As the vanilla craft window does: without it, ISHandcraftAction.FromLogic
    -- passes manualInputs = false to convertToPZNetTable, which throws.
    logic:setManualSelectInputs(true)
    logic:setContainers(containers(job.player))
    logic:setRecipe(job.recipe)
    logic:refresh()
    return logic
end

-- What the recipe still lacks, for the report: "need 3 x Base.Paper (have 1)".
function C.Missing(player, recipe)
    local inventory, missing = player:getInventory(), {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local possible = input:getPossibleInputItems()
        if possible and possible:size() > 0 then
            local need, have = math.max(1, input:getIntAmount()), 0
            for j = 0, possible:size() - 1 do have = have + count(inventory, possible:get(j):getFullName()) end
            if have < need then
                missing[#missing + 1] = "need " .. need .. " x " .. possible:get(0):getFullName() .. " (have " .. have .. ")"
            end
        end
    end
    return #missing > 0 and table.concat(missing, ", ") or "every item input is present"
end

local function inputName(input)
    local ok, name = pcall(function()
        local fullType = input:getPossibleInputItems():get(0):getFullName()
        local script = getScriptManager():FindItem(fullType)
        return script and script:getDisplayName() or fullType
    end)
    return ok and name or "an ingredient"
end

-- Why the recipe cannot be crafted right now, as the game's own craft window
-- sees it: { ready = true } or { ready = false, reasons = { ... } }. Checks
-- the recipe is known and the skills are there, then asks the craft logic
-- about each input, as the craft window does to colour it.
function C.Diagnose(player, recipeName)
    local recipe = C.FindRecipe(recipeName)
    if not recipe then return { ready = false, reasons = { recipeName .. " is not registered" } } end
    local reasons = {}
    local okLearn, mustLearn = pcall(function() return recipe:needToBeLearn() end)
    local okKnown, known = pcall(function() return player:getKnownRecipes():contains(recipe:getName()) end)
    if okLearn and mustLearn and not (okKnown and known) then
        reasons[#reasons + 1] = "your character does not know the recipe"
    end
    pcall(function()
        for i = 0, recipe:getRequiredSkillCount() - 1 do
            local skill = recipe:getRequiredSkill(i)
            local have = player:getPerkLevel(skill:getPerk())
            if have < skill:getLevel() then
                reasons[#reasons + 1] = "needs " .. skill:getPerk():getName() .. " " .. skill:getLevel() .. " (you have " .. have .. ")"
            end
        end
    end)
    local okLogic, logic = pcall(newLogic, { player = player, recipe = recipe })
    local ready = false
    if okLogic and logic then
        local inputs = recipe:getInputs()
        for i = 0, inputs:size() - 1 do
            local input = inputs:get(i)
            local okInput, satisfied = pcall(function() return logic:isInputSatisfied(input) end)
            if okInput and satisfied == false then
                reasons[#reasons + 1] = "missing " .. math.max(1, input:getIntAmount()) .. " x " .. inputName(input)
            end
        end
        local okPerform, can = pcall(function() return logic:canPerformCurrentRecipe() end)
        ready = okPerform and can == true
    else
        reasons[#reasons + 1] = "the craft logic could not be read: " .. tostring(logic)
    end
    if not ready and #reasons == 0 then
        local missing = C.Missing(player, recipe)
        reasons[1] = missing ~= "every item input is present" and missing
            or "every ingredient and skill is there, but the game still refuses it: the mod's own check (a sandbox switch) says no"
    end
    return { ready = ready, reasons = reasons }
end

local function begin(job)
    local logic = newLogic(job)
    if not logic:canPerformCurrentRecipe() then
        return false, "not craftable: " .. table.concat(C.Diagnose(job.player, job.name).reasons, "; ")
    end
    job.attempts, job.started, job.since = job.attempts + 1, false, getTimestampMs()
    ISEntityUI.HandcraftStart(job.player, logic, false, true, 0)
    return true
end

local function finish(job, ok, detail)
    C.jobs[job.player] = nil
    local info = job.attempts > 1 and (" after " .. job.attempts .. " attempts") or ""
    pcall(job.done, ok, (detail or "") .. info)
end

-- Crafts recipeName once and calls done(ok, detail) when outputType appears
-- in the inventory, or when it cannot be done. Ingredients the server just
-- gave may reach this client a moment later, so the craft starts as soon as
-- the recipe is craftable, waiting up to ARRIVAL_MS for that.
C.ARRIVAL_MS = 15000

function C.Craft(player, recipeName, outputType, done)
    local recipe = C.FindRecipe(recipeName)
    if not recipe then pcall(done, false, recipeName .. " is not registered"); return end
    if C.jobs[player] then pcall(done, false, "another craft is still running"); return end
    local now = getTimestampMs()
    local job = { player = player, name = recipeName, recipe = recipe, output = outputType, done = done, attempts = 0,
        before = count(player:getInventory(), outputType), deadline = now + C.TIMEOUT_MS,
        waitUntil = now + C.ARRIVAL_MS, waiting = true }
    C.jobs[player] = job
    C.Step(job, now)
end

-- Starts the craft if the recipe is craftable now; otherwise keeps waiting
-- for the ingredients until waitUntil, then fails naming what is missing.
local function tryBegin(job, now)
    local ok, began, why = pcall(begin, job)
    if ok and began then job.waiting = false; return end
    if now > job.waitUntil then
        finish(job, false, ok and ("ingredients did not arrive within " .. (C.ARRIVAL_MS / 1000) .. " s; " .. tostring(why)) or tostring(began))
    end
end

function C.Step(job, now)
    if count(job.player:getInventory(), job.output) > job.before then
        finish(job, true, "crafted " .. job.output); return
    end
    if now > job.deadline then finish(job, false, "no " .. job.output .. " within " .. (C.TIMEOUT_MS / 1000) .. " s"); return end
    if job.waiting then tryBegin(job, now); return end
    local busy = ISTimedActionQueue.isPlayerDoingAction(job.player)
    job.started = job.started or busy
    local stopped = job.started and not busy and now - job.since > 1500
    local neverBegan = not job.started and now - job.since > 3000
    if (stopped or neverBegan) and job.attempts < C.RETRIES then
        -- Interrupted: start again, waiting briefly if the inputs are in flux.
        job.waiting, job.waitUntil = true, now + C.ARRIVAL_MS
        tryBegin(job, now)
    end
end

if not isServer() then
    Events.OnTick.Add(function()
        local now
        for _, job in pairs(C.jobs) do
            now = now or getTimestampMs()
            C.Step(job, now)
        end
    end)
end

return LilBubbyCraft
