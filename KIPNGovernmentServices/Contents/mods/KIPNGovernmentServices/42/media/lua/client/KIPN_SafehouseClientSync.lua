-- KIPN_SafehouseClientSync.lua
--
-- Explicit client projection of the server's authoritative vanilla SafeHouse
-- list.  This follows the same proven pattern as LG Extended Safehouses:
-- remove only explicitly named rectangles, then ensure explicitly named
-- rectangles exist and carry the server's owner/title/member state.

if isServer() and not isClient() then return end

require "KIPN_Shared"

local function log(message)
    print("[KIPN SAFEHOUSE CLIENT SYNC] " .. tostring(message))
end

local function readRect(rect)
    if type(rect) ~= "table" then return nil end
    local x, y = tonumber(rect.x), tonumber(rect.y)
    local w, h = tonumber(rect.w), tonumber(rect.h)
    if not x or not y or not w or not h or w < 1 or h < 1 then return nil end
    return math.floor(x), math.floor(y), math.floor(w), math.floor(h)
end

local function exactSafehouse(rect)
    local x, y, w, h = readRect(rect)
    if not x or not SafeHouse then return nil end
    local ok, result = pcall(function()
        return SafeHouse.getSafeHouse(x, y, w, h)
    end)
    return ok and result or nil
end

local function conform(piece, owner, title, members)
    if not piece then return end

    local ok, err = pcall(function()
        -- Build 42 setOwner removes the owner from getPlayers(), so owner first.
        if type(owner) == "string" then
            piece:setOwner(owner)
        end
        if title ~= nil then
            piece:setTitle(title)
        end
        if type(members) == "table" then
            local list = piece:getPlayers()
            list:clear()
            for i = 1, #members do
                if type(members[i]) == "string" then list:add(members[i]) end
            end
        end
    end)

    if not ok then
        print("[KIPN SAFEHOUSE CLIENT SYNC] ERROR: conform failed: " .. tostring(err))
    end
end

local function applySync(args)
    if type(args) ~= "table" then return end
    local touched = false

    -- Deletions first. A client deletes NOTHING it was not explicitly named.
    if type(args.removed) == "table" then
        for i = 1, #args.removed do
            local piece = exactSafehouse(args.removed[i])
            if piece and SafeHouse then
                local ok, err = pcall(function()
                    SafeHouse.removeSafeHouse(piece)
                end)
                if ok then
                    touched = true
                else
                    print("[KIPN SAFEHOUSE CLIENT SYNC] ERROR: remove failed: " .. tostring(err))
                end
            end
        end
    end

    if type(args.pieces) == "table" then
        for i = 1, #args.pieces do
            local rect = args.pieces[i]
            local x, y, w, h = readRect(rect)
            if x then
                local piece = exactSafehouse(rect)
                if not piece and type(args.owner) == "string"
                    and SafeHouse
                then
                    local ok, result = pcall(function()
                        return SafeHouse.addSafeHouse(x, y, w, h, args.owner)
                    end)
                    if ok then piece = result end
                    if piece then touched = true end
                end
                if piece then conform(piece, args.owner, args.title, args.members) end
            end
        end
    end

    -- add/remove raise OnSafehousesChanged themselves. Metadata-only sync does not.
    if not touched then triggerEvent("OnSafehousesChanged") end
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "KIPN" then return end
    local wanted = KIPN.Shared and KIPN.Shared.Commands
        and KIPN.Shared.Commands.SAFEHOUSE_PROJECTION_SYNC
        or "safehouseProjectionSync"
    if command ~= wanted then return end
    applySync(args)
end)

log("Explicit SafeHouse projection sync loaded.")
