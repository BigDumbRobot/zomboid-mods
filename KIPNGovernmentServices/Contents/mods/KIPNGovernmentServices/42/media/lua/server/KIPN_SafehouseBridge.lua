-- KIPN_SafehouseBridge.lua
--
-- BUILD 42 SAFEHOUSE ENGINE ADAPTER
--
-- Server only: clients never mutate safehouses through this adapter; they
-- mirror the server's list via KIPN_SafehouseClientSync.lua.
--
-- KIPN owns property policy, quotas, lifecycle and persistence.
-- Vanilla SafeHouse objects are ONLY engine projections used by PZ protection
-- code and compatibility layers.
--
-- BUILD 42 API (JavaDocs):
--   SafeHouse.addSafeHouse(int x, int y, int w, int h, String player)
--   SafeHouse.removeSafeHouse(SafeHouse safeHouse)     -- STATIC
--   SafeHouse.getSafeHouse(int x, int y, int w, int h) -- STATIC
--
-- Do NOT gate Java methods with type(method) == "function".  Kahlua's Java
-- method exposure is not guaranteed to report a Lua "function" type even when
-- the method is callable.  Call documented Java methods directly inside pcall.
--
-- GEOMETRY:
-- Vanilla stores x/y/w/h. KIPN stores inclusive x1/y1/x2/y2.

if isClient() then return end

KIPN = KIPN or {}
KIPN.Bridges = KIPN.Bridges or {}
KIPN.Bridges.Safehouse = KIPN.Bridges.Safehouse or {}

local SafehouseBridge = KIPN.Bridges.Safehouse

-- No-entry buffer: every KIPN-managed engine projection is grown this many
-- tiles beyond the claimed building's own footprint on every side, so
-- vanilla's own SafehouseAllowTrepass=false protection keeps non-members
-- from getting close enough to touch (and thump/destroy) the claimed
-- structure's walls/doors.
local SAFEHOUSE_BUFFER_TILES = 2

local function log(message)
    print("[KIPN SAFEHOUSE BRIDGE] " .. tostring(message))
end

local function logError(message)
    print("[KIPN SAFEHOUSE BRIDGE] ERROR: " .. tostring(message))
end

local function readDimensions(safehouse)
    if not safehouse then return nil end

    local ok, x, y, w, h = pcall(function()
        return tonumber(safehouse:getX()),
            tonumber(safehouse:getY()),
            tonumber(safehouse:getW()),
            tonumber(safehouse:getH())
    end)

    if not ok or not x or not y or not w or not h or w < 1 or h < 1 then
        return nil
    end

    return x, y, w, h
end

function SafehouseBridge.GetId(safehouse)
    if not safehouse then return nil end
    local ok, value = pcall(function()
        return safehouse:getId()
    end)
    return ok and value ~= nil and tostring(value) ~= "" and tostring(value) or nil
end

function SafehouseBridge.GetOwner(safehouse)
    if not safehouse then return nil end
    local ok, owner = pcall(function()
        return safehouse:getOwner()
    end)
    return ok and owner ~= nil and tostring(owner) or nil
end

function SafehouseBridge.GetRect(safehouse)
    local x, y, w, h = readDimensions(safehouse)
    if not x then return nil end
    return {
        x1 = x,
        y1 = y,
        x2 = x + w - 1,
        y2 = y + h - 1,
        z = nil,
    }
end

function SafehouseBridge.GetProjectionRect(safehouse)
    local x, y, w, h = readDimensions(safehouse)
    if not x then return nil end
    return { x = x, y = y, w = w, h = h }
end

function SafehouseBridge.GetClaimRect(claim)
    if type(claim) ~= "table"
        or claim.rectX1 == nil or claim.rectY1 == nil
        or claim.rectX2 == nil or claim.rectY2 == nil
    then
        return nil
    end

    local x1 = tonumber(claim.rectX1)
    local y1 = tonumber(claim.rectY1)
    local x2 = tonumber(claim.rectX2)
    local y2 = tonumber(claim.rectY2)
    if not x1 or not y1 or not x2 or not y2 or x2 < x1 or y2 < y1 then
        return nil
    end

    return {
        x1 = x1 - SAFEHOUSE_BUFFER_TILES,
        y1 = y1 - SAFEHOUSE_BUFFER_TILES,
        x2 = x2 + SAFEHOUSE_BUFFER_TILES,
        y2 = y2 + SAFEHOUSE_BUFFER_TILES,
        z = nil,
    }
