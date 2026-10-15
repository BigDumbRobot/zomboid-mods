#!/usr/bin/env lua
-- tests/careers_blacksmith_checks.lua
--
-- Standalone Lua harness for the Blacksmith career mod's pure logic layer.
-- No Project Zomboid runtime is required: KIPNCareers_Shared.lua and
-- KIPNCareers_BlacksmithShared.lua make zero PZ-global calls (Shared.Log
-- falls back to plain `print` when the `KIPN` global is absent), so both
-- files load and run untouched under a vanilla `lua`/`luajit` interpreter.
--
-- Run from the LilBubbyModTester folder:  lua tests/careers_blacksmith_checks.lua
-- It loads Careers Framework and Careers: Blacksmith from their Steam
-- Workshop subscriptions.
-- Exits 0 if every assertion passes, 1 otherwise (suitable for CI).
--
-- Server/client files that touch real PZ containers, zones, players, and
-- KIPN.Server.* are intentionally out of scope here -- see the README's
-- dedicated-server smoke test for those.

-- Every mod comes from the Steam Workshop: its subscribed copy under
-- steamapps/workshop/content/108600/<Workshop ID>/mods/<mod id>/.
local WORKSHOP = (os.getenv("HOME") or "") .. "/Library/Application Support/Steam/steamapps/workshop/content/108600/"
local function modLua(workshopId, modId) return WORKSHOP .. workshopId .. "/mods/" .. modId .. "/42/media/lua/" end
package.path = modLua("3795313541", "CareersFramework") .. "shared/?.lua;"
    .. modLua("3806117635", "CareersBlacksmith") .. "shared/?.lua;"
    .. package.path

require("KIPNCareers_Shared")
require("KIPNCareers_BlacksmithShared")

local Shared = KIPNCareers.Shared
local Blacksmith = KIPNCareers.Blacksmith

local total = 0
local failed = 0

local function report(ok, description)
    total = total + 1
    if ok then
        io.write("  PASS  " .. description .. "\n")
    else
        failed = failed + 1
        io.write("  FAIL  " .. description .. "\n")
    end
end

local function assertEqual(actual, expected, description)
    report(actual == expected, description .. " (expected " .. tostring(expected) .. ", got " .. tostring(actual) .. ")")
end

local function assertTrue(value, description)
    report(value == true, description)
end

local function assertFalse(value, description)
    report(value == false or value == nil, description)
end

local function assertNil(value, description)
    report(value == nil, description)
end

------------------------------------------------------------
-- Shared.Clamp
------------------------------------------------------------
print("Shared.Clamp")
assertEqual(Shared.Clamp(5, 0, 10), 5, "value within range is unchanged")
assertEqual(Shared.Clamp(-5, 0, 10), 0, "value below minimum clamps to minimum")
assertEqual(Shared.Clamp(15, 0, 10), 10, "value above maximum clamps to maximum")
assertEqual(Shared.Clamp("not a number", 0, 10), 0, "non-numeric input falls back to minimum")
assertEqual(Shared.Clamp(nil, 2, 8), 2, "nil input falls back to minimum")
assertEqual(Shared.Clamp(0, 0, 10), 0, "value equal to minimum is unchanged")
assertEqual(Shared.Clamp(10, 0, 10), 10, "value equal to maximum is unchanged")

------------------------------------------------------------
-- Shared.Trim
------------------------------------------------------------
print("Shared.Trim")
assertEqual(Shared.Trim("  hello  ", 80), "hello", "surrounding whitespace is trimmed")
assertEqual(Shared.Trim("abcdefgh", 4), "abcd", "text longer than max is truncated")
assertEqual(Shared.Trim("short", 80), "short", "text shorter than max is unchanged")
assertEqual(Shared.Trim(nil, 80), "", "nil input becomes an empty string")
assertEqual(Shared.Trim("a<b>c", 80), "a(b)c", "angle brackets are neutralized")
assertEqual(Shared.Trim("a\1\2b", 80), "a  b", "control characters are replaced with spaces")

------------------------------------------------------------
-- Blacksmith.SanitizeForgeItems
------------------------------------------------------------
print("Blacksmith.SanitizeForgeItems")
assertNil((Blacksmith.SanitizeForgeItems(nil, 8)), "nil input is rejected")
assertNil((Blacksmith.SanitizeForgeItems({}, 8)), "empty list is rejected")
assertNil((Blacksmith.SanitizeForgeItems({ { itemName = "   " } }, 8)), "a blank-name-only list is rejected")

