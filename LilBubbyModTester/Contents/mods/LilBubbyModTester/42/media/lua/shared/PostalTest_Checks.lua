PostalTest = PostalTest or {}

-- Checks of the loaded Post Office services for the authenticated player.
-- No service, permission, persistence, or command-handler globals are replaced.
--   Boxes   the physical boxes of the post office the player stands in
--           (run by the guided test when the boxes have been placed)
--   Keys    the player's rentals, held keys and lock access
--           (run by the guided test when a box has been rented)
--   Guards  requests the services must refuse, and the registered handlers
--           (its own entry in the suite)
local function report()
    local r = { lines = {}, counts = { PASS = 0, FAIL = 0, BLOCKED = 0, ERROR = 0 } }
    function r:add(status, label)
        self.counts[status] = self.counts[status] + 1
        self.lines[#self.lines + 1] = status .. ": " .. label
    end
    function r:check(label, ok)
        self:add(ok and "PASS" or "FAIL", label)
        return ok
    end
    function r:finish()
        return string.format("Postal functional tests: %d PASS, %d FAIL, %d BLOCKED, %d ERROR\n",
            self.counts.PASS, self.counts.FAIL, self.counts.BLOCKED, self.counts.ERROR)
            .. table.concat(self.lines, "\n")
    end
    return r
end
PostalTest.Report = report

local function need(r, value, label)
    if value == nil then r:add("ERROR", label .. " unavailable in the running KIPN framework."); return false end
    return true
end

local function services(r)
    local s = KIPN and KIPN.Server
    if not need(r, s, "KIPN.Server") then return end
    if not need(r, s.POBoxService, "POBoxService") or not need(r, s.MarketplaceService, "MarketplaceService") then return end
    return s
end

local function claimType(s)
    return s.ClaimService.Types and s.ClaimService.Types.PO_BOX or "po_box"
end

-- The player's active box rentals.
function PostalTest.Claims(s, player)
    local result = {}
    for _, claim in pairs(s.ClaimService.GetPlayerClaims(player) or {}) do
        if claim.type == claimType(s) and claim.active ~= false then result[#result + 1] = claim end
    end
    return result
end

-- Every box key the player carries: { item, boxId }.
function PostalTest.HeldKeys(s, player)
    local finder = (s.POBoxClaimService and s.POBoxClaimService.FindPlayerPOBoxKeyItems)
        or (s.ArtifactService and s.ArtifactService.FindPlayerPOBoxKeyItems)
    return finder and finder(player) or {}
end

function PostalTest.Handler(s, name)
    local command = KIPN.Shared and KIPN.Shared.Commands and KIPN.Shared.Commands[name]
    if not command then return nil end
    if type(s.GetCommandHandler) == "function" then return s.GetCommandHandler(command) end
    return s.CommandHandlers and s.CommandHandlers[command]
end

function PostalTest.Boxes(r, player, s)
    local boxes = s.POBoxService
    local zone, zoneId = boxes.GetPlayerPostOffice(player)
    if not zone then r:add("BLOCKED", "Enter a configured post office to test its physical boxes."); return end
    local entries = boxes.GetBoxesForZone(zoneId)
    if #entries == 0 then r:add("BLOCKED", "This post office has no registered boxes; an admin must create one."); return end
    local numbers, keys = {}, {}
    for index, entry in ipairs(entries) do
        if index > 20 then r:add("BLOCKED", "Only the first 20 boxes checked in this run."); break end
        local label = "Box #" .. tostring(entry.number)
        r:check(label .. " registry and zone-number lookups agree",
            boxes.GetBox(entry.id) == entry and boxes.GetBoxAtZoneNumber(zoneId, entry.number) == entry)
        r:check(label .. " has a unique positive number and lock ID in this zone",
            tonumber(entry.number) ~= nil and tonumber(entry.number) > 0 and not numbers[entry.number]
            and tonumber(entry.keyId) ~= nil and not keys[entry.keyId])
        numbers[entry.number], keys[entry.keyId] = true, true
        local price, capacity = boxes.GetPrice(entry), boxes.GetCapacity(entry)
        r:check(label .. " configured price/capacity are usable", price ~= nil and price >= 0 and capacity ~= nil and capacity > 0)
        local object = boxes.FindWorldObject(entry)
        if not object then
            r:add("BLOCKED", label .. " world container is absent or its square is not loaded; move closer.")
        else
            local container, md = object:getContainer(), object:getModData()
            r:check(label .. " physical capacity matches configuration", container ~= nil and container:getCapacity() == capacity)
            r:check(label .. " physical key ID matches registry", object:getKeyId() == tonumber(entry.keyId))
            r:check(label .. " permanent keyed lock is enabled", object:isLockedByPadlock())
            r:check(label .. " movement protection and identity are present",
                md.KIPNProtectedMoveable == true and tostring(md.KIPNPOBoxRegistryId) == tostring(entry.id))
            local resolved, reason = boxes.ResolvePurchasableBox(player, entry.number)
            r:check(label .. " purchase resolution finds the physical box (" .. tostring(reason or "OK") .. ")", resolved == entry)
        end
    end
    local nextNumber = boxes.GetNextBoxNumber(zoneId)
    local maximum = 0
    for _, entry in ipairs(entries) do maximum = math.max(maximum, tonumber(entry.number) or 0) end
    r:check("Next box number exceeds existing numbers", nextNumber ~= nil and nextNumber > maximum)
end

function PostalTest.Keys(r, player, s)
    local boxes, market = s.POBoxService, s.MarketplaceService
    local claims = PostalTest.Claims(s, player)
    r:check("Delivery eligibility matches active PO Box ownership",
        market.CanPlayerReceiveMarketplaceDelivery(player) == (#claims > 0))
    local keys = PostalTest.HeldKeys(s, player)
    if #claims == 0 then r:add("BLOCKED", "Rent a PO Box through Postal Services to test ownership and held keys.") end
    for _, claim in ipairs(claims) do
        local entry = boxes.GetBox(claim.targetId)
        if r:check("Owned box " .. tostring(claim.targetId) .. " exists in registry", entry ~= nil) then
            local found = false
            for _, key in ipairs(keys) do
                if tostring(key.boxId) == tostring(entry.id) then
                    found = true
                    local item = key.item
                    local md = item and item:getModData()
                    r:check("Held key for box #" .. tostring(entry.number) .. " matches physical lock and claim serial", item ~= nil
                        and item:getKeyId() == tonumber(entry.keyId) and md ~= nil
                        and (tostring(md.KIPNPOBoxKeySerial) == tostring(claim.poBoxKeySerial)
                            or (type(claim.poBoxKeySerials) == "table" and claim.poBoxKeySerials[tostring(md.KIPNPOBoxKeySerial)] == true)))
                    local object = boxes.FindWorldObject(entry)
                    if object then
                        r:check("Engine allows this character to unlock box #" .. tostring(entry.number), not object:isLockedToCharacter(player))
                    else r:add("BLOCKED", "Move near owned box #" .. tostring(entry.number) .. " to test engine lock access.") end
                end
            end
            if not found then r:add("BLOCKED", "Carry the key for box #" .. tostring(entry.number) .. " (backpacks are supported).") end
        end
    end
end

local function itemCount(player)
    local ok, count = pcall(function() return player:getInventory():getItems():size() end)
    return ok and count or -1
end

-- Requests the services must refuse. Every one is refused before anything is
-- changed: no request here is valid enough to create, release, queue or grant.
function PostalTest.Guards(r, player, s)
    local boxes, market = s.POBoxService, s.MarketplaceService
    local username = player:getUsername()
    for _, name in ipairs({ "GET_PO_BOXES", "BUY_PO_BOX", "GET_PARCELS", "COLLECT_PARCEL" }) do
        r:check("A " .. name .. " command handler is registered", type(PostalTest.Handler(s, name)) == "function")
    end

    -- Purchase: box numbers that cannot exist.
    if need(r, s.POBoxClaimService and s.POBoxClaimService.ValidatePOBoxTarget, "POBoxClaimService.ValidatePOBoxTarget") then
        local accepted = {}
        for _, number in ipairs({ 0, -1, 1.5, 1000000, "abc" }) do
            if s.POBoxClaimService.ValidatePOBoxTarget(player, number) then accepted[#accepted + 1] = tostring(number) end
        end
        r:check("Purchase validation refuses box numbers 0, -1, 1.5, 1000000 and text"
            .. (#accepted > 0 and " (accepted: " .. table.concat(accepted, ", ") .. ")" or ""), #accepted == 0)
    end

    -- Create and delete: admin commands.
    local x, y, z = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    local okLevel, level = pcall(function() return s.Permissions.ResolveAccessLevel(player) end)
    local function refused(label, expected, entry, reason)
        r:check(label .. " (" .. tostring(reason) .. ")", not entry and reason == expected)
    end
    if okLevel and level == "ADMIN" then
        refused("Admin: creating a box with no square is refused", "INVALID_SQUARE", boxes.CreateBox(player, { size = "small" }))
        refused("Admin: creating a box of an unknown size is refused", "INVALID_SIZE", boxes.CreateBox(player, { x = x, y = y, z = z, size = "huge" }))
        refused("Admin: creating a box 500 tiles away is refused", "TARGET_TOO_FAR", boxes.CreateBox(player, { x = x + 500, y = y, z = z, size = "small" }))
        refused("Admin: removing a box that does not exist is refused", "PO_BOX_NOT_FOUND", boxes.DeleteBox(player, { boxId = "LilBubbyPostalTest:none" }))
    else
        refused("A player who is not an admin cannot create a box", "NOT_AUTHORIZED", boxes.CreateBox(player, { x = x, y = y, z = z, size = "small" }))
        refused("A player who is not an admin cannot remove a box", "NOT_AUTHORIZED", boxes.DeleteBox(player, { boxId = "LilBubbyPostalTest:none" }))
    end

    -- Key release: only a key that is really gone releases a box.
    local released, reason = boxes.ReleaseForRemovedKey(player, {})
    r:check("A key-removal report without a key identity is refused (" .. tostring(reason) .. ")", released == false and reason == "INVALID_KEY_IDENTITY")
    local claims = PostalTest.Claims(s, player)
    local held
    for _, key in ipairs(PostalTest.HeldKeys(s, player)) do
        for _, claim in ipairs(claims) do
            local serial = key.item:getModData().KIPNPOBoxKeySerial
            if tostring(key.boxId) == tostring(claim.targetId) and serial then held = { claim = claim, serial = tostring(serial) } end
        end
    end
    if not held then
        r:add("BLOCKED", "Rent a PO Box and carry its key to test the key-removal guards.")
    else
        local boxId = tostring(held.claim.targetId)
        released, reason = boxes.ReleaseForRemovedKey(player, { boxId = boxId, keySerial = "LilBubbyPostalTest:wrong" })
        r:check("A key-removal report with the wrong serial is refused (" .. tostring(reason) .. ")", released == false and reason == "KEY_IDENTITY_MISMATCH")
        local claim = s.ClaimService.GetClaimForTarget(claimType(s), held.claim.targetId)
        r:check("Your box is still yours after the refused report", claim ~= nil and claim.active ~= false and tostring(claim.id) == tostring(held.claim.id))
    end

    -- Parcel intake: malformed deliveries.
    local function intake(label, expected, parcel, why)
        r:check(label .. " (" .. tostring(why) .. ")", not parcel and why == expected)
    end
    local data = ModData.getOrCreate("KIPN_MarketplaceParcels")
    local function queued() return #(data.parcelsByOwner and data.parcelsByOwner[username] or {}) end
    local parcelsBefore, itemsBefore = queued(), itemCount(player)
    intake("A system parcel without a recipient or delivery is refused", "INVALID_DELIVERY", market.QueueSystemParcel(nil, nil))
    intake("A system parcel for a blank recipient is refused", "INVALID_RECIPIENT", market.QueueSystemParcel({ username = "  " }, {}))
    local recipient = { username = username }
    if market.CanPlayerReceiveMarketplaceDelivery(player) then
        intake("A system parcel without an order ID is refused", "INVALID_SYSTEM_ORDER_ID",
            market.QueueSystemParcel(recipient, { itemFullType = "Base.Paper" }))
        intake("A system parcel without an item is refused", "INVALID_ITEM",
            market.QueueSystemParcel(recipient, { systemOrderId = "LilBubbyPostalTest:guard" }))
        for _, quantity in ipairs({ 0, 101 }) do
            intake("A system parcel of " .. quantity .. " items is refused", "INVALID_QUANTITY",
                market.QueueSystemParcel(recipient, { systemOrderId = "LilBubbyPostalTest:guard", itemFullType = "Base.Paper", quantity = quantity }))
        end
        intake("An external delivery without a provider is refused", "INVALID_PROVIDER", market.QueueExternalDelivery("", player, {}))
        intake("An external delivery from an unknown provider is refused", "PROVIDER_NOT_SUPPORTED",
            market.QueueExternalDelivery("LilBubbyNoSuchProvider", player, {}))
    else
        -- The quantity is invalid as well, so nothing is queued even if the box rule fails.
        intake("A system parcel for a player without a PO Box is refused", "PO_BOX_REQUIRED",
            market.QueueSystemParcel(recipient, { systemOrderId = "LilBubbyPostalTest:guard", itemFullType = "Base.Paper", quantity = 0 }))
        intake("An external delivery for a player without a PO Box is refused", "PO_BOX_REQUIRED", market.QueueExternalDelivery("", player, {}))
    end

    -- Collection: parcels that do not exist.
    local collect = PostalTest.Handler(s, "COLLECT_PARCEL")
    if type(collect) == "function" then
        collect(player, {})
        collect(player, { parcelId = -1 })
    end
    r:check("No parcel was queued and nothing was granted by the refused requests",
        queued() == parcelsBefore and itemCount(player) == itemsBefore)
end

function PostalTest.Run(player, suite)
    local r = report()
    if not player or player:isDead() then r:add("BLOCKED", "A living player is required."); return r:finish() end
    local s = services(r)
    if not s then return r:finish() end
    suite = suite or "guards"
    local tests = { guards = PostalTest.Guards }
    local fn = tests[suite]
    if not fn then r:add("ERROR", "Unknown postal suite."); return r:finish() end
    local ok, err = pcall(fn, r, player, s)
    if not ok then r:add("ERROR", suite .. ": " .. tostring(err)) end
    return r:finish()
end
