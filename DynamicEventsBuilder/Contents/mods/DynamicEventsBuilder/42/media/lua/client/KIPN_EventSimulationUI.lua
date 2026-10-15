-- KIPN_EventSimulationUI.lua
--
-- The admin's side of Simulate <event> (server/KIPN_EventSimulationService.lua).
--
--   * A guide panel along the bottom of the screen: every step of the
--     event in order (the current one marked), what this step shows,
--     and the three choices: OK (next step), Edit (pause here and open
--     the Event Studio on the matching step), Cancel (clean up and go
--     back). While editing: Resume (replay this step with the changes)
--     and Cancel. It fades like the other always-on panels.
--   * Every hotspot glows on the floor in its kind's colour; zombie
--     spawns and ambushes glow red, bandit places magenta, and the
--     hotspot this step is about pulses under a light. The zone's edge
--     glows orange.
--   * Zombies nearby are outlined, as in combat: red, bandits magenta.
--   * A demo fire is only a flickering orange light: nothing burns.
--   * The admin is invisible and unhurt for the whole simulation.
--   * Staff invited to someone else's simulation get a short invitation
--     with OK (taken to it) and Cancel (stay out; it carries on without
--     them). Guests see the same panel with only Leave: the host moves
--     the steps on.
--
-- Everything here is local to this client and undone when it ends.

if isServer() and not isClient() then return end

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "DynamicEvents_Shared"

KIPN_EventSimulationUI = ISPanel:derive("KIPN_EventSimulationUI")
local UI = KIPN_EventSimulationUI

UI.REFRESH_MS = 500
UI.OUTLINE_RADIUS = 45
UI.MAX_FILL_TILES = 900
UI.WIDTH = 760

local ZOMBIE_COLOR = { 1.0, 0.15, 0.15 }
local ZONE_COLOR = { 1.0, 0.55, 0.15 }
local GOLD = { 1.0, 0.82, 0.3 }

local function now() return getTimestampMs() end

local function Shared() return KIPN and KIPN.Shared or {} end

local function colorFor(hotspotType)
    return (Shared().EventHotspotColors or {})[hotspotType] or { 1, 1, 1 }
end

local function send(command, args)
    local name = Shared().Commands and Shared().Commands[command]
    if name then sendClientCommand("KIPN", name, args or {}) end
end

