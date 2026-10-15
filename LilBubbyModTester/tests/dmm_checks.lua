dofile('Contents/mods/LilBubbyModTester/42/media/lua/shared/DMMTest_Checks.lua')
local function list(t)
    t.size = function(self) return #self end
    t.get = function(self, i) return self[i + 1] end
    return t
end
local function call(target, name, ...)
    local method = target and target[name]
    if method then return true, method(target, ...) end
    return false, nil
end
local function mapItem(owner, age, symbols)
    local item = {
        getName = function() return owner .. "'s Annotated Map" end,
        getFullType = function() return 'Base.Map' end,
        getModData = function() return {DMM_IsDeathMap = true, DMM_OwnerName = owner,
            DMM_DeathWorldAgeHours = age, DMM_WipedPersonalMap = true} end,
        symbols = symbols,
    }
    local object = {getItem = function() return item end, isIgnoreRemoveSandbox = function() return true end}
    item.getWorldItem = function() return object end
    return object
end
local function symbolApi(symbols)
    return {
        getSymbolCount = function() return #symbols end,
        getSymbolByIndex = function(_, i) return symbols[i + 1] end,
    }
end
DeadMansMap = {Core = {
    getValue = function(target, getter, fallback)
        local ok, value = call(target, getter)
        if ok and value ~= nil then return value end
        return fallback
    end,
    openMapSymbols = function(item) return symbolApi(item.symbols) end,
    serializeMapSymbol = function(symbol) return symbol.user and {x = symbol.x, y = symbol.y, text = symbol.text} or nil end,
    getCharacterName = function(body) return body.name end,
}}
assert(DMMTest.available())

-- Serialisation keeps only user-drawn symbols; counting reads isUserDefined.
local personal = {
    {user = true, x = 1, y = 2, text = 'a', isUserDefined = function() return true end},
    {user = false, x = 5, y = 5, isUserDefined = function() return false end},
}
assert(DMMTest.userSymbolCount(symbolApi(personal)) == 1)
local captured = DMMTest.serializeAll(symbolApi(personal))
assert(#captured == 1 and captured[1].text == 'a')

-- Seeds are counted by position and content.
local written = {{text = 'a', x = 1, y = 2}, {symbolId = 'Circle', x = 3, y = 4}}
assert(DMMTest.countSeeds(written, {{x = 1, y = 2, text = 'a'}}) == 1)
assert(DMMTest.countSeeds(written, {{x = 1, y = 2, text = 'a'}, {x = 3, y = 4, symbolId = 'Circle'}}) == 2)
assert(DMMTest.countSeeds(written, {{x = 9, y = 2, text = 'a'}}) == 0)

-- Only the requested owner's maps from this death are returned.
local squares = {}
local function square(x, y, objects, bodies)
    squares[x .. ',' .. y] = {
        getX = function() return x end, getY = function() return y end, getZ = function() return 0 end,
        getWorldObjects = function() return list(objects or {}) end,
        getDeadBodys = function() return list(bodies or {}) end,
    }
end
getCell = function() return {getGridSquare = function(_, x, y) return squares[x .. ',' .. y] end} end
square(100, 100, {mapItem('Kate', 10.0, personal), mapItem('Kate', 2.0, {}), mapItem('Bob', 10.0, {})})
square(104, 97, {mapItem('Kate', 9.98, {})})
square(106, 100, {mapItem('Kate', 10.0, {})})
local found = DMMTest.findDeathMaps(100, 100, 0, 'Kate', 10.0)
assert(#found == 2, 'expected 2 maps, got ' .. #found)
assert(found[1].name == "Kate's Annotated Map" and found[1].loose and found[1].ignoreRemove and found[1].wipedFlag)
assert(#found[1].symbols + #found[2].symbols == 1)

-- The corpse must be a player body with the right name and death time.
local function body(name, isPlayer, deathTime)
    return {name = name, isPlayer = function() return isPlayer end, getDeathTime = function() return deathTime end}
end
square(101, 101, nil, {body('Kate', false, 10.0), body('Kate', true, 3.0), body('Bob', true, 10.0)})
assert(DMMTest.findPlayerCorpse(100, 100, 0, 'Kate', 10.0) == nil)
square(99, 101, nil, {body('Kate', true, 10.05)})
assert(DMMTest.findPlayerCorpse(100, 100, 0, 'Kate', 10.0) ~= nil)

-- Symbol comparison tolerates byte-rounded colours only.
assert(DMMTest.compareSymbols({{red = 0.9, text = 'a'}}, {{red = 229 / 255, text = 'a'}}) == nil)
assert(DMMTest.compareSymbols({{red = 0.9}}, {{red = 0.5}}):find('red=0.5', 1, true))
assert(DMMTest.compareSymbols({{text = 'a'}}, {}):find('annotation count 0, expected 1', 1, true))
assert(DMMTest.compareSymbols({{text = 'a'}}, {{text = 'b'}}):find('text=b', 1, true))

-- Report verdicts: any FAIL or ERROR fails the run; INFO does not count.
local report = DMMTest.newReport('T')
report:check('one', true)
report:info('note', 'x')
assert(report:text():find('^T: PASS %(1 passed, 0 failed%)'))
report:check('two', false, 'why')
assert(report:text():find('^T: FAIL %(1 passed, 1 failed%)') and report:text():find('FAIL | two | why', 1, true))
report:error('three', 'boom')
assert(report:text():find('%(1 passed, 2 failed%)'))
print('PASS: symbol counting, seed matching, death-map owner/age filter, corpse filter, symbol comparison, report verdicts')
