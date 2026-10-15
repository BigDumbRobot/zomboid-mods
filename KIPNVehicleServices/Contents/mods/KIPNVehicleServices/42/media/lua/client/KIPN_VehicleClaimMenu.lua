-- KIPN_VehicleClaimMenu.lua
--
-- Right-click "Claim Vehicle" context menu action.
--
-- IMPORTANT:
--
-- This module does NOT determine whether a claim is actually
-- valid.
--
-- It only decides whether to SHOW the option (the player is
-- carrying a claim artifact and the vehicle looks claimable) and,
-- on confirmation, queues KIPN_VehicleClaimAction, which sends
-- KIPN.Shared.Commands.CLAIM_VEHICLE to the server.
--
-- KIPN_ClaimService.lua's command handler is the sole authority:
-- it re-validates the claim artifact, the artifact's zone scope,
-- and the vehicle's current claim status before establishing
-- ownership. A vehicle claimed elsewhere, an artifact scoped to
-- the wrong dealership, or a vehicle claimed by someone else a
-- moment ago will all be rejected server-side even if this menu
-- showed the option.
--
-- The full player-facing artifact/item type string here
-- ("Base.KIPNVehicleClaimArtifact") MUST match
-- KIPN_ArtifactConfig.lua's ArtifactConfig.ClaimItems.Vehicle on
-- the server.

if isServer() then
    return
end

require "TimedActions/ISBaseTimedAction"
require "TimedActions/KIPN_VehicleClaimAction"
require "KIPN_UI"
require "luautils"

local CLAIM_ARTIFACT_ITEM_TYPE =
    "Base.KIPNVehicleClaimArtifact"

local CLAIM_ARTIFACT_SHORT_TYPE =
    "KIPNVehicleClaimArtifact"

local VEHICLE_CLAIM_ID_KEY =
    "KIPNVehicleClaimId"

local VEHICLE_OWNER_ID_KEY =
    "KIPNVehicleOwnerSteamId"

local VEHICLE_OWNER_NAME_KEY =
    "KIPNVehicleOwnerUsername"

--------------------------------------------------------------------
-- CLIENT-SIDE OWNERSHIP HINT
--
-- Vehicle ModData is synchronized by the authoritative server claim
-- service. This check exists for immediate menu feedback only; the
-- server independently ejects unauthorized occupants based on its
-- persistent claim registry.
--------------------------------------------------------------------

local function getPlayerOwnershipId(player)

    if not player then
        return nil
    end

    -- The same key ClaimService writes into the claim and the vehicle's
    -- ModData: the server account (KIPN.Shared.GetPlayerId).
    local ok, result =
        pcall(
            KIPN.Shared.GetPlayerId,
            player
        )

    if ok and result ~= nil then
        return tostring(result)
    end

    return nil

end

local function getVehicleOwnership(vehicle)

    if not vehicle
        or type(vehicle.getModData) ~= "function"
    then

        return nil

    end

    local modData =
        vehicle:getModData()

    if type(modData) ~= "table"
        or not modData[VEHICLE_CLAIM_ID_KEY]
        or not modData[VEHICLE_OWNER_ID_KEY]
    then

        return nil

    end

    return {

        claimId =
            tostring(modData[VEHICLE_CLAIM_ID_KEY]),

        ownerId =
            tostring(modData[VEHICLE_OWNER_ID_KEY]),

        ownerName =
            tostring(
                modData[VEHICLE_OWNER_NAME_KEY]
                or "another player"
            ),

    }

end

local function playerCanAccessVehicle(player, vehicle)

    local ownership =
        getVehicleOwnership(vehicle)

    if not ownership then

        return true,
            nil

    end

    local playerId =
        getPlayerOwnershipId(player)

    if playerId ~= nil
        and playerId == ownership.ownerId
    then

        return true,
            ownership

    end

    --------------------------------------------------------
    -- Display-side compatibility fallback for servers/saves that
    -- expose SteamID64 using a different Lua string rendering. The
    -- server still authorizes solely against its claim record, so
    -- this cannot grant real access to a different account.
    --------------------------------------------------------

    local username =
        nil

    pcall(
        function()

            username =
                player:getUsername()

        end
    )

    return username ~= nil
        and tostring(username) == ownership.ownerName,
        ownership

