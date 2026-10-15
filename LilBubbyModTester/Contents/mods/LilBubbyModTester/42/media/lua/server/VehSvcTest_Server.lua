require "LilBubbyDesk"
require "LilBubbySites"
require "LilBubbyPacer"
require "LilBubbyCraft"
-- COMPUTER Vehicle Claims tests: server half. Every command acts on its
-- authenticated sender and drives the live KIPNVehicleServices code:
-- the real command handlers, artifact engine, claim store and
-- enforcement. In single player the client calls VehSvcTest.RunServer
-- directly.
if isClient() then return end
require "VehSvcTest_Checks"

local T = VehSvcTest
local Tests = {}
T.ServerTests = Tests

local watchers = {}

local CLAIM_ID_KEY, OWNER_ID_KEY, OWNER_NAME_KEY = "KIPNVehicleClaimId", "KIPNVehicleOwnerSteamId", "KIPNVehicleOwnerUsername"

------------------------------------------------------------
-- LIVE MOD ACCESS
------------------------------------------------------------

local function S() return KIPN and KIPN.Server or {} end
local function CS() return S().ClaimService end
local function AS() return S().ArtifactService end
local function VC() return S().VehClaimService end
local function VA() return S().VehArtifactService end
local function VE() return S().VehEnforcement end
local function isFn(value) return type(value) == "function" end

local function command(name)
    return KIPN and KIPN.Shared and KIPN.Shared.Commands and KIPN.Shared.Commands[name]
end

local function handler(name)
    local id = command(name)
    return id and isFn(S().GetCommandHandler) and S().GetCommandHandler(id) or nil
end

local function artifactConfig()
    return AS() and isFn(AS().GetArtifactConfig) and AS().GetArtifactConfig() or nil
end

local function vehicleConfig()
    local config = S().ClaimConfig
    return config and isFn(config.GetServiceConfig) and config.GetServiceConfig("vehicle") or nil
end

local function vehicleType()
    return CS() and CS().Types and CS().Types.VEHICLE or "vehicle"
end

local function unavailableReason()
    if not KIPN or not KIPN.Server then return "KIP Network Terminal (KIPN) is not loaded on the server." end
    if not VC() or not VA() or not VE() then return "KIPNVehicleServices is not loaded on the server." end
    if not CS() or not AS() then return "KIPN claim or artifact service is unavailable." end
    return nil
end

local function steamId(player) return CS().GetPlayerSteamId(player) end

local function isAdmin(player)
    local permissions = S().Permissions
    if permissions and isFn(permissions.ResolveAccessLevel) then
        local ok, level = pcall(permissions.ResolveAccessLevel, player)
        if ok then return level == "ADMIN" end
    end
    return false
end

