-- KIPN_VehicleEnforcement.lua
--
-- Server-authoritative non-owner vehicle access enforcement for
-- KIPN: Vehicle Services. Carved out of KIP Network Terminal's
-- KIPN_ClaimPermissions.lua (which keeps only the generic
-- owner/allowed query layer + land-claim movement enforcement).
--
-- Namespace: KIPN.Server.VehEnforcement.

if isClient() then return end

require "KIPN/KIPN_Shared"
require "KIPN/KIPN_Server"
require "KIPN_ClaimService"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.VehEnforcement = KIPN.Server.VehEnforcement or {}

local VehEnforcement = KIPN.Server.VehEnforcement

-- getVehicleById() finds nothing in single player (it only asks the
-- multiplayer VehicleManager); KIPN.Shared.GetVehicleById falls back to
-- the vehicles loaded in the cell.
local function findVehicleById(id)
    if KIPN.Shared and type(KIPN.Shared.GetVehicleById) == "function" then
        return KIPN.Shared.GetVehicleById(id)
    end
    if type(getVehicleById) == "function" then
        return getVehicleById(tonumber(id) or id)
    end
    return nil
end

-- Terminal's generic claim permission queries. Resolved at call time
-- (load order across mods is not guaranteed).
local function claimIsAllowed(claim, player)
    local C = KIPN.Server.ClaimPermissions
    if C and type(C.IsAllowed) == "function" then
        return C.IsAllowed(claim, player)
    end
    return false
end

local function log(message)
    print("[KIPN VEHICLE ENFORCEMENT] " .. tostring(message))
end
local function logError(message)
    print("[KIPN VEHICLE ENFORCEMENT] ERROR: " .. tostring(message))
end

local WARN_THROTTLE_MS = 3000
local lastWarnAtMs = {}

local function getPlayerRuntimeKey(player)
    if not player then return nil end
    local key = nil
    pcall(function()
        if type(player.getOnlineID) == "function" then key = player:getOnlineID() end
        if key == nil and type(player.getUsername) == "function" then key = player:getUsername() end
    end)
    return key ~= nil and tostring(key) or nil
end

local function getRuntimeMs()
    if type(_G.getTimestampMs) ~= "function" then return 0 end
    local ok, result = pcall(_G.getTimestampMs)
    if ok and type(result) == "number" then return result end
    return 0
end

------------------------------------------------------------
-- VEHICLE CLAIM LOOKUP / ACCESS QUERY
------------------------------------------------------------

function VehEnforcement.GetVehicleClaim(vehicle)

    if not vehicle
        or not KIPN.Server.ClaimService
        or type(
            KIPN.Server.ClaimService.GetClaimForTarget
        ) ~= "function"
        or not KIPN.Server.ClaimService.Types
    then

        return nil

    end

    local vehicleId =
        nil

    local ok =
        pcall(
            function()

                vehicleId =
                    vehicle:getId()

            end
        )

    if not ok or vehicleId == nil then

        return nil

    end

    return KIPN.Server.ClaimService.GetClaimForTarget(
        KIPN.Server.ClaimService.Types.VEHICLE,
        tostring(vehicleId)
    )

end

function VehEnforcement.CanAccessVehicle(vehicle, player)

    local claim =
        VehEnforcement.GetVehicleClaim(vehicle)

    if not claim then

        return true,
            nil

    end

    return claimIsAllowed(claim, player),
        claim

end

local function enforceVehicleAccess(player)

    if not player
        or type(player.getVehicle) ~= "function"
    then

        return true

    end

    local vehicle =
        player:getVehicle()

    if not vehicle then

        return true

    end

    local allowed,
        claim =
        VehEnforcement.CanAccessVehicle(
            vehicle,
            player
        )

    if not claim then

        return true

    end

    --------------------------------------------------------
    -- Refresh the synchronized client projection for claims made
    -- before vehicle ModData stamping was introduced, or vehicles
    -- that were unloaded when the server initialized.
    --------------------------------------------------------

    if type(
        KIPN.Server.ClaimService.SyncVehicleOwnershipMetadata
    ) == "function"
    then

        KIPN.Server.ClaimService.SyncVehicleOwnershipMetadata(
            vehicle,
            claim
        )

    end

    if allowed then

        return true

    end

    local seat =
        nil

    pcall(
        function()

            seat =
                vehicle:getSeat(player)

        end
    )

    local ejected, ejectError =
        pcall(
            function()

                vehicle:exit(player)

                if seat ~= nil
                    and tonumber(seat)
                    and tonumber(seat) >= 0
                    and type(vehicle.setCharacterPosition)
                        == "function"
                then

                    vehicle:setCharacterPosition(
                        player,
                        seat,
                        "outside"
                    )

                end

            end
        )

    if not ejected then

        logError(
            "Unable to eject unauthorized vehicle occupant: " ..
            tostring(ejectError)
        )

    end

    local playerKey =
        getPlayerRuntimeKey(player)

    local now =
        getRuntimeMs()

    local lastWarn =
        playerKey
        and lastWarnAtMs[playerKey]
        or 0

    if not playerKey
        or now - (lastWarn or 0) >= WARN_THROTTLE_MS
    then

        if playerKey then

            lastWarnAtMs[playerKey] =
                now

        end

        if type(player.Say) == "function" then

            player:Say(
                "This vehicle is claimed. You are not " ..
                "authorized to access it."
            )

        end

    end

    return false

