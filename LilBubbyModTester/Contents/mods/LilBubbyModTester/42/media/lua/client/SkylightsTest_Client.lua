require "LilBubbyShowcase"
require "ISUI/ISContextMenu"
require "LilBubbyTeleport"
require "SkylightsTest_World"

-- Skylight Test: the server builds a 5x5 wooden room with a door and stairs
-- near the player and deposits one skylight's materials in their inventory.
-- The test ends there: the server tells the player to go up the stairs and
-- build the skylight themselves. World changes are made by the server in
-- multiplayer (SkylightsTest_Server.lua).
local MODULE = SkylightsTest.MODULE
local N = SkylightsTest.ROOM
local DEPTH = SkylightsTest.DEPTH
local runner = nil
local replies = {}
local nextId = 0

local function show(playerNum, text)
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.ReportIndex(playerNum, "skylights", text)
end

local function progress(player, text)
    LilBubbyShowcase.Report(player, "skylights", text, true)
    print("[" .. MODULE .. "] " .. text)
end

local function waitFor(ms, fn, what)
    local deadline = getTimestampMs() + ms
    -- what: shown in the status banner while this wait lasts.
    local previous = LilBubbyStatus and LilBubbyStatus.notes[0]
    if what and LilBubbyStatus then LilBubbyStatus.Note(0, what) end
    local value
    while true do
        value = fn()
        if value or getTimestampMs() > deadline then break end
        coroutine.yield()
    end
    if what and LilBubbyStatus then LilBubbyStatus.notes[0] = previous end -- a wait inside another keeps the outer note
    return value or nil
end

-- What the slower world operations do, for the status banner. Quick reads
-- (site) are left out so they never hide the wait they are part of.
local OP_TEXT = { room = "building the test structure", materials = "putting the materials in your inventory",
    cleanup = "removing the test room" }

-- Runs a world operation where the world is authoritative.
local function op(player, name, args)
    args = args or {}
    if not isClient() then
        local ok, result = pcall(SkylightsTest.World[name], player, args)
        if not ok then return { error = tostring(result) } end
        return result or {}
    end
    nextId = nextId + 1
    args.id = nextId
    sendClientCommand(player, MODULE, name, args)
    local id = nextId
    local reply = waitFor(20000, function() return replies[id] end, OP_TEXT[name] and ("Waiting for the server: " .. OP_TEXT[name]))
    replies[id] = nil
    return reply or { error = "no reply from the server in 20 s" }
end

local function required(report, name, reply)
    return report:check(name, reply.error == nil, reply.error)
end

local function sq(x, y, z) return getCell():getGridSquare(x, y, z) end

