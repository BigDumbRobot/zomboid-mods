-- Designated test zones. Players never create a zone: the server keeps one
-- zone of every kind the enabled mods need, at a fixed place chosen from the
-- game's own map (Sites.DEFAULTS), and makes each the first time it is
-- needed. A test that needs a zone moves the player into its site first (the
-- showcase does this for options marked with `site`), and the server only
-- ever uses the designated zone. An admin can move every site with "Set up
-- test sites here", which lays them out around where the admin stands; that
-- is also how a server on another map gets its sites.
--
-- KIPN zones (government, dealership, career services, events) are made here.
-- Zones of other mods are made by their suite, which registers a provider:
--   Sites.Provide(key, { label, layout(origin) -> rect, spot | nil, reason,
--       create(admin, rect) -> id | nil, reason, remove(admin, id),
--       available() -> boolean })
LilBubbySites = LilBubbySites or { providers = {}, order = {} }
local Sites = LilBubbySites

Sites.MODULE = "LilBubbySites"
Sites.TAG = "LilBubbySites"
Sites.NAME = "lilBubby test site: "
-- Where each KIPN zone goes, as its centre's offset from the admin and its
-- half-width. The row runs east; the events zone lies south of it. Together
-- with the suites' own sites the layout is about 110 tiles wide and 115 deep.
Sites.KIPN = {
    { key = "government", label = "Government desk", dx = 0, dy = 0, half = 4 },
    { key = "career_services", label = "Career Services", dx = 15, dy = 0, half = 4 },
    { key = "dealership", label = "Dealership", dx = 36, dy = 0, half = 10 },
    { key = "event", label = "Dynamic Events", dx = 40, dy = 60, half = 40 },
}
Sites.SETUP_HINT = "This map has no default place for it; an admin chooses one: Open Mod Showcase, Test sites, Move the test sites here."
-- ONE test site. Everything a test needs is inside a single field (Sites.FIELD),
-- and players spawn in the middle of it: the server's SpawnPoint must be the
-- field's spawn. The zones below are patches of that one field.
-- On the vanilla map it is open ground and one building on the north-east
-- edge of West Point, read off the map's tile data.
--   event            the riverside meadow north of downtown: under 2% of its
--                    middle 61 x 61 is bush or tree, and its middle 31 x 31 is bare
--   temple           bare grass on the meadow's west edge; players stand on its south side
--   dealership       grass south of the meadow, clear 11 x 11 middle for the test car
--   government       the grass corridor south of the dealership site
--   career_services  grass east of the dealership site
--   bonk             the ground between the dealership and career services sites
--   post_office      the small walled business at 12032,6735 to 12042,6749, and 3 tiles around it
Sites.DEFAULTS = { ["Muldraugh, KY"] = {
    event = { x1 = 11961, y1 = 6621, x2 = 12041, y2 = 6701, z = 0, spot = { x = 12001, y = 6661, z = 0 } },
    temple = { x1 = 11944, y1 = 6640, x2 = 11957, y2 = 6654, z = 0, spot = { x = 11950, y = 6654, z = 0 } },
    dealership = { x1 = 12003, y1 = 6705, x2 = 12023, y2 = 6725, z = 0, spot = { x = 12013, y = 6715, z = 0 } },
    government = { x1 = 12007, y1 = 6729, x2 = 12015, y2 = 6737, z = 0, spot = { x = 12011, y = 6733, z = 0 } },
    career_services = { x1 = 12054, y1 = 6713, x2 = 12062, y2 = 6721, z = 0, spot = { x = 12058, y = 6717, z = 0 } },
    bonk = { x1 = 12028, y1 = 6705, x2 = 12048, y2 = 6725, z = 0, spot = { x = 12038, y = 6715, z = 0 } },
    post_office = { x1 = 12029, y1 = 6732, x2 = 12045, y2 = 6752, z = 0, spot = { x = 12039, y = 6742, z = 0 } },
} }
-- The one test site per map: its bounds, and where players spawn (the bare
-- middle of the meadow). Every default zone above lies inside it.
Sites.FIELD = { ["Muldraugh, KY"] = { x1 = 11944, y1 = 6621, x2 = 12062, y2 = 6752, z = 0, spawn = { x = 12001, y = 6661, z = 0 } } }
-- Zones this version moved into the field: one the server made at its old
-- default place is removed and made again at the new one.
Sites.LAYOUT = 2
Sites.MOVED = { bonk = { x1 = 12049, y1 = 6810 } }
Sites.RETRY_MS = 10000     -- a zone that could not be made is tried again after this long
-- Stands in for an admin when the server makes a zone by itself: mods that
-- ask who is creating a zone are answered by this, never by a player.
Sites.OPERATOR = {
    getUsername = function() return "LilBubbyModTester" end,
    getAccessLevel = function() return "admin" end,
    getRole = function() return { hasAdminPower = function() return true end, hasCapability = function() return true end } end,
}

