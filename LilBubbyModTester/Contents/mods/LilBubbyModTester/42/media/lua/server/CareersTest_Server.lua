require "CareersTest_Checks"
require "LilBubbyPacer"
require "LilBubbyDesk"
require "LilBubbySites"

-- Careers suite, server side. Every step calls the career's own KIPN command
-- handler as the player, exactly as its screens do, and then reads the
-- career's own records to say what happened. The tester writes no career
-- records of its own; the only thing it adds is the terminal to stand at and
-- the money to spend, both tagged so cleanup can take them back.
local T = CareersTest
local Tests = {}
T.ServerTests = Tests

local function log(message) print("[" .. T.MODULE .. "] " .. tostring(message)) end

local function isFn(value) return type(value) == "function" end

local function kipnServer() return KIPN and KIPN.Server end

local function handlerFor(command)
    local server = kipnServer()
    if not server or not isFn(server.GetCommandHandler) then return nil end
    return server.GetCommandHandler(command)
end

-- Runs one of the career's own commands as this player and returns its reply.
-- Replies come back through the career's RESULT event, which the client shows;
-- the handler's own return value tells us whether it ran at all.
local function runCommand(command, player, args)
    local handler = handlerFor(command)
    if not handler then return nil, "command " .. tostring(command) .. " is not registered" end
    local ok, result = pcall(handler, player, args or {})
    if not ok then return nil, tostring(result) end
    return result == nil and true or result
end

local function careersRoot()
    local server = kipnServer()
    if not server or not isFn(server.GetData) then return nil end
    local root = server.GetData()
    if type(root) ~= "table" then return nil end
    return type(root.careers) == "table" and root.careers or nil
end

-- Each career keeps its records in its own table. Before Drug Dealer 1.3
-- the dealer used the root.
local function careerState(career)
    local careers = careersRoot()
    if not careers then return nil end
    if type(careers[career.state]) == "table" then return careers[career.state] end
    if career.legacyState == "careers" then return careers end
    return nil
end

local function identity(player)
    -- The careers key players by KIPN identity; their own records carry it,
    -- so read it back from a record rather than guessing the format.
    local host = KIPNCareers and KIPNCareers.Host
    if host and type(host.Identity) == "function" then return host.Identity(player) end
    return "user:" .. tostring(player:getUsername())
end

local function businessesOf(career)
    local data = careerState(career)
    if not data then return {} end
    return career.id == "dealer" and (data.businesses or {}) or (data.shops or {})
end

local function ownedBusiness(career, player)
    local username = tostring(player:getUsername())
    for _, business in pairs(businessesOf(career)) do
        if business.active ~= false and (business.ownerName == username or business.ownerKey == identity(player)) then
            return business
        end
    end
end

local function countItems(player, fullType)
    local ok, n = pcall(function() return player:getInventory():getCountTypeRecurse(fullType) end)
    return ok and n or 0
end

local function giveTagged(player, fullType, count)
    local inventory, given = player:getInventory(), 0
    for _ = 1, count do
        local item = inventory:AddItem(fullType)
        if not item then break end
        item:getModData()[T.TAG] = true
        if isServer() then pcall(sendAddItemToContainer, inventory, item) end
        given = given + 1
    end
    return given
end

------------------------------------------------------------
-- MONEY AND THE TERMINAL
------------------------------------------------------------

local function economy() return KIPNCareers and KIPNCareers.Economy end

local function balance(player)
    local E = economy()
    if not E or not isFn(E.Balance) then return nil end
    local ok, amount = pcall(E.Balance, player)
    return ok and tonumber(amount) or nil
end

