-- Move to an open outdoor area and create a 13x13 temple north of the player.
STProbeResult = (function()
    local SO = SacrificialOffering
    local p, cell = getPlayer(), getCell()
    local px, py = math.floor(p:getX()), math.floor(p:getY())
    local function clear(x, y)
        local sq = cell:getGridSquare(x, y, 0)
        if not sq or not sq:isOutside() or not sq:getFloor() then return false end
        if sq:isSolid() or sq:isSolidTrans() or not sq:isFree(false) then return false end
        return true
    end
    -- zone spans x-6..x+6, y-14..y-2 ; player stands at y (two rows south)
    local function ok(x, y)
        for dx = -6, 6 do for dy = -14, 0 do if not clear(x + dx, y + dy) then return false end end end
        return true
    end
    for r = 0, 60 do
        for dx = -r, r do for dy = -r, r do
            if math.max(math.abs(dx), math.abs(dy)) == r and ok(px + dx, py + dy) then
                local x, y = px + dx, py + dy
                p:setX(x + 0.5); p:setY(y + 0.5); p:setZ(0); p:setLastX(x + 0.5); p:setLastY(y + 0.5); p:setLastZ(0)
                local before = #SO.Storage.Get().zones
                SO.ZoneService.Create(p, { x1 = x - 6, y1 = y - 14, x2 = x + 7, y2 = y - 1, name = "Live Test Temple" })
                local zones = SO.Storage.Get().zones
                local zone = zones[#zones]
                ST = { zoneId = zone.id, px = x, py = y }
                return string.format("moved to %d,%d; zones %d->%d; zone %s rect %d,%d-%d,%d pending=%s altar=%s lanterns=%s",
                    x, y, before, #zones, tostring(zone.id), zone.x1, zone.y1, zone.x2, zone.y2, tostring(zone.pendingFixtures),
                    zone.fixtures and zone.fixtures.altar and (zone.fixtures.altar.x .. "," .. zone.fixtures.altar.y) or "nil",
                    zone.fixtures and zone.fixtures.lanterns and #zone.fixtures.lanterns or "nil")
            end
        end end
    end
    return "no open 13x15 area within 60"
end)()
