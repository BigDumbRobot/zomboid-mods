require "KIPNCareers_Shared"

-- KIPNCareers_ZoneBridge
--
-- Thin adapter over KIPN.Server.WorldRegistry.
--   * Career zone types are real registered zone types. Career Services is
--     registered by KIPNCareers_Init.lua; a career adds its own with
--     RegisterZoneType, and admins draw either kind through the same
--     zone-editor calls -- no CreateZone monkey patching.
--   * Per-business zones: a `custom` KIPN zone auto-drawn over a storefront
--     building carrying the career's own capability, so its storefront menu
--     program only appears at that location.

local Shared = KIPNCareers.Shared
local ZoneBridge = KIPNCareers.ZoneBridge or {}
KIPNCareers.ZoneBridge = ZoneBridge
ZoneBridge._types = ZoneBridge._types or {}

local function log(level, message)
    Shared.Log("ZoneBridge", level, message)
end

function ZoneBridge.GetRegistry()
    return KIPN and KIPN.Server and KIPN.Server.WorldRegistry or nil
end

-- definition = { label = "Career Services", capabilities = { [capability] = true },
--                classificationField = "careerServices" }
-- Zones of this type are created with those capabilities. Registering the
-- same type again replaces its definition (safe on Lua reload).
function ZoneBridge.RegisterZoneType(zoneType, definition)
    if type(zoneType) ~= "string" or zoneType == "" or type(definition) ~= "table" then
        log("Error", "RegisterZoneType ignored: zoneType and definition are required")
        return false
    end
    local capabilities = type(definition.capabilities) == "table" and definition.capabilities or {}
    ZoneBridge._types[zoneType] = {
        label = Shared.Trim(definition.label, 64), capabilities = capabilities,
        classificationField = definition.classificationField,
    }
    local registry = ZoneBridge.GetRegistry()
    if registry and type(registry.RegisterZoneType) == "function" then
        registry.RegisterZoneType(zoneType, {
            label = ZoneBridge._types[zoneType].label,
            defaultCapabilities = capabilities,
            classificationField = definition.classificationField,
        })
    end
    log("Info", "Registered zone type=" .. zoneType)
    return true
end

function ZoneBridge.IsCareerType(zoneType)
    return zoneType ~= nil and ZoneBridge._types[zoneType] ~= nil
end

-- True when the terminal sits in a zone that grants `capability`.
function ZoneBridge.ComputerHasCapability(computerId, capability)
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.GetComputerCapabilities) ~= "function" then return false end
    return (registry.GetComputerCapabilities(computerId) or {})[capability] == true
end

function ZoneBridge.GetZones(zoneType, includeInactive)
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.GetZones) ~= "function" then return {} end
    return registry.GetZones(zoneType, includeInactive) or {}
end

function ZoneBridge.GetZonesAt(x, y, z, zoneType)
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.GetZonesAtPosition) ~= "function" then return {} end
    return registry.GetZonesAtPosition(x, y, z, zoneType) or {}
end

function ZoneBridge.Create(zoneType, cornerA, cornerB, name)
    log("Info", "Create type=" .. tostring(zoneType) .. " name=" .. tostring(name))
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.CreateZoneFromCorners) ~= "function" then
        return nil, "WORLD_REGISTRY_UNAVAILABLE"
    end
    local definition = ZoneBridge._types[zoneType]
    if not definition then return nil, "INVALID_ZONE_TYPE" end
    local cleanedName = Shared.Trim(name, 64)
    if cleanedName == "" then cleanedName = definition.label ~= "" and definition.label or "Career Zone" end
    local capabilities = {}
    for capability, granted in pairs(definition.capabilities) do capabilities[capability] = granted end
    return registry.CreateZoneFromCorners(
        zoneType,
        cornerA,
        cornerB,
        { name = cleanedName, label = cleanedName, category = "Careers", careerZoneType = zoneType },
        capabilities,
        nil
    )
end

function ZoneBridge.Update(zoneId, changes)
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.UpdateZone) ~= "function" then
        return nil, "WORLD_REGISTRY_UNAVAILABLE"
    end
    return registry.UpdateZone(zoneId, changes)
end

function ZoneBridge.SetActive(zoneId, active)
    local registry = ZoneBridge.GetRegistry()
    if not registry then return nil, "WORLD_REGISTRY_UNAVAILABLE" end
    if type(registry.SetZoneActive) == "function" then
        return registry.SetZoneActive(zoneId, active == true)
    end
    if type(registry.UpdateZone) == "function" then
        return registry.UpdateZone(zoneId, { active = active == true })
    end
    return nil, "ZONE_UPDATE_UNAVAILABLE"
end

-- rect = { x1, y1, x2, y2, z1, z2 } (building bounds from a career's server
-- module). `capability` is the career's own per-business capability string
-- (e.g. the Drug Dealer's Shared.Capabilities.BUSINESS) so this framework
-- helper stays career-agnostic; `label` defaults to "Storefront".
function ZoneBridge.CreateBusinessZone(rect, businessId, capability, label)
    log("Info", "CreateBusinessZone business=" .. tostring(businessId))
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.CreateZoneFromCorners) ~= "function" then
        return nil, "WORLD_REGISTRY_UNAVAILABLE"
    end
    if not capability then return nil, "CAPABILITY_REQUIRED" end
    local cleanedLabel = Shared.Trim(label, 64)
    if cleanedLabel == "" then cleanedLabel = "Storefront" end
    local zone, reason = registry.CreateZoneFromCorners(
        "custom",
        { x = rect.x1, y = rect.y1, z = rect.z1 or 0 },
        { x = rect.x2, y = rect.y2, z = rect.z2 or 8 },
        { name = cleanedLabel, label = cleanedLabel, category = "Careers", careerBusinessId = businessId },
        { [capability] = true },
        nil
    )
    if not zone then return nil, reason end
    return zone.id or zone
end

function ZoneBridge.RemoveBusinessZone(zoneId)
    if not zoneId then return true end
    -- WorldRegistry has no delete; deactivating removes it from capability
    -- resolution and the map.
    return ZoneBridge.SetActive(zoneId, false)
end

function ZoneBridge.OverlapsNoClaim(rect)
    local registry = ZoneBridge.GetRegistry()
    if not registry or type(registry.GetZones) ~= "function" then return false, nil end
    for _, zone in pairs(registry.GetZones(nil, false) or {}) do
        local geometry = zone.geometry or {}
        local metadata = zone.metadata or {}
        local capabilities = zone.capabilities or {}
        local blocks = zone.type == "no_claim"
            or zone.type == "do_not_claim"
            or metadata.noClaim == true
            or metadata.doNotClaim == true
            or metadata.claimPolicy == "deny"
            or capabilities["claim.block"] == true
            or capabilities["property.block"] == true
        if blocks then
            local gx1 = tonumber(geometry.x1)
            local gy1 = tonumber(geometry.y1)
            local gx2 = tonumber(geometry.x2)
            local gy2 = tonumber(geometry.y2)
            if gx1 and gy1 and gx2 and gy2
                and math.max(rect.x1, math.min(gx1, gx2)) <= math.min(rect.x2, math.max(gx1, gx2))
                and math.max(rect.y1, math.min(gy1, gy2)) <= math.min(rect.y2, math.max(gy1, gy2))
            then
                return true, zone
            end
        end
    end
    return false, nil
end

return ZoneBridge
