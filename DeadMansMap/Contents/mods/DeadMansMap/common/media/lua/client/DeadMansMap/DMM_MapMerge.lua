require "TimedActions/ISInventoryTransferUtil"
require "ISUI/Maps/ISMap"
require "DeadMansMap/DMM_Core"

DeadMansMap = DeadMansMap or {}

local MapMerge = {}
local Core = DeadMansMap.Core
local Logger = DeadMansMap.Logger

-- Only offer the option for another player's dropped Annotated Map, not any
-- ordinary Base.Map -- the DMM_IsDeathMap tag is the same one Core.tagDeathMap
-- writes when a death map is created.
local function isMergeableDeathMap(item)
    if not item or not instanceof(item, "InventoryItem") then
        return false
    end

    local isMapOk, isMap = Core.tryMethod(item, "IsMap")
    if not isMapOk or isMap ~= true then
        return false
    end

    local modDataOk, modData = Core.tryMethod(item, "getModData")
    if not modDataOk or not modData then
        return false
    end

    return modData.DMM_IsDeathMap == true
end

-- items entries are either a bare InventoryItem or a {items = {...}} stack
-- wrapper, matching the shape ISInventoryPaneContextMenu itself unpacks.
local function findMergeableItem(items)
    for _, entry in ipairs(items or {}) do
        if instanceof(entry, "InventoryItem") then
            if isMergeableDeathMap(entry) then
                return entry
            end
        elseif entry and entry.items then
            for _, sub in ipairs(entry.items) do
                if isMergeableDeathMap(sub) then
                    return sub
                end
            end
        end
    end
    return nil
end

-- Same check vanilla ISMap:canWrite uses to gate "Edit Markings": copying
-- markings is writing on your own map, so it needs a pen or pencil.
function MapMerge.canWrite(playerObj)
    if not playerObj then
        return false
    end
    local inv = playerObj:getInventory()
    return inv ~= nil and inv:containsTagRecurse(ItemTag.WRITE)
end

local function reportResult(playerObj, mapItem, result)
    if not HaloTextHelper then
        return
    end

    if not result or not result.ok then
        HaloTextHelper.addBadText(playerObj, getText("IGUI_DMM_CopyMarkings_Failed"))
        return
    end

    if result.addedCount > 0 then
        local modDataOk, modData = Core.tryMethod(mapItem, "getModData")
        local ownerName = (modDataOk and modData and modData.DMM_OwnerName) or getText("IGUI_DMM_UnknownSurvivor")
        HaloTextHelper.addGoodText(
            playerObj,
            getText("IGUI_DMM_CopyMarkings_Success", tostring(result.addedCount), tostring(ownerName))
        )
    else
        HaloTextHelper.addBadText(playerObj, getText("IGUI_DMM_CopyMarkings_NoneNew"))
    end

    if result.capReached then
        HaloTextHelper.addBadText(playerObj, getText("IGUI_DMM_CopyMarkings_CapReached"))
    end
end

-- Context-menu callback: mirrors ISInventoryPaneContextMenu.onCheckMap's
-- transfer-if-needed pattern so the option works from the floor/loot pane
-- without requiring the map be picked up first.
function MapMerge.onCopyMarkings(mapItem, playerNum)
    local trace = Logger.traceStart("MapMerge.onCopyMarkings")
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj or not mapItem then
        Logger.traceEnd(trace, "failed", "no-player-or-item")
        return
    end

    -- In multiplayer a transferred item arrives as a new object, and the one
    -- this callback was queued with still points at the floor. Without this,
    -- the re-check below queues a transfer that can never finish.
    local carried = playerObj:getInventory():getItemById(mapItem:getID())
    if carried then
        mapItem = carried
    end

    if luautils.haveToBeTransfered(playerObj, mapItem) then
        local action = ISInventoryTransferUtil.newInventoryTransferAction(
            playerObj, mapItem, mapItem:getContainer(), playerObj:getInventory()
        )
        action:setOnComplete(MapMerge.onCopyMarkings, mapItem, playerNum)
        ISTimedActionQueue.add(action)
        Logger.traceEnd(trace, "deferred", "transfer-queued")
        return
    end

    -- Re-checked here because the writing tool can be dropped between the
    -- menu opening (or a deferred transfer) and the copy running.
    if not MapMerge.canWrite(playerObj) then
        if HaloTextHelper then
            HaloTextHelper.addBadText(playerObj, getText("Tooltip_Map_CantWrite"))
        end
        Logger.traceEnd(trace, "failed", "no-writing-tool")
        return
    end

    local destMap = MapItem and MapItem.getSingleton and MapItem.getSingleton() or nil
    if not destMap then
        Logger.error("MapMerge.onCopyMarkings", "Personal MapItem singleton was unavailable")
        reportResult(playerObj, mapItem, nil)
        Logger.traceEnd(trace, "failed", "no-personal-map")
        return
    end

    local config = Core.getConfig()
    local result = Core.mergeMapSymbols(mapItem, destMap, {
        safetyMax = config.SafetyMaxAnnotations,
    })

    reportResult(playerObj, mapItem, result)
    Logger.info("MapMerge.onCopyMarkings", "Copy markings finished", result)
    Logger.traceEnd(trace, result.ok and "ok" or "failed", result)