end

local vehicleAccessTickCounter =
    0

local vehicleOwnershipSyncTickCounter =
    0

local function syncLoadedVehicleOwnershipMetadata()

    local service =
        KIPN.Server.ClaimService

    if not service
        or not service.Types
        or type(service.GetClaims) ~= "function"
        or type(service.GetClaimForTarget) ~= "function"
        or type(service.SyncVehicleOwnershipMetadata) ~= "function"
    then

        return

    end

    local claims =
        service.GetClaims(
            service.Types.VEHICLE
        )

    for _, candidate in pairs(claims) do

        local claim =
            service.GetClaimForTarget(
                service.Types.VEHICLE,
                candidate.targetId
            )

        if claim then

            local vehicle =
                findVehicleById(
                    claim.targetId
                )

            if vehicle then

                service.SyncVehicleOwnershipMetadata(
                    vehicle,
                    claim
                )

            end

        end

    end

end

local function onVehicleAccessTick()

    vehicleAccessTickCounter =
        vehicleAccessTickCounter + 1

    vehicleOwnershipSyncTickCounter =
        vehicleOwnershipSyncTickCounter + 1

    if vehicleOwnershipSyncTickCounter >= 300 then

        vehicleOwnershipSyncTickCounter =
            0

        local ok, errorMessage =
            pcall(
                syncLoadedVehicleOwnershipMetadata
            )

        if not ok then

            logError(
                "Vehicle ownership metadata sync failed: " ..
                tostring(errorMessage)
            )

        end

    end

    -- OnPlayerMove normally catches entry immediately. This small
    -- periodic audit covers stationary occupants and alternate
    -- client/mod entry paths that do not emit movement first.
    if vehicleAccessTickCounter < 15 then

        return

    end

    vehicleAccessTickCounter =
        0

    if type(getOnlinePlayers) ~= "function" then

        return

    end

    local players =
        getOnlinePlayers()

    if not players then

        return

    end

    for i = 0,
        players:size() - 1
    do

        local player =
            players:get(i)

        local ok, errorMessage =
            pcall(
                enforceVehicleAccess,
                player
            )

        if not ok then

            logError(
                "Vehicle access audit failed: " ..
                tostring(errorMessage)
            )

        end

    end

end

------------------------------------------------------------
-- SERVER-SIDE VEHICLE VANDALISM INTERCEPTION
------------------------------------------------------------
--
-- Wraps vanilla ClientCommands.vehicle functions to enforce
-- ownership limits on mechanics, towing, and door/trunk access.
------------------------------------------------------------

local OriginalVehicleCommands = {}

------------------------------------------------------------
-- NON-OWNER VEHICLE PERMISSION CATEGORIES
--
-- setDoorLocked / configDoor / configWindow / smashWindow are
-- intentionally absent from every category below -- they always
-- fall through to the default deny, matching the required semantics
-- that Open-Unlocked-Doors/Tow/Mechanics must never grant lock/
-- unlock, vandalism, or window control.
------------------------------------------------------------

local MECHANICS_COMMANDS = {
    installPart = true,
    uninstallPart = true,
    repairPart = true,
}

local TOW_COMMANDS = {
    addTowing = true,
    removeTowing = true,
}

local OPEN_DOOR_COMMANDS = {
    setDoorOpen = true,
}

local function getVehicleServiceConfig()

    return KIPN.Server.ClaimConfig
        and type(KIPN.Server.ClaimConfig.GetServiceConfig) == "function"
        and KIPN.Server.ClaimConfig.GetServiceConfig("vehicle")
        or nil

end

------------------------------------------------------------
-- DOOR LOCK-STATE RESOLUTION (Open Unlocked Doors permission)
--
-- IMPORTANT -- UNVERIFIED ARGS SHAPE:
--
-- setDoorOpen is a Java-native ClientCommands.vehicle hook with no
-- Lua call site anywhere in the shipped game (vanilla's own door-open
-- flow, ISVehicleMenu.onOpenDoor -> ISOpenVehicleDoor TimedAction,
-- never calls it directly). The exact args field identifying WHICH
-- door is targeted could not be confirmed via static analysis.
--
-- This resolves args.part defensively and fails CLOSED (treats the
-- door as locked / denies the permission) on any lookup failure, so
-- an unverified args shape can only ever be over-strict, never
-- accidentally grant access to a locked door. This must be confirmed
-- against a live Build 42 session -- see the verification notes.
------------------------------------------------------------

