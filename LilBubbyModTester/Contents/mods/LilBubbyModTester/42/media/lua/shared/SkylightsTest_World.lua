require "SkylightsTest_Checks"

-- World changes for the Skylights suite. They run where the world is
-- authoritative: on the server in multiplayer (SkylightsTest_Server.lua), or
-- directly in single player. Every object created is tagged with
-- SkylightsTest.MARKER so cleanup removes only test objects.
SkylightsTest.World = SkylightsTest.World or {}
local World = SkylightsTest.World
local N = SkylightsTest.ROOM
local DEPTH = SkylightsTest.DEPTH    -- the stairs run south of the room to y0 + DEPTH
local STAIRS_X = N - 1               -- the stairs' column, beside the room's east wall
local DOOR_Y = math.floor(N / 2)     -- the door's place in the west wall

World.sites = World.sites or {}      -- by owner key: room site

local function ownerKey(player)
    return isServer() and player:getUsername() or "local"
end

local function square(x, y, z)
    local cell = getCell()
    local sq = cell:getGridSquare(x, y, z)
    if not sq then
        sq = cell:createNewGridSquare(x, y, z, true)
    end
    return sq
end

local function buildable(name)
    for _, info in ipairs(ISBuildIsoEntity.GetAllBuildableEntities()) do
        if tostring(info:getName()) == name then return info end
    end
end

local function tag(object)
    object:getModData()[SkylightsTest.MARKER] = true
    object:transmitModData()
end

-- Places a vanilla build entity with the objects a player build creates.
-- ISBuildIsoEntity:create() needs recipe data that cheat builds lack, so this
-- validates and then calls setInfo(), create()'s object-creation step, on every
-- tile of the entity's face (stairs cover three) with a door's open sprite.
local function place(player, name, x, y, z, north, nSprite)
    local containers = ArrayList.new()
    containers:add(player:getInventory())
    local build = ISBuildIsoEntity:new(player, buildable(name), nSprite or (north and 2 or 1), containers)
    build.player = player:getPlayerNum()
    build.north = north
    build:isValid(square(x, y, z)) -- also finds the wall frame a wall replaces
    local face = build:getFace()
    local open = build:getOpenFace(north)
    if open and (open:getWidth() ~= face:getWidth() or open:getHeight() ~= face:getHeight()) then open = nil end
    for xx = 0, face:getWidth() - 1 do
        for yy = 0, face:getHeight() - 1 do
            local info = face:getTileInfo(xx, yy, 0)
            if info and info:getSpriteName() then
                local openInfo = open and open:getTileInfo(xx, yy, 0)
                local sq = square(x + xx, y + yy, z)
                build:setInfo(sq, north, info:getSpriteName(), openInfo and openInfo:getSpriteName() or false)
                -- The site was clear, so every thumpable on it belongs to the test room.
                for i = 0, sq:getObjects():size() - 1 do
                    local object = sq:getObjects():get(i)
                    if instanceof(object, "IsoThumpable") then tag(object) end
                end
            end
        end
    end
end

local function siteClear(x, y)
    local cell = getCell()
    for dx = -2, N + 2 do
        for dy = -2, DEPTH + 1 do
            local sq = cell:getGridSquare(x + dx, y + dy, 0)
            if not sq or sq:getRoom() or not sq:isOutside() or sq:getTree() or sq:HasStairs() then return false end
            local above = cell:getGridSquare(x + dx, y + dy, 1)
            if above and above:getObjects():size() > 0 then return false end
            if sq:getMovingObjects():size() > 0 then return false end
            for i = 0, sq:getObjects():size() - 1 do
                local props = sq:getObjects():get(i):getProperties()
                if props and (props:has(IsoFlagType.solid) or props:has(IsoFlagType.solidtrans)
                    or props:has(IsoFlagType.WallN) or props:has(IsoFlagType.WallW)
                    or props:has(IsoFlagType.collideN) or props:has(IsoFlagType.collideW)) then
                    return false
                end
            end
        end
    end
    return true
end

local function recalc(sq)
    sq:RecalcProperties()
    sq:RecalcAllWithNeighbours(true)
    getCell():checkHaveRoof(sq:getX(), sq:getY())
end

