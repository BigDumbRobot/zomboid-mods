-- Offline checks for LilBubbyDesk: a powered, switched-on KIPN computer is set
-- up next to the player inside the designated zone of the requested kind,
-- reused, and cleaned up; the desk never makes a zone itself. Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
print = function() end
function isServer() return true end
local modData = {}
ModData = { getOrCreate = function(tag) modData[tag] = modData[tag] or {}; return modData[tag] end }

-- A flat, empty world of squares, with one building: x 96..104, y 196..204.
local function indoors(x, y) return x >= 96 and x <= 104 and y >= 196 and y <= 204 end
local squares = {}
local function square(x, y, z)
    local key = x .. "," .. y .. "," .. z
    if not squares[key] then
        local s = { x = x, y = y, z = z, objects = {} }
        function s:getX() return self.x end
        function s:getY() return self.y end
        function s:getZ() return self.z end
        function s:TreatAsSolidFloor() return true end
        function s:isFree() return #self.objects == 0 end
        function s:getBuilding() return indoors(self.x, self.y) and {} or nil end
        function s:isOutside() return not indoors(self.x, self.y) end
        function s:getObjects() local o = self.objects; return { size = function() return #o end, get = function(_, i) return o[i + 1] end } end
        function s:AddTileObject(object) object.square = self; self.objects[#self.objects + 1] = object end
        function s:transmitRemoveItemFromSquare(object)
            for i, x in ipairs(self.objects) do if x == object then table.remove(self.objects, i) end end
            object.square = nil
        end
        squares[key] = s
    end
    return squares[key]
end
function getCell() return { getGridSquare = function(_, x, y, z) return square(x, y, z) end } end

local function worldObject(sprite)
    local o = { modData = {}, sprite = sprite }
    function o:getModData() return self.modData end
    function o:getSprite() return { getName = function() return sprite end } end
    function o:getSquare() return self.square end
    function o:transmitCompleteItemToClients() self.sent = true end
    return o
end
IsoObject = { new = function(sq, sprite) return worldObject(sprite) end }
local generators = 0
IsoGenerator = { new = function(item, cell, sq)
    generators = generators + 1
    local g = worldObject("generator")
    g.isGenerator, g.fuel, g.max = true, 0, 10
    function g:setCondition(v) self.condition = v end
    function g:setFuel(v) self.fuel = v end
    function g:getMaxFuel() return self.max end
    function g:setConnected(v) self.connected = v end
    function g:setActivated(v) self.activated = v end
    function g:setSurroundingElectricity() end
    function g:sync() end
    function g:remove() self.removed = true end
    sq:AddTileObject(g)
    return g
end }
function instanceof(o, class) return class == "IsoGenerator" and o.isGenerator == true end
function instanceItem() return { setCondition = function() end } end

-- KIPN stand-ins.
local computers, powered, zones, nextZone = {}, {}, {}, 0
KIPN = {
    Shared = { GetComputerId = function(o) return string.format("comp_%d_%d_%d", o.square.x, o.square.y, o.square.z) end },
    Server = {
        GetOrCreateComputer = function(id) computers[id] = computers[id] or { locationKey = id }; return computers[id] end,
        SetComputerPower = function(id, on) powered[id] = on end,
        Save = function() return true end,
        WorldRegistry = {
            RegisteredZoneTypes = { government = true, dealership = true },
            GetZone = function(id) return zones[id] end,
            CreateZoneFromCorners = function(zoneType, a, b, metadata)
                nextZone = nextZone + 1
                local id = zoneType .. "_" .. nextZone
                zones[id] = { id = id, type = zoneType, active = true, geometry = { x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y }, metadata = metadata }
                return zones[id]
            end,
            UpdateZone = function(id, changes)
                zones[id].active = changes.active
                zones[id].geometry = changes.geometry
                return true
            end,
            DeactivateZone = function(id) zones[id].active = false; return true end,
        },
    },
}

function getTimestampMs() return 0 end
dofile(root .. "shared/LilBubbySites.lua")
-- A map with no default sites: an admin lays them out.
LilBubbySites.DEFAULTS = {}
dofile(root .. "server/LilBubbyDesk.lua")
local D, Sites = LilBubbyDesk, LilBubbySites
local px, py = 100, 200
local player = { getUsername = function() return "Tester" end, getX = function() return px + 0.5 end,
    getY = function() return py + 0.5 end, getZ = function() return 0 end, getAccessLevel = function() return "None" end }
local admin = { getUsername = function() return "Admin" end, getX = function() return 100.5 end,
    getY = function() return 200.5 end, getZ = function() return 0 end, getAccessLevel = function() return "admin" end }

-- Nothing is made for a player before an admin has laid the sites out.
local id, notes = D.Ensure(player, "government")
assert(id == nil and notes:find("does not exist", 1, true) and nextZone == 0, "no site, no desk and no zone: " .. tostring(notes))
local refused = Sites.SetUp(player)
assert(refused.status == "BLOCKED" and nextZone == 0, "a player cannot set the test sites up")
local made = Sites.SetUp(admin)
assert(made.lines and nextZone == 2, "an admin lays out one zone per enabled kind: " .. table.concat(made.lines or {}, "; "))
local government, dealership = Sites.Get("government"), Sites.Get("dealership")
assert(government and dealership and Sites.Get("career_services") == nil, "sites exist only for registered zone types")

id, notes = D.Ensure(player, "government")
assert(id, "a desk is set up: " .. tostring(notes))
local desk = modData.LilBubbyDesk.players.Tester
local cx, cy = desk.computer.x, desk.computer.y
assert(math.abs(cx - px) <= 3 and math.abs(cy - py) <= 3, "the computer is within reach")
local computer = square(cx, cy, 0).objects[1]
assert(computer.sprite == D.SPRITE and computer.sent, "a vanilla desktop computer is placed and sent to clients")
local generator = square(desk.generator.x, desk.generator.y, 0).objects[1]
assert(generator.activated and generator.connected and generator.fuel == generator.max, "a full, connected generator is running")
assert(indoors(cx, cy) and not indoors(desk.generator.x, desk.generator.y), "the computer is beside the player indoors; the generator stands outside the building")
assert(math.abs(desk.generator.x - cx) <= D.GENERATOR_RANGE and math.abs(desk.generator.y - cy) <= D.GENERATOR_RANGE, "the generator is near enough to power the computer")
assert(computers[id] and powered[id] == true, "the computer is registered and switched on in KIPN")
local zone = zones[government.id]
assert(zone.type == "government" and zone.active and zone.geometry.x1 <= cx and zone.geometry.x2 >= cx, "the computer stands in the designated government zone")
assert(D.ZoneId(player, "government") == government.id, "the desk reports the designated zone")

local again = D.Ensure(player, "government")
assert(again == id and generators == 1 and nextZone == 2, "a second test reuses the same desk and generator, and makes no zone")
-- A generator left indoors by an earlier version of the desk is moved out.
local old = square(desk.generator.x, desk.generator.y, 0)
old:transmitRemoveItemFromSquare(generator)
square(px + 2, py + 2, 0):AddTileObject(generator)
desk.generator = { x = px + 2, y = py + 2, z = 0 }
D.Ensure(player, "government")
assert(generators == 2 and generator.removed and not indoors(desk.generator.x, desk.generator.y), "an indoor generator is replaced by one outdoors")
generators = 1

-- Outside the designated zone the desk refuses; inside it, a new desk is placed.
local dealer, why = D.Ensure(player, "dealership")
assert(dealer == nil and why:find("not in the Dealership test zone", 1, true), "a player outside the zone gets no desk: " .. tostring(why))
px = dealership.spot.x
local moved = D.Ensure(player, "dealership")
assert(moved and moved ~= id and generators == 2, "in the dealership zone, a new desk is placed")
assert(#square(cx, cy, 0).objects == 0, "the old computer is removed")
assert(nextZone == 2, "still no zone was made for the player")

-- A zone an earlier version made around the player's desk is switched off once; designated zones stay.
local legacy = KIPN.Server.WorldRegistry.CreateZoneFromCorners("government", { x = 1, y = 1 }, { x = 2, y = 2 }, {})
desk.zones.government = legacy.id
local removed, deactivated = D.Cleanup(player)
assert(removed == 2 and deactivated == 1 and not zones[legacy.id].active, "cleanup removes the computer and generator and the old per-player zone")
assert(zones[government.id].active and zones[dealership.id].active, "the designated zones stay")
io.write("PASS: test desks place a powered, switched-on KIPN computer in the designated zone with its generator outdoors, are reused, refuse outside the zone, never make a zone, and clean up\n")
