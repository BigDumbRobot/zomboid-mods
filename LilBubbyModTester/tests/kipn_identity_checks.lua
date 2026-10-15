-- Offline checks for KIPN's player identity: a player is their server
-- account, never their Steam ID, and records saved under the old Steam-based
-- keys move to the account. Loads the real KIPN files from the local project
-- (~/Zomboid/Workshop/KIPN) and runs them against old-format sample data.
-- Run from this Workshop project directory: lua tests/kipn_identity_checks.lua
local HOME = os.getenv("HOME") or ""
local K = (arg and arg[1]) or (HOME .. "/Zomboid/Workshop/KIPN/Contents/mods/KIPN/42/media/lua/")
do
    local file = io.open(K .. "shared/KIPN_Shared.lua")
    if not file then
        io.write("SKIP: KIPN is not at " .. K .. "\n")
        return
    end
    file:close()
end

local logged = {}
print = function(text) logged[#logged + 1] = tostring(text) end
require = function() end
local server, client = true, false
isServer = function() return server end
isClient = function() return client end
instanceof = function(object, class) return object ~= nil and object.class == class end
getTimestampMs = function() return 1000 end
local events = {}
Events = setmetatable({}, { __index = function(t, name)
    local event = { Add = function(fn) events[name] = fn end }
    t[name] = event
    return event
end })
SandboxVars = { KIPN = {} }
KIPN = { Server = {}, Shared = {} }
local data, saves = {}, {}
KIPN.Server.GetData = function() return data end
KIPN.Server.Save = function(domain) saves[#saves + 1] = domain or "all"; return true end
KIPN.Server.RegisterCommandHandler = function() end
dofile(K .. "shared/KIPN_Logger.lua")
dofile(K .. "shared/KIPN_Shared.lua")
dofile(K .. "server/KIPN_Permissions.lua")
dofile(K .. "server/KIPN_ClaimService.lua")
dofile(K .. "server/KIPN_LeaderboardService.lua")
local S, Claims = KIPN.Shared, KIPN.Server.ClaimService

local checks = 0
local function check(ok, label)
    checks = checks + 1
    if not ok then error("FAIL: " .. label, 2) end
end

-- The game hands Lua a Steam ID as a double: already rounded.
local function who(name, steam)
    return { class = "IsoPlayer", getUsername = function() return name end, getSteamID = function() return steam end,
        getDisplayName = function() return name .. " (character)" end, getAccessLevel = function() return "None" end,
        isAdmin = function() return false end, getRole = function() return { hasAdminPower = function() return false end } end }
end
local alice = who("Alice", 76561198000000001.0)
local bob = who("Bob", 76561198000000002.0) -- one off: the same double as Alice's
local carol = who("Carol", 76561198000900002.0)
local ROUNDED = tostring(76561198000000001.0)
check(ROUNDED == tostring(76561198000000002.0), "the fixture reproduces the rounding: two Steam IDs, one value")

------------------------------------------------------------
-- Identity
------------------------------------------------------------
check(S.GetPlayerId(alice) == "user:Alice" and S.GetPlayerId(bob) == "user:Bob", "a player is their server account")
check(S.GetPlayerId(alice) ~= S.GetPlayerId(bob), "players whose Steam IDs round together are different players")
check(S.GetPlayerSteamId(alice) == S.GetPlayerSteamId(bob) and S.GetPlayerSteamId(alice) == string.format("%.0f", 76561198000000001.0),
    "the Steam ID is still readable, rounded, for confirmation only")
check(S.IsAccountId("user:Alice") and not S.IsAccountId(ROUNDED) and not S.IsAccountId("SINGLEPLAYER") and S.AccountId("") == nil,
    "account keys are recognisable")
check(S.GetPlayerId(who("NoSteam", 0)) == "user:NoSteam", "a server without Steam uses the same account key")
local legacy = S.GetLegacyPlayerIds(alice)
local has = {}
for _, id in ipairs(legacy) do has[id] = true end
check(#legacy == 4 and has[ROUNDED] and has[string.format("%.0f", 76561198000000001.0)] and has["steam:" .. ROUNDED] and has["name:Alice"]
    and not has["user:Alice"], "every key a player's old records may be under is listed, and never the current one")
server = false
check(S.GetPlayerId(alice) == "SINGLEPLAYER", "single player has one identity")
server = true

------------------------------------------------------------
-- Claims saved under the old Steam-based key
------------------------------------------------------------
local function claim(id, owner, username, active)
    return { id = id, type = "property", targetId = "t_" .. id, ownerSteamId = owner, ownerUsername = username, active = active }
end
data.claims = { version = 2, records = {
    a = claim("a", ROUNDED, "Alice", true),
    b = claim("b", ROUNDED, "Bob", true), -- Bob's, under the key he shares with Alice
    c = claim("c", ROUNDED, nil, true), -- no username on record
    d = claim("d", "user:Carol", "Carol", true), -- already an account
    e = claim("e", ROUNDED, "Alice", false), -- released long ago
    f = claim("f", ROUNDED, "unknown", true),
} }
check(Claims.Initialize() == true, "the claim service starts on old-format data")
local records = data.claims.records
check(records.a.ownerSteamId == "user:Alice" and records.b.ownerSteamId == "user:Bob", "each claim moves to the account whose username it stored")
check(records.a.legacyOwnerSteamId == ROUNDED and records.b.legacyOwnerSteamId == ROUNDED, "the old key stays on the record")
check(records.e.ownerSteamId == "user:Alice", "released claims move too")
check(records.c.ownerSteamId == ROUNDED and records.f.ownerSteamId == ROUNDED and records.c.legacyOwnerSteamId == nil,
    "a claim with no username is left on its old key, not guessed")
check(records.d.ownerSteamId == "user:Carol" and records.d.legacyOwnerSteamId == nil, "a claim already under an account is untouched")
local function owned(player)
    local ids = {}
    for _, record in pairs(Claims.GetPlayerClaims(player)) do ids[#ids + 1] = record.id end
    table.sort(ids)
    return table.concat(ids, ",")
end
check(owned(alice) == "a" and owned(bob) == "b" and owned(carol) == "d", "each player owns exactly their own claims: " .. owned(alice) .. " / " .. owned(bob))
check(Claims.GetClaimForTarget("property", "t_b").ownerSteamId == Claims.GetPlayerSteamId(bob)
    and Claims.GetClaimForTarget("property", "t_b").ownerSteamId ~= Claims.GetPlayerSteamId(alice), "Alice no longer passes as the owner of Bob's claim")
local leftBehind, moved = 0, 0
for _, line in ipairs(logged) do
    if line:find("NOT migrated", 1, true) then leftBehind = leftBehind + 1 end
    if line:find("Claim owner migrated to server account", 1, true) then moved = moved + 1 end
end
check(moved == 3 and leftBehind == 2, "every moved and every skipped claim is logged: " .. moved .. " / " .. leftBehind)
check(saves[1] == "claims", "the migrated claims are saved: " .. table.concat(saves, ","))
logged = {}
check(Claims.Initialize() == true and records.a.legacyOwnerSteamId == ROUNDED and records.a.ownerSteamId == "user:Alice", "a second start changes nothing")
for _, line in ipairs(logged) do check(not line:find("Claim owner migrated", 1, true), "and migrates nothing again") end

-- A single-player save: the one player takes the claims under their Steam ID.
server = false
data = { claims = { version = 2, records = { s = claim("s", ROUNDED, "Alice", true), m = claim("m", "user:Dave", "Dave", true) } } }
check(Claims.Initialize() == true and data.claims.records.s.ownerSteamId == "SINGLEPLAYER" and data.claims.records.s.legacyOwnerSteamId == ROUNDED
    and data.claims.records.m.ownerSteamId == "user:Dave", "a single-player claim moves to SINGLEPLAYER; an account's claim stays")
check(owned(alice) == "s", "the single player owns it")
server = true

------------------------------------------------------------
-- Player stats rows: moved when the player is next seen
------------------------------------------------------------
data = { playerStats = {
    [ROUNDED] = { username = "Alice", deaths = 4 }, -- shared key: the stored username says whose
    ["name:Carol"] = { username = "Carol", deaths = 2 },
} }
KIPN.Server.LeaderboardService.Initialize()
local die = events.OnCharacterDeath
check(type(die) == "function", "the leaderboard listens for deaths")
die(bob)
check(data.playerStats["user:Bob"].deaths == 1 and data.playerStats[ROUNDED].deaths == 4, "Bob does not take the row Alice wrote under their shared key")
die(alice)
check(data.playerStats["user:Alice"].deaths == 5 and data.playerStats[ROUNDED] == nil and data.playerStats["user:Alice"].legacyKey == ROUNDED,
    "Alice's row moves to her account and carries on counting")
die(carol)
check(data.playerStats["user:Carol"].deaths == 3 and data.playerStats["name:Carol"] == nil, "a row filed by name moves too")

------------------------------------------------------------
-- Other saved data: keys and fields, at any depth
------------------------------------------------------------
local careers = {
    reputation = { ["steam:" .. ROUNDED] = 77, ["user:Alice"] = 5 },
    businesses = { b1 = { ownerKey = "steam:" .. ROUNDED, orders = { { clientKey = "steam:" .. ROUNDED }, { clientKey = "user:Zed" } } } },
    notifications = { ["steam:" .. ROUNDED] = { { unread = true } } },
}
local movedCount, conflicts = S.RekeyIdentity(careers, "steam:" .. ROUNDED, "user:Alice")
check(careers.businesses.b1.ownerKey == "user:Alice" and careers.businesses.b1.orders[1].clientKey == "user:Alice"
    and careers.businesses.b1.orders[2].clientKey == "user:Zed", "owner and client fields are re-keyed, others left")
check(careers.notifications["user:Alice"][1].unread and careers.notifications["steam:" .. ROUNDED] == nil, "a table keyed by the old identity is re-keyed")
check(careers.reputation["user:Alice"] == 5 and careers.reputation["steam:" .. ROUNDED] == 77 and conflicts == 1 and movedCount == 3,
    "an entry already under the account is never overwritten; the old one stays and is counted")
check(S.RekeyIdentity(careers, "user:Alice", "user:Alice") == 0 and S.RekeyIdentity(nil, "a", "b") == 0, "nothing to do is nothing done")

------------------------------------------------------------
-- The admin list still confirms against the Steam ID
------------------------------------------------------------
SandboxVars.KIPN.AdminAccounts = "Alice"
SandboxVars.KIPN.AdminSteamIDs = "76561198000000001"
logged = {}
local resolve = KIPN.Server.Permissions.ResolveAccessLevel
check(resolve(alice) == "ADMIN" and resolve(bob) == "USER", "the admin list goes by account: the Steam ID twin is not an admin")
local confirmed = false
for _, line in ipairs(logged) do confirmed = confirmed or line:find("Steam ID confirmed", 1, true) ~= nil end
check(confirmed, "and the Steam ID is still logged as a second confirmation")

io.write("PASS: KIPN identifies players by server account; claims, stats and other saved records move off their Steam-based keys without crossing between players (" .. checks .. " checks)\n")