end


--------------------------------------------------------------------
-- DEALERSHIP ZONE HINT
--------------------------------------------------------------------

local function isVehicleInDealershipZone(vehicle)

    if not vehicle then
        return false
    end

    local square =
        vehicle:getSquare()

    if not square then
        return false
    end

    local cache =
        KIPN
        and KIPN.Client
        and KIPN.Client.ZoneMapCache

    if not cache
        or type(cache.zones) ~= "table"
    then

        return false

    end

    local x =
        square:getX()

    local y =
        square:getY()

    local z =
        square:getZ()

    for _, zone in pairs(cache.zones) do

        local geometry =
            type(zone) == "table"
            and zone.geometry

        if zone.type == "dealership"
            and type(geometry) == "table"
        then

            local x1 =
                tonumber(geometry.x1)

            local y1 =
                tonumber(geometry.y1)

            local x2 =
                tonumber(geometry.x2)

            local y2 =
                tonumber(geometry.y2)

            local z1 =
                tonumber(geometry.z1) or 0

            local z2 =
                tonumber(geometry.z2) or z1

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

--------------------------------------------------------------------
-- VEHICLE ELIGIBILITY (CLIENT-SIDE HINT ONLY)
--------------------------------------------------------------------

local function isVehicleClaimable(vehicle)

    if not vehicle then
        return false
    end

    if vehicle.isRemovedFromWorld
        and vehicle:isRemovedFromWorld() then

        return false
    end

    if vehicle:getVehicleTowedBy() ~= nil
        or vehicle:getVehicleTowing() ~= nil then

        return false
    end

    return true

end

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
    -- scans the player's top-level inventory, so a Vehicle Title
    -- carried inside a bag would never make this menu option
    -- appear at all. Matches the same recursive-lookup fix already
    -- applied server-side (see KIPN_ArtifactService.lua's
    -- findArtifactItem()) and to KIPN_PropertyClaimMenu.lua.
    return inventory:containsTypeRecurse(
        CLAIM_ARTIFACT_ITEM_TYPE
    )

end

--------------------------------------------------------------------
-- CONFIRM DIALOG
--------------------------------------------------------------------

local function onClaimDialogResult(
    player,
    button,
    vehicle
)

    if button.internal == "NO" then
        return
    end

    if not isVehicleClaimable(vehicle) then

        player:setHaloNote(
            "This vehicle is no longer available to claim.",
            250, 250, 250, 300
        )

        return
    end

    if not KIPN_VehicleClaimAction.CanStart(player, true) then
        return
    end

    if luautils.walkAdj(
        player,
        vehicle:getSquare()
    ) then

        ISTimedActionQueue.add(
            KIPN_VehicleClaimAction:new(
                player,
                vehicle
            )
        )

    end

end

local function openClaimConfirmDialog(
    player,
    vehicle
)

    local message =
        "Claim this vehicle using your Vehicle Title?"

    -- KIPN.UI.CreateConfirmDialog(x, y, w, h, text, yesno, target,
    -- onclick, player, param1, param2). Non-modal (see KIPN_UI.lua's
    -- "NON-MODAL CONFIRM DIALOG" header for why vanilla ISModalDialog
    -- is not used here) but otherwise the same contract. The 9th
    -- argument is a player INDEX (it is fed straight to
    -- getSpecificPlayer()); the callback payload goes in param1.
    -- Passing `vehicle` in the 9th slot was the "expected argument of
    -- type int, got BaseVehicle" crash. onClaimDialogResult(target,
    -- button, param1) => (player, button, vehicle).
    KIPN.UI.CreateConfirmDialog(
        (getCore():getScreenWidth() / 2) - (300 / 2),
        (getCore():getScreenHeight() / 2) - (150 / 2),
        300,
        150,
        message,
        true,
        player,
        onClaimDialogResult,
        player:getPlayerNum(),
        vehicle
    )