-- Keeps detaching squares from a replaced test room for a few seconds, as the
-- removals arrive from the server over several frames (see clearStaleRooms).
local sweeps = {}
local function sweepRooms(x0, y0)
    if not x0 or not y0 then return end
    SkylightsTest.World.clearStaleRooms(x0, y0)
    sweeps[#sweeps + 1] = { x0 = x0, y0 = y0, untilMs = getTimestampMs() + 5000 }
end
Events.OnTick.Add(function()
    if #sweeps == 0 then return end
    local now = getTimestampMs()
    for i = #sweeps, 1, -1 do
        local sweep = sweeps[i]
        pcall(SkylightsTest.World.clearStaleRooms, sweep.x0, sweep.y0)
        if now > sweep.untilMs then table.remove(sweeps, i) end
    end
end)

-- Moves the player off a test structure before it is removed or replaced.
local function leaveSite(player, site)
    if not site or not site.x0 then return true end
    local px, py = math.floor(player:getX()), math.floor(player:getY())
    if px < site.x0 - 1 or px > site.x0 + N or py < site.y0 - 1 or py > site.y0 + DEPTH then return true end
    local x, y = site.x0 + N + 2, site.y0 - 2
    LilBubbyTeleport.Travel(player, { x = x, y = y, z = 0, hop = isClient() and LilBubbyTeleport.HOP or nil })
    return waitFor(LilBubbyTeleport.SETTLE_MS, function() return LilBubbyTeleport.Arrived(player, x, y, 0) end,
        "Stepping off the test room before it is removed") ~= nil
end

local function flow(player)
    local report = SkylightsTest.newReport("Skylight Test")
    runner.report = report
    report:info("Session", isClient() and "multiplayer" or "single-player")

    -- 1. Structure: room, roof, door and stairs.
    progress(player, "Skylight Test: building the test structure nearby")
    leaveSite(player, op(player, "site"))
    local site = op(player, "room")
    if not required(report, "Structure built (5x5 wooden room, roof, west door, south stairs)", site) then return report end
    if site.replaced then
        sweepRooms(site.oldX0, site.oldY0)
        report:info("Replaced", "your earlier test structure (" .. tostring(site.replaced) .. " objects removed)")
    end
    report:info("Structure", string.format("room x %d..%d, y %d..%d; door at %d,%d; stairs from %d,%d up to the roof",
        site.x0, site.x0 + N - 1, site.y0, site.y0 + N - 1, site.doorX, site.doorY, site.stairsX, site.stairsY + 2))

    -- 2. Materials. The server deposits them and has the last word: it tells
    -- the player what to do next, and the test ends here.
    progress(player, "Skylight Test: giving you the skylight materials")
    local given = op(player, "materials")
    if not required(report, "Materials deposited to your inventory (4 planks, 4 screws, screwdriver, wooden window)", given) then
        return report
    end
    report.headline = "PASS: " .. tostring(given.prompt)
    if HaloTextHelper then pcall(HaloTextHelper.addText, player, tostring(given.prompt)) end
    return report
end

local function cleanupFlow(player)
    local report = SkylightsTest.newReport("Skylights cleanup")
    runner.report = report
    -- Step off the room first: standing in a room as it is removed is what
    -- used to crash the game (see clearStaleRooms).
    local site = op(player, "site")
    if site.x0 then report:check("Moved off the test room before removing it", leaveSite(player, site)) end
    local reply = op(player, "cleanup")
    if required(report, "Cleanup ran", reply) then
        report:info("Removed", tostring(reply.removed) .. " test object(s)")
        if reply.note then report:info("Note", reply.note) end
        sweepRooms(reply.x0, reply.y0)
        local here = player:getCurrentSquare()
        local room = here and here:getRoom()
        report:check("No square you stand on points at the removed room", not room or room:getRoomDef() ~= nil)
    end
    return report
end

local function stepRunner()
    if not runner then return end
    local ok, result = coroutine.resume(runner.co)
    if not ok then
        runner.report = runner.report or SkylightsTest.newReport("Skylight Test")
        runner.report:error("Test error", tostring(result))
        result = runner.report
    end
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        if LilBubbyStatus then LilBubbyStatus.Note(playerNum, nil) end
        local text = result and result:text() or "Skylight Test ended without a report."
        -- A passing run leads with the server's instruction to the player.
        if result and result.headline and result.failed == 0 then text = result.headline .. "\n" .. text end
        show(playerNum, text)
    end
end

local function start(player, fn)
    if runner then
        show(player:getPlayerNum(), "A Skylight Test is already running.")
        return
    end
    if player:getVehicle() then
        show(player:getPlayerNum(), "BLOCKED: Exit your vehicle first.")
        return
    end
    runner = { co = coroutine.create(fn), playerNum = player:getPlayerNum() }
    local ok, result = coroutine.resume(runner.co, player)
    if not ok or coroutine.status(runner.co) == "dead" then
        local playerNum = runner.playerNum
        runner = nil
        show(playerNum, ok and result:text() or ("ERROR: " .. tostring(result)))
    end
end

LilBubbyShowcase.Register("skylights", function(index, context, objects, test)
    if test or not SkylightsTest.available() then return end
    local player = getSpecificPlayer(index)
    if not player or player:isDead() then return end
    -- Builds in the world and gives items.
    context:addOption("Skylight Test", player, function(p) start(p, flow) end)
    context:addOption("Clean up my test room", player, function(p) start(p, cleanupFlow) end)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or command ~= "reply" or type(args) ~= "table" or not args.id then return end
    replies[args.id] = args
end)

Events.OnTickEvenPaused.Add(stepRunner)
Events.OnFETick.Add(stepRunner)
