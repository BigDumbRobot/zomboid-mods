require "LilBubbyShowcase"
require "LilBubbyTeleport"
require "ISUI/ISContextMenu"
require "PostalTest_Checks"
require "PostalTest_Guided"
require "SVSBTTrapTestUI"

-- Postal suite:
--   Guided post office test  five steps, each ended by the player's OK and
--                            checked by the server before the next begins:
--                            1. moved into a nearby building made a Post
--                               Office zone, with a computer, a generator,
--                               money and a Blank Key; an overview to read
--                            2. place a PO Box of every size from the
--                               right-click menu (the server places them;
--                               the player is not made an admin)
--                            3. how Postal Services and the box key work
--                            4. switch the computer on and rent a box
--                            5. collect a delivery in Postal Services
--   Check invalid requests   requests the services must refuse
--   Clean up                 removes what the guided test placed and gave
-- Cancel at any step cleans up and returns to the showcase.

local MODULE = "LilBubbyPostalTest"
local results = {}
local function show(player, text)
    text = tostring(text or "No result")
    results[player:getPlayerNum()] = text
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.Report(player, "postal", text)
end

local function run(player, suite)
    if isClient() then
        sendClientCommand(player, MODULE, "run", { suite = suite })
    else
        local ok, text = pcall(PostalTest.Run, player, suite)
        show(player, ok and text or ("ERROR: " .. tostring(text)))
    end
end

------------------------------------------------------------
-- Guided post office test
------------------------------------------------------------

local G = PostalTest.Guided
local GUIDED = "Guided post office test"
local REPLY_MS = 30000
local POLL_MS = 1000 -- how often the server is asked whether the player has arrived
local MOVES = 3      -- times the move into the building is ordered before giving up

local active -- the guided test on screen: { playerNum, window, phase, log }
local pending, nextId = {}, 0

local function progress(player, text)
    print("[" .. MODULE .. "] " .. text)
    LilBubbyShowcase.Report(player, "postal", text, true)
end

-- Runs a server operation (directly in single player); done(reply).
local function op(player, name, args, done)
    args = args or {}
    if not isClient() then
        local ok, result = pcall(G.OPS[name], player, args)
        done(ok and (result or {}) or { error = tostring(result) })
        return
    end
    nextId = nextId + 1
    args.id = nextId
    pending[nextId] = { done = done, deadline = getTimestampMs() + REPLY_MS, name = name }
    sendClientCommand(player, MODULE, name, args)
end

local function closeWindow()
    if not active or not active.window then return end
    SVSBTTrapTestUI.Close(active.window)
    active.window = nil
end

-- Ends the test on screen: the result goes to the showcase, which reopens.
local function finish(player, text)
    closeWindow()
    active = nil
    show(player, text)
    LilBubbyShowcase.Open(player)
end

