-- KIPN_SplashScreen.lua
-- Branded splash screen shown at the end of the boot process.
--
-- This screen is a STANDALONE application, triggered directly by
-- KIPN_BootScreen once its own boot sequence completes. It is NOT a
-- child of KIPN_Terminal.
--
-- Responsibilities:
--   * own its own UIManager membership (KIPN_SplashScreen.Open())
--   * own its own proximity check (closes only when the player
--     walks more than KIPN_Terminal.MAX_PROXIMITY squares away --
--     there is no other way to dismiss it)
--   * Hold briefly on a blank terminal after the boot animation
--     finishes (a short pause).
--   * Render the KIPN branded splash art for a brief time, scaled up
--     to fill the same screen rect KIPN_Terminal occupies.
--   * Hand off to KIPN_Terminal (which opens on KIPN_MainMenu) once
--     its display timer elapses.
--
-- This screen does NOT own:
--   * boot diagnostics (that is KIPN_BootScreen)
--   * authentication
--   * session state
--   * terminal chrome
--   * a terminal instance
--   * logout
--
-- KIPN_BootScreen opens this screen once, on successful boot
-- completion -- see KIPN_BootScreen:completeBoot(). This screen is
-- the only thing that opens KIPN_Terminal after boot; it does so
-- itself, once its own pause+display timer elapses.
--
-- Splash is a ONE-SHOT flourish: if the player walks away before it
-- finishes, it simply closes (see checkProximity()) and is not
-- replayed. A later "Access KIP Network" click sees the computer's
-- boot state is already ON and goes straight to the terminal.
--
-- DEPENDENCY CONTRACT
--
-- KIPN_SplashScreen is a CLIENT-SIDE STANDALONE APPLICATION.
--
-- Like KIPN_BootScreen, it is NOT built on top of the shared
-- KIPN_UI BBS-terminal framework -- it owns its own colors, layout,
-- and scanline rendering directly against ISPanel.
--
-- KIPN_SplashScreen depends on:
--
--   KIPN_Logger
--       |
--       +-- KIPN namespace
--       +-- centralized logging
--
--   Project Zomboid UI
--       |
--       +-- ISPanel
--
-- KIPN_SplashScreen does NOT require:
--
--   * KIPN_UI
--   * KIPN_Shared
--   * KIPN_Server
--   * server-side services
--
-- IMPORTANT:
--
-- This module must never create its own global OnServerCommand
-- listener. It has no server interaction at all.
--------------------------------------------------------------------


--------------------------------------------------------------------


local LOGO_GLYPH_COLS = 5
local LOGO_GLYPH_ROWS = 7
local LOGO_GLYPH_GAP_COLS = 1
local LOGO_ROW_GAP_CELLS = 4   -- gap rows between "KIP" and "NETWORK"

-- LOGO_TOTAL_COLS and drawBlockLogo are defined after LOGO_GLYPHS
-- (below), because they depend on LOGO_ROWS and LOGO_GLYPHS.

--------------------------------------------------------------------

require "ISUI/ISPanel"
require "KIPN_UI"


--------------------------------------------------------------------
-- NAMESPACE DEPENDENCY VALIDATION
--------------------------------------------------------------------

if not KIPN then

    error(
        "[KIPN_SplashScreen] "
        .. "KIPN namespace is not initialized."
    )

end


--------------------------------------------------------------------
-- LOGGER DEPENDENCY
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN_SplashScreen] "
        .. "KIPN_Logger is not initialized."
    )

end


--------------------------------------------------------------------
-- SCREEN
--
-- KIPN_SplashScreen is a standalone application, derived directly
-- from ISPanel -- see KIPN_BootScreen.lua for the sibling standalone
-- screen this mirrors.
--
-- It does NOT:
--
--   * create a terminal
--   * create terminal chrome
--   * own HOME / CLOSE
--   * register global server listeners
--
-- KIPN_SplashScreen.Open() controls when this screen becomes
-- active; see the bottom of this file.
--------------------------------------------------------------------

KIPN_SplashScreen =
    ISPanel:derive(
        "KIPN_SplashScreen"
    )


--------------------------------------------------------------------
-- SINGLE INSTANCE
--
-- Mirrors KIPN_BootScreen.instance -- only one Splash Screen is ever
-- shown to the local player at a time.
--------------------------------------------------------------------

KIPN_SplashScreen.instance =
    nil


--------------------------------------------------------------------
-- CONSTRUCTOR
--------------------------------------------------------------------

function KIPN_SplashScreen:new(
    x,
    y,
    width,
    height
)

    local o =
        ISPanel.new(
            self,
            x,
            y,
            width,
            height
        )

    setmetatable(
        o,
        self
    )

    self.__index =
        self

    return o
