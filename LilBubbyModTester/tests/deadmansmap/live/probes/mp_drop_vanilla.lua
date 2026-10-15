DMMMPProbeResult = (function()
    local p = getPlayer()
    local map = p:getInventory():getFirstType("Base.Map")
    if not map then return "no vanilla map" end
    ISInventoryPaneContextMenu.dropItem(map, 0)
    return "dropping vanilla map id=" .. tostring(map:getID())
end)()
