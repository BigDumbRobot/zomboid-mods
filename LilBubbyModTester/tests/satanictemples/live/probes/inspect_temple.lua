-- Report skeletons, katanas, lanterns, client lights.
STProbeResult = (function()
    local SO = SacrificialOffering
    local zone = SO.Storage.FindZone(ST.zoneId)
    if not zone then return "no zone" end
    local out = {}
    for i, pos in ipairs(zone.fixtures.mannequins) do
        local m = SO.Fixtures.FindTaggedObject(pos.x, pos.y, pos.z, SO.FIXTURE.MANNEQUIN)
        if not m then out[#out+1] = "mannequin" .. i .. "=MISSING" else
            local c = m:getContainer()
            local items = {}
            for k = 0, c:getItems():size() - 1 do items[#items+1] = c:getItems():get(k):getFullType() end
            out[#out+1] = string.format("mannequin%d script=%s worn=%d items=[%s] ver=%s",
                i, tostring(m:getMannequinScriptName()), m:getWornItems():size(), table.concat(items, ","),
                tostring(m:getModData().SO_OutfitVersion))
        end
    end
    local found = 0
    for _, pos in ipairs(zone.fixtures.lanterns or {}) do
        local sq = getCell():getGridSquare(pos.x, pos.y, pos.z)
        local objs = sq and sq:getWorldObjects()
        for k = 0, (objs and objs:size() or 0) - 1 do
            local it = objs:get(k):getItem()
            local md = it:getModData()
            if md.SO_FixtureKind == "lantern" then
                found = found + 1
                if found == 1 then
                    out[#out+1] = string.format("lantern item=%s offAge=%s age=%.2f rotten=%s", it:getFullType(),
                        tostring(it:getOffAge()), it:getAge(), tostring(it:isRotten()))
                end
            end
        end
    end
    out[#out+1] = string.format("lantern positions=%d worldItems=%d", #(zone.fixtures.lanterns or {}), found)
    local lamps = getCell():getLamppostPositions()
    local orange = 0
    for k = 0, lamps:size() - 1 do
        local l = lamps:get(k)
        if math.abs(l:getR() - 1.0) < 0.01 and math.abs(l:getG() - 0.45) < 0.01 then orange = orange + 1 end
    end
    out[#out+1] = "orange lights=" .. orange
    local cz = SO.Client.FindZone(ST.zoneId)
    out[#out+1] = "client zone lanterns=" .. tostring(cz and cz.fixtures and cz.fixtures.lanterns and #cz.fixtures.lanterns)
    return table.concat(out, " | ")
end)()
