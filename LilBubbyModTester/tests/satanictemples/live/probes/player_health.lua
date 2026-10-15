STProbeResult = (function()
    local p = getPlayer()
    local b = p:getBodyDamage()
    local out = { string.format("dead=%s health=%.1f hours=%.2f", tostring(p:isDead()), b:getOverallBodyHealth(), p:getHoursSurvived()) }
    local parts = b:getBodyParts()
    for i = 0, parts:size() - 1 do
        local bp = parts:get(i)
        local flags = {}
        if bp:bleeding() then flags[#flags+1] = "bleeding" end
        if bp:isDeepWounded() then flags[#flags+1] = "deep" end
        if bp:scratched() then flags[#flags+1] = "scratch" end
        if bp:bitten() then flags[#flags+1] = "BITTEN" end
        if bp:getBurnTime() > 0 then flags[#flags+1] = "burn" end
        if bp:getFractureTime() > 0 then flags[#flags+1] = "fracture" end
        if #flags > 0 or bp:getHealth() < 99 then
            out[#out+1] = string.format("%s hp=%.0f %s", tostring(bp:getType()), bp:getHealth(), table.concat(flags, ","))
        end
    end
    local zombies, list = 0, getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        if math.abs(z:getX() - p:getX()) < 30 and math.abs(z:getY() - p:getY()) < 30 then zombies = zombies + 1 end
    end
    out[#out+1] = "zombiesWithin30=" .. zombies .. " sandboxZombies=" .. tostring(SandboxVars.Zombies)
    local st = p:getStats()
    out[#out+1] = string.format("infected=%s", tostring(b:IsInfected()))
    return table.concat(out, " | ")
end)()
