-- KIPN_OwnershipClaimMenu.lua
--
-- Keeps a caller-scoped cache of the local player's area claims and
-- exposes ownership details from the world context menu. Property
-- claims open the vanilla ISSafehouseUI. Excavation claims use a
-- compact read-only details dialog because they are KIPN records,
-- not vanilla SafeHouse objects.

if isServer() then
    return
end

require "KIPN_UI"
require "ISUI/ISWorldObjectContextMenu"
require "ISUI/UserPanel/ISSafehouseUI"

local ownedAreaClaims = {}

--------------------------------------------------------------------
-- SYNCHRONIZATION
--------------------------------------------------------------------

local function requestOwnershipData()

    if not KIPN
        or not KIPN.Shared
        or not KIPN.Shared.Commands
    then
        return
    end

    sendClientCommand(
        "KIPN",
        KIPN.Shared.Commands.GET_MY_CLAIMS,
        {}
    )

    -- Safehouses are created server-side. Ask for the projections so
    -- KIPN_SafehouseClientSync mirrors them locally for ISSafehouseUI
    -- and the vanilla context menu after reconnecting.
    sendClientCommand(
        "KIPN",
        "RequestSafehouseSync",
        {}
    )

end

local function onServerResponse(module, command, args)

    if module ~= "KIPN"
        or not KIPN.Shared
        or not KIPN.Shared.Commands
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
        or type(args) ~= "table"
    then
        return
    end

    local event = args.event
    local data = args.data

    if event == KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA then

        ownedAreaClaims = {}

        if type(data) == "table" then

            for _, claim in ipairs(data) do

                if type(claim) == "table"
                    and (
                        claim.type == "property"
                        or claim.type == "excavation"
                    )
                then
                    ownedAreaClaims[#ownedAreaClaims + 1] = claim
                end

            end

        end

        return
    end

    if event == KIPN.Shared.ResponseEvents.PROPERTY_CLAIM_SUCCESSFUL
        or event
            == KIPN.Shared.ResponseEvents.EXCAVATION_CLAIM_SUCCESSFUL
    then
        requestOwnershipData()
    end

end

--------------------------------------------------------------------
-- CLAIM LOOKUP
--------------------------------------------------------------------

local function getClickedSquare(worldobjects)

    for _, object in ipairs(worldobjects or {}) do

        if object
            and type(object.getSquare) == "function"
        then

            local square =
                object:getSquare()

            if square then
                return square
            end

        end

    end

    return nil

end

local function findOwnedClaimAt(square)

    if not square then
        return nil
    end

    local x = square:getX()
    local y = square:getY()
    local z = square:getZ()

    for _, claim in ipairs(ownedAreaClaims) do

        local x1 = tonumber(claim.rectX1)
        local y1 = tonumber(claim.rectY1)
        local x2 = tonumber(claim.rectX2)
        local y2 = tonumber(claim.rectY2)
        local claimZ = tonumber(claim.locationZ) or 0

        if x1 and y1 and x2 and y2
            and claimZ == z
            and x >= x1 and x <= x2
            and y >= y1 and y <= y2
        then
            return claim
        end

    end

    return nil

end

local function findSafehouseAtSquare(square)

    if not square then
        return nil
    end

    local list =
        SafeHouse.getSafehouseList()

    local x = square:getX()
    local y = square:getY()

    for i = 0, list:size() - 1 do

        local safehouse =
            list:get(i)

        if x >= safehouse:getX()
            and x <= safehouse:getX2()
            and y >= safehouse:getY()
            and y <= safehouse:getY2()
        then
            return safehouse
        end

    end

    return nil

end

--------------------------------------------------------------------
-- VIEW ACTIONS
--------------------------------------------------------------------

local function openSafehouse(safehouse, player)

    if not safehouse or not player then
        return
    end

    local width =
        500 + getCore():getOptionFontSizeReal() * 30

    local ui =
        ISSafehouseUI:new(
            (getCore():getScreenWidth() - width) / 2,
            getCore():getScreenHeight() / 2 - 225,
            width,
            450,
            safehouse,
            player
        )

    ui:initialise()
    ui:addToUIManager()

end

local function openExcavationDetails(claim)

    if not claim then
        return
    end

    local width =
        tonumber(claim.sizeWidthTiles)
        or (
            tonumber(claim.rectX2)
            - tonumber(claim.rectX1)
            + 1
        )

    local height =
        tonumber(claim.sizeHeightTiles)
        or (
            tonumber(claim.rectY2)
            - tonumber(claim.rectY1)
            + 1
        )

    local message =
        "EXCAVATION SITE\n\n"
        .. "Owner: " .. tostring(claim.owner or "Unknown") .. "\n"
        .. "Dimensions: "
        .. tostring(width) .. "x" .. tostring(height)
        .. " tiles\n"
        .. "Bounds: ("
        .. tostring(claim.rectX1) .. ", "
        .. tostring(claim.rectY1) .. ") to ("
        .. tostring(claim.rectX2) .. ", "
        .. tostring(claim.rectY2) .. ")\n"
        .. "Claim ID: " .. tostring(claim.id or "Unknown")

    -- Non-modal -- see KIPN_UI.lua's "NON-MODAL CONFIRM DIALOG" header.
    KIPN.UI.CreateConfirmDialog(
        getCore():getScreenWidth() / 2 - 220,
        getCore():getScreenHeight() / 2 - 130,
        440,
        260,
        message,
        false,
        nil,
        nil
    )

end

--------------------------------------------------------------------
-- CONTEXT MENU
--------------------------------------------------------------------

local function onFillOwnershipMenu(
    playerNum,
    context,
    worldobjects,
    test
)

    if not context then
        return
    end

    local square =
        getClickedSquare(worldobjects)

    local claim =
        findOwnedClaimAt(square)

    if not claim then
        return
    end

    if test then
        ISWorldObjectContextMenu.setTest()
        return
    end

    local player =
        getSpecificPlayer(playerNum)

    if claim.type == "property" then

        local safehouse =
            findSafehouseAtSquare(square)

        if not safehouse then
            return
        end

        local optionName =
            getText("ContextMenu_ViewSafehouse")

        if not context:getOptionFromName(optionName) then

            context:addOption(
                optionName,
                safehouse,
                openSafehouse,
                player
            )

        end

        return
    end

    if claim.type == "excavation"
        and not context:getOptionFromName("View Excavation Site")
    then

        context:addOption(
            "View Excavation Site",
            claim,
            openExcavationDetails
        )

    end

end


if Events.OnServerCommand then
    Events.OnServerCommand.Add(onServerResponse)
end

if Events.OnGameStart then
    Events.OnGameStart.Add(requestOwnershipData)
end

if Events.OnCreatePlayer then
    Events.OnCreatePlayer.Add(requestOwnershipData)
end

if Events.OnFillWorldObjectContextMenu then
    Events.OnFillWorldObjectContextMenu.Add(onFillOwnershipMenu)
end

print("[KIPN] Ownership Claim Menu client loaded")
