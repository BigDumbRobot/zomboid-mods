-- KIPN_POBoxBridge.lua
--
-- PO BOX OBJECT / KEY ADAPTER
--
-- PO boxes are KIPN-owned, but this bridge establishes the boundary for
-- key/object mechanics so ClaimService itself never needs to understand
-- PO-box-specific inventory semantics.

KIPN = KIPN or {}
KIPN.Bridges = KIPN.Bridges or {}

KIPN.Bridges.POBox =
    KIPN.Bridges.POBox or {}

local POBoxBridge =
    KIPN.Bridges.POBox

local function log(message)

    print(
        "[KIPN PO BOX BRIDGE] " ..
        tostring(message)
    )

end

local function logError(message)

    print(
        "[KIPN PO BOX BRIDGE] ERROR: " ..
        tostring(message)
    )

end

function POBoxBridge.GetBoxNumber(
    claim
)

    if type(claim) ~= "table" then

        log(
            "GetBoxNumber() | claim unavailable"
        )

        return nil

    end

    local number =
        claim.poBoxNumber
        or claim.boxNumber
        or claim.targetId

    log(
        "GetBoxNumber() | value=" ..
        tostring(number)
    )

    return number

end

function POBoxBridge.GetKeySerials(
    claim
)

    if type(claim) ~= "table" then

        log(
            "GetKeySerials() | claim unavailable"
        )

        return {}

    end

    local serials =
        claim.poBoxKeySerials

    if type(serials) ~= "table" then

        serials =
            {}

        if claim.poBoxKeySerial then

            serials[
                tostring(
                    claim.poBoxKeySerial
                )
            ] =
                true

        end

    end

    log(
        "GetKeySerials() | claim=" ..
        tostring(claim.id)
    )

    return serials

end

function POBoxBridge.HasKeySerial(
    claim,
    serial
)

    if serial == nil then

        log(
            "HasKeySerial() | serial=nil | result=false"
        )

        return false

    end

    local serials =
        POBoxBridge.GetKeySerials(
            claim
        )

    local result =
        serials[
            tostring(serial)
        ] == true

    log(
        "HasKeySerial() | serial=" ..
        tostring(serial) ..
        " | result=" ..
        tostring(result)
    )

    return result

end

log(
    "PO Box bridge loaded."
)