local function cleanupText(reply, cancelled)
    if reply.error then return "ERROR: Post office cleanup failed: " .. reply.error end
    local parts = {}
    local function part(count, text)
        if (count or 0) > 0 then parts[#parts + 1] = count .. " " .. text end
    end
    part(reply.claims, "box rental(s) released")
    part(reply.keys, "box key(s) removed")
    part(reply.boxes, "PO Box(es) removed")
    part(reply.parcels, "waiting test parcel(s) removed")
    part(reply.items, "given item(s) removed")
    if (reply.objects or 0) > 0 then parts[#parts + 1] = "the computer and generator removed" end
    part(reply.zones, "test zone(s) closed")
    local removed = #parts > 0 and table.concat(parts, ", ") or "nothing was left to remove"
    if reply.kept and #reply.kept > 0 then
        return "BLOCKED: Post office cleanup is not finished: could not remove PO Box " .. table.concat(reply.kept, "; ")
            .. ". The zone stays open; stand in the post office and clean up again.\nRemoved so far: " .. removed .. "."
    end
    return (cancelled and "INFO: " .. GUIDED .. " cancelled and cleaned up: " or "PASS: Cleaned up: ") .. removed
        .. ". Money spent on a rental is not given back."
end

-- Cancel at any step: back to the showcase straight away; the cleanup
-- result follows when the server has done it.
local function cancel(player)
    closeWindow()
    active = nil
    LilBubbyShowcase.Open(player)
    progress(player, GUIDED .. " cancelled: removing what it placed and gave")
    op(player, "cleanup", {}, function(reply) show(player, cleanupText(reply, true)) end)
end

-- A step passed: its line and the server's checks go into the final report.
local function passed(player, phase, text, checks)
    active.log[#active.log + 1] = "PASS: Step " .. phase .. ": " .. text
    for _, line in ipairs(checks or {}) do active.log[#active.log + 1] = line end
    progress(player, "Step " .. phase .. " passed: " .. text)
end

-- Shows a step. OK asks the server to check it: a pass runs onPass(reply), a
-- denial says what is missing and leaves the step up for another try.
local function step(player, phase, spec, onPass)
    closeWindow()
    spec.left = true
    local mine, window = active, nil
    local function check()
        if mine.checking then return end
        mine.checking = true
        window:change({ status = { text = "The server is checking this step.", ready = false }, problem = false })
        op(player, "advance", { phase = phase }, function(reply)
            mine.checking = false
            if active ~= mine or mine.window ~= window then return end
            if reply.error then finish(player, "ERROR: " .. GUIDED .. ": " .. reply.error); return end
            if reply.stale then window:change({ status = false }); return end
            if not reply.ok then
                local missing = table.concat(reply.missing or {}, " ")
                window:change({ status = false, problem = "Not yet. " .. missing })
                progress(player, "Step " .. phase .. " denied: " .. missing)
                return
            end
            onPass(reply)
        end)
    end
    window = SVSBTTrapTestUI.ShowMessage(spec, check, function() cancel(player) end)
    mine.window, mine.phase = window, phase
end

local function at(spot) return spot and (spot.x .. "," .. spot.y) or "nearby" end

local function sizeText(sizes)
    local parts = {}
    for _, size in ipairs(sizes or {}) do
        parts[#parts + 1] = tostring(size.label) .. " holds " .. tostring(size.capacity) .. " and costs $" .. tostring(size.price)
    end
    return table.concat(parts, "; ")
end

-- The last step passed: every step and every server check, under one verdict.
local function done(player, reply)
    passed(player, 5, "the parcel's " .. tostring(reply.papers) .. " sheets of paper were collected", reply.checks)
    local failed = 0
    for _, line in ipairs(active.log) do
        if line:find("^FAIL") or line:find("^ERROR") then failed = failed + 1 end
    end
    local lines = { failed == 0
        and "PASS: " .. GUIDED .. ": you set up a post office, rented " .. tostring(active.box) .. " and collected a delivery."
        or "FAIL: " .. GUIDED .. ": every step was completed, but " .. failed .. " server check(s) failed." }
    for _, line in ipairs(active.log) do lines[#lines + 1] = line end
    lines[#lines + 1] = "The post office, your box and its key stay in place. Clean up the post office test removes them and the paper."
    finish(player, table.concat(lines, "\n"))
end

-- Step 5: the player collects a delivery.
local function collect(player, setup, reply)
    active.box = reply.box
    passed(player, 4, "you rented " .. tostring(reply.box) .. " and carry its key; you have $" .. tostring(reply.cash) .. " left", reply.checks)
    step(player, 5, { headline = { "Collect a delivery.", "Click OK when the paper is in your inventory." }, details = {
        "A parcel of 2 sheets of paper has just been sent to you, the way a Marketplace order or a server award is. It waits at the post office, not in your box or your inventory.",
        "1. On the computer at " .. at(setup.computer) .. ", open Postal Services. It lists 1 parcel waiting.",
        "2. Click COLLECT PARCELS. The paper goes into your inventory.",
        "Collecting only works inside a post office, for a player carrying a key to a box they own. Without the key, or outside the zone, it is refused and the parcel keeps waiting.",
        "When you click OK the server also tries to collect the same parcel again and to send the same order again; both must give you nothing.",
    } }, function(result) done(player, result) end)
end

-- Step 4: the player rents a box.
local function rent(player, setup, reply)
    passed(player, 3, "the computer, " .. tostring(reply.available) .. " free box(es), a Blank Key and $" .. tostring(reply.cash) .. " are ready")
    step(player, 4, { headline = { "Rent a PO Box.", "Click OK when you carry its key." }, details = {
        "1. Right-click the computer at " .. at(setup.computer) .. " and choose Power On Computer. Wait for it to start.",
        "2. Right-click it again and choose Access KIP Network (sign in if it asks), then open Postal Services.",
        "3. Click a row marked AVAILABLE, then BUY NOW, and confirm. You carry $" .. tostring(reply.cash)
            .. "; the cheapest free box costs $" .. tostring(reply.cheapest) .. ".",
        "The key you receive is your ownership of the box. Keep it on you: without it you cannot open the box or collect a delivery.",
        "How delivery works: a Marketplace order is held for you at the post office. Come to a post office carrying your key, open Postal Services and click COLLECT PARCELS; the items go into your inventory. You do that in the next step.",
    } }, function(result) collect(player, setup, result) end)
end

-- Step 3: how the computer and the key work.
local function teach(player, setup, reply)
    passed(player, 2, table.concat(reply.boxes or {}, ", ") .. " stand in the post office", reply.checks)
    step(player, 3, { headline = { "Renting a box on the computer.", "Read this, then click OK." }, details = {
        "PO Boxes are rented on a KIP Network computer: right-click one, Power On Computer, then Access KIP Network once it has started.",
        "Postal Services is only on the menu of a computer standing in a Post Office zone. Any other computer does not offer the page.",
        "To rent, pick a box marked AVAILABLE and buy it. The price and one " .. tostring(setup.blankName) .. " are taken from your inventory.",
        "You get that box's key, and the key is the rental: it opens the box and you must carry it to collect deliveries. Dropping, storing or handing it over is safe, and Postal Services copies it for a fee. If a key is destroyed, the box is released and its lock is changed.",
        "Next you rent a box yourself.",
    } }, function(result) rent(player, setup, result) end)
end

-- Step 2: the player says where each box goes; the server places it.
local function place(player, setup, reply)
    passed(player, 1, "the Post Office zone, computer, generator, money and Blank Key are in place")
    step(player, 2, { headline = { "Place a PO Box of every size.", "Click OK when all three stand." }, details = {
        "In the game this is admin-only: on a server only an admin can mark a Post Office zone (KIPN: Zone Admin Tool) and spawn its PO Boxes (KIPN: Spawn PO Box). Players cannot.",
        "You are not made an admin for this test. The tester places each box for you, through the same Post Office command an admin's menu uses.",
        "To place one: stand in the zone, right-click the floor where the box should stand and choose Post office test: place a Small, Medium or Large PO Box here. One box per tile, within 10 tiles of you.",
        "Place at least one of each size, anywhere in the building or up to " .. tostring(setup.margin) .. " tiles around it.",
        sizeText(reply.sizes) .. ".",
    } }, function(result) teach(player, setup, result) end)
end

-- The right-click entries of step 2. The answer shows in the step's window.
local function requestBox(player, square, size)
    local mine = active
    if not mine or mine.phase ~= 2 or not mine.window then return end
    local window = mine.window
    op(player, "place", { x = square:getX(), y = square:getY(), size = size }, function(reply)
        if active ~= mine or mine.window ~= window then return end
        if reply.ok then
            window:change({ status = { text = "Placed " .. tostring(reply.box) .. ".", ready = true }, problem = false })
        else
            window:change({ status = false, problem = "No box placed. " .. tostring(reply.error or reply.reason) })
        end
    end)
end

Events.OnFillWorldObjectContextMenu.Add(function(index, context, objects, test)
    if test or not active or active.phase ~= 2 or active.playerNum ~= index then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local square
    for _, object in ipairs(objects or {}) do
        square = square or (object and object.getSquare and object:getSquare())
    end
    square = square or player:getSquare()
    if not square then return end
    for _, size in ipairs(G.SIZES) do
        local label = size:sub(1, 1):upper() .. size:sub(2)
        context:addOption("Post office test: place a " .. label .. " PO Box here", player, requestBox, square, size)
    end
end)

-- Step 1: what was set up and what a post office does.
local function overview(player, setup)
    step(player, 1, { headline = { "This building is now a post office.", "Read this, then click OK." }, details = {
        "You were moved into a nearby building. It is a Post Office zone now, reaching " .. tostring(setup.margin) .. " tiles past its walls.",
        "Placed for you: a desktop computer inside at " .. at(setup.computer) .. ", switched off, and a running generator with a full tank outside at "
            .. at(setup.generator) .. " (outside, because generator fumes poison a building).",
        "In your inventory: " .. tostring(G.BUNDLES) .. " money bundles ($100 each) and a " .. tostring(setup.blankName)
            .. ". You carry $" .. tostring(setup.cash) .. ".",
        "What a post office is for:",
        "- Players rent a PO Box here, on the Postal Services page of a KIP Network computer.",
        "- A rented box comes with a real key that fits only that box.",
        "- Marketplace orders are held at the post office and collected there by an owner carrying their key.",
        "- Admins set it up: they mark the Post Office zone and place the PO Boxes. The boxes are next.",
    } }, function(result) place(player, setup, result) end)
end

-- Waits for the player to stand in the building, then has the server set
-- the post office up. A player who does not arrive is moved again.
local function arrive(player, reply)
    local mine = active
    mine.deadline = getTimestampMs() + (tonumber(reply.expected) or LilBubbyTeleport.SETTLE_MS) + 5000
    progress(player, GUIDED .. ": moving you into the building at " .. tostring(reply.x) .. "," .. tostring(reply.y))
    mine.tick = function(me)
        if mine.asking or LilBubbyTeleport.Travelling(me) then return end
        mine.asking = true
        op(me, "setup", {}, function(setup)
            mine.asking = false
            if active ~= mine then return end
            if setup.error then finish(me, "ERROR: " .. GUIDED .. ": " .. setup.error); return end
            if not setup.waiting then
                mine.tick = nil
                overview(me, setup)
                return
            end
            if getTimestampMs() < mine.deadline then return end
            mine.moves = (mine.moves or 1) + 1
            if mine.moves > MOVES then
                finish(me, "BLOCKED: " .. GUIDED .. ": you did not reach the building after " .. MOVES .. " moves. Start the test again.")
                return
            end
            mine.tick = nil
            op(me, "move", {}, function(again)
                if active ~= mine then return end
                if again.error then finish(me, "ERROR: " .. GUIDED .. ": " .. again.error); return end
                arrive(me, again)
            end)
        end)
    end
end

local function startGuided(player)
    if LilBubbyAutoRun and LilBubbyAutoRun.Running and LilBubbyAutoRun.Running() then
        show(player, "SKIP: " .. GUIDED .. " waits for you at every step; start it from the Postal Service list.")
        return
    end
    closeWindow() -- a new test replaces one still on screen
    active = { playerNum = player:getPlayerNum(), log = {} }
    local mine = active
    progress(player, GUIDED .. ": looking for a nearby building")
    op(player, "begin", {}, function(reply)
        if active ~= mine then return end
        if reply.error then finish(player, (reply.status or "ERROR") .. ": " .. GUIDED .. ": " .. reply.error); return end
        arrive(player, reply)
    end)
end

local function cleanupGuided(player)
    closeWindow()
    active = nil
    progress(player, "Removing everything the post office test placed and gave")
    op(player, "cleanup", {}, function(reply) show(player, cleanupText(reply, false)) end)
end

Events.OnTick.Add(function()
    local now
    for id, request in pairs(pending) do
        now = now or getTimestampMs()
        if now > request.deadline then
            pending[id] = nil
            pcall(request.done, { error = "no reply from the server (" .. request.name .. ") in " .. (REPLY_MS / 1000) .. " s" })
        end
    end
    if not active or not active.tick then return end
    now = now or getTimestampMs()
    if now < (active.nextTick or 0) then return end
    active.nextTick = now + POLL_MS
    local player = getSpecificPlayer(active.playerNum)
    if not player then return end
    local ok, err = pcall(active.tick, player)
    if not ok then print("[" .. MODULE .. "] " .. tostring(err)) end
end)

local function submenu(context, label)
    local option = context:getOptionFromName(label)
    if option and option.subOption then return context:getSubMenu(option.subOption) end
    option = option or context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

LilBubbyShowcase.Register("postal", function(index, context, objects, test)
    if test then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local tester = submenu(context, "lilBubby's Big ol Mod Tester")
    local suite = submenu(tester, "Postal service tests")
    suite:addOption(GUIDED .. " (moves you into the test post office)", player, startGuided)
    suite:addOption("Check invalid requests and command registration", player, run, "guards")
    suite:addOption("Show last result", player, function(p)
        show(p, results[p:getPlayerNum()] or "Nothing has been run yet. Start the guided post office test, or check invalid requests.")
    end)
    suite:addOption("Clean up the post office test", player, cleanupGuided)
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= MODULE or type(args) ~= "table" then return end
    if command == "reply" then
        local request = args.id and pending[args.id]
        if request then
            pending[args.id] = nil
            pcall(request.done, args)
        end
        return
    end
    if command ~= "result" then return end
    for index = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(index)
        if player and player:getOnlineID() == args.playerID then show(player, args.text); return end
    end
end)
