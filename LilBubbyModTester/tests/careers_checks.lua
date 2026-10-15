-- Offline checks for the Careers suite: every step drives the career's own
-- KIPN command and reads the career's own records, the flyer is previewed
-- before it is saved, and nothing is written into the careers' books by the
-- tester. Run from this Workshop project directory.
local root = "Contents/mods/LilBubbyModTester/42/media/lua/"
print = function() end
require = function() end
function isServer() return true end
function isClient() return true end
local ticked = {}
Events = { OnClientCommand = { Add = function(fn) ticked[#ticked + 1] = fn end },
    OnTick = { Add = function() end }, OnServerCommand = { Add = function() end } }
function getTimestampMs() return 1000 end
LilBubbyPacer = { Run = function(_, _, _, fn) fn() end }

-- A test desk that always works.
local deskCleanups = 0
LilBubbyDesk = { Ensure = function() return "comp_1_2_0", "placed a computer" end,
    Cleanup = function() deskCleanups = deskCleanups + 1 return 2, 1 end }

dofile(root .. "shared/CareersTest_Checks.lua")
local T = CareersTest

-- Catalog: the framework's own checks, five steps per installed career, and cleanup.
local all = T.Catalog({ CareersDrugDealer = true, CareersMechanic = true, CareersBlacksmith = true })
assert(#all == #T.FrameworkSteps + 3 * #T.Steps + 1, "framework, every installed career and cleanup: " .. #all)
local one = T.Catalog({ CareersMechanic = true })
assert(#one == #T.FrameworkSteps + #T.Steps + 1, "only installed careers are offered")
assert(#T.Catalog({}) == #T.FrameworkSteps + 1, "the framework is checked even with no career installed")
for _, entry in ipairs(one) do
    assert(entry.careerId == nil or entry.careerId == "mechanic", "no other career leaks in: " .. entry.id)
end
local labels = {}
for _, entry in ipairs(all) do
    assert(not labels[entry.id], "duplicate id " .. entry.id)
    labels[entry.id] = true
end
assert(T.CareerById("mechanic").shopWord == "shop" and T.CareerById("dealer").shopWord == "business",
    "each career is described in its own words")

-- The careers' own commands and records, as stand-ins.
local commands, orders, shops, licences = {}, {}, {}, {}
local player = { getUsername = function() return "Tester" end, getOnlineID = function() return 7 end,
    isDead = function() return false end, getSteamID = function() return "STEAM7" end }
local carried, held = {}, {}
local inventory = {
    getCountTypeRecurse = function(_, fullType) return carried[fullType] or 0 end,
    AddItem = function(_, fullType)
        carried[fullType] = (carried[fullType] or 0) + 1
        local item = { fullType = fullType, modData = {} }
        function item:getModData() return self.modData end
        function item:hasModData() for _ in pairs(self.modData) do return true end return false end
        function item:getFullType() return self.fullType end
        held[#held + 1] = item
        return item
    end,
    getItems = function() return { size = function() return #held end, get = function(_, i) return held[i + 1] end } end,
    Remove = function(_, item)
        for index, candidate in ipairs(held) do
            if candidate == item then
                table.remove(held, index)
                carried[item.fullType] = math.max(0, (carried[item.fullType] or 1) - 1)
                return
            end
        end
    end,
}
player.getInventory = function() return inventory end
function sendAddItemToContainer() end
function sendRemoveItemFromContainer() end
function sendServerCommand() end

local data = { careers = { meta = {}, businesses = {}, orders = {},
    mechanic = { meta = {}, shops = shops, orders = orders, licenses = licences } } }
KIPN = { Server = {
    GetData = function() return data end,
    GetCommandHandler = function(name) return commands[name] end,
} }
local bundlesCounted = true
local function wallet()
    local total = carried["Base.Money"] or 0
    if bundlesCounted then total = total + (carried["Base.MoneyBundle"] or 0) * 100 end
    return total
end
local function spend(amount)
    for _ = 1, amount do
        for _, item in ipairs(held) do
            if item.fullType == "Base.Money" then inventory.Remove(inventory, item) break end
        end
    end
end
local function earn(amount) for _ = 1, amount do inventory.AddItem(inventory, "Base.Money") end end
KIPNCareers = { Economy = { Balance = function() return wallet() end, ItemType = function() return "Base.Money" end,
    ItemValue = function() return 1 end } }

-- The mechanic's own handlers, as the mod implements them.
commands["mechanic.buyLicense"] = function(p, args)
    assert(args.computerId, "the licence is bought at a terminal")
    if wallet() < 750 then return true end -- the career refuses, quietly
    spend(750)
    local item = p:getInventory():AddItem("KIPNCareers.MechanicBusinessLicense")
    item:getModData().kipnCareersTokenId = "lic-1"
    licences["lic-1"] = { id = "lic-1", status = "ACTIVE" }
    return true
end
commands["mechanic.startShop"] = function(_, args)
    assert(args.tokenId == "lic-1", "the bearer licence is named when the shop opens")
    shops["shop-1"] = { id = "shop-1", ownerName = "Tester", active = true, name = "Test Shop", flyerRevision = 0 }
    return true
end
commands["mechanic.saveShop"] = function(_, args)
    assert(type(args.fields) == "table" and args.fields.name, "the flyer details are sent to the career")
    shops["shop-1"].flyerRevision = shops["shop-1"].flyerRevision + 1
    return true
end
commands["mechanic.acceptOrder"] = function(_, args)
    orders[args.orderId].status = "ACCEPTED"
    return true
end
commands["mechanic.completeOrder"] = function(_, args)
    orders[args.orderId].status = "CLOSED"
    earn(orders[args.orderId].payout)
    return true
end

commands["mechanic.snapshot"] = function(_, args) assert(args.requestId, "screens ask with a request id") return true end
commands["mechanic.shopProfile"] = function() return true end
commands["mechanic.quoteOrder"] = function(_, args)
    assert(args.targetShopId == "shop-1" and args.repairs, "a quote names the shop and the work")
    return true
end

-- The server's walk-in job appears when the career's own timer is triggered.
local triggered = 0
function triggerEvent(name)
    if name ~= "EveryTenMinutes" then return end
    triggered = triggered + 1
    if data.careers.mechanic.meta.nextSystemOrderAt == 0 and shops["shop-1"] then
        orders["order-1"] = { id = "order-1", source = "SYSTEM", status = "SUBMITTED", targetShopId = "shop-1",
            payout = 120, clientName = "A stranded driver", note = "Walk-in customer." }
    end
end

ModData = ModData or { getOrCreate = (function(store) return function(tag) store[tag] = store[tag] or {}; return store[tag] end end)({}) }
dofile(root .. "shared/LilBubbySites.lua")
dofile(root .. "server/CareersTest_Server.lua")

local function run(id, args)
    return T.RunServer(player, id, args)
end

-- Licence: the tester tops up the wallet, the career charges for it.
local report = run("mechanic_licence")
assert(report.counts.FAIL == 0 and report.counts.PASS >= 2, "licence step: " .. report:text())
assert(carried["KIPNCareers.MechanicBusinessLicense"] == 1, "the career issued the licence")
assert(wallet() == 250, "the career charged its own price out of the wallet: " .. wallet())

-- Opening the shop is refused before the licence, and works after it.
report = run("mechanic_open")
assert(report.counts.FAIL == 0 and shops["shop-1"], "the shop opened: " .. report:text())

-- Flyer: the career saves it as a new revision.
report = run("mechanic_flyer", { fields = { name = "Test Shop", description = "Test" } })
assert(shops["shop-1"].flyerRevision == 1 and report.counts.FAIL == 0, "the flyer saved: " .. report:text())
report = run("mechanic_flyer", {})
assert(report.counts.BLOCKED == 1, "with no details the flyer step is blocked, not faked")

-- A job from the server, accepted through the career's own command.
report = run("mechanic_screens")
assert(report.counts.FAIL == 0 and report.counts.PASS == 3, "read-only screens: " .. report:text())

report = run("mechanic_job")
assert(triggered > 0, "the career's own timer was asked to run")
assert(orders["order-1"] and orders["order-1"].status == "ACCEPTED", "the server's job was accepted: " .. report:text())
assert(report.counts.FAIL == 0, report:text())

-- Finishing it pays the shop.
local before = wallet()
report = run("mechanic_finish")
assert(orders["order-1"].status == "CLOSED" and wallet() == before + 120, "the walk-in paid: " .. report:text())
assert(report.counts.FAIL == 0, report:text())

-- The Drug Dealer is paid at a container, so the tester says so rather than faking it.
report = run("dealer_finish")
assert(report.counts.SKIP == 1, "the dealer's delivery is left to its own screen: " .. report:text())

-- Cleanup takes back what the tester gave and removes its terminal.
report = run("cleanup")
assert(deskCleanups == 1 and report.counts.FAIL == 0, "cleanup removed the test terminal: " .. report:text())
assert(wallet() == 120, "cleanup takes back the tester's money but leaves what the career paid you: " .. wallet())
assert(shops["shop-1"], "cleanup never deletes the career's own records")

-- An unknown test is reported, not run.
assert(run("nope"):text():find("unknown test"), "unknown tests are refused")

-- ------------------------------------------------------------
-- The framework the careers sit on, as the framework implements it.
-- ------------------------------------------------------------

KIPNCareers.Shared = {
    ZoneTypes = { CAREER_SERVICES = "career_services" },
    Capabilities = { CAREER_SERVICES = "career.services" },
    Items = { FLYER = "KIPNCareers.BusinessFlyer" },
    Defaults = { FLYERS_PER_RESTART = 4, FLYER_CHANCE_PERCENT = 12 },
    Clamp = function(value, minimum, maximum)
        value = tonumber(value) or minimum
        return math.max(minimum, math.min(maximum, value))
    end,
    Log = function() end,
    Trim = function(value, maximum)
        local text = tostring(value or "")
        text = text:gsub("[%z\1-\31\127]", " "):gsub("<", "("):gsub(">", ")"):gsub("^%s+", ""):gsub("%s+$", "")
        if maximum and #text > maximum then text = text:sub(1, maximum) end
        return text
    end,
}
function getScriptManager() return { FindItem = function(_, fullType)
    return fullType == "KIPNCareers.BusinessFlyer" and { type = fullType } or nil
end } end
SandboxVars = { KIPNCareers = {} }

-- Economy, including the quirk that large payments arrive as money bundles
-- which Balance and Charge do not count.
local ITEM_VALUE = 1
KIPNCareers.Economy = {
    Settings = function() return "Base.Money", ITEM_VALUE end,
    ItemType = function() return "Base.Money" end,
    ItemValue = function() return ITEM_VALUE end,
    IsValidAmount = function(amount)
        amount = math.floor(tonumber(amount) or 0)
        return amount >= 0 and amount % ITEM_VALUE == 0
    end,
    RoundDown = function(amount)
        return math.max(ITEM_VALUE, math.floor((tonumber(amount) or 0) / ITEM_VALUE) * ITEM_VALUE)
    end,
    Balance = function() return wallet() end,
    Charge = function(_, amount)
        amount = math.floor(tonumber(amount) or 0)
        if amount == 0 then return true, nil, { free = true } end
        if amount % ITEM_VALUE ~= 0 then return false, "AMOUNT_NOT_CURRENCY_MULTIPLE" end
        if wallet() < amount then return false, "INSUFFICIENT_FUNDS" end
        spend(amount)
        return true, nil, { free = false, amount = amount }
    end,
    RefundReceipt = function(receipt)
        if not receipt or receipt.free then return true end
        earn(receipt.amount)
        return true
    end,
    GrantNow = function(_, amount)
        amount = math.floor(tonumber(amount) or 0)
        if amount <= 0 then return true end
        -- Hundreds arrive as bundles. The fixed framework counts them; the
        -- old one did not, and the suite has to notice either way.
        for _ = 1, math.floor(amount / 100) do
            local bundle = inventory.AddItem(inventory, "Base.MoneyBundle")
            bundle.bundle = true
        end
        earn(amount % 100)
        return true
    end,
}

local providers = {}
KIPNCareers.Storefronts = {
    RectanglesOverlap = function(a, b)
        return math.max(a.x1, b.x1) <= math.min(a.x2, b.x2) and math.max(a.y1, b.y1) <= math.min(a.y2, b.y2)
    end,
    Register = function(careerId, provider)
        if type(careerId) ~= "string" or careerId == "" or type(provider) ~= "function" then return false end
        providers[careerId] = provider
        return true
    end,
    Overlaps = function(rect, ignoreCareerId, ignoreId)
        for careerId, provider in pairs(providers) do
            local ok, records = pcall(provider)
            if not ok then return true, careerId, nil end
            for id, record in pairs(type(records) == "table" and records or {}) do
                local ignored = careerId == ignoreCareerId and id == ignoreId
                if not ignored and type(record) == "table" and record.active ~= false and record.bounds
                    and KIPNCareers.Storefronts.RectanglesOverlap(rect, record.bounds) then
                    return true, careerId, id
                end
            end
        end
        return false, nil, nil
    end,
}

local zones, nextZone = {}, 0
KIPNCareers.ZoneBridge = {
    GetRegistry = function() return { live = true } end,
    IsCareerType = function(zoneType) return zoneType == "career_services" end,
    GetZones = function(zoneType)
        local found = {}
        for _, zone in pairs(zones) do if zone.type == zoneType and zone.active then found[#found + 1] = zone end end
        return found
    end,
    GetZonesAt = function(x, y, _, zoneType)
        local found = {}
        for _, zone in pairs(zones) do
            if zone.type == zoneType and zone.active and x >= zone.x1 and x <= zone.x2 and y >= zone.y1 and y <= zone.y2 then
                found[#found + 1] = zone
            end
        end
        return found
    end,
    Create = function(zoneType, a, b, name)
        nextZone = nextZone + 1
        local zone = { id = "zone-" .. nextZone, type = zoneType, name = name, active = true,
            x1 = a.x, y1 = a.y, x2 = b.x, y2 = b.y }
        zones[zone.id] = zone
        return zone
    end,
    Update = function(id, changes)
        local zone = zones[id]
        if not zone then return false end
        local geometry = changes.geometry or {}
        zone.x1, zone.y1, zone.x2, zone.y2 = geometry.x1 or zone.x1, geometry.y1 or zone.y1, geometry.x2 or zone.x2, geometry.y2 or zone.y2
        return true
    end,
    SetActive = function(id, active)
        if not zones[id] then return false end
        zones[id].active = active
        return true
    end,
    RemoveBusinessZone = function(id)
        if not zones[id] then return false end
        zones[id] = nil
        return true
    end,
    OverlapsNoClaim = function() return false end,
    CreateBusinessZone = function(rect, businessId, capability, name)
        nextZone = nextZone + 1
        local zone = { id = "zone-" .. nextZone, type = "career_services", name = name, active = true,
            businessId = businessId, capability = capability,
            x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2 }
        zones[zone.id] = zone
        return zone
    end,
}
player.getX = function() return 300.5 end
player.getY = function() return 400.5 end
player.getZ = function() return 0 end

report = run("fw_money")
assert(report.counts.FAIL == 0 and report.counts.PASS >= 4, "money rules: " .. report:text())

report = run("fw_payment")
assert(report.counts.FAIL == 0 and report.counts.PASS >= 7, "payments: " .. report:text())
-- The same check catches a wallet that cannot see money paid in bundles.
bundlesCounted = false
report = run("fw_payment")
assert(report:text():find("money bundles"), "a wallet that ignores bundles is reported: " .. report:text())
bundlesCounted = true
for _ = 1, (carried["Base.MoneyBundle"] or 0) do
    for _, item in ipairs(held) do
        if item.fullType == "Base.MoneyBundle" then inventory.Remove(inventory, item) break end
    end
end

-- A player draws no zone; an admin runs the whole check.
local adminNow = false
isAdmin = function() return adminNow end
report = run("fw_zones")
assert(report.counts.FAIL == 0 and report:text():find("players do not create zones", 1, true), "zones as a player: " .. report:text())
adminNow = true
report = run("fw_zones")
assert(report.counts.FAIL == 0 and report.counts.PASS >= 10, "zones as an admin: " .. report:text())
adminNow = false
local left = 0
for _ in pairs(zones) do left = left + 1 end
assert(left == 0, "the zone test removes its own test zone")

report = run("fw_storefronts")
assert(report.counts.FAIL == 0 and report.counts.PASS >= 7, "storefronts: " .. report:text())
assert(select(1, KIPNCareers.Storefronts.Overlaps({ x1 = 900000, y1 = 900000, x2 = 900010, y2 = 900010 })) == false,
    "the storefront test leaves no stand-in career blocking ground")

report = run("fw_flyer")
assert(report.counts.FAIL == 0 and report.counts.PASS >= 6, "flyer and text rules: " .. report:text())

KIPNCareers.Mechanic = { Commands = { SNAPSHOT = "mechanic.snapshot", BUY_LICENSE = "mechanic.buyLicense",
    ACCEPT_ORDER = "mechanic.acceptOrder", SUBMIT_ORDER = "mechanic.submitOrder",
    BRAND_NEW_COMMAND = "mechanic.brandNewCommand" } }
commands["mechanic.submitOrder"] = function() return true end
report = run("fw_commands")
assert(report.counts.FAIL == 1 and report:text():find("mechanic.brandNewCommand"),
    "a command the server never registered is a failure: " .. report:text())
commands["mechanic.brandNewCommand"] = function() return true end
report = run("fw_commands")
assert(report.counts.FAIL == 0, "with every command registered the check passes: " .. report:text())
assert(report:text():find("not run by the showcase") and report:text():find("mechanic.brandNewCommand"),
    "a new command nobody drives is named, so it cannot go unnoticed: " .. report:text())
assert(report:text():find("mechanic.submitOrder"), "commands left to a second player are named too")
assert(not report:text():find("not run by the showcase[^\n]*mechanic%.snapshot"),
    "commands the showcase does drive are not listed as uncovered")

-- The flyer preview says the same as what is saved.
dofile(root .. "client/CareersFlyerUI.lua")
local career = T.CareerById("mechanic")
local values = { name = "Test Shop", proprietorAlias = "The Tester", description = "Engines and tyres",
    hours = "Dawn to dusk", adText = "", services = "", contact = "" }
local lines = CareersFlyerUI.Lines(career, values)
assert(lines.title == "Test Shop" and lines.subtitle:find("The Tester"), "the flyer shows the business and its owner")
assert(#lines.body == 2, "empty lines are left off the flyer: " .. #lines.body)
values.name, values.description = "", ""
assert(#CareersFlyerUI.Missing(career, values) == 2, "a flyer without a name or description is not saved")
io.write("PASS: careers suite offers each installed career's journey, drives the careers' own commands, takes a server job through to payment, checks the framework's money, zones, storefronts and text rules, previews the flyer, and writes nothing into the careers' books\n")
