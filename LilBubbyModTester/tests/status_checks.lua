-- Offline checks for LilBubbyStatus: while a test runs the banner always says
-- which test, the current step, what is happening this moment and for how
-- long; it stays hidden for instant results, and counts seconds only for a
-- deadline the player must act on.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local clock = 100000
function getTimestampMs() return clock end
print = function() end
local ticks = {}
Events = { OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end } }
require = function() end

dofile(root .. "client/LilBubbyStatus.lua")
dofile(root .. "client/LilBubbyCountdown.lua")
local St = LilBubbyStatus
assert(St.Banner == nil, "no game UI offline, but the tracking still loads")

local player = { x = 10.5, y = 10.5, dead = false, queue = {} }
function player:getX() return self.x end
function player:getY() return self.y end
function player:isDead() return self.dead end
ISTimedActionQueue = { getTimedActionQueue = function() return { queue = player.queue } end }

local function lines() return St.Lines(0, player, clock) end

assert(lines() == nil, "nothing shows while no test runs")

-- An instant result never flashes the banner.
St.Begin(0, "compat", "Show last result")
St.End(0, "compat", "PASS: shown")
clock = clock + 100
assert(lines() == nil and St.finished == nil, "an instant result shows nothing")

-- A real test.
St.Begin(0, "skylights", "Run the full Skylights test")
assert(lines() == nil, "hidden for the first moment")
clock = clock + 1000
local l = lines()
assert(l and l.title:find("Run the full Skylights test") and l.big == "Starting Run the full Skylights test",
    "a running test shows its name and its first step")
assert(l.small == "Working on this step", "and nothing invented about what it is doing: " .. l.small)

St.Step(0, "skylights", "Skylights test: building a test room nearby\nmore detail")
St.Sent(0, "LilBubbySkylightsTest", "room")
clock = clock + 200
assert(lines().small:find("Working on this step"), "a quick server answer is not shown as a wait")
clock = clock + 2000
l = lines()
assert(l.big == "Skylights test: building a test room nearby", "the step is the progress message's first line")
assert(l.small == "Waiting for the server to answer (room)", "a slow server answer is named: " .. l.small)
St.Received(0)

-- A note from the suite, and a nested wait keeps it.
St.Note(0, "Waiting for the room's light to settle")
assert(lines().small:find("light to settle"), "a suite's note describes its wait")

-- The character's timed action outranks the note.
player.queue = { { Type = "ISReadABook", item = { getDisplayName = function() return "Carpentry Vol. 1" end },
    action = { getJobDelta = function() return 0.4 end } }, {} }
l = lines()
assert(l.small:find("reading: Carpentry Vol. 1") and l.small:find("40%% done") and l.small:find("1 more queued"),
    "the timed action is named with its progress: " .. l.small)
player.queue = {}

-- Travelling outranks everything but the countdown.
LilBubbyTeleport = { HOP_MS = 1000, travels = { [player] = { x = 50, y = 10, hop = 8 } } }
l = lines()
assert(l.small:find("Travelling to the test spot: 40 tiles to go"), "travel shows how far is left: " .. l.small)
assert(not l.small:find("%d+ s"), "and invents no time estimate: " .. l.small)
LilBubbyTeleport.travels = {}

-- Crafting.
LilBubbyCraft = { jobs = { [player] = { waiting = true, output = "Base.Form", attempts = 0 } } }
assert(lines().small:find("Waiting for the ingredients"), "a craft waiting for ingredients says so")
LilBubbyCraft.jobs[player] = { waiting = false, output = "Base.Form", attempts = 2, since = clock }
assert(lines().small:find("Crafting Base.Form %(attempt 2%)"), "a craft in progress says what and which attempt")
LilBubbyCraft.jobs = {}

-- A countdown only where the seconds mean something: a deadline on the
-- player. At zero the test gives up, so the number is real.
LilBubbyCountdown.Start("k", 30, "Get into the pickup now")
l = lines()
assert(l.big == "Get into the pickup now" and l.small == "You have 30 seconds", "a deadline says what to do: " .. l.small)
clock = clock + 15000
assert(lines().small == "You have 15 seconds", "the deadline counts down live")
clock = clock + 17000
for _, fn in ipairs(ticks) do fn() end
assert(lines().big ~= "Get into the pickup now", "an expired deadline clears itself")

-- The result ends the test and says so briefly.
St.End(0, "other", "PASS")
assert(St.runs[0], "a result for another suite does not end this test")
St.End(0, "skylights", "PASS: Skylights test\n...")
l = lines()
assert(l and l.big == "Test finished: PASS" and l.verdict == "PASS", "the end is announced")
clock = clock + St.FINISHED_MS + 1
assert(lines() == nil, "then the banner goes away")

-- Run every test: steps between tests still show.
LilBubbyAutoRun = { Running = function() return true end }
assert(lines() and lines().big == "Getting the next test ready", "between tests of a run, the banner stays up")
St.Step(0, "all", "Preparing your character")
assert(lines().big == "Preparing your character", "the run's own steps show")
LilBubbyAutoRun = nil
St.End(0, "all", "Run every test finished")

-- A dead character is waiting for the respawn.
St.Begin(0, "dmm", "Kill me and check the map")
clock = clock + 1000
player.dead = true
assert(lines().small:find("new character"), "while dead the banner says it waits for the new character")
io.write("PASS: the status banner names the test, its step and what is happening now counts seconds only for a deadline you must act on, and announces the end\n")
