-- Shared pieces of the Careers suite: the result report and the catalog of
-- features, one set per installed career. The careers are server
-- authoritative, so every test drives the careers' own KIPN commands and
-- reads their own state; the tester never writes their records itself.
CareersTest = CareersTest or {}
CareersTest.MODULE = "LilBubbyCareersTest"
CareersTest.SUITE = "Careers tests"
CareersTest.TAG = "LilBubbyCareersTest"
CareersTest.FRAMEWORK = "CareersFramework"
CareersTest.ZONE_TYPE = "career_services"

-- Each career, as the tester drives it. commands are the career's own KIPN
-- command names; state is where its records live under KIPN's data
-- (legacyState: where they lived before the career had its own table).
CareersTest.Careers = {
    {
        id = "dealer", mod = "CareersDrugDealer", name = "Drug Dealer",
        shopWord = "business", state = "drug_dealer", legacyState = "careers",
        licenseItem = "KIPNCareers.DrugDealerBusinessLicense",
        commands = { license = "careers.buyLicense", start = "careers.startBusiness", save = "careers.saveBusiness",
            accept = "careers.acceptOrder", snapshot = "careers.snapshot" },
        -- The dealer delivers physical goods, so a job finishes at a container.
        finishesAtContainer = true,
    },
    {
        id = "mechanic", mod = "CareersMechanic", name = "Mechanic",
        shopWord = "shop", state = "mechanic",
        licenseItem = "KIPNCareers.MechanicBusinessLicense",
        commands = { license = "mechanic.buyLicense", start = "mechanic.startShop", save = "mechanic.saveShop",
            accept = "mechanic.acceptOrder", complete = "mechanic.completeOrder", snapshot = "mechanic.snapshot" },
    },
    {
        id = "blacksmith", mod = "CareersBlacksmith", name = "Blacksmith",
        shopWord = "shop", state = "blacksmith",
        licenseItem = "KIPNCareers.BlacksmithBusinessLicense",
        commands = { license = "blacksmith.buyLicense", start = "blacksmith.startShop", save = "blacksmith.saveShop",
            accept = "blacksmith.acceptOrder", complete = "blacksmith.completeOrder", snapshot = "blacksmith.snapshot" },
    },
}

-- The read-only commands each career answers screens with.
CareersTest.ScreenCommands = {
    dealer = { { key = "snapshot", command = "careers.snapshot", label = "your career snapshot" },
        { key = "profile", command = "careers.businessProfile", label = "your business profile" },
        { key = "inbox", command = "careers.inbox", label = "your inbox" } },
    mechanic = { { key = "snapshot", command = "mechanic.snapshot", label = "your shop snapshot" },
        { key = "profile", command = "mechanic.shopProfile", label = "your shop profile" },
        { key = "quote", command = "mechanic.quoteOrder", label = "a quote for a repair" } },
    blacksmith = { { key = "snapshot", command = "blacksmith.snapshot", label = "your forge snapshot" },
        { key = "profile", command = "blacksmith.shopProfile", label = "your forge profile" },
        { key = "quote", command = "blacksmith.quoteOrder", label = "a quote for a forge job" } },
}

function CareersTest.CareerById(id)
    for _, career in ipairs(CareersTest.Careers) do if career.id == id then return career end end
end

-- The flyer/business details every career stores under the same field names.
CareersTest.FlyerFields = {
    { key = "name", label = "Business name", required = true, sample = "LilBubby Test Trade" },
    { key = "proprietorAlias", label = "Proprietor", sample = "The Tester" },
    { key = "description", label = "Description", required = true, sample = "A test business opened by the Mod Showcase." },
    { key = "hours", label = "Opening hours", sample = "Dawn to dusk" },
    { key = "adText", label = "Advert line", sample = "Fair prices, no questions." },
}
-- The Mechanic and Blacksmith call these two fields something else.
CareersTest.CareerFields = {
    dealer = { { key = "products", label = "What you sell", sample = "Whatever is in stock." },
        { key = "meetingMethod", label = "How to reach you", sample = "Leave a note at the terminal." } },
    mechanic = { { key = "services", label = "Services offered", sample = "Engines, tyres, bodywork." },
        { key = "contact", label = "How to reach you", sample = "Radio channel 102.5" } },
    blacksmith = { { key = "services", label = "Services offered", sample = "Blades, tools, repairs." },
        { key = "contact", label = "How to reach you", sample = "Knock at the forge." } },
}

