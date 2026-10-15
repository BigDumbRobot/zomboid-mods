-- Night + stand near the temple for a screenshot.
STProbeResult = (function()
    local SO = SacrificialOffering
    local zone = SO.Storage.FindZone(ST.zoneId)
    local a = zone.fixtures.altar
    local p = getPlayer()
    p:setX(a.x + 0.5); p:setY(a.y + 4.5); p:setLastX(a.x + 0.5); p:setLastY(a.y + 4.5)
    getGameTime():setTimeOfDay(23.0)
    return "night set; player at " .. a.x .. "," .. (a.y + 4)
end)()