end

--------------------------------------------------------------------
-- RELEASE OWNERSHIP  (right-click a vehicle you already own)
--
-- Sends KIPN.Shared.Commands.RELEASE_CLAIM -- the exact command
-- KIPN's native "RELEASE" row in the Vehicle Records terminal
-- screen uses -- with the vehicle's claim id, read from the same
-- ModData field the server writes on claim
-- (getVehicleOwnership()). The server re-validates that the
-- requester currently owns that claim
-- (KIPN_ClaimService.lua's handleReleaseClaimCommand) and the
-- "vehicle" claim type's onAfterRelease hook clears the vehicle's
-- ownership metadata. No timed action / proximity check: releasing
-- your own claim needs neither, matching the native flow.
--------------------------------------------------------------------

-- Set when this client sends a right-click RELEASE_CLAIM, so the
-- OnServerCommand listener at the bottom of this file can report the
-- outcome (the request is fired with no terminal screen open, so
-- nothing else would tell the player whether it worked).
local pendingRelease = nil

local function nowMs()
    if type(_G.getTimestampMs) ~= "function" then
        return 0
    end
    local ok, result = pcall(_G.getTimestampMs)
    return (ok and type(result) == "number") and result or 0
end

local function sendVehicleRelease(player, vehicle)

    local ownership =
        getVehicleOwnership(vehicle)

    if not ownership
        or not ownership.claimId
    then

        player:setHaloNote(
            "This vehicle is not claimed.",
            250, 250, 250, 300
        )

        return
    end

    local command =
        KIPN.Shared
        and KIPN.Shared.Commands
        and KIPN.Shared.Commands.RELEASE_CLAIM

    if not command then

        if KIPN.Logger then
            KIPN.Logger.Error(
                "KIPN_VehicleClaimMenu: "
                .. "RELEASE_CLAIM command unavailable"
            )
        end

        return
    end

    pendingRelease = {
        player = player,
        atMs = nowMs(),
    }

    player:Say("Filing release of vehicle ownership...")

    sendClientCommand(
        "KIPN",
        command,
        {
            claimId = ownership.claimId,
        }
    )
end

local function onReleaseDialogResult(
    player,
    button,
    vehicle
)

    if button.internal == "NO" then
        return
    end

    sendVehicleRelease(player, vehicle)
end

local function openReleaseConfirmDialog(
    player,
    vehicle
)

    local message =
        "Release your ownership of this vehicle? "
        .. "It becomes unclaimed and anyone may register it."

    -- Same argument order as openClaimConfirmDialog(): the 9th
    -- argument is a player INDEX, the callback payload is param1.
    -- Non-modal -- see KIPN_UI.lua's "NON-MODAL CONFIRM DIALOG" header.
    KIPN.UI.CreateConfirmDialog(
        (getCore():getScreenWidth() / 2) - (300 / 2),
        (getCore():getScreenHeight() / 2) - (150 / 2),
        300,
        150,
        message,
        true,
        player,
        onReleaseDialogResult,
        player:getPlayerNum(),
        vehicle
    )

end

local function addReleaseOption(
    player,
    context,
    vehicle,
    ownership
)

    -- ownership is the record from playerCanAccessVehicle() at the
    -- FillMenuOutsideVehicle() call site: non-nil only when the
    -- vehicle carries a KIPN claim, and we only reach here on the
    -- owner-access branch, so a non-nil ownership means this player
    -- owns it.
    if not ownership
        or not ownership.claimId
    then
        return
    end

    local option =
        context:addOption(
            "Release Vehicle Ownership (KIPN)",
            player,
            openReleaseConfirmDialog,
            vehicle
        )

    local toolTip =
        ISToolTip:new()

    toolTip:initialise()

    toolTip.description =
        "Give up your KIPN ownership of this vehicle. It "
        .. "becomes unclaimed and anyone may register it at a "
        .. "dealership. The server verifies you are the current "
        .. "owner."

    option.toolTip =
        toolTip

end

--------------------------------------------------------------------
-- CONTEXT MENU
--------------------------------------------------------------------

local function addClaimOption(
    player,
    context,
    vehicle
)

    if not isVehicleClaimable(vehicle) then
        return
    end

    if not playerHasClaimArtifact(player) then
        return
    end

    -- The action must not appear for a vehicle parked outside a Car
    -- Dealership Zone. The server repeats this check from the live
    -- WorldRegistry before creating ownership.
    if not isVehicleInDealershipZone(vehicle) then
        return
    end

    local option =
        context:addOption(
            "Claim Vehicle (KIPN)",
            player,
            openClaimConfirmDialog,
            vehicle
        )

    local toolTip =
        ISToolTip:new()

    toolTip:initialise()

    toolTip.description =
        "Claim this vehicle using the Vehicle Title "
        .. "in your inventory. The server will verify you "
        .. "are inside the dealership zone this Vehicle "
        .. "Title was issued for."

    option.toolTip =
        toolTip

end

--------------------------------------------------------------------
-- CLAIMED VEHICLE PROTECTION / PERMISSION GATES
--
-- Owner/unclaimed vehicles keep the vanilla menu unchanged.
--
-- Non-owner permissions come from SandboxVars.KIPN:
--   VehicleNonOwnerNoAccess          (master override)
--   VehicleAllowNonOwnerMechanics
--   VehicleAllowNonOwnerOpenUnlockedDoors
--   VehicleAllowNonOwnerTow
--
-- NoAccess overrides all three regardless of their individual
-- values -- precedence is resolved once here so every caller of
-- getVehicleProtectionPolicy() automatically respects it.
--
-- Non-owners can never actually enter/sit in/drive a claimed
-- vehicle (no field grants that); this client layer only gates
-- which of the three narrow non-entry interactions are offered.
--
-- This client layer is immediate UX feedback only. The authoritative
-- decision is server-side in KIPN_ClaimPermissions.lua's
-- interceptVehicleCommand(); a client bypassing this menu is still
-- denied there.
--------------------------------------------------------------------

if not KIPN then
    KIPN = {}
end

local function getVehicleProtectionPolicy()
    local sv =
        SandboxVars
        and SandboxVars.KIPN
        or {}

    local noAccess =
        sv.VehicleNonOwnerNoAccess == true

    if noAccess then

        return {
            noAccess = true,
            mechanics = false,
            openUnlockedDoors = false,
            tow = false,
        }

    end

    return {
        noAccess = false,

        mechanics =
            sv.VehicleAllowNonOwnerMechanics == true,

        openUnlockedDoors =
            sv.VehicleAllowNonOwnerOpenUnlockedDoors == true,

        tow =
            sv.VehicleAllowNonOwnerTow == true,
    }
end

local function getNonOwnerPermission(
    playerObj,
    vehicle,
    permissionName
)

    local ownerAccess,
        ownership =
        playerCanAccessVehicle(
            playerObj,
            vehicle
        )

    if ownerAccess then
        return true,
            ownership
    end

    local policy =
        getVehicleProtectionPolicy()

    return policy[permissionName] == true,
        ownership
end

local function showVehicleAccessDenied(
    player,
    ownership,
    reason
)

    if player
        and type(player.setHaloNote) == "function"
    then

        local message =
            reason
            or (
                "Vehicle owned by " ..
                tostring(
                    ownership
                    and ownership.ownerName
                    or "another player"
                ) ..
                "."
            )

        player:setHaloNote(
            message,
            255,
            80,
            80,
            300
        )

    end

end

local function addClaimedVehicleOwnerLabel(
    context,
    ownership
)

    local option =
        context:addOption(
            "Vehicle owned by " ..
            tostring(
                ownership
                and ownership.ownerName
                or "another player"
            ),
            nil,
            nil
        )

    option.notAvailable =
        true
end

local function isUnlockedDoorPart(part)
    return part
        and part:getDoor()
        and part:getInventoryItem()
        and not part:getDoor():isLocked()
end

local function addPermittedNonOwnerContextOptions(
    playerObj,
    context,
    vehicle,
    ownership,
    test
)

    if test then
        return
    end

    addClaimedVehicleOwnerLabel(
        context,
        ownership
    )

    local policy =
        getVehicleProtectionPolicy()

    if policy.mechanics then

        context:addOption(
            getText("ContextMenu_VehicleMechanics"),
            playerObj,
            ISVehicleMenu.onMechanic,
            vehicle
        )

    end

    if policy.openUnlockedDoors then

        local part =
            vehicle:getUseablePart(
                playerObj
            )

        -- EngineDoor/hood is mechanics access, not generic unlocked-door
        -- access. This prevents "open door" permission from indirectly
        -- launching the mechanics UI.
        if isUnlockedDoorPart(part)
            and part:getId() ~= "EngineDoor"
        then

            local door =
                part:getDoor()

            if door:isOpen() then

                context:addOption(
                    getText("ContextMenu_Close_door"),
                    playerObj,
                    ISVehicleMenu.onCloseDoor,
                    part
                )

            else

                context:addOption(
                    getText("ContextMenu_Open_door"),
                    playerObj,
                    ISVehicleMenu.onOpenDoor,
                    part
                )

            end

        end

    end
end

--------------------------------------------------------------------
-- ORIGINAL VANILLA CALLBACKS
--------------------------------------------------------------------

if not KIPN.oFillMenuOutsideVehicle then
    KIPN.oFillMenuOutsideVehicle =
        ISVehicleMenu.FillMenuOutsideVehicle
end

if not KIPN.oVehicleMenuOnEnter then
    KIPN.oVehicleMenuOnEnter =
        ISVehicleMenu.onEnter
end

if not KIPN.oVehicleMenuOnEnter2 then
    KIPN.oVehicleMenuOnEnter2 =
        ISVehicleMenu.onEnter2
end

if not KIPN.oVehicleMenuOnShowSeatUI then
    KIPN.oVehicleMenuOnShowSeatUI =
        ISVehicleMenu.onShowSeatUI
end

if not KIPN.oVehicleMenuOnMechanic then
    KIPN.oVehicleMenuOnMechanic =
        ISVehicleMenu.onMechanic
end

if not KIPN.oVehicleMenuOnOpenDoor then
    KIPN.oVehicleMenuOnOpenDoor =
        ISVehicleMenu.onOpenDoor
end

if not KIPN.oVehicleMenuOnCloseDoor then
    KIPN.oVehicleMenuOnCloseDoor =
        ISVehicleMenu.onCloseDoor
end

if not KIPN.oVehicleMenuOnLockDoor then
    KIPN.oVehicleMenuOnLockDoor =
        ISVehicleMenu.onLockDoor
end

if not KIPN.oVehicleMenuOnUnlockDoor then
    KIPN.oVehicleMenuOnUnlockDoor =
        ISVehicleMenu.onUnlockDoor
end

if not KIPN.oVehicleMenuShowRadialMenuOutside then
    KIPN.oVehicleMenuShowRadialMenuOutside =
        ISVehicleMenu.showRadialMenuOutside
end

if not KIPN.oVehicleMenuShowRadialMenu then
    KIPN.oVehicleMenuShowRadialMenu =
        ISVehicleMenu.showRadialMenu
end

--------------------------------------------------------------------
-- RIGHT-CLICK MENU
--------------------------------------------------------------------

function ISVehicleMenu.FillMenuOutsideVehicle(
    player,
    context,
    vehicle,
    test
)

    local playerObj =
        getSpecificPlayer(player)

    local ownerAccess,
        ownership =
        playerCanAccessVehicle(
            playerObj,
            vehicle
        )

    if not ownerAccess then

        addPermittedNonOwnerContextOptions(
            playerObj,
            context,
            vehicle,
            ownership,
            test
        )

        return
    end

    KIPN.oFillMenuOutsideVehicle(
        player,
        context,
        vehicle,
        test
    )

    local ok,
        err =
        pcall(
            addClaimOption,
            playerObj,
            context,
            vehicle
        )

    if not ok
        and KIPN.Logger
    then

        KIPN.Logger.Error(
            "KIPN_VehicleClaimMenu: "
            .. "FillMenuOutsideVehicle failed: "
            .. tostring(err)
        )

    end

    -- "Release Vehicle Ownership (KIPN)" -- only builds an option
    -- when `ownership` is non-nil (this player owns a KIPN claim on
    -- this vehicle); harmless no-op otherwise.
    local relOk,
        relErr =
        pcall(
            addReleaseOption,
            playerObj,
            context,
            vehicle,
            ownership
        )

    if not relOk
        and KIPN.Logger
    then

        KIPN.Logger.Error(
            "KIPN_VehicleClaimMenu: "
            .. "addReleaseOption failed: "
            .. tostring(relErr)
        )

    end

end

--------------------------------------------------------------------
-- ENTER VEHICLE
--------------------------------------------------------------------

function ISVehicleMenu.onShowSeatUI(
    playerObj,
    vehicle
)

    local permitted,
        ownership =
        getNonOwnerPermission(
            playerObj,
            vehicle,
            "enter"
        )

    if not permitted then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to enter this vehicle."
        )

        return
    end

    return KIPN.oVehicleMenuOnShowSeatUI(
        playerObj,
        vehicle
    )
