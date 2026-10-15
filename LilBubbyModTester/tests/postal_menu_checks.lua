-- Routing/UI regression checks. Production service behavior is tested separately.
local source = debug.getinfo(1, "S").source:sub(2)
local testerRoot = source:match("^(.*)/tests/[^/]+$") or "."
local root = arg[1] or (testerRoot .. "/Contents/mods/LilBubbyModTester/42/media/lua/")
local events = {}
local function event(name)
    return { Add = function(fn) events[name] = events[name] or {}; table.insert(events[name], fn) end }
end
Events = { OnClientCommand = event("client"), OnServerCommand = event("server"), OnFillWorldObjectContextMenu = event("menu"), OnTick = event("tick") }
require = function() end
getActivatedMods = function() return { contains = function() return true end } end -- every tested mod enabled
local first = { id = 7, index = 0, username = "One" }
local second = { id = 8, index = 1, username = "Two" }
for _, player in ipairs({ first, second }) do
    function player:isDead() return self.dead == true end
    function player:getOnlineID() return self.id end
    function player:getPlayerNum() return self.index end
    function player:getUsername() return self.username end
end
local players = { first, second }
getSpecificPlayer = function(index) return players[index + 1] end
getNumActivePlayers = function() return #players end
local client = true
isClient = function() return client end
isServer = function() return false end
local now = 100000
getTimestampMs = function() return now end
local requests, replies, runs, dialogs = {}, {}, {}, {}
sendClientCommand = function(player, module, command, args) requests[#requests + 1] = { player = player, module = module, command = command, args = args } end
sendServerCommand = function(player, module, command, args) replies[#replies + 1] = { player = player, module = module, command = command, args = args } end
PostalTest = { Run = function(player, suite)
    runs[#runs + 1] = { player = player, suite = suite }
    return "PASS: " .. player.username .. " " .. suite
end }
dofile(root .. "shared/PostalTest_Guided.lua")
dofile(root .. "client/LilBubbyShowcase.lua")
dofile(root .. "client/PostalTest_Client.lua")
local S = LilBubbyShowcase
local menu = events.menu[1]
local empty = S.NewMenu()
menu(0, empty, {}, true)
assert(#empty.options == 0, "probe must not create menus")
menu(0, empty, {}, false)
menu(0, empty, {}, false)
assert(#empty.options == 1 and empty.options[1].name == "Open Mod Showcase", "one shared launcher")
local entries, notes = S.Build(first, "postal")
assert(#entries == 4, "all postal actions are in the showcase")
assert(entries[1].name:find("Guided post office test", 1, true) == 1, "the guided test leads the list")
assert(entries[2].name == "Check invalid requests and command registration" and entries[3].name == "Show last result")
assert(entries[4].name == "Clean up the post office test", "its cleanup closes the list")
assert(S.Run(first, "postal", entries[2], notes))
assert(requests[1].player == first and requests[1].module == "LilBubbyPostalTest" and requests[1].command == "run"
    and requests[1].args.suite == "guards", "the invalid-requests check is sent to the server")
S.sessions = {}
-- Deliver to every listener, as the game does (the showcase console logs traffic too).
local function receive(...) for _, fn in ipairs(events.server) do fn(...) end end
receive("Unrelated", "result", { playerID = 7, text = "wrong" })
receive("LilBubbyPostalTest", "result", { playerID = 999, text = "wrong" })
for _ in pairs(S.sessions) do error("unrelated responses are ignored") end
receive("LilBubbyPostalTest", "result", { playerID = 8, text = "Player two result" })
assert(S.Session(second, "postal").history[1] == "Player two result", "split-screen result goes to requester")
entries[3].onSelect(first)
assert(not S.Session(first, "postal").history[1]:find("Player two result", 1, true), "last result is separate per local player")
client = false
assert(S.Run(first, "postal", entries[2], notes))
assert(runs[1].player == first and runs[1].suite == "guards", "single player uses local authenticated character")
-- Guided test (single-player path, server operations and windows stood in):
-- each step's window, a denied and a passed OK, the result, and Cancel.
local windows, opened, ops = {}, 0, {}
SVSBTTrapTestUI = {
    ShowMessage = function(spec, onOk, onCancel)
        local window = { spec = spec, onOk = onOk, onCancel = onCancel }
        function window:change(changes) for key, value in pairs(changes) do self.spec[key] = value end end
        windows[#windows + 1] = window
        return window
    end,
    Close = function(window) window.closed = true end,
}
S.Open = function() opened = opened + 1 end
LilBubbyTeleport = { SETTLE_MS = 15000, Travelling = function() return false end }
local arrived, denials = false, { [2] = true }
local checks = { "PASS: Box #1 physical key ID matches registry" }
local answers = {
    begin = function() return { x = 10, y = 20, z = 0, expected = 1000 } end,
    move = function() return { x = 10, y = 20, z = 0, expected = 1000 } end,
    setup = function()
        if not arrived then return { waiting = true } end
        return { phase = 1, computer = { x = 11, y = 20 }, generator = { x = 3, y = 20 }, blankName = "Blank Key", cash = 1000, margin = 3 }
    end,
    place = function(_, args)
        if args.size == "large" then return { ok = false, reason = "That tile already has a PO Box." } end
        return { ok = true, box = "Small #1 ($250)" }
    end,
    advance = function(_, args)
        if denials[args.phase] then
            denials[args.phase] = nil
            return { ok = false, missing = { "No large PO Box stands in the post office yet." } }
        end
        local passes = { { sizes = { { label = "Small", capacity = 10, price = 250 } } },
            { boxes = { "Small #1 ($250)" }, checks = checks }, { available = 3, cheapest = 250, cash = 1000 },
            { box = "Small #1 ($250)", cash = 750, checks = { "PASS: Held key for box #1 matches physical lock and claim serial" } },
            { papers = 2, checks = { "PASS: Collecting the same parcel a second time grants nothing" } } }
        local reply = passes[args.phase]
        reply.ok = true
        return reply
    end,
    cleanup = function() return { claims = 1, keys = 1, boxes = 3, parcels = 1, items = 8, objects = 2, zones = 1, kept = {} } end,
}
local sentArgs = {}
for name, answer in pairs(answers) do
    PostalTest.Guided.OPS[name] = function(player, args) ops[#ops + 1] = name; sentArgs[#sentArgs + 1] = args; return answer(player, args) end
end
local function clientTick() for _, fn in ipairs(events.tick) do fn() end end
local function text(window) return table.concat(window.spec.headline, " ") .. " " .. table.concat(window.spec.details, " ") end
-- The world right-click menu as the game fills it.
local tile = { getX = function() return 12 end, getY = function() return 21 end }
first.getSquare = function() return tile end
local function rightClick()
    local context = S.NewMenu()
    for _, fn in ipairs(events.menu) do fn(0, context, { { getSquare = function() return tile end } }, false) end
    return context
end
local function option(context, fragment)
    for _, o in ipairs(context.options) do if o.name:find(fragment, 1, true) then return o end end
end
entries[1].onSelect(first)
assert(ops[1] == "begin" and #windows == 0, "the test begins by finding a building")
clientTick()
assert(ops[2] == "setup" and #windows == 0, "nothing is shown until the player stands in the building")
now = now + 500
clientTick()
assert(#ops == 2, "the server is asked about the arrival once a second, not every tick")
now = now + 7000
clientTick()
assert(ops[#ops] == "move", "a player who has not arrived by the deadline is moved again")
arrived = true
now = now + 1001
clientTick()
assert(#windows == 1 and text(windows[1]):find("money bundles", 1, true) and text(windows[1]):find("What a post office is for", 1, true),
    "step 1 says what was set up and what a post office does")
assert(windows[1].spec.left, "instructions are set against the left edge")
assert(not option(rightClick(), "Post office test"), "the box entries are not on the right-click menu before step 2")
windows[1].onOk()
assert(#windows == 2 and windows[1].closed and text(windows[2]):find("admin-only", 1, true)
    and text(windows[2]):find("You are not made an admin", 1, true), "step 2 explains that placing boxes is admin-only and that the tester does it")
local menu = rightClick()
assert(option(menu, "place a Small PO Box here") and option(menu, "place a Medium PO Box here") and option(menu, "place a Large PO Box here"),
    "step 2 adds one right-click entry per box size")
local small = option(menu, "place a Small PO Box here")
small.onSelect(small.target, small.args[1], small.args[2])
assert(ops[#ops] == "place" and sentArgs[#sentArgs].x == 12 and sentArgs[#sentArgs].y == 21 and sentArgs[#sentArgs].size == "small",
    "the entry asks the server for a box of that size on the clicked tile")
assert(windows[2].spec.status.text == "Placed Small #1 ($250)." and windows[2].spec.status.ready, "the window says the box was placed")
local large = option(menu, "place a Large PO Box here")
large.onSelect(large.target, large.args[1], large.args[2])
assert(windows[2].spec.problem == "No box placed. That tile already has a PO Box.", "a refused box says why")
windows[2].onOk()
assert(#windows == 2 and windows[2].spec.problem:find("No large PO Box", 1, true) and not windows[2].closed,
    "a denied step says what is missing and stays up")
windows[2].onOk()
assert(#windows == 3 and text(windows[3]):find("Postal Services is only on the menu", 1, true)
    and text(windows[3]):find("the key is the rental", 1, true), "step 3 explains the postal page and the key")
assert(not option(rightClick(), "Post office test"), "the box entries leave the right-click menu after step 2")
windows[3].onOk()
assert(#windows == 4 and text(windows[4]):find("Power On Computer", 1, true) and text(windows[4]):find("COLLECT PARCELS", 1, true),
    "step 4 has the player rent a box and explains delivery")
windows[4].onOk()
assert(#windows == 5 and text(windows[5]):find("2 sheets of paper", 1, true) and text(windows[5]):find("Click COLLECT PARCELS", 1, true),
    "step 5 has the player collect a delivery")
windows[5].onOk()
local report = S.Session(first, "postal").history[1]
assert(report:find("^PASS: Guided post office test: you set up a post office, rented Small #1") and report:find("PASS: Step 5", 1, true)
    and report:find("PASS: Box #1 physical key ID matches registry", 1, true) and report:find("second time grants nothing", 1, true)
    and windows[5].closed and opened == 1, "the last step ends the test with every step and server check in the report: " .. report)
clientTick()
assert(ops[#ops] == "advance", "a finished test asks the server nothing more")
-- A failed server check does not stop the steps, but decides the verdict.
checks[1] = "FAIL: Box #1 physical key ID matches registry"
entries[1].onSelect(first)
clientTick()
for i = 6, 10 do windows[i].onOk() end
report = S.Session(first, "postal").history[1]
assert(report:find("^FAIL: Guided post office test: every step was completed, but 1 server check%(s%) failed"), report)
entries[1].onSelect(first)
clientTick()
windows[11].onCancel()
assert(ops[#ops] == "cleanup" and windows[11].closed and opened == 3, "Cancel cleans up and returns to the showcase")
assert(S.Session(first, "postal").history[1]:find("^INFO: Guided post office test cancelled and cleaned up: 1 box rental"),
    "the cancel report says what was removed")
entries[4].onSelect(first)
assert(S.Session(first, "postal").history[1]:find("^PASS: Cleaned up: "), "the cleanup entry reports what it removed")
PostalTest.Guided.OPS.cleanup = function() return { kept = { "#2: it still holds items" }, boxes = 1 } end
entries[4].onSelect(first)
assert(S.Session(first, "postal").history[1]:find("^BLOCKED: Post office cleanup is not finished"), "a box that cannot be removed is reported")
client = true
runs = {}
dofile(root .. "server/LilBubbyPacer.lua")
dofile(root .. "server/PostalTest_Server.lua")
local function tick() for _, fn in ipairs(events.tick or {}) do fn() end end
local command = events.client[#events.client]
command("Unrelated", "run", first, {})
command("LilBubbyPostalTest", "wrong", first, {})
command("LilBubbyPostalTest", "run", nil, {})
assert(#runs == 0)
command("LilBubbyPostalTest", "run", first, { suite = "guards", playerID = 8, quantity = 999, itemFullType = "Base.Axe" })
assert(#runs == 1 and runs[1].player == first and runs[1].suite == "guards", "unprivileged requester cannot choose a target or payload")
assert(replies[#replies].player == first and replies[#replies].args.playerID == 7, "response is private")
command("LilBubbyPostalTest", "run", first, {})
assert(#runs == 1, "a request within a second waits its turn")
command("LilBubbyPostalTest", "run", second, { suite = "guards" })
assert(#runs == 2 and runs[2].player == second, "players have independent queues")
now = now + 1001
tick()
assert(#runs == 3 and runs[3].player == first and runs[3].suite == "guards", "the waiting request runs instead of being dropped")
now = now + 1001
for _, suite in ipairs({ "bogus", "all", "boxes", "keys", "parcel" }) do
    command("LilBubbyPostalTest", "run", first, { suite = suite })
    now = now + 1001
    tick()
end
command("LilBubbyPostalTest", "run", first, { suite = {} })
assert(#runs == 3, "unknown, retired or malformed suites cannot execute")
first.dead = true
command("LilBubbyPostalTest", "run", first, { suite = "guards" })
assert(#runs == 3 and replies[#replies].args.text:find("living player", 1, true))
first.dead = false
PostalTest.Run = function() error("Injected failure") end
command("LilBubbyPostalTest", "run", first, {})
assert(replies[#replies].args.text:find("ERROR:", 1, true), "engine errors returned to requester")
-- Guided test requests: answered to the request that asked, for the sender only.
now = now + 1001
PostalTest.Guided.OPS.advance = function(player, args) return { ok = true, phase = args.phase + 1, who = player.username } end
command("LilBubbyPostalTest", "advance", first, { id = 41, phase = 1, playerID = 8 })
local answer = replies[#replies]
assert(answer.player == first and answer.command == "reply" and answer.args.id == 41 and answer.args.who == "One"
    and answer.args.playerID == 7 and answer.args.phase == 2, "a guided step is checked for its sender and answered by id")
PostalTest.Guided.OPS.advance = function() error("Injected failure") end
now = now + 1001
command("LilBubbyPostalTest", "advance", first, { id = 42 })
assert(replies[#replies].args.id == 42 and replies[#replies].args.error:find("Injected failure", 1, true), "a failed step check is reported, not lost")
first.dead = true
command("LilBubbyPostalTest", "advance", first, { id = 43 })
assert(replies[#replies].args.id == 43 and replies[#replies].args.error:find("living player", 1, true))
print("PASS: shared launcher, showcase dispatch, all action routes, single-player path, split-screen privacy, authenticated targeting, queued (never dropped) requests, malformed requests and errors, and the guided test's steps, box placing from the right-click menu, denial, verdict, cancel, cleanup and server replies")