-- Builds a 5x5 wooden room roofed with wooden floor tiles at z=1 on a clear
-- outdoor site near the player, with a door in the west wall and wooden
-- stairs on the south side that climb north onto the roof.
function World.room(player)
    -- A room left by this player's earlier run is the suite's own; replace it.
    local replaced, old
    if World.sites[ownerKey(player)] then
        old = World.cleanup(player)
        replaced = old.removed
    end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    local found
    for r = 3, SkylightsTest.SEARCH_RADIUS do
        for dx = -r, r do
            for dy = -r, r do
                if not found and (math.abs(dx) == r or math.abs(dy) == r) and siteClear(px + dx, py + dy) then
                    found = { px + dx, py + dy }
                end
            end
        end
        if found then break end
    end
    if not found then
        return { error = "No clear, flat outdoor area of " .. (N + 5) .. "x" .. (DEPTH + 4) .. " tiles within "
            .. SkylightsTest.SEARCH_RADIUS .. " tiles." }
    end
    local x0, y0 = found[1], found[2]
    for dx = -1, N do
        for dy = -1, DEPTH do
            local sq = square(x0 + dx, y0 + dy, 0)
            for i = sq:getObjects():size() - 1, 0, -1 do
                local object = sq:getObjects():get(i)
                local props = object:getProperties()
                if not (props and props:has(IsoFlagType.solidfloor)) then sq:transmitRemoveItemFromSquare(object) end
            end
            square(x0 + dx, y0 + dy, 1)
        end
    end

    local cheat = player:isBuildCheat()
    player:setBuildCheat(true)
    local ok, err = pcall(function()
        for i = 0, N - 1 do
            for _, wall in ipairs({ { x0, y0 + i, false }, { x0 + N, y0 + i, false },
                                    { x0 + i, y0, true }, { x0 + i, y0 + N, true } }) do
                if wall[1] == x0 and i == DOOR_Y then
                    place(player, "WoodDoorFrameLvl1", wall[1], wall[2], 0, false)
                    place(player, "WoodenDoorLvl1", wall[1], wall[2], 0, false)
                else
                    place(player, "WoodenWallFrame", wall[1], wall[2], 0, wall[3])
                    place(player, "WoodenWallLvl1", wall[1], wall[2], 0, wall[3])
                end
            end
        end
        for dy = 0, N - 1 do
            for dx = 0, N - 1 do place(player, "WoodFloorLvl1", x0 + dx, y0 + dy, 1, false) end
        end
        -- Wooden stairs, west face: three tiles running south from y0+N+1,
        -- the top one's landing on y0+N at z=1, beside the roof's south edge.
        place(player, "Wood_Stairs", x0 + STAIRS_X, y0 + N + 1, 0, false, 1)
        local landing = square(x0 + STAIRS_X, y0 + N, 1):getFloor()
        if landing then tag(landing) end
    end)
    player:setBuildCheat(cheat)
    for dx = -1, N do
        for dy = -1, DEPTH do
            recalc(square(x0 + dx, y0 + dy, 1))
            recalc(square(x0 + dx, y0 + dy, 0))
        end
    end
    World.sites[ownerKey(player)] = { x0 = x0, y0 = y0 }
    if not ok then return { error = "Room build failed: " .. tostring(err), x0 = x0, y0 = y0 } end
    return { x0 = x0, y0 = y0, replaced = replaced, oldX0 = old and old.x0, oldY0 = old and old.y0,
        doorX = x0, doorY = y0 + DOOR_Y, stairsX = x0 + STAIRS_X, stairsY = y0 + N + 1 }
end

-- Gives the player one skylight's materials directly. Dropping them on the
-- roof for the player to pick up raced the multiplayer pickup transactions
-- and could be interrupted by the player; this cannot.
function World.materials(player, args)
    local inventory = player:getInventory()
    local items = { "Base.Mov_WindowWooden" }
    if not inventory:containsTypeRecurse("Screwdriver") then items[#items + 1] = "Base.Screwdriver" end
    for _ = 1, 4 do
        items[#items + 1] = "Base.Screws"
        items[#items + 1] = "Base.Plank"
    end
    local given = 0
    for _, fullType in ipairs(items) do
        local item = inventory:AddItem(fullType)
        if item then
            if isServer() then sendAddItemToContainer(inventory, item) end
            given = given + 1
        end
    end
    if given ~= #items then return { error = "Only " .. given .. " of " .. #items .. " materials could be given." } end
    return { count = given,
        prompt = "Items deposited to your inventory. Go up the stairs to the roof to build your skylight." }
end

-- Removing the room's walls and roof can leave its squares pointing at a room
-- whose RoomDef is gone. Vanilla code that reads the player's room (firearm
-- audio) then throws every frame and drops the game to the main menu, so any
-- such square around the site is detached from its room.
function World.clearStaleRooms(x0, y0)
    local cell, cleared = getCell(), 0
    for z = 0, 1 do
        for dx = -2, N + 2 do
            for dy = -2, DEPTH + 1 do
                local sq = cell:getGridSquare(x0 + dx, y0 + dy, z)
                local room = sq and sq:getRoom()
                if room and room:getRoomDef() == nil then
                    sq:setRoomID(-1)
                    cleared = cleared + 1
                end
            end
        end
    end
    return cleared
end

-- The caller's recorded test room, if any.
function World.site(player)
    local site = World.sites[ownerKey(player)]
    return site and { x0 = site.x0, y0 = site.y0 } or {}
end

-- Removes this owner's test room, its door and stairs, skylights and holes.
function World.cleanup(player)
    local key = ownerKey(player)
    local removed = 0
    local site = World.sites[key]
    if not site then
        return { removed = removed, note = "No test structure recorded for you on this server session." }
    end
    local cell = getCell()
    for z = 0, 1 do
        for dx = -1, N + 1 do
            for dy = -1, DEPTH do
                local sq = cell:getGridSquare(site.x0 + dx, site.y0 + dy, z)
                if sq then
                    for i = sq:getObjects():size() - 1, 0, -1 do
                        local object = sq:getObjects():get(i)
                        local data = object:getModData()
                        if data[SkylightsTest.MARKER] or data[SkylightsConfig.MARKER_KEY] then
                            sq:transmitRemoveItemFromSquare(object)
                            removed = removed + 1
                        end
                    end
                    local data = sq:getModData()
                    if data[SkylightsConfig.HOLE_KEY] or data.ConnectedToStairstrue or data.ConnectedToStairsfalse then
                        data[SkylightsConfig.HOLE_KEY] = nil
                        data.ConnectedToStairstrue, data.ConnectedToStairsfalse = nil, nil -- the stairs' landing
                        sq:transmitModdata()
                    end
                    recalc(sq)
                end
            end
        end
    end
    World.sites[key] = nil
    local cleared = World.clearStaleRooms(site.x0, site.y0)
    return { removed = removed, x0 = site.x0, y0 = site.y0, clearedRooms = cleared }
end