end


--------------------------------------------------------------------
-- TIMING
--
-- PAUSE_TICKS:
--     Ticks of blank terminal (scanlines only) after this screen
--     becomes active -- the "short pause" after the boot animation
--     ends and before the splash art appears.
--
-- DISPLAY_TICKS:
--     Ticks the splash art itself remains on screen before this
--     screen hands off to KIPN_Terminal.
--
-- Tick-driven, incremented once per update() call -- a fixed
-- cosmetic duration, unlike KIPN_BootScreen's server-timed
-- sequence.
--------------------------------------------------------------------

local PAUSE_TICKS = 1
local DISPLAY_TICKS = 50


--------------------------------------------------------------------
-- RUNTIME CLOCK / BACKSTOP
--
-- Splash is normally tick-driven and self-terminating (update()
-- advances the counter and hands off unconditionally). This
-- wall-clock cap is a pure safety net: if update() ever stops
-- advancing -- e.g. ISPanel.update() raising every frame -- the
-- screen still force-closes and hands off rather than sitting there
-- swallowing every key. Mirrors KIPN_BootScreen's getRuntimeMs() /
-- MAX_SCREEN_MS. Degrades to "no backstop" only when getTimestampMs()
-- is unavailable.
--------------------------------------------------------------------

local function getRuntimeMs()

    if not _G.getTimestampMs then
        return 0
    end

    local ok, result =
        pcall(function()
            return _G.getTimestampMs()
        end)

    if ok and type(result) == "number" then
        return result
    end

    return 0
end

local MAX_SCREEN_MS = 30000


--------------------------------------------------------------------
-- COLORS
--
-- Owned locally rather than read from KIPN.UI.Theme -- this screen
-- does not depend on the KIPN_UI framework (see file header).
--------------------------------------------------------------------

local COLOR_TEXT = {
    r = 0,
    g = 1,
    b = 0,
    a = 1
}

local COLOR_DIM = {
    r = 0.3,
    g = 0.7,
    b = 0.3,
    a = 1
}

local COLOR_ACCENT = {
    r = 1,
    g = 0.8,
    b = 0,
    a = 1
}

local COLOR_SCANLINE = {
    r = 0,
    g = 0.05,
    b = 0,
    a = 0.02
}


--------------------------------------------------------------------
-- SPLASH ART
--
-- The reference splash art (see "KIPN Splash Screen.txt" alongside
-- the mod project) is built from Unicode box-drawing characters
-- (U+2500-U+257F), block characters (U+2580-U+259F) and a bullet
-- (U+2022). NONE of Project Zomboid's bitmap fonts (zombiefont*,
-- zombienewtext*, zombiecodetext, mainfont*) contain glyphs in those
-- ranges -- every one of those characters draws as a missing glyph,
-- which is why the reference art does not render.
--
-- This screen instead reproduces the same composition -- a big
-- blocky "KIPN" logotype over a bordered status panel -- using
-- primitives ISPanel can always draw: self:drawRect() for every
-- border/frame line, and a hand-built pixel grid (also drawn with
-- self:drawRect()) for the big logo letters. Plain text content
-- uses only characters that exist in every candidate font.
--------------------------------------------------------------------

local TEXT_LINES = {
    subtitle = { text = "KNOX COUNTY INFORMATION & PROPERTY NETWORK", color = COLOR_DIM },
    box = {
        { text = "- lilBBS -", color = COLOR_ACCENT },
        { text = "- ONLINE -", color = COLOR_ACCENT },
    },
    tagline = { text = "PROPERTY * COMMERCE * INFORMATION", color = COLOR_DIM },
    footer = { text = "COPYRIGHT 1993 BIG DUMB ROBOT", color = COLOR_DIM },
}


--------------------------------------------------------------------
-- BLOCK LOGO GLYPHS
--
-- Hand-built 5-wide x 7-tall pixel grids for the "KIPN" logotype,
-- drawn as filled squares (see drawBlockLogo()) rather than the
-- unsupported █/╗/║/╝ glyphs from the reference art.
--------------------------------------------------------------------

-- Two rows of glyphs: "KIP" (row 1) and "NETWORK" (row 2).
-- The widest row (NETWORK = 7 glyphs) drives LOGO_TOTAL_COLS.
local LOGO_ROWS = {
    { "K", "I", "P" },
    { "N", "E", "T", "W", "O", "R", "K" },
}

