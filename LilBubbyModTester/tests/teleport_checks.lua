-- Offline checks for the native teleport helper. Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local ticks, commands = {}, {}
Events = {
    OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end },
    OnServerCommand = { Add = function(fn) commands[#commands + 1] = fn end },
}
local now = 0
function getTimestampMs() return now end
local server = false
function isServer() return server end
local cleared = 0
ISTimedActionQueue = { clear = function() cleared = cleared + 1 end }
HaloTextHelper = { addText = function(p, text) p.halo = text end }

local function player(id, x, y)
    local p = { id = id, x = x, y = y, z = 0, dead = false }
    function p:getOnlineID() return self.id end
    function p:getX() return self.x end
    function p:getY() return self.y end
    function p:getZ() return self.z end
    function p:isDead() return self.dead end
    function p:getCurrentSquare() return {} end
    function p:getRole() return { hasCapability = function() return self.admin == true end } end
    function p:teleportTo(nx, ny, nz) self.x, self.y, self.z = nx, ny, nz end
    return p
end
local me, splitScreen = player(7, 100.5, 100.5), player(8, 5.5, 5.5)
local locals = { [0] = me, [1] = splitScreen }
function getNumActivePlayers() return 2 end
function getSpecificPlayer(index) return locals[index] end
local policy = "2"
function getServerOptions() return { getOption = function(_, name) return name == "AntiCheatSpeed" and policy or nil end } end
local sent = {}
function sendServerCommand(p, module, command, args) sent[#sent + 1] = { p = p, module = module, command = command, args = args } end

dofile(root .. "shared/LilBubbyTeleport.lua")
local T = LilBubbyTeleport
assert(#ticks == 1 and #commands == 1, "client registers its travel handlers")

-- Server: speed anti-cheat on, so the order hops and allows for every hop.
server = true
local expected = T.Order(me, 400.7, 100.2, 0)
local order = sent[#sent]
assert(order.p == me and order.module == T.MODULE and order.command == "move", "order goes to the requester")
assert(order.args.x == 400 and order.args.y == 100 and order.args.hop == T.HOP, "integer destination, hopping")
assert(expected == math.ceil(300 / T.HOP) * T.HOP_MS + T.SETTLE_MS, "allowance covers every hop: " .. expected)
policy = "4"
assert(T.Order(me, 400, 100, 0) == T.SETTLE_MS and sent[#sent].args.hop == nil, "speed anti-cheat disabled: one jump")
policy = "2"; me.admin = true
Capability = { TeleportToCoordinates = "TeleportToCoordinates" }
T.Order(me, 400, 100, 0)
assert(sent[#sent].args.hop == nil, "a player allowed to teleport jumps at once")
me.admin = false
server = false

-- Client: follow the hopping order under the engine's 1 s speed sampler, at
-- every phase offset, and never exceed 20 tiles/s between samples.
local function travel(offset)
    me.x, me.y, me.z, me.halo = 100.5, 100.5, 0, nil
    now = 0
    for _, fn in ipairs(commands) do fn(T.MODULE, "move", { playerID = 7, x = 400, y = 100, z = 1, hop = T.HOP }) end
    local lastX, lastY, lastSample, fastest = me.x, me.y, -offset, 0
    for step = 1, 60000 / 20 do
        now = step * 20
        for _, fn in ipairs(ticks) do fn() end
        if now - lastSample >= 1000 then
            local speed = math.sqrt((me.x - lastX) ^ 2 + (me.y - lastY) ^ 2) / ((now - lastSample) / 1000)
            fastest = math.max(fastest, speed)
            lastX, lastY, lastSample = me.x, me.y, now
        end
        if not T.Travelling(me) then break end
    end
    return fastest
end
for offset = 0, 980, 20 do
    local fastest = travel(offset)
    assert(fastest <= 20, string.format("offset %d ms: %.1f tiles/s exceeds the limit", offset, fastest))
end
assert(me.x == 400.5 and me.y == 100.5 and me.z == 1 and me.halo == "Arrived", "arrives on the exact tile and floor")
assert(T.Arrived(me, 400, 100, 1), "arrival detection")
assert(splitScreen.x == 5.5, "another local player is never moved")
assert(cleared > 0, "queued actions are cleared before moving")

-- Single player: one immediate jump.
me.x, me.y = 10.5, 10.5
T.Order(me, 50, 60, 0)
assert(me.x == 50.5 and me.y == 60.5 and not T.Travelling(me), "single player jumps at once")

-- Dying mid-travel stops the travel.
for _, fn in ipairs(commands) do fn(T.MODULE, "move", { playerID = 7, x = 900, y = 60, z = 0, hop = T.HOP }) end
me.dead = true
now = now + 5000
for _, fn in ipairs(ticks) do fn() end
assert(not T.Travelling(me), "travel ends when the player dies")
print("PASS: native teleport orders, hop allowance, speed-limit safety at every sampler phase, exact arrival, split-screen isolation and single player")