end

function SafehouseBridge.ProjectionRectFromClaim(claim)
    local rect = SafehouseBridge.GetClaimRect(claim)
    if not rect then return nil end
    return {
        x = rect.x1,
        y = rect.y1,
        w = rect.x2 - rect.x1 + 1,
        h = rect.y2 - rect.y1 + 1,
    }
end

function SafehouseBridge.RectanglesEqual(a, b)
    return a and b
        and tonumber(a.x1) == tonumber(b.x1)
        and tonumber(a.y1) == tonumber(b.y1)
        and tonumber(a.x2) == tonumber(b.x2)
        and tonumber(a.y2) == tonumber(b.y2)
        or false
end

local function getSafehouseList()
    if not SafeHouse then return nil, "SafeHouse class unavailable." end
    local ok, list = pcall(function()
        return SafeHouse.getSafehouseList()
    end)
    if not ok then return nil, tostring(list) end
    return list, nil
end

function SafehouseBridge.FindExactRect(rect)
    if type(rect) ~= "table" or not SafeHouse then return nil end

    local x = tonumber(rect.x)
    local y = tonumber(rect.y)
    local w = tonumber(rect.w)
    local h = tonumber(rect.h)
    if not x or not y or not w or not h or w < 1 or h < 1 then return nil end

    local ok, result = pcall(function()
        return SafeHouse.getSafeHouse(x, y, w, h)
    end)
    return ok and result or nil
end

function SafehouseBridge.FindForClaim(claim)
    if type(claim) ~= "table" then return nil end

    local expectedId = claim.safehouseId and tostring(claim.safehouseId) or nil
    local expectedRect = SafehouseBridge.GetClaimRect(claim)
    local list, err = getSafehouseList()
    if not list then
        logError("FindForClaim(): " .. tostring(err))
        return nil
    end

    local rectFallback = nil
    for i = 0, list:size() - 1 do
        local safehouse = list:get(i)
        local id = SafehouseBridge.GetId(safehouse)
        if expectedId and id and expectedId == id then
            return safehouse
        end
        if not rectFallback and expectedRect
            and SafehouseBridge.RectanglesEqual(expectedRect, SafehouseBridge.GetRect(safehouse))
        then
            rectFallback = safehouse
        end
    end

    return rectFallback
end

