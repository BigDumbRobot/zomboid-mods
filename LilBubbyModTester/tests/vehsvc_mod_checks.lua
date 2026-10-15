-- Offline checks of the COMPUTER Vehicle Claims suite against the real
-- KIPNVehicleServices mod: its data files, and its client Lua run under
-- the suite's own client tests with engine stand-ins.
-- Run from this Workshop project directory: lua tests/vehsvc_mod_checks.lua
--
-- It loads the Steam Workshop subscription (3791786297) when there is one,
-- otherwise the local project ~/Zomboid/Workshop/KIPNVehicleServices.
local lua = "Contents/mods/LilBubbyModTester/42/media/lua/"
local HOME = os.getenv("HOME") or ""
local WORKSHOP = HOME .. "/Library/Application Support/Steam/steamapps/workshop/content/108600/3791786297/mods/KIPNVehicleServices/42/media/"
local LOCAL = HOME .. "/Zomboid/Workshop/KIPNVehicleServices/Contents/mods/KIPNVehicleServices/42/media/"

local function exists(path)
    local file = io.open(path, "r")
    if file then file:close() end
    return file ~= nil
end
local MOD = exists(WORKSHOP .. "sandbox-options.txt") and WORKSHOP or LOCAL
print("vehsvc_mod_checks: testing " .. (MOD == WORKSHOP and "the Workshop subscription" or "the local project") .. " (" .. MOD .. ")")

local function read(path) return assert(io.open(path, "r"), "missing " .. path):read("a") end

local out = print
local failures = 0
local function expect(condition, message)
    if not condition then
        failures = failures + 1
        out("FAIL: " .. message)
    end
end

------------------------------------------------------------
-- DATA FILES AGAINST THE SUITE'S EXPECTATIONS
------------------------------------------------------------

_G.isClient = function() return false end
_G.isServer = function() return false end
dofile(lua .. "shared/VehSvcTest_Checks.lua")
local T = VehSvcTest

-- sandbox-options.txt: every option, its default, and its translation.
local sandboxFile = read(MOD .. "sandbox-options.txt")
local options = {}
for name, body in sandboxFile:gmatch("option KIPN%.(%w+)%s*(%b{})") do
    local default = body:match("default%s*=%s*([%w%.]+)")
    if default == "true" then default = true elseif default == "false" then default = false else default = tonumber(default) end
    options[name] = default
end
local translations = read(MOD .. "lua/shared/Translate/EN/Sandbox.json")
for _, key in ipairs(T.SANDBOX_KEYS) do
    expect(options[key] ~= nil, "sandbox-options.txt has no option " .. key)
    expect(options[key] == T.SANDBOX_DEFAULTS[key], key .. " ships as " .. tostring(options[key]) .. ", the suite expects " .. tostring(T.SANDBOX_DEFAULTS[key]))
    expect(translations:find('"Sandbox_KIPN_' .. key .. '"', 1, true) ~= nil, "Sandbox.json has no name for " .. key)
    expect(translations:find('"Sandbox_KIPN_' .. key .. '_tooltip"', 1, true) ~= nil, "Sandbox.json has no tooltip for " .. key)
end
for name in pairs(options) do
    local listed = false
    for _, key in ipairs(T.SANDBOX_KEYS) do listed = listed or key == name end
    expect(listed, "the suite does not check sandbox option " .. name)
end

-- KIPN_VehClaimConfig.lua: the policy defaults match the sandbox defaults.
local claimConfig = read(MOD .. "lua/server/config/KIPN_VehClaimConfig.lua")
for sandboxKey, field in pairs(T.SANDBOX_TO_CLAIM_CONFIG) do
    local value = claimConfig:match("\n%s*" .. field .. "%s*=%s*([%w%.]+)")
    if value == "true" then value = true elseif value == "false" then value = false else value = tonumber(value) end
    expect(value == options[sandboxKey], "KIPN_VehClaimConfig " .. field .. " = " .. tostring(value) .. " but " .. sandboxKey .. " ships as " .. tostring(options[sandboxKey]))
end