local function wrap(text, width, font)
    local manager = getTextManager()
    local lines, current = {}, ""
    for word in tostring(text or ""):gmatch("%S+") do
        local candidate = current == "" and word or (current .. " " .. word)
        if current ~= "" and manager:MeasureStringX(font, candidate) > width then
            lines[#lines + 1] = current
            current = word
        else
            current = candidate
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

------------------------------------------------------------
-- VISUAL AIDS
------------------------------------------------------------

local aids = { floors = {}, outlined = {}, lights = {}, fireLights = {} }
UI.aids = aids

local function playerIndex()
    local player = getPlayer()
    return player and player:getPlayerNum() or 0
end

local function floorAt(x, y, z)
    local cell = getCell()
    local square = cell and cell:getGridSquare(x, y, z)
    return square and square:getFloor() or nil
end

local function glow(object, color, alpha)
    local index = playerIndex()
    pcall(function()
        object:setHighlighted(index, true, false)
        object:setHighlightColor(index, color[1], color[2], color[3], alpha)
    end)
    aids.floors[object] = true
end

local function clearFloors()
    local index = playerIndex()
    for object in pairs(aids.floors) do pcall(function() object:setHighlighted(index, false, false) end) end
    aids.floors = {}
end

local function clearOutlines()
    for zombie in pairs(aids.outlined) do pcall(function() zombie:unsetOutlineHighlight() end) end
    aids.outlined = {}
end

local function removeLight(light)
    pcall(function() getCell():removeLamppost(light) end)
end

local function clearLights()
    for _, light in ipairs(aids.lights) do removeLight(light) end
    for _, light in ipairs(aids.fireLights) do removeLight(light) end
    aids.lights, aids.fireLights = {}, {}
end

local function addLight(x, y, z, color, radius)
    local ok, light = pcall(function()
        local l = IsoLightSource.new(x, y, z, color[1], color[2], color[3], radius)
        getCell():addLamppost(l)
        return l
    end)
    return ok and light or nil
end

-- Floor tiles of a rectangle: all of it if small, else its edge.
local function eachTile(x1, y1, x2, y2, visit)
    local fill = (x2 - x1 + 1) * (y2 - y1 + 1) <= UI.MAX_FILL_TILES
    for x = x1, x2 do
        for y = y1, y2 do
            if fill or x == x1 or x == x2 or y == y1 or y == y2 then visit(x, y) end
        end
    end
end

-- Re-applied every REFRESH_MS: squares load as the admin arrives.
function UI.RefreshAids(data)
    if not data then return end
    local player = getPlayer()
    if not player then return end
    local px, py = player:getX(), player:getY()
    local pulse = 0.55 + 0.45 * math.abs(math.sin(now() / 350))
    for _, hotspot in ipairs(data.hotspots or {}) do
        if hotspot.x1 and math.abs((hotspot.x1 + hotspot.x2) / 2 - px) < 90 and math.abs((hotspot.y1 + hotspot.y2) / 2 - py) < 90 then
            local color = colorFor(hotspot.type)
            eachTile(hotspot.x1, hotspot.y1, hotspot.x2, hotspot.y2, function(x, y)
                local floor = floorAt(x, y, hotspot.z or 0)
                if floor then glow(floor, color, hotspot.focus and pulse or 0.55) end
            end)
        end
    end
    local zone = data.zone
    if zone and zone.x1 then
        for x = zone.x1, zone.x2 do
            for _, y in ipairs({ zone.y1, zone.y2 }) do
                if math.abs(x - px) < 70 and math.abs(y - py) < 70 then
                    local floor = floorAt(x, y, zone.z1 or 0)
                    if floor then glow(floor, ZONE_COLOR, 0.7) end
                end
            end
        end
        for y = zone.y1, zone.y2 do
            for _, x in ipairs({ zone.x1, zone.x2 }) do
                if math.abs(x - px) < 70 and math.abs(y - py) < 70 then
                    local floor = floorAt(x, y, zone.z1 or 0)
                    if floor then glow(floor, ZONE_COLOR, 0.7) end
                end
            end
        end
    end
    -- Outline zombies, bandits in their own colour.
    local bandits = {}
    for _, id in ipairs(data.bandits or {}) do if id ~= -1 then bandits[id] = true end end
    local index = playerIndex()
    local zombies = getCell() and getCell():getZombieList()
    for i = 0, (zombies and zombies:size() or 0) - 1 do
        local zombie = zombies:get(i)
        local dx, dy = zombie:getX() - px, zombie:getY() - py
        if dx * dx + dy * dy <= UI.OUTLINE_RADIUS * UI.OUTLINE_RADIUS then
            local okId, id = pcall(function() return zombie:getOnlineID() end)
            local color = (okId and bandits[id]) and (Shared().EventBanditColor or { 1, 0.3, 0.75 }) or ZOMBIE_COLOR
            pcall(function()
                zombie:setOutlineHighlight(index, true)
                zombie:setOutlineHighlightCol(index, color[1], color[2], color[3], 1)
            end)
            aids.outlined[zombie] = true
        end
    end
    -- Demo fires flicker.
    for _, light in ipairs(aids.fireLights) do removeLight(light) end
    aids.fireLights = {}
    for _, fire in ipairs(data.fires or {}) do
        local light = addLight(fire.x, fire.y, fire.z or 0, { 1.0, 0.35 + ZombRand(20) / 100, 0.05 }, 5 + ZombRand(3))
        if light then aids.fireLights[#aids.fireLights + 1] = light end
    end
end

-- New step: the focus hotspot gets a light of its own colour.
function UI.PlaceFocusLight(data)
    for _, light in ipairs(aids.lights) do removeLight(light) end
    aids.lights = {}
    for _, hotspot in ipairs(data.hotspots or {}) do
        if hotspot.focus and hotspot.x1 then
            local light = addLight(math.floor((hotspot.x1 + hotspot.x2) / 2), math.floor((hotspot.y1 + hotspot.y2) / 2), hotspot.z or 0,
                colorFor(hotspot.type), 6)
            if light then aids.lights[#aids.lights + 1] = light end
        end
    end
end

function UI.ClearAids()
    clearFloors()
    clearOutlines()
    clearLights()
end

-- Invisible and unhurt while it runs; restored after.
local function cloak(on)
    local player = getPlayer()
    if not player then return end
    if on then
        if UI.saved then return end
        local okI, invisible = pcall(function() return player:isInvisible() end)
        local okG, god = pcall(function() return player:isGodMod() end)
        UI.saved = { invisible = okI and invisible or false, god = okG and god or false }
        pcall(function() player:setInvisible(true) end)
        pcall(function() player:setGodMod(true) end)
    elseif UI.saved then
        local saved = UI.saved
        UI.saved = nil
        pcall(function() player:setInvisible(saved.invisible) end)
        pcall(function() player:setGodMod(saved.god) end)
    end
    if type(sendPlayerExtraInfo) == "function" then pcall(sendPlayerExtraInfo, player) end
end

------------------------------------------------------------
-- PANEL
------------------------------------------------------------

function UI:new()
    local width = math.min(UI.WIDTH, getCore():getScreenWidth() - 40)
    local height = 200
    local o = ISPanel.new(self, math.floor((getCore():getScreenWidth() - width) / 2), getCore():getScreenHeight() - height - 90, width, height)
    o.moveWithMouse = true
    o.backgroundColor = { r = 0.05, g = 0.06, b = 0.09, a = 0.85 }
    o.borderColor = { r = 0.75, g = 0.45, b = 1.0, a = 0.9 }
    o.data = nil
    return o
end

local function button(self, title, callback, tooltip)
    local b = ISButton:new(0, 0, 90, 26, title, self, callback)
    b:initialise()
    b.tooltip = tooltip
    self:addChild(b)
    return b
end

function UI:createChildren()
    ISPanel.createChildren(self)
    self.okButton = button(self, "OK", UI.onOk, "Next step")
    self.editButton = button(self, "Edit", UI.onEdit, "Pause here and change the event in the Studio")
    self.cancelButton = button(self, "Cancel", UI.onCancel, "Stop, remove everything the simulation made and go back")
    self.okButton.backgroundColor = { r = 0.15, g = 0.4, b = 0.18, a = 1 }
    self.cancelButton.backgroundColor = { r = 0.45, g = 0.12, b = 0.12, a = 1 }
end

-- A guest in someone else's simulation.
local function isGuest(data)
    local player = getPlayer()
    local ok, me = pcall(function() return player:getUsername() end)
    return data.admin ~= nil and ok and me ~= nil and me ~= data.admin
end

function UI:setData(data)
    local newStep = not self.data or self.data.index ~= data.index or self.data.key ~= data.key
    self.data = data
    self.guest = isGuest(data)
    self.lastWakeAt = now()
    self.okButton:setTitle(data.editing and "Resume" or (data.index >= data.total and "Finish" or "OK"))
    self.okButton.tooltip = data.editing and "Replay this step with your changes" or (data.index >= data.total and "End the simulation" or "Next step")
    self.okButton:setVisible(not self.guest)
    self.editButton:setVisible(not data.editing and not self.guest)
    self.cancelButton:setTitle(self.guest and "Leave" or "Cancel")
    self.cancelButton.tooltip = self.guest and "Leave the simulation; it carries on without you"
        or "Stop, remove everything the simulation made and go back"
    if newStep then UI.PlaceFocusLight(data) end
end

function UI:onOk()
    if not self.data then return end
    send("EVENT_SIMULATE_STEP", { id = self.data.id, choice = self.data.editing and "RESUME" or "OK" })
end

function UI:onEdit()
    if not self.data then return end
    send("EVENT_SIMULATE_STEP", { id = self.data.id, choice = "EDIT" })
    if KIPN_EventStudioUI and KIPN_EventStudioUI.OpenAt then
        KIPN_EventStudioUI.OpenAt(self.data.id, self.data.studioStep)
    end
end

function UI:onCancel()
    if not self.data then return end
    send("EVENT_SIMULATE_STEP", { id = self.data.id, choice = "CANCEL" })
end

function UI:prerender()
    local data = self.data
    if not data then return end
    local hud = KIPN_EventPlayerHUD
    local alpha = hud and hud.FadeAlpha and hud.FadeAlpha(self) or 1
    self.backgroundColor.a = 0.85 * alpha
    self.borderColor.a = 0.9 * alpha
    for _, b in ipairs({ self.okButton, self.editButton, self.cancelButton }) do
        if hud and hud.FadeButton then hud.FadeButton(b, alpha) end
    end
    ISPanel.prerender(self)

    local manager = getTextManager()
    local small, medium = UIFont.Small, UIFont.Medium
    local lineHeight = manager:getFontHeight(small) + 2
    local listWidth = math.floor(self.width * 0.32)
    local x2 = listWidth + 16
    local textWidth = self.width - x2 - 10

    -- The step list, scrolled to keep the current step in view.
    local rows = math.floor((self.height - 12) / lineHeight)
    local first = math.max(1, math.min((data.index or 1) - math.floor(rows / 2), #(data.steps or {}) - rows + 1))
    for row = 0, rows - 1 do
        local index = first + row
        local title = data.steps and data.steps[index]
        if title then
            local current = index == data.index
            local color = current and GOLD or (index < data.index and { 0.5, 0.75, 0.5 } or { 0.65, 0.65, 0.7 })
            local text = (index < data.index and "v " or (current and "> " or "  ")) .. index .. ". " .. title
            while manager:MeasureStringX(small, text) > listWidth and #text > 4 do text = text:sub(1, -5) .. "..." end
            self:drawText(text, 8, 6 + row * lineHeight, color[1], color[2], color[3], alpha, small)
        end
    end
    self:drawRect(listWidth + 8, 6, 1, self.height - 12, 0.5 * alpha, 0.6, 0.5, 0.8)

    local y = 6
    local head = "Simulating " .. tostring(data.name) .. "   |   step " .. tostring(data.index) .. " of " .. tostring(data.total)
    self:drawText(head, x2, y, 0.75, 0.72, 0.85, alpha, small)
    y = y + lineHeight
    self:drawText(tostring(data.title or ""), x2, y, GOLD[1], GOLD[2], GOLD[3], alpha, medium)
    y = y + manager:getFontHeight(medium) + 4
    local body = data.editing and (self.guest and (tostring(data.admin) .. " has paused to edit the event. It carries on when they press Resume.")
        or "Paused for editing. Change anything in the Event Studio and save; then press Resume to play this step again with your changes.")
        or tostring(data.text or "")
    if self.guest and not data.editing then body = body .. "  (" .. tostring(data.admin) .. " moves it on.)" end
    for _, line in ipairs(wrap(body, textWidth, small)) do
        if y + lineHeight > self.height - 36 then break end
        self:drawText(line, x2, y, 0.92, 0.92, 0.92, alpha, small)
        y = y + lineHeight
    end
    local by = self.height - 32
    -- Who joined, opted out or left (for the host), for 10 seconds.
    if self.guestNote and now() - (self.guestNoteAt or 0) < 10000 then
        self:drawText(self.guestNote, x2, by + 6, 0.55, 0.85, 1, alpha, small)
    end
    self.cancelButton:setX(self.width - 100); self.cancelButton:setY(by)
    if self.guest then return end
    self.editButton:setX(self.width - 196); self.editButton:setY(by)
    self.okButton:setX(data.editing and self.width - 196 or self.width - 292); self.okButton:setY(by)
end

function UI.Show(data)
    if not UI.instance then
        UI.instance = UI:new()
        UI.instance:initialise()
        UI.instance:addToUIManager()
        -- addToUIManager builds the buttons; make sure before first use.
        if not UI.instance.okButton then UI.instance:createChildren() end
    end
    UI.instance:setVisible(true)
    UI.instance:setData(data)
    return UI.instance
end

function UI.Close()
    UI.ClearAids()
    cloak(false)
    if UI.instance then
        UI.instance:setVisible(false)
        UI.instance:removeFromUIManager()
        UI.instance = nil
    end
    UI.current = nil
end

function UI.OnSimulation(data)
    if data.ended then
        UI.Close()
        return
    end
    UI.current = data
    cloak(true)
    clearFloors()
    clearOutlines()
    UI.Show(data)
    UI.RefreshAids(data)
end

------------------------------------------------------------
-- INVITATION (someone else's simulation)
------------------------------------------------------------

KIPN_EventSimulationInvite = ISPanel:derive("KIPN_EventSimulationInvite")
local Invite = KIPN_EventSimulationInvite
UI.Invite = Invite

function Invite:new(data)
    local width, height = 420, 140
    local o = ISPanel.new(self, math.floor((getCore():getScreenWidth() - width) / 2), math.floor(getCore():getScreenHeight() * 0.3), width, height)
    o.backgroundColor = { r = 0.05, g = 0.06, b = 0.09, a = 0.95 }
    o.borderColor = { r = 0.75, g = 0.45, b = 1.0, a = 0.9 }
    o.data = data
    o.moveWithMouse = true
    return o
end

function Invite:createChildren()
    ISPanel.createChildren(self)
    self.okButton = ISButton:new(self.width - 196, self.height - 34, 90, 26, "OK", self, Invite.onOk)
    self.okButton:initialise()
    self.okButton.tooltip = "Join: you are taken to the simulation"
    self:addChild(self.okButton)
    self.cancelButton = ISButton:new(self.width - 100, self.height - 34, 90, 26, "Cancel", self, Invite.onCancel)
    self.cancelButton:initialise()
    self.cancelButton.tooltip = "Stay out; it carries on without you"
    self:addChild(self.cancelButton)
end

function Invite.Text(data)
    return tostring(data.host) .. " is running a simulation of " .. tostring(data.name) .. " (" .. tostring(data.total or "?")
        .. " steps) and invites you to watch. OK takes you there; you will be invisible and unhurt until it ends or you leave. Cancel to stay out."
end

function Invite:prerender()
    ISPanel.prerender(self)
    self:drawText("Simulation invitation", 10, 8, GOLD[1], GOLD[2], GOLD[3], 1, UIFont.Medium)
    local y = 8 + getTextManager():getFontHeight(UIFont.Medium) + 4
    for _, line in ipairs(wrap(Invite.Text(self.data), self.width - 20, UIFont.Small)) do
        self:drawText(line, 10, y, 0.92, 0.92, 0.92, 1, UIFont.Small)
        y = y + getTextManager():getFontHeight(UIFont.Small) + 2
    end
end

local function answer(accept)
    local invite = Invite.instance
    if not invite then return end
    send("EVENT_SIMULATION_RESPOND", { id = invite.data.id, accept = accept })
    Invite.Close()
end

function Invite:onOk() answer(true) end
function Invite:onCancel() answer(false) end

function Invite.Show(data)
    Invite.Close()
    local invite = Invite:new(data)
    invite:initialise()
    invite:addToUIManager()
    if not invite.okButton then invite:createChildren() end
    invite:setVisible(true)
    Invite.instance = invite
    return invite
end

function Invite.Close()
    if Invite.instance then
        Invite.instance:setVisible(false)
        Invite.instance:removeFromUIManager()
        Invite.instance = nil
    end
end

function UI.OnInvite(data)
    if data.withdrawn then
        if Invite.instance and Invite.instance.data.id == data.id then Invite.Close() end
        return
    end
    Invite.Show(data)
end

local lastRefresh = 0
local function onTick()
    if not UI.current then return end
    local t = now()
    if t - lastRefresh < UI.REFRESH_MS then return end
    lastRefresh = t
    pcall(UI.RefreshAids, UI.current)
end

local function onServerCommand(module, command, args)
    if module ~= "KIPN" or type(args) ~= "table" then return end
    local S = Shared()
    if not S.Commands or command ~= S.Commands.SERVER_RESPONSE then return end
    local data = type(args.data) == "table" and args.data or {}
    if args.event == S.ResponseEvents.EVENT_SIMULATION_INVITE then UI.OnInvite(data) return end
    if args.event == S.ResponseEvents.EVENT_ACTION_RESULT and data.action == "simulationGuest" and UI.instance then
        UI.instance.guestNote, UI.instance.guestNoteAt = tostring(data.text), now()
        return
    end
    if args.event ~= S.ResponseEvents.EVENT_SIMULATION then return end
    UI.OnSimulation(data)
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnTick.Add(onTick)
