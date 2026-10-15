-- KIPN_EventZombieThemeRegistry.lua
--
-- Resolves weighted zombie themes from the outfit names actually loaded by
-- Project Zomboid Build 42. Categories use case-insensitive name patterns,
-- allowing vanilla and mod outfits to participate without hardcoding an
-- unverified outfit identifier.

if isClient() then return end

require "KIPN_Shared"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.EventZombieThemeRegistry = KIPN.Server.EventZombieThemeRegistry or {}

local Registry = KIPN.Server.EventZombieThemeRegistry
Registry.Categories = Registry.Categories or {}
Registry.Themes = Registry.Themes or {}
Registry.OutfitCache = Registry.OutfitCache or nil

local function log(message)
    print("[KIPN EVENT ZOMBIE THEME] " .. tostring(message))
end

local function logError(message)
    print("[KIPN EVENT ZOMBIE THEME] ERROR: " .. tostring(message))
end

local function normalizeId(value)
    return type(value) == "string" and value:upper():gsub("[^A-Z0-9_]", "_") or nil
end

local function javaListToLua(list, female, output)
    if not list then return end
    for index = 0, list:size() - 1 do
        local name = tostring(list:get(index))
        local current = output[name] or { name = name, male = false, female = false }
        current.female = current.female or female == true
        current.male = current.male or female ~= true
        output[name] = current
    end
end

