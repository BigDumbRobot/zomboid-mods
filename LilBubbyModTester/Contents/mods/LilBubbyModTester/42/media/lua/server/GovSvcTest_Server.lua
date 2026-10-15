require "LilBubbyDesk"
require "LilBubbyPacer"
-- Server half of the COMPUTER Safehouse and Land Claims suite. Every test
-- runs against the authenticated requester through the mod's real
-- services and command handlers. Items the suite hands out are tagged
-- so "Clean up my test items and claims" can remove them again.
if isClient() then return end
require "GovSvcTest_Checks"

local T = GovSvcTest
local MODULE, TAG = T.MODULE, T.TAG

local PROPERTY_FORM = "Base.KIPNPropertyRegistration"
local EXCAVATION_FORM = "Base.KIPNExcavationRegistration"
local DEED = "Base.KIPNPropertyClaimArtifact"
local PERMITS = {
    small = "Base.KIPNExcavationClaimArtifactSmall",
    medium = "Base.KIPNExcavationClaimArtifactMedium",
    large = "Base.KIPNExcavationClaimArtifactLarge",
}
local RENEWAL_FORMS = { property = PROPERTY_FORM, excavation = EXCAVATION_FORM }
local INGREDIENTS = {
    { "Base.SheetPaper2", 3 }, { "Base.Pen", 1 }, { "Base.Scotchtape", 1 },
    { "Base.Glue", 1 }, { "Base.Paperclip", 2 },
}
local PLACEMENT_RANGE = 15
local ADOPT_MEMBER = "LilBubbyTestMember"

-- Service handles, resolved per run so a late-loading mod is still found.
local S = {}
local function bind()
    local server = KIPN and KIPN.Server
    if not server or not server.GovClaimService or not server.GovArtifactService then
        return "Enable KIP Network Terminal (KIPN) and COMPUTER Safehouse and Land Claims (KIPNGovernmentServices) to run this suite."
    end
    S.K = server
    S.GC, S.GA = server.GovClaimService, server.GovArtifactService
    S.CS, S.AS = server.ClaimService, server.ArtifactService
    S.CC, S.SS = server.ClaimConfig, server.SafehouseService
    S.WR, S.Wallet = server.WorldRegistry, server.Wallet
    S.BR = KIPN.Bridges and KIPN.Bridges.Safehouse
    S.C, S.E = KIPN.Shared.Commands, KIPN.Shared.ResponseEvents
    return nil
end

local function capitalize(text) return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2) end
local function has(text, fragment) return type(text) == "string" and string.find(text, fragment, 1, true) ~= nil end

------------------------------------------------------------
-- OUTBOUND CAPTURE
------------------------------------------------------------

