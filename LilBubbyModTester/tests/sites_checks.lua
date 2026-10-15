-- Offline checks for LilBubbySites: the server makes the designated zones
-- itself at the map's default places, only an admin can move them, players are
-- sent into them, and the showcase moves a player to a test's site before the
-- test starts. Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
print = function() end
local modData, zones, orders, now = {}, {}, {}, 0
ModData = { getOrCreate = function(tag) modData[tag] = modData[tag] or {}; return modData[tag] end }
function getTimestampMs() return now end
function getCell() return { getGridSquare = function() return nil end } end
local ticks = {}
Events = { OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end }, OnServerCommand = { Add = function() end },
    OnFillWorldObjectContextMenu = { Add = function() end } }
KIPN = { Server = { WorldRegistry = {
    RegisteredZoneTypes = { government = true, event = true },
    GetZone = function(id) return zones[id] end,
    CreateZoneFromCorners = function(zoneType, a, b)
        local id = zoneType .. "_" .. (#orders + 1) .. "_" .. a.x
        zones[id] = { id = id, type = zoneType, active = true }
        return zones[id]
    end,
    DeactivateZone = function(id) zones[id].active = false; return true end,
} } }
LilBubbyTeleport = { SETTLE_MS = 1000, Travelling = function() return false end,
    Order = function(player, x, y, z) orders[#orders + 1] = { x = x, y = y, z = z }; return 5000 end }
dofile(root .. "shared/LilBubbySites.lua")
local Sites = LilBubbySites

local function person(name, level, x, y)
    local p = { x = x, y = y }
    function p:getUsername() return name end
    function p:getAccessLevel() return level end
    function p:getX() return self.x + 0.5 end
    function p:getY() return self.y + 0.5 end
    function p:getZ() return 0 end
    function p:getVehicle() return nil end
    function p:getCurrentSquare() return {} end
    function p:getPlayerNum() return 0 end
    return p
end
-- Single player (neither server nor client) owns its world; a server decides by role and level.
function isServer() return true end
local admin, visitor = person("Admin", "admin", 1000, 2000), person("Visitor", "None", 50, 50)

-- On the vanilla map the server makes each zone itself, where the map says, the first time it is needed.
local defaults = Sites.DEFAULTS
local sent = Sites.Go(visitor, "government")
local first = Sites.Get("government")
assert(first and first.x1 == 12007 and first.y1 == 6729 and zones[first.id].active, "the server makes the government zone at its default place")
assert(sent.x == 12011 and sent.y == 6733 and #orders == 1, "and sends the player there")
assert(Sites.Get("government").id == first.id, "it is made once")
zones[first.id].active = false
assert(Sites.Get("government").id ~= first.id and Sites.Get("government").x1 == 12007, "a zone removed behind the tester's back is made again")
assert(Sites.Get("dealership") == nil and Sites.Missing("dealership"):find("does not exist", 1, true), "no zone for a mod that is not enabled")
for _, sites in pairs(defaults) do
    local list = {}
    for key, site in pairs(sites) do
        assert(site.spot.x >= site.x1 and site.spot.x <= site.x2 and site.spot.y >= site.y1 and site.spot.y <= site.y2, key .. ": the spot is inside its zone")
        for _, other in ipairs(list) do
            assert(site.x2 < other.x1 or other.x2 < site.x1 or site.y2 < other.y1 or other.y2 < site.y1, key .. " overlaps another default site")
        end
        list[#list + 1] = site
    end
end
-- ONE test site: every default zone lies inside the map's field, and players spawn inside it too.
local fields = 0
for map, sites in pairs(defaults) do
    local field = Sites.FIELD[map]
    assert(field, map .. ": a map with default zones names its one test site")
    fields = fields + 1
    assert(field.spawn.x >= field.x1 and field.spawn.x <= field.x2 and field.spawn.y >= field.y1 and field.spawn.y <= field.y2, "players spawn inside the test site")
    for key, site in pairs(sites) do
        assert(site.x1 >= field.x1 and site.x2 <= field.x2 and site.y1 >= field.y1 and site.y2 <= field.y2, key .. " lies outside the one test site")
    end
end
assert(fields == 1 and Sites.Field() == Sites.FIELD["Muldraugh, KY"])

-- A map with no defaults: nothing exists until an admin lays the sites out.
Sites.DEFAULTS = {}
zones[Sites.Get("government").id].active = false
modData.LilBubbySites.sites = {}
for id in pairs(zones) do zones[id] = nil end
orders = {}
assert(Sites.Go(visitor, "government").status == "BLOCKED" and #orders == 0, "no site before an admin sets them up")
assert(Sites.SetUp(visitor).status == "BLOCKED", "a player cannot lay the sites out")
for _ in pairs(zones) do error("a player made a zone") end
local made = Sites.SetUp(admin)
local government, event = Sites.Get("government"), Sites.Get("event")
assert(government and event, table.concat(made.lines, "; "))
assert(government.x1 == 996 and government.x2 == 1004 and event.spot.x == 1040 and event.spot.y == 2060, "the sites are laid out around the admin")
assert(event.y1 > government.y2, "the event zone does not overlap the desk row")
local skipped = table.concat(made.lines, "; ")
assert(skipped:find("SKIP: Dealership", 1, true) and Sites.Get("dealership") == nil, "kinds whose mod is not enabled are skipped: " .. skipped)

sent = Sites.Go(visitor, "event")
assert(sent.x == 1040 and sent.y == 2060 and sent.expected == 5000 and #orders == 1, "a player is sent to the site's spot")
assert(Sites.Problem(visitor, "event"):find("not in the Dynamic Events test zone", 1, true), "outside the zone the server says so")
visitor.x, visitor.y = 1040, 2060
assert(Sites.Go(visitor, "event").arrived and #orders == 1 and Sites.Problem(visitor, "event") == nil, "a player already there is not moved")

-- Laying the sites out again moves them; the old zones are switched off.
local old = government.id
admin.x = 3000
Sites.SetUp(admin)
assert(not zones[old].active and Sites.Get("government").x1 == 2996, "setting up again moves the sites")

-- The showcase moves a player to a test's site before the test starts.
function isServer() return false end
dofile(root .. "client/LilBubbyShowcase.lua")
local S = LilBubbyShowcase
local started = 0
S.Mods[#S.Mods + 1] = { id = "fixture", name = "Fixture", description = "", guide = "" }
S.Register("fixture", function(_, context)
    context:addOption("Needs the event zone", visitor, function() started = started + 1 end).site = "event"
    context:addOption("Needs a missing zone", visitor, function() started = started + 100 end).site = "dealership"
end)
getSpecificPlayer = function() return visitor end
local entries, notes = S.Build(visitor, "fixture")
visitor.x, visitor.y = 50, 50
assert(S.Run(visitor, "fixture", entries[1], notes) and started == 0 and Sites.Moving(visitor), "the test waits while the player travels")
for _, tick in ipairs(ticks) do tick() end
assert(started == 0, "still travelling")
visitor.x, visitor.y = Sites.Get("event").spot.x, Sites.Get("event").spot.y
for _, tick in ipairs(ticks) do tick() end
assert(started == 1 and not Sites.Moving(visitor), "the test starts once the player is in the zone")
assert(S.Run(visitor, "fixture", entries[2], notes) and started == 1, "a test whose zone is not set up does not start")
local history = S.Session(visitor, "fixture").history
assert(tostring(history[1]):find("does not exist", 1, true), "and the player is told why: " .. tostring(history[1]))
io.write("PASS: the server makes the designated zones itself, only an admin can move them, and players are moved into them before a test and never make one\n")
