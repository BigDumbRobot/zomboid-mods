-- Load the production guard first only when the optional mod is enabled,
-- preserving hit-observer ordering without making it a tester dependency.
if getActivatedMods and getActivatedMods():contains("BonkZone") then
    require "BonkZone/BonkZone_Registry"
    require "BonkZone/Combat/BonkZone_CombatGuard"
end
require "LilBubbyTeleport"
require "LilBubbySites"
require "LilBubbyPacer"

-- DEV SERVER ONLY. Commands always act on their authenticated sender.
local MODULE = "BonkPvpTest"
local Registry, Guard
local function available()
    Registry = BonkZone and BonkZone.Registry
    Guard = BonkZone and BonkZone.CombatGuard
    return Registry and Guard and type(Registry.GetZones) == "function"
end
local sessions, origins = {}, {}
local observation
local function reply(p, text, status)
    print("[BonkPvpTest] " .. p:getUsername() .. " | " .. text)
    sendServerCommand(p, MODULE, "result", {text = text, status = status or "INFO", playerID = p:getOnlineID()})
end
local function valid(p)
    return p and not p:isDead() and p:getCurrentSquare() ~= nil
end
local function snapshot(p)
    local body, result = p:getBodyDamage(), {p:getBodyDamage():getOverallBodyHealth(), p:getHealth()}
    local parts = body:getBodyParts()
    for i = 0, parts:size() - 1 do
        local part = parts:get(i)
        for _, value in ipairs({part:getHealth(), part:getBleedingTime(), part:getScratchTime(),
            part:getCutTime(), part:getDeepWoundTime(), part:getFractureTime(), part:haveBullet()}) do
            result[#result + 1] = value
        end
    end
    return result
end
local function same(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end
local function preflight(p)
    if not available() then return "Enable BonkZone to use this suite. No shot was fired." end
    if not valid(p) then return "Wait until your living character has loaded." end
    if not getServerOptions():getBoolean("PVP") then return "Server PVP must be enabled." end
    if not Registry.Ready then return "Bonk Zones have not loaded yet." end
    if not Registry.IsCharacterInside(p) then return "Teleport to a Bonk Zone first. No shot was fired." end
    if p:getVehicle() then return "Exit your vehicle before testing." end
    if p:isGodMod() or p:isHealthCheat() then return "Turn off god mode and health cheats so they cannot mask damage." end
    if p:isDoShove() then return "Stop shoving before testing." end
    if p:avoidDamage() then return "A pre-existing damage shield would invalidate the test. Try again later." end
    return nil
end
-- Runs after the production guard, observes its flag without setting it ourselves.
Events.OnWeaponHitCharacter.Add(function(attacker, target, weapon)
    if observation and target == observation.player and attacker == target and weapon == observation.weapon then
        observation.events = observation.events + 1
        observation.shielded = target:avoidDamage()
    end
end)
local function finish(p, session, status, reason)
    sessions[p] = nil
    reply(p, string.format("%s | %s | hits=%d/%d blocked=%d | %s", status,
        session.label, session.done, session.total, session.blocked, reason), status)
end
local function weaponName(weapon)
    local ok, name = pcall(function() return weapon:getName() end)
    if ok and name and name ~= "" then return tostring(name) end
    return tostring(weapon:getFullType())
end

-- Tells the shooter's client to play the weapon's own gunshot where they
-- stand, so every server hit is heard as well as reported.
local function announceShot(p, session, weapon, blocked, passed)
    local sound
    pcall(function() sound = weapon:getSwingSound() end)
    sendServerCommand(p, MODULE, "shot", { playerID = p:getOnlineID(), sound = sound,
        weapon = weapon:getFullType(), name = weaponName(weapon), shot = session.done,
        total = session.total, blocked = blocked, passed = passed })
end

local function shot(p, session)
    local errorMessage = preflight(p)
    if errorMessage then finish(p, session, "ABORTED", errorMessage); return end
    local weapon = session.weapons[math.floor(session.done / session.repeats) + 1]
    local before, blocks = snapshot(p), Guard.BlockedCount
    observation = {player = p, weapon = weapon, events = 0, shielded = false}
    -- The real engine entry point. No synthetic success event, zero damage, god mode,
    -- manual AvoidDamage flag, healing, or changes to Bonk Zone definitions.
    local ok, err = pcall(function() p:Hit(weapon, p, 10, false, 1, false) end)
    local observed = observation
    observation = nil
    session.done = session.done + 1
    local blocked = Guard.BlockedCount - blocks
    session.blocked = session.blocked + blocked
    local after = snapshot(p)
    local passed = ok and observed.events == 1 and observed.shielded and blocked == 1
        and not p:avoidDamage() and same(before, after)
    announceShot(p, session, weapon, blocked, passed)
    print(string.format("[BonkPvpTest] player=%s weapon=%s hit=%d/%d blocked=%d hp=%.4f->%.4f %s",
        p:getUsername(), weapon:getFullType(), session.done, session.total, blocked, before[1], after[1], passed and "PASS" or "FAIL"))
    if not passed then
        if not same(before, after) then sendDamage(p) end
        finish(p, session, "FAIL", string.format("%s; HP %.4f -> %.4f; wounds unchanged=%s; event=%d; shield=%s; %s. Stopped immediately.",
            weapon:getFullType(), before[1], after[1], tostring(same(before, after)), observed.events,
            tostring(observed.shielded), ok and "guard must block EVERY hit" or tostring(err)))
    elseif session.done == session.total then
        finish(p, session, "PASS", "Every hit blocked; health and wounds unchanged after every hit.")
    elseif session.done % session.repeats == 0 then
        reply(p, string.format("%s: %d hit(s) fired, all blocked. Progress %d/%d.",
            weaponName(weapon), session.repeats, session.done, session.total))
    end
end
local function makeWeapon(fullType)
    local weapon = instanceItem(fullType)
    if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then
        error("Not an available ranged HandWeapon: " .. tostring(fullType))
    end
    return weapon
end
local function weaponList(p, kind)
    if kind == "held" then
        local weapon = p:getPrimaryHandItem()
        if not weapon or not instanceof(weapon, "HandWeapon") or not weapon:isRanged() then
            error("Hold a ranged weapon to test it.")
        end
        return {weapon}
    end
    local presets = {pistol = "Base.Pistol", shotgun = "Base.Shotgun", rifle = "Base.AssaultRifle"}
    if presets[kind] then return {makeWeapon(presets[kind])} end
    if kind ~= "all" then error("Unknown weapon selection") end
    local items, names = getScriptManager():getAllItems(), {}
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:isRanged() and not item:getObsolete() then names[#names + 1] = item:getFullName() end
    end
    table.sort(names)
    if #names == 0 then error("No loaded ranged weapons found") end
    local weapons = {}
    for _, name in ipairs(names) do weapons[#weapons + 1] = makeWeapon(name) end
    return weapons
end
local function start(p, args)
    if sessions[p] then reply(p, "A test is already running. Cancel it first."); return end
    local err = preflight(p)
    if err then reply(p, err, "ABORTED"); return end
    local repeats = args.mode == "burst" and 30 or args.mode == "single" and 1 or nil
    if not repeats then reply(p, "Unknown test mode.", "ABORTED"); return end
    local ok, weapons = pcall(weaponList, p, args.weapon)
    if not ok then reply(p, tostring(weapons), "ABORTED"); return end
    local session = {weapons = weapons, repeats = repeats, total = #weapons * repeats,
        done = 0, blocked = 0, nextShot = getTimestampMs(), label = tostring(args.weapon) .. " " .. args.mode}
    sessions[p] = session
    local names = {}
    for _, weapon in ipairs(weapons) do names[#names + 1] = weaponName(weapon) end
    reply(p, "START | " .. session.label .. " | " .. session.total .. " real server hits from "
        .. #weapons .. " weapon(s): " .. table.concat(names, ", ")
        .. ". You will hear every shot. Remain inside the zone; cancel from the menu.")
end
local function nativeTeleport(p, x, y, z)
    local expected = LilBubbyTeleport.Order(p, x, y, z)
    return math.ceil(expected / 1000)
end
local function teleport(p, args)
    if not valid(p) or p:getVehicle() then reply(p, "Load your character and exit any vehicle first."); return end
    if sessions[p] then reply(p, "Cancel your running test before teleporting."); return end
    local zone = args.zoneID and Registry.GetById(args.zoneID) or Registry.GetZones()[1]
    if not zone then reply(p, "No such Bonk Zone exists. " .. LilBubbySites.Missing("bonk")); return end
    local x, y = math.floor((zone.x1 + zone.x2) / 2), math.floor((zone.y1 + zone.y2) / 2)
    local z = math.max(zone.z1, math.min(zone.z2, 0))
    -- Prefer a known clear standing square if destination chunks are loaded.
    local found
    for radius = 0, 12 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local square = getCell():getGridSquare(x+dx, y+dy, z)
                    if Registry.PointInZone(zone, x+dx, y+dy, z) and square
                        and square:TreatAsSolidFloor() and square:isFree(false) then
                        found = {x=x+dx, y=y+dy}; break
                    end
                end
            end
            if found then break end
        end
        if found then break end
    end
    if found then x, y = found.x, found.y end
    if not origins[p] then origins[p] = {x = p:getX(), y = p:getY(), z = math.floor(p:getZ())} end
    local seconds = nativeTeleport(p, x, y, z)
    reply(p, "Moving you to " .. zone.name .. " (up to " .. seconds .. " s). Wait for \"Arrived\", then choose a shot test.")
end
-- The designated test zone, so the suite runs on a server with no zones yet.
-- An admin lays it out with the other test sites (LilBubbySites); players are
-- moved into it and never create a zone.
local TEST_ZONE = "lilBubby test zone"
local function syncZones()
    BonkZone.Storage.RefreshSharedRegistry()
    if BonkZone.Server and BonkZone.Server.BroadcastSync then BonkZone.Server.BroadcastSync() end
end
LilBubbySites.Provide("bonk", {
    label = "Bonk Zone",
    available = function() return available() and BonkZone.Storage ~= nil and BonkZone.Storage.AddZone ~= nil end,
    layout = function(origin)
        local x, y = origin.x + 68, origin.y
        return { x1 = x - 10, y1 = y - 10, x2 = x + 10, y2 = y + 10, z = origin.z }, { x = x, y = y, z = origin.z }
    end,
    create = function(admin, rect)
        local zone, err = BonkZone.Storage.AddZone(TEST_ZONE, rect.x1, rect.y1, rect.x2, rect.y2, "LilBubbyModTester:" .. admin:getUsername())
        if not zone then return nil, err end
        syncZones()
        return zone.id
    end,
    remove = function(_, id)
        local numeric = tonumber(id) or id
        local _ = BonkZone.Storage.RemoveZone(numeric, "LilBubbyModTester") or BonkZone.Storage.RemoveZone(tostring(id), "LilBubbyModTester")
        syncZones()
    end,
    exists = function(id) return Registry.GetById(id) ~= nil end,
})
local function testZone(p)
    local site = LilBubbySites.Get("bonk")
    if not site then reply(p, LilBubbySites.Missing("bonk"), "BLOCKED"); return end
    if Registry.IsCharacterInside(p) then reply(p, "You are already inside a Bonk Zone."); return end
    teleport(p, { zoneID = site.id })
end

Events.OnClientCommand.Add(function(module, command, p, args)
    if module ~= MODULE or not p then return end
    if not available() then
        reply(p, "BLOCKED: Enable BonkZone to use this suite.", "BLOCKED")
        return
    end
    args = type(args) == "table" and args or {}
    if command == "cancel" then
        if sessions[p] then finish(p, sessions[p], "CANCELLED", "No further shots will be fired.") end
        return
    end
    -- Queued behind this player's previous request, never dropped.
    LilBubbyPacer.Run(p, MODULE, 100, function()
        if command == "run" then start(p, args)
        elseif command == "testzone" then testZone(p)
        elseif command == "teleport" then teleport(p, args)
        elseif command == "return" then
            if sessions[p] then reply(p, "Cancel the test before returning."); return end
            local origin = origins[p]
            if not origin then reply(p, "No saved return position for this connection."); return end
            local seconds = nativeTeleport(p, origin.x, origin.y, origin.z)
            origins[p] = nil
            reply(p, "Returning you to where you started (up to " .. seconds .. " s).")
        end
    end)
end)
local lastCleanup = 0
Events.OnTick.Add(function()
    -- Bonk Zone tests are multiplayer-only; getOnlinePlayers() is nil in single player.
    if not isServer() then return end
    local now = getTimestampMs()
    if now - lastCleanup > 2000 then
        lastCleanup = now
        local online, connected = getOnlinePlayers(), {}
        for i = 0, online:size() - 1 do connected[online:get(i)] = true end
        for _, store in ipairs({sessions, origins}) do
            for p in pairs(store) do if not connected[p] then store[p] = nil end end
        end
    end
    local connected, running = {}, false
    for _ in pairs(sessions) do running = true; break end -- Kahlua has no next()
    if running then
        local online = getOnlinePlayers()
        for i = 0, online:size() - 1 do connected[online:get(i)] = true end
    end
    for p, session in pairs(sessions) do
        if not connected[p] then
            sessions[p] = nil
        elseif now >= session.nextShot then
            session.nextShot = now + 100
            local ok, err = pcall(shot, p, session)
            if not ok then observation = nil; finish(p, session, "ERROR", tostring(err)) end
        end
    end
end)
print("[BonkPvpTest] Interactive server harness loaded; all connected players may test themselves")
