-- KIPNCareers_Services.lua  (framework core)
--
-- The commands the framework answers itself, so they work whichever careers
-- are installed:
--   * careers.inbox / careers.markInboxRead -- the shared inbox every career
--     files its notices in (shown as MY BUSINESS on the Announcements screen);
--   * careers.adminCreateZone / adminUpdateZone / adminToggleZone -- the
--     admin editor for Career Services zones and any zone type a career
--     registered with ZoneBridge.RegisterZoneType;
--   * careers.closeStorefront -- close a storefront in any career (its owner
--     or an admin).
-- Answers go out on Shared.Events.RESULT.

if isClient() and not isServer() then return end

require "KIPNCareers_Shared"
require "KIPNCareers_Host"
require "KIPNCareers_ZoneBridge"
require "KIPNCareers_Storefronts"
require "KIPNCareers_Careers"

local Shared = KIPNCareers.Shared
local Host = KIPNCareers.Host
local ZoneBridge = KIPNCareers.ZoneBridge
local Storefronts = KIPNCareers.Storefronts
local Careers = KIPNCareers.Careers
local Services = KIPNCareers.Services or {}
KIPNCareers.Services = Services

local initialized = false

local function log(level, message)
    Shared.Log("Services", level, message)
end

local function result(player, action, ok, code, message, extra)
    log(ok and "Info" or "Warn", "result action=" .. tostring(action) .. " code=" .. tostring(code) .. " player=" .. Host.Username(player))
    local payload = type(extra) == "table" and extra or {}
    payload.action = action
    payload.ok = ok == true
    payload.code = code
    payload.message = message
    return Host.Send(player, Shared.Events.RESULT, payload)
end

------------------------------------------------------------
-- INBOX
------------------------------------------------------------

local function handleInbox(player, args)
    local ownerKey = Host.Identity(player)
    if not Host.Root() or not ownerKey then return false, "STATE_UNAVAILABLE" end
    Host.Send(player, Shared.Events.INBOX, {
        requestId = args and args.requestId,
        notifications = Careers.Inbox(ownerKey),
        hasBusiness = #Storefronts.ForOwner(ownerKey) > 0,
    })
    return true
end

local function handleMarkInboxRead(player, args)
    local ownerKey = Host.Identity(player)
    if not Host.Root() or not ownerKey then return false, "STATE_UNAVAILABLE" end
    local ids = type(args and args.ids) == "table" and args.ids or nil
    local wanted = {}
    if ids then
        for _, id in ipairs(ids) do wanted[tostring(id)] = true end
    end
    local changed = false
    for _, notification in ipairs(Careers.Inbox(ownerKey)) do
        if notification.unread and (not ids or wanted[tostring(notification.id)]) then
            notification.unread = false
            changed = true
        end
    end
    if changed then Host.Save() end
    return handleInbox(player, args)
end

------------------------------------------------------------
-- ADMIN ZONES
------------------------------------------------------------

local function adminCreateZone(player, args)
    local action = "adminCreateZone"
    if not Host.IsAdmin(player) then result(player, action, false, "ADMIN_REQUIRED", "Administrator access is required.") return true end
    args = args or {}
    if not ZoneBridge.IsCareerType(args.zoneType) then result(player, action, false, "INVALID_ZONE_TYPE", "Unknown Career zone type.") return true end
    local zone, reason = ZoneBridge.Create(args.zoneType, args.cornerA, args.cornerB, args.name)
    result(player, action, zone ~= nil, reason, zone and "Career zone created." or "Zone creation failed: " .. tostring(reason), { zone = zone })
    return true
end

