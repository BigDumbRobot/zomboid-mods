local p = getPlayer(); local cell = getCell()
local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
local out = { "player " .. px .. "," .. py }
for x = px - 8, px + 8 do for y = py - 8, py + 8 do
  local sq = cell:getGridSquare(x, y, pz)
  local objs = sq and sq:getObjects()
  for i = 0, (objs and objs:size() or 0) - 1 do
    local o = objs:get(i)
    local sn = o:getSprite() and o:getSprite():getName() or "nil"
    if instanceof(o, "IsoMannequin") or tostring(sn):find("headstake") then
      local worn = {}
      if instanceof(o, "IsoMannequin") then
        local w = o:getWornItems(); for j = 0, w:size() - 1 do worn[#worn+1] = w:getItemByIndex(j):getFullType() end
      end
      out[#out+1] = x .. "," .. y .. " " .. tostring(o:getClass():getSimpleName()) .. " sprite=" .. sn
        .. " script=" .. tostring(instanceof(o, "IsoMannequin") and o:getMannequinScriptName()) .. " worn=" .. table.concat(worn, ";")
        .. " hair=" .. tostring(instanceof(o, "IsoMannequin") and o:getHumanVisual():getHairModel())
    end
  end
end end
WhispProbeResult = table.concat(out, "\n")
