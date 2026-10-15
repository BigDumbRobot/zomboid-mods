require "KIPNCareers_Shared"

local Shared = KIPNCareers.Shared
local Adapter = KIPNCareers.NarcoticsAdapter or {}
KIPNCareers.NarcoticsAdapter = Adapter

local DEFAULT_ITEMS = {
    { type = "NnC.CokeBaggie", label = "Cocaine baggie", value = 95, tier = 1 },
    { type = "NnC.CokeBrick", label = "Cocaine brick", value = 900, tier = 3 },
    { type = "NnC.CrystalMeth", label = "Crystal meth", value = 125, tier = 2 },
    { type = "NnC.Fentanyl", label = "Fentanyl", value = 165, tier = 3 },
    { type = "NnC.Heroin4", label = "Heroin (refined)", value = 145, tier = 2 },
    { type = "NnC.LSD", label = "LSD", value = 75, tier = 1 },
    { type = "NnC.MDMA", label = "MDMA", value = 85, tier = 1 },
    { type = "NnC.Oxycodone", label = "Oxycodone", value = 70, tier = 1 },
    { type = "NnC.Ritalin", label = "Ritalin", value = 45, tier = 1 },
    { type = "NnC.Xanax", label = "Xanax", value = 55, tier = 1 },
    { type = "NnC.WeedBaggieAK", label = "AK baggie", value = 40, tier = 1 },
    { type = "NnC.WeedBaggieNorthernLights", label = "Northern Lights baggie", value = 45, tier = 1 },
    { type = "NnC.WeedBaggieSourDiesel", label = "Sour Diesel baggie", value = 45, tier = 1 },
    { type = "NnC.WeedBrick", label = "weed brick", value = 360, tier = 2 },
    { type = "NnC.KiefJar", label = "kief jar", value = 90, tier = 2 },
    { type = "NnC.JointAK", label = "AK joint", value = 22, tier = 1 },
    { type = "NnC.JointNorthernLights", label = "Northern Lights joint", value = 24, tier = 1 },
    { type = "NnC.JointSourDiesel", label = "Sour Diesel joint", value = 24, tier = 1 },
}

local function log(level, message)
    Shared.Log("NarcoticsAdapter", level, message)
end

local function splitCsv(value)
    log("Debug", "splitCsv invoked")
    -- B42 keeps the literal quotes on a `type = string` sandbox value, so an
    -- empty option arrives as [[""]] and a set one as [["NnC.Foo,NnC.Bar"]].
    -- Strip one balanced surrounding pair before splitting.
    local text = tostring(value or "")
    text = text:match('^"(.*)"$') or text:match("^'(.*)'$") or text
    local result = {}
    for token in string.gmatch(text, "[^,;]+") do
        token = Shared.Trim(token, 128)
        if token ~= "" then result[token] = true end
    end
    return result
end

local function findScriptItem(fullType)
    log("Debug", "findScriptItem type=" .. tostring(fullType))
    local manager = type(getScriptManager) == "function" and getScriptManager() or nil
    if not manager and ScriptManager then manager = ScriptManager.instance end
    if not manager then return nil end
    if type(manager.FindItem) == "function" then
        local ok, item = pcall(manager.FindItem, manager, fullType)
        if ok and item then return item end
    end
    if type(manager.getItem) == "function" then
        local ok, item = pcall(manager.getItem, manager, fullType)
        if ok then return item end
    end
    return nil
end

local function isModActive()
    log("Debug", "isModActive invoked")
    if type(getActivatedMods) ~= "function" then return nil end
    local mods = getActivatedMods()
    if not mods or type(mods.contains) ~= "function" then return nil end
    local ok, active = pcall(mods.contains, mods, "N&CsNarcotics")
    if ok then return active == true end
    return nil
end

function Adapter.Initialize(settings)
    log("Info", "Initialize invoked")
    settings = settings or {}
    Adapter.catalog = {}
    Adapter.byType = {}
    Adapter.modActive = isModActive()

    local disabled = splitCsv(settings.DisabledDrugItemTypes)
    local candidates = {}
    for _, definition in ipairs(DEFAULT_ITEMS) do
        candidates[#candidates + 1] = definition
    end
    for fullType in pairs(splitCsv(settings.AdditionalDrugItemTypes)) do
        candidates[#candidates + 1] = {
            type = fullType,
            label = fullType,
            value = 50,
            tier = 1,
        }
    end

    for _, definition in ipairs(candidates) do
        if not disabled[definition.type] and findScriptItem(definition.type) then
            Adapter.catalog[#Adapter.catalog + 1] = definition
            Adapter.byType[definition.type] = definition
            log("Info", "Validated drug item " .. definition.type)
        else
            log("Warn", "Skipped missing or disabled drug item " .. definition.type)
        end
    end

    Adapter.available = #Adapter.catalog > 0
        and (Adapter.modActive ~= false or settings.RequireNarcoticsMod ~= true)
    log("Info", "Adapter ready available=" .. tostring(Adapter.available) .. " items=" .. tostring(#Adapter.catalog))
    return Adapter.available
end

function Adapter.GetCatalog()
    log("Debug", "GetCatalog invoked")
    return Adapter.catalog or {}
end

function Adapter.Get(fullType)
    log("Debug", "Get type=" .. tostring(fullType))
    return Adapter.byType and Adapter.byType[fullType] or nil
end

function Adapter.IsAllowed(fullType)
    log("Debug", "IsAllowed type=" .. tostring(fullType))
    return Adapter.Get(fullType) ~= nil
end

function Adapter.SelectForReputation(reputation)
    log("Debug", "SelectForReputation reputation=" .. tostring(reputation))
    local maxTier = reputation >= 80 and 3 or (reputation >= 55 and 2 or 1)
    local eligible = {}
    for _, definition in ipairs(Adapter.catalog or {}) do
        if (definition.tier or 1) <= maxTier then eligible[#eligible + 1] = definition end
    end
    if #eligible == 0 then return nil end
    local index = type(ZombRand) == "function" and (ZombRand(#eligible) + 1) or 1
    return eligible[index]
end

return Adapter

