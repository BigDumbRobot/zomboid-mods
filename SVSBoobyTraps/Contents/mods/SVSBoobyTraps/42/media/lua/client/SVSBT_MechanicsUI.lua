require "SVSBT_Client"
require "Vehicles/ISUI/ISVehicleMechanics"

local Client = SVSBT.Client
local Shared = SVSBT.Shared
local Logger = SVSBT.Logger

-- A rigged vehicle device is only recognizable to someone who has read the
-- MAD Magazine that teaches it -- Inspecting the car, owning the device or
-- passive detection all still put the record in Client.Visible (that list
-- drives the context menu and disarm flow too), but without the magazine the
-- mechanics panel shows no warning at all. No new knowledge is granted here;
-- this only decides where to draw a small icon.
local function vehicleHasTrapKind(player, vehicle, kind)
    if not vehicle then return false end
    if not Shared.ShowsWarningIndicator(player, kind) then return false end
    local uid = Shared.VehicleUID(vehicle, false)
    if not uid then return false end

    for _, record in ipairs(Client.Visible or {}) do
        if record.kind == kind and record.vehicleUid ~= nil
            and tostring(record.vehicleUid) == tostring(uid)
            and record.state ~= "spent" and record.state ~= "destroyed" then
            return true
        end
    end

    return false
end

-- Whose magazine knowledge gates this panel's icons. Vanilla sets .chr on the
-- mechanics window itself; fall back to the local player rather than nil, so a
-- window that somehow has no character still shows the owner their own traps.
local function panelPlayer(window)
    if window and window.chr then return window.chr end
    return getSpecificPlayer(0) or getPlayer()
end

local function isDriverSeat(part)
    return part ~= nil and type(part.isSeat) == "function" and part:isSeat()
        and type(part.getContainerSeatNumber) == "function" and part:getContainerSeatNumber() == 0
end

local function partTrapKind(part)
    if not part or type(part.getId) ~= "function" then return nil end
    local partId = part:getId()

    if partId == "Battery" then
        return Shared.Kind.IgnitionCharge
    elseif partId == "Engine" then
        return Shared.Kind.RemoteImmobilizer
    elseif isDriverSeat(part) then
        return Shared.Kind.DriverSeatDye
    end

    return nil
end

local function mechanicsIcon()
    Client.MechanicsIcon = Client.MechanicsIcon or getTexture("media/textures/SVSBT_TrapIndicator.png")
    return Client.MechanicsIcon
end

-- Popping the hood counts as tampering with the car too, same as opening a
-- door/window or getting in a seat -- report it exactly once per window
-- open, the same way patchContainers reports a trunk/glovebox open.
if ISVehicleMechanics and not ISVehicleMechanics.SVSBT_OriginalInitialise then
    ISVehicleMechanics.SVSBT_OriginalInitialise = ISVehicleMechanics.initialise

    function ISVehicleMechanics:initialise()
        local run = Logger.Begin("MechanicsUI.initialise")
        ISVehicleMechanics.SVSBT_OriginalInitialise(self)

        if self.vehicle and self.chr then
            Client.SendCommand("VEHICLE_MECHANICS_OPENED", { vehicleId = self.vehicle:getId() }, self.chr)
        end

        Logger.Finish(run, true)
    end
end

if ISVehicleMechanics and not ISVehicleMechanics.SVSBT_OriginalDoDrawItem then
    ISVehicleMechanics.SVSBT_OriginalDoDrawItem = ISVehicleMechanics.doDrawItem

    -- doDrawItem is called on the listbox (self), with self.parent being the
    -- ISVehicleMechanics window that owns .vehicle/.chr.
    function ISVehicleMechanics:doDrawItem(y, item, alt)
        local run = Logger.Begin("MechanicsUI.doDrawItem")
        local result = ISVehicleMechanics.SVSBT_OriginalDoDrawItem(self, y, item, alt)
        local window = self.parent
        local part = item and item.item and not item.item.cat and item.item.part or nil
        local kind = window and window.vehicle and part and partTrapKind(part) or nil

        if kind and vehicleHasTrapKind(panelPlayer(window), window.vehicle, kind) then
            local icon = mechanicsIcon()
            if icon then
                self:drawTextureScaled(icon, 2, y + 2, 11, 11, 0.95, 0.95, 0.15, 0.10)
            end
        end

        Logger.Finish(run, true)
        return result
    end
end

if ISVehicleMechanics and not ISVehicleMechanics.SVSBT_OriginalRender then
    ISVehicleMechanics.SVSBT_OriginalRender = ISVehicleMechanics.render

    -- The Tamper Alarm has no single part it's attached to, so its warning
    -- sits next to the vehicle's name instead of a specific row.
    function ISVehicleMechanics:render()
        local run = Logger.Begin("MechanicsUI.render")
        ISVehicleMechanics.SVSBT_OriginalRender(self)

        if not self.isCollapsed and self.vehicle
            and vehicleHasTrapKind(panelPlayer(self), self.vehicle, Shared.Kind.TamperAlarm) then
            local icon = mechanicsIcon()

            if icon then
                local rectWidth = self:getWidth() - self.xCarTexOffset - 10
                local x = self.xCarTexOffset + rectWidth - 16
                local y = self.rectY + 4
                self:drawTextureScaled(icon, x, y, 12, 12, 0.95, 0.95, 0.72, 0.10)
            end
        end

        Logger.Finish(run, true)
    end
end

Logger.Info("SVSBT_MechanicsUI.load", "vehicle mechanics warning icons initialized")
