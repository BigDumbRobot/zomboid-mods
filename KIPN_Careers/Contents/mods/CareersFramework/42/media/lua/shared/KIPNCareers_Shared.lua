-- KIPNCareers_Shared.lua  (framework core)
--
-- Cross-career primitives only. A career add-on (CareersDrugDealer,
-- CareersMechanic, or a third-party one) requires this file and keeps its
-- own contract in its own table (KIPNCareers.Mechanic, KIPNCareers.Dealer)
-- -- see KIPNCareers_MechanicShared.lua for the pattern. Nothing
-- career-specific (commands, events, item tokens, permissions, order
-- status) belongs here.

KIPNCareers = KIPNCareers or {}

local Shared = KIPNCareers.Shared or {}
KIPNCareers.Shared = Shared

-- Raised when the framework gains something careers rely on. A career checks
-- it before loading so an older framework turns the career off cleanly
-- instead of failing half way through a file.
Shared.API_VERSION = 2

-- The KIPN command-router module name every career add-on sends/receives on.
Shared.MODULE = "KIPN"

-- The one zone type and capability every career's license purchase relies on.
Shared.ZoneTypes = Shared.ZoneTypes or {}
Shared.ZoneTypes.CAREER_SERVICES = "career_services"

Shared.Capabilities = Shared.Capabilities or {}
Shared.Capabilities.CAREER_SERVICES = "career.services"

-- The one physical flyer item type every career's flyer queue re-uses;
-- per-career ModData fields (kipnCareersXxx vs kipnMechXxx) distinguish them.
Shared.Items = Shared.Items or {}
Shared.Items.FLYER = "KIPNCareers.BusinessFlyer"

-- Cross-career sandbox defaults (currency + flyer distribution). A career's
-- own Shared module adds its own Defaults fields onto this same table.
Shared.Defaults = Shared.Defaults or {}
Shared.Defaults.CURRENCY_ITEM_TYPE = "Base.Money"
Shared.Defaults.CURRENCY_ITEM_VALUE = 1
Shared.Defaults.FLYERS_PER_RESTART = 4
Shared.Defaults.FLYER_CHANCE_PERCENT = 12

-- Threats (server-authoritative thieves / raiders / customers; see
-- KIPNCareers_Threats.lua).
Shared.Defaults.THREATS_ENABLED = true
Shared.Defaults.THREAT_FREQUENCY_PERCENT = 100
Shared.Defaults.THREAT_MIN_CALM_HOURS = 18
Shared.Defaults.THREAT_MAX_CALM_HOURS = 60
Shared.Defaults.THREAT_GRACE_HOURS = 24
Shared.Defaults.THREAT_MAX_LOSS_PERCENT = 25
Shared.Defaults.THREAT_OWNER_RADIUS = 60

-- Server -> client display-only events. The client never decides anything
-- about a threat; it only draws the line the server tells it to.
Shared.ThreatEvents = Shared.ThreatEvents or {}
Shared.ThreatEvents.SAY = "careers.threats.say"

-- Commands the framework itself answers, for every career: the shared inbox,
-- the Career Services zone editor and closing a storefront.
Shared.Commands = Shared.Commands or {}
Shared.Commands.INBOX = "careers.inbox"
Shared.Commands.MARK_INBOX_READ = "careers.markInboxRead"
Shared.Commands.ADMIN_CREATE_ZONE = "careers.adminCreateZone"
Shared.Commands.ADMIN_UPDATE_ZONE = "careers.adminUpdateZone"
Shared.Commands.ADMIN_TOGGLE_ZONE = "careers.adminToggleZone"
Shared.Commands.CLOSE_STOREFRONT = "careers.closeStorefront"

Shared.Events = Shared.Events or {}
Shared.Events.INBOX = "kipnCareers.inbox"
Shared.Events.INBOX_CHANGED = "kipnCareers.inboxChanged"
Shared.Events.RESULT = "kipnCareers.result"

function Shared.Log(scope, level, message)
    local text = "[KIPNCareers][" .. tostring(scope or "Shared") .. "][" .. tostring(level or "INFO") .. "] " .. tostring(message or "")
    local logger = KIPN and KIPN.Logger
    if logger and type(logger.Create) == "function" then
        local ok, instance = true, Shared._logger
        if not instance then
            ok, instance = pcall(logger.Create, "KIPNCareers")
            if ok then Shared._logger = instance end
        end
        if ok and instance then
            local method = instance[level] or instance.Info
            if type(method) == "function" then
                local sent = pcall(method, instance, text)
                if sent then return end
            end
        end
    end
    print(text)
end

function Shared.Clamp(value, minimum, maximum)
    value = tonumber(value) or minimum
    return math.max(minimum, math.min(maximum, value))
end

function Shared.Trim(value, maximum)
    local text = tostring(value or "")
    text = string.gsub(text, "[%z\1-\31\127]", " ")
    text = string.gsub(text, "<", "(")
    text = string.gsub(text, ">", ")")
    text = string.gsub(text, "^%s+", "")
    text = string.gsub(text, "%s+$", "")
    if maximum and string.len(text) > maximum then
        text = string.sub(text, 1, maximum)
    end
    return text
end

return Shared