end

function ISVehicleMenu.onEnter(
    playerObj,
    vehicle,
    seat
)

    local permitted,
        ownership =
        getNonOwnerPermission(
            playerObj,
            vehicle,
            "enter"
        )

    if not permitted then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to enter this vehicle."
        )

        return
    end

    return KIPN.oVehicleMenuOnEnter(
        playerObj,
        vehicle,
        seat
    )
end

function ISVehicleMenu.onEnter2(
    playerObj,
    vehicle,
    seat
)

    local permitted,
        ownership =
        getNonOwnerPermission(
            playerObj,
            vehicle,
            "enter"
        )

    if not permitted then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to enter this vehicle."
        )

        return
    end

    return KIPN.oVehicleMenuOnEnter2(
        playerObj,
        vehicle,
        seat
    )
end

--------------------------------------------------------------------
-- MECHANICS
--------------------------------------------------------------------

function ISVehicleMenu.onMechanic(
    playerObj,
    vehicle
)

    local permitted,
        ownership =
        getNonOwnerPermission(
            playerObj,
            vehicle,
            "mechanics"
        )

    if not permitted then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to access vehicle mechanics."
        )

        return
    end

    return KIPN.oVehicleMenuOnMechanic(
        playerObj,
        vehicle
    )
end

--------------------------------------------------------------------
-- DOORS
--------------------------------------------------------------------

