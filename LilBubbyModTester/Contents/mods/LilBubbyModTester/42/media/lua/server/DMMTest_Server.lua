require "LilBubbyPacer"
require "DMMTest_Checks"
require "LilBubbyTeleport"

-- Multiplayer half of the Dead Man's Map suite. The server records where it
-- killed each requester, so verification and the teleport back to the corpse
-- never use client-supplied coordinates.
local MODULE = DMMTest.MODULE
local deaths = {}

local function reply(player, command, args)
    args.playerID = player:getOnlineID()
    sendServerCommand(player, MODULE, command, args)
end

local function kill(player)
    if player:isDead() then return end
    local Core = DeadMansMap.Core
    local username = player:getUsername()
    deaths[username] = {
        x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()),
        characterName = Core.getCharacterName(player),
        worldAge = DMMTest.worldAge(),
    }
    print("[" .. MODULE .. "] kill " .. username .. " at " .. deaths[username].x .. "," .. deaths[username].y)
    player:Kill(nil)
end

local function verify(player, death, label)
    local maps = DMMTest.findDeathMaps(death.x, death.y, death.z, death.characterName, death.worldAge)
    print("[" .. MODULE .. "] verify " .. player:getUsername() .. " " .. label .. " found=" .. #maps)
    reply(player, "verified", {label = label, maps = maps})
end

-- The destination is always the recorded death site, never client input.
local function teleport(player, death)
    local expected = LilBubbyTeleport.Order(player, death.x, death.y, death.z)
    reply(player, "teleportPending", {x = death.x, y = death.y, z = death.z, expected = expected})
end

local function handle(command, player, args)
    local username = player:getUsername()
    if command == "kill" then
        kill(player)
        return
    end
    -- Copy markings test: the stamp only names the test's own items.
    local stamp = type(args.stamp) == "string" and args.stamp:match("^%d+$") and args.stamp or nil
    if command == "copySetup" and stamp then
        local written, stashed = DMMTest.copySetup(player, stamp)
        reply(player, "copyReady", {stamp = stamp, written = written, stashed = stashed,
            error = not written and tostring(stashed) or nil})
        return
    elseif command == "copyGivePen" then
        DMMTest.copyGivePen(player)
        reply(player, "copyPen", {})
        return
    elseif command == "copyCleanup" and stamp then
        reply(player, "copyCleaned", {stamp = stamp, returned = DMMTest.copyCleanup(player, stamp)})
        return
    end
    local death = deaths[username]
    if not death then return end
    if command == "verify" and type(args.label) == "string" and #args.label <= 40 then
        verify(player, death, args.label)
    elseif command == "teleport" and not player:isDead() then
        teleport(player, death)
    end
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or not player or not DMMTest.available() then return end
    args = type(args) == "table" and args or {}
    -- Queued behind this player's previous request, never dropped.
    LilBubbyPacer.Run(player, MODULE, 100, function() handle(command, player, args) end)
end)
