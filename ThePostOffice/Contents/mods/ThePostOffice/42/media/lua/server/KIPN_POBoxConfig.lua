-- KIPN_POBoxConfig.lua
--
-- PO Box configuration and claim policy for The Post Office. Carved
-- from KIP Network Terminal's server/config/KIPN_ArtifactConfig.lua
-- and KIPN_ClaimConfig.lua.
--
-- PO Box does not fit the Registration -> authorized computer ->
-- Claim artifact pattern the other claim services use: there is no
-- registration step, and the claim item is a vanilla "Blank Key"
-- (Base.Key_Blank) -- not a KIPN-crafted item, and not a
-- server-tracked artifact. The player only needs to be carrying one
-- and pay the purchase fee.
--
-- KeyItemType is the persistent OWNERSHIP token issued after a
-- successful purchase -- never crafted, only issued. It carries the
-- physical box registry ID in ModData.KIPNPOBoxId and the
-- human-facing number in ModData.KIPNPOBoxNumber; its real key ID is
-- bound to the registered world container's lock.

if isClient() and not isServer() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_ClaimConfig"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.POBoxConfig = KIPN.Server.POBoxConfig or {}

local POBoxConfig = KIPN.Server.POBoxConfig

local function logError(message)
    print("[KIPN PO BOX CONFIG] ERROR: " .. tostring(message))
end

POBoxConfig.ClaimItemType =
    "Base.Key_Blank"

POBoxConfig.KeyItemType =
    "Base.KIPNPOBoxKey"

POBoxConfig.Sizes = {

    small = {
        Label = "Small",
        Capacity = 10,
        Price = 250,
        Sprite = "street_decoration_01_21",
    },

    medium = {
        Label = "Medium",
        Capacity = 25,
        Price = 500,
        Sprite = "street_decoration_01_8",
    },

    large = {
        Label = "Large",
        Capacity = 50,
        Price = 1000,
        Sprite = "furniture_storage_02_8",
    },
}

POBoxConfig.KeyCopyPrice = 100

------------------------------------------------------------
-- CLAIM POLICY
------------------------------------------------------------
--
-- Registered at config load so ClaimConfig.Initialize() gives these
-- defaults the "PoBox<Field>" sandbox treatment
-- (KIPN.PoBoxMaxClaimsPerPlayer, ...).
------------------------------------------------------------

local ClaimConfig = KIPN.Server.ClaimConfig

if ClaimConfig and type(ClaimConfig.RegisterService) == "function" then

    ClaimConfig.RegisterService("PoBox", {
        MaxClaimsPerPlayer = 2,
        RegistrationExpiryDays = 14,
        ClaimTokenExpiryDays = 14,
        OwnershipExpiryDays = 0,
    }, "po_box")

else
    logError(
        "ClaimConfig.RegisterService unavailable; PO Box claim policy " ..
        "not registered."
    )
end

------------------------------------------------------------
-- SANDBOX OVERRIDES
------------------------------------------------------------

function POBoxConfig.ApplySandboxOverrides()

    local sv =
        type(SandboxVars) == "table"
        and SandboxVars.KIPN

    if type(sv) ~= "table" then
        return false
    end

    local mappings = {
        small = {
            capacity = "PoBoxSmallCapacity",
            price = "PoBoxSmallPrice",
        },
        medium = {
            capacity = "PoBoxMediumCapacity",
            price = "PoBoxMediumPrice",
        },
        large = {
            capacity = "PoBoxLargeCapacity",
            price = "PoBoxLargePrice",
        },
    }

    for sizeKey, mapping in pairs(mappings) do

        local sizeConfig = POBoxConfig.Sizes[sizeKey]

        if type(sizeConfig) == "table" then

            local capacity = tonumber(sv[mapping.capacity])
            local price = tonumber(sv[mapping.price])

            if capacity and capacity > 0 then
                sizeConfig.Capacity = math.floor(capacity)
            end

            if price and price > 0 then
                sizeConfig.Price = math.floor(price)
            end
        end
    end

    local keyCopyPrice = tonumber(sv.PoBoxKeyCopyPrice)
    if keyCopyPrice and keyCopyPrice > 0 then
        POBoxConfig.KeyCopyPrice = math.floor(keyCopyPrice)
    end

    return true
end

------------------------------------------------------------
-- VALIDATION
------------------------------------------------------------

function POBoxConfig.Validate()

    local valid = true

    for _, sizeKey in ipairs({ "small", "medium", "large" }) do

        local sizeConfig = POBoxConfig.Sizes[sizeKey]

        if type(sizeConfig) ~= "table"
            or not tonumber(sizeConfig.Capacity)
            or tonumber(sizeConfig.Capacity) < 1
            or not tonumber(sizeConfig.Price)
            or tonumber(sizeConfig.Price) < 1
            or type(sizeConfig.Sprite) ~= "string"
            or sizeConfig.Sprite == ""
        then
            logError("PO Box size '" .. tostring(sizeKey) .. "' is invalid.")
            valid = false
        end
    end

    if not tonumber(POBoxConfig.KeyCopyPrice)
        or tonumber(POBoxConfig.KeyCopyPrice) < 1
    then
        logError("PO Box key copy price is invalid.")
        valid = false
    end

    return valid
end

function POBoxConfig.Initialize()
    POBoxConfig.ApplySandboxOverrides()
    return POBoxConfig.Validate()
end

print("[KIPN] Post Office PO Box config loaded")
