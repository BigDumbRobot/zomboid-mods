require "LilBubbyShowcase"
-- COMPUTER Vehicle Claims tests: client half. Builds the right-click
-- menu, runs the client checks locally and shows every result. Client
-- gate checks swap the mod's saved vanilla callbacks (KIPN.o*) for
-- recorders, so nothing is actually entered, opened or locked.
require "VehSvcTest_Checks"
require "LilBubbyCraft"

local T = VehSvcTest
local ClientTests = {}
T.ClientTests = ClientTests

local ROOT = "lilBubby's Big ol Mod Tester"
local CLAIM_OPTION, RELEASE_OPTION = "Claim Vehicle (KIPN)", "Release Vehicle Ownership (KIPN)"
local lastResults, queued = {}, {}

local HELP = table.concat({
    "Every connected player can run every one of these tests. Results appear here and in the server log.",
    "Target vehicle: the one you are sitting in, otherwise the nearest within 12 tiles. It is shown at the top of the menu.",
    "Server tests drive the real mod code: the CLAIM_VEHICLE, ISSUE_VEHICLE_CLAIM and RELEASE_CLAIM handlers, the artifact engine and the claim store.",
    "Quick start: Run every automatic check. Then park a vehicle inside a dealership zone and run Full flow.",
    "Non-owner tests: 'Give this vehicle to the test owner' claims it for a stand-in owner, so you become a non-owner. Try the real right-click menu, entering, doors and mechanics, then run Client features. Remove the test owner when done.",
    "Seat ejection: pick the test, then get into an unclaimed vehicle within 30 seconds. The test gives it to the test owner and waits for the server to eject you.",
    "Real player flow: craft a form (Give me materials), process it at a dealership computer's Vehicle Registration screen, right-click the vehicle > Claim Vehicle (KIPN), check Vehicle Records, then right-click > Release Vehicle Ownership (KIPN).",
    "Setup checks, the on/off switch check and the claim limit check change the server's settings for a moment and put them back straight away.",
    "Client features use Lua-only stand-ins (a vehicle, dialogs, the radial menu, the two terminal screens), so nothing is entered, opened, claimed, released or sent.",
    "Vehicle results end with a Client view line: whether your client sees the same owner as the server.",
    "PASS: behaved as documented. FAIL: did not. BLOCKED: the test could not start (reason given). SKIP: not applicable here. INFO: context.",
    "Clean up removes items and claims made by these tests, not claims made through the normal menu.",
}, "\n\n")

------------------------------------------------------------
-- DISPLAY
------------------------------------------------------------

local function show(player, text)
    LilBubbyShowcase.Report(player, "vehicle", text)
end

local function submenu(context, label)
    local existing = context:getOptionFromName(label)
    if existing and existing.subOption then return context:getSubMenu(existing.subOption) end
    local option = context:addOption(label)
    local menu = LilBubbyShowcase.NewMenu()
    context:addSubMenu(option, menu)
    return menu
end

------------------------------------------------------------
-- TARGET VEHICLE AND OWNERSHIP AS THIS CLIENT SEES IT
------------------------------------------------------------

-- The cell's vehicles are a HashSet in Build 42: walk them with an
-- iterator (get(i) is unavailable). Lists with get(i) still work.
local function eachVehicle(visit)
    local vehicles = getCell() and getCell():getVehicles()
    if not vehicles then return end
    if vehicles.iterator then
        local iterator = vehicles:iterator()
        while iterator:hasNext() do visit(iterator:next()) end
        return
    end
    for i = 0, vehicles:size() - 1 do visit(vehicles:get(i)) end
end

local function findVehicle(id)
    id = tonumber(id)
    if type(getVehicleById) == "function" then
        local ok, vehicle = pcall(getVehicleById, id)
        if ok and vehicle then return vehicle end
    end
    local found
    eachVehicle(function(vehicle) if vehicle:getId() == id then found = vehicle end end)
    return found
end

local function targetVehicle(player)
    local vehicle = player:getVehicle()
    if vehicle then return vehicle end
    local best, bestDistance = nil, T.MAX_VEHICLE_DISTANCE
    eachVehicle(function(candidate)
        local dx, dy = candidate:getX() - player:getX(), candidate:getY() - player:getY()
        local distance = math.sqrt(dx * dx + dy * dy)
        if distance <= bestDistance then best, bestDistance = candidate, distance end
    end)
    return best
end

local function vehicleName(vehicle)
    local name = "vehicle"
    pcall(function() name = vehicle:getScript():getName() end)
    return name .. " #" .. tostring(vehicle:getId())
end

-- Returns the synchronized ownership metadata and whether this player
-- counts as its owner (no claim counts as owner-level access).
-- The key the running KIPN files this player's claims under: the server
-- account on current KIPN, the Steam ID on older releases.
local function ownerKey(player)
    if KIPN and KIPN.Shared and KIPN.Shared.IsAccountId then return tostring(KIPN.Shared.GetPlayerId(player)) end
    return tostring(player:getSteamID() or "")
end

local function clientOwnership(player, vehicle)
    local md = vehicle:getModData()
    if not md.KIPNVehicleClaimId or not md.KIPNVehicleOwnerSteamId then return nil, true end
    local mine = ownerKey(player) == tostring(md.KIPNVehicleOwnerSteamId)
        or tostring(player:getUsername()) == tostring(md.KIPNVehicleOwnerUsername)
    return md, mine
end

local function ownershipText(player, vehicle)
    local md, mine = clientOwnership(player, vehicle)
    if not md then return "unclaimed" end
    return mine and "yours" or ("owned by " .. tostring(md.KIPNVehicleOwnerUsername))
end

local function inDealershipCache(vehicle)
    local cache = KIPN and KIPN.Client and KIPN.Client.ZoneMapCache
    local square = vehicle:getSquare()
    if not cache or type(cache.zones) ~= "table" or not square then return false, nil end
    local x, y, z = square:getX(), square:getY(), square:getZ()
    for id, zone in pairs(cache.zones) do
        local g = type(zone) == "table" and zone.geometry
        if zone.type == "dealership" and type(g) == "table" then
            local x1, y1, x2, y2 = tonumber(g.x1), tonumber(g.y1), tonumber(g.x2), tonumber(g.y2)
            local z1 = tonumber(g.z1) or 0
            local z2 = tonumber(g.z2) or z1
            if x1 and y1 and x2 and y2 and x >= math.min(x1, x2) and x <= math.max(x1, x2)
                and y >= math.min(y1, y2) and y <= math.max(y1, y2) and z >= math.min(z1, z2) and z <= math.max(z1, z2) then
                return true, zone.id or id
            end
        end
    end
    return false, nil
end

local function clientSandbox()
    local sandbox, values = SandboxVars and SandboxVars.KIPN or {}, {}
    for _, key in ipairs(T.SANDBOX_KEYS) do values[key] = sandbox[key] end
    return values
end

local function modLoaded()
    return KIPN_VehicleClaimAction ~= nil and KIPN and KIPN.oFillMenuOutsideVehicle ~= nil
end

------------------------------------------------------------
-- STUBS AND FAKES
------------------------------------------------------------

-- Replaces the mod's saved vanilla callbacks with counters for the
-- duration of fn, then always restores them.
local function withStubs(keys, fn)
    local saved, calls = {}, {}
    for _, key in ipairs(keys) do
        saved[key] = KIPN[key]
        KIPN[key] = function() calls[key] = (calls[key] or 0) + 1 end
    end
    local ok, err = pcall(fn, calls)
    for _, key in ipairs(keys) do KIPN[key] = saved[key] end
    if not ok then error(err, 0) end
end

local function passesThrough(key, call)
    local passed = false
    withStubs({ key }, function(calls)
        call()
        passed = (calls[key] or 0) > 0
    end)
    return passed
end

