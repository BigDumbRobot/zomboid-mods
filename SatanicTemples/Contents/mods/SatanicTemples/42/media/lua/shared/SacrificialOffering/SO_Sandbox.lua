require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"

local SO = SacrificialOffering
SO.Sandbox = SO.Sandbox or {}
local Sandbox = SO.Sandbox

local DEFAULTS = {
    AnimalCorpseRecoveryStrength = 10,
    RareItemRecoveryStrength = 50,
    AcceptableItemRecipes = "Base.Sledgehammer;Base.Sledgehammer2;Base.SledgehammerForged;Base.Katana;Base.AssaultRifle+3*Base.556Clip",
    PlayerCorpsePrizeEnabled = false,
    PlayerCorpsePrizeItems = "Base.GoldBar;Base.AssaultRifle",
    WrathMinimumDamagePercent = 17,
    WrathMaximumDamagePercent = 65,
    MinimumTempleSize = SO.MIN_ZONE_SIZE_DEFAULT,
    MaximumTempleSize = SO.MAX_ZONE_SIZE_DEFAULT,
    -- Each dumpster half's offering container. Must clear a carried human corpse
    -- (~90) with headroom; large animal carcasses that still will not fit use
    -- the ground-drop path instead. Kept modest -- the value is not what caused
    -- past container duplication, but there is no reason to make it huge.
    AltarCapacity = 200,
    TraceLogging = false,
    -- Allow all players to view the Satanic Temples overlay on the world map.
    AllowAllPlayersToViewTemples = false,
}

-- Preserve values from presets created before recovery was correctly described
-- as raw-XP strength instead of a percentage of visible skill levels.
local LEGACY_KEYS = {
    AnimalCorpseRecoveryStrength = "AnimalCorpseRecoveryPercent",
    RareItemRecoveryStrength = "HighValueRecoveryPercent",
}

function Sandbox.Get(name)
    local section = SandboxVars and SandboxVars.SacrificialOffering
    if section and section[name] ~= nil then return section[name] end
    local legacyName = LEGACY_KEYS[name]
    if section and legacyName and section[legacyName] ~= nil then return section[legacyName] end
    return DEFAULTS[name]
end

function Sandbox.Number(name, minimum, maximum)
    return SO.Util.Clamp(tonumber(Sandbox.Get(name)) or DEFAULTS[name] or 0, minimum, maximum)
end

function Sandbox.Boolean(name)
    local value = Sandbox.Get(name)
    if type(value) == "boolean" then return value end
    return tostring(value):lower() == "true"
end

function Sandbox.String(name)
    local value = Sandbox.Get(name)
    if value == nil then return "" end
    value = SO.Util.Trim(tostring(value))
    -- Custom string defaults in sandbox-options.txt are raw values: quotes are
    -- retained as literal data. Older presets created while this mod quoted its
    -- defaults therefore contain a leading and trailing quote, which invalidates
    -- the first and last entries in a semicolon-delimited list. Unwrap balanced
    -- quotes here so existing worlds migrate transparently and admin-entered
    -- quoted lists remain usable.
    while #value >= 2 do
        local first, last = value:sub(1, 1), value:sub(-1)
        if (first ~= '"' and first ~= "'") or last ~= first then break end
        value = SO.Util.Trim(value:sub(2, -2))
    end
    return value
end

-- Recovery strength is a 0-100 tuning scale applied to the missing cumulative
-- XP ledger. It is deliberately not described as a percentage of skill levels:
-- PZ's increasingly expensive levels make those two measurements diverge.
function Sandbox.RecoveryStrength(kind)
    if kind == "corpse" then
        return 100
    elseif kind == "animal" then
        return Sandbox.Number("AnimalCorpseRecoveryStrength", 0, 100)
    end
    return Sandbox.Number("RareItemRecoveryStrength", 0, 100)
end

function Sandbox.WrathRange()
    local minimum = SO.Util.Round(Sandbox.Number("WrathMinimumDamagePercent", 0, 100))
    local maximum = SO.Util.Round(Sandbox.Number("WrathMaximumDamagePercent", 0, 100))
    if minimum > maximum then minimum, maximum = maximum, minimum end
    return minimum, maximum
end

function Sandbox.ZoneSizeRange()
    local minimum = SO.Util.Round(Sandbox.Number("MinimumTempleSize", 5, 100))
    local maximum = SO.Util.Round(Sandbox.Number("MaximumTempleSize", minimum, 500))
    return minimum, maximum
end

return Sandbox