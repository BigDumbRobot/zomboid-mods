-- Helpers shared by the Dead Man's Map suite's client and server halves.
-- DeadMansMap is optional for this tester, so its globals are read at call time.
DMMTest = DMMTest or {}

DMMTest.MODULE = "LilBubbyDMMTest"
DMMTest.SCAN_RADIUS = 5
-- Death maps and corpses stamped earlier than the test start (minus this
-- margin, in world hours) belong to an earlier death and are ignored.
DMMTest.AGE_MARGIN_HOURS = 0.05
DMMTest.CORPSE_DEATH_TIME_TOLERANCE_HOURS = 0.1

-- Written around the player's position before the kill.
DMMTest.SEED = {
    {text = "lilBubby DMM test: cache", dx = -5, dy = -7, r = 0.9, g = 0.1, b = 0.1},
    {symbolId = "Circle", dx = 3, dy = -5, r = 0.1, g = 0.8, b = 0.2},
    {text = "lilBubby DMM test: danger", dx = 10, dy = 3, r = 0.2, g = 0.3, b = 0.9},
    {symbolId = "Circle", dx = 15, dy = 8, r = 0.7, g = 0.7, b = 0.1},
}

function DMMTest.available()
    return DeadMansMap ~= nil and DeadMansMap.Core ~= nil and DeadMansMap.Core.openMapSymbols ~= nil
end

function DMMTest.worldAge()
    return getGameTime():getWorldAgeHours()
end

function DMMTest.userSymbolCount(api)
    local Core = DeadMansMap.Core
    local count = 0
    for i = 0, api:getSymbolCount() - 1 do
        local symbol = api:getSymbolByIndex(i)
        if symbol and Core.getValue(symbol, "isUserDefined", false) == true then
            count = count + 1
        end
    end
    return count
end

