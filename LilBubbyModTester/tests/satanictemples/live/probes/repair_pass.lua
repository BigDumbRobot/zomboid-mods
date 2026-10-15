-- Integrity pass: restock a stolen katana, replace a lantern, migrate an old
-- (clothed, version-3) mannequin, and re-add a lost lantern list.
STProbeResult = (function()
    local SO = SacrificialOffering
    local zone = SO.Storage.FindZone(ST.zoneId)
    local out = {}
    local m1p = zone.fixtures.mannequins[1]
    local m1 = SO.Fixtures.FindTaggedObject(m1p.x, m1p.y, m1p.z, SO.FIXTURE.MANNEQUIN)
    m1:getContainer():DoRemoveItem(m1:getContainer():getItems():get(0))
    local m3p = zone.fixtures.mannequins[3]
    local m3 = SO.Fixtures.FindTaggedObject(m3p.x, m3p.y, m3p.z, SO.FIXTURE.MANNEQUIN)
    m3:setMannequinScriptName("MaleWhite01"); m3:getModData().SO_OutfitVersion = 3
    local lp = zone.fixtures.lanterns[2]
    local sq = getCell():getGridSquare(lp.x, lp.y, lp.z)
    for k = sq:getWorldObjects():size() - 1, 0, -1 do
        local o = sq:getWorldObjects():get(k)
        if o:getItem():getModData().SO_FixtureKind == "lantern" then sq:transmitRemoveItemFromSquare(o); sq:removeWorldObject(o) end
    end
    out[#out+1] = string.format("before: m1 katanas=%d m3 script=%s lantern2 objs=%d",
        m1:getContainer():getItems():size(), m3:getMannequinScriptName(), sq:getWorldObjects():size())
    local savedLanterns = zone.fixtures.lanterns
    zone.fixtures.lanterns = nil
    local rev = SO.Client.ZoneRevision
    SO.ZoneService.ProvisionAndRepair()
    local l2 = 0
    for k = 0, sq:getWorldObjects():size() - 1 do
        if sq:getWorldObjects():get(k):getItem():getModData().SO_FixtureKind == "lantern" then l2 = l2 + 1 end
    end
    out[#out+1] = string.format("after: m1 katanas=%d m3 script=%s m3 items=%d lantern2=%d lanternsRestored=%s resynced=%s",
        m1:getContainer():getItems():size(), m3:getMannequinScriptName(), m3:getContainer():getItems():size(), l2,
        tostring(zone.fixtures.lanterns and #zone.fixtures.lanterns), tostring(SO.Client.ZoneRevision > rev))
    -- idempotence: a second pass must not duplicate lanterns or katanas
    SO.ZoneService.ProvisionAndRepair()
    local l3 = 0
    for k = 0, sq:getWorldObjects():size() - 1 do
        if sq:getWorldObjects():get(k):getItem():getModData().SO_FixtureKind == "lantern" then l3 = l3 + 1 end
    end
    out[#out+1] = string.format("secondPass lantern2=%d m1 katanas=%d", l3, m1:getContainer():getItems():size())
    return table.concat(out, " | ")
end)()
