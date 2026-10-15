-- Prepares a tester's character so no test stops on skills or recipe
-- knowledge: raises the skills the enabled mods' recipes and actions use, and
-- hands over the literature that teaches their recipes. The character then
-- reads it with the real read action (see LilBubbyAutoRun); anything still
-- unknown afterwards is taught directly. Skills and items are changed where
-- they are authoritative: on the server in multiplayer, locally otherwise.
LilBubbyPrep = LilBubbyPrep or {}
local P = LilBubbyPrep

P.MODULE = "LilBubbyPrep"
P.LEVEL = 10      -- high enough for every recipe, and for disarm/salvage rolls
P.TAG = "LilBubbyPrep"

local function magazines(prefix, count)
    local list = {}
    for i = 1, count do list[i] = prefix .. i end
    return list
end

-- Per mod ID: skills to raise and literature that teaches its recipes.
P.NEEDS = {
    { mod = "SVSBoobyTraps", name = "Spy vs Spy Booby Traps",
      perks = { "Electricity", "Mechanics", "Maintenance", "Doctor", "Woodwork", "Aiming", "Trapping", "MetalWelding" },
      literature = magazines("SVSBoobyTraps.MadMagazine", 10) },
    { mod = "SpyVsSpySignalTracker", name = "Spy vs Spy Signal Tracker",
      perks = { "Electricity", "Mechanics" },
      literature = magazines("Base.SVS_MadMagazine", 5) },
    { mod = "TheWhisperers", name = "The Whisperers",
      perks = { "Butchering", "Tailoring" },
      literature = {} },
}

local function active(id)
    return LilBubbyShowcase and LilBubbyShowcase.ModActive and LilBubbyShowcase.ModActive(id)
        or (getActivatedMods and (getActivatedMods():contains(id) or getActivatedMods():contains("\\" .. id)))
end

function P.Needs()
    local list = {}
    for _, need in ipairs(P.NEEDS) do
        if active(need.mod) then list[#list + 1] = need end
    end
    return list
end

local function javaList(list)
    local out = {}
    if list then for i = 0, list:size() - 1 do out[#out + 1] = tostring(list:get(i)) end end
    return out
end

function P.Knows(player, recipe)
    local ok, known = pcall(function() return player:getKnownRecipes():contains(recipe) end)
    return ok and known == true
end

-- Every recipe the enabled mods' literature teaches.
function P.Recipes()
    local recipes, seen = {}, {}
    for _, need in ipairs(P.Needs()) do
        for _, fullType in ipairs(need.literature) do
            local script = getScriptManager():FindItem(fullType)
            local taught = script and script.getLearnedRecipes and javaList(script:getLearnedRecipes()) or {}
            for _, recipe in ipairs(taught) do
                if not seen[recipe] then seen[recipe] = true; recipes[#recipes + 1] = recipe end
            end
        end
    end
    return recipes
end

local function raise(player, name)
    local perk = Perks[name]
    if not perk then return nil end
    local before = player:getPerkLevel(perk)
    for _ = 1, 12 do
        if player:getPerkLevel(perk) >= P.LEVEL then break end
        local missing = perk:getTotalXpForLevel(P.LEVEL) - player:getXp():getXP(perk)
        addXpNoMultiplier(player, perk, math.max(1, missing + 1))
    end
    return { perk = name, from = before, to = player:getPerkLevel(perk) }
end

-- Raises skills and gives unread literature. Returns what changed.
function P.Grant(player)
    local result = { perks = {}, items = {} }
    local done = {}
    for _, need in ipairs(P.Needs()) do
        for _, name in ipairs(need.perks) do
            if not done[name] then
                done[name] = true
                local change = raise(player, name)
                if change then result.perks[#result.perks + 1] = change end
            end
        end
        for _, fullType in ipairs(need.literature) do
            local script = getScriptManager():FindItem(fullType)
            local taught = script and script.getLearnedRecipes and javaList(script:getLearnedRecipes()) or {}
            local unknown = false
            for _, recipe in ipairs(taught) do unknown = unknown or not P.Knows(player, recipe) end
            if script and unknown then
                local inventory = player:getInventory()
                local item = inventory:AddItem(fullType)
                if item then
                    item:getModData()[P.TAG] = true
                    if isServer() then sendAddItemToContainer(inventory, item) end
                    result.items[#result.items + 1] = { id = item:getID(), type = fullType, name = item:getDisplayName() }
                end
            end
        end
    end
    return result
end

-- Teaches recipes the reading did not (too dark, illiterate, interrupted).
-- Only recipes the enabled mods' literature teaches are accepted.
function P.Teach(player, wanted)
    local allowed, taught = {}, {}
    for _, recipe in ipairs(P.Recipes()) do allowed[recipe] = true end
    for _, recipe in ipairs(type(wanted) == "table" and wanted or {}) do
        if allowed[recipe] and not P.Knows(player, recipe) then
            player:learnRecipe(recipe)
            taught[#taught + 1] = recipe
        end
    end
    if #taught > 0 and isServer() then pcall(sendSyncPlayerFields, player, 0x00000007) end
    return { taught = taught }
end

-- Removes the literature this module handed out, read or not.
function P.Tidy(player)
    local inventory, removed = player:getInventory(), 0
    local items = inventory:getItems()
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if item:hasModData() and item:getModData()[P.TAG] then
            inventory:Remove(item)
            if isServer() then sendRemoveItemFromContainer(inventory, item) end
            removed = removed + 1
        end
    end
    return { removed = removed }
end

return LilBubbyPrep
