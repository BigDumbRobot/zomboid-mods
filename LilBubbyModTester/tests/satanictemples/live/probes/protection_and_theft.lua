-- Guards: katana transfer (triggers the strike), lantern grab/transfer/placement,
-- skeleton pickup/destroy; then a second attempt inside the cooldown.
STProbeResult = (function()
    local SO = SacrificialOffering
    local p = getPlayer()
    local zone = SO.Storage.FindZone(ST.zoneId)
    local pos = zone.fixtures.mannequins[2]
    p:setX(pos.x + 1.5); p:setY(pos.y + 0.5); p:setLastX(pos.x + 1.5); p:setLastY(pos.y + 0.5)
    local m = SO.Fixtures.FindTaggedObject(pos.x, pos.y, pos.z, SO.FIXTURE.MANNEQUIN)
    local body = p:getBodyDamage()
    local function deepCount()
        local n, parts = 0, body:getBodyParts()
        for k = 0, parts:size() - 1 do if parts:get(k):isDeepWounded() then n = n + 1 end end
        return n
    end
    local out = {}
    body:RestoreToFullHealth()
    local h0, d0 = body:getOverallBodyHealth(), deepCount()
    local katana = m:getContainer():getItems():get(0)
    local t = ISInventoryTransferAction:new(p, katana, m:getContainer(), p:getInventory())
    out[#out+1] = "katanaTransferValid=" .. tostring(t:isValid())
    local h1, d1 = body:getOverallBodyHealth(), deepCount()
    out[#out+1] = string.format("health %.1f->%.1f (%.0f%%) deep %d->%d", h0, h1, h1 / h0 * 100, d0, d1)
    ST.healthAfterStrike = h1
    local t2 = ISInventoryTransferAction:new(p, katana, m:getContainer(), p:getInventory())
    t2:isValid()
    out[#out+1] = string.format("secondAttempt health=%.1f (cooldown %s)", body:getOverallBodyHealth(),
        math.abs(body:getOverallBodyHealth() - h1) < 0.5 and "held" or "BROKEN")
    out[#out+1] = "katanasLeft=" .. m:getContainer():getItems():size() .. " inInventory=" .. tostring(p:getInventory():contains(katana))
    local mv = ISMoveablesAction:new(p, m:getSquare(), "pickup", m:getSprite():getName(), m, nil, nil, nil)
    out[#out+1] = "skeletonPickupValid=" .. tostring(mv:isValid())
    out[#out+1] = "skeletonDestroyValid=" .. tostring(ISDestroyStuffAction:new(p, m, false):isValid())
    -- lantern
    local lp = zone.fixtures.lanterns[1]
    local sq = getCell():getGridSquare(lp.x, lp.y, lp.z)
    local wi
    for k = 0, sq:getWorldObjects():size() - 1 do
        local o = sq:getWorldObjects():get(k)
        if o:getItem():getModData().SO_FixtureKind == "lantern" then wi = o end
    end
    p:setX(lp.x + 0.5); p:setY(lp.y + 1.5); p:setLastX(lp.x + 0.5); p:setLastY(lp.y + 1.5)
    out[#out+1] = "lanternGrabValid=" .. tostring(ISGrabItemAction:new(p, wi, 50):isValid())
    out[#out+1] = "lanternTransferValid=" .. tostring(ISInventoryTransferAction:new(p, wi:getItem(), ISInventoryPage.GetFloorContainer(0), p:getInventory()):isValid())
    out[#out+1] = "lanternPlacementValid=" .. tostring(ISExtendedPlacementAction:new(p, wi:getItem()):isValid())
    -- control: an ordinary floor item can still be grabbed
    local ctrl = sq:AddWorldInventoryItem("Base.Apple", 0.2, 0.2, 0)
    local cwo = ctrl and ctrl:getWorldItem()
    out[#out+1] = "controlAppleGrabValid=" .. tostring(cwo and ISGrabItemAction:new(p, cwo, 50):isValid())
    if cwo then sq:transmitRemoveItemFromSquare(cwo); sq:removeWorldObject(cwo) end
    return table.concat(out, " | ")
end)()
