local p = getPlayer(); local cell = getCell()
local px, py = math.floor(p:getX()), math.floor(p:getY())
local S = Whisperers.Stake
local out = {}
for i = 0, 2 do
    local item = instanceItem("Whisperers.HeadStake")
    item:getModData().WhispFaceless = (i == 2) or nil
    S.dressFromModData(item)
    local sq = cell:getGridSquare(px - 1 + i * 2, py + 3, 0)
    ISMoveableSpriteProps.new(S.Sprite):placeMoveableInternal(sq, item, S.Sprite)
    out[#out + 1] = "stake at " .. sq:getX() .. "," .. sq:getY() .. " solidtrans=" .. tostring(sq:isSolidTrans())
end
local carSq = cell:getGridSquare(px - 6, py + 3, 0)
local car = addVehicleDebug("Base.CarNormal", IsoDirections.E, nil, carSq)
out[#out + 1] = "car " .. tostring(car) .. " at " .. carSq:getX() .. "," .. carSq:getY()
WhispProbeResult = table.concat(out, "\n")
