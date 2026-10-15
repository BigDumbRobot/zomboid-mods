-- KIPN_PropertyClaimMenu.lua
--
-- Right-click "Claim This Location" context menu action for
-- property/safehouse claims.
--
-- IMPORTANT:
--
-- This module does NOT determine whether a claim is actually
-- valid.
--
-- It only decides whether to SHOW the option (the player is
-- carrying a property claim artifact) and, on confirmation, queues
-- KIPN_PropertyClaimAction, which sends
-- KIPN.Shared.Commands.CLAIM_PROPERTY to the server.
--
-- KIPN_PropertyClaimService.lua's command handler is the sole
-- authority: it resolves the player's CURRENT position server-side
-- and re-validates the claim artifact, the building, zone
-- restrictions, and whether that location is already claimed before
-- establishing ownership. A restricted building or one claimed by
-- someone else a moment ago will be rejected server-side even if
-- this menu showed the option.
--
-- The full player-facing artifact/item type string here
-- ("Base.KIPNPropertyClaimArtifact") MUST match the claimItem
-- registered in KIPN_GovArtifactService.lua.
--
-- This hooks Events.OnFillWorldObjectContextMenu directly (the
-- same event client/KIPN_Interaction.lua already uses), rather
-- than wrapping a vanilla menu method like
-- client/KIPN_VehicleClaimMenu.lua does, because a property claim
-- has no discrete world object to attach to -- the target is
-- wherever the player is standing.

if isServer() then
    return
end

require "TimedActions/ISBaseTimedAction"
require "KIPN_UI"

local CLAIM_ARTIFACT_ITEM_TYPE =
    "Base.KIPNPropertyClaimArtifact"

local CLAIM_ARTIFACT_SHORT_TYPE =
    "KIPNPropertyClaimArtifact"

--------------------------------------------------------------------
-- PLAYER HOLDS CLAIM ARTIFACT
--------------------------------------------------------------------

local function playerHasClaimArtifact(player)

    if not player then
        return false
    end

    local inventory =
        player:getInventory()

    if not inventory then
        return false
    end

    -- containsTypeRecurse(), not getItemCount() -- the latter only
    -- scans the player's top-level inventory, so a Safehouse Deed
    -- carried inside a bag would be missed. The server's
    -- findArtifactItem() searches bags the same way.
    return inventory:containsTypeRecurse(
        CLAIM_ARTIFACT_ITEM_TYPE
    ) or inventory:containsTypeRecurse(
        CLAIM_ARTIFACT_SHORT_TYPE
    )

end

--------------------------------------------------------------------
-- PLAYER IS INSIDE A BUILDING
--
-- A Safehouse Deed claims a building, not open land. This is a
-- best-effort client-side gate only -- KIPN_PropertyClaimService.lua's
-- ValidatePropertyTarget() re-checks this authoritatively
-- server-side against the player's live position at claim time.
--------------------------------------------------------------------

local function playerIsInsideBuilding(player)

    if not player then
        return false
    end

    local square =
        player:getSquare()

    if not square then
        return false
    end

    local building

    local ok =
        pcall(
            function()

                building =
                    square:getBuilding()

            end
        )

    return ok and building ~= nil

end

--------------------------------------------------------------------
-- CONFIRM DIALOG
--------------------------------------------------------------------

local function onClaimDialogResult(
    player,
    button
)

    if button.internal == "NO" then
        return
    end

    if not KIPN_PropertyClaimAction.CanStart(player, true) then
        return
    end

    ISTimedActionQueue.add(
        KIPN_PropertyClaimAction:new(
            player
        )
    )

end

local function openClaimConfirmDialog(
    player
)

    local message =
        "Claim this location as your safehouse using your " ..
        "Safehouse Deed?"

    -- Non-modal -- see KIPN_UI.lua's "NON-MODAL CONFIRM DIALOG" header.
    KIPN.UI.CreateConfirmDialog(
        (getCore():getScreenWidth() / 2) - (300 / 2),
        (getCore():getScreenHeight() / 2) - (150 / 2),
        300,
        150,
        message,
        true,
        player,
        onClaimDialogResult
    )

end

--------------------------------------------------------------------
-- CONTEXT MENU
--------------------------------------------------------------------

local function onFillPropertyClaimMenu(
    playerNum,
    context,
    _worldobjects,
    test
)

    if test then
        return
    end

    if not context then
        return
    end

    local player =
        getSpecificPlayer(
            playerNum
        )

    if not playerHasClaimArtifact(player) then
        return
    end

    if not playerIsInsideBuilding(player) then
        return
    end

    local option =
        context:addOption(
            "Claim This Location (KIPN)",
            player,
            openClaimConfirmDialog
        )

    local toolTip =
        ISToolTip:new()

    toolTip:initialise()

    toolTip.description =
        "Claim your current location as a safehouse using the "
        .. "Safehouse Deed in your inventory. The server will "
        .. "verify you are inside a building and that this "
        .. "location is not already claimed."

    option.toolTip =
        toolTip

end

if Events
    and Events.OnFillWorldObjectContextMenu
then

    Events.OnFillWorldObjectContextMenu.Add(
        onFillPropertyClaimMenu
    )

end
