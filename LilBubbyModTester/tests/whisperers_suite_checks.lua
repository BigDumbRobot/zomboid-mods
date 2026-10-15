-- Offline checks for The Whisperers suite's own rules: report format, expected
-- values, the server's argument checks, the give whitelist, and a
-- cleanup that removes only what the test made. Run from this project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
require = function() end
local serverCalls = {}
local handlers = {}
Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) handlers[name] = fn end }
    rawset(t, name, e)
    return e
end })
isServer = function() return true end
isClient = function() return false end
sendServerCommand = function(player, module, command, args) serverCalls[#serverCalls + 1] = args end
sendAddItemToContainer = function() end
sendRemoveItemFromContainer = function() end
sendEquip = function() end
LilBubbyPacer = { Run = function(_, _, _, fn) fn() end }
Whisperers = { Gear = { NameKey = "WhispName" }, Client = {} }
Whisp_RemoveHeadAction, Whisp_SkinCorpseAction = {}, {}
local function list(t) return { size = function() return #t end, get = function(_, i) return t[i + 1] end } end

dofile(root .. "shared/WhisperersTest_Checks.lua")
dofile(root .. "shared/WhisperersTest_World.lua")
dofile(root .. "server/WhisperersTest_Server.lua")
local T, World = WhisperersTest, WhisperersTest.World

-- A dedicated server never loads the mod's client folder: no Whisperers.Client
-- there must not make the server refuse every request as "not enabled".
local client = Whisperers.Client
Whisperers.Client = nil
assert(T.available(), "the server does not need Whisperers.Client")
isServer = function() return false end
assert(not T.available(), "a client without Whisperers.Client is not ready")
isServer = function() return true end
Whisperers.Client = client

-- Report text is what the showcase and Run every test parse.
local r = T.newReport("Whisperers full test")
print = function() end
r:check("a", true); r:check("b", false, "why"); r:info("c", "d")
assert(r:text():find("^Whisperers full test: FAIL %(1 passed, 1 failed%)"), r:text())
assert(r:text():find("FAIL | b | why", 1, true), r:text())

-- Expected values.
local low, high = T.gutsRange(3, 2, 0.5)
assert(low == 3 and high == 4, "Butchering 3 yields 3-4 guts: " .. low .. "-" .. high)
low, high = T.gutsRange(10, 2, 0.5)
assert(low == 7 and high == 7, "Butchering 10 yields exactly 7: " .. low .. "-" .. high)
assert(T.maskCondition(1, false, 30) == 100, "perfect face, needle")
assert(T.maskCondition(1, true, 30) == 70, "perfect face, nail")
assert(T.maskCondition(0.5, true, 30) == 35, "half face, nail")

-- Server: every operation is open to every player; arguments are checked.
World.cleanup = function() return { items = 0, corpses = 0 } end
World.wash = function() return {} end
local called = {}
for _, op in ipairs({ "setup", "give", "corpse", "zombie", "hit", "ageGuts", "gaitKit" }) do
    World[op] = function() called[op] = true; return {} end
end
local player = { getUsername = function() return "tester" end }
local function send(command, args) serverCalls = {}; handlers.OnClientCommand(T.MODULE, command, player, args or {}); return serverCalls[1] end
for _, op in ipairs({ "setup", "give", "corpse", "zombie", "hit", "ageGuts", "gaitKit" }) do
    local reply = send(op, { type = "Base.Needle", damage = 10, hours = 1 })
    assert(reply.status ~= "BLOCKED" and reply.error == nil and called[op], op .. " is open to players")
    called[op] = nil
end
assert(send("cleanup").error == nil, "cleanup is open to players")
assert(send("wash").error == nil, "wash is open to players")
assert(send("corpse", { dx = 50 }).error, "a corpse far away is refused")
assert(send("hit", { damage = 500 }).error, "an absurd hit is refused")
assert(send("give", { type = 5 }).error, "a give without a type is refused")
assert(send("corpse", { dx = 1, dy = 0 }).error == nil and called.corpse, "a player may place a corpse")
assert(send("bogus") == nil, "unknown operations are ignored")

-- The give whitelist, on the real World.give.
dofile(root .. "shared/WhisperersTest_World.lua")
local given = {}
local inventory = { AddItem = function(_, t) local item = { t = t, md = {} }
    function item:getModData() return self.md end; given[#given + 1] = item; return item end }
local p2 = { getInventory = function() return inventory end }
assert(World.give(p2, { type = "Base.Katana" }).error, "only the needle and test shirt may be given mid-test")
assert(World.give(p2, { type = "Base.Needle" }).error == nil and given[1].md[T.MARKER], "a given needle is tagged")

-- The zombie mannerisms kit: a tagged face mask and skin suit at full condition.
Whisperers.Gear.Types = { Mask = "Whisperers.FaceMask", Suit = "Whisperers.SkinSuit" }
given = {}
inventory.AddItem = function(_, t)
    local it = { t = t, md = {}, cond = 3 }
    function it:getModData() return self.md end
    function it:getConditionMax() return 100 end
    function it:setCondition(c) self.cond = c end
    given[#given + 1] = it
    return it
end
isServer = function() return false end
assert(World.gaitKit(p2, {}).error == nil, "gaitKit succeeds")
assert(#given == 2 and given[1].t == "Whisperers.FaceMask" and given[2].t == "Whisperers.SkinSuit", "gaitKit gives a mask and a suit")
assert(given[1].md[T.MARKER] and given[2].md[T.MARKER], "the kit is tagged for cleanup")
assert(given[1].cond == 100 and given[2].cond == 100, "the kit starts at full condition")
isServer = function() return true end

-- Zombie mannerisms helpers.
assert(T.isZombieClip("Zombie_Walk") and not T.isZombieClip("Bob_Walk") and not T.isZombieClip(nil), "isZombieClip")
local best, share = T.dominant({ Zombie_Walk = 6, Bob_Walk = 2 })
assert(best == "Zombie_Walk" and share == 0.75, "dominant picks the most counted clip: " .. tostring(best) .. " " .. share)
assert(T.dominant({}) == nil, "an empty tally has no dominant clip")
for _, key in ipairs({ "idle", "walk", "sneakWalk", "run", "sneakRun", "sprint", "sit" }) do
    assert(T.isZombieClip(T.GAIT_CLIPS[key]), "a zombie clip for " .. key)
end

-- Cleanup removes tagged items and the IDs the test made, never the player's own gear.
local function item(id, fullType, tagged)
    local it = { id = id, t = fullType, md = tagged and { [T.MARKER] = true } or {} }
    function it:getID() return self.id end
    function it:getFullType() return self.t end
    function it:hasModData() for _ in pairs(self.md) do return true end return false end
    function it:getModData() return self.md end
    return it
end
local contents = { item(1, "Base.Katana", true), item(2, "Whisperers.FaceMask", false),
    item(3, "Whisperers.FaceMask", false), item(4, "Whisperers.Guts", false) }
local removed = {}
local bag = { getItems = function() return list(contents) end,
    Remove = function(_, it) removed[it.id] = true; for i, v in ipairs(contents) do if v == it then table.remove(contents, i) end end end }
local md = {}
local p3 = { getInventory = function() return bag end, isEquipped = function() return false end,
    getPrimaryHandItem = function() end, getSecondaryHandItem = function() end, getModData = function() return md end,
    getX = function() return 0 end, getY = function() return 0 end, getZ = function() return 0 end, getUsername = function() return "tester" end }
getCell = function() return { getGridSquare = function() return nil end } end
local result = World.cleanup(p3, { ids = { 3 } })
assert(removed[1] and removed[3], "tagged items and test-made IDs are removed")
assert(not removed[2] and not removed[4], "the player's own mask and guts are kept")
assert(result.items == 2, "two items removed: " .. tostring(result.items))

io.write("whisperers_suite_checks: all passed\n")