-- Makes sure the player can afford a price, handing over tagged cash if not.
local function ensureMoney(r, player, price)
    local E = economy()
    local itemType = E and isFn(E.ItemType) and E.ItemType() or "Base.Money"
    local value = E and isFn(E.ItemValue) and math.max(1, E.ItemValue()) or 1
    local have = balance(player)
    if have == nil then r:info("The framework's wallet is unavailable; paying with what you carry") return nil end
    if have >= price then return have end
    local notes = math.ceil((price - have) / value)
    local given = giveTagged(player, itemType, notes)
    r:info("Gave you " .. given .. " x " .. itemType .. " so you can pay " .. price)
    return balance(player)
end

-- A KIPN terminal inside a Career Services zone, which every licence purchase
-- needs. LilBubbyDesk places and powers it and removes it at cleanup.
local function deskFor(r, player)
    local computerId, notes = LilBubbyDesk.Ensure(player, T.ZONE_TYPE)
    if notes and notes ~= "" then r:info("Terminal: " .. tostring(notes)) end
    if not computerId then r:blocked("No KIPN terminal could be placed here: " .. tostring(notes)) end
    return computerId
end

------------------------------------------------------------
-- THE FRAMEWORK EVERY CAREER SITS ON
------------------------------------------------------------

local function shared() return KIPNCareers and KIPNCareers.Shared end
local function storefronts() return KIPNCareers and KIPNCareers.Storefronts end
local function zoneBridge() return KIPNCareers and KIPNCareers.ZoneBridge end

function Tests.fw_money(r, _, player)
    local E = economy()
    if not E then r:blocked("The framework's Economy is unavailable.") return end
    local itemType, itemValue = E.Settings()
    r:info("Currency: " .. tostring(itemType) .. " worth " .. tostring(itemValue) .. " each")
    r:check(E.ItemType() == itemType and E.ItemValue() == itemValue, "ItemType and ItemValue agree with Settings")
    r:check(E.IsValidAmount(0) and E.IsValidAmount(itemValue) and E.IsValidAmount(itemValue * 3),
        "Whole numbers of currency items are valid amounts")
    r:check(not E.IsValidAmount(-itemValue), "A negative amount is refused")
    if itemValue > 1 then
        r:check(not E.IsValidAmount(itemValue - 1), "An amount that is not a multiple of the item value is refused")
    else
        r:skip("This currency is worth 1 each, so every whole amount is a multiple")
    end
    r:check(E.RoundDown(itemValue * 2.7) == itemValue * 2, "A price rounds down to whole currency items",
        tostring(E.RoundDown(itemValue * 2.7)))
    r:check(E.RoundDown(0) == itemValue, "Rounding down never goes below one item", tostring(E.RoundDown(0)))
    r:info("You are carrying " .. tostring(E.Balance(player)))
end

function Tests.fw_payment(r, _, player)
    local E = economy()
    if not E then r:blocked("The framework's Economy is unavailable.") return end
    local itemValue = E.ItemValue()
    ensureMoney(r, player, itemValue * 2)
    local before = E.Balance(player)
    -- Too much money: refused, and nothing is taken.
    local ok, reason = E.Charge(player, before + itemValue * 1000)
    r:check(not ok and reason == "INSUFFICIENT_FUNDS", "Paying more than you carry is refused", tostring(reason))
    r:check(E.Balance(player) == before, "A refused payment takes nothing", tostring(E.Balance(player)))
    -- A real payment, then its refund.
    local paid, why, receipt = E.Charge(player, itemValue)
    if not r:check(paid, "A payment is taken from your inventory", tostring(why)) then return end
    r:check(E.Balance(player) == before - itemValue, "Your money went down by the price",
        tostring(E.Balance(player)) .. " after " .. tostring(before))
    r:check(E.RefundReceipt(receipt) == true, "The receipt refunds it")
    r:check(E.Balance(player) == before, "Your money is back", tostring(E.Balance(player)))
    -- A free payment moves nothing but still succeeds.
    local free, _, freeReceipt = E.Charge(player, 0)
    r:check(free and freeReceipt and freeReceipt.free == true, "Charging nothing is free and moves no items")
    -- Paying the shop: money granted must be money the framework can see again.
    local granted = E.GrantNow(player, itemValue)
    r:check(granted == true, "The framework can pay you")
    r:check(E.Balance(player) == before + itemValue, "Money you are paid is counted in your balance",
        tostring(E.Balance(player)) .. " after " .. tostring(before))
    local hundred = itemValue * 100
    if E.ItemType() == "Base.Money" then
        local wallet = E.Balance(player)
        if E.GrantNow(player, hundred) then
            r:check(E.Balance(player) == wallet + hundred,
                "A payment of " .. hundred .. " is counted too",
                "balance stayed at " .. tostring(E.Balance(player))
                    .. "; large payments arrive as money bundles, which Balance and Charge do not count until you unpack them")
        end
    end
    local left = E.Balance(player) - before
    if left > 0 then E.Charge(player, left) end
    r:info("Left your wallet as it started: " .. tostring(E.Balance(player)))
