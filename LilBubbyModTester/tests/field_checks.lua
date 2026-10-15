-- Offline checks for the one test site: the server says so when players do not
-- spawn inside it, and a zone made at a default place that has since moved
-- into the site is removed and made again there, unless an admin placed it.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local log = {}
print = function(text) log[#log + 1] = tostring(text) end
local modData, removed, made, now = {}, {}, {}, 0
ModData = { getOrCreate = function(tag) modData[tag] = modData[tag] or {}; return modData[tag] end }
function getTimestampMs() return now end
function getCell() return { getGridSquare = function() return nil end } end
function isServer() return true end
function isClient() return false end
local spawn = "0,0,0"
function getServerOptions() return { getOption = function(_, name) return name == "SpawnPoint" and spawn or "Muldraugh, KY" end } end
local minute = {}
Events = { OnTick = { Add = function() end }, OnServerCommand = { Add = function() end }, OnClientCommand = { Add = function() end },
    OnFillWorldObjectContextMenu = { Add = function() end },
    EveryOneMinute = { Add = function(fn) minute[#minute + 1] = fn end, Remove = function() minute = {} end } }
LilBubbyTeleport = { SETTLE_MS = 1000, Travelling = function() return false end, Order = function() return 5000 end }
dofile(root .. "shared/LilBubbySites.lua")
local Sites = LilBubbySites
local alive = {}
local function provide()
    Sites.Provide("bonk", { label = "Bonk Zone", available = function() return true end,
        create = function(_, rect) made[#made + 1] = rect; alive[#made] = true; return #made end,
        remove = function(_, id) removed[#removed + 1] = id; alive[id] = nil end,
        exists = function(id) return alive[id] == true end })
end

-- Spawn -------------------------------------------------------------------------
local field = Sites.Field()
assert(field.spawn.x == 12001 and field.spawn.y == 6661)
assert(Sites.SpawnProblem():find("SpawnPoint=12001,6661,0", 1, true), "no SpawnPoint: the server is told what to set")
spawn = "12067,6801,0"
assert(Sites.SpawnProblem():find("12067,6801,0", 1, true), "a SpawnPoint outside the site is a problem too")
minute[1]()
local warned = false
for _, line in ipairs(log) do warned = warned or line:find("do not spawn in the test site", 1, true) ~= nil end
assert(warned, "and it is logged when the server starts")
spawn = "12001,6661,0"
assert(Sites.SpawnProblem() == nil, "the field's spawn is fine")
spawn = "11950, 6700, 0"
assert(Sites.SpawnProblem() == nil, "so is anywhere else inside the site")

-- A Bonk zone the server made at the old default moves into the site ----------------
modData = {} -- a world saved by the previous version: no layout number yet
local stored = ModData.getOrCreate(Sites.TAG)
stored.sites = { bonk = { id = 7, x1 = 12049, y1 = 6810, x2 = 12069, y2 = 6830, z = 0, spot = { x = 12059, y = 6820, z = 0 } } }
alive[7] = true
assert(Sites.Get("bonk") == nil and #removed == 0 and stored.layout == nil, "nothing is forgotten before the suite that owns the zone has registered")
provide()
local site = Sites.Get("bonk")
assert(#removed == 1 and removed[1] == 7, "the old zone is removed")
assert(site.x1 == 12028 and site.y1 == 6705 and site.spot.x == 12038 and #made == 1, "and made again inside the site")
assert(site.x1 >= field.x1 and site.x2 <= field.x2 and site.y1 >= field.y1 and site.y2 <= field.y2)
assert(stored.layout == Sites.LAYOUT and Sites.Get("bonk").id == site.id and #made == 1 and #removed == 1, "once")

-- One an admin placed stays where it is --------------------------------------------
modData, removed, made, alive = {}, {}, {}, { [9] = true }
stored = ModData.getOrCreate(Sites.TAG)
stored.origin = { x = 500, y = 500, z = 0 }
stored.sites = { bonk = { id = 9, x1 = 12049, y1 = 6810, x2 = 12069, y2 = 6830, z = 0, spot = { x = 12059, y = 6820, z = 0 } } }
assert(Sites.Get("bonk").id == 9 and #removed == 0 and #made == 0, "an admin's layout is never touched")

-- A fresh world just uses the new place.
modData, removed, made, alive = {}, {}, {}, {}
assert(Sites.Get("bonk").x1 == 12028 and #removed == 0 and #made == 1)

io.stdout:write("field_checks: ok\n")