-- Item and recipe scripts.
local items = read(MOD .. "scripts/KIPN_VehicleArtifactItems.txt")
for _, want in ipairs(T.ITEM_SCRIPTS) do
    local short = want.type:match("%.(.+)$")
    local body = items:match("item%s+" .. short .. "%s*(%b{})")
    expect(body ~= nil, "no item script " .. short)
    if body then
        expect(body:match("DisplayName%s*=%s*([^,\n]+)") == want.name, short .. " display name")
        expect(body:find("kipn:" .. want.tag, 1, true) ~= nil, short .. " tag kipn:" .. want.tag)
    end
end
local recipes = read(MOD .. "scripts/KIPN_VehicleArtifactRecipes.txt")
expect(recipes:find("craftRecipe " .. T.RECIPE, 1, true) ~= nil, "no recipe " .. T.RECIPE)
for _, material in ipairs(T.RECIPE_INPUTS) do
    local short = material[1]:match("%.(.+)$")
    local found = recipes:find("item " .. material[2] .. " %[Base%." .. short .. "%]")
        or (short == "Pen" and recipes:find("item " .. material[2] .. " tags%[base:pen"))
    expect(found ~= nil, "recipe input " .. material[2] .. " x " .. material[1])
end
expect(recipes:find("item 1 " .. T.REGISTRATION_ITEM, 1, true) ~= nil, "recipe output")
for _, material in ipairs(T.RECIPE_MATERIALS) do
    local listed = false
    for _, input in ipairs(T.RECIPE_INPUTS) do listed = listed or input[1] == material[1] end
    expect(listed, "materials handed out include " .. material[1] .. ", which the recipe does not take")
end

-- Server registrations in KIPN_VehicleServicesInit.lua.
local init = read(MOD .. "lua/server/KIPN_VehicleServicesInit.lua")
for id, roles in pairs(T.PERMISSIONS) do
    local body = init:match('RegisterPermission%("' .. id:gsub("%.", "%%.") .. '",%s*(%b{})')
    expect(body ~= nil, "init does not register " .. id)
    if body then
        local grants = body:find("PLAYER_ADMIN", 1, true) and { PLAYER = true, ADMIN = true } or {}
        for role in (body:match("grantToRoles%s*=%s*(%b{})") or ""):gmatch('"(%u+)"') do grants[role] = true end
        for role, granted in pairs(roles) do expect((grants[role] == true) == granted, id .. " grant to " .. role) end
    end
end
for _, capability in ipairs(T.ZONE_CAPABILITIES) do
    expect(init:find('%["' .. capability:gsub("%.", "%%.") .. '"%]%s*=%s*true') ~= nil, "dealership capability " .. capability)
end
for id, want in pairs(T.APPS) do
    local body = init:match('R%("' .. id .. '",%s*(%b{})')
    expect(body and body:find('screen = "' .. want.screen .. '"', 1, true), id .. " screen")
    expect(body and body:find('"' .. want.permission .. '"', 1, true), id .. " permission")
    if want.classification then expect(body and body:find('"' .. want.classification .. '"', 1, true), id .. " classification") end
end
for _, dependency in ipairs(T.SERVICE_DEPENDENCIES) do
    expect(init:find('"' .. dependency .. '"', 1, true) ~= nil, "service dependency " .. dependency)
end
expect(init:find("order = 610", 1, true) ~= nil, "service order 610")