do
    local cleaned = Blacksmith.SanitizeForgeItems({
        { itemName = "  Machete  ", quality = 150 },
        { itemName = "" },
        { itemName = "Claw Hammer", quality = -20, quantity = 3 },
    }, 8)
    assertEqual(#cleaned, 2, "blank-name rows are dropped, valid rows kept")
    assertEqual(cleaned[1].itemName, "Machete", "item name is trimmed")
    assertEqual(cleaned[1].quality, Blacksmith.Defaults.QUALITY_MAX, "quality above max clamps to QUALITY_MAX")
    assertEqual(cleaned[1].quantity, Blacksmith.Defaults.QUANTITY_MIN, "quantity defaults to QUANTITY_MIN when omitted")
    assertEqual(cleaned[2].quality, Blacksmith.Defaults.QUALITY_MIN, "quality below min clamps to QUALITY_MIN")
    assertEqual(cleaned[2].quantity, 3, "an explicit valid quantity is preserved")
end

do
    local longName = string.rep("x", Blacksmith.Defaults.ITEM_NAME_MAX + 20)
    local cleaned = Blacksmith.SanitizeForgeItems({ { itemName = longName } }, 8)
    assertEqual(#cleaned[1].itemName, Blacksmith.Defaults.ITEM_NAME_MAX, "item name longer than max is truncated")
end

do
    local cleaned = Blacksmith.SanitizeForgeItems({ { itemName = "Hatchet", quantity = 99 } }, 8)
    assertEqual(cleaned[1].quantity, Blacksmith.Defaults.QUANTITY_MAX, "quantity above max clamps to QUANTITY_MAX")
end

do
    local rows = {}
    for i = 1, 20 do rows[i] = { itemName = "Item" .. i } end
    local cleaned = Blacksmith.SanitizeForgeItems(rows, 8)
    assertEqual(#cleaned, 8, "the maxItems cap is enforced")
end

------------------------------------------------------------
-- Blacksmith.ComputeQuotes
------------------------------------------------------------
print("Blacksmith.ComputeQuotes")

local baseConfig = {
    BaseItemPrice = 60,
    QualityPremiumPercent = 40,
    FastPriceMultiplier = 1.6,
    RegularPriceMultiplier = 1.0,
    SlowPriceMultiplier = 0.7,
    CurrencyItemValue = 1,
}

do
    local lowQuality = Blacksmith.ComputeQuotes({ { itemName = "Knife", quantity = 1, quality = Blacksmith.Defaults.QUALITY_MIN } }, baseConfig)
    local highQuality = Blacksmith.ComputeQuotes({ { itemName = "Knife", quantity = 1, quality = Blacksmith.Defaults.QUALITY_MAX } }, baseConfig)
    assertTrue(highQuality.regular > lowQuality.regular, "higher requested quality costs strictly more (the inverted-from-Mechanic direction)")
    assertEqual(lowQuality.regular, baseConfig.BaseItemPrice, "minimum quality carries no premium over the base price")
end

do
    local one = Blacksmith.ComputeQuotes({ { itemName = "Knife", quantity = 1, quality = 100 } }, baseConfig)
    local three = Blacksmith.ComputeQuotes({ { itemName = "Knife", quantity = 3, quality = 100 } }, baseConfig)
    assertEqual(three.regular, one.regular * 3, "price scales linearly with quantity")
end

do
    local quotes = Blacksmith.ComputeQuotes({ { itemName = "Knife", quantity = 1, quality = 100 } }, baseConfig)
    assertTrue(quotes.fast > quotes.regular, "Fast costs more than Regular given default multipliers")
    assertTrue(quotes.regular > quotes.slow, "Regular costs more than Slow given default multipliers")
end

do
    local currencyValue = 25
    local config = {}
    for k, v in pairs(baseConfig) do config[k] = v end
    config.CurrencyItemValue = currencyValue
    local quotes = Blacksmith.ComputeQuotes({ { itemName = "Knife", quantity = 1, quality = 100 } }, config)
    for _, tier in ipairs({ "fast", "regular", "slow" }) do
        assertEqual(quotes[tier] % currencyValue, 0, tier .. " price is a multiple of the currency item value")
        assertTrue(quotes[tier] >= currencyValue, tier .. " price respects the one-currency-unit floor")
    end
end

------------------------------------------------------------
-- Blacksmith.TierHours / TierPrice
------------------------------------------------------------
print("Blacksmith.TierHours / TierPrice")

local tierConfig = { FastCompletionHours = 12, RegularCompletionHours = 36, SlowCompletionHours = 72 }
assertEqual(Blacksmith.TierHours(Blacksmith.Tiers.FAST, tierConfig), 12, "fast tier maps to FastCompletionHours")
assertEqual(Blacksmith.TierHours(Blacksmith.Tiers.REGULAR, tierConfig), 36, "regular tier maps to RegularCompletionHours")
assertEqual(Blacksmith.TierHours(Blacksmith.Tiers.SLOW, tierConfig), 72, "slow tier maps to SlowCompletionHours")
assertEqual(Blacksmith.TierHours("bogus", tierConfig), 36, "an unknown tier falls back to Regular hours")

local tierQuotes = { fast = 160, regular = 100, slow = 70 }
assertEqual(Blacksmith.TierPrice(tierQuotes, Blacksmith.Tiers.FAST), 160, "fast tier maps to the fast quote")
assertEqual(Blacksmith.TierPrice(tierQuotes, Blacksmith.Tiers.REGULAR), 100, "regular tier maps to the regular quote")
assertEqual(Blacksmith.TierPrice(tierQuotes, Blacksmith.Tiers.SLOW), 70, "slow tier maps to the slow quote")
assertEqual(Blacksmith.TierPrice(tierQuotes, "bogus"), 100, "an unknown tier falls back to the regular quote")

------------------------------------------------------------
-- Blacksmith.IsValidTier / IsValidContainerType / IsOrderActive
------------------------------------------------------------
print("Blacksmith.IsValidTier / IsValidContainerType / IsOrderActive")

assertTrue(Blacksmith.IsValidTier(Blacksmith.Tiers.FAST), "FAST is a valid tier")
assertTrue(Blacksmith.IsValidTier(Blacksmith.Tiers.REGULAR), "REGULAR is a valid tier")
assertTrue(Blacksmith.IsValidTier(Blacksmith.Tiers.SLOW), "SLOW is a valid tier")
assertFalse(Blacksmith.IsValidTier("bogus"), "an unknown tier is invalid")
assertFalse(Blacksmith.IsValidTier(nil), "nil is not a valid tier")

assertTrue(Blacksmith.IsValidContainerType(Blacksmith.ContainerTypes.PRIVATE), "PRIVATE is a valid container type")
assertTrue(Blacksmith.IsValidContainerType(Blacksmith.ContainerTypes.PUBLIC), "PUBLIC is a valid container type")
assertTrue(Blacksmith.IsValidContainerType(Blacksmith.ContainerTypes.FORSALE), "FORSALE is a valid container type")
assertFalse(Blacksmith.IsValidContainerType("bogus"), "an unknown container type is invalid")

assertTrue(Blacksmith.IsOrderActive(Blacksmith.Status.SUBMITTED), "SUBMITTED counts as an active order")
assertTrue(Blacksmith.IsOrderActive(Blacksmith.Status.ACCEPTED), "ACCEPTED counts as an active order")
assertTrue(Blacksmith.IsOrderActive(Blacksmith.Status.COMPLETED), "COMPLETED counts as an active order (client hasn't approved yet)")
assertFalse(Blacksmith.IsOrderActive(Blacksmith.Status.CLOSED), "CLOSED does not count as an active order")
assertFalse(Blacksmith.IsOrderActive(Blacksmith.Status.DECLINED), "DECLINED does not count as an active order")
assertFalse(Blacksmith.IsOrderActive(Blacksmith.Status.CANCELLED), "CANCELLED does not count as an active order")
assertFalse(Blacksmith.IsOrderActive(Blacksmith.Status.EXPIRED), "EXPIRED does not count as an active order")

------------------------------------------------------------
-- SUMMARY
------------------------------------------------------------
print("")
print(string.format("%d/%d assertions passed", total - failed, total))
os.exit(failed == 0 and 0 or 1)
