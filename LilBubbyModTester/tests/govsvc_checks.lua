-- Local checks for the COMPUTER Safehouse and Land Claims suite.
-- Run from the Workshop project directory: lua tests/govsvc_checks.lua
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
local handlers = {}
local function event() return { Add = function(fn) handlers[#handlers + 1] = fn end, Remove = function() end } end
_G.Events = { OnClientCommand = event(), OnServerCommand = event(), OnFillWorldObjectContextMenu = event(), OnTick = event() }
_G.require = function() end
_G.isClient = function() return false end

dofile(root .. "shared/GovSvcTest_Checks.lua")
dofile(root .. "server/GovSvcTest_Server.lua")
dofile(root .. "client/LilBubbyShowcase.lua")
dofile(root .. "client/GovSvcTest_Client.lua")
local T = GovSvcTest

-- Report
local r = T.NewReport("title")
r:pass("a"); r:fail("b"); r:skip("c"); r:blocked("d"); r:info("e")
assert(r:check(true, "f") == true and r:check(nil, "g", "why") == false)
assert(r:equal(1, 2, "h") == false)
assert(r.counts.PASS == 2 and r.counts.FAIL == 3 and r.counts.SKIP == 1 and r.counts.BLOCKED == 1)
assert(r:summary():find("^FAILED | pass=2 fail=3"))
assert(r:text():find("FAIL: g %(why%)") and r:text():find("FAIL: h %(expected 2, got 1%)"))
local merged = T.NewReport("merged")
merged:pass("x")
merged:merge(r)
assert(merged.counts.PASS == 3 and #merged.lines == 1 + #r.lines)
assert(T.NewReport("empty"):summary():find("^NOT RUN"))

-- Geometry mirrors the mod: centred on the anchor, inclusive bounds.
local small = T.ExcavationRect(100, 200, 0, 5, 5)
assert(small.x1 == 98 and small.x2 == 102 and small.y1 == 198 and small.y2 == 202)
local even = T.ExcavationRect(100, 200, 0, 10, 4)
assert(even.x1 == 95 and even.x2 == 104 and even.y1 == 198 and even.y2 == 201)
assert(T.ExcavationRect(1, 1, 0, 0, 5) == nil)
local projection = T.ProjectionRect(10, 20, 14, 22)
assert(projection.x == 8 and projection.y == 18 and projection.w == 9 and projection.h == 7)
assert(T.SameRect({ x1 = 1, y1 = 2, x2 = 3, y2 = 4 }, { x1 = "1", y1 = 2, x2 = 3, y2 = 4 }))
assert(not T.SameRect({ x1 = 1, y1 = 2, x2 = 3, y2 = 4 }, nil))

-- Cash split matches the wallet's exact-payment rule.
local bundles, singles = T.CashSplit(250, 1)
assert(bundles == 2 and singles == 50)
assert(T.CashSplit(250, 20) == nil)
bundles, singles = T.CashSplit(0, 1)
assert(bundles == 0 and singles == 0)

-- Every catalog entry has an implementation on its side.
local seen = {}
for _, entry in ipairs(T.Catalog) do
    assert(not seen[entry.id], "duplicate id " .. entry.id)
    seen[entry.id] = true
    if entry.side == "server" then
        assert(type(T.ServerTests[entry.id]) == "function", "missing server test " .. entry.id)
    else
        assert(entry.side == "client" and type(T.ClientTests[entry.id]) == "function", "missing client test " .. entry.id)
    end
end
for id in pairs(T.ServerTests) do assert(seen[id], "server test not in the menu: " .. id) end
for id in pairs(T.ClientTests) do assert(seen[id], "client test not in the menu: " .. id) end
for _, id in ipairs(T.AutomaticChecks) do
    assert(T.CatalogById[id] and T.CatalogById[id].side == "server", "automatic check must be a server test: " .. id)
end
for _, tier in ipairs(T.TIERS) do
    for _, prefix in ipairs({ "issue_permit_", "desk_permit_", "land_check_", "land_claim_" }) do
        assert(T.ServerTests[prefix .. tier], "missing " .. prefix .. tier)
    end
end

-- Every follow-up check the server asks for exists on the client.
local source = io.open(root .. "server/GovSvcTest_Server.lua"):read("a")
local requested = 0
for name in source:gmatch('clientCheck = { name = "(%w+)"') do
    requested = requested + 1
    assert(type(T.ClientChecks[name]) == "function", "missing client check " .. name)
end
assert(requested >= 4)

-- Dispatch refuses unknown tests and reports a missing mod.
assert(T.RunServer({}, "nope"):text():find("unknown test"))
assert(T.RunServer({}, "c_menu"):text():find("unknown test"))
_G.KIPN = nil
assert(T.RunServer({}, "house_check"):text():find("Enable KIP Network Terminal"))

-- Handlers registered: server command listener, showcase launcher, showcase
-- console traffic log and the suite's result listener.
assert(#handlers == 4)

print("PASS: report, geometry, cash split, catalog coverage, client checks, dispatch")
