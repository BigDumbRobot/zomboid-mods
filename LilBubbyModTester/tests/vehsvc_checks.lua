-- Offline regression checks for the COMPUTER Vehicle Claims test suite.
-- Run from this Workshop project directory: lua tests/vehsvc_checks.lua
-- KIPNVehicleServices is replaced by stand-ins; the live mod is tested in game.
local lua = "Contents/mods/LilBubbyModTester/42/media/lua/"

local failures = 0
local function expect(condition, message)
    if not condition then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local function list(values)
    return { size = function() return #values end, get = function(_, index) return values[index + 1] end }
end

------------------------------------------------------------
-- GAME STUBS
------------------------------------------------------------

local handlers = {}
local function event(name)
    return { Add = function(callback) handlers[name] = handlers[name] or {}; table.insert(handlers[name], callback) end }
end
_G.Events = setmetatable({}, { __index = function(t, name) local e = event(name); rawset(t, name, e); return e end })
_G.isClient = function() return false end
_G.isServer = function() return true end
_G.require = function() end
local now = 1000
_G.getTimestampMs = function() return now end
_G.instanceof = function() return false end
_G.getOnlinePlayers = function() return list({}) end
_G.sendServerCommand = function() end
_G.print = print
local modData = {}
_G.ModData = { getOrCreate = function(tag) modData[tag] = modData[tag] or {}; return modData[tag] end }

------------------------------------------------------------
-- SUITE FILES
------------------------------------------------------------

dofile(lua .. "shared/VehSvcTest_Checks.lua")
local T = VehSvcTest
dofile(lua .. "server/VehSvcTest_Server.lua")

-- Catalog parity: every entry has exactly one implementation.
local clientSource = assert(io.open(lua .. "client/VehSvcTest_Client.lua")):read("a")
local seen = {}
for _, entry in ipairs(T.Catalog) do
    expect(not seen[entry.id], "duplicate catalog id " .. entry.id)
    seen[entry.id] = true
    if entry.side == "server" then
        expect(type(T.ServerTests[entry.id]) == "function", "server test missing: " .. entry.id)
    elseif entry.side == "flow" then
        expect(clientSource:find("function Flows%." .. entry.id .. "%(") ~= nil, "client flow missing: " .. entry.id)
    else
        expect(clientSource:find("function ClientTests%." .. entry.id .. "%(") ~= nil, "client test missing: " .. entry.id)
    end
end
for _, group in ipairs({ T.AutomaticChecks, T.AutomaticVehicleChecks, T.AutomaticClientChecks, T.AutomaticClientVehicleChecks }) do
    for _, id in ipairs(group) do expect(T.CatalogById[id] ~= nil, "automatic check not in catalog: " .. id) end
end
for id in pairs(T.ServerTests) do expect(T.CatalogById[id] ~= nil, "server test not in catalog: " .. id) end

-- Report bookkeeping.
local report = T.NewReport("t")
report:pass("a"); report:fail("b"); report:skip("c"); report:blocked("d"); report:info("e")
expect(report:summary() == "FAILED | pass=1 fail=1 blocked=1 skip=1", "report summary: " .. report:summary())
expect(report:equal(1, 2, "x") == false and report.lines[#report.lines] == "FAIL: x (expected 2, got 1)", "report equal detail")
expect(T.NewReport("t"):summary():find("NOT RUN") ~= nil, "empty report is NOT RUN")

-- Expected outcomes.
local open = { NonOwnerNoAccess = false, AllowNonOwnerMechanics = true, AllowNonOwnerTow = true, AllowNonOwnerOpenUnlockedDoors = true }
local closed = { NonOwnerNoAccess = true, AllowNonOwnerMechanics = true, AllowNonOwnerTow = true, AllowNonOwnerOpenUnlockedDoors = true }
for _, name in ipairs(T.INTERCEPTED_COMMANDS) do
    expect(T.ExpectedNonOwnerCommand(name, closed, true) == false, "NoAccess denies " .. name)
end
expect(T.ExpectedNonOwnerCommand("installPart", open) == true, "mechanics allowed")
expect(T.ExpectedNonOwnerCommand("removeTowing", open) == true, "tow allowed")
expect(T.ExpectedNonOwnerCommand("setDoorOpen", open, true) == true, "unlocked door allowed")
expect(T.ExpectedNonOwnerCommand("setDoorOpen", open, false) == false, "locked door denied")
for _, name in ipairs({ "setDoorLocked", "configDoor", "configWindow", "smashWindow" }) do
    expect(T.ExpectedNonOwnerCommand(name, open, true) == false, name .. " always denied")
end
local policy = T.ExpectedClientPolicy({ VehicleNonOwnerNoAccess = true, VehicleAllowNonOwnerMechanics = true })
expect(policy.noAccess and not policy.mechanics, "client NoAccess overrides mechanics")
expect(T.ExpectedClientPolicy(nil).mechanics == false, "client policy defaults closed")
expect(T.ExpectedExpiry(100, 0) == 0 and T.ExpectedExpiry(100, 2) == 100 + 172800, "artifact expiry")

------------------------------------------------------------
-- COMMAND INTERCEPTION AGAINST THE REAL ENFORCEMENT MODULE
------------------------------------------------------------

local config = { NonOwnerNoAccess = false, AllowNonOwnerMechanics = true, AllowNonOwnerTow = false, AllowNonOwnerOpenUnlockedDoors = true }
local claim = { id = "vehicle:7", type = "vehicle", targetId = "7", ownerSteamId = "OWNER", ownerUsername = "Owner", active = true }

local function part(id, isDoor, locked)
    local door = isDoor and { isLocked = function() return locked end, isOpen = function() return false end } or nil
    return { getId = function() return id end, getDoor = function() return door end, getInventoryItem = function() return {} end }
end
local parts = { part("Engine", false), part("DoorFrontLeft", true, false), part("EngineDoor", true, false) }
local vehicle = {
    modData = {},
    getId = function() return 7 end,
    getModData = function(self) return self.modData end,
    getPartCount = function() return #parts end,
    getPartByIndex = function(_, index) return parts[index + 1] end,
    getPartById = function(_, id) for _, p in ipairs(parts) do if p:getId() == id then return p end end end,
    getX = function() return 0 end, getY = function() return 0 end,
}
_G.getVehicleById = function(id) if id == 7 then return vehicle end end

_G.KIPN = { Server = {
    ClaimService = {
        Types = { VEHICLE = "vehicle" },
        GetClaimForTarget = function(_, id) if tostring(id) == "7" then return claim end end,
        GetPlayerSteamId = function(p) return tostring(p:getSteamID()) end,
        GetVehicleId = function(v) return tostring(v:getId()) end,
        SyncVehicleOwnershipMetadata = function() return true end,
        GetClaims = function() return {} end,
    },
    ClaimPermissions = { IsAllowed = function(c, p) return tostring(c.ownerSteamId) == tostring(p:getSteamID()) end },
    ClaimConfig = { GetServiceConfig = function() return config end },
    VehClaimService = {}, VehArtifactService = {}, ArtifactService = {},
    Permissions = { ResolveAccessLevel = function() return "USER" end },
} }

local tester = { getSteamID = function() return "TESTER" end, getUsername = function() return "Tester" end,
    getOnlineID = function() return 1 end, getX = function() return 0 end, getY = function() return 0 end,
    getZ = function() return 0 end, getVehicle = function() return nil end }

local function runCommandsTest()
    local r = T.NewReport("commands")
    T.ServerTests.commands(r, { player = tester, vehicle = vehicle, args = {}, payload = {} })
    return r
end

local function statusOf(r, name)
    for _, line in ipairs(r.lines) do
        if line:find(name .. ":", 1, true) or line:find(" " .. name .. " ", 1, true) then return line:match("^(%u+)") end
    end
end

-- No global ClientCommands: every command reported as not intercepted.
_G.ClientCommands = nil
local r = runCommandsTest()
expect(r.counts.FAIL == #T.INTERCEPTED_COMMANDS, "missing ClientCommands reports every command: " .. r:summary())

do
    local originals = {}
    _G.ClientCommands = { vehicle = {} }
    for _, name in ipairs(T.INTERCEPTED_COMMANDS) do
        ClientCommands.vehicle[name] = function() originals[name] = (originals[name] or 0) + 1 end
    end
    -- Stand-in for KIPNVehicleServices' enforcement: wraps each vanilla vehicle
    -- command and tells a non-owner the vehicle is claimed when it refuses.
    local function claimOf(v) return KIPN.Server.ClaimService.GetClaimForTarget(nil, v:getId()) end
    KIPN.Server.VehEnforcement = {
        GetVehicleClaim = claimOf,
        CanAccessVehicle = function(v, p)
            local c = claimOf(v)
            return c == nil or KIPN.Server.ClaimPermissions.IsAllowed(c, p)
        end,
        Initialize = function()
            for _, name in ipairs(T.INTERCEPTED_COMMANDS) do
                local vanilla = ClientCommands.vehicle[name]
                ClientCommands.vehicle[name] = function(p, args)
                    local v = getVehicleById(args.vehicle)
                    local door = args.part and v:getPartById(args.part)
                    local unlocked = door and door:getDoor() and not door:getDoor():isLocked() or false
                    if not KIPN.Server.VehEnforcement.CanAccessVehicle(v, p)
                        and not T.ExpectedNonOwnerCommand(name, config, unlocked) then
                        p:Say("This vehicle is claimed by someone else.")
                        return
                    end
                    return vanilla(p, args)
                end
            end
            return true
        end,
    }
    expect(KIPN.Server.VehEnforcement.Initialize() == true, "enforcement initializes")

    r = runCommandsTest()
    expect(r.counts.FAIL == 0 and r.counts.PASS == #T.INTERCEPTED_COMMANDS, "correct wrappers pass: " .. r:summary() .. "\n" .. table.concat(r.lines, "\n"))
    expect(originals.installPart == 1 and originals.setDoorOpen == 1 and not originals.smashWindow and not originals.addTowing,
        "allowed commands reached vanilla, denied ones did not")

    config.NonOwnerNoAccess = true
    r = runCommandsTest()
    expect(r.counts.FAIL == 0, "NoAccess scenario passes: " .. r:summary())
    config.NonOwnerNoAccess = false

    -- A broken mod: one wrapper missing. The suite must catch it.
    local wrapped = ClientCommands.vehicle.smashWindow
    ClientCommands.vehicle.smashWindow = function() end
    r = runCommandsTest()
    expect(r.counts.FAIL == 1 and statusOf(r, "smashWindow") == "FAIL", "unwrapped smashWindow is reported: " .. r:summary())
    ClientCommands.vehicle.smashWindow = wrapped

    -- Access decisions.
    local access = T.NewReport("access")
    T.ServerTests.access(access, { player = tester, vehicle = vehicle, args = {}, payload = {} })
    expect(access.counts.FAIL == 0 and access.counts.PASS >= 3, "access decisions: " .. access:summary() .. "\n" .. table.concat(access.lines, "\n"))
end

------------------------------------------------------------
-- OPEN TO EVERY PLAYER, AND REAL PLAYERS' CLAIMS
------------------------------------------------------------

for _, entry in ipairs(T.Catalog) do
    expect(entry.admin == nil, "every test is open to every player: " .. entry.id)
end
for _, step in ipairs({ "life_prepare", "life_form", "life_titled", "life_claimed" }) do
    expect(type(T.LifeSteps[step]) == "function", "lifecycle server step missing: " .. step)
    expect(clientSource:find('"' .. step .. '"', 1, true) ~= nil, "the client flow never requests " .. step)
end

local delivered
_G.sendServerCommand = function(_, _, _, payload) delivered = payload end
local userLevel = KIPN.Server.Permissions.ResolveAccessLevel
T.RunServer(tester, "admin_exempt", { vehicleId = 7 })
expect(delivered and delivered.text:find("stand-in admin", 1, true) ~= nil and not delivered.text:find("BLOCKED", 1, true)
    and not delivered.text:find("SKIP", 1, true), "a non-admin runs the admin test with a stand-in admin: " .. tostring(delivered and delivered.text))
expect(KIPN.Server.Permissions.ResolveAccessLevel == userLevel and userLevel(tester) == "USER", "the player's own level is left alone")
KIPN.Server.Permissions.ResolveAccessLevel = function() return "ADMIN" end
T.RunServer(tester, "admin_exempt", { vehicleId = 7 })
expect(delivered and not delivered.text:find("stand-in admin", 1, true), "a KIPN admin is checked as themselves")
KIPN.Server.Permissions.ResolveAccessLevel = function() return "USER" end

-- The fixture claim belongs to a real player ("Owner").
local releases = 0
KIPN.Shared = { Commands = { RELEASE_CLAIM = "RELEASE_CLAIM" } }
KIPN.Server.GetCommandHandler = function() return function() releases = releases + 1 end end
local safe = T.NewReport("release_not_owner")
T.ServerTests.release_not_owner(safe, { player = tester, vehicle = vehicle, args = {}, payload = {} })
expect(releases == 0 and safe.counts.BLOCKED == 1, "release test never targets a real player's claim: " .. safe:summary())

------------------------------------------------------------
-- SETUP, CONFIG, TOGGLES, CLAIM LIMIT AND RESYNC AGAINST A STAND-IN MOD
------------------------------------------------------------

local function freshReport(id) return T.NewReport(id) end
local function runServer(id, ctx)
    local r = freshReport(id)
    ctx = ctx or {}
    ctx.player, ctx.args, ctx.payload = ctx.player or tester, ctx.args or {}, ctx.payload or {}
    T.ServerTests[id](r, ctx)
    return r
end
local function failedLines(r)
    local lines = {}
    for _, line in ipairs(r.lines) do if line:find("^FAIL") then lines[#lines + 1] = line end end
    return table.concat(lines, "\n  ")
end

local REG_OFF, CLAIMS_OFF = "Vehicle registration is disabled.", "Vehicle claims are disabled."
local artifactCfg = {
    Types = { Registration = "registration", Claim = "claim" },
    Registration = { Enabled = true, VehicleEnabled = true },
    Claim = { Enabled = true, VehicleEnabled = true },
    ArtifactTypeDefs = { Vehicle = { zoneClassification = "DEALERSHIP" } },
    RegistrationItems = { Vehicle = T.REGISTRATION_ITEM },
    ClaimItems = { Vehicle = T.TITLE_ITEM },
}
local policy = {}
for key, field in pairs(T.SANDBOX_TO_CLAIM_CONFIG) do policy[field] = T.SANDBOX_DEFAULTS[key] end
_G.SandboxVars = { KIPN = {} }
for key, value in pairs(T.SANDBOX_DEFAULTS) do SandboxVars.KIPN[key] = value end

local function registrationOn() return artifactCfg.Registration.Enabled ~= false and artifactCfg.Registration.VehicleEnabled ~= false end
local function claimsOn() return artifactCfg.Claim.Enabled ~= false and artifactCfg.Claim.VehicleEnabled ~= false end
local VA = {
    CreateVehicleRegistration = function() if not registrationOn() then return false, REG_OFF end return false, "stand-in makes no forms" end,
    RegisterVehicleRegistration = function() if not registrationOn() then return false, REG_OFF end return false, "stand-in" end,
    IssueVehicleClaim = function()
        if not registrationOn() then return false, REG_OFF end
        if not claimsOn() then return false, CLAIMS_OFF end
        return false, "No registration form."
    end,
    ValidateVehicleClaim = function() if not claimsOn() then return false, CLAIMS_OFF end return false, "stand-in" end,
    FindPlayerVehicleClaimArtifact = function() if not claimsOn() then return nil, nil, CLAIMS_OFF end return nil, nil, "none" end,
}
local VC = { ValidateVehicleTarget = function() end, ValidateVehicleClaimArtifact = function() end, ClaimVehicle = function() end }

local claims, nextClaim = {}, 0
local car = { modData = {} }
function car:getId() return 8 end
function car:getModData() return self.modData end
function car:getX() return 0 end
function car:getY() return 0 end
function car:transmitModData() end
function car:getScript() return { getName = function() return "TestCar" end } end
_G.getVehicleById = function(id) if id == 8 then return car end end
local CS
CS = {
    Types = { VEHICLE = "vehicle" },
    GetPlayerSteamId = function(p) return tostring(p:getSteamID()) end,
    GetVehicleId = function(v) return tostring(v:getId()) end,
    GetVehiclePosition = function() return { x = 0, y = 0, z = 0 } end,
    GetClaimZone = function() return nil end,
    GetClaimForTarget = function(_, target)
        for _, c in pairs(claims) do if c.active and tostring(c.targetId) == tostring(target) then return c end end
    end,
    GetClaim = function(id) return claims[id] end,
    GetPlayerClaims = function(p)
        local mine = {}
        for id, c in pairs(claims) do if c.active and c.ownerSteamId == tostring(p:getSteamID()) then mine[id] = c end end
        return mine
    end,
    CreateClaimRecord = function(p, claimType, target, zone)
        nextClaim = nextClaim + 1
        local c = { id = "c" .. nextClaim, type = claimType, targetId = target, zoneId = zone, active = true,
            ownerSteamId = tostring(p:getSteamID()), ownerUsername = p:getUsername() }
        claims[c.id] = c
        return c
    end,
    RemoveClaimRecord = function(id) claims[id] = nil end,
    ReleaseClaim = function(id) if claims[id] then claims[id].active = false return true end return false, "unknown" end,
    SyncVehicleOwnershipMetadata = function(v, c)
        local md = v:getModData()
        md.KIPNVehicleClaimId = c and tostring(c.id) or nil
        md.KIPNVehicleOwnerSteamId = c and tostring(c.ownerSteamId) or nil
        md.KIPNVehicleOwnerUsername = c and tostring(c.ownerUsername) or nil
    end,
    CheckMaxClaimsForType = function(p)
        local max = tonumber(policy.MaxClaimsPerPlayer) or 0
        if max <= 0 then return true end
        local count = 0
        for _ in pairs(CS.GetPlayerClaims(p)) do count = count + 1 end
        if count >= max then return false, "You already hold the maximum number of vehicle claims." end
        return true
    end,
}
CS.GetClaimTypeDef = function(id)
    if id == "vehicle" then
        return { requiredCapability = "vehicle.claim", serviceConfigKey = "Vehicle", validateTarget = VC.ValidateVehicleTarget,
            validateClaimArtifact = VC.ValidateVehicleClaimArtifact, claim = VC.ClaimVehicle, onAfterRelease = function() end }
    end
end
local roles = { PLAYER = { permissions = {} }, ADMIN = { permissions = {} } }
for id, grants in pairs(T.PERMISSIONS) do for role, granted in pairs(grants) do roles[role].permissions[id] = granted or nil end end
local apps = {
    vehicle_registration = { screen = "KIPN_VehicleRegistration", permissions = { "vehicle.claim" }, classifications = { "DEALERSHIP" }, requiresSession = true },
    vehicle_records = { screen = "KIPN_VehicleRecords", permissions = { "vehicle.lookup" }, classifications = {}, requiresSession = true },
}
local commandIds = {}
for _, name in ipairs(T.COMMANDS) do commandIds[name] = name end
KIPN = {
    Shared = { Commands = commandIds },
    Server = {
        _registeredServices = { VehicleServices = { order = 610, dependsOn = T.SERVICE_DEPENDENCIES } },
        WorldRegistry = {
            RegisteredZoneTypes = { dealership = { label = "Car Dealership", classificationField = "dealership",
                defaultCapabilities = { ["vehicle.lookup"] = true, ["vehicle.claim"] = true, ["vehicle.transfer"] = true } } },
            ZoneTypes = { DEALERSHIP = "dealership" },
        },
        Permissions = {
            DefaultRoles = roles,
            GetDefinition = function(id) return T.PERMISSIONS[id] and {} or nil end,
            GetRolePermissions = function(role) return roles[role].permissions end,
            ResolveAccessLevel = function() return "USER" end,
        },
        ApplicationRegistry = { Get = function(id) return apps[id] end },
        ClaimService = CS,
        ArtifactService = { GetArtifactConfig = function() return artifactCfg end },
        ClaimConfig = { GetServiceConfig = function() return policy end, ServiceKeyByClaimType = { vehicle = "Vehicle" } },
        GetCommandHandler = function() return function() end end,
        Save = function() return true end,
        VehClaimService = VC, VehArtifactService = VA,
        VehEnforcement = { CanAccessVehicle = function() return true end, GetVehicleClaim = function() end },
    },
}

-- Setup: a correct mod passes; a wrong grant or a missing app fails.
local setup = runServer("setup")
expect(setup.counts.FAIL == 0 and setup.counts.PASS > 30, "setup passes a correct mod: " .. setup:summary() .. "\n  " .. failedLines(setup))
roles.PLAYER.permissions["vehicle.revoke"] = true
apps.vehicle_records = nil
setup = runServer("setup")
expect(setup.counts.FAIL == 2, "setup catches a PLAYER revoke grant and a missing app: " .. setup:summary() .. "\n  " .. failedLines(setup))
roles.PLAYER.permissions["vehicle.revoke"] = nil

-- Config: the sandbox reaches the policy; a stale policy and a client
-- with other values are reported.
local config = runServer("config", { args = { clientSandbox = SandboxVars.KIPN } })
expect(config.counts.FAIL == 0 and config.counts.SKIP == 0, "config passes when everything agrees: " .. config:summary() .. "\n  " .. failedLines(config))
policy.MaxClaimsPerPlayer = 9
local client = {}
for key, value in pairs(SandboxVars.KIPN) do client[key] = value end
client.VehicleAllowNonOwnerTow = true
config = runServer("config", { args = { clientSandbox = client } })
expect(config.counts.FAIL == 2, "config catches a stale policy and a client that disagrees: " .. config:summary() .. "\n  " .. failedLines(config))
policy.MaxClaimsPerPlayer = 5
expect(runServer("config").counts.SKIP == 1, "config skips the client comparison when the client sent nothing")

-- Toggles: refusals are checked, and every switch is put back.
local toggles = runServer("toggles")
expect(toggles.counts.FAIL == 0 and toggles.counts.PASS == 9, "toggles against a mod that honours the switches: " .. toggles:summary() .. "\n  " .. failedLines(toggles))
expect(artifactCfg.Registration.Enabled == true and artifactCfg.Registration.VehicleEnabled == true and artifactCfg.Claim.VehicleEnabled == true,
    "toggles restores every switch")
VA.ValidateVehicleClaim = function() return false, "stand-in ignores the switch" end
toggles = runServer("toggles")
expect(toggles.counts.FAIL == 1, "toggles catches a title check that ignores the claims switch: " .. toggles:summary())
VA.CreateVehicleRegistration = function() error("mod raised") end
local raised = pcall(runServer, "toggles")
expect(not raised and artifactCfg.Registration.VehicleEnabled == true, "toggles restores the switch even when the mod raises")

-- Claim limit: a stand-in claim reaches it, and the limit and your claims
-- are put back.
local quota = runServer("quota")
expect(quota.counts.FAIL == 0 and quota.counts.PASS >= 4 and quota.counts.SKIP == 1, "quota with no claims and no vehicle: " .. quota:summary() .. "\n  " .. failedLines(quota))
expect(policy.MaxClaimsPerPlayer == 5 and next(claims) == nil, "quota restores the limit and removes its stand-in claim")
CS.CheckMaxClaimsForType = function() return true end
quota = runServer("quota")
expect(quota.counts.FAIL == 1 and policy.MaxClaimsPerPlayer == 5 and next(claims) == nil, "quota catches a limit that is never enforced: " .. quota:summary())

-- Resync: the wiped metadata comes back, or the tester writes it back
-- itself; the temporary claim is released either way.
local function lastDelivered() return delivered and delivered.text or "" end
local function tick() for _, fn in ipairs(handlers.OnTick or {}) do fn() end end
T.RunServer(tester, "resync", { vehicleId = 8 })
expect(lastDelivered():find("waiting up to 90 seconds", 1, true) ~= nil, "resync tells you it is waiting: " .. lastDelivered())
expect(car.modData.KIPNVehicleClaimId == nil, "resync wiped the metadata")
tick()
expect(lastDelivered():find("Metadata restored", 1, true) == nil, "resync keeps waiting while the metadata is missing")
local temporary
for _, c in pairs(claims) do if c.active then temporary = c end end
CS.SyncVehicleOwnershipMetadata(car, temporary)
now = now + 5000
tick()
expect(lastDelivered():find("PASS: Metadata restored 5.0 seconds after the wipe", 1, true) ~= nil and lastDelivered():find("FAIL", 1, true) == nil,
    "resync passes once the mod writes the metadata back:\n" .. lastDelivered())
expect(temporary and temporary.active == false and car.modData.KIPNVehicleClaimId ~= nil, "resync released its temporary claim")
CS.SyncVehicleOwnershipMetadata(car, nil)
T.RunServer(tester, "resync", { vehicleId = 8 })
now = now + 91000
tick()
expect(lastDelivered():find("FAIL: Metadata was still missing 90 seconds after the wipe", 1, true) ~= nil,
    "resync fails when the metadata never comes back:\n" .. lastDelivered())
local stillActive = false
for _, c in pairs(claims) do stillActive = stillActive or c.active end
expect(not stillActive and car.modData.KIPNVehicleClaimId ~= nil, "a failed resync writes the metadata back and releases its claim")

if failures == 0 then print("vehsvc_checks: all checks passed") else print("vehsvc_checks: " .. failures .. " failure(s)") os.exit(1) end
