-- Checks that a career switches itself off cleanly, instead of failing to
-- load, when the pieces it stands on are missing or out of date:
--   * its server file's Bridge is missing, empty or incomplete;
--   * the framework has no threats layer;
--   * the framework is older than the career (Shared.API_VERSION).
-- Run from this Workshop project directory: lua tests/version_checks.lua
-- The career projects are expected beside this one (../CareersMechanic, ...);
-- set CAREERS_WORKSHOP to point somewhere else.
local L = os.getenv("CAREERS_WORKSHOP") or ".."
local function lua(dir, mod) return L .. "/" .. dir .. "/Contents/mods/" .. mod .. "/42/media/lua/" end
local fw = lua("KIPN_Careers", "CareersFramework")
local mods = {
    { name = "Mechanic", dir = lua("CareersMechanic", "CareersMechanic"), shared = "KIPNCareers_MechanicShared", server = "KIPNCareers_MechanicServer",
      svc = "MechanicServer", threats = "KIPNCareers_MechanicThreats", out = "MechanicThreats", init = "KIPNCareers_MechanicInit" },
    { name = "Blacksmith", dir = lua("CareersBlacksmith", "CareersBlacksmith"), shared = "KIPNCareers_BlacksmithShared", server = "KIPNCareers_BlacksmithServer",
      svc = "BlacksmithServer", threats = "KIPNCareers_BlacksmithThreats", out = "BlacksmithThreats", init = "KIPNCareers_BlacksmithInit" },
    { name = "Drug Dealer", dir = lua("CareersDrugDealer", "CareersDrugDealer"), shared = "KIPNCareers_DealerShared", server = "KIPNCareers_DealerServer",
      svc = "DealerServer", threats = "KIPNCareers_DealerThreats", out = "DealerThreats", init = "KIPNCareers_DealerInit" },
}
do
    local probe = io.open(mods[1].dir .. "shared/" .. mods[1].shared .. ".lua", "r")
    if not probe then print("version_checks: SKIPPED (career projects not found beside this one)") return end
    probe:close()
end

function isClient() return false end
function isServer() return true end
function ZombRand() return 0 end
function getTimestampMs() return 0 end
local originalPrint = print
local total, failed = 0, 0
local function fn() end
local function report(ok, description, detail)
    total = total + 1
    if not ok then failed = failed + 1 end
    originalPrint((ok and "  PASS  " or "  FAIL  ") .. description .. ((not ok and detail) and ("  -> " .. tostring(detail)) or ""))
end

-- A clean Lua state for one case: no careers loaded, the framework's shared
-- file and the career's shared file in place.
local function fresh(mod)
    for name in pairs(package.loaded) do if name:find("^KIPNCareers") then package.loaded[name] = nil end end
    KIPNCareers, KIPN = nil, nil
    print = fn
    Events = setmetatable({}, { __index = function(t, k) local e = { Add = fn, Remove = fn } rawset(t, k, e) return e end })
    package.path = fw .. "shared/?.lua;" .. fw .. "server/?.lua;" .. mod.dir .. "shared/?.lua;" .. mod.dir .. "server/?.lua;" .. "./?.lua"
    -- The adapter reads the game's script manager; a stand-in is enough here.
    package.preload["KIPNCareers_NarcoticsAdapter"] = function()
        KIPNCareers.NarcoticsAdapter = { available = true, Initialize = fn, Get = fn }
        return KIPNCareers.NarcoticsAdapter
    end
    require("KIPNCareers_Shared")
    KIPNCareers.Shared.Log = fn
end

originalPrint("A career's Threats file without a usable server Bridge")
local career = { RegisterThreats = fn, id = "x" }
local cases = {
    { "no server table", function() return nil end },
    { "server without Bridge", function() return {} end },
    { "empty Bridge", function() return { Bridge = {} } end },
    { "partial Bridge", function() return { Bridge = { career = career, state = fn, notify = fn } } end },
    { "Bridge without its career", function() return { Bridge = setmetatable({}, { __index = function(_, key) return key ~= "career" and fn or nil end }) } end },
    { "no framework Threats", function() return { Bridge = setmetatable({ career = career }, { __index = function() return fn end }) } end, true },
}
for _, mod in ipairs(mods) do
    for _, case in ipairs(cases) do
        fresh(mod)
        require(mod.shared)
        package.loaded[mod.server] = true
        KIPNCareers[mod.svc] = case[2]()
        if case[3] then package.loaded["KIPNCareers_Threats"] = true end
        local ok, err = pcall(require, mod.threats)
        report(ok and KIPNCareers[mod.out] == nil, mod.name .. ": " .. case[1], err)
    end
end

originalPrint("A career on a framework older than it needs")
for _, mod in ipairs(mods) do
    fresh(mod)
    KIPNCareers.Shared.API_VERSION = nil -- a framework from before the version existed
    local ok, err = pcall(require, mod.server)
    report(ok and KIPNCareers[mod.svc] == nil, mod.name .. ": the server file loads and stays off", err)
    ok, err = pcall(require, mod.threats)
    report(ok and KIPNCareers[mod.out] == nil, mod.name .. ": its threats stay off", err)
    ok, err = pcall(require, mod.init)
    report(ok, mod.name .. ": its init file loads", err)
end

originalPrint("A career on the current framework")
for _, mod in ipairs(mods) do
    fresh(mod)
    local ok, err = pcall(require, mod.server)
    report(ok and type(KIPNCareers[mod.svc]) == "table" and type(KIPNCareers[mod.svc].Bridge) == "table", mod.name .. ": the server file loads", err)
    ok, err = pcall(require, mod.threats)
    report(ok and type(KIPNCareers[mod.out]) == "table", mod.name .. ": its threats load", err)
end

originalPrint(string.format("\n%d/%d passed", total - failed, total))
os.exit(failed == 0 and 0 or 1)
