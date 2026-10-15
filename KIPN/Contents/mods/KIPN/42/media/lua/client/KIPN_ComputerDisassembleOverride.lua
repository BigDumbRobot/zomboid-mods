-- KIPN_ComputerDisassembleOverride.lua
--
-- Removes vanilla's generic right-click "Disassemble" ability
-- (ISUI/ISDisassembleMenu.lua) for any world object KIPN recognizes
-- as a computer.
--
-- IMPORTANT:
--
-- Vanilla lets ANY placed "Desktop Computer" moveable (and other
-- moveables sharing a KIPN-recognized computer sprite, e.g.
-- Mov_Microphone, Mov_Projector, Mov_SatelliteDish,
-- Mov_SecurityTerminal2, Mov_TVCamera -- see
-- KIPN.Shared.IsComputerObjectSprite) be broken down through that
-- generic submenu, independently of KIPN's own "Disassemble
-- Computer" option (see addDisassembleOption() in
-- KIPN_Interaction.lua, queued via
-- client/TimedActions/KIPN_DisassembleComputerAction.lua).
--
-- The two are incompatible:
--
--   * Vanilla's version REMOVES the world object outright and does
--     not consult the server at all -- it would silently orphan
--     any KIPN computer record tied to that square/ID and bypass
--     the authoritative checks KIPN_Server.lua's
--     handleDisassembleComputer performs (computer must be OFF,
--     player must carry a screwdriver).
--
--   * KIPN's version never removes the world object -- it only
--     degrades Hardware Condition server-side.
--
-- Leaving vanilla's path active would let a player bypass KIPN's
-- system entirely, so this file removes it: KIPN-recognized
-- computer objects are stripped out of ISDisassembleMenu's input
-- before the vanilla menu is built, and are therefore never
-- offered vanilla's "Disassemble" option at all.
--
-- This uses the SAME detector KIPN_Interaction.lua uses to decide
-- whether to offer its own Power On/Off, Access KIP Network,
-- Repair, and Disassemble options (KIPN.Shared.IsComputerObjectSprite),
-- so what counts as "a computer" never drifts between the two
-- systems.

if isServer() then
    return
end

--------------------------------------------------------------------
-- LOAD-ORDER DEPENDENCIES
--
-- KIPN_Shared establishes the KIPN namespace and
-- KIPN.Shared.IsComputerObjectSprite. It lives in media/lua/shared,
-- which Project Zomboid always loads before media/lua/client, but
-- this require is kept explicit anyway, matching this mod's
-- existing convention (see e.g. KIPN_AnnouncementService.lua)
-- rather than relying on load order alone.
--
-- ISUI/ISDisassembleMenu is the vanilla file being overridden here.
-- It is a base-game file, always loaded before any mod's client
-- Lua, but this require is likewise kept explicit and defensive.
--------------------------------------------------------------------

require "KIPN_Shared"
require "ISUI/ISDisassembleMenu"

if not KIPN
    or not KIPN.Shared
    or not KIPN.Shared.IsComputerObjectSprite
then

    error(
        "KIPN_ComputerDisassembleOverride: " ..
        "KIPN.Shared.IsComputerObjectSprite is unavailable. " ..
        "Load order is broken."
    )
end

local vanillaCreateMenu =
    ISDisassembleMenu.createMenu

function ISDisassembleMenu.createMenu(
    worldObjects,
    context,
    playerObj
)

    local filteredObjects =
        worldObjects

    if worldObjects then

        filteredObjects =
            {}

        for _, object in ipairs(
            worldObjects
        ) do

            if not KIPN.Shared.IsComputerObjectSprite(
                object
            )
            then

                table.insert(
                    filteredObjects,
                    object
                )
            end
        end
    end

    return vanillaCreateMenu(
        filteredObjects,
        context,
        playerObj
    )
end