-- Runs fn while recording every sendServerCommand call (still delivered).
local function capture(fn)
    local sent, original = {}, sendServerCommand
    sendServerCommand = function(a, b, c, d)
        if type(a) == "string" then
            sent[#sent + 1] = { module = a, command = b, args = c, broadcast = true }
            return original(a, b, c)
        end
        sent[#sent + 1] = { player = a, module = b, command = c, args = d }
        return original(a, b, c, d)
    end
    local results = { pcall(fn) }
    sendServerCommand = original
    if not results[1] then error(results[2], 0) end
    return sent, results[2], results[3]
end

local function responses(sent, event)
    local found = {}
    for _, entry in ipairs(sent or {}) do
        local args = entry.args
        if entry.command == S.C.SERVER_RESPONSE and type(args) == "table" and (not event or args.event == event) then
            found[#found + 1] = args
        end
    end
    return found
end

local function projections(sent)
    local found = {}
    for _, entry in ipairs(sent or {}) do
        if entry.command == S.C.SAFEHOUSE_PROJECTION_SYNC then found[#found + 1] = entry end
    end
    return found
end

-- Calls a registered KIPN command handler the way the dispatcher does.
local function callHandler(command, player, args)
    local handler = S.K.GetCommandHandler(command)
    local result = { handled = false, reason = "handler not registered: " .. tostring(command), sent = {} }
    if type(handler) == "function" then
        local sent, handled, reason = capture(function() return handler(player, args or {}) end)
        result = { handled = handled, reason = reason, sent = sent }
    end
    result.first = function(event) return responses(result.sent, event)[1] end
    result.errorCode = function()
        local err = responses(result.sent, S.E.ERROR)[1]
        return err and err.data and err.data.code, err and err.data and err.data.message
    end
    return result
end

------------------------------------------------------------
-- INVENTORY
------------------------------------------------------------

local function eachContainer(player, fn)
    local seen = {}
    local function visit(container)
        if not container or seen[container] then return end
        seen[container] = true
        fn(container)
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item and instanceof(item, "InventoryContainer") then visit(item:getInventory()) end
        end
    end
    visit(player:getInventory())
end

local function allItems(player)
    local list = {}
    eachContainer(player, function(container)
        local items = container:getItems()
        for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    end)
    return list
end

local function itemsOfType(player, fullType)
    local list = {}
    for _, item in ipairs(allItems(player)) do
        if item:getFullType() == fullType then list[#list + 1] = item end
    end
    return list
end

local function holds(player, target)
    for _, item in ipairs(allItems(player)) do
        if item == target then return true end
    end
    return false
end

local function tag(item)
    if item then item:getModData()[TAG] = true end
    return item
end

local function give(player, fullType, count)
    local inventory, added = player:getInventory(), {}
    for _ = 1, count or 1 do
        local item = inventory:AddItem(fullType)
        if not item then break end
        tag(item)
        if type(sendAddItemToContainer) == "function" then pcall(sendAddItemToContainer, inventory, item) end
        added[#added + 1] = item
    end
    return added
end

local function removeItem(item)
    local container = item and item:getContainer()
    if not container then return false end
    container:Remove(item)
    if type(sendRemoveItemFromContainer) == "function" then pcall(sendRemoveItemFromContainer, container, item) end
    return true
end

-- Retires a test document: consumes its artifact record, then removes it.
local function discard(player, item)
    if not item or not holds(player, item) then return end
    if S.AS.GetItemArtifactId(item) then S.AS.ConsumeArtifactItem(player, item) end
    if holds(player, item) then removeItem(item) end
end

-- Tags items of a type that appeared since `before` (a list from itemsOfType).
local function tagNew(player, fullType, before)
    local known, added = {}, {}
    for _, item in ipairs(before) do known[item] = true end
    for _, item in ipairs(itemsOfType(player, fullType)) do
        if not known[item] then added[#added + 1] = tag(item) end
    end
    return added
end

local function cashTotal(player)
    return S.Wallet.CountInventoryCurrency(player)
end

local function giveCash(player, amount)
    local _, currencyType, value = cashTotal(player)
    local bundles, singles = T.CashSplit(amount, value)
    if not bundles then return false end
    give(player, "Base.MoneyBundle", bundles)
    give(player, currencyType, singles)
    return true
end

------------------------------------------------------------
-- WORLD
------------------------------------------------------------

local function position(player)
    return { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
end

local function insideBuilding(player)
    local square = player:getCurrentSquare()
    return square ~= nil and square:getBuilding() ~= nil
end

local function buildingFootprint(player)
    local def = player:getCurrentSquare():getBuilding():getDef()
    return { x1 = def:getX(), y1 = def:getY(), x2 = def:getX() + def:getW() - 1, y2 = def:getY() + def:getH() - 1 }
end

local function safehouses()
    local list, out = SafeHouse.getSafehouseList(), {}
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out
end

-- True when any safehouse overlaps the inclusive rectangle.
local function safehouseOverlaps(rect)
    for _, safehouse in ipairs(safehouses()) do
        local other = S.BR.GetRect(safehouse)
        if other and other.x1 <= rect.x2 and other.x2 >= rect.x1 and other.y1 <= rect.y2 and other.y2 >= rect.y1 then
            return true
        end
    end
    return false
end

local function sameProjection(a, b)
    return a ~= nil and b ~= nil and a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h
end

local function describeProjection(rect)
    return rect and (rect.x .. "," .. rect.y .. " " .. rect.w .. "x" .. rect.h) or "none"
end

local function testScope()
    local zones = S.WR.GetZones and S.WR.GetZones(S.WR.ZoneTypes.GOVERNMENT) or {}
    for key, zone in pairs(zones) do return tostring(type(zone) == "table" and zone.id or key) end
    return "lilbubby-test-scope"
end

local function nearbyComputer(player)
    local origin, cell = player:getCurrentSquare(), getCell()
    if not origin or not cell then return nil end
    local best, bestDistance
    for dx = -3, 3 do
        for dy = -3, 3 do
            local square = cell:getGridSquare(origin:getX() + dx, origin:getY() + dy, origin:getZ())
            local objects = square and square:getObjects()
            if objects then
                for i = 0, objects:size() - 1 do
                    local object = objects:get(i)
                    local distance = math.abs(dx) + math.abs(dy)
                    if KIPN.Shared.IsComputerObjectSprite(object) and (not best or distance < bestDistance) then
                        best, bestDistance = object, distance
                    end
                end
            end
        end
    end
    return best
end

local function findRecipe(name)
    local manager = ScriptManager.instance
    for _, candidate in ipairs({ "Base." .. name, name }) do
        local ok, recipe = pcall(function() return manager:getCraftRecipe(candidate) end)
        if ok and recipe then return recipe end
    end
    local ok, all = pcall(function() return manager:getAllCraftRecipes() end)
    if ok and all then
        for i = 0, all:size() - 1 do
            local recipe = all:get(i)
            if recipe and recipe:getName() == name then return recipe end
        end
    end
end

------------------------------------------------------------
-- TEST CLAIM TRACKING
------------------------------------------------------------

local function claimStore(player)
    local data = ModData.getOrCreate(TAG)
    data.claims = data.claims or {}
    local key = tostring(S.CS.GetPlayerSteamId(player))
    data.claims[key] = data.claims[key] or {}
    return data.claims[key]
end

local function track(player, claimId)
    claimStore(player)[tostring(claimId)] = getTimestampMs()
end

-- Active test claims for the player, oldest first.
local function trackedClaims(player, claimType)
    local store, list = claimStore(player), {}
    for id, stamp in pairs(store) do
        local claim = S.CS.GetClaim(id)
        if not claim or claim.active == false then
            store[id] = nil
        elseif not claimType or claim.type == claimType then
            list[#list + 1] = { claim = claim, stamp = stamp }
        end
    end
    table.sort(list, function(a, b) return a.stamp < b.stamp end)
    local claims = {}
    for i, row in ipairs(list) do claims[i] = row.claim end
    return claims
end

local function latestClaim(player, claimType)
    local claims = trackedClaims(player, claimType)
    return claims[#claims]
end

local function claimRect(claim)
    return { x1 = tonumber(claim.rectX1), y1 = tonumber(claim.rectY1), x2 = tonumber(claim.rectX2), y2 = tonumber(claim.rectY2) }
end

local function countClaims(player, claimType)
    local count = 0
    for _, claim in pairs(S.CS.GetPlayerClaims(player)) do
        if claim.type == claimType then count = count + 1 end
    end
    return count
end

local function quotaFull(player, r, claimType)
    local max = tonumber(S.CC.GetServiceConfig(claimType).MaxClaimsPerPlayer) or 0
    local count = countClaims(player, claimType)
    if max > 0 and count >= max then
        r:blocked("you already hold " .. count .. "/" .. max .. " " .. claimType .. " claims; release one first")
        return true
    end
    return false
end

local function listedRow(sent, claimId)
    for _, response in ipairs(responses(sent, S.E.MY_CLAIMS_DATA)) do
        for _, row in ipairs(type(response.data) == "table" and response.data or {}) do
            if type(row) == "table" and tostring(row.id) == tostring(claimId) then return row end
        end
    end
end

local function claimByArtifact(player, claimType, artifactId)
    for _, row in pairs(S.CS.GetPlayerClaims(player)) do
        if row.type == claimType and tostring(row.artifactId) == tostring(artifactId) then return row end
    end
end

------------------------------------------------------------
-- DOCUMENT HELPERS
------------------------------------------------------------

local function issueDeed(player, r)
    local before = #itemsOfType(player, PROPERTY_FORM)
    local form = give(player, PROPERTY_FORM, 1)[1]
    if not r:check(form ~= nil, "received a Safehouse Registration Form") then return end
    local registered, reason = S.GA.RegisterPropertyRegistration(player, form)
    if not r:check(registered == true, "registration form registered with the server", reason) then return end
    local ok, record, item, dropped = S.GA.IssuePropertyClaim(player, testScope())
    if not r:check(ok == true, "Safehouse Deed issued", record) then return end
    tag(item)
    r:equal(item and item:getFullType(), DEED, "deed item type")
    r:equal(tostring(S.AS.GetItemArtifactId(item)), tostring(record.id), "deed carries its server artifact id")
    r:equal(#itemsOfType(player, PROPERTY_FORM), before, "registration form consumed")
    if dropped then r:info("inventory full: the deed was dropped at your feet") end
    return item, record
end

local function issuePermit(player, r, tierId)
    local tier = S.CC.GetExcavationSizeTierById(tierId)
    if not r:check(tier ~= nil, tierId .. " tier configured") then return end
    local before = #itemsOfType(player, EXCAVATION_FORM)
    local form = give(player, EXCAVATION_FORM, 1)[1]
    if not r:check(form ~= nil, "received an Excavation Registration Form") then return end
    local registered, reason = S.GA.RegisterExcavationRegistration(player, form)
    if not r:check(registered == true, "registration form registered with the server", reason) then return end
    local ok, record, item, dropped = S.GA.IssueExcavationClaim(player, testScope(), tier)
    if not r:check(ok == true, capitalize(tierId) .. " Excavation Permit issued", record) then return end
    tag(item)
    local data = item and item:getModData() or {}
    r:equal(item and item:getFullType(), PERMITS[tierId], "permit item type")
    r:equal(data.KIPNExcavationSize, tierId, "permit size class on the item")
    r:equal(data.KIPNExcavationClassSize, tierId, "permit class on the item")
    r:equal(type(record.metadata) == "table" and record.metadata.classSize, tierId, "permit class on the server record")
    r:check(item and has(item:getName(), tier.label), "permit name shows the size", item and item:getName())
    r:equal(#itemsOfType(player, EXCAVATION_FORM), before, "registration form consumed")
    if dropped then r:info("inventory full: the permit was dropped at your feet") end
    return item, record, tier
end

------------------------------------------------------------
-- SHARED VERIFIERS
------------------------------------------------------------

local function verifyHouse(player, r, claim)
    local label = "safehouse claim " .. tostring(claim.id)
    r:check(claim.active ~= false, label .. " is active")
    r:check(claim.safehouseManaged == true, label .. " is KIPN-managed")
    r:check(claim.rectIsFootprint == true, label .. " records the building footprint")
    r:equal(claim.ownerUsername, player:getUsername(), label .. " owner")
    local safehouse = S.BR.FindForClaim(claim)
    local live
    if r:check(safehouse ~= nil, label .. " has a vanilla safehouse") then
        live = S.BR.GetProjectionRect(safehouse)
        local expected = T.ProjectionRect(claim.rectX1, claim.rectY1, claim.rectX2, claim.rectY2)
        r:equal(S.BR.GetOwner(safehouse), player:getUsername(), "vanilla safehouse owner")
        r:check(sameProjection(live, expected),
            "vanilla safehouse is the footprint plus the " .. T.SAFEHOUSE_BUFFER_TILES .. "-tile buffer",
            "footprint " .. claim.rectX1 .. "," .. claim.rectY1 .. "-" .. claim.rectX2 .. "," .. claim.rectY2
                .. ", safehouse " .. describeProjection(live))
        r:equal(tostring(claim.safehouseId), tostring(S.BR.GetId(safehouse)), "claim remembers the safehouse id")
    end
    r:check(not S.CS.IsClaimExpired(claim), label .. " is not expired")
    local list = callHandler(S.C.GET_MY_CLAIMS, player, {})
    local row = listedRow(list.sent, claim.id)
    if r:check(row ~= nil, label .. " appears in Property Records") then
        r:info(label .. " expires in " .. tostring(row.expiryDaysRemaining) .. " day(s)")
    end
    -- Listing claims runs reconciliation; the safehouse must not change.
    local after = S.BR.FindForClaim(claim)
    r:check(after ~= nil and sameProjection(S.BR.GetProjectionRect(after), live),
        label .. " safehouse is stable after reconciliation", describeProjection(after and S.BR.GetProjectionRect(after)))
    return live and { x = live.x, y = live.y, w = live.w, h = live.h, owner = claim.ownerUsername, id = claim.id }
end

local function verifyLand(player, r, claim)
    local label = "excavation claim " .. tostring(claim.id)
    r:check(claim.active ~= false, label .. " is active")
    r:equal(claim.ownerUsername, player:getUsername(), label .. " owner")
    local width, height = tonumber(claim.sizeWidthTiles), tonumber(claim.sizeHeightTiles)
    local expected = T.ExcavationRect(tonumber(claim.locationX), tonumber(claim.locationY), tonumber(claim.locationZ), width, height)
    r:check(T.SameRect(claimRect(claim), expected), label .. " area is " .. tostring(width) .. "x" .. tostring(height) .. " centred on its anchor")
    r:check(S.CC.GetExcavationSizeTierById(tostring(claim.sizeTierId)) ~= nil, label .. " size class " .. tostring(claim.sizeTierId) .. " is valid")
    local sent = capture(function() S.SS.BroadcastExcavationAreas() end)
    local seen = false
    for _, response in ipairs(responses(sent, "KIPN_ExcavationAreas")) do
        for _, area in ipairs(response.data and response.data.areas or {}) do
            if T.SameRect(area, claimRect(claim)) then seen = true end
        end
    end
    r:check(seen, label .. " is in the excavation areas sent to players")
    local list = callHandler(S.C.GET_MY_CLAIMS, player, {})
    r:check(listedRow(list.sent, claim.id) ~= nil, label .. " appears in Property Records")
    return { x1 = claim.rectX1, y1 = claim.rectY1, x2 = claim.rectX2, y2 = claim.rectY2, z = tonumber(claim.locationZ) or 0, id = claim.id }
end

------------------------------------------------------------
-- TESTS
------------------------------------------------------------

local tests = {}
GovSvcTest.ServerTests = tests

local function craftTest(player, r, recipeName, output)
    local recipe = findRecipe(recipeName)
    if not r:check(recipe ~= nil, recipeName .. " registered") then return end
    for _, row in ipairs(INGREDIENTS) do
        r:equal(#give(player, row[1], row[2]), row[2], "received " .. row[2] .. " x " .. row[1])
    end
    local ok, ready, detail = pcall(function()
        local containers = ArrayList.new()
        eachContainer(player, function(container) containers:add(container) end)
        local logic = HandcraftLogic.new(player, nil, nil)
        logic:setContainers(containers)
        logic:setRecipe(recipe)
        logic:refresh()
        return logic:canPerformCurrentRecipe() == true, "inputs satisfied=" .. tostring(logic:areAllInputItemsSatisfied())
    end)
    if ok then
        r:check(ready, "the recipe can be crafted now", detail)
    else
        r:fail("crafting check errored: " .. tostring(ready))
    end
    -- Your client then crafts it with the normal timed action (LilBubbyCraft).
    if ok and ready then r.clientCheck = { name = "craft", data = { recipe = recipeName, output = output } } end
end

tests.craft_property = function(player, r) craftTest(player, r, "KIPN.CreatePropertyRegistration", PROPERTY_FORM) end
tests.craft_excavation = function(player, r) craftTest(player, r, "KIPN.CreateExcavationRegistration", EXCAVATION_FORM) end

local function registerTest(player, r, formType, register, service)
    local form = give(player, formType, 1)[1]
    if not r:check(form ~= nil, "received a " .. formType) then return end
    local ok, record = S.GA[register](player, form)
    if not r:check(ok == true, "registration accepted", record) then return end
    r:equal(tostring(S.AS.GetItemArtifactId(form)), tostring(record.id), "form carries its artifact id")
    local stored = S.AS.GetArtifact(record.id)
    r:check(stored ~= nil and stored.service == service and stored.itemType == formType, "server stored the " .. service .. " registration")
    local again, againReason = S.GA[register](player, form)
    r:check(again == false, "a form cannot be registered twice", againReason)
    local paper = give(player, "Base.SheetPaper2", 1)[1]
    local wrong, wrongReason = S.GA[register](player, paper)
    r:check(wrong == false, "another item cannot be registered", wrongReason)
    removeItem(paper)
    local missing, missingReason = S.GA[register](player, nil)
    r:check(missing == false, "a missing item is refused", missingReason)
end

tests.register_property = function(player, r) registerTest(player, r, PROPERTY_FORM, "RegisterPropertyRegistration", "property") end
tests.register_excavation = function(player, r) registerTest(player, r, EXCAVATION_FORM, "RegisterExcavationRegistration", "excavation") end

tests.issue_deed = function(player, r)
    issueDeed(player, r)
    local refused, reason = S.GA.IssuePropertyClaim(player, nil)
    r:check(refused == false, "issuing without a registration zone is refused", reason)
end

for _, tierId in ipairs(T.TIERS) do
    tests["issue_permit_" .. tierId] = function(player, r)
        issuePermit(player, r, tierId)
        local scope = testScope()
        local noPrice, noPriceReason = S.GA.IssueExcavationClaim(player, scope, { id = tierId, widthTiles = 5, heightTiles = 5 })
        r:check(noPrice == false, "a size without a price is refused", noPriceReason)
        local badClass, badReason = S.GA.IssueExcavationClaim(player, scope, { id = "huge", widthTiles = 5, heightTiles = 5, price = 1 })
        r:check(badClass == false, "an unknown size class is refused", badReason)
        local noTier, noTierReason = S.GA.IssueExcavationClaim(player, scope, nil)
        r:check(noTier == false, "a missing size is refused", noTierReason)
    end
end

local function forgedChecks(player, r, fullType, validate, label)
    local paper = give(player, "Base.SheetPaper2", 1)[1]
    local wrong, wrongReason = validate(player, paper, nil)
    r:check(wrong == false, "another item is not a valid " .. label, wrongReason)
    removeItem(paper)
    local forged = give(player, fullType, 1)[1]
    local fake, fakeReason = validate(player, forged, nil)
    r:check(fake == false, "a " .. label .. " without a server record is refused", fakeReason)
    removeItem(forged)
end

tests.deed_lifecycle = function(player, r)
    local item, record = issueDeed(player, r)
    if not item then return end
    local found, foundRecord = S.GA.FindPlayerPropertyClaimArtifact(player)
    r:check(found ~= nil and foundRecord ~= nil, "a valid deed is found in your inventory")
    local valid, validRecord = S.GA.ValidatePropertyClaim(player, item, nil)
    r:check(valid == true and validRecord and validRecord.id == record.id, "the deed validates", validRecord)
    r:check(S.GC.ValidatePropertyClaimArtifact(player, item, nil) == true, "claim service accepts the deed")
    forgedChecks(player, r, DEED, S.GA.ValidatePropertyClaim, "Safehouse Deed")
    local consumed, consumeReason = S.GA.ConsumePropertyClaim(player, item, nil)
    r:check(consumed == true, "the deed is consumed", consumeReason)
    if S.AS.GetArtifactConfig().Consumption.ConsumeClaimAfterSuccessfulClaim ~= false then
        r:check(not holds(player, item), "the deed left your inventory")
        r:check(S.AS.GetArtifact(record.id).consumed == true, "the server record is marked consumed")
        r:check(S.GA.ValidatePropertyClaim(player, item, nil) == false, "a consumed deed no longer validates")
    else
        r:info("ConsumeClaimAfterSuccessfulClaim is off; the deed is kept")
    end
end

tests.permit_lifecycle = function(player, r)
    local item, record = issuePermit(player, r, "small")
    if not item then return end
    local found, foundRecord = S.GA.FindPlayerExcavationClaimArtifact(player)
    r:check(found ~= nil and foundRecord ~= nil, "a valid permit is found in your inventory")
    local stored = S.AS.GetArtifact(record.id)
    stored.metadata = nil
    local valid, validRecord = S.GA.ValidateExcavationClaim(player, item, nil)
    r:check(valid == true and validRecord and validRecord.id == record.id, "the permit validates", validRecord)
    r:equal(stored.metadata and stored.metadata.classSize, "small", "a permit record without a class is repaired from its item type")
    r:check(S.GC.ValidateExcavationClaimArtifact(player, item, nil) == true, "claim service accepts the permit")
    forgedChecks(player, r, PERMITS.small, S.GA.ValidateExcavationClaim, "Excavation Permit")
    local consumed, consumeReason = S.GA.ConsumeExcavationClaim(player, item, nil)
    r:check(consumed == true, "the permit is consumed", consumeReason)
    if S.AS.GetArtifactConfig().Consumption.ConsumeClaimAfterSuccessfulClaim ~= false then
        r:check(not holds(player, item), "the permit left your inventory")
        r:check(S.AS.GetArtifact(record.id).consumed == true, "the server record is marked consumed")
    end
end

-- Nearby computer and what the desk should do there.
local function describeDesk(computerId)
    local classification = S.WR.GetComputerClassification(computerId)
    local desk = {
        id = computerId,
        government = classification ~= nil and classification.government == true,
        powered = S.K.CheckBuildingPower(computerId) == true,
    }
    desk.valid = desk.government and desk.powered
    return desk
end

local function deskContext(player, r)
    local computer = nearbyComputer(player)
    local desk = computer and describeDesk(KIPN.Shared.GetComputerId(computer))
    if not (desk and desk.valid) then
        -- No powered government computer here: set up a test desk (LilBubbyDesk).
        local id, notes = LilBubbyDesk.Ensure(player, S.WR.ZoneTypes and S.WR.ZoneTypes.GOVERNMENT or "government")
        if not id then
            r:blocked("no powered government computer nearby, and a test desk could not be set up: " .. tostring(notes))
            return
        end
        r:info("test desk: " .. notes)
        desk = describeDesk(id)
    end
    r:info("computer " .. tostring(desk.id) .. " | government zone=" .. tostring(desk.government)
        .. " | power=" .. tostring(desk.powered))
    return desk
end

-- Reports a desk refusal; refusals are expected away from a powered government desk.
local function deskRefused(r, desk, reason, what)
    if desk.valid then
        r:fail("the government desk refused " .. what .. ": " .. tostring(reason))
    elseif not desk.government then
        r:check(has(reason, "government") or has(reason, "COMPUTER_"), "a computer outside a government zone refuses " .. what, reason)
    else
        r:check(has(reason, "power"), "an unpowered government computer refuses " .. what, reason)
    end
end

tests.desk_deed = function(player, r)
    local refused = callHandler(S.C.ISSUE_PROPERTY_CLAIM, player, {})
    r:check(refused.handled == false, "a request without a computer is refused", refused.reason)
    local desk = deskContext(player, r)
    if not desk then return end
    local before = itemsOfType(player, DEED)
    local form = give(player, PROPERTY_FORM, 1)[1]
    local reply = callHandler(S.C.ISSUE_PROPERTY_CLAIM, player, { computerId = desk.id })
    if reply.handled == false then
        discard(player, form)
        deskRefused(r, desk, reply.reason, "a deed")
        return
    end
    r:check(desk.valid, "only a powered government computer issues deeds")
    local issued = reply.first(S.E.PROPERTY_CLAIM_ARTIFACT_ISSUED)
    r:check(issued ~= nil, "desk reports the deed as issued")
    if issued and issued.data and issued.data.droppedOnGround then
        r:info("inventory full: the deed was dropped at your feet")
    else
        r:equal(#tagNew(player, DEED, before), 1, "one deed added to your inventory")
    end
end

for _, tierId in ipairs(T.TIERS) do
    tests["desk_permit_" .. tierId] = function(player, r)
        local desk = deskContext(player, r)
        if not desk then return end
        local tier = S.CC.GetExcavationSizeTierById(tierId)
        local startCash = cashTotal(player)
        local form = give(player, EXCAVATION_FORM, 1)[1]
        if desk.valid and tier.price > 0 and startCash < tier.price then
            local broke = callHandler(S.C.ISSUE_EXCAVATION_CLAIM, player, { computerId = desk.id, tierId = tierId })
            r:check(broke.handled == false and has(broke.reason, "Insufficient"), "without enough cash the permit is refused", broke.reason)
        end
        local before = itemsOfType(player, PERMITS[tierId])
        r:check(giveCash(player, tier.price), "received " .. tier.price .. " in cash for the fee")
        local funded = cashTotal(player)
        local reply = callHandler(S.C.ISSUE_EXCAVATION_CLAIM, player, { computerId = desk.id, tierId = tierId })
        local function refundSurplus()
            local surplus = cashTotal(player) - startCash
            if surplus > 0 then S.Wallet.Charge(player, surplus) end
        end
        if reply.handled == false then
            discard(player, form)
            refundSurplus()
            deskRefused(r, desk, reply.reason, "a permit")
            return
        end
        r:check(desk.valid, "only a powered government computer sells permits")
        r:check(reply.first(S.E.EXCAVATION_CLAIM_ARTIFACT_ISSUED) ~= nil, "desk reports the permit as issued")
        r:equal(cashTotal(player), funded - tier.price, "the fee of " .. tier.price .. " was charged")
        refundSurplus()
        r:equal(#tagNew(player, PERMITS[tierId], before), 1, capitalize(tierId) .. " permit added to your inventory")
        local extra = give(player, EXCAVATION_FORM, 1)[1]
        local badTier = callHandler(S.C.ISSUE_EXCAVATION_CLAIM, player, { computerId = desk.id, tierId = "huge" })
        r:check(badTier.handled == false and has(badTier.reason, "valid excavation claim size"), "an unknown size is refused at the desk", badTier.reason)
        discard(player, extra)
    end
end

tests.desk_cash = function(player, r)
    local total, currencyType, value = cashTotal(player)
    r:info("server wallet counts " .. tostring(total) .. " (" .. tostring(currencyType) .. " worth " .. tostring(value) .. ", bundles worth 100)")
    local charged, reason = S.Wallet.Charge(player, 0)
    r:check(charged == true, "a zero fee always succeeds", reason)
    r.clientCheck = { name = "cash", data = { total = total } }
end

tests.house_check = function(player, r)
    local pos = position(player)
    local ok, reason, data = S.GC.ValidatePropertyTarget(player, pos)
    if not insideBuilding(player) then
        r:check(ok == false and has(reason, "inside a building"), "claiming outside a building is refused", reason)
        r:info("stand inside a building to check it")
        return
    end
    if not ok then
        r:blocked("this building cannot be claimed: " .. tostring(reason))
        return
    end
    r:pass("this building can be claimed")
    local footprint = buildingFootprint(player)
    r:check(T.SameRect(data.rect, footprint), "the claim records the whole building footprint")
    r:equal(data.targetId, footprint.x1 .. "_" .. footprint.y1 .. "_" .. footprint.x2 .. "_" .. footprint.y2, "target id is the footprint")
    local buffered = { x1 = footprint.x1 - T.SAFEHOUSE_BUFFER_TILES, y1 = footprint.y1 - T.SAFEHOUSE_BUFFER_TILES,
        x2 = footprint.x2 + T.SAFEHOUSE_BUFFER_TILES, y2 = footprint.y2 + T.SAFEHOUSE_BUFFER_TILES }
    if data.existingSafehouse then
        r:info("your vanilla safehouse here will be adopted and rebuilt with the buffer")
    else
        r:check(not safehouseOverlaps(buffered), "no safehouse overlaps the building or its buffer")
    end
    r:info("your safehouse claims: " .. countClaims(player, "property") .. "/" .. tostring(S.CC.GetServiceConfig("property").MaxClaimsPerPlayer))
end

-- Claims the building the player stands in with a freshly issued deed.
local function claimHere(player, r)
    local _, record = issueDeed(player, r)
    if not record then return end
    local reply = callHandler(S.C.CLAIM_PROPERTY, player, {})
    if reply.handled == false then
        r:fail("the claim was refused: " .. tostring(reply.reason))
        r:info("the deed stays in your inventory for a retry through Claim This Location")
        return
    end
    r:check(reply.first(S.E.PROPERTY_CLAIM_SUCCESSFUL) ~= nil, "the server reports the claim as successful")
    r:check(#projections(reply.sent) > 0, "the new safehouse is sent to players")
    local claim = claimByArtifact(player, "property", record.id)
    if not r:check(claim ~= nil, "the claim record uses the deed") then return end
    track(player, claim.id)
    r:check(S.AS.GetArtifact(record.id).consumed == true, "the deed was consumed")
    r:check(T.SameRect(claimRect(claim), buildingFootprint(player)), "the claim records the building footprint")
    return claim
end

tests.house_claim = function(player, r)
    if not insideBuilding(player) then r:skip("stand inside a building to claim it"); return end
    local ok, reason = S.GC.ValidatePropertyTarget(player, position(player))
    if not ok then r:blocked("this building cannot be claimed: " .. tostring(reason)); return end
    if quotaFull(player, r, "property") then return end
    local claim = claimHere(player, r)
    if not claim then return end
    r.clientCheck = { name = "house", data = { houses = { verifyHouse(player, r, claim) } } }
end

tests.house_adopt = function(player, r)
    if not insideBuilding(player) then r:skip("stand inside an unclaimed building"); return end
    if quotaFull(player, r, "property") then return end
    local footprint = buildingFootprint(player)
    local buffered = { x1 = footprint.x1 - T.SAFEHOUSE_BUFFER_TILES, y1 = footprint.y1 - T.SAFEHOUSE_BUFFER_TILES,
        x2 = footprint.x2 + T.SAFEHOUSE_BUFFER_TILES, y2 = footprint.y2 + T.SAFEHOUSE_BUFFER_TILES }
    if safehouseOverlaps(buffered) then r:skip("this building or its buffer already has a safehouse"); return end
    local original = { x = footprint.x1, y = footprint.y1, w = footprint.x2 - footprint.x1 + 1, h = footprint.y2 - footprint.y1 + 1 }
    local vanilla = SafeHouse.addSafeHouse(original.x, original.y, original.w, original.h, player:getUsername())
    if not r:check(vanilla ~= nil, "a plain vanilla safehouse was made on the building footprint") then return end
    pcall(function() vanilla:addPlayer(ADOPT_MEMBER) end)
    pcall(function() vanilla:setTitle("LilBubby adopt test") end)
    S.SS.BroadcastProjectionForSafehouse(vanilla)
    local ok, reason, data = S.GC.ValidatePropertyTarget(player, position(player))
    r:check(ok == true and data.existingSafehouse == vanilla, "your vanilla safehouse is recognised for adoption", reason)
    local claim = ok and claimHere(player, r)
    if not claim then
        local leftover = S.BR.FindExactRect(original)
        if leftover then
            local snapshot = S.BR.Snapshot(leftover)
            S.BR.RemoveAuthoritative(leftover)
            S.SS.BroadcastProjectionRemoval(snapshot)
        end
        return
    end
    r:check(claim.safehouseAdopted == true, "the claim is marked as adopted")
    r:check(S.BR.FindExactRect(original) == nil, "the unbuffered safehouse is gone")
    local live = S.BR.FindForClaim(claim)
    local snapshot = live and S.BR.Snapshot(live)
    local kept = false
    for _, member in ipairs(snapshot and snapshot.members or {}) do
        if member == ADOPT_MEMBER then kept = true end
    end
    r:check(kept, "safehouse members are kept")
    r:equal(snapshot and snapshot.title, "LilBubby adopt test", "safehouse title is kept")
    r.clientCheck = { name = "house", data = { houses = { verifyHouse(player, r, claim) } } }
end

tests.house_verify = function(player, r)
    local claims = trackedClaims(player, "property")
    if #claims == 0 then r:skip("run Claim this building first"); return end
    local houses = {}
    for _, claim in ipairs(claims) do houses[#houses + 1] = verifyHouse(player, r, claim) end
    r.clientCheck = { name = "house", data = { houses = houses } }
end

tests.house_expiry = function(player, r)
    local claim = latestClaim(player, "property")
    if not claim then r:skip("run Claim this building first"); return end
    local days = tonumber(S.CC.GetServiceConfig("property").OwnershipExpiryDays) or 0
    if days <= 0 then r:skip("safehouse ownership never expires on this server"); return end
    local now = S.CS.GetWorldDays()
    claim.lastRenewedAtWorldDays = now - days - 1
    r:check(S.CS.IsClaimExpired(claim), "a claim past " .. days .. " days reads as expired")
    local renewed, why = S.CS.RenewClaim(claim.id)
    r:check(renewed == true, "the claim store renews it", why)
    r:check(not S.CS.IsClaimExpired(claim), "renewal restarts the ownership period")
    claim.lastRenewedAtWorldDays = now - days - 1
    local sent = capture(function() S.CS.GetPlayerClaims(player) end)
    local after = S.CS.GetClaim(claim.id)
    r:check(after.active == false, "the expired claim is released on the next lookup")
    r:equal(after.releaseReason, "ownership_expired", "release reason")
    r:check(S.BR.FindForClaim(claim) == nil, "the vanilla safehouse is removed with it")
    r:check(#projections(sent) > 0, "players are told the safehouse is gone")
end

tests.house_release_panel = function(player, r)
    local empty = callHandler(S.C.RELEASE_SAFEHOUSE, player, {})
    r:check(empty.handled == false and empty.reason == "INVALID_SAFEHOUSE_RECT", "a release without an area is refused", empty.reason)
    local missing = callHandler(S.C.RELEASE_SAFEHOUSE, player, { x = 1, y = 1, w = 1, h = 1 })
    r:equal(missing.errorCode(), "SAFEHOUSE_NOT_FOUND", "releasing a missing safehouse reports it")
    local claim = latestClaim(player, "property")
    if not claim then r:skip("run Claim this building first"); return end
    local safehouse = S.BR.FindForClaim(claim)
    if not r:check(safehouse ~= nil, "the claim has a vanilla safehouse") then return end
    local rect = S.BR.GetProjectionRect(safehouse)
    local reply = callHandler(S.C.RELEASE_SAFEHOUSE, player, rect)
    local code, message = reply.errorCode()
    if not r:check(reply.handled ~= false and code == nil, "the panel release is accepted", tostring(reply.reason or code) .. " " .. tostring(message)) then return end
    local after = S.CS.GetClaim(claim.id)
    r:check(after.active == false, "the KIPN claim is released")
    r:check(after.releaseReason == "player_released" or after.releaseReason == "admin_released", "release reason", after.releaseReason)
    r:check(S.BR.FindExactRect(rect) == nil, "the vanilla safehouse is removed")
    r:check(reply.first(S.E.MY_CLAIMS_DATA) ~= nil, "Property Records is refreshed")
    r:check(#projections(reply.sent) > 0, "players are told the safehouse is gone")
end

tests.house_release_records = function(player, r)
    local empty = callHandler(S.C.RELEASE_CLAIM, player, {})
    r:equal(empty.errorCode(), "CLAIM_ID_REQUIRED", "a release without a claim id is refused")
    local claim = latestClaim(player, "property")
    if not claim then r:skip("run Claim this building first"); return end
    local safehouse = S.BR.FindForClaim(claim)
    local rect = safehouse and S.BR.GetProjectionRect(safehouse)
    local reply = callHandler(S.C.RELEASE_CLAIM, player, { claimId = claim.id })
    local code, message = reply.errorCode()
    if not r:check(code == nil, "Property Records release is accepted", tostring(code) .. " " .. tostring(message)) then return end
    r:check(S.CS.GetClaim(claim.id).active == false, "the KIPN claim is released")
    r:check(rect == nil or S.BR.FindExactRect(rect) == nil, "the vanilla safehouse is removed")
    r:check(reply.first(S.E.MY_CLAIMS_DATA) ~= nil, "Property Records is refreshed")
end

tests.zones_here = function(player, r)
    local pos = position(player)
    local zones = S.WR.GetZonesAtPosition(pos.x, pos.y, pos.z) or {}
    local doNotClaim, service = false, false
    for id, zone in pairs(zones) do
        r:info("you are in zone " .. tostring(zone.name or id) .. " (" .. tostring(zone.type) .. ")")
        if zone.type == S.WR.ZoneTypes.DO_NOT_CLAIM then doNotClaim = true
        elseif zone.type ~= S.WR.ZoneTypes.CUSTOM then service = true end
    end
    if not doNotClaim and not service then
        r:skip("stand inside a Do Not Claim zone or a KIPN service zone (government, dealership, ...) to test zone rules")
        return
    end
    local ok, reason = S.GC.ValidateExcavationTarget(player, pos, S.CC.GetExcavationSizeTierById("small"))
    if doNotClaim then
        r:check(not ok and has(reason, "Do Not Claim"), "land in a Do Not Claim zone cannot be claimed", reason)
    else
        r:check(not ok and has(reason, "restricted KIPN service zone"), "land in a KIPN service zone cannot be claimed", reason)
    end
    if insideBuilding(player) then
        local houseOk, houseReason = S.GC.ValidatePropertyTarget(player, pos)
        if doNotClaim then
            r:check(not houseOk and has(houseReason, "Do Not Claim"), "a building in a Do Not Claim zone cannot be claimed", houseReason)
        elseif S.CC.GetServiceConfig("property").AllowClaimsInKIPNZones == true then
            r:check(houseOk or not has(houseReason, "restricted"), "service-zone buildings are allowed by the sandbox", houseReason)
        else
            r:check(not houseOk and has(houseReason, "restricted"), "a building in a KIPN service zone cannot be claimed", houseReason)
        end
    end
end

for _, tierId in ipairs(T.TIERS) do
    tests["land_check_" .. tierId] = function(player, r)
        local tier = S.CC.GetExcavationSizeTierById(tierId)
        local pos = position(player)
        local ok, reason, data = S.GC.ValidateExcavationTarget(player, pos, tier)
        if not ok then r:blocked("this land cannot be claimed: " .. tostring(reason)); return end
        r:pass("this land can be claimed")
        r:check(T.SameRect(data.rect, T.ExcavationRect(pos.x, pos.y, pos.z, tier.widthTiles, tier.heightTiles)),
            "the " .. tier.widthTiles .. "x" .. tier.heightTiles .. " area is centred on you")
        r:equal(data.targetId, pos.x .. "_" .. pos.y .. "_" .. pos.z, "anchor tile id")
    end

    tests["land_claim_" .. tierId] = function(player, r)
        local tier = S.CC.GetExcavationSizeTierById(tierId)
        local pos = position(player)
        local ok, reason = S.GC.ValidateExcavationTarget(player, pos, tier)
        if not ok then r:blocked("this land cannot be claimed: " .. tostring(reason)); return end
        if quotaFull(player, r, "excavation") then return end
        local _, record = issuePermit(player, r, tierId)
        if not record then return end
        local reply = callHandler(S.C.CLAIM_EXCAVATION, player, { targetX = pos.x, targetY = pos.y, targetZ = pos.z })
        if reply.handled == false then
            r:fail("the claim was refused: " .. tostring(reply.reason))
            r:info("the permit stays in your inventory for a retry through Claim Land")
            return
        end
        r:check(reply.first(S.E.EXCAVATION_CLAIM_SUCCESSFUL) ~= nil, "the server reports the claim as successful")
        local claim = S.CS.GetClaimForTarget("excavation", pos.x .. "_" .. pos.y .. "_" .. pos.z)
        if not r:check(claim ~= nil and tostring(claim.artifactId) == tostring(record.id), "the claim record uses the permit") then return end
        track(player, claim.id)
        r:equal(claim.sizeTierId, tierId, "claim size class")
        r:check(S.AS.GetArtifact(record.id).consumed == true, "the permit was consumed")
        r.clientCheck = { name = "land", data = { areas = { verifyLand(player, r, claim) } } }
    end
end

tests.land_rules = function(player, r)
    local pos = position(player)
    local function refused(args, fragment, label)
        local reply = callHandler(S.C.CLAIM_EXCAVATION, player, args)
        r:check(reply.handled == false and has(reply.reason, fragment), label, reply.reason)
    end
    refused({}, "target location must be selected", "a claim without a target is refused")
    refused({ targetX = pos.x, targetY = pos.y, targetZ = pos.z + 1 }, "current level", "a target on another floor is refused")
    refused({ targetX = pos.x + PLACEMENT_RANGE + 1, targetY = pos.y, targetZ = pos.z }, "too far away",
        "a target more than " .. PLACEMENT_RANGE .. " tiles away is refused")
    local noSize, noSizeReason = S.GC.ValidateExcavationTarget(player, pos, { id = "small" })
    r:check(noSize == false, "a size without dimensions is refused", noSizeReason)
    local tier = S.CC.GetExcavationSizeTierById("small")
    if insideBuilding(player) then
        local ok, reason = S.GC.ValidateExcavationTarget(player, pos, tier)
        r:check(not ok, "land inside a building cannot be claimed", reason)
    end
    local claim = latestClaim(player, "excavation")
    if claim then
        local anchor = { x = tonumber(claim.locationX), y = tonumber(claim.locationY), z = tonumber(claim.locationZ) }
        local same, sameReason = S.GC.ValidateExcavationTarget(player, anchor, tier)
        r:check(same == false and has(sameReason, "already claimed"), "an anchor tile cannot be claimed twice", sameReason)
        local near, nearReason = S.GC.ValidateExcavationTarget(player, { x = anchor.x + 1, y = anchor.y, z = anchor.z }, tier)
        r:check(near == false and has(nearReason, "overlaps"), "an overlapping claim is refused", nearReason)
    else
        r:skip("claim land first to test overlap rules")
    end
end

tests.land_verify = function(player, r)
    local claims = trackedClaims(player, "excavation")
    if #claims == 0 then r:skip("run Claim land here first"); return end
    local areas = {}
    for _, claim in ipairs(claims) do areas[#areas + 1] = verifyLand(player, r, claim) end
    r.clientCheck = { name = "land", data = { areas = areas } }
end

tests.land_quota = function(player, r)
    local max = tonumber(S.CC.GetServiceConfig("excavation").MaxClaimsPerPlayer) or 0
    if max <= 0 then r:skip("excavation claims are unlimited on this server"); return end
    local needed = max - countClaims(player, "excavation")
    if needed > 3 then r:skip("the limit of " .. max .. " is too high to fill in one test"); return end
    local tier = S.CC.GetExcavationSizeTierById("small")
    local origin, step, offset, created = position(player), tier.widthTiles + 2, 0, {}
    local function nextSpot()
        for _ = 1, 8 do
            offset = offset + 1
            local spot = { x = origin.x + offset * step, y = origin.y, z = origin.z }
            if S.GC.ValidateExcavationTarget(player, spot, tier) then return spot end
        end
    end
    for _ = 1, needed do
        local spot = nextSpot()
        if not spot then r:blocked("not enough open land east of you to fill the limit"); break end
        local item = issuePermit(player, r, "small")
        local ok, claim = S.GC.ClaimExcavation(player, spot, item, tier)
        if not r:check(ok == true, "filler claim created", claim) then break end
        created[#created + 1] = claim
        track(player, claim.id)
    end
    if countClaims(player, "excavation") >= max then
        local spot = nextSpot()
        local item = spot and issuePermit(player, r, "small")
        if item then
            local ok, why = S.GC.ClaimExcavation(player, spot, item, tier)
            r:check(ok == false and has(why, "maximum number"), "a claim over the limit of " .. max .. " is refused", why)
            discard(player, item)
        end
    end
    for _, claim in ipairs(created) do S.CS.ReleaseClaim(claim.id, "test_cleanup") end
    r:info("released the " .. #created .. " filler claim(s)")
end

tests.land_release = function(player, r)
    local claims = trackedClaims(player, "excavation")
    if #claims == 0 then r:skip("no test excavation claims to release"); return end
    for _, claim in ipairs(claims) do
        local reply = callHandler(S.C.RELEASE_CLAIM, player, { claimId = claim.id })
        local code, message = reply.errorCode()
        r:check(code == nil and S.CS.GetClaim(claim.id).active == false, "released excavation claim " .. tostring(claim.id), tostring(code) .. " " .. tostring(message))
        r:check(#responses(reply.sent, "KIPN_ExcavationAreas") > 0, "players receive the updated excavation areas")
    end
end

local function renewTarget(player)
    return latestClaim(player, "property") or latestClaim(player, "excavation")
end

tests.renew_desk = function(player, r)
    local claim = renewTarget(player)
    if not claim then r:skip("claim a building or land with this suite first"); return end
    local desk = deskContext(player, r)
    if not desk then return end
    local days = tonumber(S.CC.GetServiceConfig(claim.type).OwnershipExpiryDays) or 0
    local now = S.CS.GetWorldDays()
    local formType = RENEWAL_FORMS[claim.type]
    local form = give(player, formType, 1)[1]
    local formsBefore = #itemsOfType(player, formType)
    -- Age the claim so the reset is visible.
    local previous = claim.lastRenewedAtWorldDays
    claim.lastRenewedAtWorldDays = now - math.max(1, math.floor(days / 2))
    local reply = callHandler(S.C.RENEW_CLAIM, player, { claimId = claim.id, computerId = desk.id })
    if reply.handled == false then
        claim.lastRenewedAtWorldDays = previous
        discard(player, form)
        deskRefused(r, desk, reply.reason, "a renewal")
        return
    end
    r:check(desk.valid, "only a powered government computer renews claims")
    local renewed = reply.first(S.E.CLAIM_RENEWED)
    r:check(renewed ~= nil and renewed.data and tostring(renewed.data.claimId) == tostring(claim.id), "desk reports the claim as renewed")
    r:check(math.abs((tonumber(claim.lastRenewedAtWorldDays) or -1) - now) < 0.05, "ownership period restarts now",
        claim.lastRenewedAtWorldDays)
    r:check(not S.CS.IsClaimExpired(claim), "the claim is not expired")
    r:equal(#itemsOfType(player, formType), formsBefore - 1, "one " .. formType .. " was turned in")
    local row = listedRow(reply.sent, claim.id)
    if r:check(row ~= nil, "Property Records is refreshed") and days > 0 then
        r:check(math.floor((tonumber(row.expiryDaysRemaining) or -1) + 0.5) == days, "Property Records shows the full period again",
            row.expiryDaysRemaining)
    end
end

tests.renew_rules = function(player, r)
    local desk = deskContext(player, r)
    local computerId = desk and desk.id or "lilbubby-no-computer"
    local missing, missingReason = S.GA.RenewClaim(player, "lilbubby-no-claim", computerId)
    r:check(missing == false and has(missingReason, "no longer exists"), "an unknown claim cannot be renewed", missingReason)
    local mine = tostring(S.CS.GetPlayerSteamId(player))
    local foreign
    for _, claimType in ipairs({ "property", "excavation" }) do
        for _, claim in pairs(S.CS.GetClaims(claimType)) do
            if claim.active ~= false and tostring(claim.ownerSteamId) ~= mine then foreign = claim end
        end
    end
    if foreign then
        local ok, why = S.GA.RenewClaim(player, foreign.id, computerId)
        r:check(ok == false and has(why, "do not own"), "someone else's claim cannot be renewed", why)
    else
        r:skip("no other player's claim exists to test ownership")
    end
    local claim = renewTarget(player)
    if not claim then r:skip("claim a building or land with this suite first to test the rest"); return end
    local days = tonumber(S.CC.GetServiceConfig(claim.type).OwnershipExpiryDays) or 0
    if days > 0 then
        local previous = claim.lastRenewedAtWorldDays
        claim.lastRenewedAtWorldDays = S.CS.GetWorldDays() - days - 1
        local ok, why = S.GA.RenewClaim(player, claim.id, computerId)
        r:check(ok == false and has(why, "expired"), "an expired claim cannot be renewed", why)
        claim.lastRenewedAtWorldDays = previous
    end
    local noDesk, noDeskReason = S.GA.RenewClaim(player, claim.id, nil)
    r:check(noDesk == false and has(noDeskReason, "Computer"), "renewal without a computer is refused", noDeskReason)
    if not desk or not desk.valid then
        r:skip("stand at a powered government computer to test the form requirement")
        return
    end
    local formType = RENEWAL_FORMS[claim.type]
    if #itemsOfType(player, formType) > 0 then
        r:skip("drop your " .. formType .. " items to test renewal without a form")
        return
    end
    local otherForm = give(player, claim.type == "property" and EXCAVATION_FORM or PROPERTY_FORM, 1)[1]
    local ok, why = S.GA.RenewClaim(player, claim.id, desk.id)
    r:check(ok == false and has(why, "required to renew"), "the wrong Registration Form is not accepted", why)
    discard(player, otherForm)
end

tests.cleanup = function(player, r)
    local released = 0
    for _, claim in ipairs(trackedClaims(player)) do
        local ok, why = S.CS.ReleaseClaim(claim.id, "test_cleanup")
        if r:check(ok == true, "released test " .. claim.type .. " claim " .. tostring(claim.id), why) then released = released + 1 end
    end
    local removed = 0
    for _, item in ipairs(allItems(player)) do
        if item:getModData()[TAG] then
            discard(player, item)
            removed = removed + 1
        end
    end
    r:info("released " .. released .. " claim(s) and removed " .. removed .. " test item(s)")
    local objects, zones = LilBubbyDesk.Cleanup(player)
    r:info("removed " .. objects .. " test desk object(s) and deactivated " .. zones .. " test zone(s)")
    r:pass("cleanup finished")
end

tests.all_checks = function(player, r)
    for _, id in ipairs(T.AutomaticChecks) do
        local section = T.NewReport(T.CatalogById[id].label)
        local ok, err = pcall(tests[id], player, section)
        if not ok then section:fail("test errored: " .. tostring(err)) end
        r.lines[#r.lines + 1] = "-- " .. section.title .. " --"
        r:merge(section)
        if section.clientCheck then r.clientCheck = section.clientCheck end
    end
end

------------------------------------------------------------
-- DISPATCH
------------------------------------------------------------

function GovSvcTest.RunServer(player, id)
    local entry = T.CatalogById[id]
    local r = T.NewReport(entry and entry.label or tostring(id))
    if not entry or entry.side ~= "server" or not tests[id] then
        r:fail("unknown test")
        return r
    end
    local missing = bind()
    if missing then
        r:fail(missing)
        return r
    end
    local ok, err = pcall(tests[id], player, r)
    if not ok then r:fail("test errored: " .. tostring(err)) end
    return r
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= MODULE or command ~= "run" or not player or player:isDead() then return end
    if type(args) ~= "table" or type(args.id) ~= "string" then return end
    -- Requests are queued behind the previous one, never dropped.
    LilBubbyPacer.Run(player, MODULE, 100, function()
        local r = GovSvcTest.RunServer(player, args.id)
        print("[" .. MODULE .. "] " .. player:getUsername() .. " | " .. args.id .. " | " .. r:summary())
        sendServerCommand(player, MODULE, "result", { playerID = player:getOnlineID(), id = args.id, text = r:text(), clientCheck = r.clientCheck })
    end)
end)