local function server() return type(isServer) == "function" and isServer() end
local function client() return type(isClient) == "function" and isClient() end

function Sites.Provide(key, provider)
    if not Sites.providers[key] then Sites.order[#Sites.order + 1] = key end
    provider.key = key
    Sites.providers[key] = provider
end

function Sites.Label(key)
    local provider = Sites.providers[key]
    return provider and provider.label or tostring(key)
end

function Sites.Missing(key)
    local why = Sites.failures and Sites.failures[key]
    return "The " .. Sites.Label(key) .. " test zone does not exist on this server yet"
        .. (why and (": " .. tostring(why.reason) .. ". The server tries again by itself.") or (". " .. Sites.SETUP_HINT))
end

-- Admins by the game's role or access level, or by KIPN's own list.
function Sites.IsAdmin(player)
    if not client() and not server() then return true end
    local ok, result = pcall(function()
        local role = player and player.getRole and player:getRole()
        if role and role.hasAdminPower and role:hasAdminPower() then return true end
        if client() then
            if type(isAdmin) == "function" and isAdmin() then return true end
            if type(getAccessLevel) == "function" and string.lower(tostring(getAccessLevel())) == "admin" then return true end
            local access = KIPN and KIPN.Client and KIPN.Client.AdminAccess
            return access ~= nil and type(access.GetAccessLevel) == "function" and access.GetAccessLevel() == "ADMIN"
        end
        if player and player.getAccessLevel and string.lower(tostring(player:getAccessLevel())) == "admin" then return true end
        local permissions = KIPN and KIPN.Server and KIPN.Server.Permissions
        return permissions ~= nil and type(permissions.ResolveAccessLevel) == "function"
            and permissions.ResolveAccessLevel(player) == "ADMIN"
    end)
    return ok and result == true
end

------------------------------------------------------------
-- SERVER (and single player): the sites themselves
------------------------------------------------------------

local function data()
    local stored = ModData.getOrCreate(Sites.TAG)
    stored.sites = stored.sites or {}
    return stored
end

local function registry() return KIPN and KIPN.Server and KIPN.Server.WorldRegistry end

local function kipnProvider(entry)
    return {
        label = entry.label,
        available = function()
            local WR = registry()
            return WR ~= nil and WR.RegisteredZoneTypes ~= nil and WR.RegisteredZoneTypes[entry.key] ~= nil
        end,
        layout = function(origin)
            local x, y = origin.x + entry.dx, origin.y + entry.dy
            return { x1 = x - entry.half, y1 = y - entry.half, x2 = x + entry.half, y2 = y + entry.half, z = origin.z },
                { x = x, y = y, z = origin.z }
        end,
        create = function(_, rect)
            local zone, reason = registry().CreateZoneFromCorners(entry.key, { x = rect.x1, y = rect.y1, z = rect.z },
                { x = rect.x2, y = rect.y2, z = rect.z }, { name = Sites.NAME .. entry.label, lilBubbyTest = true })
            if not zone then return nil, reason end
            return zone.id
        end,
        remove = function(_, id)
            local WR = registry()
            if WR and WR.GetZone(id) and WR.GetZone(id).active ~= false then WR.DeactivateZone(id) end
        end,
        exists = function(id)
            local WR = registry()
            local zone = WR and WR.GetZone(id)
            return zone ~= nil and zone.active ~= false
        end,
    }
end
for _, entry in ipairs(Sites.KIPN) do
    if not Sites.providers[entry.key] then Sites.Provide(entry.key, kipnProvider(entry)) end
end

local function syncKipn()
    if not (KIPN and KIPN.Server) then return end
    if KIPN.Server.BroadcastZoneSync then pcall(KIPN.Server.BroadcastZoneSync) end
    if KIPN.Server.Save then pcall(KIPN.Server.Save, "configuration") end
end

-- The world's map folder(s), as the server or the save names them.
local function mapName()
    local ok, name = pcall(function()
        if server() or client() then return getServerOptions():getOption("Map") end
        return getWorld():getMap()
    end)
    return ok and name and tostring(name) or "Muldraugh, KY"
end

-- Where the site goes when no admin has moved it: this map's default, or nil.
local function default(key)
    local map = mapName()
    for name, sites in pairs(Sites.DEFAULTS) do
        if map:find(name, 1, true) and sites[key] then return sites[key] end
    end
end

-- This map's one test site ({ x1, y1, x2, y2, z, spawn }), or nil.
function Sites.Field()
    local map = mapName()
    for name, field in pairs(Sites.FIELD) do
        if map:find(name, 1, true) then return field end
    end
end

-- nil when new characters spawn inside the test site, otherwise what to change.
function Sites.SpawnProblem()
    local field = Sites.Field()
    if not field or not (server() or client()) then return nil end
    local ok, text = pcall(function() return getServerOptions():getOption("SpawnPoint") end)
    local x, y = tostring(ok and text or ""):match("^%s*(%-?%d+)%s*,%s*(%-?%d+)")
    x, y = tonumber(x), tonumber(y)
    if x and y and x >= field.x1 and x <= field.x2 and y >= field.y1 and y <= field.y2 then return nil end
    return "Players do not spawn in the test site. Set SpawnPoint=" .. field.spawn.x .. "," .. field.spawn.y .. "," .. field.spawn.z
        .. " in the server settings (it is " .. tostring(ok and text or "unset") .. ")."
end

-- Forgets a zone the server made at a default place that has since moved, so
-- it is made again inside the field. Zones an admin placed are left alone.
local function migrate(stored)
    if stored.layout == Sites.LAYOUT then return end
    for key, was in pairs(Sites.MOVED) do
        local old = stored.sites[key]
        if old and not stored.origin and old.x1 == was.x1 and old.y1 == was.y1 then
            local provider = Sites.providers[key]
            if not provider then return end -- its suite has not registered yet; try again on the next call
            pcall(provider.remove, Sites.OPERATOR, old.id)
            stored.sites[key] = nil
            print("[" .. Sites.MODULE .. "] moving the " .. provider.label .. " test zone into the test site")
        end
    end
    stored.layout = Sites.LAYOUT
end

local function record(key, id, rect, spot)
    local z = rect.z or 0
    local site = { id = id, x1 = rect.x1, y1 = rect.y1, x2 = rect.x2, y2 = rect.y2, z = z,
        spot = spot or { x = math.floor((rect.x1 + rect.x2) / 2), y = math.floor((rect.y1 + rect.y2) / 2), z = z } }
    data().sites[key] = site
    return site
end

Sites.failures = {}

-- The designated site for `key` ({ id, x1, y1, x2, y2, z, spot }), or nil.
-- Its zone is made here, by the server, the first time it is asked for (or
-- again if it was removed behind the tester's back): at the place an admin
-- chose, else at this map's default.
function Sites.Get(key)
    local provider = Sites.providers[key]
    if not provider then return nil end
    migrate(data())
    local site = data().sites[key]
    if site then
        local ok, there = pcall(provider.exists, site.id)
        if not ok or there then return site end
    end
    local place = site or default(key)
    local usable, yes = pcall(provider.available)
    if not place or not (usable and yes) then return nil end
    local failed = Sites.failures[key]
    local now = getTimestampMs()
    if failed and now - failed.at < Sites.RETRY_MS then return nil end
    local made, id, reason = pcall(provider.create, Sites.OPERATOR, place)
    if not made or id == nil then
        Sites.failures[key] = { at = now, reason = made and reason or id }
        print("[" .. Sites.MODULE .. "] could not make the " .. provider.label .. " test zone: " .. tostring(made and reason or id))
        return nil
    end
    Sites.failures[key] = nil
    syncKipn()
    print("[" .. Sites.MODULE .. "] made the " .. provider.label .. " test zone " .. tostring(id)
        .. " at " .. place.x1 .. "," .. place.y1 .. " to " .. place.x2 .. "," .. place.y2)
    return record(key, id, place, place.spot)
end

function Sites.Inside(player, key)
    local site = Sites.Get(key)
    if not site then return false end
    local x, y = math.floor(player:getX()), math.floor(player:getY())
    return x >= site.x1 and x <= site.x2 and y >= site.y1 and y <= site.y2 and math.floor(player:getZ()) == site.z
end

-- nil when the player stands in the site, otherwise why the test cannot use it.
function Sites.Problem(player, key)
    if not Sites.Get(key) then return Sites.Missing(key) end
    if not Sites.Inside(player, key) then
        return "You are not in the " .. Sites.Label(key) .. " test zone. Start the test from the showcase, which moves you there."
    end
    return nil
end

-- A free square to stand on at the site's spot, or the spot itself while the
-- area is not loaded.
local function standing(site)
    local spot = site.spot
    for radius = 0, 6 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                if math.abs(dx) == radius or math.abs(dy) == radius then
                    local x, y = spot.x + dx, spot.y + dy
                    local square = getCell():getGridSquare(x, y, spot.z)
                    if square and x >= site.x1 and x <= site.x2 and y >= site.y1 and y <= site.y2
                        and square:TreatAsSolidFloor() and square:isFree(false) then
                        return { x = x, y = y, z = spot.z }
                    end
                end
            end
        end
    end
    return spot
end

-- Sends the player to the site. Returns { arrived = true }, or the spot with
-- the arrival allowance in ms, or { error }.
function Sites.Go(player, key)
    local site = Sites.Get(key)
    if not site then return { status = "BLOCKED", error = Sites.Missing(key) } end
    local rect = { x1 = site.x1, y1 = site.y1, x2 = site.x2, y2 = site.y2, z = site.z }
    if Sites.Inside(player, key) then return { arrived = true, rect = rect } end
    if player:getVehicle() then return { status = "BLOCKED", error = "Get out of the vehicle first." } end
    local spot = standing(site)
    return { x = spot.x, y = spot.y, z = spot.z, rect = rect,
        expected = LilBubbyTeleport.Order(player, spot.x, spot.y, spot.z) }
end

-- Moves the sites: lays every available one out around the admin, replacing
-- the earlier ones (the defaults included).
-- Returns { lines = { "PASS: ...", ... } } or { error }.
function Sites.SetUp(player)
    if not Sites.IsAdmin(player) then
        return { status = "BLOCKED", error = "Only an admin sets up the test sites. Everyone can use them once they exist." }
    end
    local stored = data()
    local origin = { x = math.floor(player:getX()), y = math.floor(player:getY()), z = math.floor(player:getZ()) }
    local lines = {}
    for _, key in ipairs(Sites.order) do
        local provider = Sites.providers[key]
        local ok, usable = pcall(provider.available)
        if not (ok and usable) then
            lines[#lines + 1] = "SKIP: " .. provider.label .. " (its mod is not enabled)"
        else
            local old = stored.sites[key]
            if old then pcall(provider.remove, player, old.id) end
            stored.sites[key] = nil
            local laid, rect, spot = pcall(provider.layout, origin, player)
            if not laid or not rect then
                lines[#lines + 1] = "FAIL: " .. provider.label .. ": " .. tostring(laid and spot or rect)
            else
                rect.z = rect.z or origin.z
                local made, id, reason = pcall(provider.create, player, rect)
                if made and id ~= nil then
                    record(key, id, rect, spot)
                    Sites.failures[key] = nil
                    lines[#lines + 1] = string.format("PASS: %s zone %s at %d,%d to %d,%d", provider.label, tostring(id),
                        rect.x1, rect.y1, rect.x2, rect.y2)
                else
                    lines[#lines + 1] = "FAIL: " .. provider.label .. ": " .. tostring(made and reason or id)
                end
            end
        end
    end
    stored.origin = origin
    syncKipn()
    print("[" .. Sites.MODULE .. "] set up by " .. tostring(player:getUsername()) .. " at " .. origin.x .. "," .. origin.y .. "," .. origin.z)
    return { lines = lines }
end

-- What exists, for the showcase.
function Sites.List()
    local list = {}
    for _, key in ipairs(Sites.order) do
        local provider = Sites.providers[key]
        local ok, usable = pcall(provider.available)
        if ok and usable then
            local site = Sites.Get(key)
            list[#list + 1] = { key = key, label = provider.label, ready = site ~= nil,
                x = site and site.spot.x, y = site and site.spot.y }
        end
    end
    return list
end

local OPS = { go = function(player, args) return Sites.Go(player, tostring(args.site)) end,
    setup = function(player) return Sites.SetUp(player) end,
    list = function() return { sites = Sites.List() } end }

function Sites.Op(player, command, args)
    local fn = OPS[command]
    if not fn then return { error = "unknown request " .. tostring(command) } end
    local ok, result = pcall(fn, player, type(args) == "table" and args or {})
    if not ok then return { error = tostring(result) } end
    return result or {}
end

-- The server makes its zones soon after it starts, so they are there before
-- anyone asks. Whatever cannot be made yet is made when it is first needed.
if (server() or not client()) and Events and Events.EveryOneMinute then
    local function makeAll()
        Events.EveryOneMinute.Remove(makeAll)
        local problem = Sites.SpawnProblem()
        if problem then print("[" .. Sites.MODULE .. "] " .. problem) end
        for _, key in ipairs(Sites.order) do pcall(Sites.Get, key) end
    end
    Events.EveryOneMinute.Add(makeAll)
end

if server() and Events and Events.OnClientCommand then
    Events.OnClientCommand.Add(function(module, command, player, args)
        if module ~= Sites.MODULE or not player or not OPS[command] then return end
        args = type(args) == "table" and args or {}
        local reply = Sites.Op(player, command, args)
        reply.op, reply.requestId, reply.playerID = command, args.requestId, player:getOnlineID()
        sendServerCommand(player, Sites.MODULE, "reply", reply)
    end)
end

------------------------------------------------------------
-- CLIENT: asking, and travelling to a site before a test
------------------------------------------------------------

Sites.RETRIES = 2          -- the move is ordered again this many times before giving up
Sites.GRACE_MS = 10000     -- past the server's arrival allowance
Sites.REPLY_MS = 20000
local pending, nextId = {}, 0
local trips = {}           -- player -> the trip under way

-- Asks the server (or runs it here in single player); done(reply).
function Sites.Ask(player, command, args, done)
    args = args or {}
    if not client() then done(Sites.Op(player, command, args)) return end
    nextId = nextId + 1
    args.requestId = nextId
    pending[nextId] = { done = done, deadline = getTimestampMs() + Sites.REPLY_MS, player = player, command = command, args = args }
    sendClientCommand(player, Sites.MODULE, command, args)
end

function Sites.Moving(player) return trips[player] ~= nil end

local function there(player, rect)
    local x, y = math.floor(player:getX()), math.floor(player:getY())
    return player:getCurrentSquare() ~= nil and x >= rect.x1 and x <= rect.x2 and y >= rect.y1 and y <= rect.y2
        and math.floor(player:getZ()) == rect.z
end

local function order(player, trip)
    Sites.Ask(player, "go", { site = trip.key }, function(reply)
        if trips[player] ~= trip then return end
        if reply.error then
            trips[player] = nil
            trip.done(false, reply.error)
        elseif reply.arrived then
            trips[player] = nil
            trip.done(true)
        else
            trip.rect = reply.rect
            trip.deadline = getTimestampMs() + (tonumber(reply.expected) or LilBubbyTeleport.SETTLE_MS) + Sites.GRACE_MS
        end
    end)
end

-- Moves the player into the site, then calls done(true) or done(false, why).
function Sites.Travel(player, key, done)
    local trip = { key = key, done = done, tries = 0 }
    trips[player] = trip
    order(player, trip)
end

if not server() and Events and Events.OnTick and Events.OnServerCommand then
    Events.OnTick.Add(function()
        local now
        for id, request in pairs(pending) do
            now = now or getTimestampMs()
            if now > request.deadline then
                pending[id] = nil
                request.done({ error = "The server did not answer the test site request." })
            end
        end
        for player, trip in pairs(trips) do
            now = now or getTimestampMs()
            if trip.rect and there(player, trip.rect) and not LilBubbyTeleport.Travelling(player) then
                trips[player] = nil
                trip.done(true)
            elseif trip.deadline and now > trip.deadline then
                trip.deadline = nil
                if trip.tries < Sites.RETRIES then
                    -- Ordered again rather than given up on.
                    trip.tries = trip.tries + 1
                    order(player, trip)
                else
                    trips[player] = nil
                    trip.done(false, "You did not arrive at the " .. Sites.Label(trip.key) .. " test zone.")
                end
            end
        end
    end)
    Events.OnServerCommand.Add(function(module, command, args)
        if module ~= Sites.MODULE or command ~= "reply" or type(args) ~= "table" then return end
        local request = pending[args.requestId]
        if not request or request.player:getOnlineID() ~= args.playerID then return end
        pending[args.requestId] = nil
        request.done(args)
    end)
end

return LilBubbySites
