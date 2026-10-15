-- KIPN_Interaction.lua
-- Detects computers and opens the KIPN terminal.
--
-- IMPORTANT:
--
-- Whether the menu is offered AT ALL is a plain client-side read
-- of world electricity (hasWorldElectricity()) - the same square:
-- haveElectricity() / square:hasGridPower() check vanilla
-- appliances (lamps, fridges, TVs) already make locally, with no
-- server round trip, because there is nothing here worth
-- protecting with a request: a modified client claiming "I have
-- power" gains nothing beyond what the vanilla client already
-- exposes. When there is no electricity, no menu option is
-- offered at all - not even "Power On Computer".
--
-- Once electricity is confirmed, this module offers a manual
-- "Power On Computer" / "Power Off Computer" toggle (SET_POWER),
-- alongside "Access KIP Network" once the computer is actually
-- on/booting. The server remains authoritative for everything
-- after that: whether a power-on request is actually allowed
-- (handleSetPower re-checks building electricity itself), and
-- whether accessing the computer means a fresh power-on (boot
-- screen), an existing but unauthenticated session (login), or an
-- already logged-in session (straight to the main menu).
-- KIPN_Server.lua's handleCheckPower() ALSO auto-reconciles KIPN's
-- persisted power/boot state against real electricity every time
-- it's asked (e.g. a real power outage), but defers to an explicit
-- manual "Power Off" (computer.manualOff) - see handleSetPower()/
-- handleCheckPower() in KIPN_Server.lua.
--
-- This module:
--
--   * Detects computer objects
--   * Resolves deterministic computer IDs
--   * Reads world electricity directly (no server dependency)
--   * Requests authoritative boot/session state
--   * Caches the latest server response
--   * Builds the context menu (Power On/Off, Access KIP Network)
--   * Opens the KIPN terminal
--
-- The cache is NEVER treated as permanent authority.
--
-- A fresh CHECK_POWER request is sent whenever the context menu
-- is opened. The result is asynchronous, so the menu built on this
-- pass uses the LAST SERVER-CONFIRMED boot state (fail closed to
-- "Power On Computer" when nothing is cached yet); KIPN_Terminal
-- itself also fails closed (requires boot) when no confirmed state
-- exists yet.
--
-- DEPENDENCY CONTRACT
--
-- Interaction is a CLIENT-SIDE WORLD INTERACTION MODULE.
--
-- It depends on:
--
--   KIPN_Logger
--       |
--       +-- KIPN namespace
--       +-- centralized logging
--
--   KIPN_Shared
--       |
--       +-- computer identifiers
--       +-- command identifiers
--       +-- response identifiers
--       +-- shared protocol constants
--
--   KIPN_Terminal
--       |
--       +-- terminal opening
--       +-- terminal viewer/container
--
-- It does NOT depend on:
--
--   * KIPN_UI
--   * KIPN_MainMenu
--   * KIPN_Server
--   * server-side services
--   * sandbox variables
--
-- IMPORTANT:
--
-- KIPN_Terminal must NOT require KIPN_Interaction.
--
-- Interaction calls the Terminal API.
-- Terminal does not call Interaction.
--
-- This keeps the dependency direction one-way and prevents a
-- Terminal <-> Interaction circular dependency.

--------------------------------------------------------------------
-- EXPLICIT LOAD-ORDER DEPENDENCIES
--
-- Project Zomboid loads client Lua files alphabetically within a
-- directory. "KIPN_Interaction" sorts before "KIPN_Terminal", so
-- without an explicit require here, the guard clause below would
-- always fail: KIPN_Terminal would not exist yet.
--
-- This require forces KIPN_Terminal to load first, regardless of
-- file iteration order. This is safe: KIPN_Terminal does NOT
-- require KIPN_Interaction, so no circular dependency is created.
--------------------------------------------------------------------

require "KIPN_Terminal"

--------------------------------------------------------------------
-- BOOT SCREEN DEPENDENCY
--
-- Interaction opens the standalone Boot Screen directly the moment
-- the player who powers on a computer is confirmed BOOTING (see the
-- POWER_STATUS handling in onServerResponse() below). "KIPN_BootScreen"
-- already sorts before "KIPN_Interaction" alphabetically, so this
-- require is defensive rather than strictly load-bearing today --
-- kept for the same documented reason as the KIPN_Terminal require
-- above, in case that ordering ever changes.
--------------------------------------------------------------------

require "KIPN_BootScreen"

--------------------------------------------------------------------
-- DISASSEMBLE ACTION DEPENDENCY
--
-- addDisassembleOption() below queues a KIPN_DisassembleComputerAction.
-- This require guarantees the base class it derives from is loaded
-- first, matching KIPN_VehicleClaimMenu.lua's existing convention.
--------------------------------------------------------------------

require "TimedActions/ISBaseTimedAction"

--------------------------------------------------------------------
-- NAMESPACE DEPENDENCY VALIDATION
--
-- The require "KIPN_Terminal" above guarantees the global KIPN
-- namespace and KIPN.Client already exist by this point, since
-- KIPN_Terminal.lua establishes them itself.
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_Interaction] "
        .. "KIPN namespace is not initialized."
    )

end


if not KIPN.Client then

    error(
        "[KIPN_Interaction] "
        .. "KIPN.Client is not initialized."
    )

end


--------------------------------------------------------------------
-- SHARED CONTRACT DEPENDENCY
--
-- Interaction uses shared protocol and identifier definitions.
--
-- Shared must therefore be initialized before this module.
--------------------------------------------------------------------

if not KIPN.Shared then

    error(
        "[KIPN_Interaction] "
        .. "KIPN_Shared is not initialized."
    )

end


--------------------------------------------------------------------
-- LOGGER DEPENDENCY
--
-- Interaction produces diagnostic output and therefore requires the
-- centralized KIPN logger.
--
-- There is intentionally no second logging implementation here.
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN_Interaction] "
        .. "KIPN_Logger is not initialized."
    )

end


--------------------------------------------------------------------
-- TERMINAL DEPENDENCY
--
-- Interaction opens the KIPN terminal.
--
-- The terminal itself must already be loaded and expose its public
-- opening interface before Interaction is initialized.
--
-- IMPORTANT:
--
-- Do NOT add:
--
--     require "KIPN_Interaction"
--
-- to KIPN_Terminal.lua.
--
-- That would create a circular dependency.
--------------------------------------------------------------------

if not KIPN_Terminal then

    error(
        "[KIPN_Interaction] "
        .. "KIPN_Terminal is not initialized."
    )

end


--------------------------------------------------------------------
-- BOOT STATE CACHE
--
-- Whether the square has electricity is answered instantly and
-- locally (hasWorldElectricity()) and never cached here. This
-- cache holds only the latest SERVER-CONFIRMED boot/session state
-- (KIPN.Shared.BootStates.OFF/BOOTING/ON) per computerId, used to
-- decide what the context menu offers ("Power On Computer" vs.
-- "Access KIP Network"/"Power Off Computer").
--
-- Whenever the context menu opens, Interaction requests a fresh
-- CHECK_POWER operation from the server.
--------------------------------------------------------------------

KIPN._bootStateCache =
    KIPN._bootStateCache or {}

--------------------------------------------------------------------
-- COMPUTER CONDITION CACHE
--
-- Last server-reported Hardware Condition (0-100) per computerId,
-- populated from the same POWER_STATUS round trip that populates
-- KIPN._bootStateCache above, plus COMPUTER_CONDITION_UPDATED after
-- a successful disassemble. Used to render a non-clickable
-- "Hardware Condition: NN%" label in the right-click menu. Same
-- "fails closed / silently omitted until first round trip"
-- philosophy as the boot-state cache.
--------------------------------------------------------------------

KIPN._conditionCache =
    KIPN._conditionCache or {}

--------------------------------------------------------------------
-- PENDING ENTRY
--
-- computerId -> world computer object. Marks "the next POWER_STATUS
-- reply for this computer should open something automatically" --
-- set right before requesting fresh power state, whether that
-- request came from "Power On Computer" (addPowerOnOption) or
-- "Access KIP Network" (addTerminalOption). See the POWER_STATUS
-- handling in onServerResponse() below, which is the single place
-- that consumes this and decides KIPN_BootScreen vs. KIPN_Terminal.
--------------------------------------------------------------------

KIPN._pendingEntry =
    KIPN._pendingEntry or {}