-- The enforcement wraps exactly the commands the suite checks.
local enforcement = read(MOD .. "lua/server/KIPN_VehicleEnforcement.lua")
local wrapped = {}
for name in (enforcement:match("cmdsToIntercept%s*=%s*(%b{})") or ""):gmatch('"(%w+)"') do wrapped[#wrapped + 1] = name end
expect(table.concat(wrapped, ",") == table.concat(T.INTERCEPTED_COMMANDS, ","), "intercepted commands: " .. table.concat(wrapped, ","))

-- The claim menu overrides exactly the functions the suite checks.
local claimMenu = read(MOD .. "lua/client/KIPN_VehicleClaimMenu.lua")
local overrides = {}
for key, name in claimMenu:gmatch("KIPN%.(o%w+)%s*=%s*ISVehicleMenu%.(%w+)") do overrides[#overrides + 1] = name .. "=" .. key end
local clientSource = read(lua .. "client/VehSvcTest_Client.lua")
local listed = {}
for name, key in (clientSource:match("local WRAPPED = (%b{})") or ""):gmatch('{ "(%w+)", "(o%w+)" }') do listed[#listed + 1] = name .. "=" .. key end
table.sort(overrides)
table.sort(listed)
expect(#overrides == 11 and table.concat(overrides, ",") == table.concat(listed, ","), "menu overrides " .. table.concat(overrides, ",") .. " vs suite " .. table.concat(listed, ","))

------------------------------------------------------------
-- ENGINE STAND-INS FOR THE CLIENT FILES
------------------------------------------------------------

local function list(values)
    return { size = function() return #values end, get = function(_, i) return values[i + 1] end }
end

local handlers = {}
_G.Events = setmetatable({}, { __index = function(t, name)
    local e = { Add = function(fn) handlers[name] = handlers[name] or {}; table.insert(handlers[name], fn) end }
    rawset(t, name, e)
    return e
end })
_G.isClient = function() return true end
_G.isServer = function() return false end
_G.isSinglePlayer = function() return false end
_G.require = function() end
_G.print = function() end
local clock = 1000
_G.getTimestampMs = function() return clock end
_G.getText = function(key) return key end
_G.getTexture = function() return {} end
_G.getCore = function() return { getScreenWidth = function() return 1920 end, getScreenHeight = function() return 1080 end } end
_G.getPlayerScreenLeft = function() return 0 end
_G.getPlayerScreenTop = function() return 0 end
_G.getPlayerScreenWidth = function() return 1920 end
_G.getPlayerScreenHeight = function() return 1080 end
_G.getSoundManager = function() return { playUISound = function() end } end
_G.setJoypadFocus = function() end
_G.ZombRand = function(a) return a end
local clientSent = {}
_G.sendClientCommand = function(...) clientSent[#clientSent + 1] = { ... } end
_G.SandboxVars = { KIPN = {} }
for key, value in pairs(T.SANDBOX_DEFAULTS) do SandboxVars.KIPN[key] = value end
_G.HaloTextHelper = { addText = function() end }
_G.instanceof = function() return false end

local function inventory(types)
    local inv = {}
    local items = {}
    for _, t in ipairs(types or {}) do items[#items + 1] = { getFullType = function() return t end } end
    function inv:getItems() return list(items) end
    function inv:containsTypeRecurse(t) for _, item in ipairs(items) do if item:getFullType() == t then return true end end return false end
    function inv:contains(t) return self:containsTypeRecurse(t) end
    return inv
end

local halos = {}
local player = { inv = inventory({}) }
function player:getPlayerNum() return 0 end
function player:getSteamID() return "76561190000000001" end
function player:getUsername() return "Tester" end
function player:getInventory() return self.inv end
function player:isTimedActionInstant() return false end
function player:getVehicle() return nil end
function player:getNearVehicle() return nil end
function player:setHaloNote(text) halos[#halos + 1] = text end
function player:Say(text) halos[#halos + 1] = text end
function player:getX() return 0 end
function player:getY() return 0 end
_G.getSpecificPlayer = function() return player end
_G.getPlayer = function() return player end
_G.getNumActivePlayers = function() return 1 end

local square = { getX = function() return 3 end, getY = function() return 4 end, getZ = function() return 0 end }
local vehicle = { modData = {} }
function vehicle:getId() return 7 end
function vehicle:getSquare() return square end
function vehicle:getModData() return self.modData end
function vehicle:isRemovedFromWorld() return false end
function vehicle:getVehicleTowedBy() return nil end
function vehicle:getVehicleTowing() return nil end
function vehicle:getPartCount() return 0 end
function vehicle:getX() return 0 end
function vehicle:getY() return 0 end
function vehicle:getScript() return { getName = function() return "TestCar" end } end
_G.getCell = function() return { getVehicles = function() return list({ vehicle }) end } end

-- Vanilla stand-ins the mod saves as KIPN.o* before overriding.
_G.ISVehicleMenu = {}
for _, name in ipairs({ "FillMenuOutsideVehicle", "onEnter", "onEnter2", "onShowSeatUI", "onMechanic", "onOpenDoor",
    "onCloseDoor", "onLockDoor", "onUnlockDoor", "showRadialMenuOutside", "showRadialMenu" }) do
    ISVehicleMenu[name] = function() end
end
_G.ISToolTip = { new = function() return { initialise = function() end } end }
_G.luautils = { walkAdj = function() return true end }
_G.ISTimedActionQueue = { add = function() end }
_G.ISBaseTimedAction = {}
function ISBaseTimedAction:derive(typeName)
    local o = setmetatable({}, { __index = self })
    o.Type = typeName
    return o
end
function ISBaseTimedAction.new(class, character)
    local o = setmetatable({}, { __index = class })
    o.character = character
    return o
end
function ISBaseTimedAction.perform() end
function ISBaseTimedAction.stop() end
_G.ISPanel = { initialise = function() end, update = function() end, prerender = function() end }

local function color() return { r = 1, g = 1, b = 1, a = 1 } end
_G.KIPN = {
    Shared = {
        Commands = { CLAIM_VEHICLE = "claimVehicle", ISSUE_VEHICLE_CLAIM = "issueVehicleClaim", RELEASE_CLAIM = "releaseClaim",
            GET_MY_CLAIMS = "getMyClaims", SERVER_RESPONSE = "serverResponse" },
        ResponseEvents = { ERROR = "error", MY_CLAIMS_DATA = "myClaimsData", VEHICLE_CLAIM_ARTIFACT_ISSUED = "vehicleClaimArtifactIssued",
            VEHICLE_CLAIM_SUCCESSFUL = "vehicleClaimSuccessful" },
    },
    Logger = { Info = function() end, Warn = function() end, Error = function() end },
    UI = {
        CreateScreen = function() return {} end,
        CreateConfirmDialog = function() end,
        CreateButton = function() return { setX = function() end, setY = function() end, setWidth = function() end,
            setVisible = function() end, bringToTop = function() end } end,
        PickRandomFlavorMessage = function() return "Filing paperwork..." end,
        SetupScreen = function() end, EnableScroll = function() end,
        Theme = { dimText = color(), text = color(), accent = color(), warning = color(), fontBody = 0 },
    },
    ClaimCraftSound = { Start = function() end, Stop = function() end, Complete = function() end, Fail = function() end },
}
_G.getPlayerRadialMenu = function() error("the radial check should stand in its own menu") end

-- Tester stand-ins: only what VehSvcTest_Client.lua touches at load.
_G.LilBubbyShowcase = { Register = function() end, Report = function() end, NewMenu = function() end }
_G.LilBubbyCraft = {}
_G.LilBubbyCountdown = nil

------------------------------------------------------------
-- THE REAL CLIENT FILES
------------------------------------------------------------

local modLua = MOD .. "lua/client/"
dofile(modLua .. "KIPN_VehicleBridge.lua")
dofile(modLua .. "TimedActions/KIPN_VehicleClaimAction.lua")
dofile(modLua .. "KIPN_VehicleClaimMenu.lua")
dofile(modLua .. "KIPN_VehicleRegistration.lua")
dofile(modLua .. "KIPN_VehicleRecords.lua")
dofile(lua .. "client/VehSvcTest_Client.lua")
local C = T.ClientTests

local function run(id, target)
    local r = T.NewReport(id)
    local ok, err = pcall(C[id], r, player, target)
    if not ok then r:fail("ERROR: " .. tostring(err)) end
    return r
end
local function failed(r)
    local lines = {}
    for _, line in ipairs(r.lines) do if line:find("^FAIL") then lines[#lines + 1] = line end end
    return table.concat(lines, "\n  ")
end

for _, id in ipairs({ "c_modules", "c_policy", "c_radial", "c_dialogs", "c_registration", "c_records" }) do
    local r = run(id)
    expect(r.counts.FAIL == 0 and r.counts.PASS > 0, id .. " against the real mod: " .. r:summary() .. "\n  " .. failed(r))
end
for _, id in ipairs({ "c_action", "c_bridge" }) do
    local r = run(id, vehicle)
    expect(r.counts.FAIL == 0 and r.counts.PASS > 0, id .. " against the real mod: " .. r:summary() .. "\n  " .. failed(r))
end

-- The checks put back everything they swap.
expect(SandboxVars.KIPN.VehicleNonOwnerNoAccess == false and SandboxVars.KIPN.VehicleAllowNonOwnerMechanics == false
    and SandboxVars.KIPN.VehicleClaimCraftSeconds == 10, "client checks restore SandboxVars.KIPN")
expect(getTimestampMs() == clock and getSpecificPlayer(0) == player and KIPN.Client == nil, "client checks restore the globals they swap")
expect(#clientSent == 0, "client checks sent " .. #clientSent .. " real command(s)")

-- A broken mod is caught: a lock gate that lets non-owners through.
do
    local original = ISVehicleMenu.onLockDoor
    ISVehicleMenu.onLockDoor = function(playerObj, part) return KIPN.oVehicleMenuOnLockDoor(playerObj, part) end
    local r = run("c_policy")
    expect(r.counts.FAIL > 0, "c_policy catches a lock gate open to non-owners")
    ISVehicleMenu.onLockDoor = original
    -- And a Records screen that lists every claim type.
    local receive = KIPN_VehicleRecords.receiveResponse
    KIPN_VehicleRecords.receiveResponse = function(self, event, data)
        if event == KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA then self.properties, self.loading = data, false return end
        return receive(self, event, data)
    end
    r = run("c_records")
    expect(r.counts.FAIL > 0, "c_records catches non-vehicle claims in the list")
    KIPN_VehicleRecords.receiveResponse = receive
end

------------------------------------------------------------
-- SERVER REPLY LISTENERS (not driven in game: a fake reply would
-- also reach KIPN's own terminal listeners)
------------------------------------------------------------

local function reply(event, data)
    for _, fn in ipairs(handlers.OnServerCommand or {}) do fn("KIPN", "serverResponse", { event = event, data = data }) end
end
local function heard(list, text)
    for _, line in ipairs(list) do if line:find(text, 1, true) then return true end end
    return false
end

local said = {}
local claimer = { Say = function(_, text) said[#said + 1] = text end }
local action = KIPN_VehicleClaimAction:new(player, vehicle)
action.character = claimer
action:perform()
reply("vehicleClaimSuccessful", {})
expect(heard(said, "Vehicle claim successful."), "a successful claim is announced")
said = {}
reply("vehicleClaimSuccessful", {})
expect(#said == 0, "a second success with no claim pending says nothing")
action:perform()
reply("error", { command = "releaseClaim", reason = "unrelated" })
expect(#said == 0, "an error for another command is not taken as the claim's")
reply("error", { command = "claimVehicle", reason = "Vehicle is already claimed." })
expect(heard(said, "Vehicle claim failed: Vehicle is already claimed."), "a refused claim gives the server's reason")

-- The right-click release reports its outcome, and forgets a stale one.
local releaser = { said = {} }
function releaser:Say(text) self.said[#self.said + 1] = text end
function releaser:setHaloNote(text) self.said[#self.said + 1] = text end
local owned = { modData = { KIPNVehicleClaimId = "claim-1", KIPNVehicleOwnerSteamId = player:getSteamID(), KIPNVehicleOwnerUsername = "Tester" } }
function owned:getModData() return self.modData end
local dialog
KIPN.UI.CreateConfirmDialog = function(...) dialog = { ... } end
local context = { options = {} }
function context:addOption(name, target, onSelect, ...) local o = { name = name, target = target, onSelect = onSelect, params = { ... } }; self.options[#self.options + 1] = o; return o end
function context:getOptionFromName(name) for _, o in ipairs(self.options) do if o.name == name then return o end end end
owned.getSquare = function() return nil end
owned.isRemovedFromWorld = function() return false end
owned.getVehicleTowedBy = function() return nil end
owned.getVehicleTowing = function() return nil end
ISVehicleMenu.FillMenuOutsideVehicle(0, context, owned, false)
local option = context:getOptionFromName("Release Vehicle Ownership (KIPN)")
expect(option ~= nil, "release option on an owned vehicle")
if option then
    option.onSelect(option.target, option.params[1])
    dialog[8](releaser, { internal = "YES" }, dialog[10])
    reply("myClaimsData", {})
    expect(heard(releaser.said, "Vehicle ownership released."), "a release is announced when the claims list comes back")
    releaser.said = {}
    dialog[8](releaser, { internal = "YES" }, dialog[10])
    reply("error", { message = "Not your claim." })
    expect(heard(releaser.said, "Vehicle release failed: Not your claim."), "a refused release gives the server's reason")
    releaser.said = {}
    dialog[8](releaser, { internal = "YES" }, dialog[10])
    clock = clock + 9000
    reply("myClaimsData", {})
    expect(not heard(releaser.said, "released."), "a claims list 9 seconds later is not taken as the release's answer")
end

if failures == 0 then out("vehsvc_mod_checks: all checks passed") else out("vehsvc_mod_checks: " .. failures .. " failure(s)") os.exit(1) end
