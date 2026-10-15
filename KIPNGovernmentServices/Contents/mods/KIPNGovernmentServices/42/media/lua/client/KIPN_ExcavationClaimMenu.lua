-- KIPN_ExcavationClaimMenu.lua
--
-- Right-click "Claim Land" context menu action for excavation
-- claims.
--
-- IMPORTANT:
--
-- This module does NOT determine whether a claim is actually
-- valid.
--
-- It only decides whether to SHOW the option (the player is
-- carrying an excavation claim artifact) and, on confirmation,
-- activates KIPN_ExcavationPlacementOverlay -- the mouse-driven
-- placement mode that lets the player choose WHERE (within range)
-- to place the claim, sized to match the tier they purchased.
--
-- KIPN_PropertyClaimService.lua's CLAIM_EXCAVATION command handler
-- is the sole authority: it resolves and re-validates the proposed
-- target location, the claim artifact, its size tier, zone restrictions,
-- whether every square in the area is open land (not inside a
-- building, not solid/blocked, not water), and whether that area
-- is already claimed, before establishing ownership. Nothing this
-- menu or the overlay decides is trusted -- the placement
-- overlay's own land-validity preview is a best-effort
-- client-side hint only.
--
-- The full player-facing artifact/item type string here
-- ("Base.KIPNExcavationClaimArtifact") MUST match the claimItem
-- registered in KIPN_GovArtifactService.lua.
--
-- Unlike client/KIPN_PropertyClaimMenu.lua (a property claim has no
-- discrete world object and is anchored to wherever the player is
-- standing), an excavation claim's location is chosen by the player
-- via the placement overlay, so this also hooks
-- Events.OnFillWorldObjectContextMenu directly.

if isServer() then
    return
end

require "KIPN_ExcavationPlacementOverlay"

local CLAIM_ARTIFACT_ITEM_TYPE =
    "Base.KIPNExcavationClaimArtifact"

local function log(message)

    print(
        "[KIPN EXCAVATION CLAIM MENU] " ..
        tostring(message)
    )

end

--------------------------------------------------------------------
-- FIND CLAIM ARTIFACT
--------------------------------------------------------------------

local function findClaimArtifactItem(player)

    if not player then
        return nil
    end

    local inventory =
        player:getInventory()

    if not inventory then
        return nil
    end

    local types = {
        "Base.KIPNExcavationClaimArtifactSmall",
        "Base.KIPNExcavationClaimArtifactMedium",
        "Base.KIPNExcavationClaimArtifactLarge",
        CLAIM_ARTIFACT_ITEM_TYPE
    }

    for _, t in ipairs(types) do
        local item = inventory:getFirstTypeRecurse(t)
        if item then
            return item
        end
    end

    return nil

end

--------------------------------------------------------------------
-- CLAIM LAND
--------------------------------------------------------------------

local function onClaimLandClick(player)

    local item =
        findClaimArtifactItem(player)

    if not item then
        return
    end

    ----------------------------------------------------------------
    -- Display-only size hint written by the server at issuance
    -- (KIPN_GovArtifactService.lua's IssueExcavationClaim). Not
    -- authoritative -- only used to size the preview rectangle.
    -- A permit with no usable dimension hint is refused rather
    -- than displaying a potentially incorrect claim footprint.
    ----------------------------------------------------------------

    local modData =
        item.getModData
        and item:getModData()
        or nil

    local function normalizeSizeClass(value)

        if type(value) ~= "string" then
            return nil
        end

        local normalized =
            string.lower(value)

        if normalized == "small"
            or normalized == "medium"
            or normalized == "large"
        then
            return normalized
        end

        return nil

    end

    ------------------------------------------------------------
    -- PREVIEW SIZE CLASS
    --
    -- This is CLIENT-SIDE DISPLAY INFORMATION ONLY.
    --
    -- Admins may assign ANY tile dimensions to Small / Medium /
    -- Large, so numeric dimensions must NEVER be used to infer a
    -- class. A 12x12 Small permit is still Small if the admin made
    -- Small 12x12.
    --
    -- Preferred source:
    --     KIPNExcavationSize written by ArtifactService at issuance.
    --
    -- Legacy fallback:
    --     the known size-specific physical item type.
    --
    -- A legacy tier label may also be used strictly as a preview
    -- hint. Ownership authority remains entirely server-side.
    ------------------------------------------------------------

    local sizeClass =
        normalizeSizeClass(
            modData
            and modData.KIPNExcavationSize
        )

    local fullType =
        type(item.getFullType) == "function"
        and item:getFullType()
        or nil

    if not sizeClass then

        if fullType ==
            "Base.KIPNExcavationClaimArtifactSmall"
        then
            sizeClass = "small"

        elseif fullType ==
            "Base.KIPNExcavationClaimArtifactMedium"
        then
            sizeClass = "medium"

        elseif fullType ==
            "Base.KIPNExcavationClaimArtifactLarge"
        then
            sizeClass = "large"

        end

    end

    if not sizeClass then

        sizeClass =
            normalizeSizeClass(
                modData
                and modData.KIPNExcavationTierLabel
            )

    end

    if not sizeClass then

        if player.Say then
            player:Say(
                "This Excavation Permit is invalid or missing its size class."
            )
        end

        return
    end

    log(
        "Placement preview class resolved | itemType=" ..
        tostring(fullType) ..
        " | sizeClass=" ..
        tostring(sizeClass)
    )

    KIPN_ExcavationPlacementOverlay.Activate(
        player,
        sizeClass
    )

end

--------------------------------------------------------------------
-- CONTEXT MENU
--------------------------------------------------------------------

local function onFillExcavationClaimMenu(
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

    if not findClaimArtifactItem(player) then
        return
    end

    local option =
        context:addOption(
            "Claim Land (KIPN Excavation)",
            player,
            onClaimLandClick
        )

    local toolTip =
        ISToolTip:new()

    toolTip:initialise()

    toolTip.description =
        "Enter placement mode to choose where to claim land using "
        .. "the Excavation Permit in your inventory. The server "
        .. "will verify the location is valid open land and not "
        .. "already claimed."

    option.toolTip =
        toolTip

end

if Events
    and Events.OnFillWorldObjectContextMenu
then

    Events.OnFillWorldObjectContextMenu.Add(
        onFillExcavationClaimMenu
    )

end