function ISVehicleMenu.onOpenDoor(
    playerObj,
    part
)

    local vehicle =
        part
        and part:getVehicle()

    local ownerAccess,
        ownership =
        playerCanAccessVehicle(
            playerObj,
            vehicle
        )

    if ownerAccess then
        return KIPN.oVehicleMenuOnOpenDoor(
            playerObj,
            part
        )
    end

    if part
        and part:getId() == "EngineDoor"
    then

        local policy =
            getVehicleProtectionPolicy()

        if not policy.mechanics then

            showVehicleAccessDenied(
                playerObj,
                ownership,
                "You do not have permission to open this vehicle's hood."
            )

            return
        end

        return KIPN.oVehicleMenuOnOpenDoor(
            playerObj,
            part
        )
    end

    local policy =
        getVehicleProtectionPolicy()

    if not policy.openUnlockedDoors then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to open this vehicle's doors."
        )

        return
    end

    if not isUnlockedDoorPart(part) then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "This permission only allows already-unlocked doors."
        )

        return
    end

    return KIPN.oVehicleMenuOnOpenDoor(
        playerObj,
        part
    )
end

function ISVehicleMenu.onCloseDoor(
    playerObj,
    part
)

    local vehicle =
        part
        and part:getVehicle()

    local ownerAccess,
        ownership =
        playerCanAccessVehicle(
            playerObj,
            vehicle
        )

    if ownerAccess then
        return KIPN.oVehicleMenuOnCloseDoor(
            playerObj,
            part
        )
    end

    local policy =
        getVehicleProtectionPolicy()

    local permitted =
        part
        and (
            (
                part:getId() == "EngineDoor"
                and policy.mechanics
            )
            or (
                part:getId() ~= "EngineDoor"
                and policy.openUnlockedDoors
            )
        )

    if not permitted then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to close this vehicle's door."
        )

        return
    end

    return KIPN.oVehicleMenuOnCloseDoor(
        playerObj,
        part
    )
