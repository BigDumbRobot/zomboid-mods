-- DynamicEvents_KIPNCompat.lua
--
-- Pieces the event system used to get from KIPN before Dynamic Events
-- was split out, provided here when the current KIPN lacks them. Each
-- is only added if missing, so a KIPN that still has it wins.
--
--   * The "event" zone type. Event zones are ordinary WorldRegistry
--     zones of this type; without it registered, drawing an event zone
--     is rejected and starting an event fails with NOT_AN_EVENT_ZONE.
--   * Permissions.AuthorizeEventTier, the tiered check the runtime
--     and Director use (copied from KIPN's last pre-split build):
--       ADMIN      every category
--       MODERATOR  LIFECYCLE_BASIC (start/stop, add time, end)
--       STAFF      STAFF_TOOLS (announce, hint, spectate)
--       GM         GM_CONTROLS (spawn, difficulty, PvP, objective controls)
--       OBSERVER   VIEW
--     VIEW is shared by every non-USER tier.

if isClient() and not isServer() then return end

require "KIPN_WorldRegistry"
require "KIPN_Permissions"

local WorldRegistry = KIPN and KIPN.Server and KIPN.Server.WorldRegistry
if WorldRegistry and WorldRegistry.RegisterZoneType then
    WorldRegistry.RegisterZoneType("event", {
        label = "Event Zone",
        defaultCapabilities = {},
    })
end

local Permissions = KIPN and KIPN.Server and KIPN.Server.Permissions
if Permissions and not Permissions.AuthorizeEventTier then
    local EVENT_CATEGORY_TIERS = {
        VIEW = { OBSERVER = true, GM = true, STAFF = true, MODERATOR = true },
        LIFECYCLE_BASIC = { MODERATOR = true },
        STAFF_TOOLS = { STAFF = true },
        GM_CONTROLS = { GM = true },
    }

    -- Returns ok, tier. An unknown category fails closed.
    function Permissions.AuthorizeEventTier(player, category)
        local tier = Permissions.ResolveAccessLevel(player)
        if tier == "ADMIN" then return true, tier end
        local allowed = EVENT_CATEGORY_TIERS[category]
        return allowed ~= nil and allowed[tier] == true, tier
    end

    -- Which categories a tier can reach (for the Director panel's layout).
    function Permissions.GetEventTierCategories(tier)
        local result = {}
        for category, allowed in pairs(EVENT_CATEGORY_TIERS) do
            if tier == "ADMIN" or allowed[tier] then result[#result + 1] = category end
        end
        return result
    end
end