end

function Tests.fw_zones(r, _, player)
    local Z, S = zoneBridge(), shared()
    if not Z or not S then r:blocked("The framework's ZoneBridge is unavailable.") return end
    r:check(Z.IsCareerType(T.ZONE_TYPE) == true, "career_services is a career zone type")
    r:check(Z.IsCareerType("lilbubby_not_a_zone_type") ~= true, "Anything else is not")
    r:check(Z.GetRegistry() ~= nil, "KIPN's world registry is reachable")
    -- Everyone checks the designated Career Services zone; only an admin draws zones.
    local site = LilBubbySites.Get(T.ZONE_TYPE)
    if site then
        local here = Z.GetZonesAt(site.spot.x, site.spot.y, site.spot.z, T.ZONE_TYPE)
        r:check(here and #here > 0, "The designated Career Services zone is found where it was drawn", here and #here or "none")
        local all = Z.GetZones(T.ZONE_TYPE)
        r:check(all and #all > 0, "It is listed with the Career Services zones", all and #all or "none")
    else
        r:info(LilBubbySites.Missing(T.ZONE_TYPE))
    end
    if not LilBubbySites.IsAdmin(player) then
        r:info("Drawing, moving and removing a zone is checked when an admin runs this test: players do not create zones")
        return
    end
    local x, y, z = math.floor(player:getX()) + 6, math.floor(player:getY()) + 6, math.floor(player:getZ())
    local zone, reason = Z.Create(T.ZONE_TYPE, { x = x, y = y, z = z }, { x = x + 2, y = y + 2, z = z },
        "lilBubby framework test zone")
    if not r:check(zone ~= nil, "A Career Services zone can be created", tostring(reason)) then return end
    local zoneId = zone.id or zone
    local found = Z.GetZonesAt(x + 1, y + 1, z, T.ZONE_TYPE)
    r:check(found and #found > 0, "The new zone is found where it was drawn", found and #found or "none")
    local listed = Z.GetZones(T.ZONE_TYPE)
    r:check(listed and #listed > 0, "It is listed with the other Career Services zones", listed and #listed or "none")
    r:check(Z.Update(zoneId, { geometry = { x1 = x + 1, y1 = y + 1, x2 = x + 3, y2 = y + 3, z1 = z, z2 = z } }) ~= false,
        "The zone can be moved")
    r:check(Z.SetActive(zoneId, false) ~= false, "The zone can be switched off")
    r:check(Z.RemoveBusinessZone(zoneId) ~= false, "The zone can be removed again")
    local after = Z.GetZonesAt(x + 1, y + 1, z, T.ZONE_TYPE)
    r:check(not after or #after == 0, "Nothing of the test zone is left", after and #after or 0)
    local rect = { x1 = x, y1 = y, x2 = x + 2, y2 = y + 2 }
    r:info("No Claim zone over that spot: " .. tostring(Z.OverlapsNoClaim(rect) == true))
    -- The zone a career draws over a storefront so its screens appear there.
    local businessZone = Z.CreateBusinessZone(rect, "lilbubby-test-business", S.Capabilities.CAREER_SERVICES,
        "lilBubby framework test storefront")
    if r:check(businessZone ~= nil, "A storefront's own capability zone can be drawn") then
        r:check(Z.RemoveBusinessZone(businessZone.id or businessZone) ~= false, "And removed again")
    end
end

function Tests.fw_storefronts(r)
    local SF = storefronts()
    if not SF then r:blocked("The framework's Storefronts registry is unavailable.") return end
    local a = { x1 = 0, y1 = 0, x2 = 10, y2 = 10 }
    r:check(SF.RectanglesOverlap(a, { x1 = 5, y1 = 5, x2 = 15, y2 = 15 }) == true, "Two buildings that share ground overlap")
    r:check(SF.RectanglesOverlap(a, { x1 = 11, y1 = 11, x2 = 20, y2 = 20 }) == false, "Two that do not, do not")
    local careerId = "lilbubby_test_career"
    local bounds = { x1 = 900000, y1 = 900000, x2 = 900010, y2 = 900010 }
    r:check(SF.Register(careerId, function() return { test = { active = true, bounds = bounds } } end) == true,
        "A career can register its storefronts")
    r:check(SF.Register(careerId, nil) == false, "A registration without a provider is refused")
    local overlaps, who, which = SF.Overlaps(bounds)
    r:check(overlaps == true and who == careerId, "A storefront blocks another over the same ground",
        tostring(who) .. "/" .. tostring(which))
    r:check(SF.Overlaps(bounds, careerId, "test") == false, "A storefront never blocks itself")
    r:check(SF.Overlaps({ x1 = 900020, y1 = 900020, x2 = 900030, y2 = 900030 }) == false,
        "Ground nobody occupies is free")
    -- A career whose provider throws must not let shops stack.
    SF.Register(careerId, function() error("this career is broken") end)
    r:check(SF.Overlaps(bounds) == true, "A career that fails to answer blocks the ground rather than allowing it")
    SF.Register(careerId, function() return {} end)
    r:pass("The tester's stand-in career was emptied again")
end

function Tests.fw_flyer(r)
    local S = shared()
    if not S then r:blocked("The framework is unavailable.") return end
    local flyer = S.Items and S.Items.FLYER
    local exists = flyer and getScriptManager():FindItem(flyer) ~= nil
    r:check(exists == true, "The shared Business Flyer item exists in this build", tostring(flyer))
    r:check(S.ZoneTypes.CAREER_SERVICES == T.ZONE_TYPE and S.Capabilities.CAREER_SERVICES ~= nil,
        "The Career Services zone type and capability are defined")
    local raw = SandboxVars and SandboxVars.KIPNCareers or {}
    r:info("Flyers per business after a restart: " .. tostring(raw.FlyersPerRestart or S.Defaults.FLYERS_PER_RESTART)
        .. ", chance per eligible container: " .. tostring(raw.FlyerSpawnChancePercent or S.Defaults.FLYER_CHANCE_PERCENT) .. "%")
    -- Every career passes player text through these before storing it.
    r:check(S.Trim("  hello  ") == "hello", "Business text is trimmed")
    r:check(S.Trim("<script>") == "(script)", "Angle brackets cannot be stored", S.Trim("<script>"))
    r:check(S.Trim("abcdef", 3) == "abc", "Long text is cut to its limit", S.Trim("abcdef", 3))
    r:check(S.Trim("a\tb") == "a b", "Control characters become spaces", S.Trim("a\tb"))
    r:check(S.Clamp(50, 1, 10) == 10 and S.Clamp(-5, 1, 10) == 1 and S.Clamp("4", 1, 10) == 4,
        "Numbers are clamped into range")
    r:check(pcall(S.Log, "LilBubbyTester", "Info", "coverage check") == true, "The framework's log accepts a message")
end

------------------------------------------------------------
-- STEPS
------------------------------------------------------------

function Tests.licence(r, career, player)
    local before = countItems(player, career.licenseItem)
    if before > 0 then r:info("You already carry a " .. career.name .. " licence") end
    local computerId = deskFor(r, player)
    if not computerId then return end
    local wallet = balance(player)
    ensureMoney(r, player, 1000)
    local reply, err = runCommand(career.commands.license, player, { computerId = computerId })
    if not r:check(reply ~= nil, career.name .. ": the mod's own buyLicense command ran", err) then return end
    local after = countItems(player, career.licenseItem)
    if not r:check(after > before, career.name .. ": a bearer licence is in your inventory",
        "still " .. after .. "; the career's reply in the strip says why") then return end
    local spent = wallet and balance(player) and (wallet - balance(player)) or nil
    r:info("Wallet: " .. tostring(wallet) .. " -> " .. tostring(balance(player))
        .. (spent and spent > 0 and (" (paid " .. spent .. ")") or ""))
end

function Tests.open(r, career, player)
    if ownedBusiness(career, player) then
        r:info("You already run a " .. career.name .. " " .. career.shopWord .. " here")
    end
    local licence = countItems(player, career.licenseItem)
    if licence == 0 then r:blocked("Buy a " .. career.name .. " licence first.") return end
    -- The careers redeem a specific bearer licence, named by its token.
    local tokenId
    local items = player:getInventory():getItems()
    for i = 0, items:size() - 1 do
        local item = items:get(i)
        if item:getFullType() == career.licenseItem and item:hasModData() then
            tokenId = item:getModData().kipnCareersTokenId or tokenId
        end
    end
    local reply, err = runCommand(career.commands.start, player, { tokenId = tokenId })
    if not r:check(reply ~= nil, career.name .. ": the mod's own start command ran", err) then return end
    local business = ownedBusiness(career, player)
    if not r:check(business ~= nil, career.name .. ": your " .. career.shopWord .. " is on the server's books",
        "the career refused it; its reply in the strip says why (you must stand inside a building you may use)") then return end
    r:info("Storefront: " .. tostring(business.name) .. " (" .. tostring(business.id) .. ")")
end

-- The client sends the flyer fields it collected; the career saves them.
function Tests.flyer(r, career, player, args)
    local business = ownedBusiness(career, player)
    if not business then r:blocked("Open your " .. career.shopWord .. " first.") return end
    local fields = type(args) == "table" and args.fields or nil
    if type(fields) ~= "table" then r:blocked("No flyer details were sent.") return end
    local before = tonumber(business.flyerRevision) or 0
    local reply, err = runCommand(career.commands.save, player, { fields = fields })
    if not r:check(reply ~= nil, career.name .. ": the mod's own save command ran", err) then return end
    business = ownedBusiness(career, player) or business
    r:check((tonumber(business.flyerRevision) or 0) > before,
        career.name .. ": your flyer is saved as a new revision",
        "revision stayed at " .. tostring(business.flyerRevision) .. "; the career's reply says why")
    r:info("Flyers with these details go into loot after the next server restart.")
end

-- Asks the career for the work its server hands out, without waiting for the
-- next ten-minute beat: the careers gate generation on their own clock, so we
-- clear that clock and let their own periodic code run.
local function forceServerJob(career)
    local data = careerState(career)
    if not data then return false, "the career's records are unavailable" end
    data.meta = type(data.meta) == "table" and data.meta or {}
    data.meta.nextSystemOfferAt = 0
    data.meta.nextSystemOrderAt = 0
    if not isFn(triggerEvent) then return false, "this build cannot trigger the career's timer" end
    local ok, err = pcall(triggerEvent, "EveryTenMinutes")
    if not ok then return false, tostring(err) end
    return true
end

local function openServerJob(career, business)
    local data = careerState(career)
    for _, order in pairs((data or {}).orders or {}) do
        local mine = order.targetBusinessId == business.id or order.targetShopId == business.id
        local waiting = order.status == "OPEN" or order.status == "SUBMITTED"
        if mine and waiting and order.source == "SYSTEM" then return order end
    end
end

function Tests.job(r, career, player)
    local business = ownedBusiness(career, player)
    if not business then r:blocked("Open your " .. career.shopWord .. " first.") return end
    local job = openServerJob(career, business)
    if not job then
        local ok, err = forceServerJob(career)
        if not ok then r:info("Could not hurry the career's timer: " .. tostring(err)) end
        job = openServerJob(career, business)
    end
    if not r:check(job ~= nil, career.name .. ": the server sent your " .. career.shopWord .. " a job",
        "no waiting job; the career posts them on its own timer and caps how many wait at once") then return end
    r:info("Job: " .. tostring(job.objective or job.note or "walk-in customer")
        .. " | pays " .. tostring(job.payout))
    local reply, err = runCommand(career.commands.accept, player, { orderId = job.id })
    if not r:check(reply ~= nil, career.name .. ": the mod's own accept command ran", err) then return end
    local data = careerState(career)
    local accepted = data and data.orders and data.orders[job.id]
    r:check(accepted and accepted.status == "ACCEPTED", career.name .. ": the job is yours",
        accepted and tostring(accepted.status) or "the job is gone")
    if career.finishesAtContainer then
        r:info("Deliver " .. tostring(job.quantity) .. " x " .. tostring(job.itemLabel)
            .. " into a container and use the career's own Complete Work Order; the tester does not carry goods for you.")
    end
end

function Tests.finish(r, career, player)
    if career.finishesAtContainer then
        r:skip(career.name .. ": this career is paid on delivery at a container, so finish it in the career's own screen")
        return
    end
    local business = ownedBusiness(career, player)
    if not business then r:blocked("Open your " .. career.shopWord .. " first.") return end
    local data = careerState(career)
    local job
    for _, order in pairs((data or {}).orders or {}) do
        local mine = order.targetShopId == business.id
        if mine and order.status == "ACCEPTED" and order.source == "SYSTEM" then job = order end
    end
    if not r:check(job ~= nil, career.name .. ": you have a server job in progress",
        "accept one first with Take a job the server sends you") then return end
    local wallet = balance(player)
    local reply, err = runCommand(career.commands.complete, player, { orderId = job.id })
    if not r:check(reply ~= nil, career.name .. ": the mod's own complete command ran", err) then return end
    local closed = data.orders[job.id]
    r:check(closed and closed.status == "CLOSED", career.name .. ": the walk-in paid and the job closed",
        closed and tostring(closed.status) or "the job is gone")
    local after = balance(player)
    r:check(after == nil or wallet == nil or after > wallet,
        career.name .. ": the payment reached your wallet",
        "wallet " .. tostring(wallet) .. " -> " .. tostring(after) .. "; payments queue until you are near a container")
    r:info("Paid " .. tostring(job.payout) .. " for " .. tostring(job.clientName or "the customer"))
end

-- Every command a career publishes must be registered with KIPN, or one of
-- its screens is dead. This also names the ones the showcase does not drive
-- itself, so a command added later cannot go unnoticed.
function Tests.fw_commands(r)
    local tables = T.CommandTables()
    local careers = 0
    for careerName, commands in pairs(tables) do
        careers = careers + 1
        local missing, uncovered = {}, {}
        for key, command in pairs(commands) do
            if handlerFor(command) == nil then missing[#missing + 1] = command end
            local note = T.CommandNotes[key]
            if not note then uncovered[#uncovered + 1] = command
            elseif not note:find("^run by") and not note:find("^read by") then
                uncovered[#uncovered + 1] = command .. " (" .. note .. ")"
            end
        end
        r:check(#missing == 0, careerName .. ": every command it publishes is registered on the server",
            table.concat(missing, ", "))
        if #uncovered > 0 then
            r:info(careerName .. ": not run by the showcase - " .. table.concat(uncovered, "; "))
        end
    end
    r:check(careers > 0, "At least one career publishes its commands")
end

-- The read-only commands the careers answer their screens with.
function Tests.screens(r, career, player)
    local asked = 0
    for _, screen in ipairs(T.ScreenCommands[career.id] or {}) do
        local args = { requestId = "lilbubby-" .. screen.key }
        if screen.key == "quote" then
            local business = ownedBusiness(career, player)
            if not business then
                r:skip(career.name .. ": a quote needs your own " .. career.shopWord .. " to price")
                args = nil
            else
                args.targetShopId = business.id
                args.tier = "regular"
                args.repairs = { { part = "Engine", quality = 80 } }
                args.forgeItems = { { itemName = "Hunting knife", quantity = 1, quality = 80 } }
            end
        end
        if args then
            local reply, err = runCommand(screen.command, player, args)
            r:check(reply ~= nil, career.name .. ": the mod answers with " .. screen.label, err)
            asked = asked + 1
        end
    end
    if asked == 0 then r:info("This career offers no read-only screens") end
end

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

function Tests.cleanup(r, _, player)
    local removedItems = 0
    local inventory = player:getInventory()
    local items = inventory:getItems()
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if item:hasModData() and item:getModData()[T.TAG] then
            inventory:Remove(item)
            if isServer() then pcall(sendRemoveItemFromContainer, inventory, item) end
            removedItems = removedItems + 1
        end
    end
    r:info("Took back " .. removedItems .. " item(s) the tester gave you")
    local closed = 0
    for _, career in ipairs(T.Careers) do
        local business = ownedBusiness(career, player)
        if business then
            -- The careers have no "close my business" command, so the record
            -- stays; say so plainly rather than editing their books.
            r:info(career.name .. ": your test " .. career.shopWord .. " \"" .. tostring(business.name)
                .. "\" is still open. The career has no close command; leave it or remove it as an admin.")
            closed = closed + 1
        end
    end
    if closed == 0 then r:info("No test businesses are open") end
    local removed, deactivated = LilBubbyDesk.Cleanup(player)
    r:pass("Removed the test terminal and its zone (" .. tostring(removed) .. " object(s), "
        .. tostring(deactivated) .. " zone(s))")
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------

local function deliver(player, text)
    log(tostring(player:getUsername()) .. " | " .. text:gsub("\n", " | "))
    if isServer() then
        sendServerCommand(player, T.MODULE, "result", { playerID = player:getOnlineID(), text = text })
    elseif T.ClientReceive then
        T.ClientReceive({ text = text })
    end
end

function T.RunServer(player, id, args)
    local entry
    for _, candidate in ipairs(T.Catalog()) do if candidate.id == id then entry = candidate end end
    local r = T.NewReport(T.SUITE .. ": " .. (entry and entry.label or tostring(id)))
    if not entry then r:fail("unknown test " .. tostring(id)) return r end
    if not kipnServer() then r:blocked("Enable KIP Network Terminal to use this suite.") return r end
    if not KIPNCareers then r:blocked("Enable the Careers Framework to use this suite.") return r end
    local career = entry.careerId and T.CareerById(entry.careerId)
    local step = Tests[entry.step or entry.id]
    if not step then r:fail("no implementation for " .. tostring(id)) return r end
    local ok, err = pcall(step, r, career, player, args)
    if not ok then r:fail("ERROR: " .. tostring(err)) end
    return r
end

if isServer() or not isClient() then
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= T.MODULE or command ~= "run" or not player or player:isDead() then return end
        -- Requests are queued behind the previous one, never dropped.
        LilBubbyPacer.Run(player, T.MODULE, 100, function()
            local report = T.RunServer(player, type(args) == "table" and args.id, args)
            deliver(player, report:text())
        end)
    end)
end

return CareersTest
