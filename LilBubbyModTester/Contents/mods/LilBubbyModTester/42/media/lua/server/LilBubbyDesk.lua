-- Test desks: tests that need a KIPN computer get one inside the designated
-- zone of the kind the test needs (government, dealership, ...). The zone is
-- never made here: an admin lays the test sites out once (LilBubbySites) and
-- the player is moved into the site before the test starts. The server
-- places a vanilla desktop computer next to the player, powers it with a
-- running generator placed outdoors (a generator running inside poisons the
-- building), and registers and switches it on in KIPN. One desk per player
-- is reused; Cleanup removes the computer and generator.
LilBubbyDesk = LilBubbyDesk or {}
local D = LilBubbyDesk

D.SPRITE = "appliances_com_01_72" -- vanilla Mov_DesktopComputer
D.TAG = "LilBubbyDesk"
D.GENERATOR_RANGE = 15 -- tiles from the computer searched for an outdoor square; a generator powers 20

local function state(player)
    local data = ModData.getOrCreate(D.TAG)
    data.players = data.players or {}
    local key = player:getUsername()
    data.players[key] = data.players[key] or { zones = {} }
    return data.players[key], data
end

local function tagged(object) return object and object:getModData()[D.TAG] == true end

local function findTagged(x, y, z, want)
    local square = getCell():getGridSquare(x, y, z)
    local objects = square and square:getObjects()
    for i = 0, (objects and objects:size() or 0) - 1 do
        local object = objects:get(i)
        if tagged(object) and (want == nil or want(object)) then return object, square end
    end
end

local function freeSquare(player, minDistance, maxDistance, avoid)
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for r = minDistance, maxDistance do
        for dx = -r, r do
            for dy = -r, r do
                if (math.abs(dx) == r or math.abs(dy) == r) and not (avoid and avoid.x == px + dx and avoid.y == py + dy) then
                    local square = getCell():getGridSquare(px + dx, py + dy, pz)
                    if square and square:TreatAsSolidFloor() and square:isFree(false) then return square end
                end
            end
        end
    end
end

local function outdoors(square)
    return square ~= nil and square:getBuilding() == nil and square:isOutside()
end

-- The nearest free outdoor square to the computer, on its floor or the ground.
local function outdoorSquare(spot)
    local levels = spot.z == 0 and { 0 } or { spot.z, 0 }
    for _, z in ipairs(levels) do
        for r = 2, D.GENERATOR_RANGE do
            for dx = -r, r do
                for dy = -r, r do
                    if math.abs(dx) == r or math.abs(dy) == r then
                        local square = getCell():getGridSquare(spot.x + dx, spot.y + dy, z)
                        if outdoors(square) and square:TreatAsSolidFloor() and square:isFree(false) then return square end
                    end
                end
            end
        end
    end
end

local function removeObject(object, square)
    if instanceof(object, "IsoGenerator") then
        pcall(function() object:setActivated(false) end)
        pcall(function() object:remove() end)
    end
    if object:getSquare() then square:transmitRemoveItemFromSquare(object) end
end

local function place(square, object)
    square:AddTileObject(object)
    object:getModData()[D.TAG] = true
    if isServer() then object:transmitCompleteItemToClients() end
end

local function computerHere(desk)
    return desk.computer and findTagged(desk.computer.x, desk.computer.y, desk.computer.z,
        function(object) return object:getSprite() and object:getSprite():getName() == D.SPRITE end)
end

local function near(player, spot, range)
    return spot and math.abs(player:getX() - spot.x) <= range and math.abs(player:getY() - spot.y) <= range
        and math.floor(player:getZ()) == spot.z
end

-- The desk's computer square ({ x, y, z }), or nil.
function D.ComputerSpot(player)
    return state(player).computer
end

-- The desk's generator square ({ x, y, z }), or nil.
function D.GeneratorSpot(player)
    return state(player).generator
end

-- The designated test zone of zoneType, or nil while it is not set up.
function D.ZoneId(player, zoneType)
    local site = LilBubbySites.Get(zoneType)
    return site and site.id
end

-- The desk's computer and generator objects where they still stand.
function D.Objects(player)
    local desk = state(player)
    local generator = desk.generator and findTagged(desk.generator.x, desk.generator.y, desk.generator.z,
        function(object) return instanceof(object, "IsoGenerator") end)
    return computerHere(desk) or nil, generator or nil
end