function DMMTest.serializeAll(api)
    local Core = DeadMansMap.Core
    local list = {}
    for i = 0, api:getSymbolCount() - 1 do
        local data = Core.serializeMapSymbol(api:getSymbolByIndex(i))
        if data then list[#list + 1] = data end
    end
    return list
end

-- Adds the SEED markings to a symbols API, centred on (x, y). Returns the
-- absolute positions written so callers can look for them later.
function DMMTest.writeSeed(api, x, y)
    local written = {}
    for _, seed in ipairs(DMMTest.SEED) do
        local sx, sy = x + seed.dx, y + seed.dy
        local symbol
        if seed.text then
            symbol = api:addUntranslatedText(seed.text, "text-note", sx, sy)
        else
            symbol = api:addTexture(seed.symbolId, sx, sy)
        end
        symbol:setRGBA(seed.r, seed.g, seed.b, 1)
        symbol:setUserDefined(true)
        written[#written + 1] = {text = seed.text, symbolId = seed.symbolId, x = sx, y = sy}
    end
    return written
end

-- Returns how many of the written seeds appear in a serialized symbol list.
function DMMTest.countSeeds(written, symbols)
    local found = 0
    for _, want in ipairs(written) do
        for _, got in ipairs(symbols) do
            if math.abs(got.x - want.x) < 0.5 and math.abs(got.y - want.y) < 0.5
                and (want.text and got.text == want.text or want.symbolId and got.symbolId == want.symbolId) then
                found = found + 1
                break
            end
        end
    end
    return found
end

-- Every death map owned by ownerName and stamped at or after sinceAge within
-- SCAN_RADIUS of (x, y, z), as plain tables so the server can send them.
function DMMTest.findDeathMaps(x, y, z, ownerName, sinceAge)
    local Core = DeadMansMap.Core
    local found = {}
    local cell = getCell()
    for dx = -DMMTest.SCAN_RADIUS, DMMTest.SCAN_RADIUS do
        for dy = -DMMTest.SCAN_RADIUS, DMMTest.SCAN_RADIUS do
            local square = cell and cell:getGridSquare(x + dx, y + dy, z)
            local objects = square and square:getWorldObjects()
            for i = 0, (objects and objects:size() or 0) - 1 do
                local object = objects:get(i)
                local item = object:getItem()
                local modData = item and item:getModData()
                if modData and modData.DMM_IsDeathMap == true
                    and modData.DMM_OwnerName == ownerName
                    and (tonumber(modData.DMM_DeathWorldAgeHours) or 0) >= sinceAge - DMMTest.AGE_MARGIN_HOURS then
                    local api = Core.openMapSymbols(item)
                    found[#found + 1] = {
                        name = item:getName(),
                        fullType = item:getFullType(),
                        loose = item:getWorldItem() == object,
                        ignoreRemove = object:isIgnoreRemoveSandbox() == true,
                        wipedFlag = modData.DMM_WipedPersonalMap == true,
                        corpseTagged = modData.DMM_CorpseTagged == true,
                        x = square:getX(), y = square:getY(), z = square:getZ(),
                        symbols = api and DMMTest.serializeAll(api) or {},
                    }
                end
            end
        end
    end
    return found
end

-- The player corpse named characterName that died at deathAge, near (x, y, z).
function DMMTest.findPlayerCorpse(x, y, z, characterName, deathAge)
    local Core = DeadMansMap.Core
    local cell = getCell()
    for dx = -DMMTest.SCAN_RADIUS, DMMTest.SCAN_RADIUS do
        for dy = -DMMTest.SCAN_RADIUS, DMMTest.SCAN_RADIUS do
            local square = cell and cell:getGridSquare(x + dx, y + dy, z)
            local bodies = square and square:getDeadBodys()
            for i = 0, (bodies and bodies:size() or 0) - 1 do
                local body = bodies:get(i)
                local deathTime = tonumber(Core.getValue(body, "getDeathTime", nil))
                if Core.getValue(body, "isPlayer", false) == true
                    and Core.getCharacterName(body) == characterName
                    and deathTime and math.abs(deathTime - deathAge) <= DMMTest.CORPSE_DEATH_TIME_TOLERANCE_HOURS then
                    return body, square
                end
            end
        end
    end
    return nil
end

------------------------------------------------------------
-- COPY MARKINGS TEST: items. Run directly in single player and on the
-- server in multiplayer, so the map, the pen and the writing tools the
-- client sees are real, synced items.
------------------------------------------------------------

DMMTest.COPY_OWNER = "DMM Copy Test"
DMMTest.COPY_SEED = {
    {text = "lilBubby DMM copy test: cache", dx = -6, dy = -9, r = 0.9, g = 0.1, b = 0.1},
    {symbolId = "Circle", dx = 4, dy = -6, r = 0.1, g = 0.8, b = 0.2},
    {text = "lilBubby DMM copy test: danger", dx = 12, dy = 5, r = 0.2, g = 0.3, b = 0.9},
}
-- Writing tools set aside per player (username, or "sp").
DMMTest.copyStash = DMMTest.copyStash or {}

local function stashKey(player)
    return isServer() and player:getUsername() or "sp"
end

function DMMTest.copyDeathId(stamp)
    return "lilbubby-copytest-" .. tostring(stamp)
end

function DMMTest.writeCopySeed(api, x, y, stamp)
    local written = {}
    for _, seed in ipairs(DMMTest.COPY_SEED) do
        local sx, sy = x + seed.dx, y + seed.dy
        local text = seed.text and (seed.text .. " " .. stamp) or nil
        local symbol
        if text then
            symbol = api:addUntranslatedText(text, "text-note", sx, sy)
        else
            symbol = api:addTexture(seed.symbolId, sx, sy)
        end
        symbol:setRGBA(seed.r, seed.g, seed.b, 1)
        symbol:setUserDefined(true)
        written[#written + 1] = {text = text, symbolId = seed.symbolId, x = sx, y = sy}
    end
    return written
end

local function removeFromContainer(container, item)
    container:Remove(item)
    if isServer() then sendRemoveItemFromContainer(container, item) end
end

local function addToContainer(container, item)
    container:AddItem(item)
    if isServer() then sendAddItemToContainer(container, item) end
end

-- Drops a test Annotated Map on the player's square, the way a death drops
-- one, and sets every writing tool aside. Returns the written markings.
function DMMTest.copySetup(player, stamp)
    local Core = DeadMansMap.Core
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local item = instanceItem("Base.Map")
    item:setMapID(Core.MAP_ID)
    local api = Core.openMapSymbols(item)
    if not api then return nil, "could not open the map's symbols" end
    local written = DMMTest.writeCopySeed(api, x, y, stamp)
    Core.tagDeathMap(item, {characterName = DMMTest.COPY_OWNER, deathId = DMMTest.copyDeathId(stamp),
        x = x, y = y, z = z, worldAgeHours = DMMTest.worldAge()}, #written, #written)
    local square = player:getCurrentSquare()
    local added = square:AddWorldInventoryItem(item, 0.5, 0.5, 0.0, false)
    local worldObject = added and added:getWorldItem()
    if worldObject and isServer() then worldObject:transmitCompleteItemToClients() end

    local stashed = {}
    local inv = player:getInventory()
    for _ = 1, 100 do
        local tool = inv:getFirstTagRecurse(ItemTag.WRITE)
        if not tool then break end
        local container = tool:getContainer()
        removeFromContainer(container, tool)
        stashed[#stashed + 1] = {item = tool, container = container}
    end
    DMMTest.copyStash[stashKey(player)] = stashed
    return written, #stashed
end

function DMMTest.copyGivePen(player)
    local pen = instanceItem("Base.Pen")
    pen:getModData().LilBubbyDMMCopyPen = true
    addToContainer(player:getInventory(), pen)
    return pen
end

-- Every item carrying the test's marks, anywhere in the player's inventory.
local function testItems(container, deathId, found)
    local items = container:getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        local data = item:getModData()
        if data.LilBubbyDMMCopyPen == true or data.DMM_DeathId == deathId then
            found[#found + 1] = {item = item, container = container}
        end
        if instanceof(item, "InventoryContainer") then testItems(item:getInventory(), deathId, found) end
    end
    return found
end

-- Removes the test map (carried or still on the ground nearby) and the pen,
-- and puts the writing tools back. Returns how many writing tools went back.
function DMMTest.copyCleanup(player, stamp)
    local deathId = DMMTest.copyDeathId(stamp)
    for _, entry in ipairs(testItems(player:getInventory(), deathId, {})) do
        removeFromContainer(entry.container, entry.item)
    end
    local cell = getCell()
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -DMMTest.SCAN_RADIUS, DMMTest.SCAN_RADIUS do
        for dy = -DMMTest.SCAN_RADIUS, DMMTest.SCAN_RADIUS do
            local square = cell:getGridSquare(x + dx, y + dy, z)
            local objects = square and square:getWorldObjects()
            for i = (objects and objects:size() or 0) - 1, 0, -1 do
                local object = objects:get(i)
                local item = object:getItem()
                if item and item:getModData().DMM_DeathId == deathId then
                    square:transmitRemoveItemFromSquare(object)
                end
            end
        end
    end
    local stashed = DMMTest.copyStash[stashKey(player)] or {}
    DMMTest.copyStash[stashKey(player)] = nil
    for _, entry in ipairs(stashed) do addToContainer(entry.container, entry.item) end
    return #stashed
end

-- The engine stores colours as bytes, so 0.9 comes back as 229/255.
local TOLERANCE = 1 / 255 + 0.0001

-- Returns nil when equal, otherwise a description of the first difference.
function DMMTest.compareSymbols(expected, actual)
    if #actual ~= #expected then
        return "annotation count " .. #actual .. ", expected " .. #expected
    end
    for i, want in ipairs(expected) do
        for key, value in pairs(want) do
            local got = actual[i][key]
            local differs
            if type(value) == "number" and type(got) == "number" then
                differs = math.abs(value - got) > TOLERANCE
            else
                differs = got ~= value
            end
            if differs then
                return "annotation " .. i .. " " .. key .. "=" .. tostring(got) .. ", expected " .. tostring(value)
            end
        end
    end
    return nil
end

local Report = {}
Report.__index = Report

function DMMTest.newReport(title)
    return setmetatable({title = title, lines = {}, passed = 0, failed = 0}, Report)
end

function Report:add(status, name, detail)
    self.lines[#self.lines + 1] = status .. " | " .. name .. (detail and (" | " .. tostring(detail)) or "")
    print("[" .. DMMTest.MODULE .. "] " .. self.lines[#self.lines])
end

function Report:check(name, condition, detail)
    if condition then self.passed = self.passed + 1 else self.failed = self.failed + 1 end
    self:add(condition and "PASS" or "FAIL", name, detail)
    return condition
end

function Report:info(name, detail)
    self:add("INFO", name, detail)
end

function Report:error(name, detail)
    self.failed = self.failed + 1
    self:add("ERROR", name, detail)
end

function Report:text()
    local verdict = self.failed == 0 and "PASS" or "FAIL"
    return self.title .. ": " .. verdict .. " (" .. self.passed .. " passed, " .. self.failed .. " failed)\n"
        .. table.concat(self.lines, "\n")
end