end

-- Door permission deliberately does NOT include lock/unlock authority.
function ISVehicleMenu.onUnlockDoor(
    playerObj,
    part
)

    local vehicle =
        part
        and part:getVehicle()

    local ownerAccess,
        ownership =
        playerCanAccessVehicle(
            playerObj,
            vehicle
        )

    if not ownerAccess then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to unlock this vehicle."
        )

        return
    end

    return KIPN.oVehicleMenuOnUnlockDoor(
        playerObj,
        part
    )
end

function ISVehicleMenu.onLockDoor(
    playerObj,
    part
)

    local vehicle =
        part
        and part:getVehicle()

    local ownerAccess,
        ownership =
        playerCanAccessVehicle(
            playerObj,
            vehicle
        )

    if not ownerAccess then

        showVehicleAccessDenied(
            playerObj,
            ownership,
            "You do not have permission to lock this vehicle."
        )

        return
    end

    return KIPN.oVehicleMenuOnLockDoor(
        playerObj,
        part
    )
end

--------------------------------------------------------------------
-- RESTRICTED OUTSIDE RADIAL MENU
--------------------------------------------------------------------

local function showRestrictedVehicleRadialMenu(
    playerObj,
    vehicle,
    ownership
)

    local playerIndex =
        playerObj:getPlayerNum()

    local menu =
        getPlayerRadialMenu(
            playerIndex
        )

    if menu:isReallyVisible() then

        if menu.joyfocus then
            setJoypadFocus(
                playerIndex,
                nil
            )
        end

        menu:undisplay()

        return
    end

    menu:clear()

    local policy =
        getVehicleProtectionPolicy()

    local added =
        false

    if policy.mechanics then

        menu:addSlice(
            getText("ContextMenu_VehicleMechanics"),
            getTexture("media/ui/vehicles/vehicle_repair.png"),
            ISVehicleMenu.onMechanic,
            playerObj,
            vehicle
        )

        added =
            true
    end

    if policy.openUnlockedDoors then

        local part =
            vehicle:getUseablePart(
                playerObj
            )

        if isUnlockedDoorPart(part)
            and part:getId() ~= "EngineDoor"
        then

            local callback =
                part:getDoor():isOpen()
                and ISVehicleMenu.onCloseDoor
                or ISVehicleMenu.onOpenDoor

            local label =
                part:getDoor():isOpen()
                and getText("ContextMenu_Close_door")
                or getText("ContextMenu_Open_door")

            menu:addSlice(
                label,
                getTexture("media/ui/vehicles/vehicle_exit.png"),
                callback,
                playerObj,
                part
            )

            added =
                true
        end

    end

    if not added then

        showVehicleAccessDenied(
            playerObj,
            ownership
        )

        return
    end

    menu:setX(
        getPlayerScreenLeft(playerIndex)
        + getPlayerScreenWidth(playerIndex) / 2
        - menu:getWidth() / 2
    )

    menu:setY(
        getPlayerScreenTop(playerIndex)
        + getPlayerScreenHeight(playerIndex) / 2
        - menu:getHeight() / 2
    )

    menu:addToUIManager()

    pcall(
        function()
            getSoundManager():playUISound(
                "UIVehicleMenuOpen"
            )
            menu.sounds.undisplay =
                "UIVehicleMenuClose"
        end
    )