end

local function onFillInventoryObjectContextMenu(playerNum, context, items)
    local mapItem = findMergeableItem(items)
    if not mapItem then
        return
    end

    local option = context:addOption(
        getText("ContextMenu_DMM_CopyMarkings"),
        mapItem,
        MapMerge.onCopyMarkings,
        playerNum
    )
    option.itemForTexture = mapItem

    -- notAvailable draws the option in red and makes it unclickable.
    if not MapMerge.canWrite(getSpecificPlayer(playerNum)) then
        option.notAvailable = true
        local tooltip = ISInventoryPaneContextMenu.addToolTip()
        tooltip.description = getText("Tooltip_Map_CantWrite")
        option.toolTip = tooltip
    end
end

-- A disabled ISButton always draws grey text; this variant keeps the
-- button unclickable but draws its title in textColor (red) instead.
local DMMCopyButton = ISButton:derive("DMMCopyButton")

function DMMCopyButton:render()
    local enabled = self.enable
    self.enable = true
    ISButton.render(self)
    self.enable = enabled
end

function MapMerge.onMapCopyButton(mapUI)
    MapMerge.onCopyMarkings(mapUI.mapObj, mapUI.playerNum)
end

-- Adds "Copy markings to my map" beside the vanilla map-viewer buttons,
-- but only when the map being viewed is a Dead Man's Map.
local originalCreateChildren = ISMap.createChildren
function ISMap:createChildren()
    originalCreateChildren(self)

    if not isMergeableDeathMap(self.mapObj) then
        return
    end

    -- ISMap.lua keeps its spacing and button height in file locals, so take
    -- them from the vanilla buttons instead.
    local spacing = self.showMapKey.x - self.ok:getRight()
    local title = getText("IGUI_DMM_CopyMarkings_Button")
    local btnWidth = spacing * 2 + getTextManager():MeasureStringX(UIFont.Small, title)
    local btn = DMMCopyButton:new(
        self.placeSymbBtn:getRight() + spacing, self.ok.y, btnWidth, self.ok.height, title, self, MapMerge.onMapCopyButton
    )
    btn.internal = "DMM_COPY"
    btn:initialise()
    btn:instantiate()
    btn.borderColor = {r=1, g=1, b=1, a=0.4}
    self:addChild(btn)
    self.dmmCopyBtn = btn
end

local originalUpdateButtons = ISMap.updateButtons
function ISMap:updateButtons()
    originalUpdateButtons(self)

    local btn = self.dmmCopyBtn
    if not btn then
        return
    end

    -- placeSymbBtn resizes to its title, so follow its right edge.
    btn:setX(self.placeSymbBtn:getRight() + self.showMapKey.x - self.ok:getRight())
    btn:setVisible(self.showMapKey:isVisible())

    btn.enable = MapMerge.canWrite(self.character)
    if btn.enable then
        btn.textColor = {r=1, g=1, b=1, a=1}
        btn.tooltip = nil
    else
        local bad = getCore():getBadHighlitedColor()
        btn.textColor = {r=bad:getR(), g=bad:getG(), b=bad:getB(), a=1}
        btn.tooltip = getText("Tooltip_Map_CantWrite")
    end
end

DeadMansMap.MapMerge = MapMerge

if Events and Events.OnFillInventoryObjectContextMenu then
    Events.OnFillInventoryObjectContextMenu.Add(onFillInventoryObjectContextMenu)
    Logger.info("DMM_MapMerge", "Registered OnFillInventoryObjectContextMenu")
else
    Logger.error("DMM_MapMerge", "OnFillInventoryObjectContextMenu event was unavailable")
end

Logger.info("DMM_MapMerge", "Map merge module loaded")

return MapMerge
