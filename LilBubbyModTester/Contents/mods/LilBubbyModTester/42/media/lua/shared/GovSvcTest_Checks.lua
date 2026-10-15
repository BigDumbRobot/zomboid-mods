-- Shared pieces of the COMPUTER Safehouse and Land Claims test suite:
-- the result report, the test catalog used to build the menu, and the
-- pure geometry the server and client checks compare against.
GovSvcTest = GovSvcTest or {}
GovSvcTest.MODULE = "LilBubbyGovSvcTest"
GovSvcTest.TAG = "LilBubbyGovSvcTest"
GovSvcTest.SUITE = "COMPUTER Safehouse and Land Claims tests"

local Report = {}
Report.__index = Report

function GovSvcTest.NewReport(title)
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
-- GEOMETRY (mirrors the mod's own math)
------------------------------------------------------------

GovSvcTest.SAFEHOUSE_BUFFER_TILES = 2

-- Excavation rectangle centred on the anchor tile, inclusive bounds.
function GovSvcTest.ExcavationRect(x, y, z, width, height)
    width, height = math.floor(tonumber(width) or 0), math.floor(tonumber(height) or 0)
    if width <= 0 or height <= 0 then return nil end
    local x1 = x - math.floor(width / 2)
    local y1 = y - math.floor(height / 2)
    return { x1 = x1, y1 = y1, x2 = x1 + width - 1, y2 = y1 + height - 1, z = z }
end

-- Vanilla SafeHouse x/y/w/h for a claim's inclusive rectangle plus the
-- no-entry buffer.
function GovSvcTest.ProjectionRect(x1, y1, x2, y2)
    local b = GovSvcTest.SAFEHOUSE_BUFFER_TILES
    return { x = x1 - b, y = y1 - b, w = (x2 - x1 + 1) + 2 * b, h = (y2 - y1 + 1) + 2 * b }
end

function GovSvcTest.SameRect(a, b)
    return type(a) == "table" and type(b) == "table"
        and tonumber(a.x1) == tonumber(b.x1) and tonumber(a.y1) == tonumber(b.y1)
        and tonumber(a.x2) == tonumber(b.x2) and tonumber(a.y2) == tonumber(b.y2)
end

-- Exact-payment split used by the wallet: bundles worth 100 first,
-- then singles of the configured value. Returns nil when not payable.
function GovSvcTest.CashSplit(amount, singleValue)
    amount, singleValue = math.floor(tonumber(amount) or 0), tonumber(singleValue) or 1
    if amount < 0 or singleValue <= 0 then return nil end
    local bundles = math.floor(amount / 100)
    local remainder = amount - bundles * 100
    if remainder % singleValue ~= 0 then return nil end
    return bundles, remainder / singleValue
end

------------------------------------------------------------
-- CATALOG
--
-- side = "server" runs on the server against the requesting player;
-- side = "client" runs locally. Every id must have an implementation
-- (checked by tests/govsvc_checks.lua).
------------------------------------------------------------

GovSvcTest.TIERS = { "small", "medium", "large" }

local function tierEntries(prefix, label, group)
    local list = {}
    for _, tier in ipairs(GovSvcTest.TIERS) do
        list[#list + 1] = { id = prefix .. tier, label = label .. " (" .. tier .. ")", group = group, side = "server" }
    end
    return list
end

local catalog = {
    { id = "all_checks", label = "Run every automatic check (changes nothing)", side = "server" },


    { id = "craft_property", label = "Safehouse Registration Form (gives ingredients)", group = "Crafting", side = "server" },
    { id = "craft_excavation", label = "Excavation Registration Form (gives ingredients)", group = "Crafting", side = "server" },

    { id = "register_property", label = "Register a Safehouse Registration Form", group = "Documents", side = "server" },
    { id = "register_excavation", label = "Register an Excavation Registration Form", group = "Documents", side = "server" },
    { id = "issue_deed", label = "Issue a Safehouse Deed", group = "Documents", side = "server" },
}
for _, entry in ipairs(tierEntries("issue_permit_", "Issue an Excavation Permit", "Documents")) do catalog[#catalog + 1] = entry end
for _, entry in ipairs({
    { id = "deed_lifecycle", label = "Find, validate and consume a Safehouse Deed", group = "Documents", side = "server" },
    { id = "permit_lifecycle", label = "Find, validate and consume an Excavation Permit", group = "Documents", side = "server" },
    { id = "desk_deed", label = "Nearby computer: issue a Safehouse Deed", group = "Government desk", side = "server" },
}) do catalog[#catalog + 1] = entry end
for _, entry in ipairs(tierEntries("desk_permit_", "Nearby computer: buy an Excavation Permit", "Government desk")) do catalog[#catalog + 1] = entry end
for _, entry in ipairs({
    { id = "desk_cash", label = "Cash counting matches the server wallet", group = "Government desk", side = "server" },

    { id = "house_check", label = "Check this building (no changes)", group = "Safehouse claims", side = "server" },
    { id = "house_claim", label = "Claim this building (gives a deed, keeps the claim)", group = "Safehouse claims", side = "server" },
    { id = "house_adopt", label = "Claim a building I already have a vanilla safehouse on", group = "Safehouse claims", side = "server" },
    { id = "house_verify", label = "Verify my test safehouses", group = "Safehouse claims", side = "server" },
    { id = "house_expiry", label = "Expiry, renewal and expired release", group = "Safehouse claims", side = "server" },
    { id = "house_release_panel", label = "Release through the safehouse panel", group = "Safehouse claims", side = "server" },
    { id = "house_release_records", label = "Release through Property Records", group = "Safehouse claims", side = "server" },
    { id = "zones_here", label = "Zone restrictions where I stand", group = "Safehouse claims", side = "server" },
}) do catalog[#catalog + 1] = entry end
for _, entry in ipairs(tierEntries("land_check_", "Check land here, no changes", "Excavation claims")) do catalog[#catalog + 1] = entry end
for _, entry in ipairs(tierEntries("land_claim_", "Claim land here, gives a permit", "Excavation claims")) do catalog[#catalog + 1] = entry end
for _, entry in ipairs({
    { id = "land_rules", label = "Placement range, level and overlap rules", group = "Excavation claims", side = "server" },
    { id = "land_verify", label = "Verify my test excavation claims", group = "Excavation claims", side = "server" },
    { id = "land_quota", label = "Claim limit", group = "Excavation claims", side = "server" },
    { id = "land_release", label = "Release my test excavation claims", group = "Excavation claims", side = "server" },

    { id = "renew_desk", label = "Renew my latest test claim at a nearby computer", group = "Renewal", side = "server" },
    { id = "renew_rules", label = "Renewal refusals", group = "Renewal", side = "server" },


    { id = "c_menu", label = "Context menu entries here", group = "Client features", side = "client" },
    { id = "c_gate", label = "Vanilla Claim Safehouse is blocked", group = "Client features", side = "client" },
    { id = "c_access", label = "Excavation access enforcement", group = "Client features", side = "client" },
    { id = "c_placement", label = "Excavation placement preview", group = "Client features", side = "client" },
    { id = "c_panel", label = "Safehouse panel and boundary viewer", group = "Client features", side = "client" },

    { id = "cleanup", label = "Clean up my test items and claims", side = "server" },
}) do catalog[#catalog + 1] = entry end

GovSvcTest.Catalog = catalog
GovSvcTest.CatalogById = {}
for _, entry in ipairs(catalog) do GovSvcTest.CatalogById[entry.id] = entry end

-- Non-mutating server tests bundled into "all_checks".
GovSvcTest.AutomaticChecks = {
    "desk_cash", "house_check", "land_check_small", "land_rules", "zones_here",
}

return GovSvcTest