local function buildOutfitCache()
    local byName = {}
    local ok, err = pcall(function()
        javaListToLua(getAllOutfits(false), false, byName)
        javaListToLua(getAllOutfits(true), true, byName)
    end)

    if not ok then
        logError("buildOutfitCache() failed: " .. tostring(err))
        Registry.OutfitCache = { all = {}, byCategory = {} }
        return Registry.OutfitCache
    end

    local all = {}
    for _, entry in pairs(byName) do all[#all + 1] = entry end
    table.sort(all, function(a, b) return a.name < b.name end)

    local cache = { all = all, byCategory = {} }
    for categoryId, category in pairs(Registry.Categories) do
        local matches = {}
        for _, entry in ipairs(all) do
            local lowerName = entry.name:lower()
            for _, pattern in ipairs(category.patterns or {}) do
                if lowerName:find(pattern, 1, true) then
                    matches[#matches + 1] = entry
                    break
                end
            end
        end
        cache.byCategory[categoryId] = matches
        log("buildOutfitCache() category=" .. categoryId .. " matches=" .. tostring(#matches))
    end

    Registry.OutfitCache = cache
    log("buildOutfitCache() -> outfits=" .. tostring(#all))
    return cache
end

function Registry.RegisterCategory(categoryId, definition)
    local id = normalizeId(categoryId)
    if not id or id == "" or type(definition) ~= "table" then
        logError("RegisterCategory() rejected invalid category")
        return false
    end
    Registry.Categories[id] = {
        id = id,
        label = tostring(definition.label or id),
        patterns = type(definition.patterns) == "table" and definition.patterns or {},
    }
    Registry.OutfitCache = nil
    log("RegisterCategory() -> " .. id)
    return true
end

function Registry.RegisterTheme(themeId, definition)
    local id = normalizeId(themeId)
    if not id or id == "" or type(definition) ~= "table" then
        logError("RegisterTheme() rejected invalid theme")
        return false
    end
    Registry.Themes[id] = {
        id = id,
        label = tostring(definition.label or id),
        categories = type(definition.categories) == "table" and definition.categories or {},
        randomWeight = math.max(0, tonumber(definition.randomWeight) or 0),
    }
    log("RegisterTheme() -> " .. id)
    return true
end

function Registry.NormalizeSelection(raw)
    if type(raw) == "string" then raw = { themeId = raw } end
    raw = type(raw) == "table" and raw or {}

    local themeId = normalizeId(raw.themeId or raw.id or "RANDOM") or "RANDOM"
    local selection = {
        themeId = Registry.Themes[themeId] and themeId or "RANDOM",
        categories = {},
    }

    if type(raw.categories) == "table" then
        for _, row in ipairs(raw.categories) do
            local categoryId = normalizeId(type(row) == "table" and row.categoryId or row)
            local weight = type(row) == "table" and tonumber(row.weight) or 1
            if categoryId and Registry.Categories[categoryId] and weight and weight > 0 then
                selection.categories[#selection.categories + 1] = {
                    categoryId = categoryId,
                    weight = math.min(10000, math.floor(weight)),
                }
            end
        end
    end

    log("NormalizeSelection() -> " .. selection.themeId .. " customCategories=" .. tostring(#selection.categories))
    return selection
end

local function chooseWeighted(rows)
    local total = 0
    for _, row in ipairs(rows) do total = total + math.max(0, tonumber(row.weight) or 0) end
    if total <= 0 then return nil end
    local roll = ZombRand(total) + 1
    local cursor = 0
    for _, row in ipairs(rows) do
        cursor = cursor + math.max(0, tonumber(row.weight) or 0)
        if roll <= cursor then return row end
    end
    return rows[#rows]
end

function Registry.ResolveOutfit(selection)
    selection = Registry.NormalizeSelection(selection)
    local cache = Registry.OutfitCache or buildOutfitCache()
    local theme = Registry.Themes[selection.themeId] or Registry.Themes.RANDOM
    local categoryRows = #selection.categories > 0 and selection.categories or theme.categories
    local weighted = {}

    for _, row in ipairs(categoryRows or {}) do
        local categoryId = normalizeId(row.categoryId)
        local outfits = categoryId and cache.byCategory[categoryId] or nil
        if outfits and #outfits > 0 then
            weighted[#weighted + 1] = {
                categoryId = categoryId,
                weight = tonumber(row.weight) or 1,
                outfits = outfits,
            }
        end
    end

    local randomWeight = math.max(0, tonumber(theme.randomWeight) or 0)
    if randomWeight > 0 or #weighted == 0 then
        weighted[#weighted + 1] = { categoryId = "RANDOM", weight = math.max(1, randomWeight), outfits = cache.all }
    end

    local category = chooseWeighted(weighted)
    if not category or not category.outfits or #category.outfits == 0 then
        log("ResolveOutfit() -> random vanilla outfit")
        return nil, 50, "RANDOM"
    end

    local outfit = category.outfits[ZombRand(1, #category.outfits + 1)]
    local femaleChance = 50
    if outfit.female and not outfit.male then femaleChance = 100 end
    if outfit.male and not outfit.female then femaleChance = 0 end
    log("ResolveOutfit() -> category=" .. category.categoryId .. " outfit=" .. outfit.name)
    return outfit.name, femaleChance, category.categoryId
end

function Registry.GetMetadata()
    local themes = {}
    for _, themeId in ipairs(KIPN.Shared.EventZombieThemeOrder or {}) do
        local theme = Registry.Themes[themeId]
        if theme then themes[#themes + 1] = { id = theme.id, label = theme.label } end
    end
    log("GetMetadata() -> " .. tostring(#themes))
    return themes
end

function Registry.Initialize()
    Registry.RegisterCategory("MILITARY", { label = "Military", patterns = { "army", "military", "soldier", "camo" } })
    Registry.RegisterCategory("MEDICAL", { label = "Medical", patterns = { "doctor", "nurse", "patient", "hospital", "medical", "surgeon" } })
    Registry.RegisterCategory("POLICE", { label = "Police", patterns = { "police", "sheriff", "statepolice", "swat" } })
    Registry.RegisterCategory("FIRE_EMERGENCY", { label = "Fire and Emergency", patterns = { "fireman", "firefighter", "paramedic", "ambulance" } })
    Registry.RegisterCategory("PRISON", { label = "Prison", patterns = { "prison", "inmate", "convict", "guard" } })
    Registry.RegisterCategory("CONSTRUCTION", { label = "Construction", patterns = { "construction", "worker", "foreman" } })
    Registry.RegisterCategory("RURAL", { label = "Rural", patterns = { "farmer", "ranger", "hunter", "fisher" } })
    Registry.RegisterCategory("INDUSTRIAL", { label = "Industrial", patterns = { "factory", "mechanic", "metal", "weld" } })
    Registry.RegisterCategory("FORMAL", { label = "Formal", patterns = { "suit", "formal", "wedding", "business" } })

    Registry.RegisterTheme("RANDOM", { label = "Random / Default", randomWeight = 100 })
    Registry.RegisterTheme("MILITARY", { label = "Military", categories = { { categoryId = "MILITARY", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("MEDICAL", { label = "Medical", categories = { { categoryId = "MEDICAL", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("MILITARY_HOSPITAL", {
        label = "Military Hospital",
        categories = {
            { categoryId = "MILITARY", weight = 55 },
            { categoryId = "MEDICAL", weight = 35 },
        },
        randomWeight = 10,
    })
    Registry.RegisterTheme("POLICE", { label = "Police", categories = { { categoryId = "POLICE", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("FIRE_EMERGENCY", { label = "Fire and Emergency", categories = { { categoryId = "FIRE_EMERGENCY", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("PRISON", { label = "Prison", categories = { { categoryId = "PRISON", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("CONSTRUCTION", { label = "Construction", categories = { { categoryId = "CONSTRUCTION", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("RURAL", { label = "Rural", categories = { { categoryId = "RURAL", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("INDUSTRIAL", { label = "Industrial", categories = { { categoryId = "INDUSTRIAL", weight = 85 } }, randomWeight = 15 })
    Registry.RegisterTheme("FORMAL", { label = "Formal", categories = { { categoryId = "FORMAL", weight = 85 } }, randomWeight = 15 })

    buildOutfitCache()
    log("Initialize() -> complete")
    return true
end

log("module loaded")