--------------------------------------------------------------------
-- AMBIENT COMPUTER SOUND STATE
--
-- Server-broadcast, world-wide (not scoped to "the player who
-- asked") -- see KIPN.Server.BroadcastToAll() and the
-- COMPUTER_SOUND_ON/OFF/SYNC handling in onComputerSoundResponse()
-- below.
--
-- KIPN._onComputers: computerId -> {x, y, z} for every computer the
-- server currently reports as BOOTING/ON. Purely a cache of server
-- state; it does NOT mean a sound is actually playing locally --
-- checkComputerAmbientLoops() (the periodic tick further below)
-- decides that based on the local player's proximity and whether
-- the square is even loaded on this client.
--
-- KIPN._computerOnLoopSounds: computerId -> the PlayWorldSound()
-- loop handle actually playing on THIS client right now, a subset
-- of KIPN._onComputers gated by proximity.
--
-- KIPN._computerDialUpSounds: computerId -> the PlayWorldSound()
-- one-shot handle for the "KIPN_DialUp" tone, if it may still be
-- playing on THIS client. The tone is started only when the server
-- marks COMPUTER_SOUND_ON as the result of an explicit "Power On
-- Computer" request; periodic/login reconciliation only restores
-- the loop/glow state. Tracked so a power-off/pickup that lands
-- mid-dial-tone can force-stop it immediately instead of letting it
-- play out over an already-silenced computer.
--
-- KIPN._computerGlowObjects: computerId -> the IsoLightSource
-- ("screen glow") currently registered with the cell for that
-- computer on THIS client, a subset of KIPN._onComputers gated by
-- proximity -- mirrors KIPN._computerOnLoopSounds exactly, just for
-- the visual effect instead of the audio loop. See
-- startComputerScreenGlow()/stopComputerScreenGlow() further below.
--------------------------------------------------------------------

KIPN._onComputers =
    KIPN._onComputers or {}

KIPN._computerOnLoopSounds =
    KIPN._computerOnLoopSounds or {}

-- computerId -> "healthy" | "damaged": which running-sound tier the
-- currently-playing loop in KIPN._computerOnLoopSounds was started for,
-- so the ambient tick can swap the loop when Hardware Condition crosses
-- the damaged threshold without waiting for a power cycle.
KIPN._computerOnLoopTier =
    KIPN._computerOnLoopTier or {}

KIPN._computerDialUpSounds =
    KIPN._computerDialUpSounds or {}

KIPN._computerGlowObjects =
    KIPN._computerGlowObjects or {}


--------------------------------------------------------------------
-- SAFE LOGGER HELPERS
--
-- These helpers centralize Interaction diagnostics through the
-- KIPN logger.
--
-- The fallback print is retained as a defensive measure for unusual
-- startup conditions, although the dependency validation above
-- normally guarantees that KIPN.Logger exists.
--------------------------------------------------------------------

local function logDebug(
    message
)

    if KIPN.Logger
        and KIPN.Logger.Debug
    then

    else

        print(
            "[KIPN INTERACTION] "
            .. tostring(message)
        )

    end

end


--------------------------------------------------------------------

local function logInfo(
    message
)

    if KIPN.Logger
        and KIPN.Logger.Info
    then

        KIPN.Logger.Info(
            tostring(message)
        )

    else

        print(
            "[KIPN INTERACTION] "
            .. tostring(message)
        )

    end

end


--------------------------------------------------------------------

local function logWarn(
    message
)

    if KIPN.Logger
        and KIPN.Logger.Warn
    then

        KIPN.Logger.Warn(
            tostring(message)
        )

    else

        print(
            "[KIPN INTERACTION] WARN: "
            .. tostring(message)
        )

    end

end


--------------------------------------------------------------------

local function logError(
    message
)

    if KIPN.Logger
        and KIPN.Logger.Error
    then

        KIPN.Logger.Error(
            tostring(message)
        )

    else

        print(
            "[KIPN INTERACTION] ERROR: "
            .. tostring(message)
        )

    end

end

--------------------------------------------------------------------
-- COMPUTER DETECTION
--------------------------------------------------------------------

local function isComputerObject(obj)

    local success =
        false

    local result =
        false

    local ok, err =
        pcall(
            function()

                logDebug(
                    "KIPN_Interaction:isComputerObject()"
                )

                if not obj then

                    logDebug(
                        "isComputerObject(): object is nil"
                    )

                    success = true

                    return
                end

                ----------------------------------------------------
                -- SPRITE/NAME DETECTION
                --
                -- Delegates to the shared heuristic
                -- (KIPN.Shared.IsComputerObjectSprite) so the
                -- client's world-object detection and the server's
                -- Hardware Condition modData resolution never drift
                -- apart.
                ----------------------------------------------------

                if KIPN.Shared
                    and KIPN.Shared.IsComputerObjectSprite
                    and KIPN.Shared.IsComputerObjectSprite(obj)
                then

                    logDebug(
                        "COMPUTER DETECTED obj=" ..
                        tostring(obj)
                    )

                    result =
                        true
                end

                success =
                    true
            end
        )

    if not ok then

        logError(
            "isComputerObject() failed: " ..
            tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- COMPUTER ID
--
-- The computer ID is deliberately based on the square.
--
-- This is important because the server checks the square for
-- electricity/generator power.
--
-- Therefore:
--
--     client computer ID
--             |
--             v
--     x/y/z square
--             |
--             v
--     server computer lookup
--             |
--             v
--     server square power check
--
-- No object hash is used because object hashes are unnecessary
-- and can make identity less predictable across client/server
-- boundaries.
--------------------------------------------------------------------

local function getComputerId(obj)

    local success =
        false

    local result =
        nil

    local ok, err =
        pcall(
            function()

                logDebug(
                    "KIPN_Interaction:getComputerId()"
                )

                if not obj then

                    logWarn(
                        "getComputerId(): object is nil"
                    )

                    return
                end

                if not obj.getSquare then

                    logWarn(
                        "getComputerId(): object has no getSquare()"
                    )

                    return
                end

                local square =
                    obj:getSquare()

                if not square then

                    logWarn(
                        "getComputerId(): object square is nil"
                    )

                    return
                end

                if not square.getX
                    or not square.getY
                    or not square.getZ
                then

                    logWarn(
                        "getComputerId(): square coordinate API unavailable"
                    )

                    return
                end

                local x =
                    square:getX()

                local y =
                    square:getY()

                local z =
                    square:getZ()

                if x == nil
                    or y == nil
                    or z == nil
                then

                    logWarn(
                        "getComputerId(): invalid square coordinates"
                    )

                    return
                end

                result =
                    string.format(
                        "comp_%d_%d_%d",
                        x,
                        y,
                        z
                    )

                logDebug(
                    "getComputerId(): resolved " ..
                    tostring(result)
                )

                success =
                    true
            end
        )

    if not ok then

        logError(
            "getComputerId() failed: " ..
            tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- IN-WORLD ELECTRICITY CHECK
--
-- "Does this square currently have power" is plain world state,
-- already replicated to every client the same way vanilla
-- appliances (lamps, fridges, TVs) read it - with no round trip,
-- because there is nothing here worth protecting with a server
-- request: a modified client claiming "I have power" gains nothing
-- beyond what the vanilla client already exposes.
--
-- IMPORTANT: square:haveElectricity() ALONE is not enough, and
-- hasGridPower() ALONE is too permissive. Vanilla itself never uses
-- hasGridPower() by itself for a stationary appliance - see
-- ISWorldObjectContextMenu.lua's car battery charger check (the same
-- family of object as a TV/computer sitting on furniture):
--
--   square:haveElectricity() or
--       (square:hasGridPower() and square:getRoom())
--
-- haveElectricity() reflects LOCAL/generator power specifically, and
-- is valid outdoors (a generator can sit anywhere, so no room check).
-- hasGridPower() reflects ordinary grid power before the world-wide
-- shutoff (SandboxVars.ElecShutModifier) - but it is true for the
-- ENTIRE map, indoors or out, until that shutoff happens. Without
-- also requiring square:getRoom() (i.e. the square is actually part
-- of a building interior), a computer sitting in the woods far from
-- any wiring - exactly like a TV never can - would incorrectly
-- report having power. See KIPN.Shared.HasSquareElectricity() for
-- the shared implementation this mirrors.
--------------------------------------------------------------------

local function hasWorldElectricity(obj)

    local success =
        false

    local result =
        false

    local ok, err =
        pcall(
            function()

                if not obj
                    or not obj.getSquare
                then

                    return
                end

                local square =
                    obj:getSquare()

                if not square then

                    return
                end

                local hasGeneratorMethod =
                    type(
                        square.haveElectricity
                    ) == "function"

                local hasGridMethod =
                    type(
                        square.hasGridPower
                    ) == "function"

                if not hasGeneratorMethod
                    and not hasGridMethod
                then

                    return
                end

                local generatorPowered =
                    hasGeneratorMethod
                    and square:haveElectricity()
                    == true

                local gridPowered =
                    hasGridMethod
                    and square:hasGridPower()
                    == true
                    and type(square.getRoom)
                    == "function"
                    and square:getRoom()
                    ~= nil

                result =
                    generatorPowered
                    or gridPowered

                success =
                    true
            end
        )

    if not ok then

        logError(
            "hasWorldElectricity() failed: " ..
            tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- REQUEST POWER STATE
--
-- This is asynchronous.
--
-- The server response will arrive through OnServerCommand and
-- update KIPN._bootStateCache.
--------------------------------------------------------------------

local function requestPowerState(
    computer
)

    local success =
        false

    local result =
        false

    local ok, err =
        pcall(
            function()

                logDebug(
                    "requestPowerState()"
                )

                if not computer then

                    logWarn(
                        "requestPowerState(): " ..
                        "computer is nil"
                    )

                    return
                end

                local computerId =
                    getComputerId(computer)

                if not computerId then

                    logWarn(
                        "requestPowerState(): " ..
                        "unable to generate computer ID"
                    )

                    return
                end

                if not sendClientCommand then

                    logError(
                        "requestPowerState(): " ..
                        "sendClientCommand() unavailable"
                    )

                    return
                end

                if not KIPN.Shared
                    or not KIPN.Shared.Commands
                    or not KIPN.Shared.Commands.CHECK_POWER
                then

                    logError(
                        "requestPowerState(): " ..
                        "CHECK_POWER command unavailable"
                    )

                    return
                end

                local payload = {

                    computerId =
                        computerId
                }

                local sent, sendError =
                    pcall(
                        function()

                            sendClientCommand(
                                "KIPN",
                                KIPN.Shared.Commands.CHECK_POWER,
                                payload
                            )
                        end
                    )

                if not sent then

                    logError(
                        "requestPowerState(): " ..
                        "sendClientCommand failed: " ..
                        tostring(sendError)
                    )

                    return
                end

                logDebug(
                    "CHECK_POWER sent for " ..
                    tostring(computerId)
                )

                result =
                    true

                success =
                    true
            end
        )

    if not ok then

        logError(
            "requestPowerState() failed: " ..
            tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- REQUEST SET POWER
--
-- Fire-and-forget, same shape as requestPowerState(). The player
-- explicitly chose "Power On Computer" / "Power Off Computer" from
-- the context menu - this sends that request to the server, which
-- is authoritative for whether it's actually allowed (building
-- electricity, etc). The response arrives asynchronously through
-- the existing POWER_STATUS handling in onServerResponse() and
-- updates KIPN._bootStateCache, the same cache the menu already
-- reads from.
--------------------------------------------------------------------

local function requestSetPower(
    computer,
    computerId,
    isOn
)

    local success =
        false

    local result =
        false

    local ok, err =
        pcall(
            function()

                logDebug(
                    "requestSetPower(): isOn=" ..
                    tostring(isOn)
                )

                if not computerId then

                    logWarn(
                        "requestSetPower(): " ..
                        "computerId is nil"
                    )

                    return
                end

                if not sendClientCommand then

                    logError(
                        "requestSetPower(): " ..
                        "sendClientCommand() unavailable"
                    )

                    return
                end

                if not KIPN.Shared
                    or not KIPN.Shared.Commands
                    or not KIPN.Shared.Commands.SET_POWER
                then

                    logError(
                        "requestSetPower(): " ..
                        "SET_POWER command unavailable"
                    )

                    return
                end

                local payload = {

                    computerId =
                        computerId,

                    isOn =
                        isOn == true
                }

                local sent, sendError =
                    pcall(
                        function()

                            sendClientCommand(
                                "KIPN",
                                KIPN.Shared.Commands.SET_POWER,
                                payload
                            )
                        end
                    )

                if not sent then

                    logError(
                        "requestSetPower(): " ..
                        "sendClientCommand failed: " ..
                        tostring(sendError)
                    )

                    return
                end

                logDebug(
                    "SET_POWER sent for " ..
                    tostring(computerId) ..
                    ": isOn=" ..
                    tostring(isOn)
                )

                result =
                    true

                success =
                    true
            end
        )

    if not ok then

        logError(
            "requestSetPower() failed: " ..
            tostring(err)
        )
    end

    return result
end

--------------------------------------------------------------------
-- ADD TERMINAL OPTION
--
-- Offered alongside "Power Off Computer" whenever the last
-- server-confirmed boot state is BOOTING or ON (see
-- onFillKIPNMenu) - it's only reached after hasWorldElectricity()
-- already confirmed the square has power.
--
-- This does NOT act on the stale KIPN._bootStateCache entry --
-- it marks KIPN._pendingEntry and sends a fresh CHECK_POWER
-- (requestPowerState()), so the decision (KIPN_BootScreen if still
-- BOOTING, KIPN_Terminal if ON) is always made from current server
-- data. See the POWER_STATUS handling in onServerResponse() below.
--------------------------------------------------------------------

local function addTerminalOption(
    context,
    computer,
    computerId
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                context:addOption(
                    "Access KIP Network",
                    computer,
                    function(compObj)

                        logDebug(
                            "KIPN terminal access selected"
                        )

                        if not computerId then

                            logError(
                                "Access KIP Network: computerId unavailable"
                            )

                            return
                        end

                        KIPN._pendingEntry[computerId] =
                            compObj

                        requestPowerState(
                            compObj
                        )
                    end
                )

                success =
                    true
            end
        )

    if not ok then

        logError(
            "addTerminalOption() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- ADD POWER ON OPTION
--
-- Offered instead of "Access KIP Network" whenever the last
-- server-confirmed boot state for this computer is OFF (or
-- unknown - fail closed, same philosophy as onFillKIPNMenu()'s
-- own fallback). The player must explicitly power the computer on
-- before "Access KIP Network" appears; see onFillKIPNMenu().
--
-- Marks KIPN._pendingEntry so that once the resulting POWER_STATUS
-- reply confirms BOOTING, the standalone KIPN_BootScreen pops open
-- automatically for THIS player -- the computer power-on event
-- itself, independent of ever opening a terminal. See the
-- POWER_STATUS handling in onServerResponse() below.
--------------------------------------------------------------------

local function addPowerOnOption(
    context,
    computer,
    computerId
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                context:addOption(
                    "Power On Computer",
                    computer,
                    function(compObj)

                        logDebug(
                            "Power On Computer selected"
                        )

                        if computerId then

                            KIPN._pendingEntry[computerId] =
                                compObj
                        end

                        requestSetPower(
                            compObj,
                            computerId,
                            true
                        )

                        local player =
                            getPlayer
                            and getPlayer()
                            or nil

                        if player
                            and player.Say
                        then

                            player:Say(
                                "Powering on..."
                            )
                        end
                    end
                )

                success =
                    true
            end
        )

    if not ok then

        logError(
            "addPowerOnOption() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- ADD POWER OFF OPTION
--
-- Offered alongside "Access KIP Network" whenever the last
-- server-confirmed boot state for this computer is BOOTING or ON.
-- Turning it off sets the server-side manualOff override, so it
-- stays off even while the building keeps real electricity - see
-- handleSetPower()/handleCheckPower() in KIPN_Server.lua.
--------------------------------------------------------------------

local function addPowerOffOption(
    context,
    computer,
    computerId
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                context:addOption(
                    "Power Off Computer",
                    computer,
                    function(compObj)

                        logDebug(
                            "Power Off Computer selected"
                        )

                        ------------------------------------------
                        -- SOUND
                        --
                        -- No local trigger here -- the server
                        -- broadcasts COMPUTER_SOUND_OFF once
                        -- SET_POWER actually completes, and that
                        -- broadcast is what stops the loop for
                        -- every player who can hear it (including
                        -- this one). See onComputerSoundResponse().
                        ------------------------------------------

                        requestSetPower(
                            compObj,
                            computerId,
                            false
                        )

                        local player =
                            getPlayer
                            and getPlayer()
                            or nil

                        if player
                            and player.Say
                        then

                            player:Say(
                                "Powering down..."
                            )
                        end
                    end
                )

                success =
                    true
            end
        )

    if not ok then

        logError(
            "addPowerOffOption() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- PLAYER HAS SCREWDRIVER
--
-- Best-effort client-side check for "Disassemble Computer" below.
-- The server independently re-checks this authoritatively in
-- handleDisassembleComputer -- this only decides whether the menu
-- option is offered at all.
--------------------------------------------------------------------

local function playerHasScrewdriver()

    local player =
        getPlayer
        and getPlayer()
        or nil

    if not player
        or not player.getInventory
    then

        return false
    end

    local inventory =
        player:getInventory()

    if not inventory
        or not inventory.contains
    then

        return false
    end

    return inventory:contains("Base.Screwdriver")
        or inventory:contains("Base.Screwdriver_Improvised")
        or inventory:contains("Base.Screwdriver_Old")
end

--------------------------------------------------------------------
-- PLAYER HAS COMPUTER REPAIR KIT
--
-- Best-effort client-side check for "Repair Computer" below. The
-- server independently re-checks this authoritatively in
-- handleRepairComputer -- this only decides whether the menu option
-- is offered at all.
--------------------------------------------------------------------

local function playerHasRepairKit()

    local player =
        getPlayer
        and getPlayer()
        or nil

    if not player
        or not player.getInventory
    then

        return false
    end

    local inventory =
        player:getInventory()

    if not inventory
        or not inventory.contains
    then

        return false
    end

    return inventory:contains("Base.KIPNComputerRepairKit")
end

--------------------------------------------------------------------
-- COMPUTER CONDITION REPAIR ENABLED
--
-- Client-side read of the same "0 = off" sandbox gate the server
-- enforces authoritatively in handleRepairComputer. Purely decides
-- whether the menu option is offered.
--------------------------------------------------------------------

local function computerRepairEnabled()

    return not (
        SandboxVars
        and SandboxVars.KIPN
        and SandboxVars.KIPN.ComputerConditionRepairPercentage == 0
    )
end

--------------------------------------------------------------------
-- ADD REPAIR OPTION
--
-- Offered whenever the last server-confirmed boot state is OFF (or
-- unknown) and computer repair has not been disabled entirely via
-- sandbox settings (computerRepairEnabled()) -- if it HAS been
-- disabled, the option is omitted altogether, same as before.
--
-- Otherwise the option is ALWAYS shown, but rendered red and made
-- non-selectable (option.notAvailable = true) whenever the last
-- known Hardware Condition is already 100%, or the player is
-- missing a screwdriver and/or a Computer Repair Kit -- so players
-- can see the option exists and understand why it's blocked,
-- rather than it silently disappearing. An unknown (not yet
-- cached) condition fails closed to "unavailable", matching this
-- file's existing "fail closed until first round trip" philosophy.
--
-- All of this is a best-effort client-side gate only -- computer
-- must be off, condition < 100%, required repair tool (default:
-- a screwdriver -- admin-configurable, see
-- KIPN_CraftingRequirementsConfig.lua's COMPUTER_REPAIR_TOOL), and
-- Computer Repair Kit are all re-validated authoritatively
-- server-side in KIPN_Server.lua's handleRepairComputer, matching
-- addDisassembleOption() below.
--
-- Repairing restores, but never exceeds 100%, Computer Condition.
-- The Computer Repair Kit itself IS consumed on a successful
-- repair -- the repair tool (screwdriver) is kept, like the one
-- required to disassemble a computer.
--------------------------------------------------------------------

local function addRepairOption(
    context,
    computer,
    computerId
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                if not computerRepairEnabled() then

                    success =
                        true

                    return
                end

                local cachedCondition =
                    KIPN._conditionCache[
                        computerId
                    ]

                local isMaxCondition =
                    cachedCondition == nil
                    or cachedCondition >= 100

                local hasRequiredItems =
                    playerHasScrewdriver()
                    and playerHasRepairKit()

                local option =
                    context:addOption(
                        "Repair Computer",
                        computer,
                        function(compObj)

                            logDebug(
                                "Repair Computer selected"
                            )

                            local player =
                                getPlayer
                                and getPlayer()
                                or nil

                            if not player then

                                return
                            end

                            if not KIPN_RepairComputerAction
                                or not KIPN_RepairComputerAction.CanStart
                                or not KIPN_RepairComputerAction.CanStart(player, true)
                            then
                                return
                            end

                            ISTimedActionQueue.add(
                                KIPN_RepairComputerAction:new(
                                    player,
                                    compObj,
                                    computerId
                                )
                            )
                        end
                    )

                if option
                    and (
                        isMaxCondition
                        or not hasRequiredItems
                    )
                then

                    option.notAvailable =
                        true
                end

                success =
                    true
            end
        )

    if not ok then

        logError(
            "addRepairOption() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- ADD DISASSEMBLE OPTION
--
-- Offered only when the last server-confirmed boot state is OFF
-- (or unknown) and the player carries a screwdriver. Both
-- conditions are re-validated authoritatively server-side in
-- KIPN_Server.lua's handleDisassembleComputer -- this is a
-- best-effort client-side gate only, matching this file's existing
-- all-or-nothing electricity-gate philosophy (the option is simply
-- omitted rather than shown disabled).
--
-- Disassembling degrades, but never destroys, Computer Condition -
-- the world object is never removed.
--------------------------------------------------------------------

local function addDisassembleOption(
    context,
    computer,
    computerId
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                if not playerHasScrewdriver() then

                    success =
                        true

                    return
                end

                context:addOption(
                    "Disassemble Computer",
                    computer,
                    function(compObj)

                        logDebug(
                            "Disassemble Computer selected"
                        )

                        local player =
                            getPlayer
                            and getPlayer()
                            or nil

                        if not player then

                            return
                        end

                        if not KIPN_DisassembleComputerAction
                            or not KIPN_DisassembleComputerAction.CanStart
                            or not KIPN_DisassembleComputerAction.CanStart(player, true)
                        then
                            return
                        end

                        ISTimedActionQueue.add(
                            KIPN_DisassembleComputerAction:new(
                                player,
                                compObj,
                                computerId
                            )
                        )
                    end
                )

                success =
                    true
            end
        )

    if not ok then

        logError(
            "addDisassembleOption() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- CONTEXT MENU
--------------------------------------------------------------------

local function onFillKIPNMenu(
    playerNum,
    context,
    worldObjects,
    test
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                logDebug(
                    "onFillKIPNMenu(): playerNum=" ..
                    tostring(playerNum) ..
                    " test=" ..
                    tostring(test)
                )

                if not context
                    or not worldObjects
                then

                    logWarn(
                        "onFillKIPNMenu(): " ..
                        "missing context/worldObjects"
                    )

                    return
                end

                ----------------------------------------------------
                -- TEST PHASE
                ----------------------------------------------------

                if test then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- FIND COMPUTER
                ----------------------------------------------------

                local computer =
                    nil

                for _, obj in ipairs(
                    worldObjects
                ) do

                    if isComputerObject(obj) then

                        computer =
                            obj

                        break
                    end
                end

                if not computer then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- COMPUTER ID
                ----------------------------------------------------

                local computerId =
                    getComputerId(
                        computer
                    )

                if not computerId then

                    logWarn(
                        "onFillKIPNMenu(): " ..
                        "could not generate computer ID"
                    )

                    return
                end

                logInfo(
                    "Building KIPN menu for computerId=" ..
                    tostring(computerId)
                )

                ----------------------------------------------------
                -- IN-WORLD ELECTRICITY (INSTANT, LOCAL) - THE GATE
                --
                -- This is a plain client-side read of world state,
                -- same as vanilla appliances. It does not depend on
                -- the CHECK_POWER command pipeline at all, so the
                -- menu is never stuck guessing because of a
                -- server-side issue with that pipeline.
                --
                -- No electricity -> no menu option, full stop. This
                -- is a hard prerequisite: even an explicit "Power On
                -- Computer" request will be rejected server-side
                -- (handleSetPower's own building-power check) when
                -- the building has no real electricity, so there is
                -- nothing useful to offer without it.
                ----------------------------------------------------

                local worldHasElectricity =
                    hasWorldElectricity(
                        computer
                    )

                logInfo(
                    "Computer electricity: " ..
                    "id=" ..
                    tostring(computerId) ..
                    " worldHasElectricity=" ..
                    tostring(worldHasElectricity)
                )

                if not worldHasElectricity then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- REQUEST FRESH SERVER STATE
                --
                -- Electricity is confirmed present. Whether this
                -- counts as booting/already-on versus off is
                -- server-owned persisted state - KIPN_Server.lua's
                -- handleCheckPower() reconciles it against real
                -- electricity automatically, deferring to a manual
                -- "Power Off" override (computer.manualOff) when one
                -- is in effect.
                --
                -- IMPORTANT:
                --
                -- This does NOT synchronously change the current
                -- menu. The response updates KIPN._bootStateCache
                -- for the NEXT time the menu is opened.
                ----------------------------------------------------

                requestPowerState(
                    computer
                )

                ----------------------------------------------------
                -- CHOOSE MENU OPTIONS FROM LAST KNOWN BOOT STATE
                --
                -- The player must explicitly power an off computer
                -- on before "Access KIP Network" is offered - there
                -- is no auto-boot-on-access. An unknown state (never
                -- checked yet) fails closed to "Power On Computer".
                ----------------------------------------------------

                local cachedBootState =
                    KIPN._bootStateCache[
                        computerId
                    ]

                if cachedBootState ==
                        KIPN.Shared.BootStates.ON
                    or cachedBootState ==
                        KIPN.Shared.BootStates.BOOTING
                then

                    addTerminalOption(
                        context,
                        computer,
                        computerId
                    )

                    addPowerOffOption(
                        context,
                        computer,
                        computerId
                    )

                else

                    addPowerOnOption(
                        context,
                        computer,
                        computerId
                    )

                    addDisassembleOption(
                        context,
                        computer,
                        computerId
                    )

                    addRepairOption(
                        context,
                        computer,
                        computerId
                    )
                end

                ----------------------------------------------------
                -- HARDWARE CONDITION LABEL
                --
                -- Non-clickable, only shown once a value has been
                -- cached from a prior POWER_STATUS/
                -- COMPUTER_CONDITION_UPDATED response -- same
                -- "silently omitted until first round trip"
                -- philosophy as cachedBootState above.
                ----------------------------------------------------

                local cachedCondition =
                    KIPN._conditionCache[
                        computerId
                    ]

                if cachedCondition ~= nil then

                    context:addOption(
                        "Hardware Condition: " ..
                        tostring(cachedCondition) ..
                        "%"
                    )
                end

                success =
                    true
            end
        )

    if not ok then

        logError(
            "onFillKIPNMenu() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- SERVER RESPONSE
--
-- CHECK_POWER returns:
--
-- {
--     event = POWER_STATUS,
--     data = {
--         computerId = "...",
--         bootState = "OFF" | "BOOTING" | "ON",
--         ...
--     }
-- }
--
-- The server is authoritative for bootState. Electricity itself
-- is never part of what this function caches - it's read fresh,
-- locally, via hasWorldElectricity() every time the menu opens.
--
-- This function ONLY caches the result.
--------------------------------------------------------------------

local function onServerResponse(
    module,
    command,
    args
)

    local success =
        false

    local ok, err =
        pcall(
            function()

                logDebug(
                    "onServerResponse(): module=" ..
                    tostring(module) ..
                    " command=" ..
                    tostring(command)
                )

                ----------------------------------------------------
                -- MODULE FILTER
                ----------------------------------------------------

                if module ~= "KIPN" then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- RESPONSE COMMAND FILTER
                ----------------------------------------------------

                if not KIPN.Shared
                    or not KIPN.Shared.Commands
                then

                    logWarn(
                        "onServerResponse(): " ..
                        "KIPN.Shared.Commands unavailable"
                    )

                    return
                end

                if command ~=
                    KIPN.Shared.Commands.SERVER_RESPONSE
                then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- ARGUMENTS
                ----------------------------------------------------

                if type(args) ~= "table" then

                    logWarn(
                        "onServerResponse(): " ..
                        "response args missing"
                    )

                    return
                end

                ----------------------------------------------------
                -- COMPUTER-RELATED ERROR RESPONSES
                --
                -- CHECK_POWER, SET_POWER, REPAIR_COMPUTER, or
                -- DISASSEMBLE_COMPUTER can all reject with a generic
                -- ERROR event (e.g. "Power On Computer" clicked with
                -- no building electricity -> NO_POWER, or "Repair
                -- Computer" clicked without a screwdriver ->
                -- MISSING_TOOL). Without this, the rejection is
                -- silently dropped: the boot-state cache is never
                -- updated (for power errors), and the player is
                -- never told why the request didn't work.
                ----------------------------------------------------

                if args.event ==
                    KIPN.Shared.ResponseEvents.ERROR
                then

                    local errorData =
                        args.data

                    local code =
                        type(errorData) == "table"
                        and errorData.code
                        or nil

                    local knownErrorCodes = {

                        INVALID_COMPUTER =
                            true,

                        POWER_STATUS_UNAVAILABLE =
                            true,

                        NO_POWER =
                            true,

                        POWER_CHANGE_FAILED =
                            true,

                        INVALID_POWER_STATE =
                            true,

                        -- REPAIR_COMPUTER / DISASSEMBLE_COMPUTER
                        -- application-level codes -- these never
                        -- carry errorData.command (only the
                        -- infrastructure-level router failures
                        -- below do), so they must be matched by
                        -- code here.
                        COMPUTER_NOT_OFF =
                            true,

                        MISSING_TOOL =
                            true,

                        MISSING_REPAIR_KIT =
                            true,

                        REPAIR_DISABLED =
                            true,

                        COMPUTER_ALREADY_REPAIRED =
                            true,
                    }

                    ----------------------------------------------------
                    -- INFRASTRUCTURE-LEVEL FAILURES
                    --
                    -- The command router (onClientCommand /
                    -- safeOnClientCommand in KIPN_Server.lua) can
                    -- also reject a request before it ever reaches
                    -- handleCheckPower - e.g. UNKNOWN_COMMAND if the
                    -- handler failed to register, or
                    -- SERVER_HANDLER_ERROR if the handler itself
                    -- threw. Those codes are not power-specific, but
                    -- the router echoes back which command triggered
                    -- them, so match on that instead of the code.
                    -- Without this, a server-side registration/
                    -- startup bug looks identical to this module
                    -- doing nothing at all: no success, no failure,
                    -- no message.
                    ----------------------------------------------------

                    local errorCommand =
                        type(errorData) == "table"
                        and errorData.command
                        or nil

                    local isKnownCommand =
                        errorCommand ==
                            KIPN.Shared.Commands.CHECK_POWER
                        or errorCommand ==
                            KIPN.Shared.Commands.SET_POWER
                        or errorCommand ==
                            KIPN.Shared.Commands.REPAIR_COMPUTER
                        or errorCommand ==
                            KIPN.Shared.Commands.DISASSEMBLE_COMPUTER

                    if code
                        and (
                            knownErrorCodes[code]
                            or isKnownCommand
                        )
                    then

                        local message =
                            type(errorData) == "table"
                            and errorData.message
                            or "Unable to complete the computer request."

                        logWarn(
                            "Computer request rejected: " ..
                            "code=" ..
                            tostring(code) ..
                            " message=" ..
                            tostring(message)
                        )

                        local player =
                            getPlayer
                            and getPlayer()
                            or nil

                        if player
                            and player.Say
                        then

                            player:Say(
                                tostring(message)
                            )
                        end
                    end

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- EVENT FILTER
                ----------------------------------------------------

                if not KIPN.Shared.ResponseEvents
                    or not KIPN.Shared.ResponseEvents.POWER_STATUS
                then

                    logWarn(
                        "onServerResponse(): " ..
                        "POWER_STATUS response event unavailable"
                    )

                    return
                end

                if args.event ~=
                    KIPN.Shared.ResponseEvents.POWER_STATUS
                then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- RESPONSE DATA
                ----------------------------------------------------

                local data =
                    args.data

                if type(data) ~= "table" then

                    logWarn(
                        "onServerResponse(): " ..
                        "POWER_STATUS data missing"
                    )

                    return
                end

                if not data.computerId then

                    logWarn(
                        "onServerResponse(): " ..
                        "POWER_STATUS computerId missing"
                    )

                    return
                end

                ----------------------------------------------------
                -- SERVER-AUTHORITATIVE BOOT STATE
                --
                -- Electricity presence itself is never cached here
                -- - it's read fresh, locally, every time the menu
                -- opens (hasWorldElectricity()). This cache only
                -- holds bootState, so "Access KIP Network" knows
                -- whether to show the boot screen.
                ----------------------------------------------------

                local computerId =
                    tostring(
                        data.computerId
                    )

                local bootState =
                    data.bootState

                KIPN._bootStateCache[
                    computerId
                ] =
                    bootState

                if data.condition ~= nil then

                    KIPN._conditionCache[
                        computerId
                    ] =
                        data.condition
                end

                logInfo(
                    "POWER_STATUS received: " ..
                    "computerId=" ..
                    computerId ..
                    " bootState=" ..
                    tostring(bootState)
                )

                ----------------------------------------------------
                -- PENDING ENTRY DISPATCH
                --
                -- Set by "Power On Computer" (for the requesting
                -- player only -- the server only replies to whoever
                -- sent the request) and by "Access KIP Network" (for
                -- any nearby player). Either way, this is the single
                -- place that decides what opens: KIPN_BootScreen if
                -- still BOOTING (sized to this response's real
                -- boot timing), straight into KIPN_Terminal if
                -- already ON.
                ----------------------------------------------------

                local pendingComputer =
                    KIPN._pendingEntry[
                        computerId
                    ]

                if pendingComputer then

                    KIPN._pendingEntry[
                        computerId
                    ] =
                        nil

                    if bootState ==
                        KIPN.Shared.BootStates.ON
                    then

                        if KIPN_Terminal
                            and KIPN_Terminal.OpenTerminal
                        then

                            KIPN_Terminal.OpenTerminal(
                                pendingComputer
                            )

                        else

                            logError(
                                "Pending entry: " ..
                                "KIPN_Terminal.OpenTerminal() " ..
                                "unavailable"
                            )
                        end

                    elseif bootState ==
                        KIPN.Shared.BootStates.BOOTING
                    then

                        if KIPN_BootScreen
                            and KIPN_BootScreen.Open
                        then

                            KIPN_BootScreen.Open(
                                pendingComputer,
                                computerId,
                                data
                            )

                        else

                            logError(
                                "Pending entry: " ..
                                "KIPN_BootScreen.Open() unavailable"
                            )
                        end

                    else

                        logWarn(
                            "Pending entry: unexpected bootState=" ..
                            tostring(bootState) ..
                            " for computerId=" ..
                            computerId
                        )
                    end
                end

                success =
                    true
            end
        )

    if not ok then

        logError(
            "onServerResponse() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- AMBIENT COMPUTER SOUND
--
-- Entirely server-driven (see KIPN_Server.lua's COMPUTER_SOUND_ON/
-- OFF/SYNC broadcasts) so every nearby player hears a computer's
-- looping "on" hum and any dial-up tone caused by an explicit
-- "Power On Computer" action, not just whoever flipped the switch.
-- The loop survives across logins/reconnects for as long as the
-- server still considers the computer on (COMPUTER_SOUND_SYNC
-- re-broadcasts the full picture on a timer); the one-shot does not.
--
-- This module has two moving parts:
--
--   1. onComputerSoundResponse() -- a SEPARATE OnServerCommand
--      listener (not folded into onServerResponse() above, to
--      avoid disturbing that function's existing POWER_STATUS
--      dispatch) that keeps KIPN._onComputers in sync with the
--      server's broadcasts and plays the dial-up one-shot only when
--      the event is marked as an explicit manual power-on.
--
--   2. checkComputerAmbientLoops() -- a throttled OnTick handler
--      that starts/stops the actual looping PlayWorldSound() for
--      any computer in KIPN._onComputers based on the LOCAL
--      player's proximity, mirroring vanilla ambient-sound
--      patterns (a world sound only matters once its square is
--      loaded/near enough to be audible anyway).
--------------------------------------------------------------------

local AMBIENT_LOOP_RADIUS_TILES =
    15

local AMBIENT_CHECK_INTERVAL_MS =
    2000

local lastAmbientCheckMs =
    0

-- Below this server-reported Hardware Condition (0-100) a powered
-- computer's ambient loop uses the degraded "struggling hardware"
-- variant instead of the clean running sound.
local COMPUTER_DAMAGED_SOUND_CONDITION =
    50

-- "healthy" | "damaged" for a computer, from its last server-reported
-- Hardware Condition. An unknown condition is treated as healthy so a
-- computer never sounds broken just because its condition has not
-- synced to this client yet.
local function resolveComputerLoopTier(
    computerId
)

    local condition =
        KIPN._conditionCache[
            computerId
        ]

    if type(condition) == "number"
        and condition < COMPUTER_DAMAGED_SOUND_CONDITION
    then

        return "damaged"
    end

    return "healthy"
end

local function pickComputerOnLoopSoundName(
    computerId
)

    if resolveComputerLoopTier(computerId) == "damaged" then

        return "KIPN_computerOnDamage2"
    end

    if ZombRand(1, 3) == 1 then

        return "KIPN_computerOn1"
    end

    return "KIPN_computerOn2"
end

local function stopComputerOnLoop(
    computerId
)

    local soundId =
        KIPN._computerOnLoopSounds[
            computerId
        ]

    if not soundId then

        return
    end

    pcall(
        function()

            getSoundManager():StopSound(
                soundId
            )
        end
    )

    KIPN._computerOnLoopSounds[
        computerId
    ] = nil

    KIPN._computerOnLoopTier[
        computerId
    ] = nil
end

local function stopComputerDialUp(
    computerId
)

    local soundId =
        KIPN._computerDialUpSounds[
            computerId
        ]

    if not soundId then

        return
    end

    pcall(
        function()

            getSoundManager():StopSound(
                soundId
            )
        end
    )

    KIPN._computerDialUpSounds[
        computerId
    ] = nil
end

--------------------------------------------------------------------
-- PLAY COMPUTER OFF TONE
--
-- Shared by the COMPUTER_SOUND_OFF broadcast handler and the local
-- "computer object physically removed" handling below, so both
-- power-off and pickup play the exact same one-shot.
--------------------------------------------------------------------

local function playComputerOffTone(
    x,
    y,
    z
)

    if not x
        or not y
        or not z
    then

        return
    end

    local okSquare,
        square =
        pcall(
            function()

                return getCell():getGridSquare(
                    x,
                    y,
                    z
                )
            end
        )

    if not okSquare
        or not square
    then

        return
    end

    pcall(
        function()

            getSoundManager():PlayWorldSound(
                "KIPN_computerOff",
                square,
                0,
                8,
                1,
                false
            )
        end
    )
end

local function startComputerOnLoop(
    computerId,
    x,
    y,
    z
)

    if KIPN._computerOnLoopSounds[
        computerId
    ] then

        return
    end

    if not getCell then

        return
    end

    local okSquare,
        square =
        pcall(
            function()

                return getCell():getGridSquare(
                    x,
                    y,
                    z
                )
            end
        )

    if not okSquare
        or not square
    then

        return
    end

    local tier =
        resolveComputerLoopTier(
            computerId
        )

    local okSound,
        soundId =
        pcall(
            function()

                return getSoundManager():PlayWorldSound(
                    pickComputerOnLoopSoundName(computerId),
                    true,
                    square,
                    0,
                    8,
                    1,
                    false
                )
            end
        )

    if okSound
        and soundId
    then

        KIPN._computerOnLoopSounds[
            computerId
        ] = soundId

        KIPN._computerOnLoopTier[
            computerId
        ] = tier
    end
end

--------------------------------------------------------------------
-- SCREEN GLOW
--
-- Attaches a TV-style light-emitting glow at a powered-on computer's
-- world position, and removes it again on power-off/pickup -- the
-- same lifecycle as the ambient sound loop above, just for the
-- visual instead of the audio.
--
-- IMPORTANT -- NOT IsoObject:setLightSource():
--
-- setLightSource() only exists on IsoThumpable (doors, generators,
-- and similar special world objects) -- KIPN computers are placed as
-- plain IsoObject sprites (detected by
-- KIPN.Shared.IsComputerObjectSprite()'s sprite/name heuristic, see
-- isComputerObject() above), which have no such method at all. That
-- earlier approach failed silently every time (the call was wrapped
-- in a pcall, so the missing-method error was swallowed and nothing
-- was ever logged) -- the light never actually appeared.
--
-- The correct vanilla API for a standalone light not tied to a
-- specific IsoThumpable is IsoCell:addLamppost()/removeLamppost()
-- (the same mechanism vanilla street lamps use) -- both accept
-- either an existing IsoLightSource or raw x/y/z/r/g/b/radius
-- directly. See media/lua Candle stubs for
-- zombie.iso.IsoCell:addLamppost/removeLamppost.
--------------------------------------------------------------------

local COMPUTER_GLOW_R =
    0.55

local COMPUTER_GLOW_G =
    0.70

local COMPUTER_GLOW_B =
    0.85

local COMPUTER_GLOW_RADIUS =
    4

local function findComputerObjectAt(
    x,
    y,
    z
)

    if not getCell then

        return nil
    end

    local okSquare,
        square =
        pcall(
            function()

                return getCell():getGridSquare(
                    x,
                    y,
                    z
                )
            end
        )

    if not okSquare
        or not square
    then

        return nil
    end

    local okObjects,
        objects =
        pcall(
            function()

                return square:getObjects()
            end
        )

    if not okObjects
        or not objects
    then

        return nil
    end

    for i = 0, objects:size() - 1 do

        local obj =
            objects:get(i)

        if isComputerObject(
            obj
        ) then

            return obj
        end
    end

    return nil
end

local function stopComputerScreenGlow(
    computerId
)

    local light =
        KIPN._computerGlowObjects[
            computerId
        ]

    if not light then

        return
    end

    pcall(
        function()

            if light.setActive then
                light:setActive(false)
            end

            getCell():removeLamppost(
                light
            )

            IsoGridSquare.setRecalcLightTime(
                -1.0
            )
        end
    )

    KIPN._computerGlowObjects[
        computerId
    ] = nil
end

local function startComputerScreenGlow(
    computerId,
    x,
    y,
    z
)

    if KIPN._computerGlowObjects[
        computerId
    ] then

        return
    end

    local obj =
        findComputerObjectAt(
            x,
            y,
            z
        )

    if not obj then

        return
    end

    local ok,
        light =
        pcall(
            function()

                local lightSource =
                    getCell():addLamppost(
                        x,
                        y,
                        z,
                        COMPUTER_GLOW_R,
                        COMPUTER_GLOW_G,
                        COMPUTER_GLOW_B,
                        COMPUTER_GLOW_RADIUS
                    )

                if lightSource
                    and lightSource.setActive
                then

                    lightSource:setActive(
                        true
                    )
                end

                IsoGridSquare.setRecalcLightTime(
                    -1.0
                )

                return lightSource
            end
        )

    if ok
        and light
    then

        KIPN._computerGlowObjects[
            computerId
        ] = light
    end
end

--------------------------------------------------------------------
-- HANDLE COMPUTER REMOVED (POWERED OFF OR PICKED UP)
--
-- The single place that reacts to a computer's physical object no
-- longer being the one making sound: stops the loop AND any
-- still-playing dial-up tone on THIS client immediately, plays the
-- power-off tone at its last known position, drops it from the
-- local "on" cache so nothing restarts it, and tells the server so
-- the persisted record (and every other client) converges too.
--
-- Called from two places:
--
--   1. onComputerObjectAboutToBeRemoved() -- the SAME tick a
--      player picks the computer up (or otherwise removes it),
--      for whoever performed that action.
--
--   2. checkComputerAmbientLoops()'s physical-presence check --
--      a polling fallback (every AMBIENT_CHECK_INTERVAL_MS) that
--      catches every other case: another player's client, a
--      removal that doesn't fire OnObjectAboutToBeRemoved, etc.
--------------------------------------------------------------------

local function handleComputerRemoved(
    computerId,
    x,
    y,
    z
)

    if not computerId then

        return
    end

    ------------------------------------------------------------
    -- Only an already-ON computer transitions to "removed" here
    -- -- a computer that was off has no loop/glow to stop and no
    -- power-off tone to play, so a pickup of it must stay silent.
    ------------------------------------------------------------

    if not KIPN._onComputers[
        computerId
    ] then

        return
    end

    KIPN._onComputers[
        computerId
    ] = nil

    -- The physical computer is gone (picked up) or the server just
    -- told us it powered off -- drop the cached "on" menu state too
    -- so a re-place doesn't briefly offer "Access KIP Network"
    -- before the next CHECK_POWER round trip.
    KIPN._bootStateCache[
        computerId
    ] =
        KIPN.Shared.BootStates.OFF

    stopComputerOnLoop(
        computerId
    )

    stopComputerDialUp(
        computerId
    )

    stopComputerScreenGlow(
        computerId
    )

    playComputerOffTone(
        x,
        y,
        z
    )

    requestSetPower(
        nil,
        computerId,
        false
    )
end

--------------------------------------------------------------------
-- PROXIMITY TICK
--
-- Every AMBIENT_CHECK_INTERVAL_MS: start a loop for any known-on
-- computer within AMBIENT_LOOP_RADIUS_TILES of the local player,
-- and stop any currently-playing loop whose computer the server no
-- longer reports as on. Distance is checked in 2D (x/y only) since
-- KIPN computers don't need cross-floor audibility.
--------------------------------------------------------------------

local function checkComputerAmbientLoops()

    local player =
        getPlayer
        and getPlayer()
        or nil

    if not player then

        return
    end

    local px =
        player:getX()

    local py =
        player:getY()

    local radiusSq =
        AMBIENT_LOOP_RADIUS_TILES
        * AMBIENT_LOOP_RADIUS_TILES

    ----------------------------------------------------------------
    -- PHYSICAL PRESENCE CHECK
    --
    -- KIPN._onComputers only reflects the SERVER's last-known power
    -- state -- it has no idea whether the world object at those
    -- coordinates still exists. A computer that gets picked up (or
    -- otherwise removed) leaves no trace the server would notice on
    -- its own, so without this the ambient loop/dial-up tone would
    -- keep playing from the old square indefinitely. For every
    -- computer the server still thinks is on, if its square happens
    -- to be loaded here and no longer contains a matching computer
    -- object, treat that exactly like an explicit power-off. This
    -- is a polling fallback; the immediate, same-tick stop for
    -- whoever actually performs the pickup lives in
    -- onComputerObjectAboutToBeRemoved() below.
    ----------------------------------------------------------------

    for computerId, info in pairs(
        KIPN._onComputers
    ) do

        local okSquare,
            square =
            pcall(
                function()

                    return getCell():getGridSquare(
                        info.x,
                        info.y,
                        info.z
                    )
                end
            )

        if okSquare
            and square
        then

            local stillPresent =
                false

            local okObjects,
                objects =
                pcall(
                    function()

                        return square:getObjects()
                    end
                )

            if okObjects
                and objects
            then

                for i = 0, objects:size() - 1 do

                    if isComputerObject(
                        objects:get(i)
                    ) then

                        stillPresent =
                            true

                        break
                    end
                end
            end

            if not stillPresent then

                handleComputerRemoved(
                    computerId,
                    info.x,
                    info.y,
                    info.z
                )
            end
        end
    end

    for computerId, info in pairs(
        KIPN._onComputers
    ) do

        local dx =
            info.x - px

        local dy =
            info.y - py

        if (dx * dx + dy * dy)
            <= radiusSq
        then

            ----------------------------------------------------
            -- CONDITION-TIER SWAP
            --
            -- If a loop is already playing but Hardware Condition
            -- has since crossed the damaged threshold in either
            -- direction, stop it so the block below restarts it
            -- with the correct (clean / degraded) variant. Without
            -- this the sound would only change on a power cycle.
            ----------------------------------------------------

            if KIPN._computerOnLoopSounds[computerId]
                and KIPN._computerOnLoopTier[computerId]
                    ~= resolveComputerLoopTier(computerId)
            then

                stopComputerOnLoop(
                    computerId
                )
            end

            startComputerOnLoop(
                computerId,
                info.x,
                info.y,
                info.z
            )

            startComputerScreenGlow(
                computerId,
                info.x,
                info.y,
                info.z
            )
        end
    end

    for computerId, _ in pairs(
        KIPN._computerOnLoopSounds
    ) do

        if not KIPN._onComputers[
            computerId
        ] then

            stopComputerOnLoop(
                computerId
            )
        end
    end

    for computerId, _ in pairs(
        KIPN._computerGlowObjects
    ) do

        if not KIPN._onComputers[
            computerId
        ] then

            stopComputerScreenGlow(
                computerId
            )
        end
    end
end

local function onAmbientTick()

    if not _G.getTimestampMs then

        return
    end

    local now =
        getTimestampMs()

    if now - lastAmbientCheckMs
        < AMBIENT_CHECK_INTERVAL_MS
    then

        return
    end

    lastAmbientCheckMs =
        now

    local ok, err =
        pcall(
            checkComputerAmbientLoops
        )

    if not ok then

        logError(
            "onAmbientTick() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- SERVER BROADCAST LISTENER
--------------------------------------------------------------------

local function onComputerSoundResponse(
    module,
    command,
    args
)

    local ok, err =
        pcall(
            function()

                if module ~= "KIPN" then

                    return
                end

                if not KIPN.Shared
                    or not KIPN.Shared.Commands
                    or command ~=
                        KIPN.Shared.Commands.SERVER_RESPONSE
                then

                    return
                end

                if type(args) ~= "table" then

                    return
                end

                local event =
                    args.event

                local data =
                    args.data

                if type(data) ~= "table" then

                    return
                end

                ------------------------------------------------
                -- COMPUTER_SOUND_ON
                ------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.COMPUTER_SOUND_ON
                then

                    local computerId =
                        data.computerId

                    if not computerId
                        or not data.x
                        or not data.y
                        or not data.z
                    then

                        return
                    end

                    KIPN._onComputers[
                        computerId
                    ] = {
                        x = data.x,
                        y = data.y,
                        z = data.z,
                    }

                    -- Live Hardware Condition, so the ambient loop can
                    -- switch to the degraded (<50%) variant for every
                    -- nearby client, not just after a local interaction.
                    if type(data.condition) == "number" then

                        KIPN._conditionCache[
                            tostring(computerId)
                        ] =
                            data.condition
                    end

                    ----------------------------------------------
                    -- SEED THE BOOT-STATE CACHE
                    --
                    -- COMPUTER_SOUND_ON is a server-authoritative
                    -- "this computer is BOOTING/ON" broadcast that
                    -- survives reconnects (COMPUTER_SOUND_SYNC re-
                    -- sends it). Without seeding KIPN._bootStateCache
                    -- here, onFillKIPNMenu() has no confirmed state
                    -- after a fresh login and fails closed to "Power
                    -- On Computer" -- even while this client is
                    -- already playing the "on" hum for that same
                    -- computer. The real BOOTING-vs-ON decision is
                    -- still made from a fresh CHECK_POWER when the
                    -- player actually picks "Access KIP Network"
                    -- (see addTerminalOption / the POWER_STATUS
                    -- dispatch above); this only fixes which option
                    -- the menu offers.
                    ----------------------------------------------

                    KIPN._bootStateCache[
                        computerId
                    ] =
                        data.bootState
                        or KIPN.Shared.BootStates.ON

                    -- A COMPUTER_SOUND_ON event can also be emitted
                    -- by the periodic server reconciliation when a
                    -- player logs in near an already-on computer.
                    -- That path must restore only ambient state, not
                    -- replay the boot one-shot. handleSetPower() is
                    -- the only server path that sets playDialUp.
                    if data.playDialUp == true
                    then

                        local okSquare,
                            square =
                            pcall(
                                function()

                                    return getCell():getGridSquare(
                                        data.x,
                                        data.y,
                                        data.z
                                    )
                                end
                            )

                        if okSquare
                            and square
                        then

                            local okDialUp,
                                dialUpSoundId =
                                pcall(
                                    function()

                                        return getSoundManager():PlayWorldSound(
                                            "KIPN_DialUp",
                                            square,
                                            0,
                                            8,
                                            1,
                                            false
                                        )
                                    end
                                )

                            if okDialUp
                                and dialUpSoundId
                            then

                                KIPN._computerDialUpSounds[
                                    computerId
                                ] = dialUpSoundId
                            end
                        end
                    end

                    return
                end

                ------------------------------------------------
                -- COMPUTER_SOUND_OFF
                --
                -- Always stops BOTH the looping "on" hum and any
                -- still-playing dial-up one-shot immediately -- a
                -- power-off landing mid-dial-tone must not let the
                -- tone finish playing over a now-silent computer.
                ------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.COMPUTER_SOUND_OFF
                then

                    local computerId =
                        data.computerId

                    if not computerId then

                        return
                    end

                    KIPN._onComputers[
                        computerId
                    ] = nil

                    -- Keep the menu's boot-state cache converged with
                    -- the ambient-sound state (see the COMPUTER_SOUND_ON
                    -- seeding note above).
                    KIPN._bootStateCache[
                        computerId
                    ] =
                        KIPN.Shared.BootStates.OFF

                    stopComputerOnLoop(
                        computerId
                    )

                    stopComputerDialUp(
                        computerId
                    )

                    stopComputerScreenGlow(
                        computerId
                    )

                    playComputerOffTone(
                        data.x,
                        data.y,
                        data.z
                    )

                    return
                end

                ------------------------------------------------
                -- COMPUTER_SOUND_SYNC
                --
                -- Full snapshot -- rebuild KIPN._onComputers from
                -- it wholesale and stop any locally-playing loop
                -- for a computerId that fell out of the list
                -- (self-healing against a missed OFF broadcast).
                ------------------------------------------------

                if event ==
                    KIPN.Shared.ResponseEvents.COMPUTER_SOUND_SYNC
                then

                    local newOnComputers =
                        {}

                    if type(data.computers) == "table" then

                        for _, entry in ipairs(
                            data.computers
                        ) do

                            if entry.computerId
                                and entry.x
                                and entry.y
                                and entry.z
                            then

                                newOnComputers[
                                    entry.computerId
                                ] = {
                                    x = entry.x,
                                    y = entry.y,
                                    z = entry.z,
                                }

                                -- Keep the right-click menu's
                                -- boot-state cache in step with this
                                -- authoritative snapshot (see the
                                -- COMPUTER_SOUND_ON seeding note
                                -- above) so a reconnecting player is
                                -- offered "Access KIP Network" for an
                                -- already-on computer straight away.
                                KIPN._bootStateCache[
                                    entry.computerId
                                ] =
                                    entry.bootState
                                    or KIPN.Shared.BootStates.ON

                                -- Live Hardware Condition for the
                                -- ambient-loop tier decision (clean vs.
                                -- degraded <50% sound). The proximity
                                -- pass in checkComputerAmbientLoops()
                                -- swaps a playing loop when this crosses
                                -- the threshold.
                                if type(entry.condition) == "number" then

                                    KIPN._conditionCache[
                                        tostring(entry.computerId)
                                    ] =
                                        entry.condition
                                end
                            end
                        end
                    end

                    ------------------------------------------------
                    -- A computer that dropped out of the snapshot
                    -- is no longer BOOTING/ON -- converge its cached
                    -- menu state to OFF too, mirroring the loop/glow
                    -- teardown below.
                    ------------------------------------------------

                    for computerId, _ in pairs(
                        KIPN._onComputers
                    ) do

                        if not newOnComputers[
                            computerId
                        ] then

                            KIPN._bootStateCache[
                                computerId
                            ] =
                                KIPN.Shared.BootStates.OFF
                        end
                    end

                    for computerId, _ in pairs(
                        KIPN._computerOnLoopSounds
                    ) do

                        if not newOnComputers[
                            computerId
                        ] then

                            stopComputerOnLoop(
                                computerId
                            )

                            stopComputerDialUp(
                                computerId
                            )
                        end
                    end

                    for computerId, _ in pairs(
                        KIPN._computerDialUpSounds
                    ) do

                        if not newOnComputers[
                            computerId
                        ] then

                            stopComputerDialUp(
                                computerId
                            )
                        end
                    end

                    for computerId, _ in pairs(
                        KIPN._computerGlowObjects
                    ) do

                        if not newOnComputers[
                            computerId
                        ] then

                            stopComputerScreenGlow(
                                computerId
                            )
                        end
                    end

                    KIPN._onComputers =
                        newOnComputers
                end
            end
        )

    if not ok then

        logError(
            "onComputerSoundResponse() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- COMPUTER OBJECT ABOUT TO BE REMOVED
--
-- Fires (vanilla Events.OnObjectAboutToBeRemoved) the moment a
-- world object is picked up, scrapped, or otherwise taken off the
-- square -- including the vanilla "pick up/move" flow used on
-- movable furniture-type objects like KIPN computers. This is what
-- makes the sound "tied to the physical object": the player who
-- just picked it up hears the loop/dial-up tone stop and the
-- power-off tone play on THIS SAME TICK, rather than waiting for
-- checkComputerAmbientLoops()'s polling fallback or a server round
-- trip.
--------------------------------------------------------------------

local function onComputerObjectAboutToBeRemoved(
    object
)

    local ok, err =
        pcall(
            function()

                if not object then

                    return
                end

                if not isComputerObject(
                    object
                ) then

                    return
                end

                ----------------------------------------------------
                -- The object is still ON the square at this point
                -- (this fires just before removal), so its own
                -- coordinates are the correct place to play the
                -- off tone from.
                ----------------------------------------------------

                local square =
                    object.getSquare
                    and object:getSquare()

                local x =
                    square
                    and square.getX
                    and square:getX()

                local y =
                    square
                    and square.getY
                    and square:getY()

                local z =
                    square
                    and square.getZ
                    and square:getZ()

                local computerId =
                    getComputerId(
                        object
                    )

                if not computerId then

                    return
                end

                handleComputerRemoved(
                    computerId,
                    x,
                    y,
                    z
                )
            end
        )

    if not ok then

        logError(
            "onComputerObjectAboutToBeRemoved() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- COMPUTER CONDITION UPDATED RESPONSE
--
-- Fired after a successful "Disassemble Computer" or "Repair
-- Computer" action so the right-click condition label
-- (KIPN._conditionCache) refreshes immediately, without waiting for
-- the next POWER_STATUS round trip. data.repairApplied is only
-- present on a repair response (data.degradationApplied on a
-- disassemble response) -- used below only to pick the right verb.
--------------------------------------------------------------------

local function onComputerConditionUpdated(
    module,
    command,
    args
)

    local ok, err =
        pcall(
            function()

                if module ~= "KIPN" then

                    return
                end

                if not KIPN.Shared
                    or not KIPN.Shared.Commands
                    or command ~=
                        KIPN.Shared.Commands.SERVER_RESPONSE
                then

                    return
                end

                if type(args) ~= "table" then

                    return
                end

                if args.event ~=
                    KIPN.Shared.ResponseEvents.COMPUTER_CONDITION_UPDATED
                then

                    return
                end

                local data =
                    args.data

                if type(data) ~= "table"
                    or not data.computerId
                    or data.condition == nil
                then

                    return
                end

                KIPN._conditionCache[
                    tostring(data.computerId)
                ] =
                    data.condition

                local player =
                    getPlayer
                    and getPlayer()
                    or nil

                if player
                    and player.Say
                then

                    local verb =
                        "Disassembled"

                    if data.repairApplied ~= nil then

                        verb =
                            "Repaired"
                    end

                    local suffix =
                        ""

                    if data.repairKitConsumed == true then

                        suffix =
                            " Repair Kit consumed."
                    end

                    player:Say(
                        verb ..
                        ". Hardware condition: " ..
                        tostring(data.condition) ..
                        "%" ..
                        suffix
                    )
                end
            end
        )

    if not ok then

        logError(
            "onComputerConditionUpdated() failed: " ..
            tostring(err)
        )
    end
end

--------------------------------------------------------------------
-- EVENT REGISTRATION
--------------------------------------------------------------------

if Events
    and Events.OnServerCommand
then

    Events.OnServerCommand.Add(
        onServerResponse
    )

    Events.OnServerCommand.Add(
        onComputerSoundResponse
    )

    Events.OnServerCommand.Add(
        onComputerConditionUpdated
    )

    logDebug(
        "OnServerCommand registered"
    )

else

    logError(
        "Events.OnServerCommand is unavailable"
    )
end

if Events
    and Events.OnTick
then

    Events.OnTick.Add(
        onAmbientTick
    )

    logDebug(
        "OnTick registered for ambient computer sound"
    )

else

    logError(
        "Events.OnTick is unavailable; " ..
        "ambient computer sound will not play."
    )
end

if Events
    and Events.OnFillWorldObjectContextMenu
then

    Events.OnFillWorldObjectContextMenu.Add(
        onFillKIPNMenu
    )

    logInfo(
        "OnFillWorldObjectContextMenu registered"
    )

else

    logError(
        "Events.OnFillWorldObjectContextMenu is unavailable"
    )
end

if Events
    and Events.OnObjectAboutToBeRemoved
then

    Events.OnObjectAboutToBeRemoved.Add(
        onComputerObjectAboutToBeRemoved
    )

    logDebug(
        "OnObjectAboutToBeRemoved registered " ..
        "for computer pickup/removal sound handling"
    )

else

    logError(
        "Events.OnObjectAboutToBeRemoved is unavailable; " ..
        "a picked-up computer's sound will only stop via " ..
        "the polling fallback in checkComputerAmbientLoops()."
    )
end

--------------------------------------------------------------------
-- MODULE READY
--------------------------------------------------------------------

print(
    "[KIPN] Interaction handler loaded with " ..
    "server-authoritative power controls"
)