local function copyStringList(javaList)
    local out = {}
    if javaList then
        for i = 0, javaList:size() - 1 do
            local value = javaList:get(i)
            if value ~= nil then out[#out + 1] = tostring(value) end
        end
    end
    return out
end

function SafehouseBridge.Snapshot(safehouse)
    local rect = SafehouseBridge.GetProjectionRect(safehouse)
    local owner = SafehouseBridge.GetOwner(safehouse)
    if not rect or not owner then return nil end

    local snapshot = {
        rect = rect,
        safehouseId = SafehouseBridge.GetId(safehouse),
        owner = owner,
        title = nil,
        members = {},
        respawnMembers = {},
        hitPoints = nil,
        lastVisited = nil,
    }

    pcall(function() snapshot.title = safehouse:getTitle() end)
    pcall(function() snapshot.members = copyStringList(safehouse:getPlayers()) end)
    pcall(function() snapshot.respawnMembers = copyStringList(safehouse:getPlayersRespawn()) end)
    pcall(function() snapshot.hitPoints = safehouse:getHitPoints() end)
    pcall(function() snapshot.lastVisited = safehouse:getLastVisited() end)
    return snapshot
end

function SafehouseBridge.ConformFromSnapshot(safehouse, snapshot)
    if not safehouse or type(snapshot) ~= "table" then return false end

    local ok, err = pcall(function()
        if snapshot.owner then safehouse:setOwner(snapshot.owner) end
        if snapshot.title ~= nil then safehouse:setTitle(snapshot.title) end
        if snapshot.hitPoints ~= nil then safehouse:setHitPoints(snapshot.hitPoints) end
        if snapshot.lastVisited ~= nil then safehouse:setLastVisited(snapshot.lastVisited) end

        if type(snapshot.members) == "table" then
            local players = safehouse:getPlayers()
            if players then
                players:clear()
                for i = 1, #snapshot.members do players:add(snapshot.members[i]) end
            end
        end

        if type(snapshot.respawnMembers) == "table" then
            local respawn = safehouse:getPlayersRespawn()
            if respawn then
                respawn:clear()
                for i = 1, #snapshot.respawnMembers do respawn:add(snapshot.respawnMembers[i]) end
            end
        end
    end)

    if not ok then
        logError("ConformFromSnapshot() failed: " .. tostring(err))
        return false
    end
    return true
end

function SafehouseBridge.CreateProjection(claim)
    if type(claim) ~= "table" then return nil, "Invalid KIPN property claim." end
    if not SafeHouse then return nil, "SafeHouse class unavailable." end

    local rect = SafehouseBridge.ProjectionRectFromClaim(claim)
    local owner = claim.ownerUsername and tostring(claim.ownerUsername) or nil
    if not rect or not owner or owner == "" then
        return nil, "Claim is missing safehouse geometry or owner."
    end

    -- IMPORTANT: intentionally DO NOT call SafeHouse.hasSafehouse(),
    -- alreadyHaveSafehouse(), or allowSafeHouse(). Those are vanilla claim-policy
    -- gates and would reintroduce the one-safehouse-per-player behavior KIPN is
    -- replacing. KIPN's own quota was already checked before this adapter runs.

    local sameOwnerBefore = 0
    do
        local list = getSafehouseList()
        if list then
            for i = 0, list:size() - 1 do
                if SafehouseBridge.GetOwner(list:get(i)) == owner then
                    sameOwnerBefore = sameOwnerBefore + 1
                end
            end
        end
    end

    local ok, safehouseOrErr = pcall(function()
        return SafeHouse.addSafeHouse(rect.x, rect.y, rect.w, rect.h, owner)
    end)

    if not ok then
        return nil, tostring(safehouseOrErr)
    end

    local safehouse = safehouseOrErr
    if not safehouse then
        return nil, "SafeHouse.addSafeHouse() returned nil."
    end

    local actual = SafehouseBridge.GetProjectionRect(safehouse)
    if not actual
        or actual.x ~= rect.x or actual.y ~= rect.y
        or actual.w ~= rect.w or actual.h ~= rect.h
    then
        return nil, "SafeHouse.addSafeHouse() did not create the requested rectangle."
    end

    local ownerAfter = SafehouseBridge.GetOwner(safehouse)
    if ownerAfter ~= owner then
        return nil, "SafeHouse.addSafeHouse() returned a SafeHouse with the wrong owner."
    end

    local sameOwnerAfter = 0
    do
        local list = getSafehouseList()
        if list then
            for i = 0, list:size() - 1 do
                if SafehouseBridge.GetOwner(list:get(i)) == owner then
                    sameOwnerAfter = sameOwnerAfter + 1
                end
            end
        end
    end

    log("Created engine projection | claim=" .. tostring(claim.id)
        .. " | owner=" .. owner
        .. " | rect=" .. rect.x .. "," .. rect.y .. "," .. rect.w .. "," .. rect.h
        .. " | sameOwnerBefore=" .. tostring(sameOwnerBefore)
        .. " | sameOwnerAfter=" .. tostring(sameOwnerAfter))

    return safehouse, nil
end

function SafehouseBridge.RestoreSnapshot(snapshot)
    if type(snapshot) ~= "table" or type(snapshot.rect) ~= "table"
        or type(snapshot.owner) ~= "string"
    then
        return nil, "Invalid safehouse snapshot."
    end

    local existing = SafehouseBridge.FindExactRect(snapshot.rect)
    if existing then
        SafehouseBridge.ConformFromSnapshot(existing, snapshot)
        return existing, nil
    end

    if not SafeHouse then return nil, "SafeHouse class unavailable." end

    local rect = snapshot.rect
    local ok, safehouseOrErr = pcall(function()
        return SafeHouse.addSafeHouse(rect.x, rect.y, rect.w, rect.h, snapshot.owner)
    end)
    if not ok then return nil, tostring(safehouseOrErr) end
    if not safehouseOrErr then return nil, "Safehouse restore returned nil." end

    SafehouseBridge.ConformFromSnapshot(safehouseOrErr, snapshot)
    return safehouseOrErr, nil
end

function SafehouseBridge.RemoveAuthoritative(safehouse)
    if not safehouse then return false, "Safehouse unavailable." end
    if not SafeHouse then return false, "SafeHouse class unavailable." end

    local snapshot = SafehouseBridge.Snapshot(safehouse)
    local beforeId = SafehouseBridge.GetId(safehouse)
    local projection = SafehouseBridge.GetProjectionRect(safehouse)

    log("Calling documented static SafeHouse.removeSafeHouse(safehouse)"
        .. " | id=" .. tostring(beforeId)
        .. " | rect=" .. tostring(projection and projection.x) .. ","
        .. tostring(projection and projection.y) .. ","
        .. tostring(projection and projection.w) .. ","
        .. tostring(projection and projection.h))

    -- Build 42 JavaDocs: public static void removeSafeHouse(SafeHouse safeHouse)
    -- Deliberately use a closure rather than pcall(SafeHouse.removeSafeHouse, ...)
    -- so Kahlua does not need to expose the Java method as a first-class Lua
    -- function value.
    local ok, err = pcall(function()
        SafeHouse.removeSafeHouse(safehouse)
    end)
    if not ok then
        logError("Static remove threw: " .. tostring(err))
        return false, tostring(err)
    end

    -- Verify by identity/id/rectangle against the authoritative list.
    local list, listErr = getSafehouseList()
    if not list then
        return false, "Unable to verify safehouse removal: " .. tostring(listErr)
    end

    for i = 0, list:size() - 1 do
        local candidate = list:get(i)
        if candidate == safehouse then
            return false, "Safehouse object remained in authoritative list after removal."
        end

        local candidateId = SafehouseBridge.GetId(candidate)
        if beforeId and candidateId and beforeId == candidateId then
            return false, "Safehouse ID remained in authoritative list after removal."
        end

        if projection then
            local candidateRect = SafehouseBridge.GetProjectionRect(candidate)
            if candidateRect
                and candidateRect.x == projection.x and candidateRect.y == projection.y
                and candidateRect.w == projection.w and candidateRect.h == projection.h
            then
                return false, "Safehouse rectangle remained in authoritative list after removal."
            end
        end
    end

    log("Authoritative static SafeHouse removal verified.")
    return true, snapshot
end

function SafehouseBridge.EnsureClaimProjection(claim)
    if type(claim) ~= "table" then return nil, "Invalid KIPN property claim." end

    local expectedRect = SafehouseBridge.GetClaimRect(claim)
    local expectedOwner = claim.ownerUsername and tostring(claim.ownerUsername) or nil
    if not expectedRect or not expectedOwner then
        return nil, "Claim geometry/owner unavailable."
    end

    local existing = SafehouseBridge.FindForClaim(claim)
    if existing then
        local sameRect = SafehouseBridge.RectanglesEqual(
            SafehouseBridge.GetRect(existing), expectedRect
        )
        local sameOwner = SafehouseBridge.GetOwner(existing) == expectedOwner
        if sameRect and sameOwner then
            return existing, nil
        end

        -- If this is the same stored SafeHouse ID, KIPN owns the projection and
        -- repairs external vanilla edits by replacing it from KIPN state.
        local existingId = SafehouseBridge.GetId(existing)
        if claim.safehouseId and existingId
            and tostring(claim.safehouseId) == tostring(existingId)
        then
            -- Rebuild at the claim's buffered footprint, keeping the
            -- members, respawn list, title and hit points.
            local snapshot = SafehouseBridge.Snapshot(existing)
            local removed, why = SafehouseBridge.RemoveAuthoritative(existing)
            if not removed then
                return nil, "Unable to repair changed KIPN safehouse: " .. tostring(why)
            end
            local rebuilt, reason = SafehouseBridge.CreateProjection(claim)
            if not rebuilt then
                if snapshot then SafehouseBridge.RestoreSnapshot(snapshot) end
                return nil, reason
            end
            if snapshot then
                snapshot.owner = expectedOwner
                SafehouseBridge.ConformFromSnapshot(rebuilt, snapshot)
            end
            return rebuilt, nil
        else
            return nil, "A different vanilla safehouse conflicts with this KIPN property rectangle."
        end
    end

    -- Exact-rectangle conflict that wasn't associated by ID.
    local projection = SafehouseBridge.ProjectionRectFromClaim(claim)
    local exact = SafehouseBridge.FindExactRect(projection)
    if exact then
        if SafehouseBridge.GetOwner(exact) == expectedOwner then
            return exact, nil
        end
        return nil, "A vanilla safehouse owned by another player occupies this KIPN property rectangle."
    end

    return SafehouseBridge.CreateProjection(claim)
end

log("Build 42 static SafeHouse adapter loaded.")
