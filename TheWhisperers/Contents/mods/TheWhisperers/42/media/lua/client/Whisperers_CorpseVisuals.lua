-- The Whisperers: show beheaded corpses correctly on every client.
-- The server only syncs the corpse's modData, so each client re-applies the
-- headless look.
require "Whisperers_Gear"

local W = Whisperers
local G = W.Gear

local SWEEP_RADIUS = 8
local SWEEP_MS = 2000
local nextSweep = 0

local function apply(object)
    if object and instanceof(object, "IsoDeadBody") then
        if object:getModData().WhispHeadless then G.applyCorpseVisuals(object) end
    end
end

local function onSquare(square)
    if not square then return end
    local bodies = square:getStaticMovingObjects()
    for i = 0, bodies:size() - 1 do apply(bodies:get(i)) end
end

local function onTick()
    local now = getTimestampMs()
    if now < nextSweep then return end
    nextSweep = now + SWEEP_MS
    local player = getSpecificPlayer(0)
    local cell = getCell()
    if not player or not cell then return end
    local px, py, pz = math.floor(player:getX()), math.floor(player:getY()), math.floor(player:getZ())
    for dx = -SWEEP_RADIUS, SWEEP_RADIUS do
        for dy = -SWEEP_RADIUS, SWEEP_RADIUS do
            onSquare(cell:getGridSquare(px + dx, py + dy, pz))
        end
    end
end

-- Halo messages the server sends about gear tearing or guts rotting.
local function onServerCommand(module, command, args)
    if module ~= W.Module or command ~= "Halo" or type(args) ~= "table" then return end
    local player = getSpecificPlayer(0)
    if not player or not HaloTextHelper or type(args.key) ~= "string" then return end
    if args.good then
        HaloTextHelper.addGoodText(player, getText(args.key))
    else
        HaloTextHelper.addBadText(player, getText(args.key))
    end
end

Events.LoadGridsquare.Add(onSquare)
Events.OnTick.Add(onTick)
Events.OnServerCommand.Add(onServerCommand)