local function adminUpdateZone(player, args)
    local action = "adminUpdateZone"
    if not Host.IsAdmin(player) then result(player, action, false, "ADMIN_REQUIRED", "Administrator access is required.") return true end
    args = args or {}
    local changes = type(args.changes) == "table" and args.changes or {}
    changes.type = nil
    if changes.metadata then
        changes.metadata.name = Shared.Trim(changes.metadata.name or changes.metadata.label, 64)
        changes.metadata.label = changes.metadata.name
        changes.metadata.category = "Careers"
    end
    local zone, reason = ZoneBridge.Update(args.zoneId, changes)
    result(player, action, zone == true, reason, zone and "Career zone updated." or "Zone update failed: " .. tostring(reason), { success = zone == true })
    return true
end

local function adminToggleZone(player, args)
    local action = "adminToggleZone"
    if not Host.IsAdmin(player) then result(player, action, false, "ADMIN_REQUIRED", "Administrator access is required.") return true end
    args = args or {}
    local zone, reason = ZoneBridge.SetActive(args.zoneId, args.active == true)
    result(player, action, zone ~= nil and zone ~= false, reason, zone and "Career zone state updated." or "Zone state update failed: " .. tostring(reason), { zone = zone })
    return true
end

------------------------------------------------------------
-- STOREFRONTS
------------------------------------------------------------

-- args = { careerId = , storefrontId = }
local function handleCloseStorefront(player, args)
    local action = "closeStorefront"
    args = args or {}
    local career = Careers.Get(tostring(args.careerId or ""))
    local record = career and career:Storefronts()[tostring(args.storefrontId or "")]
    if not record or record.active == false then
        result(player, action, false, "STOREFRONT_NOT_FOUND", "That storefront is not open.") return true
    end
    local ownerKey = Host.Identity(player)
    if record.ownerKey ~= ownerKey and not Host.IsAdmin(player) then
        result(player, action, false, "NOT_YOUR_STOREFRONT", "Only the owner or an administrator can close a storefront.") return true
    end
    local ok, code = career:CloseStorefront(record.id, ownerKey)
    result(player, action, ok, ok and "STOREFRONT_CLOSED" or code,
        ok and "The storefront was closed." or "The storefront could not be closed: " .. tostring(code),
        { careerId = career.id, storefrontId = record.id })
    return true
end

------------------------------------------------------------
-- ROUTER
------------------------------------------------------------

local handlers = {
    [Shared.Commands.INBOX] = handleInbox,
    [Shared.Commands.MARK_INBOX_READ] = handleMarkInboxRead,
    [Shared.Commands.ADMIN_CREATE_ZONE] = adminCreateZone,
    [Shared.Commands.ADMIN_UPDATE_ZONE] = adminUpdateZone,
    [Shared.Commands.ADMIN_TOGGLE_ZONE] = adminToggleZone,
    [Shared.Commands.CLOSE_STOREFRONT] = handleCloseStorefront,
}

local sessionCommands = {
    [Shared.Commands.ADMIN_CREATE_ZONE] = true,
    [Shared.Commands.ADMIN_UPDATE_ZONE] = true,
    [Shared.Commands.ADMIN_TOGGLE_ZONE] = true,
    [Shared.Commands.CLOSE_STOREFRONT] = true,
}

function Services.Initialize()
    if initialized then return true end
    if not KIPN or not KIPN.Server or type(KIPN.Server.RegisterCommandHandler) ~= "function" or not Host.Root() then
        return false
    end
    for command, handler in pairs(handlers) do
        if not KIPN.Server.GetCommandHandler or not KIPN.Server.GetCommandHandler(command) then
            local guarded = function(player, args)
                if sessionCommands[command] and not Host.HasAuthenticatedSession(player) then
                    result(player, command, false, "AUTHENTICATION_REQUIRED", "Log in to KIPN before using this Career Services action.")
                    return true
                end
                return handler(player, args)
            end
            if not KIPN.Server.RegisterCommandHandler(command, guarded) then
                log("Error", "Failed to register command " .. tostring(command))
                return false
            end
        end
    end
    initialized = true
    log("Info", "Careers Framework services initialized api=" .. tostring(Shared.API_VERSION))
    return true
end

Careers.Bootstrap(Services.Initialize)

return Services
