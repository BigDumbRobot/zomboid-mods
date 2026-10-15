-- KIPN_GovClaimConfig.lua
--
-- Government Services claim policy: registers the "House" (property /
-- safehouse) and "Excavation" per-service claim config blocks into
-- Terminal's ClaimConfig, plus the excavation size-tier definitions and
-- the public GET_EXCAVATION_SIZE_TIERS command.

if isClient() then return end

require "KIPN_Shared"
require "KIPN_Server"
require "KIPN_ClaimConfig"

KIPN = KIPN or {}
KIPN.Server = KIPN.Server or {}
KIPN.Server.ClaimConfig = KIPN.Server.ClaimConfig or {}

local ClaimConfig = KIPN.Server.ClaimConfig

------------------------------------------------------------
-- PER-SERVICE POLICY  (registered into Terminal's ClaimConfig)
------------------------------------------------------------
--
-- Registered at config load so the defaults get the same
-- "<Service><Field>" sandbox-override treatment (applied by
-- Terminal's ClaimConfig.Initialize()) as the built-in Vehicle block.
------------------------------------------------------------

if type(ClaimConfig.RegisterService) == "function" then

    ClaimConfig.RegisterService("House", {
        MaxClaimsPerPlayer = 1,
        RegistrationExpiryDays = 14,
        ClaimTokenExpiryDays = 14,
        OwnershipExpiryDays = 120,
        ClaimCraftSeconds = 10,
        AllowClaimsInKIPNZones = false,
    }, "property")

    ClaimConfig.RegisterService("Excavation", {
        MaxClaimsPerPlayer = 2,
        RegistrationExpiryDays = 14,
        ClaimTokenExpiryDays = 14,
        OwnershipExpiryDays = 120,
        AllowNonOwnerEnter = true,
        AllowNonOwnerBuild = false,
        AllowNonOwnerLoot = false,
        AllowNonOwnerExcavate = false,
        ClaimCraftSeconds = 10,
    }, "excavation")

else
    print("[KIPN GOV CLAIM CONFIG] ERROR: ClaimConfig.RegisterService " ..
        "unavailable; House/Excavation claim policy not registered.")
end

------------------------------------------------------------
-- EXCAVATION SIZE TIERS
------------------------------------------------------------
--
-- Exactly THREE excavation permit classes exist:
--
--     small
--     medium
--     large
--
-- Admins may assign the widthTiles / heightTiles / price for each
-- class, but they may not create additional excavation classes or
-- remove one of these three.
--
-- The purchased permit stores the stable CLASS ID. At placement /
-- ownership-claim time, the current server configuration resolves
-- that class ID to its admin-assigned dimensions.
--
-- `id` is therefore a fixed protocol identifier, not an arbitrary
-- admin-defined row identifier.
------------------------------------------------------------

ClaimConfig.ExcavationSizeTiers = {

    { id = "small", label = "Small (5x5)", widthTiles = 5, heightTiles = 5, price = 200 },

    { id = "medium", label = "Medium (10x10)", widthTiles = 10, heightTiles = 10, price = 500 },

    { id = "large", label = "Large (20x20)", widthTiles = 20, heightTiles = 20, price = 1000 },

}

local EXCAVATION_TIER_IDS = {
    small = true,
    medium = true,
    large = true,
}

local function copyExcavationSizeTiers(list)

    local copy = {}

    if type(list) ~= "table" then
        return copy
    end

    for _, tier in ipairs(list) do

        if type(tier) == "table" then

            table.insert(copy, {
                id = tier.id,
                label = tier.label,
                widthTiles = tier.widthTiles,
                heightTiles = tier.heightTiles,
                price = tier.price,
            })
        end
    end

    return copy
end

------------------------------------------------------------
-- GET EXCAVATION SIZE TIERS
--
-- Returns a fresh copy of the default tiers with the sandbox
-- Excavation<Size>WidthTiles / HeightTiles / Price values applied.
-- Never hands out the live internal table.
------------------------------------------------------------

function ClaimConfig.GetExcavationSizeTiers()

    local sv =
        SandboxVars
        and SandboxVars.KIPN
        or {}

    local tiers =
        copyExcavationSizeTiers(
            ClaimConfig.ExcavationSizeTiers
        )

    local prefixes = {
        small = "ExcavationSmall",
        medium = "ExcavationMedium",
        large = "ExcavationLarge",
    }

    for _, tier in ipairs(tiers) do

        local prefix =
            prefixes[tier.id]

        if prefix then

            local width =
                tonumber(
                    sv[prefix .. "WidthTiles"]
                )

            local height =
                tonumber(
                    sv[prefix .. "HeightTiles"]
                )

            local price =
                tonumber(
                    sv[prefix .. "Price"]
                )

            if width then
                tier.widthTiles =
                    math.floor(width)
            end

            if height then
                tier.heightTiles =
                    math.floor(height)
            end

            if price then
                tier.price =
                    math.floor(price)
            end

            local classLabel =
                tier.id == "small"
                and "Small"
                or (
                    tier.id == "medium"
                    and "Medium"
                    or "Large"
                )

            tier.label =
                classLabel ..
                " (" ..
                tostring(tier.widthTiles) ..
                "x" ..
                tostring(tier.heightTiles) ..
                ")"

        end

    end

    return tiers
end

------------------------------------------------------------
-- GET EXCAVATION SIZE TIER BY ID
------------------------------------------------------------

function ClaimConfig.GetExcavationSizeTierById(tierId)

    if type(tierId) ~= "string"
        or tierId == ""
    then
        return nil
    end

    local wantedId =
        string.lower(
            tierId
        )

    if not EXCAVATION_TIER_IDS[wantedId] then
        return nil
    end

    local tiers =
        ClaimConfig.GetExcavationSizeTiers()

    for _, tier in ipairs(tiers) do

        if type(tier) == "table"
            and type(tier.id) == "string"
            and string.lower(tier.id) == wantedId
        then
            return tier
        end

    end

    return nil
end

------------------------------------------------------------
-- COMMAND HANDLERS
------------------------------------------------------------

local function handleGetExcavationSizeTiers(player, _args)

    KIPN.Server.SendToPlayer(
        player,
        KIPN.Shared.ResponseEvents.EXCAVATION_SIZE_TIERS_DATA,
        {
            tiers = ClaimConfig.GetExcavationSizeTiers(),
        }
    )

    return true
end


------------------------------------------------------------
-- INITIALIZE  (driven by KIPN_GovServicesInit.lua's RegisterService)
------------------------------------------------------------

function ClaimConfig.InitializeGovExcavationTiers()

    if type(KIPN.Server.RegisterCommandHandler) == "function"
        and type(KIPN.Server.GetCommandHandler) == "function"
        and not KIPN.Server.GetCommandHandler(
            KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS
        )
    then
        -- GET_EXCAVATION_SIZE_TIERS is intentionally PUBLIC -- any
        -- authenticated player may view the available sizes/prices.
        KIPN.Server.RegisterCommandHandler(
            KIPN.Shared.Commands.GET_EXCAVATION_SIZE_TIERS,
            handleGetExcavationSizeTiers
        )
    end

    print("[KIPN GOV CLAIM CONFIG] Initialized.")
    return true
end

print("[KIPN] Government Services Claim Config loaded")
