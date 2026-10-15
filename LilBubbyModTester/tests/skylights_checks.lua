-- Skylights suite helpers and server command guards; no game engine required.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
require = function() end
local handlers = {}
Events = setmetatable({}, { __index = function(t, key)
    local event = { Add = function(fn) handlers[key] = handlers[key] or {}; table.insert(handlers[key], fn) end }
    t[key] = event
    return event
end })
print = function() end
dofile(root .. "shared/SkylightsTest_Checks.lua")
dofile(root .. "shared/SkylightsTest_World.lua")
local T = SkylightsTest

-- Availability follows the Skylights globals at call time.
assert(not T.available(), "unavailable without Skylights")
SkylightsConfig = { indoorBrightness = function() return 80 end, HOLE_KEY = "SkylightsHole", MARKER_KEY = "SkylightsProbe" }
SkylightsDaylight = { skylightOn = function() return nil end }
SkylightsGlass = {}
assert(T.available(), "available once Skylights is loaded")

-- Report verdicts.
local report = T.newReport("Skylights full test")
report:check("a", true); report:info("b", "x")
assert(report:text():find("^Skylights full test: PASS %(1 passed, 0 failed%)"))
report:check("c", false, "why"); report:error("d", "boom")
local text = report:text()
assert(text:find("FAIL %(1 passed, 2 failed%)") and text:find("FAIL | c | why", 1, true) and text:find("ERROR | d | boom", 1, true))

-- Server command guards.
SandboxVars = {}
isServer = function() return true end
getTimestampMs = (function() local now = 0; return function() now = now + 1000; return now end end)()
local sent = {}
sendServerCommand = function(player, module, command, args) sent[#sent + 1] = args end
isClient = function() return false end
SandboxVars = {}
dofile(root .. "server/LilBubbyPacer.lua")
dofile(root .. "server/SkylightsTest_Server.lua")
local handler = handlers.OnClientCommand[1]
local player = { getUsername = function() return "Tester" end, getAccessLevel = function() return "admin" end }
local visitor = { getUsername = function() return "Visitor" end, getAccessLevel = function() return "None" end }

getTimestampMs = function() return 10000 end
handler(T.MODULE, "site", visitor, { id = 110 })
assert(sent[#sent].status == nil and sent[#sent].error == nil, "reading your own test site is player-level")
getTimestampMs = function() return 11000 end
handler(T.MODULE, "cleanup", visitor, { id = 111 })
assert(sent[#sent].status == nil and sent[#sent].note, "cleaning up your own room is player-level")
getTimestampMs = (function() local now = 20000; return function() now = now + 1000; return now end end)()
for i = #sent, 1, -1 do sent[i] = nil end

handler("SomeOtherModule", "sandbox", player, { id = 1 })
assert(#sent == 0, "other modules ignored")
handler(T.MODULE, "explode", player, { id = 1 })
assert(#sent == 0, "unknown commands ignored")

for _, command in ipairs({ "sandbox", "time", "zombie", "state", "teleport", "roof" }) do
    handler(T.MODULE, command, player, { id = 2, x = 1, y = 2, z = 1 })
    assert(#sent == 0, command .. " is no longer a Skylights command")
end

-- The server deposits the materials and tells the player what to do next.
local added = {}
local inventory = { containsTypeRecurse = function() return false end,
    AddItem = function(_, fullType) added[#added + 1] = fullType; return {} end }
sendAddItemToContainer = function() end
player.getInventory = function() return inventory end
local clock = 500000 -- later than every earlier request
getTimestampMs = function() return clock end
handler(T.MODULE, "materials", player, { id = 7 })
assert(sent[#sent].id == 7 and sent[#sent].error == nil and sent[#sent].count == 10 and #added == 10,
    "window, screwdriver, 4 screws and 4 planks deposited")
assert(sent[#sent].prompt == "Items deposited to your inventory. Go up the stairs to the roof to build your skylight.")
-- A request right behind another is queued, never refused: the test keeps going.
handler(T.MODULE, "materials", player, { id = 8 })
assert(sent[#sent].id == 7, "the second request waits its turn")
clock = clock + 100
for _, tick in ipairs(handlers.OnTick or {}) do tick() end
assert(sent[#sent].id == 8 and sent[#sent].error == nil and #added == 20, "the queued request runs and is answered")

SkylightsGlass = nil
getTimestampMs = function() return 99999 end
handler(T.MODULE, "cleanup", player, { id = 9 })
assert(sent[#sent].error == "Skylights is not enabled on this server.", "refuses without Skylights")


-- Removing the room must not leave squares pointing at a room without a
-- RoomDef: vanilla firearm audio reads it every frame and crashes the game.
local squares = {}
local liveRoom = { getRoomDef = function() return {} end }
local deadRoom = { getRoomDef = function() return nil end }
local function square(room)
    local s = { roomId = room and 1 or -1, room = room }
    function s:getRoom() return self.roomId ~= -1 and self.room or nil end
    function s:setRoomID(id) self.roomId = id; if id == -1 then self.room = nil end end
    return s
end
squares["10,10,0"] = square(deadRoom)
squares["11,10,1"] = square(deadRoom)
squares["12,12,0"] = square(liveRoom)
squares["13,13,0"] = square(nil)
getCell = function() return { getGridSquare = function(_, x, y, z) return squares[x .. "," .. y .. "," .. z] end } end
assert(T.World.clearStaleRooms(10, 10) == 2, "both squares of the removed room are detached")
assert(squares["10,10,0"]:getRoom() == nil and squares["11,10,1"]:getRoom() == nil, "stale rooms cleared on both floors")
assert(squares["12,12,0"]:getRoom() == liveRoom, "a real room is left alone")
io.write("PASS: Skylights suite availability, report verdicts, admin-only gating, materials and the player prompt, queued requests, server command guards and stale-room clearing after cleanup\n")