-- A player stand-in with a fixed identity. It records what the mod
-- says to it, so a denial can be observed without a real player.
local function proxyPlayer(id, name)
    local proxy = { said = {} }
    function proxy:getSteamID() return id end
    function proxy:getUsername() return name end
    function proxy:getOnlineID() return -1 end
    function proxy:Say(text) self.said[#self.said + 1] = tostring(text) end
    return proxy
end

-- The owner key the mod gives the test owner's claims: its account name on
-- current KIPN, its stand-in Steam ID on older releases.
local function testOwnerId()
    return tostring(steamId(proxyPlayer(T.TEST_OWNER_ID, T.TEST_OWNER_NAME)))
end

------------------------------------------------------------
-- TEST BOOKKEEPING (what cleanup may remove)
------------------------------------------------------------

local function testData()
    local data = ModData.getOrCreate(T.TAG)
    data.claims = data.claims or {}
    data.artifacts = data.artifacts or {}
    return data
end

local function remember(kind, id, owner)
    if id ~= nil then testData()[kind][tostring(id)] = tostring(owner) end
end

local function forget(kind, id)
    if id ~= nil then testData()[kind][tostring(id)] = nil end
end

local function saveClaims()
    if not isFn(S().Save) then return false end
    local ok, result = pcall(S().Save, "claims")
    return ok and result ~= false
end

------------------------------------------------------------
-- INVENTORY
------------------------------------------------------------

local function eachItem(player, visitItem)
    local seen = {}
    local function visit(container)
        if not container or seen[container] then return end
        seen[container] = true
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            visitItem(item, container)
            if instanceof(item, "InventoryContainer") then visit(item:getInventory()) end
        end
    end
    visit(player:getInventory())
end

local function itemsOfType(player, fullType)
    local found = {}
    eachItem(player, function(item, container)
        if item:getFullType() == fullType then found[#found + 1] = { item = item, container = container } end
    end)
    return found
end

local function artifactIdOf(item)
    local ok, id = pcall(AS().GetItemArtifactId, item)
    return ok and id or nil
end

local function holdsArtifact(player, artifactId)
    local held = false
    eachItem(player, function(item)
        if artifactId ~= nil and tostring(artifactIdOf(item)) == tostring(artifactId) then held = true end
    end)
    return held
end

local function removeItem(item, container)
    container = container or item:getContainer()
    if not container then return false end
    container:Remove(item)
    if isFn(sendRemoveItemFromContainer) then pcall(sendRemoveItemFromContainer, container, item) end
    return true
end

-- Adds a tagged item so cleanup can find it again.
local function giveTagged(player, fullType)
    local inventory = player:getInventory()
    local ok, item = pcall(function() return inventory:AddItem(fullType) end)
    if not ok or not item then return nil end
    item:getModData()[T.TAG] = true
    if isFn(sendAddItemToContainer) then pcall(sendAddItemToContainer, inventory, item) end
    return item
end

local function deleteArtifactRecord(artifactId)
    local data = AS().GetArtifactData()
    if data and data.records and artifactId ~= nil then data.records[tostring(artifactId)] = nil end
    pcall(AS().SaveArtifactData)
    forget("artifacts", artifactId)
end

-- Removes an item the test created and its artifact record.
local function discardTestArtifact(player, item)
    if not item then return end
    local id = artifactIdOf(item)
    local container = item:getContainer()
    if container then removeItem(item, container) end
    if id then deleteArtifactRecord(id) end
end

local function validArtifact(player, itemType, artifactType, scopeId)
    local ok, item, record, reason = pcall(AS().FindValidArtifact, player, itemType, artifactType, "vehicle", scopeId)
    if not ok then return nil, nil, tostring(item) end
    return item, record, reason
end

------------------------------------------------------------
-- VEHICLES, ZONES, COMPUTERS
------------------------------------------------------------

local function distanceTo(player, x, y)
    local dx, dy = player:getX() - x, player:getY() - y
    return math.sqrt(dx * dx + dy * dy)
end

local function resolveVehicle(player, args)
    local id = tonumber(args and args.vehicleId)
    if not id then return nil, "No vehicle was selected. Stand within 12 tiles of one (or sit in it)." end
    -- KIPN's lookup also finds vehicles in single player, where getVehicleById finds none.
    local lookup = KIPN and KIPN.Shared and KIPN.Shared.GetVehicleById or getVehicleById
    local vehicle = isFn(lookup) and lookup(id) or nil
    if not vehicle then return nil, "Vehicle " .. tostring(id) .. " is not loaded on the server." end
    if distanceTo(player, vehicle:getX(), vehicle:getY()) > T.MAX_VEHICLE_DISTANCE then
        return nil, "Vehicle " .. tostring(id) .. " is too far away. Stand within 12 tiles of it."
    end
    return vehicle
end

local function vehicleId(vehicle) return CS().GetVehicleId(vehicle) end
local function vehicleClaim(vehicle) return CS().GetClaimForTarget(vehicleType(), vehicleId(vehicle)) end

local function vehicleZone(vehicle)
    local position = CS().GetVehiclePosition(vehicle)
    if not position then return nil, nil, nil end
    local zone, zoneId = CS().GetClaimZone(position, vehicleType())
    return zone, zoneId, position
end

local function vehicleLabel(vehicle)
    local name = "vehicle"
    pcall(function() name = vehicle:getScript():getName() end)
    return name .. " #" .. tostring(vehicleId(vehicle))
end

local function describeClaim(claim)
    if not claim then return "unclaimed" end
    return "claim " .. tostring(claim.id) .. " owned by " .. tostring(claim.ownerUsername) .. " (" .. tostring(claim.ownerSteamId) .. ")"
end

local function computerPosition(id, computer)
    if computer.x ~= nil then return computer.x, computer.y, computer.z end
    if type(computer.location) == "table" then return computer.location.x, computer.location.y, computer.location.z end
    if KIPN.Shared and isFn(KIPN.Shared.ParseComputerIdCoords) then
        return KIPN.Shared.ParseComputerIdCoords(computer.locationKey or id)
    end
end

local function nearbyComputers(player, range)
    local data = isFn(S().GetData) and S().GetData() or nil
    local list = {}
    for id, computer in pairs(data and data.computers or {}) do
        if type(computer) == "table" then
            local x, y, z = computerPosition(id, computer)
            if x and y then
                local distance = distanceTo(player, x, y)
                if distance <= range then list[#list + 1] = { id = id, x = x, y = y, z = z, distance = distance } end
            end
        end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    return list
end

local function dealershipZoneOf(classification)
    if type(classification) ~= "table" then return nil end
    for _, zone in pairs(classification.zones or {}) do
        if zone.type == "dealership" then return zone end
    end
end

------------------------------------------------------------
-- VEHICLE OWNERSHIP HELPERS
------------------------------------------------------------

local function metadataOf(vehicle)
    local md = vehicle:getModData()
    return md[CLAIM_ID_KEY], md[OWNER_ID_KEY], md[OWNER_NAME_KEY]
end

local function checkMetadata(r, vehicle, claim, label)
    local claimId, ownerId, ownerName = metadataOf(vehicle)
    label = label or "Vehicle metadata"
    if claim then
        r:equal(claimId, tostring(claim.id), label .. ": claim id")
        r:equal(ownerId, tostring(claim.ownerSteamId), label .. ": owner id")
        r:equal(ownerName, tostring(claim.ownerUsername or "Unknown"), label .. ": owner name")
    else
        r:check(claimId == nil and ownerId == nil and ownerName == nil, label .. " is cleared on an unclaimed vehicle",
            "found claim=" .. tostring(claimId) .. " owner=" .. tostring(ownerName))
    end
end

-- Claims the vehicle for the stand-in test owner, which makes every
-- real player a non-owner of it.
local function assignTestOwner(player, vehicle)
    local id = vehicleId(vehicle)
    if vehicleClaim(vehicle) then return nil, "Vehicle is already claimed." end
    local _, zoneId, position = vehicleZone(vehicle)
    local owner = proxyPlayer(T.TEST_OWNER_ID, T.TEST_OWNER_NAME)
    local record, reason = CS().CreateClaimRecord(owner, vehicleType(), id, zoneId or "lilbubby-test-zone", nil, position, { lilBubbyTest = true })
    if not record then return nil, reason end
    if not saveClaims() then
        CS().RemoveClaimRecord(record.id)
        return nil, "The claim store could not be saved."
    end
    CS().SyncVehicleOwnershipMetadata(vehicle, record)
    remember("claims", record.id, steamId(player))
    return record
end

local function releaseTestClaim(claimId)
    local ok, reason = CS().ReleaseClaim(claimId, "lilbubby_test_cleanup")
    if ok then forget("claims", claimId) end
    return ok, reason
end

-- Runs fn with the vehicle claimed by someone other than the player,
-- using a temporary test-owner claim when it is unclaimed. Tests that could
-- change the claim if the mod misbehaved pass testOwnerOnly, so a real
-- player's claim is never put at risk.
local function withForeignClaim(r, player, vehicle, fn, testOwnerOnly)
    local claim = vehicleClaim(vehicle)
    local temporary = nil
    if claim and tostring(claim.ownerSteamId) == tostring(steamId(player)) then
        r:blocked("You own this vehicle. Release it, or use another vehicle.")
        return
    end
    if claim and testOwnerOnly and tostring(claim.ownerSteamId) ~= testOwnerId() then
        r:blocked("This vehicle belongs to " .. tostring(claim.ownerUsername)
            .. ". Use an unclaimed vehicle or one given to the test owner, so a real player's claim is never at risk.")
        return
    end
    if not claim then
        local reason
        temporary, reason = assignTestOwner(player, vehicle)
        if not temporary then r:blocked("Could not create a temporary test-owner claim: " .. tostring(reason)) return end
        claim = temporary
        r:info("Temporary claim " .. tostring(claim.id) .. " for " .. T.TEST_OWNER_NAME)
    end
    local ok, err = pcall(fn, claim)
    if temporary then
        local released, reason = releaseTestClaim(temporary.id)
        r:check(released, "Temporary test-owner claim released", reason)
    end
    if not ok then error(err, 0) end
end

------------------------------------------------------------
-- SHARED STEPS
------------------------------------------------------------

-- createdAt and expiresAt come from separate clock reads, so allow a
-- couple of seconds between them.
local function checkExpiry(r, record, days, label)
    local actual, expected = tonumber(record.expiresAt) or 0, T.ExpectedExpiry(record.createdAt, days)
    local close = (expected == 0 and actual == 0) or (expected > 0 and math.abs(actual - expected) <= 2)
    r:check(close, label .. " expiry follows the " .. tostring(days) .. " day setting",
        "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

-- Returns a valid tracked Registration Form, creating one if needed.
local function ensureForm(r, player)
    local config = artifactConfig()
    local item, record = validArtifact(player, T.REGISTRATION_ITEM, config.Types.Registration)
    if item then
        r:info("Using your Registration Form " .. tostring(record.id))
        return item, record
    end
    local ok, created, createdItem = VA().CreateVehicleRegistration(player)
    if not ok then
        r:blocked("CreateVehicleRegistration refused: " .. tostring(created))
        return nil
    end
    remember("artifacts", created.id, steamId(player))
    r:info("Created test Registration Form " .. tostring(created.id))
    return createdItem, created
end

-- Issues a title scoped to zoneId through IssueVehicleClaim and checks
-- every documented effect.
local function issueTitle(r, player, zoneId)
    local config = artifactConfig()
    local form, formRecord = ensureForm(r, player)
    if not form then return nil end
    local ok, claimRecord, claimItem, dropped = VA().IssueVehicleClaim(player, zoneId)
    if not r:check(ok, "IssueVehicleClaim issues a Vehicle Title", not ok and claimRecord or nil) then return nil end
    remember("artifacts", claimRecord.id, steamId(player))
    r:check(claimItem and claimItem:getFullType() == T.TITLE_ITEM, "Issued item is a Vehicle Title")
    r:equal(tostring(artifactIdOf(claimItem)), tostring(claimRecord.id), "Title carries its artifact id")
    r:equal(claimRecord.type, config.Types.Claim, "Title record type")
    r:equal(claimRecord.service, "vehicle", "Title record service")
    r:equal(tostring(claimRecord.scopeId), tostring(zoneId), "Title is scoped to the dealership zone")
    r:check(claimRecord.consumed == false, "Title record starts unconsumed")
    checkExpiry(r, claimRecord, (vehicleConfig() or {}).ClaimTokenExpiryDays, "Title")
    local formAfter = AS().GetArtifact(formRecord.id)
    r:check(formAfter and formAfter.consumed == true, "Registration Form record is consumed")
    r:check(not holdsArtifact(player, formRecord.id), "Registration Form is removed from inventory")
    if dropped then
        r:info("Your inventory was full: the title was dropped on the ground. Pick it up before claiming.")
    else
        r:check(holdsArtifact(player, claimRecord.id), "Title is in your inventory")
    end
    return claimItem, claimRecord
end

-- Returns a title valid for zoneId, issuing one if needed.
local function ensureTitle(r, player, zoneId)
    local config = artifactConfig()
    local item, record = validArtifact(player, T.TITLE_ITEM, config.Types.Claim, zoneId)
    if item then
        r:info("Using your Vehicle Title " .. tostring(record.id))
        return item, record
    end
    return issueTitle(r, player, zoneId)
end

-- Claims the vehicle through the real CLAIM_VEHICLE handler.
local function claimVehicle(r, player, vehicle)
    local claim = vehicleClaim(vehicle)
    if claim then r:blocked("Vehicle is already " .. describeClaim(claim) .. ".") return nil end
    local zone, zoneId = vehicleZone(vehicle)
    if not zone then r:blocked("Move the vehicle into an active dealership zone first.") return nil end
    local withinQuota, quotaReason = CS().CheckMaxClaimsForType(player, vehicleType())
    if not withinQuota then r:blocked(tostring(quotaReason) .. " Release a vehicle claim first.") return nil end
    local title, titleRecord = ensureTitle(r, player, zoneId)
    if not title then return nil end

    local claimHandler = handler("CLAIM_VEHICLE")
    if not r:check(isFn(claimHandler), "CLAIM_VEHICLE handler registered") then return nil end
    local ok, result = claimHandler(player, { vehicleId = vehicle:getId() })
    if not r:check(ok == true and result == "CLAIM_SUCCESSFUL", "CLAIM_VEHICLE succeeds", result) then return nil end

    claim = vehicleClaim(vehicle)
    if not r:check(claim ~= nil, "Claim record exists for the vehicle") then return nil end
    remember("claims", claim.id, steamId(player))
    r:equal(tostring(claim.ownerSteamId), tostring(steamId(player)), "Claim owner is you")
    r:equal(claim.ownerUsername, player:getUsername(), "Claim owner name")
    r:equal(tostring(claim.zoneId), tostring(zoneId), "Claim zone is the vehicle's dealership")
    r:equal(tostring(claim.artifactId), tostring(titleRecord.id), "Claim records the title it used")
    local titleAfter = AS().GetArtifact(titleRecord.id)
    r:check(titleAfter and titleAfter.consumed == true, "Title record is consumed")
    r:check(not holdsArtifact(player, titleRecord.id), "Title is removed from inventory")
    checkMetadata(r, vehicle, claim)
    r:check(VE().CanAccessVehicle(vehicle, player) == true, "Server lets you (the owner) access the vehicle")
    local intruderAllowed = VE().CanAccessVehicle(vehicle, proxyPlayer(T.INTRUDER_ID, "Intruder"))
    r:check(intruderAllowed == false, "Server denies a non-owner")
    return claim
end

-- Releases the claim through the real RELEASE_CLAIM handler.
local function releaseVehicle(r, player, vehicle)
    local claim = vehicleClaim(vehicle)
    if not claim then r:blocked("Vehicle is not claimed.") return false end
    if tostring(claim.ownerSteamId) ~= tostring(steamId(player)) then
        r:blocked("You do not own this vehicle's claim (" .. describeClaim(claim) .. ").")
        return false
    end
    local releaseHandler = handler("RELEASE_CLAIM")
    if not r:check(isFn(releaseHandler), "RELEASE_CLAIM handler registered") then return false end
    releaseHandler(player, { claimId = claim.id })
    local after = CS().GetClaim(claim.id)
    r:check(after and after.active == false, "Claim is inactive after release")
    r:equal(after and after.releaseReason, "player_released", "Release reason")
    r:check(vehicleClaim(vehicle) == nil, "Vehicle is unclaimed after release")
    checkMetadata(r, vehicle, nil, "Vehicle metadata after release")
    r:check(VE().CanAccessVehicle(vehicle, proxyPlayer(T.INTRUDER_ID, "Intruder")) == true, "Anyone may use the vehicle again")
    forget("claims", claim.id)
    return true
end

------------------------------------------------------------
-- SETUP AND CONFIGURATION
------------------------------------------------------------

local function listHas(list, value)
    if type(list) ~= "table" then return false end
    if list[value] == true then return true end
    for _, entry in pairs(list) do if entry == value then return true end end
    return false
end

local function sortedKeys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- Sets tbl[key] for the length of fn, then always puts it back. Server
-- Lua is single-threaded, so nobody else sees the temporary value.
local function withValue(tbl, key, value, fn)
    local old = tbl[key]
    tbl[key] = value
    local ok, err = pcall(fn)
    tbl[key] = old
    if not ok then error(err, 0) end
end

function Tests.setup(r, ctx)
    local services = S()._registeredServices
    local service = type(services) == "table" and services.VehicleServices or nil
    if r:check(service ~= nil, "VehicleServices add-on service is registered") then
        r:equal(service.order, 610, "Service order (after every Terminal built-in)")
        for _, dependency in ipairs(T.SERVICE_DEPENDENCIES) do
            r:check(listHas(service.dependsOn, dependency), "Service depends on " .. dependency)
        end
    end

    local world = S().WorldRegistry
    local zoneType = world and world.RegisteredZoneTypes and world.RegisteredZoneTypes.dealership
    if r:check(zoneType ~= nil, "dealership zone type is registered") then
        r:equal(zoneType.label, "Car Dealership", "Zone type label")
        r:equal(zoneType.classificationField, "dealership", "Zone type classification field")
        for _, capability in ipairs(T.ZONE_CAPABILITIES) do
            r:check(type(zoneType.defaultCapabilities) == "table" and zoneType.defaultCapabilities[capability] == true,
                "Dealership zones grant " .. capability)
        end
        r:equal(world.ZoneTypes and world.ZoneTypes.DEALERSHIP, "dealership", "ZoneTypes.DEALERSHIP")
    end

    local permissions = S().Permissions
    for _, id in ipairs(sortedKeys(T.PERMISSIONS)) do
        r:check(permissions and isFn(permissions.GetDefinition) and permissions.GetDefinition(id) ~= nil, "Permission " .. id .. " is registered")
        for _, role in ipairs(sortedKeys(T.PERMISSIONS[id])) do
            local granted = T.PERMISSIONS[id][role]
            local defaults = permissions and permissions.DefaultRoles and permissions.DefaultRoles[role]
            local has = type(defaults) == "table" and type(defaults.permissions) == "table" and defaults.permissions[id] == true
            r:equal(has, granted, role .. " role " .. (granted and "is granted " or "is not granted ") .. id)
            if permissions and isFn(permissions.GetRolePermissions) then
                local live = permissions.GetRolePermissions(role)[id] == true
                if live ~= granted then
                    r:info(role .. " role on this server " .. (live and "has " or "lacks ") .. id .. ": a server-configured role replaces the default")
                end
            end
        end
    end

    local claimType = isFn(CS().GetClaimTypeDef) and CS().GetClaimTypeDef("vehicle") or nil
    if r:check(claimType ~= nil, "vehicle claim type is registered") then
        r:equal(claimType.requiredCapability, "vehicle.claim", "Claim type needs the vehicle.claim zone capability")
        r:equal(claimType.serviceConfigKey, "Vehicle", "Claim type uses the Vehicle policy")
        r:check(claimType.validateTarget == VC().ValidateVehicleTarget, "Claim type validates targets with VehClaimService")
        r:check(claimType.validateClaimArtifact == VC().ValidateVehicleClaimArtifact, "Claim type validates titles with VehClaimService")
        r:check(claimType.claim == VC().ClaimVehicle, "Claim type claims with VehClaimService.ClaimVehicle")
        r:check(isFn(claimType.onAfterRelease), "Claim type clears vehicle metadata after a release (onAfterRelease)")
    end
    r:equal(CS().Types and CS().Types.VEHICLE, "vehicle", "ClaimService.Types.VEHICLE")

    local config = artifactConfig()
    local artifactType = config and config.ArtifactTypeDefs and config.ArtifactTypeDefs.Vehicle
    if r:check(artifactType ~= nil, "Vehicle artifact type is registered") then
        r:equal(artifactType.zoneClassification, "DEALERSHIP", "Vehicle artifacts belong to dealership computers")
    end
    r:equal(config and config.RegistrationItems and config.RegistrationItems.Vehicle, T.REGISTRATION_ITEM, "Registration item type")
    r:equal(config and config.ClaimItems and config.ClaimItems.Vehicle, T.TITLE_ITEM, "Title item type")

    local claimConfig = S().ClaimConfig
    r:equal(claimConfig and claimConfig.ServiceKeyByClaimType and claimConfig.ServiceKeyByClaimType.vehicle, "Vehicle",
        "vehicle claims read the Vehicle policy block")
    r:check(vehicleConfig() ~= nil, "Vehicle policy block is registered")

    for _, name in ipairs(T.COMMANDS) do
        r:check(command(name) ~= nil, "KIPN.Shared.Commands." .. name .. " exists")
        r:check(isFn(handler(name)), name .. " handler is registered")
    end

    local apps = S().ApplicationRegistry
    for _, id in ipairs(sortedKeys(T.APPS)) do
        local want = T.APPS[id]
        local app = apps and isFn(apps.Get) and apps.Get(id) or nil
        if r:check(app ~= nil, id .. " terminal app is registered") then
            r:equal(app.screen, want.screen, id .. " opens " .. want.screen)
            r:check(listHas(app.permissions, want.permission), id .. " needs " .. want.permission)
            r:check(app.requiresSession == true, id .. " needs a signed-in session")
            r:check(app.enabled ~= false, id .. " is enabled")
            if want.classification then
                r:check(listHas(app.classifications, want.classification), id .. " is offered only on " .. want.classification .. " computers")
            else
                local any = false
                for _ in pairs(app.classifications or {}) do any = true end
                r:check(not any, id .. " is offered on every computer")
            end
        end
    end
end

-- The artifact switches: admin runtime overrides win over the sandbox.
local function expectedSwitch(sandbox, key)
    local settings = S().Settings
    local admin = settings and isFn(settings.GetAdminOverrides) and settings.GetAdminOverrides("Artifact") or {}
    if admin[key] ~= nil then return admin[key], "admin override" end
    return sandbox[key], "sandbox"
end

function Tests.config(r, ctx)
    local sandbox = SandboxVars and SandboxVars.KIPN
    if not r:check(type(sandbox) == "table", "SandboxVars.KIPN exists on the server") then return end
    local policy = vehicleConfig()
    if not r:check(policy ~= nil, "Vehicle claim policy exists") then return end
    for _, key in ipairs(T.SANDBOX_KEYS) do
        local field = T.SANDBOX_TO_CLAIM_CONFIG[key]
        if field then r:equal(policy[field], sandbox[key], key .. " reaches the server policy (" .. field .. ")") end
        if sandbox[key] ~= T.SANDBOX_DEFAULTS[key] then
            r:info(key .. " = " .. tostring(sandbox[key]) .. " (ships as " .. tostring(T.SANDBOX_DEFAULTS[key]) .. ")")
        end
    end
    local config = artifactConfig()
    local registration, registrationSource = expectedSwitch(sandbox, "VehicleRegistrationEnabled")
    r:equal(config.Registration.VehicleEnabled, registration, "VehicleRegistrationEnabled reaches the artifact policy (" .. registrationSource .. ")")
    local claims, claimsSource = expectedSwitch(sandbox, "VehicleClaimsEnabled")
    r:equal(config.Claim.VehicleEnabled, claims, "VehicleClaimsEnabled reaches the artifact policy (" .. claimsSource .. ")")

    local client = ctx.args and ctx.args.clientSandbox
    if type(client) ~= "table" then
        r:skip("Your client sent no sandbox values to compare")
        return
    end
    for _, key in ipairs(T.SANDBOX_KEYS) do
        r:equal(client[key], sandbox[key], "Your client has the server's " .. key)
    end
end

function Tests.scripts(r, ctx)
    local manager = getScriptManager()
    for _, want in ipairs(T.ITEM_SCRIPTS) do
        local script = manager:FindItem(want.type)
        if r:check(script ~= nil, want.type .. " item script exists") then
            r:equal(script:getDisplayName(), want.name, want.type .. " display name")
            local ok, tags = pcall(function() return tostring(script:getTags()) end)
            if ok then
                r:check(string.find(tags, want.tag, 1, true) ~= nil, want.type .. " has the kipn:" .. want.tag .. " tag", tags)
            else
                r:skip(want.type .. " tags cannot be read in this build")
            end
        end
    end
    local recipe = LilBubbyCraft.FindRecipe(T.RECIPE)
    if not r:check(recipe ~= nil, T.RECIPE .. " recipe exists") then return end
    local amounts = {}
    local inputs = recipe:getInputs()
    for i = 0, inputs:size() - 1 do
        local input = inputs:get(i)
        local possible = input:getPossibleInputItems()
        for j = 0, (possible and possible:size() or 0) - 1 do
            amounts[possible:get(j):getFullName()] = input:getIntAmount()
        end
    end
    for _, material in ipairs(T.RECIPE_INPUTS) do
        r:equal(amounts[material[1]], material[2], "Recipe takes " .. material[2] .. " x " .. material[1])
    end
    local ok, output = pcall(function() return recipe:getOutputs():get(0):getPossibleResultItems():get(0):getFullName() end)
    r:equal(ok and output or nil, T.REGISTRATION_ITEM, "Recipe makes a Vehicle Registration Form")
    local timeOk, time = pcall(function() return recipe:getTime() end)
    if timeOk then r:info("Recipe time: " .. tostring(time)) end
end

function Tests.toggles(r, ctx)
    local player, config = ctx.player, artifactConfig()
    local REGISTRATION_OFF, CLAIMS_OFF = "Vehicle registration is disabled.", "Vehicle claims are disabled."
    r:info("Live switches: registration " .. tostring(config.Registration.VehicleEnabled) .. ", claims " .. tostring(config.Claim.VehicleEnabled)
        .. ". Each is turned off for a moment and restored.")
    local function registrationRefusals(label)
        local ok, reason, item = VA().CreateVehicleRegistration(player)
        if ok then discardTestArtifact(player, item) end
        r:check(not ok and reason == REGISTRATION_OFF, label .. ": creating a form is refused", reason)
        ok, reason = VA().RegisterVehicleRegistration(player, {})
        r:check(not ok and reason == REGISTRATION_OFF, label .. ": registering a crafted form is refused", reason)
        ok, reason = VA().IssueVehicleClaim(player, "lilbubby-test-zone")
        r:check(not ok and reason == REGISTRATION_OFF, label .. ": issuing a title is refused", reason)
    end
    withValue(config.Registration, "VehicleEnabled", false, function() registrationRefusals("Vehicle registration off") end)
    withValue(config.Registration, "Enabled", false, function() registrationRefusals("All registration off") end)
    withValue(config.Claim, "VehicleEnabled", false, function()
        local ok, reason = VA().IssueVehicleClaim(player, "lilbubby-test-zone")
        local expected = config.Registration.VehicleEnabled == false and REGISTRATION_OFF or CLAIMS_OFF
        r:check(not ok and reason == expected, "Vehicle claims off: issuing a title is refused", reason)
        ok, reason = VA().ValidateVehicleClaim(player, {}, "lilbubby-test-zone")
        r:check(not ok and reason == CLAIMS_OFF, "Vehicle claims off: a title does not validate", reason)
        local item, _, findReason = VA().FindPlayerVehicleClaimArtifact(player, nil)
        r:check(item == nil and findReason == CLAIMS_OFF, "Vehicle claims off: title search finds nothing", findReason)
    end)
    r:info("Switches restored: registration " .. tostring(config.Registration.VehicleEnabled) .. ", claims " .. tostring(config.Claim.VehicleEnabled))
end

------------------------------------------------------------
-- REGISTRATION FORMS
------------------------------------------------------------

function Tests.form_create(r, ctx)
    local player, config = ctx.player, artifactConfig()
    -- The materials come with the test: you watch your character craft one
    -- form with the normal timed action, and the server tracks another.
    local manager = getScriptManager()
    for _, material in ipairs(T.RECIPE_MATERIALS) do
        if manager:FindItem(material[1]) == nil then
            r:skip(material[1] .. " does not exist in this game build")
        else
            local given = 0
            for _ = 1, material[2] do
                if giveTagged(player, material[1]) then given = given + 1 end
            end
            r:equal(given, material[2], "Gave " .. material[1])
        end
    end
    ctx.payload.craft = { recipe = T.RECIPE, output = T.REGISTRATION_ITEM }
    local ok, record, item = VA().CreateVehicleRegistration(player)
    if not r:check(ok, "CreateVehicleRegistration creates a form", not ok and record or nil) then return end
    remember("artifacts", record.id, steamId(player))
    r:check(item and item:getFullType() == T.REGISTRATION_ITEM, "Created item is a Vehicle Registration Form")
    r:equal(tostring(artifactIdOf(item)), tostring(record.id), "Form carries its artifact id")
    r:equal(record.type, config.Types.Registration, "Form record type")
    r:equal(record.service, "vehicle", "Form record service")
    r:check(record.consumed == false, "Form record starts unconsumed")
    checkExpiry(r, record, (vehicleConfig() or {}).RegistrationExpiryDays, "Form")
    local valid, reason = AS().ValidateArtifact(player, record.id, config.Types.Registration, "vehicle")
    r:check(valid, "Form validates", reason)
end

function Tests.form_register(r, ctx)
    local player, config = ctx.player, artifactConfig()
    local item = giveTagged(player, T.REGISTRATION_ITEM)
    if not r:check(item ~= nil, "Gave an untracked Registration Form") then return end
    r:check(artifactIdOf(item) == nil, "New form has no artifact id yet")
    local ok, record = VA().RegisterVehicleRegistration(player, item)
    if r:check(ok, "RegisterVehicleRegistration tracks the form", not ok and record or nil) then
        remember("artifacts", record.id, steamId(player))
        r:equal(tostring(artifactIdOf(item)), tostring(record.id), "Form now carries its artifact id")
        r:equal(record.type, config.Types.Registration, "Form record type")
        local again, reason = VA().RegisterVehicleRegistration(player, item)
        r:check(not again and reason == "Registration item is already tracked.", "Registering the same form twice is refused", reason)
    end
    local paper = giveTagged(player, "Base.SheetPaper2")
    if paper then
        local wrong, reason = VA().RegisterVehicleRegistration(player, paper)
        r:check(not wrong and reason == "Incorrect registration item.", "A different item is refused", reason)
        removeItem(paper)
    end
    local missing, reason = VA().RegisterVehicleRegistration(player, nil)
    r:check(not missing and reason == "Registration item unavailable.", "A missing item is refused", reason)
end

local function artifactStatus(player, item, expectedType)
    local id = artifactIdOf(item)
    if not id then return "untracked (crafted, not yet processed)", false end
    local record = AS().GetArtifact(id)
    if not record then return "artifact " .. tostring(id) .. ": record missing", false end
    local valid, reason = AS().ValidateArtifact(player, id, expectedType, "vehicle")
    local state = valid and "VALID" or tostring(reason)
    return "artifact " .. tostring(id) .. " scope=" .. tostring(record.scopeId) .. " expiresAt=" .. tostring(record.expiresAt) .. " -> " .. state, valid
end

function Tests.my_forms(r, ctx)
    local player, config = ctx.player, artifactConfig()
    for _, kind in ipairs({
        { label = "Registration Form", item = T.REGISTRATION_ITEM, type = config.Types.Registration },
        { label = "Vehicle Title", item = T.TITLE_ITEM, type = config.Types.Claim },
    }) do
        local held, anyValid = itemsOfType(player, kind.item), false
        r:info(#held .. " " .. kind.label .. "(s) in your inventory")
        for _, found in ipairs(held) do
            local text, valid = artifactStatus(player, found.item, kind.type)
            anyValid = anyValid or valid
            r:info(kind.label .. ": " .. text)
        end
        local item = validArtifact(player, kind.item, kind.type)
        r:equal(item ~= nil, anyValid, "The server finds a valid " .. kind.label .. " exactly when one of yours is valid")
    end
end

------------------------------------------------------------
-- VEHICLE TITLES
------------------------------------------------------------

function Tests.issue_zone(r, ctx)
    local zone, zoneId = vehicleZone(ctx.vehicle)
    if not zone then r:blocked("This vehicle is not inside an active dealership zone.") return end
    r:info("Dealership zone " .. tostring(zoneId))
    issueTitle(r, ctx.player, zoneId)
end

function Tests.issue_desk(r, ctx)
    local player = ctx.player
    local computer = nearbyComputers(player, 6)[1]
    local classification = computer and S().WorldRegistry.GetComputerClassification(computer.id)
    if not (classification and classification.dealership == true and dealershipZoneOf(classification)) then
        -- No dealership computer here: a test desk in the designated zone (LilBubbyDesk).
        local id, notes = LilBubbyDesk.Ensure(player, "dealership")
        if not id then r:blocked("No dealership computer nearby, and a test desk could not be set up: " .. tostring(notes)) return end
        r:info("Test desk: " .. notes)
        computer = { id = id }
        classification = S().WorldRegistry.GetComputerClassification(id)
    end
    local dealer = dealershipZoneOf(classification)
    local expectSuccess = classification and classification.dealership == true and dealer ~= nil
    r:info("Computer " .. tostring(computer.id) .. ": dealership=" .. tostring(expectSuccess) .. " zone=" .. tostring(dealer and dealer.id))
    local deskHandler = handler("ISSUE_VEHICLE_CLAIM")
    if not r:check(isFn(deskHandler), "ISSUE_VEHICLE_CLAIM handler registered") then return end

    local untracked = 0
    for _, found in ipairs(itemsOfType(player, T.REGISTRATION_ITEM)) do
        if not artifactIdOf(found.item) then untracked = untracked + 1 end
    end
    if expectSuccess and untracked == 0 then ensureForm(r, player) end
    if untracked > 0 then r:info("The desk will use one of your " .. untracked .. " crafted (untracked) forms first") end

    local before = {}
    for _, found in ipairs(itemsOfType(player, T.TITLE_ITEM)) do before[tostring(artifactIdOf(found.item))] = true end
    local ok, result = deskHandler(player, { computerId = computer.id })
    if not expectSuccess then
        r:check(not ok, "A computer outside a dealership zone refuses to issue titles", result)
        r:info("Refusal reason: " .. tostring(result))
        return
    end
    if not r:check(ok == true and result == "CLAIM_ARTIFACT_ISSUED", "Dealership computer issues a Vehicle Title", result) then return end
    local issued
    for _, found in ipairs(itemsOfType(player, T.TITLE_ITEM)) do
        local id = artifactIdOf(found.item)
        if id and not before[tostring(id)] then issued = AS().GetArtifact(id) end
    end
    if r:check(issued ~= nil, "New title is in your inventory (or check the ground if your inventory was full)") then
        remember("artifacts", issued.id, steamId(player))
        r:equal(tostring(issued.scopeId), tostring(dealer.id), "Title is scoped to the computer's dealership zone")
    end
end

function Tests.issue_rejections(r, ctx)
    local player, config = ctx.player, artifactConfig()
    local deskHandler = handler("ISSUE_VEHICLE_CLAIM")
    if r:check(isFn(deskHandler), "ISSUE_VEHICLE_CLAIM handler registered") then
        local ok, reason = deskHandler(player, {})
        r:check(not ok and reason == "Computer could not be identified.", "Desk request without a computer is refused", reason)
        ok, reason = deskHandler(player, { computerId = "lilbubby-no-such-computer" })
        r:check(not ok, "Desk request for an unknown computer is refused", reason)
        r:info("Unknown computer reason: " .. tostring(reason))
    end
    local ok, reason = VA().IssueVehicleClaim(player, nil)
    r:check(not ok and reason == "Registration zone unavailable.", "Issuing without a dealership zone is refused", reason)
    ok, reason = VA().IssueVehicleClaim(nil, "zone")
    r:check(not ok and reason == "Player unavailable.", "Issuing without a player is refused", reason)
    ok, reason = VA().CreateVehicleRegistration(nil)
    r:check(not ok and reason == "Player unavailable.", "Creating a form without a player is refused", reason)
    local form = validArtifact(player, T.REGISTRATION_ITEM, config.Types.Registration)
    if form then
        r:skip("You hold a valid Registration Form; drop or use it to test the no-form refusal")
    else
        local titlesBefore = #itemsOfType(player, T.TITLE_ITEM)
        ok, reason = VA().IssueVehicleClaim(player, "lilbubby-test-zone")
        r:check(not ok, "Issuing without a valid Registration Form is refused", reason)
        r:equal(#itemsOfType(player, T.TITLE_ITEM), titlesBefore, "No title was issued")
    end
end

function Tests.title_rejections(r, ctx)
    local player, vehicle, config = ctx.player, ctx.vehicle, artifactConfig()
    local zone, zoneId = vehicleZone(vehicle)
    if not zone then r:blocked("This vehicle is not inside an active dealership zone.") return end
    local ok, reason = VA().ValidateVehicleClaim(player, nil, zoneId)
    r:check(not ok and reason == "Vehicle claim artifact required.", "No title is refused", reason)

    local paper = giveTagged(player, "Base.SheetPaper2")
    if paper then
        ok, reason = VA().ValidateVehicleClaim(player, paper, nil)
        r:check(not ok and reason == "Vehicle zone could not be determined.", "Unknown zone is refused", reason)
        ok, reason = VA().ValidateVehicleClaim(player, paper, zoneId)
        r:check(not ok and reason == "Incorrect claim artifact.", "A different item is refused", reason)
        removeItem(paper)
    end
    local blank = giveTagged(player, T.TITLE_ITEM)
    if blank then
        ok, reason = VA().ValidateVehicleClaim(player, blank, zoneId)
        r:check(not ok and reason == "Invalid claim artifact.", "An untracked (crafted or spawned) title is refused", reason)
        removeItem(blank)
    end

    local wrongRecord, wrongItem = AS().CreatePhysicalArtifact(player, config.Types.Claim, "vehicle", T.TITLE_ITEM, "lilbubby-wrong-zone")
    if r:check(wrongRecord and wrongItem, "Created a title scoped to another dealership") then
        remember("artifacts", wrongRecord.id, steamId(player))
        ok, reason = VA().ValidateVehicleClaim(player, wrongItem, zoneId)
        r:check(not ok and reason == "Artifact is not valid for this zone.", "Title from another dealership is refused", reason)
        local found = VA().FindPlayerVehicleClaimArtifact(player, zoneId)
        r:check(found ~= wrongItem, "Title search for this dealership skips the other dealership's title")
        ok, reason = VA().ConsumeVehicleClaim(player, wrongItem, zoneId)
        r:check(not ok, "Consuming a wrong-zone title is refused", reason)
        r:check(AS().GetArtifact(wrongRecord.id).consumed == false and holdsArtifact(player, wrongRecord.id), "Refused title is not consumed")

        wrongRecord.scopeId = zoneId
        wrongRecord.consumed = true
        ok, reason = VA().ValidateVehicleClaim(player, wrongItem, zoneId)
        r:check(not ok and reason == "Artifact has already been consumed.", "A consumed title is refused", reason)
        wrongRecord.consumed = false
        wrongRecord.expiresAt = 1
        ok, reason = VA().ValidateVehicleClaim(player, wrongItem, zoneId)
        r:check(not ok and reason == "Artifact has expired.", "An expired title is refused", reason)
        discardTestArtifact(player, wrongItem)
    end

    local goodRecord, goodItem = AS().CreatePhysicalArtifact(player, config.Types.Claim, "vehicle", T.TITLE_ITEM, zoneId)
    if r:check(goodRecord and goodItem, "Created a title for this dealership") then
        remember("artifacts", goodRecord.id, steamId(player))
        local valid, result = VA().ValidateVehicleClaim(player, goodItem, zoneId)
        r:check(valid and result and result.id == goodRecord.id, "Title for this dealership validates", not valid and result or nil)
        local foundItem, foundRecord = VA().FindPlayerVehicleClaimArtifact(player, zoneId)
        r:check(foundItem ~= nil and foundRecord and tostring(foundRecord.scopeId) == tostring(zoneId), "Title search for this dealership finds a matching title")
        discardTestArtifact(player, goodItem)
    end
end

------------------------------------------------------------
-- VEHICLE CLAIMS
------------------------------------------------------------

function Tests.target_check(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local claim = vehicleClaim(vehicle)
    local zone, zoneId = vehicleZone(vehicle)
    r:info(vehicleLabel(vehicle) .. ": " .. describeClaim(claim) .. ", zone=" .. tostring(zoneId))
    local ok, reason, data = VC().ValidateVehicleTarget(player, vehicle)
    if claim then
        r:check(not ok and reason == "Vehicle is already claimed.", "Claimed vehicle is not claimable", reason)
    elseif not zone then
        r:check(not ok, "Vehicle outside a dealership zone is not claimable", reason)
        r:info("Reason: " .. tostring(reason))
    else
        r:check(ok, "Vehicle in a dealership zone is claimable", reason)
        r:equal(data and tostring(data.zoneId), tostring(zoneId), "Target check reports the vehicle's zone")
        r:equal(data and data.vehicleId, vehicleId(vehicle), "Target check reports the vehicle id")
    end
    local towed = vehicle:getVehicleTowedBy() ~= nil or vehicle:getVehicleTowing() ~= nil
    if towed then r:info("Vehicle is towing or towed: the right-click Claim option is hidden, but the server does not check this") end
    ok, reason = VC().ValidateVehicleTarget(nil, vehicle)
    r:check(not ok and reason == "Player is required.", "Target check without a player is refused", reason)
    ok, reason = VC().ValidateVehicleTarget(player, nil)
    r:check(not ok and reason == "Vehicle is unavailable.", "Target check without a vehicle is refused", reason)
end

function Tests.claim(r, ctx)
    claimVehicle(r, ctx.player, ctx.vehicle)
end

function Tests.full_flow(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local claim = vehicleClaim(vehicle)
    if claim then r:blocked("Vehicle is already " .. describeClaim(claim) .. ".") return end
    local zone, zoneId = vehicleZone(vehicle)
    if not zone then r:blocked("Move the vehicle into an active dealership zone first.") return end
    r:info("Step 1: Registration Form and Vehicle Title")
    local title = issueTitle(r, player, zoneId)
    if not title then return end
    -- A second title for another dealership: CLAIM_VEHICLE must pick the
    -- one for this vehicle's dealership, not whichever it finds first.
    local decoyRecord, decoyItem = AS().CreatePhysicalArtifact(player, artifactConfig().Types.Claim, "vehicle", T.TITLE_ITEM, "lilbubby-wrong-zone")
    if decoyRecord then remember("artifacts", decoyRecord.id, steamId(player)) end
    r:info("Step 2: claim (you also carry a title for another dealership)")
    local claimed = claimVehicle(r, player, vehicle)
    if decoyRecord and decoyItem then
        local after = AS().GetArtifact(decoyRecord.id)
        r:check(after and after.consumed == false and holdsArtifact(player, decoyRecord.id),
            "The other dealership's title was left alone")
        discardTestArtifact(player, decoyItem)
    end
    if not claimed then return end
    r:info("Step 3: release")
    releaseVehicle(r, player, vehicle)
end

function Tests.claim_rejections(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local claimHandler = handler("CLAIM_VEHICLE")
    if not r:check(isFn(claimHandler), "CLAIM_VEHICLE handler registered") then return end
    local ok, reason = claimHandler(player, {})
    r:check(not ok and reason == "Vehicle could not be resolved.", "Claim without a vehicle id is refused", reason)
    ok, reason = claimHandler(player, { vehicleId = -987654 })
    r:check(not ok and reason == "Vehicle could not be resolved.", "Claim of an unknown vehicle is refused", reason)

    local zone, zoneId = vehicleZone(vehicle)
    local title = zone and validArtifact(player, T.TITLE_ITEM, artifactConfig().Types.Claim, zoneId)
    if not title and not vehicleClaim(vehicle) and zone then
        ok, reason = claimHandler(player, { vehicleId = vehicle:getId() })
        r:check(not ok, "Claim without a Vehicle Title is refused", reason)
        r:check(vehicleClaim(vehicle) == nil, "Vehicle stays unclaimed")
    elseif title then
        r:skip("You hold a title for this dealership; the no-title refusal needs none")
    end
    ok, reason = VC().ClaimVehicle(player, vehicle, nil)
    r:check(not ok, "ClaimVehicle without a title item is refused", reason)

    withForeignClaim(r, player, vehicle, function(claim)
        local before = vehicleClaim(vehicle)
        local refused, refusal = claimHandler(player, { vehicleId = vehicle:getId() })
        r:check(not refused, "Claiming someone else's vehicle is refused", refusal)
        r:info("Refusal reason: " .. tostring(refusal))
        local after = vehicleClaim(vehicle)
        r:check(after and after.id == before.id and after.ownerSteamId == before.ownerSteamId, "Existing claim is unchanged")
        local valid, targetReason = VC().ValidateVehicleTarget(player, vehicle)
        r:check(not valid and targetReason == "Vehicle is already claimed.", "Target check reports the vehicle is claimed", targetReason)
        if title then
            r:check(holdsArtifact(player, artifactIdOf(title)), "Your title was not consumed by the refused claim")
        end
    end)
end

function Tests.my_claims(r, ctx)
    local player = ctx.player
    local config = vehicleConfig() or {}
    local count = 0
    for _, claim in pairs(CS().GetPlayerClaims(player)) do
        if claim.type == vehicleType() and claim.active ~= false then
            count = count + 1
            r:info("Claim " .. tostring(claim.id) .. " vehicle #" .. tostring(claim.targetId) .. " zone=" .. tostring(claim.zoneId)
                .. " created day " .. tostring(claim.createdAtWorldDays) .. " expired=" .. tostring(CS().IsClaimExpired(claim)))
        end
    end
    local max = tonumber(config.MaxClaimsPerPlayer) or 0
    r:info("You hold " .. count .. " vehicle claim(s); limit " .. (max > 0 and tostring(max) or "unlimited"))
    local within = CS().CheckMaxClaimsForType(player, vehicleType())
    r:equal(within == true, max <= 0 or count < max, "Claim limit check")

    local days = tonumber(config.OwnershipExpiryDays) or 0
    local now = CS().GetWorldDays and CS().GetWorldDays() or nil
    if not now then
        r:skip("World day count unavailable")
    else
        local old = { type = vehicleType(), active = true, createdAtWorldDays = now - math.max(days, 1) - 1 }
        r:equal(CS().IsClaimExpired(old), days > 0, "An old claim " .. (days > 0 and "expires" or "never expires") .. " (OwnershipExpiryDays=" .. days .. ")")
        local fresh = { type = vehicleType(), active = true, createdAtWorldDays = now }
        r:equal(CS().IsClaimExpired(fresh), false, "A new claim is not expired")
    end
end

-- A target id no vehicle can have, for a stand-in claim.
local QUOTA_TARGET = "-424242"

local function vehicleClaimCount(player)
    local count = 0
    for _, claim in pairs(CS().GetPlayerClaims(player)) do
        if claim.type == vehicleType() and claim.active ~= false then count = count + 1 end
    end
    return count
end

function Tests.quota(r, ctx)
    local player, policy = ctx.player, vehicleConfig()
    if not policy then r:blocked("The Vehicle claim policy is missing.") return end
    local count, filler = vehicleClaimCount(player), nil
    if count == 0 then
        local position = { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
        local reason
        filler, reason = CS().CreateClaimRecord(player, vehicleType(), QUOTA_TARGET, "lilbubby-test-zone", nil, position, { lilBubbyTest = true })
        if not filler then r:blocked("Could not create a stand-in claim to reach the limit: " .. tostring(reason)) return end
        count = 1
        r:info("You hold no vehicle claims, so a stand-in claim " .. tostring(filler.id) .. " (no real vehicle) counts as one")
    end
    r:info("The limit is set to your " .. count .. " claim(s) for this test, then restored to " .. tostring(policy.MaxClaimsPerPlayer))
    local ok, err = pcall(function()
        withValue(policy, "MaxClaimsPerPlayer", count, function()
            local within, reason = CS().CheckMaxClaimsForType(player, vehicleType())
            r:check(within == false, "At the limit, the claim limit check refuses", reason)
            r:info("Refusal reason: " .. tostring(reason))
        end)
        withValue(policy, "MaxClaimsPerPlayer", count + 1, function()
            r:check(CS().CheckMaxClaimsForType(player, vehicleType()) == true, "Below the limit, the check allows")
        end)
        withValue(policy, "MaxClaimsPerPlayer", 0, function()
            r:check(CS().CheckMaxClaimsForType(player, vehicleType()) == true, "A limit of 0 means unlimited")
        end)
        local vehicle = ctx.vehicle
        if not vehicle then r:skip("No vehicle nearby: a real CLAIM_VEHICLE past the limit was not tried") return end
        if vehicleClaim(vehicle) then r:skip("Vehicle is claimed: a real CLAIM_VEHICLE past the limit needs an unclaimed one") return end
        local zone, zoneId = vehicleZone(vehicle)
        if not zone then r:skip("Vehicle is outside a dealership: a real CLAIM_VEHICLE past the limit needs one inside") return end
        local title, titleRecord = ensureTitle(r, player, zoneId)
        if not title then return end
        withValue(policy, "MaxClaimsPerPlayer", count, function()
            local claimed, reason = handler("CLAIM_VEHICLE")(player, { vehicleId = vehicle:getId() })
            r:check(not claimed, "CLAIM_VEHICLE past the limit is refused", reason)
            local claim = vehicleClaim(vehicle)
            if claim then remember("claims", claim.id, steamId(player)) end
            r:check(claim == nil, "Vehicle stays unclaimed")
            local after = AS().GetArtifact(titleRecord.id)
            r:check(after and after.consumed == false and holdsArtifact(player, titleRecord.id), "Your title was not used up")
        end)
    end)
    if filler then
        CS().RemoveClaimRecord(filler.id)
        r:check(CS().GetClaimForTarget(vehicleType(), QUOTA_TARGET) == nil, "Stand-in claim removed")
    end
    r:equal(vehicleClaimCount(player), filler and 0 or count, "Your claim count is back to what it was")
    if not ok then error(err, 0) end
end

function Tests.metadata(r, ctx)
    local claim = vehicleClaim(ctx.vehicle)
    r:info(vehicleLabel(ctx.vehicle) .. ": " .. describeClaim(claim))
    checkMetadata(r, ctx.vehicle, claim)
end

-- Wipes the vehicle's ownership metadata and waits for the mod's
-- periodic resync (every 300 server ticks) to write it back.
function Tests.resync(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    if player:getVehicle() == vehicle then
        r:blocked("Get out of the vehicle first: a seated occupant's check also restores the metadata, which would hide the periodic resync.")
        return
    end
    local claim, temporary = vehicleClaim(vehicle), nil
    if claim and tostring(claim.ownerSteamId) ~= testOwnerId() and tostring(claim.ownerSteamId) ~= tostring(steamId(player)) then
        r:blocked("This vehicle belongs to " .. tostring(claim.ownerUsername) .. ". Use an unclaimed vehicle, yours, or one given to the test owner.")
        return
    end
    if not claim then
        local reason
        temporary, reason = assignTestOwner(player, vehicle)
        if not temporary then r:blocked("Could not create a temporary test-owner claim: " .. tostring(reason)) return end
        claim = temporary
        r:info("Temporary claim " .. tostring(claim.id) .. " for " .. T.TEST_OWNER_NAME)
    end
    checkMetadata(r, vehicle, claim, "Metadata before the wipe")
    local md = vehicle:getModData()
    md[CLAIM_ID_KEY], md[OWNER_ID_KEY], md[OWNER_NAME_KEY] = nil, nil, nil
    pcall(function() vehicle:transmitModData() end)
    r:check(metadataOf(vehicle) == nil, "Metadata wiped (the claim record is untouched)")
    local function done()
        if not temporary then return end
        local released, reason = releaseTestClaim(temporary.id)
        r:check(released, "Temporary test-owner claim released", reason)
    end
    local started = getTimestampMs()
    ctx.notice = "Ownership metadata wiped on " .. vehicleLabel(vehicle) .. ": waiting up to 90 seconds for the periodic resync."
    ctx.countdown, ctx.countdownLabel = 90, "Waiting for the periodic resync"
    ctx.async = {
        deadline = started + 90000,
        poll = function()
            if metadataOf(vehicle) == nil then return false end
            r:pass(string.format("Metadata restored %.1f seconds after the wipe", (getTimestampMs() - started) / 1000))
            checkMetadata(r, vehicle, claim, "Restored metadata")
            done()
            return true
        end,
        timeout = function()
            r:fail("Metadata was still missing 90 seconds after the wipe")
            CS().SyncVehicleOwnershipMetadata(vehicle, claim)
            r:info("The tester wrote the metadata back itself")
            done()
        end,
    }
end

------------------------------------------------------------
-- RELEASE
------------------------------------------------------------

function Tests.release(r, ctx)
    releaseVehicle(r, ctx.player, ctx.vehicle)
end

function Tests.release_not_owner(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local releaseHandler = handler("RELEASE_CLAIM")
    if not r:check(isFn(releaseHandler), "RELEASE_CLAIM handler registered") then return end
    withForeignClaim(r, player, vehicle, function(claim)
        releaseHandler(player, { claimId = claim.id })
        local after = CS().GetClaim(claim.id)
        r:check(after and after.active ~= false, "Claim stays active after a non-owner release request")
        r:equal(vehicleClaim(vehicle) and vehicleClaim(vehicle).id, claim.id, "Vehicle still belongs to " .. tostring(claim.ownerUsername))
        local claimId = metadataOf(vehicle)
        r:equal(claimId, tostring(claim.id), "Vehicle metadata is unchanged")
        releaseHandler(player, { claimId = "lilbubby-no-such-claim" })
        r:check(CS().GetClaim(claim.id).active ~= false, "Unknown claim id changes nothing")
    end, true)
end

------------------------------------------------------------
-- NON-OWNER ENFORCEMENT
------------------------------------------------------------

function Tests.owner_assign(r, ctx)
    local record, reason = assignTestOwner(ctx.player, ctx.vehicle)
    if not record then r:blocked("Could not give the vehicle to the test owner: " .. tostring(reason)) return end
    r:pass("Claim " .. tostring(record.id) .. " created for " .. T.TEST_OWNER_NAME)
    checkMetadata(r, ctx.vehicle, record)
    r:equal(VE().CanAccessVehicle(ctx.vehicle, ctx.player), false, "Server now treats you as a non-owner")
    r:info("Now try the real game: right-click the vehicle, try to enter, open doors, lock, tow, mechanics. Then run the Client features tests. Remove the test owner when done.")
end

function Tests.owner_clear(r, ctx)
    local claim = vehicleClaim(ctx.vehicle)
    if not claim or tostring(claim.ownerSteamId) ~= testOwnerId() then
        r:blocked("This vehicle is not owned by the test owner (" .. describeClaim(claim) .. ").")
        return
    end
    local ok, reason = releaseTestClaim(claim.id)
    r:check(ok, "Test-owner claim released", reason)
    r:check(vehicleClaim(ctx.vehicle) == nil, "Vehicle is unclaimed")
    checkMetadata(r, ctx.vehicle, nil)
end

function Tests.access(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local claim = VE().GetVehicleClaim(vehicle)
    r:equal(claim and claim.id, vehicleClaim(vehicle) and vehicleClaim(vehicle).id, "Enforcement sees the same claim as the claim store")
    local mine = claim and tostring(claim.ownerSteamId) == tostring(steamId(player))
    r:info(vehicleLabel(vehicle) .. ": " .. describeClaim(claim) .. "; you are " .. (not claim and "free to use it" or (mine and "the owner" or "a non-owner"))
        .. (isAdmin(player) and " (KIPN admin)" or ""))
    local allowed = VE().CanAccessVehicle(vehicle, player)
    r:equal(allowed, claim == nil or mine == true, "Server access decision for you")
    local intruder = VE().CanAccessVehicle(vehicle, proxyPlayer(T.INTRUDER_ID, "Intruder"))
    r:equal(intruder, claim == nil, "Server access decision for a stranger")
    if claim then
        local owner = proxyPlayer(tostring(claim.ownerSteamId), tostring(claim.ownerUsername))
        r:equal(VE().CanAccessVehicle(vehicle, owner), true, "Server access decision for the owner")
    end
end

function Tests.commands(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local commands = rawget(_G, "ClientCommands")
    local vehicleCommands = type(commands) == "table" and commands.vehicle or nil
    if type(vehicleCommands) ~= "table" then
        r:info("No global ClientCommands.vehicle table exists on this server. Build 42 declares ClientCommands as local in server/ClientCommands.lua and has no Lua vehicle commands, so VehEnforcement has nothing to wrap.")
        for _, name in ipairs(T.INTERCEPTED_COMMANDS) do
            r:fail(name .. " is not intercepted: the documented non-owner rule is not enforced on the server")
        end
        return
    end
    local config = vehicleConfig()
    withForeignClaim(r, player, vehicle, function()
        local door, engineDoor
        for i = 0, vehicle:getPartCount() - 1 do
            local part = vehicle:getPartByIndex(i)
            if part:getDoor() and part:getId() ~= "EngineDoor" and not door then door = part end
            if part:getId() == "EngineDoor" then engineDoor = part end
        end
        local doorUnlocked = door and door:getInventoryItem() ~= nil and not door:getDoor():isLocked()
        r:info("Door used for setDoorOpen: " .. tostring(door and door:getId()) .. " unlocked=" .. tostring(doorUnlocked))
        for _, name in ipairs(T.INTERCEPTED_COMMANDS) do
            local fn = vehicleCommands[name]
            if not isFn(fn) then
                r:fail(name .. " is not intercepted: ClientCommands.vehicle." .. name .. " does not exist")
            else
                -- A stand-in stranger: the wrapper only speaks to it when it denies.
                -- The unknown part id keeps an allowed command from changing anything.
                local stranger = proxyPlayer(T.INTRUDER_ID, "Intruder")
                local args = { vehicle = vehicle:getId(), part = "LilBubbyNoSuchPart" }
                if name == "setDoorOpen" and door then
                    args.part = door:getId()
                    args.open = door:getDoor():isOpen()
                end
                pcall(fn, stranger, args)
                local denied = false
                for _, text in ipairs(stranger.said) do
                    if string.find(text, "claimed", 1, true) then denied = true end
                end
                local expected = T.ExpectedNonOwnerCommand(name, config, doorUnlocked)
                r:equal(not denied, expected, name .. ": non-owner " .. (expected and "allowed" or "denied"))
            end
        end
        if engineDoor then r:info("Hood (EngineDoor) opening is a client-side mechanics gate; see Client features") end
    end)
end

function Tests.eject(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local claim = vehicleClaim(vehicle)
    if claim then
        r:blocked("Use an unclaimed vehicle (" .. describeClaim(claim) .. "). The test gives it to the test owner once you are seated.")
        return
    end
    if isAdmin(player) then r:info("You are a KIPN admin. README says admins are unaffected; the server rule only exempts the owner.") end
    local phase, started, record = "enter", getTimestampMs(), nil
    ctx.notice = "Seat ejection test armed: get into " .. vehicleLabel(vehicle) .. " within 30 seconds."
    ctx.countdown, ctx.countdownLabel = 30, "Get into " .. vehicleLabel(vehicle) .. " now"
    ctx.async = {
        deadline = started + 30000,
        poll = function(watch)
            if phase == "enter" then
                if player:getVehicle() ~= vehicle then return false end
                local reason
                record, reason = assignTestOwner(player, vehicle)
                if not record then
                    r:blocked("Could not give the vehicle to the test owner: " .. tostring(reason))
                    return true
                end
                r:info("You are seated. Vehicle given to " .. T.TEST_OWNER_NAME .. " (claim " .. tostring(record.id) .. ")")
                watch.notice = "You are seated and the vehicle now belongs to someone else: waiting up to 10 seconds for the server to eject you"
                phase, started, watch.deadline = "eject", getTimestampMs(), getTimestampMs() + 10000
                return false
            end
            if player:getVehicle() == vehicle then return false end
            r:pass(string.format("Server ejected you %.1f seconds after the vehicle was claimed", (getTimestampMs() - started) / 1000))
            local released, reason = releaseTestClaim(record.id)
            r:check(released, "Test-owner claim released", reason)
            return true
        end,
        timeout = function()
            if phase == "enter" then
                r:blocked("You did not get into the vehicle within 30 seconds.")
                return
            end
            r:fail("You were still seated 10 seconds after the vehicle was claimed by someone else")
            local released, reason = releaseTestClaim(record.id)
            r:check(released, "Test-owner claim released", reason)
        end,
    }
    ctx.payload.checkSeat = true
end

-- A KIPN admin is checked as themselves. Anyone else watches a stand-in
-- admin try: KIPN answers ADMIN for the stand-in during this one check, and
-- the player's own rights and KIPN's admin list are never touched.
function Tests.admin_exempt(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    local permissions = S().Permissions
    local who, resolve = player, nil
    if not isAdmin(player) then
        if not (permissions and isFn(permissions.ResolveAccessLevel)) then r:blocked("KIPN permissions are unavailable.") return end
        who, resolve = proxyPlayer(T.TEST_ADMIN_ID, "LilBubby Test Admin"), permissions.ResolveAccessLevel
        r:info("You are not a KIPN admin, so a stand-in admin tries the vehicle for you")
    end
    withForeignClaim(r, player, vehicle, function()
        if resolve then
            permissions.ResolveAccessLevel = function(p) if p == who then return "ADMIN" end return resolve(p) end
        end
        local ok, allowed = pcall(VE().CanAccessVehicle, vehicle, who)
        if resolve then permissions.ResolveAccessLevel = resolve end
        if not ok then error(allowed, 0) end
        r:check(allowed == true, "Admins may access a claimed vehicle (README section 5)",
            "the server only allows the owner; admins are ejected and blocked like anyone else")
    end)
end

------------------------------------------------------------
-- VEHICLE CLAIM LIFECYCLE
--
-- Server steps of the client's "Vehicle claim lifecycle" flow. The
-- client crafts the form, uses the desk and claims the car the way a
-- player does; these steps set up the world and check what the mod
-- did. life_claimed then runs one in-game day on the server clock with
-- OwnershipExpiryDays = 1 and waits for the mod to release the claim.
------------------------------------------------------------

local Life = {}
T.LifeSteps = Life

local LIFE_ZONE_RADIUS = 10
local LIFE_CAR = "Base.CarNormal"
-- The server clock moves a quarter hour every 250 ms: one day in ~24 s.
local LIFE_STEP_HOURS, LIFE_STEP_MS = 0.25, 250
local LIFE_CHECKPOINTS = { 0.25, 0.5, 0.75, 0.95 }
local LIFE_RELEASE_WAIT_MS = 90000

local function worldDays() return CS().GetWorldDays() end

-- A square with a clear 3x5 patch around it, whole inside the zone
-- centred on the computer.
local function freeCarSquare(cx, cy, cz, radius)
    for r = 3, radius - 3 do
        for dx = -r, r do
            for dy = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local clear = true
                    for ox = -1, 1 do
                        for oy = -2, 2 do
                            local square = getCell():getGridSquare(cx + dx + ox, cy + dy + oy, cz)
                            if not (square and square:TreatAsSolidFloor() and square:isFree(false) and not square:getVehicleContainer()) then
                                clear = false
                            end
                        end
                    end
                    if clear then return getCell():getGridSquare(cx + dx, cy + dy, cz) end
                end
            end
        end
    end
end

local function restoreExpiry(r)
    local data, policy = testData(), vehicleConfig()
    if data.expiryRestore == nil or not policy then return end
    policy.OwnershipExpiryDays = data.expiryRestore
    if r then r:info("OwnershipExpiryDays restored to " .. tostring(data.expiryRestore)) end
    data.expiryRestore = nil
end

-- The remaining ownership KIPN itself reports: its claims list
-- (GET_MY_CLAIMS), recorded on the way out and still sent to you.
local function reportedRemaining(player, claimId)
    local server = S()
    local original, seen, found = server.SendToPlayer, false, nil
    server.SendToPlayer = function(target, event, payload)
        if event == KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA and type(payload) == "table" then
            seen = true
            for _, entry in ipairs(payload) do
                if type(entry) == "table" and tostring(entry.id) == tostring(claimId) then found = entry end
            end
        end
        return original(target, event, payload)
    end
    local ok, err = pcall(CS().SendPlayerClaims, player, {})
    server.SendToPlayer = original
    if not ok then return nil, "the claims list raised: " .. tostring(err) end
    if not seen then return nil, "no claims list was sent" end
    if not found then return nil, "the claim is not in your claims list" end
    return tonumber(found.expiryDaysRemaining), found
end

-- Moves the server clock on by hours, a step small enough for the
-- game's own day and night bookkeeping to follow it.
-- getWorldAgeHours() counts whole days from nightsSurvived, which the game
-- only increments when time passes 7:00 by itself; a jump across 7:00
-- skips it and world age falls back a day, so the missed night is added.
local function stepClock(hours)
    local gameTime = getGameTime()
    local before = gameTime:getWorldAgeHours()
    gameTime:setTimeOfDay(gameTime:getTimeOfDay() + hours)
    if gameTime:getWorldAgeHours() < before + hours - 12 then
        gameTime:setNightsSurvived(gameTime:getNightsSurvived() + 1)
    end
end

function Life.life_prepare(r, ctx)
    local player = ctx.player
    local computerId, notes = LilBubbyDesk.Ensure(player, "dealership")
    if not computerId then r:blocked("Could not set up a dealership computer: " .. tostring(notes)) return end
    r:info("Test desk: " .. notes)
    local classification = S().WorldRegistry.GetComputerClassification(computerId)
    local zone = dealershipZoneOf(classification)
    if not r:check(classification and classification.dealership == true and zone ~= nil, "The computer is inside a dealership zone") then return end
    -- The car goes inside the designated dealership zone, around its middle.
    local site = LilBubbySites.Get("dealership")
    local spot = site and site.spot
    local square = spot and freeCarSquare(spot.x, spot.y, spot.z, LIFE_ZONE_RADIUS)
    if not square then r:blocked("No clear 3x5 patch for a car inside the dealership test zone.") return end
    local vehicle = addVehicleDebug(LIFE_CAR, IsoDirections.S, nil, square) or square:getVehicleContainer()
    if not r:check(vehicle ~= nil, "A test car was parked at " .. square:getX() .. "," .. square:getY()) then return end
    vehicle:getModData()[T.TAG] = true
    pcall(function() vehicle:transmitModData() end)
    local data = testData()
    data.vehicles = data.vehicles or {}
    data.vehicles[tostring(vehicle:getId())] = tostring(steamId(player))
    local _, carZoneId = vehicleZone(vehicle)
    r:equal(tostring(carZoneId), tostring(zone.id), "The car is in the computer's dealership zone")
    r:check(vehicleClaim(vehicle) == nil, "The car is unclaimed")
    for _, material in ipairs(T.RECIPE_MATERIALS) do
        local given = 0
        for _ = 1, material[2] do
            if giveTagged(player, material[1]) then given = given + 1 end
        end
        r:equal(given, material[2], "Gave you " .. material[2] .. " x " .. material[1])
    end
    return { computerId = computerId, zoneId = zone.id, vehicleId = vehicle:getId() }
end

function Life.life_form(r, ctx)
    local untracked = 0
    for _, found in ipairs(itemsOfType(ctx.player, T.REGISTRATION_ITEM)) do
        if not artifactIdOf(found.item) then untracked = untracked + 1 end
    end
    r:check(untracked >= 1, "The server sees your crafted Registration Form, not yet registered", untracked .. " untracked form(s)")
    local leftover = 0
    eachItem(ctx.player, function(item)
        if item:getModData()[T.TAG] and item:getFullType() == "Base.SheetPaper2" then leftover = leftover + 1 end
    end)
    r:equal(leftover, 0, "The craft used up the paper the test gave you")
    return { forms = untracked }
end

function Life.life_titled(r, ctx)
    local player, args, config = ctx.player, ctx.args, artifactConfig()
    local zoneId = args.zoneId
    if args.refused then
        r:fail("The dealership computer refused the Registration Form: " .. tostring(args.refused))
        -- Carry on the way the desk would have, so the rest of the lifecycle is still checked.
        for _, found in ipairs(itemsOfType(player, T.REGISTRATION_ITEM)) do
            if not artifactIdOf(found.item) then VA().RegisterVehicleRegistration(player, found.item) end
        end
        local ok, reason = VA().IssueVehicleClaim(player, zoneId)
        if not r:check(ok, "Issued the title directly instead (IssueVehicleClaim), to test the rest", not ok and reason or nil) then return end
    end
    r:equal(#itemsOfType(player, T.REGISTRATION_ITEM), 0, "The Registration Form was used up")
    local titles = {}
    for _, found in ipairs(itemsOfType(player, T.TITLE_ITEM)) do
        local record = artifactIdOf(found.item) and AS().GetArtifact(artifactIdOf(found.item))
        if record and tostring(record.scopeId) == tostring(zoneId) and record.consumed == false then titles[#titles + 1] = record end
    end
    if not r:check(#titles >= 1, "You hold a Vehicle Title for this dealership", #titles .. " found") then return end
    local record = titles[#titles]
    remember("artifacts", record.id, steamId(player))
    r:equal(record.type, config.Types.Claim, "Title record type")
    r:equal(record.service, "vehicle", "Title record service")
    checkExpiry(r, record, (vehicleConfig() or {}).ClaimTokenExpiryDays, "Title")
    local valid, reason = VA().ValidateVehicleClaim(player, validArtifact(player, T.TITLE_ITEM, config.Types.Claim, zoneId), zoneId)
    r:check(valid, "The title is valid for this dealership", not valid and reason or nil)
    return { titleId = record.id }
end

function Life.life_claimed(r, ctx)
    local player, vehicle = ctx.player, ctx.vehicle
    if not vehicle then r:blocked("The test car is not loaded on the server.") return end
    local claim = vehicleClaim(vehicle)
    if not r:check(claim ~= nil, "The server has a claim on the car") then return end
    remember("claims", claim.id, steamId(player))
    r:equal(tostring(claim.ownerSteamId), tostring(steamId(player)), "The claim is yours")
    r:equal(tostring(claim.artifactId), tostring(ctx.args.titleId), "The claim used your title")
    local title = AS().GetArtifact(ctx.args.titleId)
    r:check(title and title.consumed == true and not holdsArtifact(player, ctx.args.titleId), "The title was used up")
    checkMetadata(r, vehicle, claim)
    r:check(VE().CanAccessVehicle(vehicle, player) == true, "You may use the car")
    r:check(VE().CanAccessVehicle(vehicle, proxyPlayer(T.INTRUDER_ID, "Intruder")) == false, "Anyone else is kept out")

    local policy = vehicleConfig()
    local data = testData()
    if data.expiryRestore == nil then data.expiryRestore = policy.OwnershipExpiryDays end
    r:info("OwnershipExpiryDays is " .. tostring(policy.OwnershipExpiryDays) .. " on this server; set to 1 for this test")
    policy.OwnershipExpiryDays = 1
    local anchor = tonumber(claim.lastRenewedAtWorldDays) or tonumber(claim.createdAtWorldDays)
    if not r:check(anchor ~= nil, "The claim records when ownership began") then restoreExpiry(r) return end
    local remaining, detail = reportedRemaining(player, claim.id)
    r:check(remaining ~= nil and math.abs(remaining - (1 - (worldDays() - anchor))) <= 0.02,
        string.format("Right after claiming, KIPN reports %.2f day(s) of ownership left", remaining or -1), remaining == nil and detail or nil)

    local started, lastDays, checkpoint, releaseDeadline = getTimestampMs(), worldDays(), 1, nil
    local nextStep = started
    local function done()
        forget("claims", claim.id)
        restoreExpiry(r)
    end
    local function finalChecks(releasedAfterMs)
        r:pass(string.format("KIPN released the claim on its own %.1f s after the day ran out", releasedAfterMs / 1000))
        local after = CS().GetClaim(claim.id)
        r:check(after and after.active == false, "The claim is no longer active")
        r:equal(after and after.releaseReason, "ownership_expired", "Release reason")
        local held = after and tonumber(after.releasedAtWorldDays) and tonumber(after.releasedAtWorldDays) - anchor
        r:check(held and held >= 1 and held <= 1.1, string.format("Ownership lasted %.2f in-game days (limit 1)", held or -1))
        local still = false
        for _, mine in pairs(CS().GetPlayerClaims(player)) do
            if tostring(mine.id) == tostring(claim.id) then still = true end
        end
        r:check(not still, "The claim is gone from your claims")
        checkMetadata(r, vehicle, nil, "The car's ownership metadata")
        r:check(VE().CanAccessVehicle(vehicle, proxyPlayer(T.INTRUDER_ID, "Intruder")) == true, "Anyone may use the car again")
        local claimable, reason = VC().ValidateVehicleTarget(player, vehicle)
        r:check(claimable, "The car can be claimed again", not claimable and reason or nil)
    end

    ctx.notice = string.format("You own the test car. The server clock now runs through one in-game day (about %d s).",
        math.floor(24 / LIFE_STEP_HOURS * LIFE_STEP_MS / 1000))
    ctx.async = {
        deadline = started + 600000,
        poll = function(watch)
            local now = getTimestampMs()
            local metadataId = metadataOf(vehicle)
            if releaseDeadline then
                if metadataId == nil then
                    finalChecks(now - (releaseDeadline - LIFE_RELEASE_WAIT_MS))
                    done()
                    return true
                end
                if now < releaseDeadline then return false end
                r:fail("The claim was still active " .. LIFE_RELEASE_WAIT_MS / 1000 .. " s after one day of ownership ran out")
                done()
                return true
            end
            if now < nextStep then return false end
            nextStep = now + LIFE_STEP_MS
            local days = worldDays()
            if days < lastDays - 0.001 then
                r:fail(string.format("World time went backwards (%.3f to %.3f days) while the clock was moved", lastDays, days))
                done()
                return true
            end
            lastDays = days
            local elapsed = days - anchor
            if metadataId == nil then
                r:fail(string.format("Ownership ended early, after %.2f days", elapsed))
                done()
                return true
            end
            while checkpoint <= #LIFE_CHECKPOINTS and elapsed >= LIFE_CHECKPOINTS[checkpoint] do
                local left, why = reportedRemaining(player, claim.id)
                r:check(left ~= nil and math.abs(left - (1 - elapsed)) <= 0.05,
                    string.format("After %.2f days KIPN reports %.2f day(s) of ownership left", elapsed, left or -1), left == nil and why or nil)
                local record = CS().GetClaim(claim.id)
                r:check(record and record.active ~= false, string.format("The car is still yours after %.2f days", elapsed))
                watch.notice = string.format("Owned for %.2f of 1 in-game day; KIPN says %.2f day(s) left", elapsed, left or -1)
                checkpoint = checkpoint + 1
            end
            if elapsed >= 1.02 then
                releaseDeadline = now + LIFE_RELEASE_WAIT_MS
                r:info(string.format("One day of ownership has passed (%.2f days, %.1f s of real time); the server clock is left as it is",
                    elapsed, (now - started) / 1000))
                watch.notice = "One day has passed: waiting for KIPN to end your ownership (up to " .. LIFE_RELEASE_WAIT_MS / 1000 .. " s)"
                return false
            end
            if now - started > 300000 then
                r:fail(string.format("The world advanced only %.2f days in 5 minutes of stepping the clock", elapsed))
                done()
                return true
            end
            stepClock(LIFE_STEP_HOURS)
            return false
        end,
        timeout = function()
            r:fail("The lifecycle's day did not finish within 10 minutes")
            done()
        end,
    }
    return { claimId = claim.id }
end

------------------------------------------------------------
-- CLEANUP AND ALL CHECKS
------------------------------------------------------------

function Tests.cleanup(r, ctx)
    local player = ctx.player
    local me = tostring(steamId(player))
    local data = testData()
    for i = #watchers, 1, -1 do
        if watchers[i].player == player then
            if watchers[i].timeout then pcall(watchers[i].timeout, watchers[i]) end
            table.remove(watchers, i)
        end
    end
    local released = 0
    for claimId, owner in pairs(data.claims) do
        if owner == me then
            local claim = CS().GetClaim(claimId)
            if claim and claim.active ~= false then
                local ok, reason = CS().ReleaseClaim(claimId, "lilbubby_test_cleanup")
                if ok then released = released + 1 else r:fail("Could not release claim " .. claimId .. ": " .. tostring(reason)) end
            end
            data.claims[claimId] = nil
        end
    end
    r:pass("Released " .. released .. " test claim(s)")
    local mine = {}
    for artifactId, owner in pairs(data.artifacts) do
        if owner == me then mine[artifactId] = true end
    end
    local doomed = {}
    eachItem(player, function(item, container)
        local id = artifactIdOf(item)
        if item:getModData()[T.TAG] or (id and mine[tostring(id)]) then doomed[#doomed + 1] = { item = item, container = container } end
    end)
    for _, entry in ipairs(doomed) do removeItem(entry.item, entry.container) end
    r:pass("Removed " .. #doomed .. " test item(s) from your inventory")
    local records = 0
    for artifactId in pairs(mine) do
        deleteArtifactRecord(artifactId)
        records = records + 1
    end
    r:pass("Deleted " .. records .. " test artifact record(s)")
    local cars = 0
    for id, owner in pairs(data.vehicles or {}) do
        if owner == me then
            local car = resolveVehicle(player, { vehicleId = id })
            if car and car:getModData()[T.TAG] then
                pcall(function() car:permanentlyRemove() end)
                cars = cars + 1
            end
            data.vehicles[id] = nil
        end
    end
    r:pass("Removed " .. cars .. " test car(s)")
    restoreExpiry(r)
    local objects, zones = LilBubbyDesk.Cleanup(player)
    r:pass("Removed " .. objects .. " test desk object(s) and deactivated " .. zones .. " test zone(s)")
    r:info("Claims you made with the normal right-click menu are untouched.")
end

function Tests.all_checks(r, ctx)
    local ids = {}
    for _, id in ipairs(T.AutomaticChecks) do ids[#ids + 1] = id end
    if ctx.vehicle then
        for _, id in ipairs(T.AutomaticVehicleChecks) do ids[#ids + 1] = id end
    else
        r:skip("No vehicle nearby: vehicle checks were not run")
    end
    for _, id in ipairs(ids) do
        r:info("--- " .. T.CatalogById[id].label)
        local ok, err = pcall(Tests[id], r, ctx)
        if not ok then r:fail(id .. " raised: " .. tostring(err)) end
    end
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------

local function deliver(player, payload)
    print("[" .. T.MODULE .. "] " .. tostring(player:getUsername()) .. " | " .. (string.gsub(payload.text or "", "\n", " | ")))
    payload.playerID = player:getOnlineID()
    if isServer() then
        sendServerCommand(player, T.MODULE, "result", payload)
    elseif T.ClientReceive then
        T.ClientReceive(payload)
    end
end

local function finish(r, ctx)
    if ctx.vehicle then
        ctx.payload.vehicleId = ctx.vehicle:getId()
        local ok, claim = pcall(vehicleClaim, ctx.vehicle)
        ctx.payload.serverClaimId = ok and claim and tostring(claim.id) or ""
    end
    ctx.payload.text = r:text()
    if ctx.payload.life then ctx.payload.lines, ctx.payload.counts = r.lines, r.counts end
    deliver(ctx.player, ctx.payload)
end

function T.RunServer(player, id, args)
    args = type(args) == "table" and args or {}
    local entry = T.CatalogById[id]
    local test = Tests[id]
    local life = Life[id] ~= nil
    if life then
        -- A step of the lifecycle flow: not a menu entry of its own.
        entry, test = { id = id, label = "Vehicle claim lifecycle: " .. id, side = "server", vehicle = id == "life_claimed" }, Life[id]
    end
    local r = T.NewReport(T.SUITE .. " | " .. (entry and entry.label or tostring(id)))
    local ctx = { player = player, args = args, payload = { id = id, life = life or nil } }
    local reason = unavailableReason()
    if not entry or entry.side ~= "server" or not test then
        r:fail("Unknown test: " .. tostring(id))
    elseif reason then
        r:blocked(reason)
    else
        if entry.vehicle or args.vehicleId then
            local vehicle, vehicleReason = resolveVehicle(player, args)
            ctx.vehicle = vehicle
            if not vehicle and entry.vehicle then r:blocked(vehicleReason) end
        end
        if ctx.vehicle or not entry.vehicle then
            local ok, result = pcall(test, r, ctx)
            if not ok then r:fail("ERROR: " .. tostring(result)) elseif life then ctx.payload.data = result end
        end
    end
    if ctx.async then
        ctx.async.player, ctx.async.report, ctx.async.ctx = player, r, ctx
        watchers[#watchers + 1] = ctx.async
        deliver(player, { text = ctx.notice or "Test running. The result will appear when it finishes.", status = "INFO",
            countdown = ctx.countdown, countdownLabel = ctx.countdownLabel })
        return
    end
    finish(r, ctx)
end

Events.OnTick.Add(function()
    if #watchers == 0 then return end
    local now = getTimestampMs()
    for i = #watchers, 1, -1 do
        local watch = watchers[i]
        local ok, done = pcall(watch.poll, watch)
        if watch.notice then
            -- A step the player should know about, mid-test.
            pcall(deliver, watch.player, { text = watch.notice, status = "INFO" })
            watch.notice = nil
        end
        if not ok then
            watch.report:fail("ERROR: " .. tostring(done))
            done = true
        elseif not done and now > watch.deadline then
            local timedOut, err = pcall(watch.timeout, watch)
            if not timedOut then watch.report:fail("ERROR: " .. tostring(err)) end
            done = true
        end
        if done then
            table.remove(watchers, i)
            local delivered, err = pcall(finish, watch.report, watch.ctx)
            if not delivered then print("[" .. T.MODULE .. "] could not deliver result: " .. tostring(err)) end
        end
    end
end)

Events.OnClientCommand.Add(function(module, commandName, player, args)
    if module ~= T.MODULE or commandName ~= "run" or not player or player:isDead() then return end
    -- Requests are queued behind the previous one, never dropped.
    LilBubbyPacer.Run(player, T.MODULE, 100, function()
        T.RunServer(player, type(args) == "table" and args.id, args)
    end)
end)
