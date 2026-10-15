-- Satanic Temples: player identity and the login-name migration, run against
-- the mod's real SO_Storage and SO_PlayerLedger with small stand-ins.
--   lua tests/satanictemples_identity_checks.lua [<mod lua folder>]
-- The default is the local Workshop copy of the mod.
local base = arg[1] or (os.getenv("HOME") .. "/Zomboid/Workshop/SatanicTemples/Contents/mods/SatanicTemples/42/media/lua")
package.path = base .. "/shared/?.lua;" .. base .. "/server/?.lua;" .. package.path
local modData = {}
ModData = { getOrCreate = function(k) modData[k] = modData[k] or {}; return modData[k] end,
            get = function(k) return modData[k] end, exists = function(k) return modData[k] ~= nil end,
            add = function(k, v) modData[k] = v end, remove = function(k) modData[k] = nil end, transmit = function() end }
Events = setmetatable({}, { __index = function(t, k) local e = { Add = function() end }; t[k] = e; return e end })
SERVER = true
isClient = function() return false end
isServer = function() return SERVER end
getTimestampMs = function() return 0 end
getGameTime = function() return { getWorldAgeHours = function() return 0 end } end
getOnlinePlayers = function() return { size = function() return 0 end } end
getSandboxOptions = function() return nil end
SandboxVars = { SacrificialOffering = {} }
instanceof = function() return false end
print = print
require "SacrificialOffering/SO_Constants"
require "SacrificialOffering/SO_Util"
require "SacrificialOffering/SO_Logger"
require "SacrificialOffering/SO_Sandbox"
require "SacrificialOffering/SO_Storage"
require "SacrificialOffering/SO_PlayerLedger"
local SO = SacrificialOffering
local L, St = SO.PlayerLedger, SO.Storage
local function player(name, steam, num)
    return { getUsername = function() return name end, getSteamID = function() return steam end,
             getPlayerNum = function() return num or 0 end, getOnlineID = function() return 1 end }
end
local ok = true
local function check(label, cond) print((cond and "PASS " or "FAIL ") .. label); ok = ok and cond end

local root = St.Get()
-- Kahlua prints the Steam ID double as Java does ("7.656119951162512E16"), so the stand-in returns that text.
-- A pre-update record under the rounded Steam key, shared by two neighbouring IDs.
root.players["steam:7.656119951162512E16"] = { bestXP = { Woodwork = 5000 }, deathGeneration = 3, marker = "old" }
local a = player("Alice", "7.656119951162512E16")
local id = L.GetIdentity(a)
check("multiplayer key is the login name", id == "user:alice")
check("old record copied to the login name", root.players["user:alice"] and root.players["user:alice"].marker == "old")
check("old record kept (copy, not move)", root.players["steam:7.656119951162512E16"] ~= nil)
check("copy is independent", root.players["user:alice"] ~= root.players["steam:7.656119951162512E16"])
check("old key maps to the new one", root.identityAliases["steam:7.656119951162512E16"] == "user:alice")
check("old corpse tag resolves to its owner", L.CanonicalIdentity("steam:7.656119951162512E16") == "user:alice")
root.players["user:alice"].bestXP.Woodwork = 9000
L.GetIdentity(a)
check("second join does not overwrite the new record", root.players["user:alice"].bestXP.Woodwork == 9000)
local b = player("Bob", "7.656119951162512E16")
L.GetIdentity(b)
check("neighbouring account gets its own copy", root.players["user:bob"] and root.players["user:bob"] ~= root.players["user:alice"])
check("alias stays with the first owner", root.identityAliases["steam:7.656119951162512E16"] == "user:alice")
local c = player("Carol", "0")
check("non-Steam player keyed by login name", L.GetIdentity(c) == "user:carol" and root.players["user:carol"] == nil)
SERVER = false
check("single player keyed by player slot", L.GetIdentity(player("Some Character", "0", 0)) == "local:0")
print(ok and "PASS: login-name identity, legacy Steam record copy, corpse aliases, single-player slots" or "FAIL: see above")
if not ok then os.exit(1) end
