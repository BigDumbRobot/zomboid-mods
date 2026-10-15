-- Shared pieces of the COMPUTER Vehicle Claims test suite: the result
-- report, the test catalog used to build the menu, and the expected
-- outcomes the server and client checks compare the live mod against.
VehSvcTest = VehSvcTest or {}
VehSvcTest.MODULE = "LilBubbyVehSvcTest"
VehSvcTest.TAG = "LilBubbyVehSvcTest"
VehSvcTest.SUITE = "COMPUTER Vehicle Claims tests"
VehSvcTest.MOD_ID = "KIPNVehicleServices"

-- Stand-in identities. Neither can ever match a real Steam ID.
VehSvcTest.TEST_OWNER_ID = "LILBUBBY_TEST_OWNER"
VehSvcTest.TEST_OWNER_NAME = "LilBubby Test Owner"
VehSvcTest.INTRUDER_ID = "LILBUBBY_TEST_INTRUDER"
VehSvcTest.TEST_ADMIN_ID = "LILBUBBY_TEST_ADMIN"

VehSvcTest.REGISTRATION_ITEM = "Base.KIPNVehicleRegistration"
VehSvcTest.TITLE_ITEM = "Base.KIPNVehicleClaimArtifact"
VehSvcTest.RECIPE = "KIPN.CreateVehicleRegistration"
VehSvcTest.MAX_VEHICLE_DISTANCE = 12

-- Recipe inputs from KIPN_VehicleArtifactRecipes.txt.
VehSvcTest.RECIPE_MATERIALS = {
    { "Base.SheetPaper2", 3 },
    { "Base.Pen", 1 },
    { "Base.Stapler", 1 },
    { "Base.Staples", 1 }, -- drainable box; the recipe draws 2 uses from it
    { "Base.Paperclip", 1 },
}

-- What the recipe itself asks for (the Staples box gives 2 uses).
VehSvcTest.RECIPE_INPUTS = {
    { "Base.SheetPaper2", 3 },
    { "Base.Pen", 1 },
    { "Base.Stapler", 1 },
    { "Base.Staples", 2 },
    { "Base.Paperclip", 1 },
}
VehSvcTest.ITEM_SCRIPTS = {
    { type = "Base.KIPNVehicleRegistration", name = "Vehicle Registration Form", tag = "vehicle_registration" },
    { type = "Base.KIPNVehicleClaimArtifact", name = "Vehicle Title", tag = "vehicle_claim" },
}

local Report = {}
Report.__index = Report

function VehSvcTest.NewReport(title)
    return setmetatable({ title = title, lines = {}, counts = { PASS = 0, FAIL = 0, SKIP = 0, BLOCKED = 0 } }, Report)
end

