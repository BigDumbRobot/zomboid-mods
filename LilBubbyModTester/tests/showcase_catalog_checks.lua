-- Load the real suite builders and ensure the showcase exposes their actions.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
require = function() end
getActivatedMods = function() return { contains = function() return true end } end -- every tested mod enabled
Events = setmetatable({}, { __index = function(t, key)
    local event = { Add = function() end }; t[key] = event; return event
end })
dofile(root .. "shared/LilBubbySites.lua")
dofile(root .. "client/LilBubbyShowcase.lua")
for _, name in ipairs({"PostalTest", "GovSvcTest", "VehSvcTest", "DMMTest", "SkylightsTest", "CareersTest", "WhisperersTest", "SatanicTemplesTest", "DynamicEventsTest"}) do
    dofile(root .. "shared/" .. name .. "_Checks.lua")
end
dofile(root .. "shared/PostalTest_Guided.lua")
dofile(root .. "shared/SkylightsTest_World.lua")
dofile(root .. "shared/SVSBTTest_Traps.lua")
local player = { getPlayerNum = function() return 0 end, getVehicle = function() return nil end,
    getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end,
    isDead = function() return false end }
getSpecificPlayer = function() return player end
isClient = function() return true end
getCell = function() return { getVehicles = function() return { size = function() return 0 end } end } end
BonkZone = { Registry = { GetZones = function() return {{name="Test Zone", id="zone"}} end } }
SVSBT = { Shared = {KindRecipe = { testTrap = "recipe" }}, Client = { KindName = function(kind) return kind end }, Config = {} }
DMMTest.available = function() return true end
SkylightsTest.available = function() return true end
WhisperersTest.available = function() return true end
SatanicTemplesTest.available = function() return true end
-- Enough of Dynamic Events' shared data for its suite to build its menu.
KIPN = { oFillMenuOutsideVehicle = function() end, Shared = { EventModes = { OLYMPICS = "OLYMPICS" },
    EventClassicScenarioOrder = { "FIRE_SALE" }, EventClassicScenarios = { FIRE_SALE = { label = "Fire Sale", venue = { label = "the mall" } } } } }
KIPN_VehicleClaimAction = {}
for _, name in ipairs({"BonkPvpTest", "PostalTest", "GovSvcTest", "VehSvcTest", "SVSBTTest", "DMMTest", "SkylightsTest", "CareersTest", "WhisperersTest", "SatanicTemplesTest", "DynamicEventsTest", "CompatTest", "LilBubbyAutoRun"}) do
    dofile(root .. "client/" .. name .. (name:find("^LilBubby") and "" or "_Client") .. ".lua")
end
local S = LilBubbyShowcase
local counts = {}
for _, mod in ipairs(S.Mods) do
    local entries, notes = S.Build(player, mod.id)
    assert(#entries > 0, mod.id .. ": " .. notes)
    local keys = {}
    for _, entry in ipairs(entries) do
        assert(not keys[entry.key], "duplicate feature " .. entry.key)
        keys[entry.key] = true
    end
    counts[mod.id] = #entries
end
assert(counts.government == #GovSvcTest.Catalog + 1)
-- Dynamic Events: every feature, one visit per classic location, cleanup and show last result.
assert(counts.events == #DynamicEventsTest.Features + 1 + 2, "every Dynamic Events feature is listed: " .. tostring(counts.events))
assert(counts.vehicle == #VehSvcTest.Catalog + 2)
assert(counts.careers == #CareersTest.Catalog({ CareersDrugDealer = true, CareersMechanic = true, CareersBlacksmith = true }) + 1,
    "every careers feature is listed: " .. tostring(counts.careers))
assert(counts.postal == 4 and counts.dmm == 3 and counts.bonk == 16 and counts.all == 4 and counts.skylights == 2 and counts.whisperers == 6
    and counts.satanic == 5 and counts.spy == 3, "satanic features: " .. tostring(counts.satanic))
local vehicles = S.Build(player, "vehicle")
for _, entry in ipairs(vehicles) do
    local catalog = entry.args[1]
    if type(catalog) == "table" and catalog.vehicle then assert(entry.notAvailable, "missing vehicle blocks action") end
end
print("PASS: all eleven real suite catalogs load, no duplicate features, catalog coverage and missing vehicle gating")