end

function ISVehicleMenu.showRadialMenuOutside(
    playerObj
)

    local vehicle =
        ISVehicleMenu.getVehicleToInteractWith
        and ISVehicleMenu.getVehicleToInteractWith(
            playerObj
        )
        or playerObj:getNearVehicle()

    if vehicle then

        local ownerAccess,
            ownership =
            playerCanAccessVehicle(
                playerObj,
                vehicle
            )

        if not ownerAccess then

            showRestrictedVehicleRadialMenu(
                playerObj,
                vehicle,
                ownership
            )

            return
        end

    end

    return KIPN.oVehicleMenuShowRadialMenuOutside(
        playerObj
    )
end

function ISVehicleMenu.showRadialMenu(
    playerObj
)

    local vehicle =
        playerObj:getVehicle()

    if vehicle then

        local permitted,
            ownership =
            getNonOwnerPermission(
                playerObj,
                vehicle,
                "enter"
            )

        if not permitted then

            showVehicleAccessDenied(
                playerObj,
                ownership
            )

            return
        end

    end

    return KIPN.oVehicleMenuShowRadialMenu(
        playerObj
    )
end

--------------------------------------------------------------------
-- RELEASE RESULT FEEDBACK
--
-- sendVehicleRelease() fires RELEASE_CLAIM with no timed action and
-- no terminal screen open, so nothing else would tell the player
-- whether it worked. The server (KIPN_ClaimService.lua's
-- handleReleaseClaimCommand) re-pushes MY_CLAIMS_DATA on success and
-- sends ERROR on failure -- correlate whichever comes back to the
-- release we just started (pendingRelease). Mirrors the response
-- listener in TimedActions/KIPN_VehicleClaimAction.lua.
--------------------------------------------------------------------