-- A full tank, connected and running.
function D.Refuel(generator)
    generator:setCondition(100)
    generator:setFuel(generator:getMaxFuel())
    generator:setConnected(true)
    generator:setActivated(true)
    pcall(function() generator:setSurroundingElectricity() end)
    if isServer() then pcall(function() generator:transmitCompleteItemToClients() end) end
    pcall(function() generator:sync() end)
end

-- Returns a powered, switched-on KIPN computer id within reach of the player
-- inside the designated zone of zoneType, and notes describing what was set
-- up; or nil and why (the zone is not set up, or the player is not in it).
-- options.computerSquare chooses where a new computer goes. options.power =
-- false leaves the computer off for the player to switch on.
function D.Ensure(player, zoneType, options)
    options = type(options) == "table" and options or {}
    local problem = LilBubbySites.Problem(player, zoneType)
    if problem then return nil, problem end
    local desk, data = state(player)
    local notes = {}
    local computer = near(player, desk.computer, 3) and computerHere(desk)
    if not computer then
        D.RemoveObjects(player)
        local square = options.computerSquare or freeSquare(player, 1, 3)
        if not square then return nil, "no free floor within 3 tiles for a test computer" end
        computer = IsoObject.new(square, D.SPRITE, "Computer")
        place(square, computer)
        desk.computer = { x = square:getX(), y = square:getY(), z = square:getZ() }
        notes[#notes + 1] = "placed a computer at " .. desk.computer.x .. "," .. desk.computer.y
    end
    local generator, generatorSquare
    if desk.generator then
        generator, generatorSquare = findTagged(desk.generator.x, desk.generator.y, desk.generator.z,
            function(object) return instanceof(object, "IsoGenerator") end)
    end
    local outside = (not generator or not outdoors(generatorSquare)) and outdoorSquare(desk.computer) or nil
    if generator and outside then
        -- An earlier desk's generator standing indoors moves out.
        removeObject(generator, generatorSquare)
        generator = nil
    end
    if not generator then
        local square = outside or freeSquare(player, 2, 4, desk.computer)
        if not square then return nil, "no free floor for the test generator" end
        if not outside then
            notes[#notes + 1] = "no free outdoor square within " .. D.GENERATOR_RANGE
                .. " tiles: the generator stands indoors, where its fumes are poisonous"
        end
        local item = instanceItem("Base.Generator")
        item:setCondition(100)
        generator = IsoGenerator.new(item, getCell(), square)
        generator:getModData()[D.TAG] = true
        desk.generator = { x = square:getX(), y = square:getY(), z = square:getZ() }
        notes[#notes + 1] = "placed a generator at " .. desk.generator.x .. "," .. desk.generator.y
    end
    D.Refuel(generator)

    local id = KIPN.Shared.GetComputerId(computer)
    if not id then return nil, "KIPN does not recognise the test computer" end
    if KIPN.Server.GetOrCreateComputer then KIPN.Server.GetOrCreateComputer(id) end
    local switchOn = options.power ~= false
    if switchOn and KIPN.Server.SetComputerPower then pcall(KIPN.Server.SetComputerPower, id, true) end
    local zoneId = D.ZoneId(player, zoneType)
    data.dirty = true
    notes[#notes + 1] = "computer " .. tostring(id) .. " powered by the generator, "
        .. (switchOn and "switched on" or "left off for you to switch on") .. ", in the designated "
        .. zoneType .. " test zone " .. tostring(zoneId)
    return id, table.concat(notes, "; ")
end

function D.RemoveObjects(player)
    local desk = state(player)
    local removed = 0
    for _, spot in ipairs({ desk.computer, desk.generator }) do
        local object, square = findTagged(spot and spot.x or 0, spot and spot.y or 0, spot and spot.z or 0)
        if object then
            removeObject(object, square)
            removed = removed + 1
        end
    end
    desk.computer, desk.generator = nil, nil
    return removed
end

-- Removes the test computer and generator. The designated zones stay. A
-- zone an earlier version of the tester made around this player's desk is
-- switched off, once.
function D.Cleanup(player)
    local desk = state(player)
    local removed = D.RemoveObjects(player)
    local WR = KIPN and KIPN.Server and KIPN.Server.WorldRegistry
    local zones = 0
    for zoneType, id in pairs(desk.zones) do
        if WR and WR.GetZone(id) and WR.GetZone(id).active ~= false then
            if WR.DeactivateZone(id) then zones = zones + 1 end
        end
        desk.zones[zoneType] = nil
    end
    if zones > 0 and KIPN.Server.BroadcastZoneSync then pcall(KIPN.Server.BroadcastZoneSync) end
    return removed, zones
end

return LilBubbyDesk
