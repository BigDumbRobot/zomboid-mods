STProbeResult = (function()
    local lamps, orange = getCell():getLamppostPositions(), 0
    for k = 0, lamps:size() - 1 do
        local l = lamps:get(k)
        if math.abs(l:getR() - 1.0) < 0.01 and math.abs(l:getG() - 0.45) < 0.01 then orange = orange + 1 end
    end
    return "orange lights after removal=" .. orange
end)()