local LOGO_GLYPHS = {

    K = {
        "#...#",
        "#..#.",
        "#.#..",
        "##...",
        "#.#..",
        "#..#.",
        "#...#",
    },

    I = {
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "#####",
    },

    P = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#....",
        "#....",
        "#....",
    },

    N = {
        "#...#",
        "##..#",
        "#.#.#",
        "#.#.#",
        "#..##",
        "#...#",
        "#...#",
    },

    E = {
        "#####",
        "#....",
        "#....",
        "####.",
        "#....",
        "#....",
        "#####",
    },

    T = {
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    },

    W = {
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#.#.#",
        "#.#.#",
        ".#.#.",
    },

    O = {
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    },

    R = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#.#..",
        "#..#.",
        "#...#",
    },

    [" "] = {
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
    },
}

-- LOGO_TOTAL_COLS: widest row is NETWORK (7 glyphs).
-- Defined here, after LOGO_ROWS and LOGO_GLYPHS.
local LOGO_MAX_ROW = 7   -- length of the widest row
local LOGO_TOTAL_COLS =
    (
        LOGO_MAX_ROW * LOGO_GLYPH_COLS
    )
    + (
        (LOGO_MAX_ROW - 1) * LOGO_GLYPH_GAP_COLS
    )

-- LOGO_TOTAL_HEIGHT: two glyph rows plus the gap between them.
local LOGO_TOTAL_ROWS =
    (2 * LOGO_GLYPH_ROWS)
    + LOGO_ROW_GAP_CELLS

--------------------------------------------------------------------
-- BLOCK LOGO
--
-- Draws the stacked two-row logotype:
--   Row 1: K I P
--   Row 2: N E T W O R K
-- Each row is left-offset so its glyphs are centered within the
-- column width of the widest row (NETWORK, 7 glyphs).
--------------------------------------------------------------------

