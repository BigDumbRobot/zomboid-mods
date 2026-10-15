-- Offline checks for the Bonk Zone suite against a stand-in BonkZone guard.
-- Failure injection proves that missing blocks, wounds with unchanged overall
-- HP, and stale shields fail. Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local report = print
print = function() end -- the suite logs every hit
local function event()
    local e = { handlers = {} }
    function e.Add(fn) e.handlers[#e.handlers + 1] = fn end
    function e.fire(...) for _, fn in ipairs(e.handlers) do fn(...) end end
    return e
end
Events = { OnClientCommand = event(), OnWeaponHitCharacter = event(), OnTick = event(), OnServerCommand = event() }
local now, messages, moves, hits, behavior = 100000, {}, {}, 0, "normal"
function sendDamage() end
function isServer() return true end
function isClient() return false end
function getTimestampMs() return now end
function instanceof(o, class) return o and o.kind == class end
getActivatedMods = function() return { contains = function(_, id) return id == "BonkZone" end } end
require = function(name)
    if name == "LilBubbyTeleport" then dofile(root .. "shared/LilBubbyTeleport.lua") end
    if name == "LilBubbySites" then dofile(root .. "shared/LilBubbySites.lua") end
    if name == "LilBubbyPacer" then dofile(root .. "server/LilBubbyPacer.lua") end
end
local function list(values) return { size = function() return #values end, get = function(_, i) return values[i + 1] end } end

local p = { kind = "IsoPlayer", hp = 100, x = 10, god = false, avoid = false, wound = 0 }
function p:getUsername() return "OrdinaryPlayer" end
function p:getOnlineID() return 7 end
function p:getX() return self.x end
function p:getY() return 10 end
function p:getZ() return 0 end
function p:isDead() return false end
function p:getCurrentSquare() return {} end
function p:getVehicle() return nil end
function p:getRole() return { hasCapability = function() return false end } end
function p:isGodMod() return self.god end
function p:isHealthCheat() return false end
function p:isDoShove() return false end
function p:avoidDamage() return self.avoid end
function p:setAvoidDamage(v) self.avoid = v end
function p:getHealth() return self.hp end
function p:getBodyDamage()
    local part = { getHealth = function() return p.hp end, getBleedingTime = function() return p.wound end,
        getScratchTime = function() return 0 end, getCutTime = function() return 0 end,
        getDeepWoundTime = function() return 0 end, getFractureTime = function() return 0 end,
        haveBullet = function() return false end }
    return { getOverallBodyHealth = function() return p.hp end, getBodyParts = function() return list({ part }) end }
end
function instanceItem(name)
    return { kind = "HandWeapon", isRanged = function() return true end, getFullType = function() return name end }
end
function p:getPrimaryHandItem() return instanceItem("Mod.ExampleRifle") end
function getScriptManager() return { getAllItems = function() return list({
    { isRanged = function() return true end, getObsolete = function() return false end, getFullName = function() return "Base.Pistol" end },
    { isRanged = function() return true end, getObsolete = function() return false end, getFullName = function() return "Mod.ExampleRifle" end },
}) end } end
function p:Hit(weapon, attacker, damage)
    hits = hits + 1
    if behavior ~= "missing" then Events.OnWeaponHitCharacter.fire(attacker, self, weapon, damage) end
    if not self.avoid then self.hp = self.hp - damage end
    if behavior ~= "stale" then self.avoid = false end
    if behavior == "wound" then self.wound = self.wound + 1 end
end
local speedPolicy = "2" -- Kick: moves must hop
function getServerOptions()
    return { getBoolean = function() return true end, getOption = function(_, name) return name == "AntiCheatSpeed" and speedPolicy or nil end }
end
function sendServerCommand(player, module, command, args)
    if module == "BonkPvpTest" then messages[#messages + 1] = { player = player, command = command, args = args } end
    if module == "LilBubbyTeleport" then moves[#moves + 1] = { player = player, command = command, args = args } end
end
function getCell() return { getGridSquare = function() return {
    TreatAsSolidFloor = function() return true end, isFree = function() return true end } end } end
local online = { p }
function getOnlinePlayers() return list(online) end

-- Stand-in production guard: blocks every hit inside a zone with a one-shot shield.
local zone = { id = "test", name = "Test", x1 = 0, y1 = 0, x2 = 20, y2 = 20, z1 = 0, z2 = 0 }
BonkZone = {
    Registry = {
        Ready = true,
        GetZones = function() return { zone } end,
        GetById = function(id) return id == zone.id and zone or nil end,
        PointInZone = function(z, x, y) return x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 end,
        IsCharacterInside = function(c) return c:getX() >= zone.x1 and c:getX() <= zone.x2 end,
    },
    CombatGuard = { BlockedCount = 0 },
}
Events.OnWeaponHitCharacter.Add(function(attacker, target)
    if BonkZone.Registry.IsCharacterInside(target) then
        BonkZone.CombatGuard.BlockedCount = BonkZone.CombatGuard.BlockedCount + 1
        target:setAvoidDamage(true)
    end
end)
dofile(root .. "server/BonkPvpTest_Server.lua")

local function command(cmd, args)
    now = now + 1100
    Events.OnClientCommand.fire("BonkPvpTest", cmd, p, args or {})
end
local function ticks(count) for _ = 1, count do now = now + 101; Events.OnTick.fire() end end
local function last()
    for i = #messages, 1, -1 do if messages[i].command == "result" then return messages[i].args end end
end
local function shotsAnnounced()
    local n = 0
    for _, message in ipairs(messages) do if message.command == "shot" then n = n + 1 end end
    return n
end

command("teleport", { zoneID = "test", x = 999999, playerID = 99 })
local move = assert(moves[1], "teleport sent no move order")
assert(move.player == p and move.command == "move" and move.args.playerID == 7, "move order targets the requester only")
assert(move.args.x == 10 and move.args.y == 10 and move.args.z == 0, "teleport accepted an arbitrary destination")
assert(move.args.hop == LilBubbyTeleport.HOP, "speed anti-cheat on: the move must hop")
speedPolicy = "4"
command("teleport", { zoneID = "test" })
assert(moves[2].args.hop == nil, "speed anti-cheat disabled: the move is one jump")
command("run", { weapon = "pistol", mode = "single", playerID = 99 }); ticks(1)
assert(last().status == "PASS" and hits == 1 and p.hp == 100, "ordinary client single shot failed")
assert(shotsAnnounced() == hits, "every shot is announced to the client so it can be heard")
command("run", { weapon = "held", mode = "burst" }); ticks(30)
assert(last().status == "PASS" and hits == 31 and p.hp == 100, "30 shots were not all blocked")
assert(shotsAnnounced() == hits, "every shot of a burst is announced")
command("run", { weapon = "all", mode = "burst" }); ticks(60)
assert(last().status == "PASS" and hits == 91, "all ranged sweep omitted modded weapon")
p.god = true
command("run", { weapon = "pistol", mode = "single" }); ticks(1)
assert(last().status == "ABORTED" and hits == 91, "god mode invalidated test")
p.god = false; p.x = 30
command("run", { weapon = "pistol", mode = "single" }); ticks(1)
assert(last().status == "ABORTED" and hits == 91, "shot outside zone")
p.x = 10
command("run", { weapon = "held", mode = "burst" }); ticks(1)
command("cancel"); ticks(30)
assert(last().status == "CANCELLED" and hits == 92, "cancel fired additional hits")
command("run", { weapon = "held", mode = "burst" }); ticks(1); p.x = 30; ticks(1)
assert(last().status == "ABORTED" and hits == 93, "burst fired after zone exit")
p.x = 10
command("return")
assert(#moves == 3 and moves[3].args.x == 10, "return goes back to the position saved before the first teleport")
behavior = "missing"
command("run", { weapon = "pistol", mode = "burst" }); ticks(30)
assert(last().status == "FAIL" and hits == 94 and p.hp == 90, "missing guard did not fail fast")
p.hp = 100; behavior = "wound"
command("run", { weapon = "pistol", mode = "burst" }); ticks(30)
assert(last().status == "FAIL" and hits == 95 and p.hp == 100, "wound-only damage escaped detection")
p.wound = 0; behavior = "stale"
command("run", { weapon = "pistol", mode = "burst" }); ticks(30)
assert(last().status == "FAIL" and hits == 96, "unconsumed shield yielded false PASS")
p.avoid = false; behavior = "normal"
command("run", { weapon = "held", mode = "burst" }); online = {}; ticks(30)
assert(hits == 96, "disconnected session continued")
report("PASS: ordinary-client shots, 30-hit rearming, modded sweep, native teleport orders, cancellation, zone exit, disconnect, and injected failures")
