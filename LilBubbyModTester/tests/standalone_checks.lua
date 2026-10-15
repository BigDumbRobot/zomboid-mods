-- The tester must load without any of the mods it can exercise.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local loaded, events = {}, {}
isClient = function() return false end
isServer = function() return false end
Events = setmetatable({}, { __index = function(t, name)
    events[name] = {}
    local event = { Add = function(callback) table.insert(events[name], callback) end }
    t[name] = event
    return event
end })
getActivatedMods = function() return { contains = function() return false end } end
require = function(name)
    -- Vanilla UI and timed actions are supplied by the game.
    if name:match("^ISUI/") or name:match("^TimedActions/") or name:match("^Vehicles/") then return end
    if loaded[name] then return end
    for _, side in ipairs({"shared", "client", "server"}) do
        local path = root .. side .. "/" .. name .. ".lua"
        local file = io.open(path)
        if file then
            file:close(); loaded[name] = true; dofile(path); return
        end
    end
    error("Unexpected external dependency: " .. name)
end
for _, name in ipairs({"PostalTest_Checks", "GovSvcTest_Checks", "VehSvcTest_Checks", "SVSBTTest_Traps", "DMMTest_Checks", "SkylightsTest_Checks", "SatanicTemplesTest_Checks"}) do require(name) end
for _, side in ipairs({"client", "server"}) do
    for _, name in ipairs({"BonkPvpTest", "PostalTest", "GovSvcTest", "VehSvcTest", "SVSBTTest", "DMMTest", "SkylightsTest", "SatanicTemplesTest"}) do
        dofile(root .. side .. "/" .. name .. "_" .. (side == "client" and "Client" or "Server") .. ".lua")
    end
end
dofile(root .. "client/CompatTest_Client.lua")
dofile(root .. "client/LilBubbyAutoRun.lua")
dofile(root .. "server/LilBubbyPrep_Server.lua")
assert(#LilBubbyShowcase.InstalledMods() == 0, "no suite is listed when none of its mods is enabled")
local player = { getPlayerNum = function() return 0 end, getOnlineID = function() return 1 end,
    getUsername = function() return "Tester" end, getVehicle = function() return nil end,
    getX = function() return 0 end, getY = function() return 0 end }
getSpecificPlayer = function() return player end
getCell = function() return { getVehicles = function() return { size = function() return 0 end } end } end
isClient = function() return true end
for _, mod in ipairs(LilBubbyShowcase.Mods) do
    local entries, notes = LilBubbyShowcase.Build(player, mod.id)
    assert(not notes:find("Unable to load features", 1, true), mod.id .. ": " .. notes)
    if mod.id == "bonk" then assert(#entries == 0 and notes:find("not enabled", 1, true), notes) end
end
local replies = {}
sendServerCommand = function(p, module, command, args) replies[#replies + 1] = args end
for _, command in ipairs({"run", "teleport", "return", "cancel"}) do
    for _, callback in ipairs(events.OnClientCommand) do callback("BonkPvpTest", command, player, {}) end
    assert(replies[#replies].status == "BLOCKED", "Bonk command must refuse missing mod: " .. command)
end
-- Detect the integration at call time too: initialization order must not cache nil.
BonkZone = { Registry = { GetZones = function() return {} end }, CombatGuard = {} }
getActivatedMods = function() return { contains = function(_, id) return id == "BonkZone" end } end
local entries = LilBubbyShowcase.Build(player, "bonk")
assert(#entries > 0, "Bonk suite becomes available after optional mod initializes")
local listed = {}
for _, mod in ipairs(LilBubbyShowcase.InstalledMods()) do listed[#listed + 1] = mod.id end
assert(table.concat(listed, ",") == "all,bonk,sites,compat", "only BonkZone's suites and the test sites are listed: " .. table.concat(listed, ","))
getActivatedMods = function() return { contains = function(_, id) return id == "\\KIPN" or id == "\\KIPNVehicleServices" end } end
listed = {}
for _, mod in ipairs(LilBubbyShowcase.InstalledMods()) do listed[#listed + 1] = mod.id end
assert(table.concat(listed, ",") == "all,vehicle,sites,compat", "backslash-prefixed mod IDs are recognised: " .. table.concat(listed, ","))
local info = assert(io.open("Contents/mods/LilBubbyModTester/42/mod.info")):read("a")
assert(not info:match("\nrequire="), "tester must not declare mod dependencies")
print("PASS: all client/server harnesses load with no tested mods, showcase builds, missing Bonk commands blocked and optional integration detected later")
