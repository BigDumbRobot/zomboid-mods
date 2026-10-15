-- KIPN_ZoneAdminTrigger.lua
--
-- Adds a "KIPN: Zone Admin Tool" entry to the world right-click
-- context menu, visible only to admins, which opens/closes the
-- KIPN_ZoneAdminUI panel.
--
-- NOTE ON TRIGGER CHOICE:
-- This is a context-menu entry rather than a hotkey or slash
-- command because it's the most reliable, well-established way
-- to gate a Lua-side action behind admin status without needing
-- a custom keybinding registration. If you'd prefer a keybind or
-- a dedicated button elsewhere in your KIPN UI, this file is the
-- only one that needs to change — KIPN_ZoneAdminUI.Toggle() is
-- the entry point either way.
--
-- ADMIN CHECK: KIPN_AdminAccess uses the server-resolved KIPN level,
-- including KIPN.AdminSteamIDs, with native PZ admin state only as an
-- immediate presentation hint while that response is pending.

require "ISUI/ISWorldObjectContextMenu"
require "KIPN_AdminAccess"
require "KIPN_ZoneAdminUI"

local PO_BOX_MODULE = "KIPN_POBoxAdmin"

local REASON_LABELS = {
    NOT_AUTHORIZED = "Admin access is required.",
    INVALID_SQUARE = "The selected square is invalid.",
    INVALID_SIZE = "The selected PO Box size is invalid.",
    TARGET_TOO_FAR = "Move within 10 tiles of the target square.",
    POST_OFFICE_ZONE_REQUIRED = "PO Boxes can only be spawned inside a Post Office Zone.",
    BOX_NUMBER_ALREADY_REGISTERED = "That box number already exists at this post office.",
    SQUARE_ALREADY_HAS_PO_BOX = "That square already contains a registered PO Box.",
    SQUARE_NOT_LOADED = "The selected square is not loaded on the server.",
    PO_BOX_IS_OWNED = "Owned PO Boxes cannot be removed.",
    PO_BOX_NOT_EMPTY = "Empty the PO Box before removing it.",
    PO_BOX_NOT_FOUND = "The registered PO Box was not found.",
    REGISTRY_SAVE_FAILED = "The PO Box registry could not be saved.",
    BOX_NUMBER_LIMIT_REACHED = "This post office has reached its PO Box numbering limit.",
}

local function hasZoneAdminAccess(playerNum)
    return KIPN.Client.AdminAccess.IsAdmin(playerNum)
end

local function getSelectedSquare(worldobjects, playerNum)
    for _, object in ipairs(worldobjects or {}) do
        if object and type(object.getSquare) == "function" then
            local square = object:getSquare()
            if square then return square end
        end
    end

    local player = getSpecificPlayer(playerNum)
    return player and player:getSquare() or nil
end

local function getPOBoxObject(worldobjects)
    for _, object in ipairs(worldobjects or {}) do
        if object and type(object.getModData) == "function" then
            local modData = object:getModData()
            if modData and modData.KIPNPOBoxRegistryId then
                return object, tostring(modData.KIPNPOBoxRegistryId)
            end
        end
    end

    return nil, nil
end

local function requestCreatePOBox(_target, playerNum, square, sizeKey)
    local player = getSpecificPlayer(playerNum)

    if not player or not square then return end

    sendClientCommand(player, PO_BOX_MODULE, "CreateBox", {
        x = square:getX(),
        y = square:getY(),
        z = square:getZ(),
        size = sizeKey,
    })
end

local function isPlayerInsidePostOfficeZone(playerNum)
    local player = getSpecificPlayer(playerNum)
    local square = player and player:getSquare()
    local cache = KIPN
        and KIPN.Client
        and KIPN.Client.ZoneMapCache

    if not square or not cache or type(cache.zones) ~= "table" then
        return false
    end

    local x = square:getX()
    local y = square:getY()
    local z = square:getZ()

    for _, zone in ipairs(cache.zones) do
        local geometry = type(zone) == "table" and zone.geometry

        if zone.type == "post_office"
            and zone.active ~= false
            and type(geometry) == "table"
        then
            local x1 = tonumber(geometry.x1)
            local y1 = tonumber(geometry.y1)
            local x2 = tonumber(geometry.x2)
            local y2 = tonumber(geometry.y2)
            local z1 = tonumber(geometry.z1) or 0
            local z2 = tonumber(geometry.z2) or z1

            if x1 and y1 and x2 and y2
                and x >= math.min(x1, x2)
                and x <= math.max(x1, x2)
                and y >= math.min(y1, y2)
                and y <= math.max(y1, y2)
                and z >= math.min(z1, z2)
                and z <= math.max(z1, z2)
            then
                return true
            end
        end
    end

    return false
end

local function requestDeletePOBox(_target, playerNum, boxId)
    local player = getSpecificPlayer(playerNum)
    if not player then return end

    sendClientCommand(player, PO_BOX_MODULE, "DeleteBox", {
        boxId = boxId,
    })
end

local function onFillWorldObjectContextMenu(playerNum, context, worldobjects, test)
    if test then return end

    if not hasZoneAdminAccess(playerNum) then
        return
    end

    context:addOption("KIPN: Zone Admin Tool", nil, function()
        KIPN_ZoneAdminUI.Toggle()
    end)

    local square = getSelectedSquare(worldobjects, playerNum)

    if square and isPlayerInsidePostOfficeZone(playerNum) then
        local spawnOption = context:addOption("KIPN: Spawn PO Box")
        local spawnMenu = ISContextMenu:getNew(context)
        context:addSubMenu(spawnOption, spawnMenu)

        spawnMenu:addOption("Small PO Box", nil, requestCreatePOBox, playerNum, square, "small")
        spawnMenu:addOption("Medium PO Box", nil, requestCreatePOBox, playerNum, square, "medium")
        spawnMenu:addOption("Large PO Box", nil, requestCreatePOBox, playerNum, square, "large")
    end

    local _boxObject, boxId = getPOBoxObject(worldobjects)
    if boxId then
        context:addOption(
            "KIPN: Remove PO Box",
            nil,
            requestDeletePOBox,
            playerNum,
            boxId
        )
    end
end

Events.OnFillWorldObjectContextMenu.Add(onFillWorldObjectContextMenu)

local function onServerCommand(module, command, args)
    if module ~= PO_BOX_MODULE then return end

    if command ~= "CreateBoxResult" and command ~= "DeleteBoxResult" then
        return
    end

    local player = getSpecificPlayer(0)
    if not player then return end

    local message
    if args and args.success then
        if command == "CreateBoxResult" then
            message = "Created " .. tostring(args.size) .. " PO Box #"
                .. tostring(args.boxNumber) .. "."
        else
            message = "PO Box removed."
        end
    else
        local reason = args and args.reason
        message = REASON_LABELS[reason] or tostring(reason or "PO Box request failed.")
    end

    player:setHaloNote(message)
end

Events.OnServerCommand.Add(onServerCommand)

print("[KIPN] Zone Admin trigger loaded")
