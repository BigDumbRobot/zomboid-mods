-- Delete the temple: skeletons, katanas and lanterns must all go.
STProbeResult = (function()
    local SO = SacrificialOffering
    local zone = SO.Storage.FindZone(ST.zoneId)
    local fx = SO.Util.DeepCopy(zone.fixtures)
    SO.ZoneService.Delete(getPlayer(), { zoneId = ST.zoneId })
    SO.Fixtures.CleanupTombstones()
    local m, l = 0, 0
    for _, pos in ipairs(fx.mannequins) do
        if SO.Fixtures.FindTaggedObject(pos.x, pos.y, pos.z, SO.FIXTURE.MANNEQUIN) then m = m + 1 end
    end
    for _, pos in ipairs(fx.lanterns) do
        local sq = getCell():getGridSquare(pos.x, pos.y, pos.z)
        for k = 0, sq:getWorldObjects():size() - 1 do
            if sq:getWorldObjects():get(k):getItem():getModData().SO_FixtureKind == "lantern" then l = l + 1 end
        end
    end
    return string.format("zoneGone=%s skeletonsLeft=%d lanternsLeft=%d", tostring(SO.Storage.FindZone(ST.zoneId) == nil), m, l)
end)()
