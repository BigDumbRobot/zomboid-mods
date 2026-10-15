-- KIPN_VehicleBridge.lua
--
-- VANILLA VEHICLE ADAPTER
--
-- The vehicle claim service should use this module for BaseVehicle
-- identity / synchronized ownership metadata instead of embedding those
-- game-object details in the public ClaimService router.

KIPN = KIPN or {}
KIPN.Bridges = KIPN.Bridges or {}

KIPN.Bridges.Vehicle =
    KIPN.Bridges.Vehicle or {}

local VehicleBridge =
    KIPN.Bridges.Vehicle

local CLAIM_ID_KEY =
    "KIPNVehicleClaimId"

local OWNER_ID_KEY =
    "KIPNVehicleOwnerSteamId"

local OWNER_NAME_KEY =
    "KIPNVehicleOwnerUsername"

local function log(message)

    print(
        "[KIPN VEHICLE BRIDGE] " ..
        tostring(message)
    )

end

local function logError(message)

    print(
        "[KIPN VEHICLE BRIDGE] ERROR: " ..
        tostring(message)
    )

end

function VehicleBridge.GetId(
    vehicle
)

    if not vehicle
        or type(
            vehicle.getId
        ) ~= "function"
    then

        log(
            "GetId() | unavailable"
        )

        return nil

    end

    local ok, result =
        pcall(
            function()

                return vehicle:getId()

            end
        )

    if not ok
        or result == nil
    then

        log(
            "GetId() | result=nil"
        )

        return nil

    end

    local id =
        tostring(result)

    log(
        "GetId() | id=" ..
        id
    )

    return id

end

function VehicleBridge.GetSquare(
    vehicle
)

    if not vehicle
        or type(
            vehicle.getSquare
        ) ~= "function"
    then

        log(
            "GetSquare() | unavailable"
        )

        return nil

    end

    local ok, square =
        pcall(
            function()

                return vehicle:getSquare()

            end
        )

    if not ok then

        logError(
            "GetSquare() failed: " ..
            tostring(square)
        )

        return nil

    end

    log(
        "GetSquare() | found=" ..
        tostring(square ~= nil)
    )

    return square

end

function VehicleBridge.GetPosition(
    vehicle
)

    local square =
        VehicleBridge.GetSquare(
            vehicle
        )

    if not square then

        return nil

    end

    local position

    local ok, errorMessage =
        pcall(
            function()

                position = {

                    x =
                        square:getX(),

                    y =
                        square:getY(),

                    z =
                        square:getZ(),

                }

            end
        )

    if not ok then

        logError(
            "GetPosition() failed: " ..
            tostring(errorMessage)
        )

        return nil

    end

    log(
        "GetPosition() | " ..
        tostring(position.x) ..
        "," ..
        tostring(position.y) ..
        "," ..
        tostring(position.z)
    )

    return position

end

function VehicleBridge.SyncOwnershipMetadata(
    vehicle,
    claim
)

    if not vehicle
        or type(
            vehicle.getModData
        ) ~= "function"
    then

        logError(
            "SyncOwnershipMetadata() vehicle unavailable."
        )

        return false

    end

    local ok, errorMessage =
        pcall(
            function()

                local modData =
                    vehicle:getModData()

                if type(modData) ~= "table" then

                    error(
                        "vehicle ModData unavailable"
                    )

                end

                if claim then

                    modData[
                        CLAIM_ID_KEY
                    ] =
                        tostring(
                            claim.id
                        )

                    modData[
                        OWNER_ID_KEY
                    ] =
                        tostring(
                            claim.ownerSteamId
                        )

                    modData[
                        OWNER_NAME_KEY
                    ] =
                        tostring(
                            claim.ownerUsername
                            or "Unknown"
                        )

                else

                    modData[
                        CLAIM_ID_KEY
                    ] =
                        nil

                    modData[
                        OWNER_ID_KEY
                    ] =
                        nil

                    modData[
                        OWNER_NAME_KEY
                    ] =
                        nil

                end

                if type(
                    vehicle.transmitModData
                ) == "function"
                then

                    vehicle:transmitModData()

                end

            end
        )

    if not ok then

        logError(
            "SyncOwnershipMetadata() failed: " ..
            tostring(errorMessage)
        )

        return false

    end

    log(
        "SyncOwnershipMetadata() | claim=" ..
        tostring(
            claim
            and claim.id
            or "none"
        )
    )

    return true

end

log(
    "Vehicle bridge loaded."
)