local function drawBlockLogo(self, x, y, cellSize, color)

    local rowGapPx = LOGO_ROW_GAP_CELLS * cellSize

    for rowIdx, glyphRow in ipairs(LOGO_ROWS) do

        local rowCols =
            #glyphRow * LOGO_GLYPH_COLS
            + (#glyphRow - 1) * LOGO_GLYPH_GAP_COLS

        local totalColsPx =
            LOGO_TOTAL_COLS * cellSize

        -- Center this row horizontally within the logo width.
        local rowStartX =
            x + math.floor((totalColsPx - rowCols * cellSize) / 2)

        local rowStartY =
            y + (rowIdx - 1) * (LOGO_GLYPH_ROWS * cellSize + rowGapPx)

        for colIdx, glyph in ipairs(glyphRow) do

            local glyphDef = LOGO_GLYPHS[glyph]

            if glyphDef then

                local colOffset =
                    rowStartX
                    + (colIdx - 1)
                    * (LOGO_GLYPH_COLS + LOGO_GLYPH_GAP_COLS)
                    * cellSize

                for r = 1, #glyphDef do

                    local glyphLine = glyphDef[r]

                    for c = 1, #glyphLine do

                        if glyphLine:sub(c, c) == "#" then

                            self:drawRect(
                                colOffset + (c - 1) * cellSize,
                                rowStartY + (r - 1) * cellSize,
                                cellSize,
                                cellSize,
                                color.a,
                                color.r,
                                color.g,
                                color.b
                            )
                        end
                    end
                end
            end
        end
    end
end


local LOGO_MIN_CELL = 3
local LOGO_MAX_CELL = 14


--------------------------------------------------------------------
-- SCALED FONT SELECTION
--
-- The largest of these candidate fonts whose widest TEXT_LINES entry
-- still fits inside this screen's own width is used for every text
-- line, rather than a fixed font size independent of the screen it
-- is drawn on.
--------------------------------------------------------------------

local FONT_CANDIDATES = {
    UIFont.Large,
    UIFont.Medium,
    UIFont.Small,
}

local LAYOUT_MARGIN = 40


--------------------------------------------------------------------
-- BOX FRAME
--
-- Draws a rectangular border out of four filled rects -- the
-- drawRect()-based replacement for the reference art's ┌─┐│└┘ /
-- ╔═╗║╚╝ box-drawing glyphs, which no Project Zomboid font contains.
--------------------------------------------------------------------

local function drawBoxFrame(
    self,
    x,
    y,
    w,
    h,
    thickness,
    color
)

    self:drawRect(
        x,
        y,
        w,
        thickness,
        color.a,
        color.r,
        color.g,
        color.b
    )

    self:drawRect(
        x,
        y + h - thickness,
        w,
        thickness,
        color.a,
        color.r,
        color.g,
        color.b
    )

    self:drawRect(
        x,
        y,
        thickness,
        h,
        color.a,
        color.r,
        color.g,
        color.b
    )

    self:drawRect(
        x + w - thickness,
        y,
        thickness,
        h,
        color.a,
        color.r,
        color.g,
        color.b
    )
end


--------------------------------------------------------------------
-- BLOCK LOGO
--
-- Draws the "KIPN" logotype from LOGO_GLYPHS, one filled square per
-- '#' cell, scaled up to cellSize pixels per cell.
--------------------------------------------------------------------




--------------------------------------------------------------------
-- CENTERED TEXT
--
-- Draws text horizontally centered within this screen's own width.
--------------------------------------------------------------------

local function drawCenteredText(
    self,
    text,
    y,
    color,
    font
)

    local textWidth =
        getTextManager():MeasureStringX(
            font,
            text
        )

    local x =
        math.floor(
            (self.width - textWidth) / 2
        )

    self:drawText(
        text,
        x,
        y,
        color.r,
        color.g,
        color.b,
        color.a,
        font
    )
end


--------------------------------------------------------------------
-- LAYOUT SPLASH ART
--
-- Picks the largest font that fits, sizes the block logo to the same
-- width constraint, then stacks logo / subtitle / status box /
-- tagline / footer and centers the whole block both horizontally and
-- vertically within this screen. Cached on self after the first call
-- -- the screen's own size never changes for the lifetime of an
-- instance.
--------------------------------------------------------------------

function KIPN_SplashScreen:layoutSplashArt()

    local maxWidth =
        self.width - LAYOUT_MARGIN

    ----------------------------------------------------------------
    -- TEXT FONT
    ----------------------------------------------------------------

    local font =
        nil

    for _, candidate in ipairs(
        FONT_CANDIDATES
    ) do

        local fits =
            true

        local measured =
            getTextManager():MeasureStringX(
                candidate,
                TEXT_LINES.subtitle.text
            )

        if measured > maxWidth then

            fits =
                false
        end

        for _, line in ipairs(
            TEXT_LINES.box
        ) do

            if getTextManager():MeasureStringX(
                candidate,
                line.text
            ) > maxWidth then

                fits =
                    false
            end
        end

        if fits then

            font =
                candidate

            break
        end
    end

    if not font then

        font =
            UIFont.Small
    end

    local lineHeight =
        getTextManager():getFontHeight(
            font
        ) + 4

    self.splashFont =
        font

    self.splashLineHeight =
        lineHeight

    ----------------------------------------------------------------
    -- LOGO CELL SIZE
    ----------------------------------------------------------------

    local cellSize =
        math.floor(
            maxWidth / LOGO_TOTAL_COLS
        )

    if cellSize > LOGO_MAX_CELL then

        cellSize =
            LOGO_MAX_CELL
    end

    if cellSize < LOGO_MIN_CELL then

        cellSize =
            LOGO_MIN_CELL
    end

    self.splashLogoCellSize =
        cellSize

    local logoWidth =
        LOGO_TOTAL_COLS * cellSize

    -- Two stacked rows of glyphs with a gap between them.
    local logoHeight =
        LOGO_TOTAL_ROWS * cellSize

    ----------------------------------------------------------------
    -- STATUS BOX SIZE
    ----------------------------------------------------------------

    local boxTextWidth =
        0

    for _, line in ipairs(
        TEXT_LINES.box
    ) do

        local measured =
            getTextManager():MeasureStringX(
                font,
                line.text
            )

        if measured > boxTextWidth then

            boxTextWidth =
                measured
        end
    end

    local BOX_PADDING_X = 24
    local BOX_PADDING_Y = 12
    local BOX_LINE_GAP = 4
    local BOX_BORDER = 2

    local boxWidth =
        boxTextWidth + (BOX_PADDING_X * 2)

    local boxHeight =
        (lineHeight * #TEXT_LINES.box)
        + (BOX_LINE_GAP * (#TEXT_LINES.box - 1))
        + (BOX_PADDING_Y * 2)

    self.splashBoxWidth =
        boxWidth

    self.splashBoxHeight =
        boxHeight

    self.splashBoxBorder =
        BOX_BORDER

    self.splashBoxPaddingY =
        BOX_PADDING_Y

    self.splashBoxLineGap =
        BOX_LINE_GAP

    ----------------------------------------------------------------
    -- VERTICAL STACK
    ----------------------------------------------------------------

    local LOGO_GAP_AFTER = 16
    local SECTION_GAP = 14

    local totalHeight =
        logoHeight
        + LOGO_GAP_AFTER
        + lineHeight
        + SECTION_GAP
        + boxHeight
        + SECTION_GAP
        + lineHeight
        + SECTION_GAP
        + lineHeight

    self.splashLogoWidth =
        logoWidth

    self.splashLogoHeight =
        logoHeight

    self.splashLogoGapAfter =
        LOGO_GAP_AFTER

    self.splashSectionGap =
        SECTION_GAP

    ----------------------------------------------------------------
    -- OUTER FRAME
    --
    -- A drawRect()-based rectangular frame around the whole stack --
    -- the replacement for the reference art's outer ╔══╗ box.
    ----------------------------------------------------------------

    local contentWidth =
        logoWidth

    for _, key in ipairs(
        { "subtitle", "tagline", "footer" }
    ) do

        local measured =
            getTextManager():MeasureStringX(
                font,
                TEXT_LINES[key].text
            )

        if measured > contentWidth then

            contentWidth =
                measured
        end
    end

    if boxWidth > contentWidth then

        contentWidth =
            boxWidth
    end

    local FRAME_PADDING = 24
    local FRAME_BORDER = 2

    local frameWidth =
        contentWidth + (FRAME_PADDING * 2)

    local frameHeight =
        totalHeight + (FRAME_PADDING * 2)

    local frameX =
        math.floor(
            (self.width - frameWidth) / 2
        )

    local frameY =
        math.floor(
            (self.height - frameHeight) / 2
        )

    self.splashFrameX =
        frameX

    self.splashFrameY =
        frameY

    self.splashFrameWidth =
        frameWidth

    self.splashFrameHeight =
        frameHeight

    self.splashFrameBorder =
        FRAME_BORDER

    self.splashX =
        math.floor(
            (self.width - logoWidth) / 2
        )

    self.splashY =
        frameY + FRAME_PADDING
end


--------------------------------------------------------------------
-- SCANLINES
--
-- A local scanline overlay -- this screen does not depend on
-- KIPN.UI.DrawScanlines() (see file header).
--------------------------------------------------------------------

local function drawScanlines(
    self
)

    if self.height <= 0 then

        return
    end

    for i = 0, self.height, 4 do

        local yPos =
            (
                i
                + (self.scanlineOffset or 0)
            ) % self.height

        self:drawRect(
            0,
            yPos,
            self.width,
            1,
            COLOR_SCANLINE.a,
            COLOR_SCANLINE.r,
            COLOR_SCANLINE.g,
            COLOR_SCANLINE.b
        )
    end
end


--------------------------------------------------------------------
-- INITIALIZE
--------------------------------------------------------------------

function KIPN_SplashScreen:initialise()

    local success =
        false

    local ok, err =
        pcall(
            function()

                ISPanel.initialise(
                    self
                )

                self:create()

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_SplashScreen:initialise() failed: "
            .. tostring(err)
        )
    end
end


--------------------------------------------------------------------
-- CREATE
--------------------------------------------------------------------

function KIPN_SplashScreen:create()

    local success =
        false

    local ok, err =
        pcall(
            function()

                ----------------------------------------------------
                -- APPEARANCE
                ----------------------------------------------------

                self.backgroundColor =
                    (
                        KIPN.Shared
                        and KIPN.Shared.Colors
                        and KIPN.Shared.Colors.bg
                    )
                    or {
                        r = 0,
                        g = 0,
                        b = 0,
                        a = 1
                    }

                ----------------------------------------------------
                -- SCREEN STATE
                ----------------------------------------------------

                self.tickCount =
                    0

                self.done =
                    false

                -- Anchors the MAX_SCREEN_MS wall-clock backstop in
                -- update() -- see the getRuntimeMs() note above.
                self.openedAtMs =
                    getRuntimeMs()

                self.scanlineOffset =
                    self.scanlineOffset or 0

                self.splashFont =
                    nil

                ----------------------------------------------------
                -- INPUT
                ----------------------------------------------------

                self:setWantKeyEvents(
                    true
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_SplashScreen:create() failed: "
            .. tostring(err)
        )
    end
end


--------------------------------------------------------------------
-- CLOSE SELF
--
-- Purely a client-side dismissal -- there is no server-side splash
-- state to reconcile. See the file header: splash is a one-shot
-- flourish, not replayed on a later "Access KIP Network" once the
-- computer's boot state is ON.
--------------------------------------------------------------------

function KIPN_SplashScreen:closeSelf()

    self:setVisible(
        false
    )

    KIPN.UI.CRT.Unmount(self)

    if KIPN_SplashScreen.instance
        == self then

        KIPN_SplashScreen.instance =
            nil
    end
end


--------------------------------------------------------------------
-- RESOLVE COMPUTER SQUARE
--
-- KIPN_SplashScreen.Open() records self.computerSquare once from
-- computer:getSquare(), which can be nil (most often right after a
-- reconnect, before the world object's GridSquare has streamed in).
-- Left unresolved, checkProximity()'s "not self.computerSquare"
-- guard blocks the walk-away dismissal. Lazily re-resolves it -- the
-- object directly, then its coordinates -- exactly as
-- KIPN_BootScreen:resolveComputerSquare() and
-- KIPN_Terminal.OpenTerminal() do.
--------------------------------------------------------------------

function KIPN_SplashScreen:resolveComputerSquare()

    if self.computerSquare then

        return self.computerSquare
    end

    local computer =
        self.computer

    if not computer then

        return nil
    end

    if computer.getSquare then

        local ok, square =
            pcall(function()
                return computer:getSquare()
            end)

        if ok and square then

            self.computerSquare =
                square

            return square
        end
    end

    if computer.getX
        and computer.getY
        and computer.getZ
        and getCell
    then

        local ok, square =
            pcall(function()
                return getCell():getGridSquare(
                    math.floor(computer:getX()),
                    math.floor(computer:getY()),
                    computer:getZ()
                )
            end)

        if ok and square then

            self.computerSquare =
                square

            return square
        end
    end

    return nil
end


--------------------------------------------------------------------
-- HAND OFF TO TERMINAL
--
-- The single place splash opens KIPN_Terminal: the normal timed
-- path in update(), the ESC "skip the flourish" path in
-- onKeyPress(), and the MAX_SCREEN_MS backstop all route through
-- here. Idempotent -- self.done guards against a double hand-off,
-- the same guard KIPN_BootScreen:completeBoot() uses.
--------------------------------------------------------------------

function KIPN_SplashScreen:handoffToTerminal()

    if self.done then

        return
    end

    self.done =
        true

    local computer =
        self.computer

    self:closeSelf()

    if not KIPN_Terminal
        or not KIPN_Terminal.OpenTerminal
    then

        KIPN.Logger.Error(
            "KIPN_SplashScreen:handoffToTerminal(): "
            .. "KIPN_Terminal.OpenTerminal() unavailable"
        )

        return
    end

    KIPN_Terminal.OpenTerminal(
        computer
    )
end


--------------------------------------------------------------------
-- CHECK PROXIMITY
--
-- The normal way to dismiss this screen mid-flourish: walking more
-- than KIPN_Terminal.MAX_PROXIMITY squares away, losing power, or
-- dying. ESC skips straight to the terminal (see onKeyPress()); the
-- MAX_SCREEN_MS backstop in update() is the last resort.
--------------------------------------------------------------------

function KIPN_SplashScreen:checkProximity()

    if KIPN_SplashScreen.instance ~= self then

        return
    end

    local player =
        getPlayer()

    if not player
        or player:isDead() then

        self:closeSelf()

        return
    end

    local square =
        self:resolveComputerSquare()

    if not square then

        return
    end

    if KIPN.Shared
        and KIPN.Shared.HasSquareElectricity
        and not KIPN.Shared.HasSquareElectricity(
            square
        ) then

        self:closeSelf()

        return
    end

    if KIPN.Shared
        and KIPN.Shared.IsPlayerNearSquare
        and not KIPN.Shared.IsPlayerNearSquare(
            square,
            KIPN_Terminal.MAX_PROXIMITY,
            KIPN_Terminal.MAX_Z_DIFFERENCE
        ) then

        self:closeSelf()
    end
end


--------------------------------------------------------------------
-- UPDATE
--
-- Advances the pause+display timer and, once elapsed, hands off to
-- KIPN_Terminal exactly once (guarded by self.done, the same
-- double-fire guard KIPN_BootScreen:completeBoot() uses).
--------------------------------------------------------------------

function KIPN_SplashScreen:update()

    local success =
        false

    local ok, err =
        pcall(
            function()

                ISPanel.update(
                    self
                )

                self.scanlineOffset =
                    (
                        self.scanlineOffset
                        + 0.5
                    ) % 4

                if self.done then

                    success =
                        true

                    return
                end

                self.tickCount =
                    self.tickCount + 1

                ----------------------------------------------------
                -- WALL-CLOCK BACKSTOP
                --
                -- Splash normally hands off on the tick counter
                -- below. If that counter ever stops advancing this
                -- forces the hand-off anyway, so the screen -- which
                -- swallows every key -- can't sit there forever.
                ----------------------------------------------------

                if self.openedAtMs
                    and getRuntimeMs() - self.openedAtMs
                        >= MAX_SCREEN_MS
                then

                    KIPN.Logger.Warn(
                        "KIPN_SplashScreen: exceeded MAX_SCREEN_MS; "
                        .. "forcing hand-off to terminal."
                    )

                    self:handoffToTerminal()

                    success =
                        true

                    return
                end

                if self.tickCount
                    < PAUSE_TICKS + DISPLAY_TICKS
                then

                    success =
                        true

                    return
                end

                self:handoffToTerminal()

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_SplashScreen:update() failed: "
            .. tostring(err)
        )
    end
end


--------------------------------------------------------------------
-- PRERENDER
--------------------------------------------------------------------

function KIPN_SplashScreen:prerender()

    local success =
        false

    local ok, err =
        pcall(
            function()

                ISPanel.prerender(
                    self
                )

                drawScanlines(
                    self
                )

                ----------------------------------------------------
                -- PAUSE PHASE
                --
                -- Blank terminal (scanlines only) for the short
                -- pause after the boot animation ends.
                ----------------------------------------------------

                if self.tickCount
                    < PAUSE_TICKS
                then

                    success =
                        true

                    return
                end

                ----------------------------------------------------
                -- DISPLAY PHASE
                ----------------------------------------------------

                if not self.splashFont then

                    self:layoutSplashArt()
                end

                ----------------------------------------------------
                -- OUTER FRAME
                ----------------------------------------------------

                drawBoxFrame(
                    self,
                    self.splashFrameX,
                    self.splashFrameY,
                    self.splashFrameWidth,
                    self.splashFrameHeight,
                    self.splashFrameBorder,
                    COLOR_TEXT
                )

                local y =
                    self.splashY

                ----------------------------------------------------
                -- LOGO
                ----------------------------------------------------

                drawBlockLogo(
                    self,
                    self.splashX,
                    y,
                    self.splashLogoCellSize,
                    COLOR_TEXT
                )

                y =
                    y
                    + self.splashLogoHeight
                    + self.splashLogoGapAfter

                ----------------------------------------------------
                -- SUBTITLE
                ----------------------------------------------------

                drawCenteredText(
                    self,
                    TEXT_LINES.subtitle.text,
                    y,
                    TEXT_LINES.subtitle.color,
                    self.splashFont
                )

                y =
                    y
                    + self.splashLineHeight
                    + self.splashSectionGap

                ----------------------------------------------------
                -- STATUS BOX
                ----------------------------------------------------

                local boxX =
                    math.floor(
                        (self.width - self.splashBoxWidth) / 2
                    )

                drawBoxFrame(
                    self,
                    boxX,
                    y,
                    self.splashBoxWidth,
                    self.splashBoxHeight,
                    self.splashBoxBorder,
                    COLOR_ACCENT
                )

                local boxTextY =
                    y
                    + self.splashBoxBorder
                    + self.splashBoxPaddingY

                for _, line in ipairs(
                    TEXT_LINES.box
                ) do

                    drawCenteredText(
                        self,
                        line.text,
                        boxTextY,
                        line.color,
                        self.splashFont
                    )

                    boxTextY =
                        boxTextY
                        + self.splashLineHeight
                        + self.splashBoxLineGap
                end

                y =
                    y
                    + self.splashBoxHeight
                    + self.splashSectionGap

                ----------------------------------------------------
                -- TAGLINE
                ----------------------------------------------------

                drawCenteredText(
                    self,
                    TEXT_LINES.tagline.text,
                    y,
                    TEXT_LINES.tagline.color,
                    self.splashFont
                )

                y =
                    y
                    + self.splashLineHeight
                    + self.splashSectionGap

                ----------------------------------------------------
                -- FOOTER
                ----------------------------------------------------

                drawCenteredText(
                    self,
                    TEXT_LINES.footer.text,
                    y,
                    TEXT_LINES.footer.color,
                    self.splashFont
                )

                success =
                    true
            end
        )

    if not ok then

        KIPN.Logger.Error(
            "KIPN_SplashScreen:prerender() failed: "
            .. tostring(err)
        )
    end
end


--------------------------------------------------------------------
-- CREATE CHILDREN
--
-- Clickable SKIP -- the mouse equivalent of ESC below: hands off to
-- the terminal now instead of waiting out the display timer.
--------------------------------------------------------------------

function KIPN_SplashScreen:createChildren()

    ISPanel.createChildren(self)

    self.skipButton =
        KIPN.UI.CreateButton(
            self,
            self.width - 70,
            5,
            60,
            20,
            "SKIP",
            KIPN_SplashScreen.onSkipClick
        )
end

function KIPN_SplashScreen:onSkipClick()
    self:handoffToTerminal()
end


--------------------------------------------------------------------
-- KEY PRESS
--
-- The splash is a cosmetic flourish with no protected state, so ESC
-- simply skips it: hand off to the terminal now instead of waiting
-- out the display timer. Every other key is swallowed (the player
-- still can't act on the world behind it). Walking away
-- (checkProximity()) remains the "don't want the terminal at all"
-- exit.
--------------------------------------------------------------------

function KIPN_SplashScreen:onKeyPress(
    key
)

    if key == Keyboard.KEY_ESCAPE then

        self:handoffToTerminal()
    end

    return true
end


--------------------------------------------------------------------
-- OPEN
--
-- The single entry point for the standalone Splash Screen. Called
-- by KIPN_BootScreen:completeBoot() once its boot sequence finishes
-- successfully.
--------------------------------------------------------------------

function KIPN_SplashScreen.Open(
    computer,
    computerId
)

    if not computer then

        KIPN.Logger.Warn(
            "KIPN_SplashScreen.Open(): "
            .. "computer missing"
        )

        return nil
    end

    ---------------------------------------------------------------
    -- CLOSE ANY STRAY BOOT SCREEN
    --
    -- Splash always follows boot -- if one is somehow still open,
    -- it is superseded.
    ---------------------------------------------------------------

    if KIPN_BootScreen
        and KIPN_BootScreen.instance then

        KIPN_BootScreen.instance:closeSelf()
    end

    ---------------------------------------------------------------
    -- REUSE AN EXISTING INSTANCE FOR THE SAME COMPUTER
    ---------------------------------------------------------------

    if KIPN_SplashScreen.instance
        and KIPN_SplashScreen.instance.computerId
            == computerId then

        return KIPN_SplashScreen.instance
    end

    ---------------------------------------------------------------
    -- CLOSE A STRAY INSTANCE FOR A DIFFERENT COMPUTER
    ---------------------------------------------------------------

    if KIPN_SplashScreen.instance then

        KIPN_SplashScreen.instance:closeSelf()
    end

    ---------------------------------------------------------------
    -- CREATE
    --
    -- Same size/centering as KIPN_Terminal.OpenTerminal() and
    -- KIPN_BootScreen.Open(), so Boot -> Splash -> Terminal all
    -- occupy the identical screen rect.
    --
    -- All three mount into the one KIPN.UI.CRT monitor housing,
    -- which positions them inside its bezel.
    ---------------------------------------------------------------

    local w =
        KIPN_Terminal.DEFAULT_WIDTH

    local h =
        KIPN_Terminal.DEFAULT_HEIGHT

    local x =
        (getCore():getScreenWidth() - w)
        / 2

    local y =
        (getCore():getScreenHeight() - h)
        / 2

    local screen =
        KIPN_SplashScreen:new(
            x,
            y,
            w,
            h
        )

    screen.computer =
        computer

    screen.computerId =
        computerId

    screen.computerSquare =
        computer.getSquare
        and computer:getSquare()
        or nil

    local initOk, initErr =
        pcall(
            function()
                screen:initialise()
            end
        )

    if not initOk then

        KIPN.Logger.Error(
            "KIPN_SplashScreen.Open(): "
            .. "initialise() failed: "
            .. tostring(initErr)
        )

        return nil
    end

    local instantiateOk, instantiateErr =
        pcall(
            function()
                screen:instantiate()
            end
        )

    if not instantiateOk then

        KIPN.Logger.Error(
            "KIPN_SplashScreen.Open(): "
            .. "instantiate() failed: "
            .. tostring(instantiateErr)
        )

        return nil
    end

    KIPN.UI.CRT.Mount(screen)

    KIPN_SplashScreen.instance =
        screen

    KIPN.Logger.Info(
        "KIPN_SplashScreen.Open(): opened for computer "
        .. tostring(computerId)
    )

    return screen
end


--------------------------------------------------------------------
-- PLAYER PROXIMITY
--------------------------------------------------------------------

local function onPlayerUpdate(
    isoPlayer
)

    if not isoPlayer then
        return
    end

    if KIPN_SplashScreen.instance then

        KIPN_SplashScreen.instance:checkProximity()
    end
end

if Events.OnPlayerUpdate then

    Events.OnPlayerUpdate.Add(
        onPlayerUpdate
    )
end


--------------------------------------------------------------------
-- GAME EXIT
--------------------------------------------------------------------

local function onGameExit()

    if KIPN_SplashScreen.instance then

        KIPN_SplashScreen.instance:closeSelf()
    end
end

if Events.OnGameExit then

    Events.OnGameExit.Add(
        onGameExit
    )

elseif Events.OnGameQuit then

    Events.OnGameQuit.Add(
        onGameExit
    )
end


--------------------------------------------------------------------
-- LOADED
--------------------------------------------------------------------

print(
    "[KIPN] Splash Screen loaded"
)