function CareersTest.FieldsFor(careerId)
    local fields = {}
    for _, field in ipairs(CareersTest.FlyerFields) do fields[#fields + 1] = field end
    for _, field in ipairs(CareersTest.CareerFields[careerId] or {}) do fields[#fields + 1] = field end
    return fields
end

-- Where each career publishes its own command list, so the suite can check
-- every one of them is registered, and say which it drives itself.
function CareersTest.CommandTables()
    local tables = {}
    local C = KIPNCareers
    if not C then return tables end
    -- Drug Dealer 1.3 keeps its commands in its own table and leaves the
    -- framework's (inbox, zone editor, closing a storefront) in Shared.
    if C.Dealer and C.Dealer.Commands then
        tables["Drug Dealer"] = C.Dealer.Commands
        if C.Shared and C.Shared.Commands then tables["Careers Framework"] = C.Shared.Commands end
    elseif C.Shared and C.Shared.Commands then
        tables["Drug Dealer"] = C.Shared.Commands
    end
    if C.Mechanic and C.Mechanic.Commands then tables["Mechanic"] = C.Mechanic.Commands end
    if C.Blacksmith and C.Blacksmith.Commands then tables["Blacksmith"] = C.Blacksmith.Commands end
    return tables
end

-- Commands the showcase runs for you, and why the rest are left alone.
CareersTest.CommandNotes = {
    SNAPSHOT = "read by Check what your screens are told",
    SHOP_PROFILE = "read by Check what your screens are told",
    BUSINESS_PROFILE = "read by Check what your screens are told",
    INBOX = "read by Check what your screens are told",
    QUOTE_ORDER = "read by Check what your screens are told",
    BUY_LICENSE = "run by Buy a business licence",
    START_BUSINESS = "run by Open your business",
    START_SHOP = "run by Open your shop",
    SAVE_BUSINESS = "run by Design your business flyer",
    SAVE_SHOP = "run by Design your business flyer",
    ACCEPT_ORDER = "run by Take a job the server sends you",
    COMPLETE_ORDER = "run by Finish the job you accepted",
    COMPLETE_WORK_ORDER = "the Drug Dealer is paid on delivery at a container, in its own screen",
    SEAL_DELIVERY = "part of the Drug Dealer's delivery, done in its own screen",
    DROP_DELIVERY = "part of the Drug Dealer's delivery, done in its own screen",
    OPEN_PARCEL = "opens a sealed parcel a buyer received",
    SUBMIT_ORDER = "sending work to someone else's shop: needs a second player",
    CANCEL_ORDER = "cancels a work order you sent to someone else's shop",
    DECLINE_ORDER = "turning work down: try it by hand on a walk-in job",
    APPROVE_ORDER = "a customer approving finished work: needs a second player",
    MARK_INBOX_READ = "marks your notifications read",
    SET_CONTAINER_TYPE = "marks a container as your public or private drop, in the career's own screen",
    CLEAR_CONTAINER_TYPE = "unmarks a drop container, in the career's own screen",
    ADMIN_CREATE_ZONE = "admin zone editing",
    ADMIN_UPDATE_ZONE = "admin zone editing",
    ADMIN_TOGGLE_ZONE = "admin zone editing",
}

local Report = {}
Report.__index = Report

function CareersTest.NewReport(title)
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
    if condition then self:pass(label)
    else self:fail(label .. (detail ~= nil and (" (" .. tostring(detail) .. ")") or "")) end
    return condition and true or false
end

function Report:summary()
    local c = self.counts
    local verdict = c.FAIL > 0 and "FAILED" or (c.PASS > 0 and "PASSED" or "NOT RUN")
    return verdict .. " | pass=" .. c.PASS .. " fail=" .. c.FAIL .. " blocked=" .. c.BLOCKED .. " skip=" .. c.SKIP
end

function Report:text()
    return tostring(self.title) .. "\n" .. self:summary() .. "\n\n" .. table.concat(self.lines, "\n")
end

-- The framework everything else sits on: money, storefront overlap rules,
-- the Career Services zone type and the shared flyer item.
CareersTest.FrameworkSteps = {
    { id = "fw_money", label = "Check the shared money rules" },
    { id = "fw_payment", label = "Take a payment and refund it" },
    { id = "fw_zones", label = "Check the Career Services zone (admins also create, move and remove one)" },
    { id = "fw_storefronts", label = "Check the storefront overlap rules" },
    { id = "fw_flyer", label = "Check the shared flyer item and text rules" },
    { id = "fw_commands", label = "Check every career command the server offers" },
}
CareersTest.FRAMEWORK_GROUP = "Careers Framework"

-- The features offered per career, in the order a player would do them.
CareersTest.Steps = {
    { id = "licence", label = "Buy a business licence at a terminal", side = "server" },
    { id = "open", label = "Open your %s where you stand", side = "server" },
    { id = "flyer", label = "Design your business flyer", side = "client" },
    { id = "screens", label = "Check what your %s screens are told", side = "server" },
    { id = "job", label = "Take a job the server sends you", side = "server" },
    { id = "finish", label = "Finish the job you accepted", side = "server" },
}

function CareersTest.Catalog(installed)
    local catalog = {}
    for _, step in ipairs(CareersTest.FrameworkSteps) do
        catalog[#catalog + 1] = { id = step.id, step = step.id, label = step.label,
            group = CareersTest.FRAMEWORK_GROUP, side = "server" }
    end
    for _, career in ipairs(CareersTest.Careers) do
        if not installed or installed[career.mod] then
            for _, step in ipairs(CareersTest.Steps) do
                catalog[#catalog + 1] = {
                    id = career.id .. "_" .. step.id, careerId = career.id, step = step.id,
                    group = career.name, side = step.side,
                    label = string.format(step.label, career.shopWord),
                }
            end
        end
    end
    catalog[#catalog + 1] = { id = "cleanup", label = "Clean up my test businesses and licences", side = "server" }
    return catalog
end

return CareersTest