local function fakeContext()
    local context = { options = {} }
    function context:addOption(name, target, onSelect, ...)
        local option = { name = name, target = target, onSelect = onSelect, params = { ... } }
        self.options[#self.options + 1] = option
        return option
    end
    function context:addOptionOnTop(...) return self:addOption(...) end
    function context:getOptionFromName(name)
        for _, option in ipairs(self.options) do if option.name == name then return option end end
    end
    return context
end

local function menuOptions(player, vehicle)
    local context, passed = fakeContext(), false
    withStubs({ "oFillMenuOutsideVehicle" }, function(calls)
        ISVehicleMenu.FillMenuOutsideVehicle(player:getPlayerNum(), context, vehicle, false)
        passed = (calls.oFillMenuOutsideVehicle or 0) > 0
    end)
    return context, passed
end

-- Sets tbl[key] = value for each field during fn, then always puts the
-- old values back (including nil).
local function withFields(tbl, fields, fn)
    local saved = {}
    for key, value in pairs(fields) do
        saved[#saved + 1] = { key = key, value = tbl[key] }
        tbl[key] = value
    end
    local ok, err = pcall(fn)
    for i = #saved, 1, -1 do tbl[saved[i].key] = saved[i].value end
    if not ok then error(err, 0) end
end

local FAKE_CLAIM_ID = "lilbubby-fake-claim"
local STRANGER = { id = T.TEST_OWNER_ID, name = T.TEST_OWNER_NAME }
local function me(player) return { id = ownerKey(player), name = player:getUsername() } end

-- A vehicle that exists only in Lua, owned by owner ({ id, name }) or
-- unclaimed. vehicle.useable is the part the player stands at.
local function fakeVehicle(owner)
    local md = {}
    if owner then
        md.KIPNVehicleClaimId, md.KIPNVehicleOwnerSteamId, md.KIPNVehicleOwnerUsername = FAKE_CLAIM_ID, owner.id, owner.name
    end
    local vehicle = { parts = {}, square = nil, towed = false, transmitted = 0 }
    function vehicle:getModData() return md end
    function vehicle:getUseablePart() return self.useable end
    function vehicle:getId() return -1 end
    function vehicle:getSquare() return self.square end
    function vehicle:isRemovedFromWorld() return false end
    function vehicle:getVehicleTowedBy() return self.towed and {} or nil end
    function vehicle:getVehicleTowing() return nil end
    function vehicle:transmitModData() self.transmitted = self.transmitted + 1 end
    local function part(id, locked, open)
        local door = {}
        function door:isLocked() return locked end
        function door:isOpen() return open == true end
        local p = {}
        function p:getVehicle() return vehicle end
        function p:getId() return id end
        function p:getDoor() return door end
        function p:getInventoryItem() return {} end
        return p
    end
    vehicle.parts.unlocked = part("DoorFrontLeft", false)
    vehicle.parts.locked = part("DoorFrontRight", true)
    vehicle.parts.open = part("DoorRearLeft", false, true)
    vehicle.parts.hood = part("EngineDoor", false)
    return vehicle
end

-- An inventory that exists only in Lua. Entries are full item types;
-- a nested table is a bag holding those entries.
local function fakeInventory(entries)
    local inventory, items = {}, {}
    for _, entry in ipairs(entries or {}) do
        local item = {}
        if type(entry) == "table" then
            local inner = fakeInventory(entry)
            function item:getFullType() return "Base.Bag_Schoolbag" end
            function item:getInventory() return inner end
        else
            function item:getFullType() return entry end
        end
        items[#items + 1] = item
    end
    local function matches(fullType, wanted) return fullType == wanted or string.match(fullType, "%.(.+)$") == wanted end
    function inventory:getItems() return { size = function() return #items end, get = function(_, i) return items[i + 1] end } end
    function inventory:contains(wanted)
        for _, item in ipairs(items) do if matches(item:getFullType(), wanted) then return true end end
        return false
    end
    function inventory:containsTypeRecurse(wanted)
        for _, item in ipairs(items) do
            if matches(item:getFullType(), wanted) then return true end
            if item.getInventory and item:getInventory():containsTypeRecurse(wanted) then return true end
        end
        return false
    end
    return inventory
end

-- A stand-in for the player with the same identity. It records what the
-- mod says to it, and carries only what it is given.
local function fakePlayer(player, carries, vehicle)
    local fake, inventory = { said = {}, halos = {} }, fakeInventory(carries)
    function fake:getSteamID() return player:getSteamID() end
    function fake:getUsername() return player:getUsername() end
    function fake:getPlayerNum() return player:getPlayerNum() end
    function fake:getVehicle() return vehicle end
    function fake:getInventory() return inventory end
    function fake:isTimedActionInstant() return false end
    function fake:Say(text) self.said[#self.said + 1] = tostring(text) end
    function fake:setHaloNote(text) self.halos[#self.halos + 1] = tostring(text) end
    return fake
end

local function heard(fake, text)
    for _, list in ipairs({ fake.said, fake.halos }) do
        for _, line in ipairs(list) do if string.find(line, text, 1, true) then return true end end
    end
    return false
end

local function fakeRadialMenu()
    local menu = { slices = {}, shown = false, sounds = {} }
    function menu:isReallyVisible() return false end
    function menu:clear() self.slices = {} end
    function menu:addSlice(text, _, callback, a, b) self.slices[#self.slices + 1] = { text = text, callback = callback, a = a, b = b } end
    function menu:slice(text)
        for _, slice in ipairs(self.slices) do if slice.text == text then return slice end end
    end
    function menu:setX() end
    function menu:setY() end
    function menu:getWidth() return 200 end
    function menu:getHeight() return 200 end
    function menu:addToUIManager() self.shown = true end
    function menu:undisplay() self.shown = false end
    return menu
end

-- The policies the client checks run under: the live sandbox, then the
-- two forced ones.
local function policies()
    local list = { { name = "live sandbox", values = {} } }
    for _, forced in ipairs(T.FORCED_POLICIES) do list[#list + 1] = forced end
    return list
end

local function describePolicy(policy)
    return "mechanics=" .. tostring(policy.mechanics) .. " doors=" .. tostring(policy.openUnlockedDoors)
        .. " tow=" .. tostring(policy.tow) .. " noAccess=" .. tostring(policy.noAccess)
end

local function realDoorParts(vehicle)
    local door, hood
    for i = 0, vehicle:getPartCount() - 1 do
        local part = vehicle:getPartByIndex(i)
        if part:getDoor() and part:getId() ~= "EngineDoor" and not door then door = part end
        if part:getId() == "EngineDoor" then hood = part end
    end
    return door, hood
end

local function doorUnlocked(part)
    return part ~= nil and part:getDoor() ~= nil and part:getInventoryItem() ~= nil and not part:getDoor():isLocked()
end

------------------------------------------------------------
-- CLIENT TESTS
------------------------------------------------------------

local WRAPPED = {
    { "FillMenuOutsideVehicle", "oFillMenuOutsideVehicle" },
    { "onEnter", "oVehicleMenuOnEnter" },
    { "onEnter2", "oVehicleMenuOnEnter2" },
    { "onShowSeatUI", "oVehicleMenuOnShowSeatUI" },
    { "onMechanic", "oVehicleMenuOnMechanic" },
    { "onOpenDoor", "oVehicleMenuOnOpenDoor" },
    { "onCloseDoor", "oVehicleMenuOnCloseDoor" },
    { "onLockDoor", "oVehicleMenuOnLockDoor" },
    { "onUnlockDoor", "oVehicleMenuOnUnlockDoor" },
    { "showRadialMenuOutside", "oVehicleMenuShowRadialMenuOutside" },
    { "showRadialMenu", "oVehicleMenuShowRadialMenu" },
}

function ClientTests.c_menu(r, player, vehicle)
    local md, owner = clientOwnership(player, vehicle)
    r:info(vehicleName(vehicle) .. " is " .. ownershipText(player, vehicle))
    local context, passed = menuOptions(player, vehicle)
    local has = function(name) return context:getOptionFromName(name) ~= nil end
    if owner then
        r:check(passed, "Vanilla vehicle menu shown to " .. (md and "the owner" or "anyone on an unclaimed vehicle"))
        local hasTitle = player:getInventory():containsTypeRecurse(T.TITLE_ITEM)
        local inZone = inDealershipCache(vehicle)
        local towed = vehicle:getVehicleTowedBy() ~= nil or vehicle:getVehicleTowing() ~= nil
        r:info("Title carried=" .. tostring(hasTitle) .. " in cached dealership zone=" .. tostring(inZone) .. " towing/towed=" .. tostring(towed))
        r:equal(has(CLAIM_OPTION), hasTitle and inZone and not towed and md == nil, "Claim Vehicle (KIPN) offered only for an unclaimed, untowed vehicle in a dealership while carrying a title")
        r:equal(has(RELEASE_OPTION), md ~= nil, "Release Vehicle Ownership (KIPN) offered only to the owner")
    else
        local policy = T.ExpectedClientPolicy(SandboxVars.KIPN)
        r:check(not passed, "Vanilla vehicle menu hidden from a non-owner")
        r:check(has("Vehicle owned by " .. tostring(md.KIPNVehicleOwnerUsername)), "Owner label shown")
        r:equal(has(getText("ContextMenu_VehicleMechanics")), policy.mechanics, "Mechanics option follows the sandbox")
        r:check(not has(CLAIM_OPTION) and not has(RELEASE_OPTION), "No claim or release option for a non-owner")
        r:info("Door option offered: " .. tostring(has(getText("ContextMenu_Open_door")) or has(getText("ContextMenu_Close_door")))
            .. " (depends on which door you stand at)")
    end
end

function ClientTests.c_gates(r, player, vehicle)
    local md, owner = clientOwnership(player, vehicle)
    local policy = T.ExpectedClientPolicy(SandboxVars.KIPN)
    r:info(vehicleName(vehicle) .. " is " .. ownershipText(player, vehicle) .. "; expecting " .. (owner and "every gate to pass through" or "non-owner rules"))
    local function gate(key, label, expected, call)
        r:equal(passesThrough(key, call), expected, label .. (expected and " passes through" or " is blocked"))
    end
    gate("oVehicleMenuOnShowSeatUI", "Seat picker", owner, function() ISVehicleMenu.onShowSeatUI(player, vehicle) end)
    gate("oVehicleMenuOnEnter", "Enter", owner, function() ISVehicleMenu.onEnter(player, vehicle, 0) end)
    gate("oVehicleMenuOnEnter2", "Enter (seat switch)", owner, function() ISVehicleMenu.onEnter2(player, vehicle, 0) end)
    gate("oVehicleMenuOnMechanic", "Mechanics", owner or policy.mechanics, function() ISVehicleMenu.onMechanic(player, vehicle) end)
    local door, hood = realDoorParts(vehicle)
    if door then
        r:info("Door " .. door:getId() .. " unlocked=" .. tostring(doorUnlocked(door)))
        gate("oVehicleMenuOnOpenDoor", "Open " .. door:getId(), owner or (policy.openUnlockedDoors and doorUnlocked(door)), function() ISVehicleMenu.onOpenDoor(player, door) end)
        gate("oVehicleMenuOnCloseDoor", "Close " .. door:getId(), owner or policy.openUnlockedDoors, function() ISVehicleMenu.onCloseDoor(player, door) end)
        gate("oVehicleMenuOnLockDoor", "Lock " .. door:getId(), owner, function() ISVehicleMenu.onLockDoor(player, door) end)
        gate("oVehicleMenuOnUnlockDoor", "Unlock " .. door:getId(), owner, function() ISVehicleMenu.onUnlockDoor(player, door) end)
    else
        r:skip("This vehicle has no doors")
    end
    if hood then
        gate("oVehicleMenuOnOpenDoor", "Open hood", owner or policy.mechanics, function() ISVehicleMenu.onOpenDoor(player, hood) end)
        gate("oVehicleMenuOnCloseDoor", "Close hood", owner or policy.mechanics, function() ISVehicleMenu.onCloseDoor(player, hood) end)
    end
    if player:getVehicle() == vehicle then
        gate("oVehicleMenuShowRadialMenu", "In-vehicle radial menu", owner, function() ISVehicleMenu.showRadialMenu(player) end)
    else
        r:skip("In-vehicle radial menu: sit in the vehicle to check it")
    end
    r:info("Radial menus are checked with a stand-in vehicle under Radial menus")
end

function ClientTests.c_modules(r)
    r:check(type(KIPN_VehicleClaimAction) == "table" and type(KIPN_VehicleClaimAction.CanStart) == "function", "Claim timed action is loaded")
    for _, name in ipairs({ "KIPN_VehicleRegistration", "KIPN_VehicleRecords" }) do
        local screen = rawget(_G, name)
        r:check(type(screen) == "table" and type(screen.onShow) == "function" and type(screen.receiveResponse) == "function"
            and type(screen.prerender) == "function", name .. " screen is loaded")
    end
    local bridge = KIPN.Bridges and KIPN.Bridges.Vehicle
    r:check(type(bridge) == "table" and type(bridge.SyncOwnershipMetadata) == "function", "Vehicle bridge is loaded")
    r:check(type(KIPN.UI) == "table" and type(KIPN.UI.CreateConfirmDialog) == "function", "KIPN confirm dialog is available to the claim menu")
    for _, pair in ipairs(WRAPPED) do
        local vanilla, current = KIPN[pair[2]], ISVehicleMenu[pair[1]]
        r:check(type(vanilla) == "function" and type(current) == "function" and vanilla ~= current,
            "ISVehicleMenu." .. pair[1] .. " is overridden, vanilla kept in KIPN." .. pair[2],
            "vanilla=" .. type(vanilla) .. " current=" .. type(current))
    end
end

-- Menu and gates on a Lua-only vehicle owned by the test owner, under
-- the live sandbox and two forced policies. SandboxVars.KIPN is put
-- back after each.
function ClientTests.c_policy(r, player)
    if not r:check(type(SandboxVars.KIPN) == "table", "SandboxVars.KIPN exists on your client") then return end
    local num = player:getPlayerNum()
    local MECHANICS, OPEN, CLOSE = getText("ContextMenu_VehicleMechanics"), getText("ContextMenu_Open_door"), getText("ContextMenu_Close_door")
    local function menuAt(vehicle, part, test)
        vehicle.useable = part
        local context, passed = fakeContext(), false
        withStubs({ "oFillMenuOutsideVehicle" }, function(calls)
            ISVehicleMenu.FillMenuOutsideVehicle(num, context, vehicle, test)
            passed = (calls.oFillMenuOutsideVehicle or 0) > 0
        end)
        return context, passed
    end
    local function has(context, name) return context:getOptionFromName(name) ~= nil end

    for _, entry in ipairs(policies()) do
        withFields(SandboxVars.KIPN, entry.values, function()
            local policy = T.ExpectedClientPolicy(SandboxVars.KIPN)
            r:info("--- Policy: " .. entry.name .. " (" .. describePolicy(policy) .. ")")
            local vehicle = fakeVehicle(STRANGER)
            local context, passed = menuAt(vehicle, vehicle.parts.unlocked, false)
            r:check(not passed, "Vanilla vehicle menu hidden from a non-owner")
            local label = context:getOptionFromName("Vehicle owned by " .. T.TEST_OWNER_NAME)
            r:check(label ~= nil and label.notAvailable == true, "Owner label shown, greyed out")
            r:equal(has(context, MECHANICS), policy.mechanics, "Mechanics option follows the policy")
            r:equal(has(context, OPEN), policy.openUnlockedDoors, "Open door offered at an unlocked door only when allowed")
            r:check(not has(context, CLAIM_OPTION) and not has(context, RELEASE_OPTION), "No claim or release option")
            context = menuAt(vehicle, vehicle.parts.open, false)
            r:equal(has(context, CLOSE), policy.openUnlockedDoors, "Close door offered at an open door only when allowed")
            context = menuAt(vehicle, vehicle.parts.locked, false)
            r:check(not has(context, OPEN) and not has(context, CLOSE), "No door option at a locked door")
            context = menuAt(vehicle, vehicle.parts.hood, false)
            r:check(not has(context, OPEN) and not has(context, CLOSE), "No door option at the hood (that is mechanics)")
            context, passed = menuAt(vehicle, vehicle.parts.unlocked, true)
            r:check(not passed and #context.options == 0, "A test-only menu fill adds nothing")

            local stranger = fakePlayer(player, {})
            local function gate(key, label, expected, call)
                r:equal(passesThrough(key, call), expected, label .. (expected and " passes through" or " is blocked"))
            end
            gate("oVehicleMenuOnShowSeatUI", "Seat picker", false, function() ISVehicleMenu.onShowSeatUI(stranger, vehicle) end)
            gate("oVehicleMenuOnEnter", "Enter", false, function() ISVehicleMenu.onEnter(stranger, vehicle, 0) end)
            gate("oVehicleMenuOnEnter2", "Enter (seat switch)", false, function() ISVehicleMenu.onEnter2(stranger, vehicle, 0) end)
            gate("oVehicleMenuOnMechanic", "Mechanics", policy.mechanics, function() ISVehicleMenu.onMechanic(stranger, vehicle) end)
            gate("oVehicleMenuOnOpenDoor", "Open an unlocked door", policy.openUnlockedDoors, function() ISVehicleMenu.onOpenDoor(stranger, vehicle.parts.unlocked) end)
            gate("oVehicleMenuOnOpenDoor", "Open a locked door", false, function() ISVehicleMenu.onOpenDoor(stranger, vehicle.parts.locked) end)
            gate("oVehicleMenuOnOpenDoor", "Open the hood", policy.mechanics, function() ISVehicleMenu.onOpenDoor(stranger, vehicle.parts.hood) end)
            gate("oVehicleMenuOnCloseDoor", "Close a door", policy.openUnlockedDoors, function() ISVehicleMenu.onCloseDoor(stranger, vehicle.parts.open) end)
            gate("oVehicleMenuOnCloseDoor", "Close the hood", policy.mechanics, function() ISVehicleMenu.onCloseDoor(stranger, vehicle.parts.hood) end)
            gate("oVehicleMenuOnLockDoor", "Lock a door", false, function() ISVehicleMenu.onLockDoor(stranger, vehicle.parts.unlocked) end)
            gate("oVehicleMenuOnUnlockDoor", "Unlock a door", false, function() ISVehicleMenu.onUnlockDoor(stranger, vehicle.parts.locked) end)
            r:check(heard(stranger, "You do not have permission to enter this vehicle."), "A blocked entry tells you why")
            if policy.openUnlockedDoors then
                r:check(heard(stranger, "only allows already-unlocked doors"), "A locked door tells you the permission is for unlocked doors")
            end
        end)
    end

    r:info("--- Your own vehicle and an unclaimed one, under the strictest policy")
    withFields(SandboxVars.KIPN, T.FORCED_POLICIES[2].values, function()
        for _, case in ipairs({ { label = "your own vehicle", owner = me(player) }, { label = "an unclaimed vehicle" } }) do
            local vehicle = fakeVehicle(case.owner)
            local context, passed = menuAt(vehicle, vehicle.parts.unlocked, false)
            r:check(passed, "Vanilla vehicle menu shown on " .. case.label)
            r:equal(has(context, RELEASE_OPTION), case.owner ~= nil, "Release option only on your own vehicle (" .. case.label .. ")")
            local owner = fakePlayer(player, {})
            local all = true
            for _, pair in ipairs({
                { "oVehicleMenuOnEnter", function() ISVehicleMenu.onEnter(owner, vehicle, 0) end },
                { "oVehicleMenuOnMechanic", function() ISVehicleMenu.onMechanic(owner, vehicle) end },
                { "oVehicleMenuOnOpenDoor", function() ISVehicleMenu.onOpenDoor(owner, vehicle.parts.locked) end },
                { "oVehicleMenuOnLockDoor", function() ISVehicleMenu.onLockDoor(owner, vehicle.parts.unlocked) end },
                { "oVehicleMenuOnUnlockDoor", function() ISVehicleMenu.onUnlockDoor(owner, vehicle.parts.locked) end },
            }) do
                all = passesThrough(pair[1], pair[2]) and all
            end
            r:check(all, "Enter, mechanics, doors and locks all pass through on " .. case.label)
        end
    end)
end

function ClientTests.c_radial(r, player)
    local MECHANICS, OPEN = getText("ContextMenu_VehicleMechanics"), getText("ContextMenu_Open_door")
    local function outside(vehicle)
        local menu, passed = fakeRadialMenu(), false
        withFields(_G, { getPlayerRadialMenu = function() return menu end }, function()
            withFields(ISVehicleMenu, { getVehicleToInteractWith = function() return vehicle end }, function()
                passed = passesThrough("oVehicleMenuShowRadialMenuOutside", function() ISVehicleMenu.showRadialMenuOutside(player) end)
            end)
        end)
        return menu, passed
    end
    local function inside(vehicle)
        local occupant = fakePlayer(player, {}, vehicle)
        return passesThrough("oVehicleMenuShowRadialMenu", function() ISVehicleMenu.showRadialMenu(occupant) end), occupant
    end

    for _, entry in ipairs(policies()) do
        withFields(SandboxVars.KIPN, entry.values, function()
            local policy = T.ExpectedClientPolicy(SandboxVars.KIPN)
            r:info("--- Policy: " .. entry.name .. " (" .. describePolicy(policy) .. ")")
            local vehicle = fakeVehicle(STRANGER)
            vehicle.useable = vehicle.parts.unlocked
            local menu, passed = outside(vehicle)
            r:check(not passed, "V-key menu: vanilla radial hidden from a non-owner")
            local mechanics, door = menu:slice(MECHANICS), menu:slice(OPEN)
            r:equal(mechanics ~= nil, policy.mechanics, "V-key menu: Mechanics slice follows the policy")
            r:equal(door ~= nil, policy.openUnlockedDoors, "V-key menu: Open door slice follows the policy")
            r:equal(menu.shown, policy.mechanics or policy.openUnlockedDoors, "V-key menu opens only when it has a slice")
            if mechanics then r:check(mechanics.callback == ISVehicleMenu.onMechanic, "Mechanics slice goes through the mechanics gate") end
            if door then r:check(door.callback == ISVehicleMenu.onOpenDoor and door.b == vehicle.parts.unlocked, "Door slice goes through the door gate") end
            vehicle.useable = vehicle.parts.hood
            menu = outside(vehicle)
            r:check(menu:slice(OPEN) == nil, "V-key menu: no door slice at the hood")
            local seated = inside(vehicle)
            r:check(not seated, "In-vehicle radial menu blocked for a non-owner")
        end)
    end
    for _, case in ipairs({ { label = "your own vehicle", owner = me(player) }, { label = "an unclaimed vehicle" } }) do
        local vehicle = fakeVehicle(case.owner)
        local _, passed = outside(vehicle)
        r:check(passed, "V-key menu: vanilla radial on " .. case.label)
        r:check((inside(vehicle)), "In-vehicle radial menu on " .. case.label)
    end
end

-- The claim and release options, their confirm dialogs and what each
-- answer does. Dialogs, sends and the action queue are replaced by
-- recorders, so nothing is claimed, released or queued.
function ClientTests.c_dialogs(r, player)
    local num = player:getPlayerNum()
    local dialogs, sent, queued, walked = {}, {}, {}, 0
    local recorders = {
        sendClientCommand = function(...) sent[#sent + 1] = { ... } end,
    }
    local function recording(fn)
        withFields(KIPN.UI, { CreateConfirmDialog = function(...) dialogs[#dialogs + 1] = { ... } end }, function()
            withFields(_G, recorders, function()
                withFields(luautils, { walkAdj = function() walked = walked + 1; return true end }, function()
                    withFields(ISTimedActionQueue, { add = function(action) queued[#queued + 1] = action end }, fn)
                end)
            end)
        end)
    end
    local function menuFor(asPlayer, vehicle)
        local context = fakeContext()
        withFields(_G, { getSpecificPlayer = function() return asPlayer end }, function()
            withStubs({ "oFillMenuOutsideVehicle" }, function() ISVehicleMenu.FillMenuOutsideVehicle(num, context, vehicle, false) end)
        end)
        return context
    end
    local function confirm(option, answer, asPlayer)
        dialogs = {}
        recording(function() option.onSelect(option.target, option.params[1]) end)
        local dialog = dialogs[1]
        if dialog and answer then recording(function() dialog[8](asPlayer, { internal = answer }, dialog[10]) end) end
        return dialog
    end

    r:info("--- Release")
    local owned = fakeVehicle(me(player))
    local release = menuFor(player, owned):getOptionFromName(RELEASE_OPTION)
    if r:check(release ~= nil, "Release option offered on your own vehicle") then
        r:check(release.toolTip ~= nil, "Release option has a tooltip")
        local owner = fakePlayer(player, {})
        local dialog = confirm(release)
        if r:check(dialog ~= nil, "Release asks for confirmation first") then
            r:equal(dialog[9], num, "Dialog gets your player index (not the vehicle)")
            r:check(dialog[10] == owned, "Dialog carries the vehicle")
            r:check(string.find(tostring(dialog[5]), "Release", 1, true) ~= nil, "Dialog explains the release", dialog[5])
            r:equal(#sent, 0, "Nothing is sent before you answer")
            confirm(release, "NO", owner)
            r:equal(#sent, 0, "No sends nothing")
            confirm(release, "YES", owner)
            local message = sent[#sent]
            r:check(message and message[1] == "KIPN" and message[2] == KIPN.Shared.Commands.RELEASE_CLAIM
                and type(message[3]) == "table" and message[3].claimId == FAKE_CLAIM_ID,
                "Yes sends RELEASE_CLAIM with the vehicle's claim id")
            r:check(heard(owner, "Filing release"), "You are told the release was filed")
            sent = {}
            recording(function() dialog[8](owner, { internal = "YES" }, fakeVehicle(nil)) end)
            r:check(#sent == 0 and heard(owner, "This vehicle is not claimed."), "Releasing a vehicle that is no longer claimed sends nothing and says so")
        end
    end
    r:check(menuFor(player, fakeVehicle(nil)):getOptionFromName(RELEASE_OPTION) == nil, "No release option on an unclaimed vehicle")

    r:info("--- Claim (a stand-in dealership zone around a Lua-only vehicle)")
    local square = {}
    function square:getX() return 5 end
    function square:getY() return 5 end
    function square:getZ() return 0 end
    local client = KIPN.Client or {}
    local hadClient = KIPN.Client ~= nil
    KIPN.Client = client
    local ok, err = pcall(withFields, client, { ZoneMapCache = { zones = { lilbubby = { id = "lilbubby", type = "dealership",
        geometry = { x1 = 0, y1 = 0, x2 = 10, y2 = 10, z1 = 0 } } } } }, function()
        local vehicle = fakeVehicle(nil)
        vehicle.square = square
        local withTitle, bagged, without = fakePlayer(player, { T.TITLE_ITEM }), fakePlayer(player, { { T.TITLE_ITEM } }), fakePlayer(player, {})
        local function offered(asPlayer) return menuFor(asPlayer, vehicle):getOptionFromName(CLAIM_OPTION) end
        local option = offered(withTitle)
        r:check(option ~= nil, "Claim option offered: unclaimed, in a dealership, carrying a title")
        r:check(offered(bagged) ~= nil, "A title in a bag counts")
        r:check(offered(without) == nil, "No claim option without a title")
        vehicle.towed = true
        r:check(offered(withTitle) == nil, "No claim option on a towed vehicle")
        vehicle.towed = false
        vehicle.square = nil
        r:check(offered(withTitle) == nil, "No claim option outside a dealership")
        vehicle.square = square
        if option then
            r:check(option.toolTip ~= nil, "Claim option has a tooltip")
            local dialog = confirm(option)
            if r:check(dialog ~= nil, "Claim asks for confirmation first") then
                r:equal(dialog[9], num, "Dialog gets your player index (not the vehicle)")
                r:check(dialog[10] == vehicle, "Dialog carries the vehicle")
                confirm(option, "NO", withTitle)
                r:equal(#queued, 0, "No queues nothing")
                confirm(option, "YES", without)
                r:check(#queued == 0 and heard(without, "A Vehicle Title is required"), "Yes without a title queues nothing and says why")
                vehicle.towed = true
                local towedPlayer = fakePlayer(player, { T.TITLE_ITEM })
                confirm(option, "YES", towedPlayer)
                r:check(#queued == 0 and heard(towedPlayer, "no longer available"), "Yes on a vehicle towed meanwhile queues nothing and says why")
                vehicle.towed = false
                confirm(option, "YES", withTitle)
                local action = queued[#queued]
                r:check(walked > 0 and action ~= nil and action.Type == "KIPN_VehicleClaimAction" and action.vehicle == vehicle,
                    "Yes walks you to the vehicle and queues the claim action for it")
                r:equal(#sent, 0, "Nothing is sent until the action finishes")
            end
        end
    end)
    if not hadClient then KIPN.Client = nil end
    if not ok then error(err, 0) end
end

function ClientTests.c_action(r, player, vehicle)
    local A = KIPN_VehicleClaimAction
    r:check(not A.CanStart(fakePlayer(player, {}), false), "Cannot start without a Vehicle Title")
    r:check(A.CanStart(fakePlayer(player, { T.TITLE_ITEM }), false), "Starts with a Vehicle Title")
    r:check(A.CanStart(fakePlayer(player, { { T.TITLE_ITEM } }), false), "A title in a bag counts")
    local told = fakePlayer(player, {})
    A.CanStart(told, true)
    r:check(heard(told, "A Vehicle Title is required"), "Says why when asked to")

    local action = A:new(player, vehicle)
    r:check(action.vehicle == vehicle and action.character == player, "Action targets you and this vehicle")
    r:check(action.stopOnWalk == true and action.stopOnRun == true, "Walking or running away stops it")
    r:equal(action.maxTime, player:isTimedActionInstant() and 1 or 60, "Duration")
    r:check(action:isValid() == true, "Valid while the vehicle is in the world")

    local stopped, anim = 0, nil
    local function probe(carries)
        return setmetatable({ character = fakePlayer(player, carries), vehicle = vehicle,
            forceStop = function() stopped = stopped + 1 end, setActionAnim = function(_, name) anim = name end }, { __index = A })
    end
    probe({}):start()
    r:equal(stopped, 1, "Starting without a title stops at once (the title is rechecked at start)")
    probe({ T.TITLE_ITEM }):start()
    r:check(stopped == 1 and anim == "VehicleWorkOnMid", "Starting with a title plays the work animation", anim)

    local sent = {}
    withFields(_G, { sendClientCommand = function(...) sent[#sent + 1] = { ... } end }, function()
        withFields(ISBaseTimedAction, { perform = function() end }, function() action:perform() end)
    end)
    local message = sent[1]
    r:check(#sent == 1 and message[1] == player and message[2] == "KIPN" and message[3] == KIPN.Shared.Commands.CLAIM_VEHICLE
        and type(message[4]) == "table" and message[4].vehicleId == vehicle:getId(),
        "Finishing sends CLAIM_VEHICLE for this vehicle (and nothing else)")
    r:info("The server's reply (\"Vehicle claim successful.\" or the refusal) is checked by tests/vehsvc_checks.lua")
end

function ClientTests.c_bridge(r, _, vehicle)
    local B = KIPN.Bridges and KIPN.Bridges.Vehicle
    if not r:check(type(B) == "table", "KIPN.Bridges.Vehicle is loaded") then return end
    r:equal(B.GetId(vehicle), tostring(vehicle:getId()), "GetId returns the vehicle id as text")
    r:check(B.GetSquare(vehicle) == vehicle:getSquare(), "GetSquare returns the vehicle's square")
    local position, square = B.GetPosition(vehicle), vehicle:getSquare()
    r:check(position and square and position.x == square:getX() and position.y == square:getY() and position.z == square:getZ(),
        "GetPosition matches the vehicle's square")
    r:check(B.GetId(nil) == nil and B.GetSquare(nil) == nil and B.GetPosition(nil) == nil, "No vehicle gives nil")

    -- Metadata is written to a Lua-only vehicle: the client never writes the real one.
    local fake = fakeVehicle(nil)
    local md = fake:getModData()
    r:check(B.SyncOwnershipMetadata(fake, { id = 7, ownerSteamId = 42 }) == true, "Sync with a claim succeeds")
    r:check(md.KIPNVehicleClaimId == "7" and md.KIPNVehicleOwnerSteamId == "42" and md.KIPNVehicleOwnerUsername == "Unknown",
        "Sync writes the claim id and owner as text, and Unknown for a missing name")
    r:check(B.SyncOwnershipMetadata(fake, nil) == true and md.KIPNVehicleClaimId == nil and md.KIPNVehicleOwnerSteamId == nil
        and md.KIPNVehicleOwnerUsername == nil, "Sync with no claim clears all three fields")
    r:equal(fake.transmitted, 2, "Each sync transmits the vehicle's mod data")
    r:equal(B.SyncOwnershipMetadata(nil, {}), false, "Sync without a vehicle fails")
end

-- The Vehicle Registration screen's logic on a stand-in screen, with the
-- clock, sends, sounds and your inventory replaced by recorders.
function ClientTests.c_registration(r, player)
    if not r:check(type(SandboxVars.KIPN) == "table", "SandboxVars.KIPN exists on your client") then return end
    local Screen, events = KIPN_VehicleRegistration, KIPN.Shared.ResponseEvents
    local now, sent, sounds = 100000, {}, {}
    local carrier = fakePlayer(player, {})
    local function carrying(entries) carrier = fakePlayer(player, entries) end
    local function screen(computerId)
        local button = { setVisible = function() end }
        return setmetatable({ processButton = button, height = 400,
            terminal = computerId and { GetComputerId = function() return computerId end } or nil }, { __index = Screen })
    end
    local sound = {}
    for _, name in ipairs({ "Start", "Stop", "Complete", "Fail" }) do sound[name] = function() sounds[name] = (sounds[name] or 0) + 1 end end
    withFields(_G, {
        getPlayer = function() return carrier end,
        getTimestampMs = function() return now end,
        sendClientCommand = function(...) sent[#sent + 1] = { ... } end,
    }, function()
        withFields(KIPN, { ClaimCraftSound = sound }, function()
            withFields(ISPanel, { update = function() end }, function()
                local s = screen("lilbubby-computer")
                carrying({ { T.REGISTRATION_ITEM } })
                s:checkInventory()
                r:check(s.hasRegistrationItem == true and s.processButton.enable == true, "A form in a bag enables Craft a Vehicle Title")
                carrying({})
                s:checkInventory()
                r:check(s.hasRegistrationItem == false and s.processButton.enable == false, "No form disables the button")
                s:onProcessClick()
                r:check(s.statusTitle == "REGISTRATION NOT FOUND" and #sent == 0, "Clicking without a form says so and sends nothing", s.statusTitle)

                carrying({ T.REGISTRATION_ITEM })
                s = screen(nil)
                s:onProcessClick()
                r:check(s.statusTitle == "COMPUTER NOT IDENTIFIED" and #sent == 0, "An unidentified computer says so and sends nothing", s.statusTitle)

                withFields(SandboxVars.KIPN, { VehicleClaimCraftSeconds = 0 }, function()
                    s = screen("lilbubby-computer")
                    s:onProcessClick()
                    local message = sent[1]
                    r:check(#sent == 1 and message[1] == "KIPN" and message[2] == KIPN.Shared.Commands.ISSUE_VEHICLE_CLAIM
                        and message[3].computerId == "lilbubby-computer", "With a 0 second wait the request goes at once, with the computer id")
                    s:onProcessClick()
                    r:equal(#sent, 1, "A second click while the server answers sends nothing")
                end)

                sent = {}
                withFields(SandboxVars.KIPN, { VehicleClaimCraftSeconds = 5 }, function()
                    s = screen("lilbubby-computer")
                    s:onProcessClick()
                    r:equal(s.craftEndAtMs, now + 5000, "VehicleClaimCraftSeconds=5 sets a 5 second wait")
                    r:check(#sent == 0 and s.statusTitle == "PROCESSING REGISTRATION..." and (sounds.Start or 0) == 1,
                        "The wait shows its status and starts the sound, and nothing is sent yet")
                    now = now + 4000
                    s:update()
                    r:equal(#sent, 0, "Nothing is sent before the wait ends")
                    now = now + 1500
                    s:update()
                    r:check(#sent == 1 and sent[1][3].computerId == "lilbubby-computer" and s.craftEndAtMs == nil, "The request goes when the wait ends")

                    sent = {}
                    s = screen("lilbubby-computer")
                    s:onProcessClick()
                    carrying({})
                    now = now + 100
                    s:update()
                    r:check(#sent == 0 and s.statusTitle == "REGISTRATION NOT FOUND" and s.craftEndAtMs == nil and s.requestInFlight == false
                        and (sounds.Stop or 0) >= 1, "The wait is abandoned when the form leaves your inventory")
                end)

                s = screen("lilbubby-computer")
                s.requestInFlight = true
                s:receiveResponse(events.VEHICLE_CLAIM_ARTIFACT_ISSUED, {})
                r:check(s.statusTitle == "VEHICLE TITLE ISSUED" and s.requestInFlight == false and (sounds.Complete or 0) == 1,
                    "An issued title shows success and plays the completion sound")
                s:receiveResponse(events.VEHICLE_CLAIM_ARTIFACT_ISSUED, { droppedOnGround = true })
                r:check(string.find(tostring(s.statusSubtitle), "dropped on the ground", 1, true) ~= nil, "A full inventory says the title is on the ground")
                s.requestInFlight = true
                s:receiveResponse(events.ERROR, { reason = "LilBubby refusal" })
                r:check(s.statusTitle == "REGISTRATION FAILED" and s.statusSubtitle == "LilBubby refusal" and s.requestInFlight == false
                    and (sounds.Fail or 0) == 1, "A refusal shows the server's reason")
                s.craftEndAtMs, s.pendingClaimArgs = now + 1000, {}
                s:onLeaveScreen()
                r:check(s.craftEndAtMs == nil and s.pendingClaimArgs == nil, "Leaving the screen cancels a wait")
            end)
        end)
    end)
    r:info("Drawing and the button's place are seen by opening the screen at a dealership computer")
end

-- The Vehicle Records screen's logic on a stand-in screen. Drawing is
-- recorded instead of shown.
function ClientTests.c_records(r, player)
    local Screen, events, commands = KIPN_VehicleRecords, KIPN.Shared.ResponseEvents, KIPN.Shared.Commands
    local now, sent, drawn, status, beeps = 50000, {}, {}, nil, 0
    local reader = fakePlayer(player, {})
    local s = setmetatable({ properties = {}, pendingReleaseArmedAt = 0 }, { __index = Screen })
    function s:drawText(text) drawn[#drawn + 1] = tostring(text) end
    local function shown(text)
        for _, line in ipairs(drawn) do if line == text then return true end end
        return false
    end
    local claims = {
        { type = "vehicle", id = "v-never", ownershipNeverExpires = true },
        { type = "vehicle", id = "v-expired", expiryDaysRemaining = 0.2 },
        { type = "vehicle", id = "v-one", expiryDaysRemaining = 1 },
        { type = "vehicle", id = "v-five", expiryDaysRemaining = 5.4 },
        { type = "vehicle", id = "v-legacy", releasable = false },
        { type = "property", id = "p-house" },
        "not a claim",
    }
    withFields(_G, {
        getPlayer = function() return reader end,
        getTimestampMs = function() return now end,
        sendClientCommand = function(...) sent[#sent + 1] = { ... } end,
        getSoundManager = function() return { playUISound = function() beeps = beeps + 1 end } end,
    }, function()
        withFields(KIPN.UI, {
            EnableScroll = function() end, DrawScanlines = function() end, SetContentHeight = function() end,
            DrawBanner = function() return 40 end, ScrollY = function(_, y) return y end,
            DrawSectionHeader = function(_, y, text) drawn[#drawn + 1] = tostring(text); return y + 20 end,
            DrawStatusMessage = function(_, _, title) status = title end,
        }, function()
            withFields(ISPanel, { update = function() end, prerender = function() end }, function()
                s:onShow()
                r:check(s.loading == true and #sent == 1 and sent[1][2] == commands.GET_MY_CLAIMS, "Opening the screen asks the server for your claims")
                s:prerender()
                r:equal(status, "SEARCHING VEHICLE RECORDS...", "While loading it says so")
                now = now + 4000
                s:update()
                r:check(s.loading == true, "Still waiting after 4 seconds")
                now = now + 2000
                s:update()
                s:prerender()
                r:check(s.loading == false and s.timedOut == true and status == "SEARCH TIMED OUT", "After 5 seconds with no answer it says it timed out")

                s:receiveResponse(events.MY_CLAIMS_DATA, claims)
                r:equal(#s.properties, 5, "Only vehicle claims are listed")
                r:check(s.loading == false and s.timedOut == false, "An answer ends the wait")
                drawn, status = {}, nil
                s:prerender()
                r:check(shown("VEHICLE CLAIMS") and status == nil, "Claims are drawn under VEHICLE CLAIMS")
                for _, claim in ipairs(claims) do
                    if type(claim) == "table" and claim.type == "vehicle" then
                        local expected = "EXPIRES: " .. T.ExpectedExpiryText(claim)
                        r:check(shown(expected), claim.id .. " shows " .. expected)
                    end
                end
                r:check(shown("LEGACY") and #s.rowClaimIds == 4, "A claim that cannot be released shows LEGACY and has no release button")

                sent = {}
                local rect = s.rowHitRects[1]
                local claimId = rect and s.rowClaimIds[rect.index]
                if r:check(rect ~= nil, "Release buttons can be clicked") then
                    s:onMouseDown(0, rect.y1)
                    r:check(s.pendingReleaseId == claimId and #sent == 0, "The first click asks you to confirm")
                    drawn = {}
                    s:prerender()
                    r:check(shown("[ CONFIRM RELEASE? ]"), "The button then reads CONFIRM RELEASE?")
                    s:onMouseDown(0, rect.y1)
                    r:check(#sent == 1 and sent[1][2] == commands.RELEASE_CLAIM and sent[1][3].claimId == claimId and s.pendingReleaseFeedback == true,
                        "The second click sends RELEASE_CLAIM for that claim")
                    s:receiveResponse(events.MY_CLAIMS_DATA, {})
                    r:check(beeps == 1 and s.pendingReleaseFeedback == false, "The refreshed list after a release beeps once")
                    s.properties = { claims[1] }
                    drawn = {}
                    s:prerender()
                    rect = s.rowHitRects[1]
                    s:onMouseDown(0, rect.y1)
                    now = now + 7000
                    s:update()
                    r:check(s.pendingReleaseId == nil, "An unconfirmed release is forgotten after 6 seconds")
                end

                s.properties = {}
                s:prerender()
                r:equal(status, "NO CLAIM RECORDS FOUND", "No vehicle claims says so")
                s:receiveResponse(events.MY_CLAIMS_DATA, "not a list")
                r:equal(#s.properties, 0, "A malformed answer lists nothing")
                s.loading = true
                s:receiveResponse(events.ERROR, "LilBubby refusal")
                r:check(s.loading == false and heard(reader, "ERROR: LilBubby refusal"), "A server error ends the wait and is said aloud")
            end)
        end)
    end)
end

------------------------------------------------------------
-- VEHICLE CLAIM LIFECYCLE (client flow)
--
-- 1. The server sets up a computer in a dealership zone, a car in the
--    same zone and the form materials (life_prepare).
-- 2. Your character crafts the form with the real recipe (life_form).
-- 3. The real Vehicle Registration screen code presents it at that
--    computer (life_titled).
-- 4. The real right-click Claim option, its dialog (answered Yes) and
--    timed action claim the car (life_claimed).
-- 5. The server runs one in-game day with OwnershipExpiryDays = 1 and
--    checks the mod ends your ownership.
------------------------------------------------------------

local Flows = {}
T.Flows = Flows
local life = nil

local function lifeSay(text)
    print("[" .. T.MODULE .. "] " .. text)
    LilBubbyShowcase.Report(life.player, "vehicle", text, true)
end

local function lifeFinish()
    local run = life
    life = nil
    local text = run.r:text()
    print("[" .. T.MODULE .. "] " .. (string.gsub(text, "\n", " | ")))
    lastResults[run.player:getPlayerNum()] = text
    show(run.player, text)
end

local function lifeRequest(id, args)
    args = args or {}
    args.id = id
    life.waiting = id
    life.deadline = getTimestampMs() + (id == "life_claimed" and 660000 or 60000)
    if isClient() then
        sendClientCommand(life.player, T.MODULE, "run", args)
    elseif T.RunServer then
        T.RunServer(life.player, id, args)
    end
end

local function lifeReply(event, command)
    local replies = life.replies
    for i = 1, #replies do
        local reply = replies[i]
        local data = type(reply.data) == "table" and reply.data or {}
        if reply.event == event and (command == nil or data.command == nil or data.command == command) then
            table.remove(replies, i)
            return reply, data
        end
    end
end

local function lifeDesk()
    lifeSay("Step 3 of 5: presenting the form at the dealership computer's Vehicle Registration desk")
    local screen = setmetatable({ height = 400, processButton = { setVisible = function() end },
        terminal = { GetComputerId = function() return life.computerId end } }, { __index = KIPN_VehicleRegistration })
    life.screen, life.replies = screen, {}
    screen:checkInventory()
    life.r:check(screen.hasRegistrationItem == true, "The Vehicle Registration desk sees your form (Craft a Vehicle Title is enabled)")
    screen:onProcessClick()
    if not life.r:check(screen.requestInFlight == true, "Craft a Vehicle Title was accepted", screen.statusTitle) then lifeFinish() return end
    local seconds = tonumber(SandboxVars.KIPN and SandboxVars.KIPN.VehicleClaimCraftSeconds) or 0
    life.r:info("The desk processes the form for " .. seconds .. " s (VehicleClaimCraftSeconds)")
    life.phase, life.phaseDeadline = "desk", getTimestampMs() + seconds * 1000 + 30000
end

local function lifeClaim()
    lifeSay("Step 4 of 5: claiming the test car with the right-click Claim option")
    life.replies = {}
    life.phase, life.phaseDeadline = "claim_option", getTimestampMs() + 15000
end

local function lifeStartClaimAction(vehicle)
    if luautils.walkAdj(life.player, vehicle:getSquare()) then
        ISTimedActionQueue.add(KIPN_VehicleClaimAction:new(life.player, vehicle))
    end
end

local function lifeTick()
    local now, r, player = getTimestampMs(), life.r, life.player
    if life.waiting then
        if now > life.deadline then
            r:fail("No answer from the server for " .. life.waiting)
            lifeFinish()
        end
        return
    end
    if life.phase == "desk" then
        withFields(ISPanel, { update = function() end }, function() life.screen:update() end)
        local issued = lifeReply(KIPN.Shared.ResponseEvents.VEHICLE_CLAIM_ARTIFACT_ISSUED)
        local _, refusal = lifeReply(KIPN.Shared.ResponseEvents.ERROR, KIPN.Shared.Commands.ISSUE_VEHICLE_CLAIM)
        if issued then
            life.screen:receiveResponse(issued.event, issued.data)
            r:equal(life.screen.statusTitle, "VEHICLE TITLE ISSUED", "The desk screen shows the title was issued")
            life.phase = "title"
        elseif refusal then
            life.phase = nil
            lifeRequest("life_titled", { zoneId = life.zoneId, refused = tostring(refusal.reason or refusal.message or refusal.code or "no reason given") })
        elseif now > life.phaseDeadline then
            life.phase = nil
            lifeRequest("life_titled", { zoneId = life.zoneId, refused = "no answer from the desk" })
        end
        return
    end
    if life.phase == "title" then
        if player:getInventory():containsTypeRecurse(T.TITLE_ITEM) then
            r:pass("The Vehicle Title arrived in your inventory")
            life.phase = nil
            lifeRequest("life_titled", { zoneId = life.zoneId })
        elseif now > life.phaseDeadline then
            r:fail("The desk said the title was issued, but none reached your inventory")
            lifeFinish()
        end
        return
    end
    if life.phase == "claim_option" then
        local vehicle = findVehicle(life.vehicleId)
        if not vehicle then
            if now > life.phaseDeadline then r:fail("The test car is not loaded on your client") lifeFinish() end
            return
        end
        local context = fakeContext()
        withStubs({ "oFillMenuOutsideVehicle" }, function()
            ISVehicleMenu.FillMenuOutsideVehicle(player:getPlayerNum(), context, vehicle, false)
        end)
        local option = context:getOptionFromName(CLAIM_OPTION)
        if option then
            r:pass("Right-clicking the car offers Claim Vehicle (KIPN)")
            local dialog
            withFields(KIPN.UI, { CreateConfirmDialog = function(...) dialog = { ... } end }, function()
                option.onSelect(option.target, option.params[1])
            end)
            if r:check(dialog ~= nil, "Claiming asks for confirmation; the test answers Yes") then
                dialog[8](dialog[7], { internal = "YES" }, dialog[10])
            else
                lifeStartClaimAction(vehicle)
            end
        elseif now > life.phaseDeadline then
            local inZone = inDealershipCache(vehicle)
            r:fail("Right-clicking the car never offered Claim Vehicle (KIPN) (checked for 15 s; car in your client's dealership zone list="
                .. tostring(inZone) .. ")")
            r:info("Carrying on with the claim timed action itself, so the rest of the lifecycle is still checked")
            lifeStartClaimAction(vehicle)
        else
            return
        end
        life.phase, life.phaseDeadline = "claim_wait", now + 60000
        return
    end
    if life.phase == "claim_wait" then
        local success = lifeReply(KIPN.Shared.ResponseEvents.VEHICLE_CLAIM_SUCCESSFUL)
        local _, refusal = lifeReply(KIPN.Shared.ResponseEvents.ERROR, KIPN.Shared.Commands.CLAIM_VEHICLE)
        if refusal then
            r:fail("The server refused the claim: " .. tostring(refusal.reason or refusal.message))
            lifeFinish()
            return
        end
        if success then life.claimConfirmed = true end
        local vehicle = findVehicle(life.vehicleId)
        local md = vehicle and vehicle:getModData()
        local mine = md and md.KIPNVehicleClaimId ~= nil and tostring(md.KIPNVehicleOwnerSteamId) == ownerKey(player)
        if life.claimConfirmed and mine then
            r:pass("The server confirmed the claim, and your client sees the car as yours")
            life.phase = nil
            lifeSay("Step 5 of 5: one in-game day of ownership (the server clock runs fast)")
            lifeRequest("life_claimed", { vehicleId = life.vehicleId, titleId = life.titleId })
        elseif now > life.phaseDeadline then
            r:fail("No claim within 60 s (server confirmed=" .. tostring(life.claimConfirmed == true) .. ", your client sees it as yours=" .. tostring(mine == true) .. ")")
            lifeFinish()
        end
    end
end

function T.LifeReceive(player, args)
    if not life or args.id ~= life.waiting then return end
    life.waiting = nil
    local r = life.r
    for _, line in ipairs(args.lines or {}) do r.lines[#r.lines + 1] = line end
    for status, count in pairs(args.counts or {}) do r.counts[status] = (r.counts[status] or 0) + count end
    local data = args.data
    if type(data) ~= "table" then lifeFinish() return end
    if args.id == "life_prepare" then
        life.computerId, life.zoneId, life.vehicleId = data.computerId, data.zoneId, data.vehicleId
        lifeSay("Step 2 of 5: crafting a Vehicle Registration Form with the recipe")
        LilBubbyCraft.Craft(player, T.RECIPE, T.REGISTRATION_ITEM, function(ok, detail)
            if not life then return end
            if not life.r:check(ok, "You crafted a Vehicle Registration Form with the recipe", detail ~= "" and detail or nil) then
                lifeFinish()
                return
            end
            lifeRequest("life_form")
        end)
    elseif args.id == "life_form" then
        lifeDesk()
    elseif args.id == "life_titled" then
        life.titleId = data.titleId
        lifeClaim()
    elseif args.id == "life_claimed" then
        lifeFinish()
    end
end

function Flows.lifecycle(player)
    if life then show(player, T.SUITE .. "\nBLOCKED: The lifecycle test is already running.") return end
    life = { player = player, replies = {}, r = T.NewReport(T.SUITE .. " | " .. T.CatalogById.lifecycle.label) }
    life.r:info("This test builds a test computer, zone and car, and moves the server clock on by one in-game day for everyone.")
    lifeSay("Step 1 of 5: setting up a dealership computer, zone and test car")
    lifeRequest("life_prepare")
end

Events.OnServerCommand.Add(function(module, command, args)
    if life and module == "KIPN" and KIPN.Shared and command == KIPN.Shared.Commands.SERVER_RESPONSE and type(args) == "table" then
        life.replies[#life.replies + 1] = args
    end
end)

Events.OnTick.Add(function()
    if not life then return end
    local ok, err = pcall(lifeTick)
    if not ok and life then
        life.r:fail("ERROR: " .. tostring(err))
        lifeFinish()
    end
end)

------------------------------------------------------------
-- RUNNING
------------------------------------------------------------

local function runClientChecks(player, ids, vehicle, title)
    local r = T.NewReport(title)
    for _, id in ipairs(ids) do
        local entry = T.CatalogById[id]
        if #ids > 1 then r:info("--- " .. entry.label) end
        if entry.vehicle and not vehicle then
            r:blocked("No vehicle within 12 tiles")
        else
            local ok, err = pcall(ClientTests[id], r, player, vehicle)
            if not ok then r:fail("ERROR: " .. tostring(err)) end
        end
    end
    return r
end

local function clientChecksFor(player, vehicle)
    local ids = {}
    for _, id in ipairs(T.AutomaticClientChecks) do ids[#ids + 1] = id end
    if vehicle then for _, id in ipairs(T.AutomaticClientVehicleChecks) do ids[#ids + 1] = id end end
    return runClientChecks(player, ids, vehicle, "Client checks")
end

local function request(player, entry)
    local vehicle = targetVehicle(player)
    if not modLoaded() then
        show(player, T.SUITE .. "\nBLOCKED: KIPNVehicleServices is not enabled on this client.")
        return
    end
    if entry.side == "flow" then
        Flows[entry.id](player)
        return
    end
    if entry.side == "client" then
        local text = runClientChecks(player, { entry.id }, vehicle, T.SUITE .. " | " .. entry.label):text()
        lastResults[player:getPlayerNum()] = text
        show(player, text)
        return
    end
    local args = { id = entry.id, vehicleId = vehicle and vehicle:getId() or nil }
    if entry.id == "config" or entry.id == "all_checks" then args.clientSandbox = clientSandbox() end
    if isClient() then
        sendClientCommand(player, T.MODULE, "run", args)
    elseif T.RunServer then
        T.RunServer(player, entry.id, args)
    else
        show(player, T.SUITE .. "\nBLOCKED: The server half of the tester did not load.")
    end
end

local function localPlayer(id)
    for i = 0, getNumActivePlayers() - 1 do
        local player = getSpecificPlayer(i)
        if player and player:getOnlineID() == id then return player end
    end
    if not isClient() then return getSpecificPlayer(0) end
end

-- Appends what this client sees, once ownership changes have had time
-- to reach it.
local function clientView(player, args)
    local lines = {}
    if args.vehicleId then
        local vehicle = findVehicle(args.vehicleId)
        if not vehicle then
            lines[#lines + 1] = "SKIP: Vehicle " .. tostring(args.vehicleId) .. " is not loaded on this client"
        else
            local seen = vehicle:getModData().KIPNVehicleClaimId
            local expected = args.serverClaimId ~= "" and args.serverClaimId or nil
            local status = tostring(seen) == tostring(expected) and "PASS" or "FAIL"
            lines[#lines + 1] = status .. ": Client view: your client sees claim " .. tostring(seen) .. ", the server has " .. tostring(expected)
        end
    end
    if args.checkSeat and string.find(args.text or "", "Server ejected you", 1, true) then
        lines[#lines + 1] = (player:getVehicle() == nil and "PASS: Client view: your client also shows you outside the vehicle"
            or "FAIL: Client view: your client still shows you seated (server and client disagree)")
    end
    if args.id == "all_checks" then
        lines[#lines + 1] = clientChecksFor(player, targetVehicle(player)):text()
    end
    return table.concat(lines, "\n")
end

function T.ClientReceive(args)
    local player = localPlayer(args.playerID)
    if not player then return end
    if LilBubbyCountdown then
        -- A wait on the player (get into the vehicle): count it down; any
        -- later message ends it.
        if args.status == "INFO" and tonumber(args.countdown) then
            LilBubbyCountdown.Start(T.MODULE, tonumber(args.countdown), args.countdownLabel or args.text)
        else
            LilBubbyCountdown.Stop(T.MODULE)
        end
    end
    if args.status == "INFO" then
        print("[" .. T.MODULE .. "] " .. tostring(args.text))
        LilBubbyShowcase.Report(player, "vehicle", args.text, true)
        HaloTextHelper.addText(player, args.text)
        return
    end
    if args.life then
        T.LifeReceive(player, args)
        return
    end
    if type(args.craft) == "table" then
        -- Materials were given; craft the form here with the normal timed action.
        LilBubbyShowcase.Report(player, "vehicle", "Crafting " .. tostring(args.craft.recipe) .. " with the normal timed action...", true)
        LilBubbyCraft.Craft(player, args.craft.recipe, args.craft.output, function(ok, detail)
            args.text = (args.text or "") .. "\n" .. (ok and "PASS" or "FAIL") .. ": Crafted "
                .. tostring(args.craft.output) .. " from the materials" .. (detail and detail ~= "" and (" (" .. detail .. ")") or "")
            args.craft = nil
            queued[#queued + 1] = { player = player, args = args, due = getTimestampMs() }
        end)
        return
    end
    queued[#queued + 1] = { player = player, args = args, due = getTimestampMs() + (args.vehicleId and 1500 or 0) }
end

Events.OnTick.Add(function()
    if #queued == 0 then return end
    local now = getTimestampMs()
    for i = #queued, 1, -1 do
        local item = queued[i]
        if now >= item.due then
            table.remove(queued, i)
            local ok, extra = pcall(clientView, item.player, item.args)
            local text = item.args.text or "No result"
            if not ok then extra = "FAIL: Client view raised: " .. tostring(extra) end
            if extra ~= "" then text = text .. "\n\n" .. extra end
            print("[" .. T.MODULE .. "] " .. (string.gsub(text, "\n", " | ")))
            lastResults[item.player:getPlayerNum()] = text
            show(item.player, text)
        end
    end
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= T.MODULE or command ~= "result" or type(args) ~= "table" then return end
    T.ClientReceive(args)
end)

------------------------------------------------------------
-- MENU
------------------------------------------------------------

LilBubbyShowcase.Register("vehicle", function(index, context, objects, test)
    if test then return end
    local player = getSpecificPlayer(index)
    if not player then return end
    local tester = submenu(context, ROOT)
    local suite = submenu(tester, T.SUITE)
    suite:addOption("How these tests work", player, function(p) show(p, T.SUITE .. "\n\n" .. HELP) end)
    local vehicle = targetVehicle(player)
    local target = suite:addOption(vehicle and ("Target: " .. vehicleName(vehicle) .. " #" .. tostring(vehicle:getId()) .. " (" .. ownershipText(player, vehicle) .. ")")
        or "Target: no vehicle within 12 tiles")
    target.notAvailable = true
    if not modLoaded() then
        local missing = suite:addOption("KIPNVehicleServices is not enabled")
        missing.notAvailable = true
        return
    end
    local groups = {}
    for _, entry in ipairs(T.Catalog) do
        local menu = suite
        if entry.group then
            groups[entry.group] = groups[entry.group] or submenu(suite, entry.group)
            menu = groups[entry.group]
        end
        local option = menu:addOption(entry.label, player, request, entry)
        option.site = entry.site
        if entry.vehicle and not vehicle then option.notAvailable = true end
    end
    suite:addOption("Show last result", player, function(p)
        show(p, lastResults[p:getPlayerNum()] or "No result yet. Start with 'Run every automatic check'.")
    end)
end)
