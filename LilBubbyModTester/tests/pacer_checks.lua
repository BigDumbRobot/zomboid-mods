-- Offline checks for the request pacer: requests are spaced, never lost.
-- Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local ticks = {}
Events = { OnTick = { Add = function(fn) ticks[#ticks + 1] = fn end } }
local clock = 1000
function getTimestampMs() return clock end
print = function() end
dofile(root .. "server/LilBubbyPacer.lua")
local Q = LilBubbyPacer
local function tick() for _, fn in ipairs(ticks) do fn() end end
local function player(name) return { getUsername = function() return name end } end
local one, two = player("One"), player("Two")

local ran = {}
for i = 1, 3 do Q.Run(one, "Suite", 1000, function() ran[#ran + 1] = i end) end
assert(#ran == 1 and ran[1] == 1, "the first request runs at once")
assert(Q.Pending(one, "Suite") == 2, "the others wait")
Q.Run(two, "Suite", 1000, function() ran[#ran + 1] = "two" end)
assert(ran[2] == "two", "another player is not held up")
Q.Run(one, "Other", 1000, function() ran[#ran + 1] = "other" end)
assert(ran[3] == "other", "another suite is not held up")
clock = clock + 999; tick()
assert(#ran == 3, "nothing runs before the gap")
clock = clock + 1; tick()
assert(ran[4] == 2 and #ran == 4, "the next request runs once the gap has passed")
clock = clock + 1000; tick()
assert(ran[5] == 3 and Q.Pending(one, "Suite") == 0, "every request ran, in order")

Q.Run(one, "Suite", 0, function() error("boom") end)
Q.Run(one, "Suite", 0, function() ran[#ran + 1] = "after" end)
clock = clock + 1000; tick()
assert(ran[#ran] == "after", "a failing request does not block the ones behind it")

for _ = 1, Q.LIMIT + 5 do Q.Run(two, "Flood", 1000000, function() end) end
assert(Q.Pending(two, "Flood") == Q.LIMIT, "a flood is capped: one runs, LIMIT wait, the rest are dropped")
io.write("PASS: requests are spaced per player and suite, run in order once their turn comes, survive failures, and floods are capped\n")
