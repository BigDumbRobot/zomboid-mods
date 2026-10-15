-- Dispatch and session regression tests; no game engine or UI required.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/client/"
local menuEvents = {}
Events = { OnFillWorldObjectContextMenu = { Add = function(fn) menuEvents[#menuEvents + 1] = fn end } }
dofile(root .. "LilBubbyShowcase.lua")
local S = LilBubbyShowcase
local player = { getPlayerNum = function() return 0 end }
local other = { getPlayerNum = function() return 1 end }
local target, disabled, removed, calls = "vehicle #1", false, false, 0
S.Register("test", function(index, root)
    assert(index == 0)
    local tester, suite, group = S.NewMenu(), S.NewMenu(), S.NewMenu()
    root:addSubMenu(root:addOption("Tester"), tester)
    tester:addSubMenu(tester:addOption("Suite"), suite)
    suite:addOption(target).notAvailable = true
    suite:addSubMenu(suite:addOption("Group"), group)
    if not removed then
        local action = group:addOption("Action", player, function(p, a, b, c)
            assert(p == player and a == "first" and b == nil and c == "third", "preserve argument holes")
            calls = calls + 1
            S.Report(p, "test", "PASS: done")
        end, "first", nil, "third")
        action.notAvailable = disabled
    end
end)
local entries, notes = S.Build(player, "test")
assert(#entries == 1 and entries[1].path == "Group" and notes == "vehicle #1")
assert(S.Run(player, "test", entries[1], notes) and calls == 1)
assert(S.Session(player, "test").history[1] == "PASS: done", "synchronous result survives STARTED")
assert(S.Session(player, "test").tried[entries[1].key])
target = "vehicle #2"
assert(not S.Run(player, "test", entries[1], notes) and calls == 1, "target changes require review")
target = "vehicle #1"; disabled = true
assert(not S.Run(player, "test", entries[1], notes) and calls == 1, "disabled state revalidated")
disabled = false; removed = true
assert(not S.Run(player, "test", entries[1], notes) and calls == 1, "removed target cannot execute")
S.Report(other, "test", "other player")
S.Report(player, "different", "other mod")
assert(S.Session(player, "test").history[1] == "PASS: done", "history isolated by mod and player")
for i = 1, 50 do S.Report(player, "test", tostring(i)) end
assert(#S.Session(player, "test").history == 40 and S.Session(player, "test").history[1] == "50")
S.ReportIndex(1, "test", "respawn report")
assert(S.Session(other, "test").history[1] == "respawn report")
S.Register("broken", function() error("missing service") end)
local broken, errorText = S.Build(player, "broken")
assert(#broken == 0 and errorText:find("missing service", 1, true))
local summary = S.Summarize("Header\n" .. string.rep("PASS: fine\n", 20) .. "FAIL: late failure\nBLOCKED: missing key")
assert(summary:find("late failure", 1, true) and summary:find("missing key", 1, true))
getSpecificPlayer = function() return player end
local context = S.NewMenu()
menuEvents[1](0, context, {}, true)
assert(#context.options == 0)
menuEvents[1](0, context, {}, false)
menuEvents[1](0, context, {}, false)
assert(#context.options == 1 and context.options[1].name == "Open Mod Showcase")
print("PASS: showcase dispatch, stale targets, argument preservation, availability, session privacy, bounded history, summary failures and single launcher")