local function isDoorCurrentlyUnlocked(vehicle, args)

    if not vehicle or not args or args.part == nil then
        return false
    end

    local ok, unlocked =
        pcall(
            function()

                if type(vehicle.getPartById) ~= "function" then
                    return false
                end

                local part =
                    vehicle:getPartById(args.part)

                if not part
                    or type(part.getDoor) ~= "function"
                then
                    return false
                end

                local door =
                    part:getDoor()

                if not door
                    or type(door.isLocked) ~= "function"
                then
                    return false
                end

                return door:isLocked() == false

            end
        )

    if not ok then
        return false
    end

    return unlocked == true

end

------------------------------------------------------------
-- RESOLVE WHETHER A NON-OWNER MAY RUN THIS COMMAND
--
-- NonOwnerNoAccess overrides every individual permission below,
-- regardless of their own values.
------------------------------------------------------------

local function nonOwnerCommandAllowed(cmdName, vehicle, args, serviceConfig)

    if not serviceConfig then
        return false, "NO_SERVICE_CONFIG"
    end

    if serviceConfig.NonOwnerNoAccess == true then
        return false, "NO_ACCESS_OVERRIDE"
    end

    if MECHANICS_COMMANDS[cmdName] then
        return serviceConfig.AllowNonOwnerMechanics == true,
            "MECHANICS"
    end

    if TOW_COMMANDS[cmdName] then
        return serviceConfig.AllowNonOwnerTow == true,
            "TOW"
    end

    if OPEN_DOOR_COMMANDS[cmdName] then
        local allowed =
            serviceConfig.AllowNonOwnerOpenUnlockedDoors == true
            and isDoorCurrentlyUnlocked(vehicle, args)
        return allowed,
            "OPEN_UNLOCKED_DOORS"
    end

    return false, "OWNER_ONLY_COMMAND"

end

local function interceptVehicleCommand(cmdName)

    if not ClientCommands
        or not ClientCommands.vehicle
        or type(ClientCommands.vehicle[cmdName]) ~= "function"
    then
        return
    end

    if OriginalVehicleCommands[cmdName] then
        return
    end

    OriginalVehicleCommands[cmdName] = ClientCommands.vehicle[cmdName]

    ClientCommands.vehicle[cmdName] = function(player, args)

        local vehicle = nil

        if args and type(args.vehicle) == "number" then
            vehicle = findVehicleById(args.vehicle)
        end

        if vehicle then
            local allowed, claim = VehEnforcement.CanAccessVehicle(vehicle, player)

            if not allowed then

                local serviceConfig =
                    getVehicleServiceConfig()

                local nonOwnerAllowed, category =
                    nonOwnerCommandAllowed(
                        cmdName,
                        vehicle,
                        args,
                        serviceConfig
                    )

                log(
                    "Vehicle trespass decision | cmd=" .. tostring(cmdName) ..
                    " | category=" .. tostring(category) ..
                    " | claim=" .. tostring(claim and claim.id or "nil") ..
                    " | actor=" .. tostring(
                        player and type(player.getUsername) == "function"
                        and player:getUsername() or "unknown"
                    ) ..
                    " | result=" .. tostring(nonOwnerAllowed and "ALLOW" or "DENY")
                )

                if not nonOwnerAllowed then
                    if type(player.Say) == "function" then
                        player:Say("This vehicle is claimed. You cannot modify it.")
                    end
                    return
                end

            end
        end

        OriginalVehicleCommands[cmdName](player, args)

    end

end

------------------------------------------------------------
-- INITIALIZATION  (driven by KIPN_VehicleServicesInit.lua's RegisterService)
------------------------------------------------------------

function VehEnforcement.Initialize()

    local cmdsToIntercept = {
        "installPart", "uninstallPart", "repairPart",
        "addTowing", "removeTowing",
        "setDoorOpen", "setDoorLocked", "configDoor",
        "configWindow", "smashWindow",
    }

    for _, cmd in ipairs(cmdsToIntercept) do
        pcall(interceptVehicleCommand, cmd)
    end

    -- VehicleManager.instance is not yet set during server init (Initialize()
    -- runs before the game loop starts), so an immediate sync here always
    -- throws. onVehicleAccessTick's periodic resync (every 300 OnTick calls)
    -- performs the first real sync once vehicles exist.

    if Events and Events.OnPlayerMove then
        Events.OnPlayerMove.Add(function(player)
            pcall(enforceVehicleAccess, player)
        end)
    else
        logError("Events.OnPlayerMove unavailable; vehicle access not enforced on move.")
    end

    if Events and Events.OnTick then
        Events.OnTick.Add(onVehicleAccessTick)
    else
        logError("Events.OnTick unavailable; stationary vehicle access auditing off.")
    end

    log("Vehicle access enforcement initialized.")
    return true
end

print("[KIPN] Vehicle Services enforcement loaded")

