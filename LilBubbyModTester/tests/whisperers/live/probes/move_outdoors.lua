local p = getPlayer()
local cell = getCell()
local px, py = math.floor(p:getX()), math.floor(p:getY())
local function clear(x, y)
    local sq = cell:getGridSquare(x, y, 0)
    if not sq or not sq:isOutside() or not sq:getFloor() then return false end
    if sq:getObjects():size() > 1 or sq:isSolid() or sq:isSolidTrans() then return false end
    return true
end
local function ok(x, y)
    for dx = -5, 5 do for dy = -1, 4 do if not clear(x + dx, y + dy) then return false end end end
    return true
end
for r = 1, 40 do
    for dx = -r, r do for dy = -r, r do
        if math.max(math.abs(dx), math.abs(dy)) == r and ok(px + dx, py + dy) then
            local x, y = px + dx + 0.5, py + dy + 0.5
            p:setX(x); p:setY(y); p:setZ(0); p:setLastX(x); p:setLastY(y); p:setLastZ(0)
            WhispProbeResult = "moved to " .. (px + dx) .. "," .. (py + dy)
            return
        end
    end end
end
WhispProbeResult = "no open spot within 40"