function Report:add(status, label)
    if self.counts[status] then self.counts[status] = self.counts[status] + 1 end
    self.lines[#self.lines + 1] = status .. ": " .. tostring(label)
end
function Report:pass(label) self:add("PASS", label) end
function Report:fail(label) self:add("FAIL", label) end
function Report:skip(label) self:add("SKIP", label) end
function Report:blocked(label) self:add("BLOCKED", label) end
function Report:info(label) self:add("INFO", label) end

function Report:check(condition, label, detail)
    if condition then
        self:pass(label)
    else
        self:fail(label .. (detail ~= nil and (" (" .. tostring(detail) .. ")") or ""))
    end
    return condition and true or false
end

-- Compares two values and shows both on failure.
function Report:equal(actual, expected, label)
    return self:check(actual == expected, label, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

function Report:merge(other)
    for _, line in ipairs(other.lines) do self.lines[#self.lines + 1] = line end
    for status, count in pairs(other.counts) do self.counts[status] = (self.counts[status] or 0) + count end
end

function Report:summary()
    local c = self.counts
    local verdict = c.FAIL > 0 and "FAILED" or (c.PASS > 0 and "PASSED" or "NOT RUN")
    return verdict .. " | pass=" .. c.PASS .. " fail=" .. c.FAIL .. " blocked=" .. c.BLOCKED .. " skip=" .. c.SKIP
end

function Report:text()
    return tostring(self.title) .. "\n" .. self:summary() .. "\n\n" .. table.concat(self.lines, "\n")
end

------------------------------------------------------------
-- EXPECTED OUTCOMES (the rules README section 5 documents)
------------------------------------------------------------

VehSvcTest.MECHANICS_COMMANDS = { installPart = true, uninstallPart = true, repairPart = true }
VehSvcTest.TOW_COMMANDS = { addTowing = true, removeTowing = true }
VehSvcTest.INTERCEPTED_COMMANDS = {
    "installPart", "uninstallPart", "repairPart",
    "addTowing", "removeTowing",
    "setDoorOpen", "setDoorLocked", "configDoor",
    "configWindow", "smashWindow",
}

-- Whether a non-owner may run a vanilla vehicle command. NonOwnerNoAccess
-- overrides everything; lock, window and vandalism commands always deny.
function VehSvcTest.ExpectedNonOwnerCommand(command, config, doorUnlocked)
    if type(config) ~= "table" or config.NonOwnerNoAccess == true then return false end
    if VehSvcTest.MECHANICS_COMMANDS[command] then return config.AllowNonOwnerMechanics == true end
    if VehSvcTest.TOW_COMMANDS[command] then return config.AllowNonOwnerTow == true end
    if command == "setDoorOpen" then return config.AllowNonOwnerOpenUnlockedDoors == true and doorUnlocked == true end
    return false
end

-- The client menu policy derived from SandboxVars.KIPN.
function VehSvcTest.ExpectedClientPolicy(sandbox)
    sandbox = type(sandbox) == "table" and sandbox or {}
    if sandbox.VehicleNonOwnerNoAccess == true then
        return { noAccess = true, mechanics = false, openUnlockedDoors = false, tow = false }
    end
    return {
        noAccess = false,
        mechanics = sandbox.VehicleAllowNonOwnerMechanics == true,
        openUnlockedDoors = sandbox.VehicleAllowNonOwnerOpenUnlockedDoors == true,
        tow = sandbox.VehicleAllowNonOwnerTow == true,
    }
end

-- Artifact expiry timestamp: 0 means never.
function VehSvcTest.ExpectedExpiry(createdAt, days)
    days = tonumber(days) or 0
    if days <= 0 then return 0 end
    return (tonumber(createdAt) or 0) + days * 24 * 60 * 60
end

-- Sandbox key -> { ClaimConfig field or ArtifactConfig path }.
VehSvcTest.SANDBOX_TO_CLAIM_CONFIG = {
    VehicleMaxClaimsPerPlayer = "MaxClaimsPerPlayer",
    VehicleRegistrationExpiryDays = "RegistrationExpiryDays",
    VehicleClaimTokenExpiryDays = "ClaimTokenExpiryDays",
    VehicleOwnershipExpiryDays = "OwnershipExpiryDays",
    VehicleClaimCraftSeconds = "ClaimCraftSeconds",
    VehicleNonOwnerNoAccess = "NonOwnerNoAccess",
    VehicleAllowNonOwnerOpenUnlockedDoors = "AllowNonOwnerOpenUnlockedDoors",
    VehicleAllowNonOwnerTow = "AllowNonOwnerTow",
    VehicleAllowNonOwnerMechanics = "AllowNonOwnerMechanics",
}
-- Shipped defaults (README section 6). tests/vehsvc_checks.lua checks
-- these against sandbox-options.txt and KIPN_VehClaimConfig.lua.
VehSvcTest.SANDBOX_DEFAULTS = {
    VehicleClaimsEnabled = true, VehicleRegistrationEnabled = true,
    VehicleMaxClaimsPerPlayer = 5, VehicleRegistrationExpiryDays = 14,
    VehicleClaimTokenExpiryDays = 14, VehicleOwnershipExpiryDays = 0,
    VehicleClaimCraftSeconds = 10, VehicleNonOwnerNoAccess = false,
    VehicleAllowNonOwnerOpenUnlockedDoors = false, VehicleAllowNonOwnerTow = false,
    VehicleAllowNonOwnerMechanics = false,
}
VehSvcTest.SANDBOX_KEYS = {
    "VehicleClaimsEnabled", "VehicleRegistrationEnabled",
    "VehicleMaxClaimsPerPlayer", "VehicleRegistrationExpiryDays",
    "VehicleClaimTokenExpiryDays", "VehicleOwnershipExpiryDays",
    "VehicleClaimCraftSeconds", "VehicleNonOwnerNoAccess",
    "VehicleAllowNonOwnerOpenUnlockedDoors", "VehicleAllowNonOwnerTow",
    "VehicleAllowNonOwnerMechanics",
}

------------------------------------------------------------
-- CATALOG
--
-- side = "server" runs on the server against the requesting player;
-- side = "client" runs locally. Every test is open to every player.
-- site = "dealership": the showcase moves the player into the designated
-- dealership zone before the test starts.
-- vehicle = true needs a target vehicle
-- (the one you are in, or the nearest within 12 tiles). Every result
-- about a vehicle also shows whether this client sees the same claim
-- as the server. Every id must have an implementation (checked by
-- tests/vehsvc_checks.lua).
------------------------------------------------------------

VehSvcTest.Catalog = {
    { id = "all_checks", label = "Run every automatic check (changes nothing)", side = "server" },

    { id = "setup", label = "Services, zone type, permissions, claim types, commands and apps", group = "Setup and configuration", side = "server" },
    { id = "config", label = "Sandbox options reach the server policy and your client", group = "Setup and configuration", side = "server" },
    { id = "scripts", label = "Registration Form and Vehicle Title items, and the form recipe", group = "Setup and configuration", side = "server" },
    { id = "toggles", label = "Registration or claims switched off are refused", group = "Setup and configuration", side = "server" },

    { id = "form_create", label = "Create a Registration Form (gives materials and crafts one)", group = "Registration forms", side = "server" },
    { id = "form_register", label = "Register an untracked (crafted) form", group = "Registration forms", side = "server" },
    { id = "my_forms", label = "My forms and titles, with their artifact state", group = "Registration forms", side = "server" },

    { id = "issue_zone", label = "Issue a Vehicle Title for this vehicle's dealership", group = "Vehicle Titles", side = "server", vehicle = true },
    { id = "issue_desk", label = "Nearby computer: process a form (real desk command)", group = "Vehicle Titles", side = "server", site = "dealership" },
    { id = "issue_rejections", label = "Issuance rejections (bad computer, no zone, no form)", group = "Vehicle Titles", side = "server" },
    { id = "title_rejections", label = "Title validation rejections (scope, type, consumed)", group = "Vehicle Titles", side = "server", vehicle = true },

    { id = "target_check", label = "Can this vehicle be claimed? (no changes)", group = "Vehicle claims", side = "server", vehicle = true },
    { id = "claim", label = "Claim this vehicle (issues a title if needed, keeps the claim)", group = "Vehicle claims", side = "server", vehicle = true },
    { id = "full_flow", label = "Full flow: form, title, claim, release", group = "Vehicle claims", side = "server", vehicle = true },
    { id = "claim_rejections", label = "Claim rejections (already claimed, no title)", group = "Vehicle claims", side = "server", vehicle = true },
    { id = "my_claims", label = "My vehicle claims, quota and expiry", group = "Vehicle claims", side = "server" },
    { id = "quota", label = "Claim limit: a claim past the limit is refused", group = "Vehicle claims", side = "server" },
    { id = "metadata", label = "Vehicle ownership metadata matches the claim", group = "Vehicle claims", side = "server", vehicle = true },
    { id = "resync", label = "Periodic metadata resync repairs wiped ownership (up to 90 s)", group = "Vehicle claims", side = "server", vehicle = true },
    -- side = "flow": a client flow that also runs server steps (T.LifeSteps).
    { id = "lifecycle", label = "Vehicle claim lifecycle: craft, register, claim, 1 day of ownership, expiry", group = "Vehicle claims", side = "flow", site = "dealership" },

    { id = "release", label = "Release my claim on this vehicle (real command)", group = "Release", side = "server", vehicle = true },
    { id = "release_not_owner", label = "Release is refused for a claim I do not own", group = "Release", side = "server", vehicle = true },

    { id = "owner_assign", label = "Give this vehicle to the test owner (makes me a non-owner)", group = "Non-owner enforcement", side = "server", vehicle = true },
    { id = "owner_clear", label = "Remove the test owner's claim from this vehicle", group = "Non-owner enforcement", side = "server", vehicle = true },
    { id = "access", label = "Server access decision for me on this vehicle", group = "Non-owner enforcement", side = "server", vehicle = true },
    { id = "commands", label = "Mechanics/tow/door/window command interception", group = "Non-owner enforcement", side = "server", vehicle = true },
    { id = "eject", label = "Seat ejection (get in within 30 seconds)", group = "Non-owner enforcement", side = "server", vehicle = true },
    { id = "admin_exempt", label = "Admins may use a claimed vehicle", group = "Non-owner enforcement", side = "server", vehicle = true },

    { id = "c_modules", label = "Client modules, screens and the 11 vehicle menu overrides", group = "Client features", side = "client" },
    { id = "c_menu", label = "Right-click menu entries for this vehicle", group = "Client features", side = "client", vehicle = true },
    { id = "c_gates", label = "Enter/mechanics/door/lock gates for this vehicle", group = "Client features", side = "client", vehicle = true },
    { id = "c_policy", label = "Non-owner menu and gates under the live and two forced policies", group = "Client features", side = "client" },
    { id = "c_radial", label = "Radial menus (V key and in-vehicle) for owners and non-owners", group = "Client features", side = "client" },
    { id = "c_dialogs", label = "Claim and release confirm dialogs and what they send", group = "Client features", side = "client" },
    { id = "c_action", label = "Claim timed action: title check, timing and the request it sends", group = "Client features", side = "client", vehicle = true },
    { id = "c_bridge", label = "Vehicle bridge: id, square, position and metadata", group = "Client features", side = "client", vehicle = true },
    { id = "c_registration", label = "Vehicle Registration screen: form check, wait and request", group = "Client features", side = "client" },
    { id = "c_records", label = "Vehicle Records screen: loading, list, expiry and release", group = "Client features", side = "client" },

    { id = "cleanup", label = "Clean up my test items and claims", side = "server" },
}

VehSvcTest.CatalogById = {}
for _, entry in ipairs(VehSvcTest.Catalog) do VehSvcTest.CatalogById[entry.id] = entry end

-- Server tests bundled into "all_checks": they change nothing, or
-- restore what they change before returning. Vehicle tests are included
-- only when a target vehicle was found.
VehSvcTest.AutomaticChecks = { "setup", "config", "scripts", "toggles", "my_forms", "my_claims" }
VehSvcTest.AutomaticVehicleChecks = { "target_check", "access", "metadata" }
VehSvcTest.AutomaticClientChecks = { "c_modules", "c_policy", "c_radial", "c_dialogs", "c_registration", "c_records" }
VehSvcTest.AutomaticClientVehicleChecks = { "c_menu", "c_gates", "c_action", "c_bridge" }

-- What KIPN_VehicleServicesInit.lua registers with the Terminal.
VehSvcTest.PERMISSIONS = {
    ["vehicle.lookup"] = { PLAYER = true, ADMIN = true },
    ["vehicle.claim"] = { PLAYER = true, ADMIN = true },
    ["vehicle.transfer"] = { PLAYER = true, ADMIN = true },
    ["vehicle.revoke"] = { PLAYER = false, ADMIN = true },
}
VehSvcTest.ZONE_CAPABILITIES = { "vehicle.lookup", "vehicle.claim", "vehicle.transfer" }
VehSvcTest.APPS = {
    vehicle_registration = { screen = "KIPN_VehicleRegistration", permission = "vehicle.claim", classification = "DEALERSHIP" },
    vehicle_records = { screen = "KIPN_VehicleRecords", permission = "vehicle.lookup" },
}
VehSvcTest.SERVICE_DEPENDENCIES = { "WorldRegistry", "ClaimService", "ArtifactService", "Permissions", "ApplicationRegistry" }
VehSvcTest.COMMANDS = { "CLAIM_VEHICLE", "ISSUE_VEHICLE_CLAIM", "RELEASE_CLAIM" }

-- The three non-owner policies the client checks run under. "live" is
-- whatever SandboxVars.KIPN holds; the other two are forced for a moment.
VehSvcTest.FORCED_POLICIES = {
    { name = "everything allowed", values = { VehicleNonOwnerNoAccess = false, VehicleAllowNonOwnerMechanics = true,
        VehicleAllowNonOwnerOpenUnlockedDoors = true, VehicleAllowNonOwnerTow = true } },
    { name = "No Access over everything allowed", values = { VehicleNonOwnerNoAccess = true, VehicleAllowNonOwnerMechanics = true,
        VehicleAllowNonOwnerOpenUnlockedDoors = true, VehicleAllowNonOwnerTow = true } },
}

-- Vehicle Records' expiry column, from the claim fields the server sends.
function VehSvcTest.ExpectedExpiryText(claim)
    if claim.ownershipNeverExpires then return "NEVER" end
    local days = tonumber(claim.expiryDaysRemaining)
    if not days then return "---" end
    days = math.floor(days + 0.5)
    if days <= 0 then return "EXPIRED" end
    if days == 1 then return "1 DAY" end
    return days .. " DAYS"
end

return VehSvcTest