local function onReleaseServerResponse(module, command, args)

    if module ~= "KIPN" then
        return
    end

    if not KIPN.Shared
        or not KIPN.Shared.Commands
        or command ~= KIPN.Shared.Commands.SERVER_RESPONSE
    then
        return
    end

    if not pendingRelease
        or not pendingRelease.player
        or not pendingRelease.player.Say
    then
        return
    end

    -- Drop a stale pending release (unrelated response, or the
    -- reply never arrived) so a much later MY_CLAIMS_DATA -- e.g.
    -- from opening the Vehicle Records screen -- can't be mistaken
    -- for this one.
    local elapsed = nowMs() - (pendingRelease.atMs or 0)

    if pendingRelease.atMs > 0
        and elapsed > 8000
    then
        pendingRelease = nil
        return
    end

    local event =
        args and args.event

    if event == KIPN.Shared.ResponseEvents.MY_CLAIMS_DATA then

        pendingRelease.player:Say("Vehicle ownership released.")
        pendingRelease = nil

    elseif event == KIPN.Shared.ResponseEvents.ERROR then

        local data =
            args.data

        local reason =
            (type(data) == "table"
                and (data.message or data.reason))
            or "unknown reason"

        pendingRelease.player:Say(
            "Vehicle release failed: " .. tostring(reason)
        )

        pendingRelease = nil

    end
end

if Events.OnServerCommand then
    Events.OnServerCommand.Add(onReleaseServerResponse)
end
