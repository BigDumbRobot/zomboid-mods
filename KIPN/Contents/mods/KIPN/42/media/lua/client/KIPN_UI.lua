-- KIPN_UI.lua
--
-- Shared BBS-terminal UI framework for all KIPN client screens.
--
-- Responsibilities:
--   * Provide the shared KIPN.UI namespace.
--   * Provide centralized UI theme definitions.
--   * Provide common screen/panel setup.
--   * Provide shared BBS visual helpers.
--   * Provide shared button creation.
--   * Provide shared status/message rendering.
--   * Provide shared table rendering.
--   * Provide shared screen-class creation.
--   * Provide shared weather-icon presentation helpers.
--   * Provide shared floating-window dragging support.
--   * Provide shared view-clipping (overflow protection).
--
-- IMPORTANT:
--
-- KIPN_UI.lua is a PRESENTATION utility layer.
--
-- It does NOT own:
--   * terminal navigation
--   * authentication
--   * sessions
--   * server communication
--   * application state
--   * computer state
--   * power state
--   * sandbox configuration
--   * Starlit initialization
--
-- KIPN_Terminal is the navigation/controller layer and owns:
--   * application activation
--   * application switching
--   * HOME
--   * BACK
--   * CLOSE
--   * ESC handling
--   * terminal-level navigation state
--
-- Child applications use KIPN.UI for presentation helpers but
-- communicate with the terminal through the application's defined
-- interface.
--
-- SANDBOX CONFIGURATION
--
-- KIPN does NOT load a custom KIPN_SandboxVars.lua file.
--
-- KIPN uses vanilla Project Zomboid SandboxVars as the authoritative
-- source for server-configurable feature switches.
--
-- Those vanilla sandbox switches are used to determine which
-- additional KIPN administrative controls/features are unlocked.
--
-- KIPN_UI.lua does not read or interpret SandboxVars directly.
--
-- Configuration belongs to the appropriate KIPN configuration/service
-- layer so that UI code remains presentation-only.
--
-- DEPENDENCY CONTRACT
--
-- KIPN_UI requires only:
--
--   1. KIPN_Shared
--      Provides shared KIPN contracts and definitions used by
--      presentation code. (This file establishes the KIPN
--      namespace itself, the same way every other KIPN module
--      does, rather than depending on a separate bootstrap file.)
--
--   2. Project Zomboid ISUI classes
--      Provides the base UI classes used by this framework.
--
-- KIPN_UI does NOT require:
--
--   * KIPN_Terminal
--   * KIPN_MainMenu
--   * KIPN_Interaction
--   * KIPN_Token
--   * authentication services
--   * server services
--   * Starlit
--   * Sandbox configuration modules
--
-- This keeps KIPN_UI below the application/navigation layer and
-- prevents circular dependencies.
--
-- CLIENT LOAD POSITION
--
-- The intended dependency chain is:
--
--   KIPN_Shared
--       |
--       v
--   KIPN_UI
--       |
--       +-------------------+
--       |                   |
--       v                   v
--   KIPN_Terminal      Child Screens
--                       |
--                       +--> KIPN_MainMenu
--                       +--> other applications
--
-- KIPN_Shared provides shared contracts.
-- KIPN_UI provides presentation utilities.
-- KIPN_Terminal provides the application container/controller.
-- Child screens provide application-specific content.
--
-- IMPORTANT:
--
-- This file must remain safe to load on the CLIENT only.
-- It should not initialize server systems or server authority.
--
-- File:
--   media/lua/client/KIPN_UI.lua

--------------------------------------------------------------------
-- CORE NAMESPACE / DEPENDENCIES
--------------------------------------------------------------------

KIPN = KIPN or {}
KIPN.Client = KIPN.Client or {}

require "KIPN_Shared"

--------------------------------------------------------------------
-- PROJECT ZOMBOID UI DEPENDENCIES
--------------------------------------------------------------------
--
-- These are vanilla Project Zomboid UI classes.
--
-- KIPN_UI derives presentation functionality from these classes,
-- but does not own or replace them.
--------------------------------------------------------------------

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "KIPN_Preferences"

--------------------------------------------------------------------
-- SHARED DEPENDENCY VALIDATION
--------------------------------------------------------------------

if not KIPN.Shared then

    error(
        "[KIPN_UI] "
        .. "KIPN.Shared is not initialized."
    )

end

--------------------------------------------------------------------
-- LOGGER DEPENDENCY
--------------------------------------------------------------------
--
-- KIPN_Logger should be loaded before KIPN_UI by the client
-- bootstrap.
--
-- UI code may use the centralized logger, but the UI framework
-- itself does not initialize the logger.
--
-- This is an intentional dependency direction:
--
--   Logger
--      |
--      v
--   Shared / UI / Terminal / Applications
--
-- and NOT:
--
--   UI --> initialize Logger
--
--------------------------------------------------------------------

if not KIPN.Logger then

    error(
        "[KIPN_UI] "
        .. "KIPN.Logger is not initialized."
    )

end

--------------------------------------------------------------------
-- UI NAMESPACE
--------------------------------------------------------------------

KIPN.UI =
    KIPN.UI or {}

--------------------------------------------------------------------
-- MODULE LOGGER
--------------------------------------------------------------------
--
-- Create one scoped logger for this module.
--
-- This keeps UI logging consistent with the rest of KIPN while
-- ensuring that the module name is automatically attached to
-- log entries.
--------------------------------------------------------------------

local log =
    KIPN.Logger.Create(
        "KIPN_UI"
    )

--------------------------------------------------------------------
-- THEME
--
-- Every screen should read colors/fonts from here instead of
-- re-declaring literal {r=0, g=1, b=0} tables. Changing a value here
-- changes it everywhere.
--------------------------------------------------------------------

KIPN.UI.Theme = {

    -- Panel chrome
    background = {
        r = 0.0,
        g = 0.0,
        b = 0.0,
        a = 1
    },

    border = {
        r = 0.1,
        g = 0.9,
        b = 0.2,
        a = 0.3
    },

    borderWidth = 2,

    -- Text
    text = {
        r = 0,
        g = 1,
        b = 0,
        a = 1
    },

    dimText = {
        r = 0.3,
        g = 0.7,
        b = 0.3,
        a = 1
    },

    headerText = {
        r = 0,
        g = 1,
        b = 0,
        a = 0.4
    },

    warning = {
        r = 1,
        g = 0.8,
        b = 0,
        a = 1
    },

    error = {
        r = 1,
        g = 0.3,
        b = 0.3,
        a = 1
    },

    accent = {
        r = 1,
        g = 0.8,
        b = 0,
        a = 1
    },

    -- Structural elements
    --
    -- NOTE:
    -- drawRect()/drawRectBorder() take arguments in
    -- (a, r, g, b) order in PZ's Lua API.
    --
    -- drawText() uses (r, g, b, a).
    --
    -- These fields are therefore intentionally stored according
    -- to how they are passed to drawRect().

    divider = {
        a = 0,
        r = 0.7,
        g = 0.1,
        b = 0.5
    },

    scanline = {
        a = 0.02,
        r = 0,
        g = 0.05,
        b = 0
    },

    -- Table zebra striping
    zebraA = {
        r = 0.03,
        g = 0.1,
        b = 0.03,
        a = 0.25
    },

    zebraB = {
        r = 0.05,
        g = 0.13,
        b = 0.05,
        a = 0.25
    },

    tableHeaderBg = {
        r = 0,
        g = 0.15,
        b = 0,
        a = 0.5
    },

    tableHover = {
        r = 0.1,
        g = 0.4,
        b = 0.15,
        a = 0.35
    },

    -- Buttons
    button = {

        background = {
            r = 0.05,
            g = 0.15,
            b = 0.05,
            a = 0.9
        },

        backgroundDanger = {
            r = 0.3,
            g = 0.05,
            b = 0.05,
            a = 0.9
        },

        backgroundHover = {
            r = 0.1,
            g = 0.5,
            b = 0.2,
            a = 0.9
        },

        backgroundHoverDanger = {
            r = 0.8,
            g = 0.1,
            b = 0.1,
            a = 0.9
        },

        border = {
            r = 0,
            g = 0.8,
            b = 0.2,
            a = 0.8
        },

        text = {
            r = 0.2,
            g = 1.0,
            b = 0.2,
            a = 1
        },
    },

    -- Fonts
    fontTitle = UIFont.Medium,
    fontHeader = UIFont.Small,
    fontBody = UIFont.Small,
    fontLarge = UIFont.Large,

    -- Banner box width, in ASCII "=" fill characters.
    --
    -- Kept as a fixed value rather than derived from pixel width,
    -- since fixed-width monospace fill does not line up reliably
    -- against arbitrary panel widths.

    bannerWidth = 70,
}

local Theme = KIPN.UI.Theme

--------------------------------------------------------------------
-- SETUP SCREEN
--
-- One-liner for the common panel setup every screen was hand-coding.
--
-- Also enables view-clipping (see KIPN.UI.EnableClipping() below)
-- so that every screen using this helper automatically gets overflow
-- protection -- hand-drawn content can never bleed past the screen's
-- own bounds, regardless of whether the screen also opted into
-- scrolling.
--------------------------------------------------------------------

function KIPN.UI.SetupScreen(self)

    if not self then
        return
    end

    self.backgroundColor =
        Theme.background

    self.borderColor =
        Theme.border

    self.borderWidth =
        Theme.borderWidth

    self.scanlineOffset =
        self.scanlineOffset or 0

    KIPN.UI.EnableClipping(self)
end

--------------------------------------------------------------------
-- CLIPPING / VIEW PROTECTION
--
-- Constrains ALL drawing performed by a panel -- both its own
-- self:drawText()/self:drawRect() calls and any child widgets
-- (buttons, native scrollbars, etc.) -- to the panel's own
-- rectangle, so hand-drawn content (long tables, long banners,
-- anything whose extent depends on data) can never spill past the
-- edges of the panel it belongs to.
--
-- A screen/container opts in once, e.g. in initialise():
--
--     KIPN.UI.EnableClipping(self)
--
-- This is called automatically by KIPN.UI.SetupScreen(), so screens
-- using that helper do not need to call it separately. Containers
-- that manage their own chrome (e.g. KIPN_Terminal, the floating
-- window itself) should call it directly.
--
-- Implementation note:
--
-- This follows the same setStencilRect()/clearStencilRect() pattern
-- vanilla PZ's own ISCollapsableWindow uses: the clip region is
-- opened in prerender() (before this panel or any of its children
-- have drawn anything this frame) and closed in render() (which
-- fires after all children have been drawn), so the clip covers the
-- panel's full draw pass, not just its own direct drawing calls.
--------------------------------------------------------------------

function KIPN.UI.EnableClipping(self)

    if not self then
        return
    end

    if self.kipnClipEnabled then
        return
    end

    self.kipnClipEnabled =
        true

    local originalPrerender =
        self.prerender

    local originalRender =
        self.render

    self.prerender = function(screen)

        screen:setStencilRect(
            0,
            0,
            screen.width,
            screen.height
        )

        if originalPrerender then
            originalPrerender(screen)
        end
    end

    self.render = function(screen)

        if originalRender then
            originalRender(screen)
        end

        screen:clearStencilRect()
    end
end

--------------------------------------------------------------------
-- SCROLLING
--
-- Generic scroll-container support for screens that hand-draw their
-- own content (self:drawText()/self:drawRect() in prerender())
-- rather than relying on PZ's native child-widget scrolling.
--
-- A terminal child screen opts in during initialise() after
-- ISPanel.initialise(self), then calls it once more from onShow()
-- after KIPN_Terminal has created its final Java UI object:
--
--     KIPN.UI.EnableScroll(self)
--
--     function MyScreen:onMouseWheel(del)
--         return KIPN.UI.OnScrollMouseWheel(self, del)
--     end
--
-- Then, in prerender(), every manually-drawn y coordinate is passed
-- through:
--
--     self:drawText(text, x, KIPN.UI.ScrollY(self, y), ...)
--
-- and once the full logical content height for this frame is known
-- (the final "y" cursor value, i.e. how far down the content would
-- extend if nothing were clipped):
--
--     KIPN.UI.SetContentHeight(self, y)
--
-- KIPN.UI.DrawDivider()/DrawSectionHeader()/DrawBanner()/DrawTable()
-- already call KIPN.UI.ScrollY() internally, so screens using those
-- helpers get scroll-aware positioning (and, for DrawTable(),
-- scroll-aware hit rectangles) for free.
--
-- The scrollbar (a native ISScrollBar, see ISUI/ISScrollBar) is only
-- shown once content actually exceeds the panel's own height -- "the
-- information exceeds the screen bounds."
--
-- CHILD WIDGETS (real ISButtons etc. added via addChild()):
--
-- By default (opts.scrollChildren omitted/false) child widgets do
-- NOT track this panel's scroll -- they stay glued to whatever x/y
-- they were given, which is what a persistent tab bar / SAVE button
-- wants (KIPN.UI.CreateButton()'s opts.fixed backstops this per
-- button). A screen whose buttons are laid out INLINE with the
-- scrolling content instead (e.g. KIPN_LORDScreen's per-view action
-- buttons, positioned via the same logical/unscrolled y the
-- hand-drawn text above/below them uses) should pass
-- opts.scrollChildren = true so those buttons move together with
-- everything else as the content flow's y positions do.
--------------------------------------------------------------------

KIPN.UI.SCROLL_WHEEL_STEP = 40

function KIPN.UI.EnableScroll(self, opts)

    if not self then
        return
    end

    opts =
        opts or {}

    if not self.kipnScrollEnabled then

        self.kipnScrollEnabled =
            true

        self.kipnContentHeight =
            self.height
    end

    ----------------------------------------------------------------
    -- FIXED HEADER / CLIPPED BODY
    --
    -- opts.contentTop is the logical y where this screen's fixed
    -- chrome (banner, tab row, etc.) ends and its scrollable body
    -- begins. Scrolling never reveals content above that line -- see
    -- KIPN.UI.BeginScrollClip()/EndScrollClip() -- so hand-drawn
    -- content can never render behind/through a tab row the way it
    -- could when the only protection was the tab buttons' own
    -- scrollWithParent=false.
    ----------------------------------------------------------------

    self.kipnScrollContentTop =
        opts.contentTop
        or self.kipnScrollContentTop
        or 0

    ----------------------------------------------------------------
    -- ATTACH AFTER INSTANTIATION
    --
    -- KIPN_Terminal calls a child screen's initialise() before its
    -- final instantiate(). addScrollBars() implicitly instantiates a
    -- panel when javaObject is nil; the terminal's later instantiate()
    -- then replaces that Java UI object and leaves the scrollbar on
    -- the discarded one. EnableScroll() is therefore safe to call in
    -- initialise() to opt in, and again from onShow() to attach the
    -- native scrollbar to the final UI object.
    ----------------------------------------------------------------

    if not self.javaObject then
        return
    end

    if not self.kipnScrollBarAttached then

        self:addScrollBars()

        self.kipnScrollBarAttached =
            true
    end

    self:setScrollChildren(
        opts.scrollChildren
        and true
        or false
    )

    self:setScrollWithParent(false)
    self:setScrollHeight(
        self.kipnContentHeight or self.height
    )

    local currentScroll =
        self:getYScroll() or 0

    if currentScroll > 0 then
        self:setYScroll(0)
    end

    self:updateScrollbars()
end

--------------------------------------------------------------------
-- SET CONTENT HEIGHT
--
-- Called once per prerender() with the logical bottom-most y the
-- screen's content reaches this frame. No-ops for screens that never
-- called KIPN.UI.EnableScroll().
--------------------------------------------------------------------

function KIPN.UI.SetContentHeight(self, contentHeight)

    if not self
        or not self.kipnScrollEnabled then

        return
    end

    local target =
        math.max(
            contentHeight or 0,
            self.height
        )

    if self.kipnContentHeight == target then
        return
    end

    self.kipnContentHeight =
        target

    self:setScrollHeight(target)

    ----------------------------------------------------------------
    -- CLAMP EXISTING SCROLL
    --
    -- Content can shrink between frames (e.g. a filtered list) --
    -- keep the current scroll position from pointing past the new
    -- bottom. maxScroll is measured against the visible BODY height
    -- (below the fixed header), not the full panel height, or the
    -- last contentTop pixels of content would be scrollable past
    -- the point where the header clip already hides them.
    ----------------------------------------------------------------

    local maxScroll =
        math.max(
            0,
            target
                - (self.height - (self.kipnScrollContentTop or 0))
        )

    local currentScroll =
        self:getYScroll() or 0

    if currentScroll > 0 then

        self:setYScroll(0)

    elseif currentScroll < -maxScroll then

        self:setYScroll(-maxScroll)
    end

    self:updateScrollbars()
end

--------------------------------------------------------------------
-- SCROLL Y
--
-- Converts a logical content-space y into the visual y it should
-- actually be drawn/hit-tested at. A no-op unless the screen called
-- KIPN.UI.EnableScroll().
--------------------------------------------------------------------

function KIPN.UI.ScrollY(self, y)

    if not self
        or not self.kipnScrollEnabled then

        return y
    end

    -- Project Zomboid represents downward scrolling with a negative
    -- Y-scroll value (zero at the top, -maxScroll at the bottom).
    return y + (self:getYScroll() or 0)
end

--------------------------------------------------------------------
-- SCROLL CLIP
--
-- Hard-clips scrolled content to the region below a screen's fixed
-- header (banner/tab row) so scrolled-past text can never render
-- behind or through it -- previously the only thing keeping a tab
-- button visually on top of scrolled-up text was draw order (the
-- button just happened to render after prerender()), which is why
-- text could still visibly slide up and get cut off mid-line right
-- at the header's edge instead of being cleanly hidden beneath it.
--
-- Wrap ONLY the scroll-following content drawing in a screen's
-- prerender() with these two calls -- fixed chrome (the banner, tab
-- buttons) must be drawn either before BeginScrollClip() or as real
-- child widgets (which render after prerender() regardless of any
-- stencil rect opened and closed within it):
--
--     local y = KIPN.UI.DrawBanner(self, "...")
--     -- (real tab button widgets already drew themselves earlier)
--     KIPN.UI.BeginScrollClip(self)
--     -- ... all of this screen's ScrollY()-adjusted drawing ...
--     KIPN.UI.EndScrollClip(self)
--     KIPN.UI.SetContentHeight(self, y)
--------------------------------------------------------------------

function KIPN.UI.BeginScrollClip(self)

    if not self
        or not self.kipnScrollEnabled then

        return
    end

    local top =
        self.kipnScrollContentTop
        or 0

    self:setStencilRect(
        0,
        top,
        self.width,
        self.height - top
    )
end

function KIPN.UI.EndScrollClip(self)

    if not self
        or not self.kipnScrollEnabled then

        return
    end

    ----------------------------------------------------------------
    -- POP, DON'T WIDEN
    --
    -- setStencilRect()/clearStencilRect() are a nested increment/
    -- decrement pair around a single GLOBAL stencil-buffer depth
    -- (zombie.ui.UIElement's static stencilLevel), not an independent
    -- per-call rectangle: each setStencilRect() only increments
    -- pixels that already passed the PREVIOUS depth's test, and
    -- clearStencilRect() decrements depth by exactly one, restoring
    -- whatever depth/rect was active before this one opened.
    --
    -- A screen that also uses KIPN.UI.EnableClipping() (most do, via
    -- SetupScreen()) already has an outer full-panel rect open at
    -- that lower depth. Re-opening a wider rect here (as this used
    -- to do) pushes a THIRD, deeper level whose mask quad can only
    -- mark pixels already inside the tighter body-only clip -- tab
    -- buttons above contentTop never reach that depth, so testing
    -- for it makes them fail the stencil test and disappear entirely
    -- (invisible, though still clickable, since hit-testing doesn't
    -- consult the stencil buffer). A plain clearStencilRect() pops
    -- back to the outer rect's depth correctly instead.
    ----------------------------------------------------------------

    self:clearStencilRect()
end

--------------------------------------------------------------------
-- MOUSE WHEEL
--
-- Screens that opted into scrolling should forward their
-- onMouseWheel(del) here.
--------------------------------------------------------------------

function KIPN.UI.OnScrollMouseWheel(self, del)

    if not self
        or not self.kipnScrollEnabled then

        return false
    end

    local maxScroll =
        math.max(
            0,
            (self.kipnContentHeight or self.height)
                - (self.height - (self.kipnScrollContentTop or 0))
        )

    if maxScroll <= 0 then
        return true
    end

    local target =
        (self:getYScroll() or 0)
        - (del * KIPN.UI.SCROLL_WHEEL_STEP)

    if target > 0 then

        target = 0

    elseif target < -maxScroll then

        target = -maxScroll
    end

    self:setYScroll(target)
    self:updateScrollbars()

    return true
end

--------------------------------------------------------------------
-- WINDOW DRAGGING
--
-- Makes a container a floating, freely-moveable window by attaching
-- an invisible drag handle over a given region of it (typically a
-- chrome/title strip) that repositions the container when dragged.
--
-- A container opts in once, e.g. in createChildren(), BEFORE adding
-- any buttons/widgets that live inside the drag region and should
-- remain individually clickable:
--
--     KIPN.UI.EnableDragging(self, 0, 0, self.width, 30)
--
-- x/y/w/h describe the draggable region in the container's own
-- local coordinates and default to the container's full bounds when
-- omitted, i.e. KIPN.UI.EnableDragging(self) makes the whole panel
-- a drag surface.
--
-- IMPORTANT -- ordering:
--
-- PZ dispatches a mouse click to the topmost child under the cursor.
-- Because the drag handle is just another child, adding it BEFORE
-- other children (buttons, etc.) means anything added afterward
-- naturally sits "in front of" it and keeps first claim on clicks
-- within its own bounds -- the drag handle only ever receives clicks
-- that land on otherwise-empty chrome. This is the same layering
-- vanilla PZ relies on for ISCollapsableWindow's title-bar buttons.
--------------------------------------------------------------------

function KIPN.UI.EnableDragging(self, x, y, w, h)

    if not self then
        return nil
    end

    local handle =
        ISPanel:new(
            x or 0,
            y or 0,
            w or self.width,
            h or self.height
        )

    handle:initialise()

    handle.background =
        false

    handle.moveWithMouse =
        true

    ---------------------------------------------------------------
    -- MOVE THE WHOLE WINDOW
    --
    -- Vanilla ISPanel drag only moves the handle's immediate parent.
    -- When the container is mounted inside the CRT monitor housing
    -- (see KIPN.UI.CRT below), that would slide the screen around
    -- inside the bezel -- so move the top-most ancestor instead.
    -- For an unmounted container the root IS the container, so
    -- behavior is unchanged.
    ---------------------------------------------------------------

    local function dragRoot(dx, dy)

        local root = handle

        while root.parent do
            root = root.parent
        end

        root:setX(root.x + dx)
        root:setY(root.y + dy)
    end

    function handle:onMouseMove(dx, dy)

        self.mouseOver = true

        if self.moving then
            dragRoot(dx, dy)
        end
    end

    function handle:onMouseMoveOutside(dx, dy)

        self.mouseOver = false

        if self.moving then
            dragRoot(dx, dy)
        end
    end

    self:addChild(handle)

    self.kipnDragHandle =
        handle

    return handle
end

--------------------------------------------------------------------
-- SCANLINES
--------------------------------------------------------------------

function KIPN.UI.DrawScanlines(self)

    if not self then
        return
    end

    if self.height <= 0 then
        return
    end

    local c =
        Theme.scanline

    for i = 0, self.height, 4 do

        local yPos =
            (
                i
                + (self.scanlineOffset or 0)
            )
            % self.height

        self:drawRect(
            0,
            yPos,
            self.width,
            1,
            c.a,
            c.r,
            c.g,
            c.b
        )
    end
end

--------------------------------------------------------------------
-- DIVIDER
--
-- Standard horizontal rule.
--
-- Returns the y position immediately below the divider so callers
-- can chain:
--
--     y = KIPN.UI.DrawDivider(self, y) + 10
--------------------------------------------------------------------

function KIPN.UI.DrawDivider(self, y, inset)

    if not self then
        return y
    end

    inset =
        inset or 15

    local c =
        Theme.divider

    self:drawRect(
        inset,
        KIPN.UI.ScrollY(self, y),
        self.width - (inset * 2),
        1,
        c.a,
        c.r,
        c.g,
        c.b
    )

    return y + 1
end

--------------------------------------------------------------------
-- SECTION HEADER
--
-- Standard divider + accent-colored subsection label, e.g.:
--
--   ─────────────────────────────
--   ONLINE PLAYERS
--
-- Draws its own leading divider (inset 20) followed by the label.
--
-- Returns the y position content under the header should start at.
--
--     y = KIPN.UI.DrawSectionHeader(self, y, "ONLINE PLAYERS")
--------------------------------------------------------------------

function KIPN.UI.DrawSectionHeader(self, y, text)

    if not self then
        return y
    end

    y =
        KIPN.UI.DrawDivider(
            self,
            y,
            20
        )

    y = y + 8

    self:drawText(
        text or "",
        20,
        KIPN.UI.ScrollY(self, y),
        Theme.accent.r,
        Theme.accent.g,
        Theme.accent.b,
        Theme.accent.a,
        Theme.fontHeader
    )

    y = y + 22

    return y
end

--------------------------------------------------------------------
-- BANNER
--
-- Draws the boxed BBS header:
--
--   +========================+
--   | TITLE                  |
--   +========================+
--
-- IMPORTANT -- ASCII ONLY:
--
-- Project Zomboid's bitmap fonts (zombiefont*, zombienewtext*,
-- zombiecodetext, mainfont*) do not contain glyphs for Unicode
-- box-drawing characters (U+2500-U+257F) -- those draw as missing
-- glyphs ("?") on affected clients. This banner is built entirely
-- from plain ASCII (+, =, |) for the same reason KIPN_SplashScreen's
-- art is drawn from primitives rather than ╔═╗║╚╝ -- see that file's
-- header for the full rationale.
--
-- title    - main header text
--
-- opts     - optional table:
--
--     rightText
--         Text drawn at the right edge of the title row.
--
--     rightFont
--         Font for rightText. Defaults to fontLarge.
--
-- Returns the y position immediately below the banner.
--------------------------------------------------------------------

-- Deliberately NOT scroll-adjusted (no KIPN.UI.ScrollY() on any of its
-- own draws): a banner is chrome, like the tab row below it, and must
-- stay pinned to the same screen position no matter how far the body
-- beneath it has scrolled. It always draws at this same logical y and
-- always returns the same value, so callers can treat its return as a
-- fixed constant when deciding where their own fixed header ends.
function KIPN.UI.DrawBanner(self, title, opts)

    if not self then
        return 20
    end

    opts =
        opts or {}

    local y =
        20

    local border =
        string.rep(
            "=",
            Theme.bannerWidth
        )

    local h =
        Theme.headerText

    self:drawText(
        "+" .. border .. "+",
        10,
        y,
        h.r,
        h.g,
        h.b,
        h.a,
        Theme.fontHeader
    )

    y =
        y + 18

    self:drawText(
        "|",
        10,
        y,
        h.r,
        h.g,
        h.b,
        h.a,
        Theme.fontHeader
    )

    self:drawText(
        title or "",
        30,
        y,
        Theme.text.r,
        Theme.text.g,
        Theme.text.b,
        Theme.text.a,
        Theme.fontTitle
    )

    if opts.rightText then

        self:drawText(
            opts.rightText,
            self.width - 30,
            y,
            1,
            1,
            1,
            1,
            opts.rightFont
                or Theme.fontLarge
        )
    end

    self:drawText(
        "|",
        self.width - 20,
        y,
        h.r,
        h.g,
        h.b,
        h.a,
        Theme.fontHeader
    )

    y =
        y + 18

    self:drawText(
        "+" .. border .. "+",
        10,
        y,
        h.r,
        h.g,
        h.b,
        h.a,
        Theme.fontHeader
    )

    y =
        y + 22

    return y
end

--------------------------------------------------------------------
-- BUTTON FACTORY
--
-- Creates and attaches a themed ISButton.
--
-- This is a generic visual button factory only.
--
-- Navigation buttons such as HOME/BACK/CLOSE remain owned by
-- KIPN_Terminal.
--------------------------------------------------------------------

function KIPN.UI.CreateButton(
    self,
    x,
    y,
    w,
    h,
    label,
    onClick,
    opts
)

    if not self then
        return nil
    end

    opts =
        opts or {}

    local btn =
        ISButton:new(
            x,
            y,
            w,
            h,
            label,
            self,
            onClick
        )

    btn:initialise()
    btn:instantiate()

    btn.borderColor =
        opts.borderColor
        or Theme.button.border

    btn.backgroundColor =
        opts.backgroundColor
        or (
            opts.danger
            and Theme.button.backgroundDanger
        )
        or Theme.button.background

    btn.backgroundColorMouseOver =
        opts.backgroundColorMouseOver
        or (
            opts.danger
            and Theme.button.backgroundHoverDanger
        )
        or Theme.button.backgroundHover

    btn.textColor =
        opts.textColor
        or Theme.button.text

    ----------------------------------------------------------------
    -- FIXED (SCROLL-IMMUNE) BUTTONS
    --
    -- opts.fixed = true marks a button that must never move when its
    -- parent scrolls -- tab bars, a persistent SAVE button, etc. This
    -- is independent of (and a backstop for) the parent's own
    -- KIPN.UI.EnableScroll()/setScrollChildren() setup: PZ's engine
    -- only shifts a child's on-screen position by its parent's
    -- yScroll when BOTH the parent has scrollChildren=true AND the
    -- CHILD itself has scrollWithParent=true (see
    -- zombie.ui.UIElement:getAbsoluteY()). Forcing
    -- scrollWithParent=false directly on the button guarantees it
    -- stays put regardless of the parent's flag, rather than relying
    -- on that single shared flag alone.
    ----------------------------------------------------------------

    if opts.fixed
        and btn.setScrollWithParent then

        btn:setScrollWithParent(false)
    end

    self:addChild(btn)

    return btn
end

--------------------------------------------------------------------
-- NON-MODAL CONFIRM DIALOG
--
-- A drop-in replacement for vanilla ISModalDialog with the exact
-- same constructor and callback contract:
--
--     KIPN.UI.CreateConfirmDialog(x, y, width, height, text, yesno,
--         target, onclick, player, param1, param2)
--
--     onclick(target, button, param1, param2)  -- button.internal is
--                                                  "YES" / "NO" / "OK"
--
-- WHY NOT ISModalDialog:
--
-- ISModalDialog derives from ISPanelJoypad, which manages joypad
-- input focus on open/close (setJoypadFocus()/updateJoypadFocus()).
-- In multiplayer this focus handoff does not always restore cleanly,
-- and the symptom is global: the mouse wheel stops reaching whatever
-- UI panel is under the cursor (player inventory, loot window, any
-- other panel) and appears to only zoom the camera instead, for the
-- rest of the session. This has already been confirmed and worked
-- around once before, in SVSBoobyTraps' SVSBTReportWindow (see that
-- mod's SVSBT_Client.lua) -- KIPN.UI.CreateConfirmDialog() is the
-- same fix (a plain ISPanel, no joypad focus involvement at all)
-- generalized for reuse across every KIPN add-on that needs a simple
-- Yes/No or OK confirmation popup.
--------------------------------------------------------------------

local ConfirmDialog =
    ISPanel:derive("KIPN_NonModalConfirmDialog")

KIPN.UI.ConfirmDialogClass =
    ConfirmDialog

local CONFIRM_FONT_HGT =
    getTextManager():getFontHeight(UIFont.Small)

local CONFIRM_BUTTON_HGT =
    CONFIRM_FONT_HGT + 6

local CONFIRM_BORDER_SPACING =
    10

------------------------------------------------------------
-- TEXT WRAPPING
--
-- prerender() used to draw self.text as a single drawTextCentre()
-- line -- fine for a short message, but any caller whose text was
-- wider than the dialog (e.g. KIPNGovernmentServices' Safehouse Deed
-- confirmation) overflowed past the panel's left/right edges instead
-- of wrapping. Greedily wraps on word boundaries to fit maxWidth,
-- respecting any newlines already in the source text.
------------------------------------------------------------

local function wrapConfirmText(text, font, maxWidth)

    text = tostring(text or "")

    local lines = {}

    for paragraph in (text .. "\n"):gmatch("(.-)\n") do

        local words = {}

        for word in paragraph:gmatch("%S+") do
            words[#words + 1] = word
        end

        if #words == 0 then

            lines[#lines + 1] = ""

        else

            local current = words[1]

            for i = 2, #words do

                local candidate = current .. " " .. words[i]

                if getTextManager():MeasureStringX(font, candidate) <= maxWidth then
                    current = candidate
                else
                    lines[#lines + 1] = current
                    current = words[i]
                end

            end

            lines[#lines + 1] = current

        end

    end

    return lines

end

function ConfirmDialog:initialise()

    ISPanel.initialise(self)

    local btnWid =
        100

    local btnY =
        self:getHeight()
        - CONFIRM_BORDER_SPACING
        - CONFIRM_BUTTON_HGT
        - 1

    if self.yesno then

        self.yes =
            ISButton:new(
                (self:getWidth() - CONFIRM_BORDER_SPACING) / 2 - btnWid,
                btnY,
                btnWid,
                CONFIRM_BUTTON_HGT,
                getText("UI_Yes"),
                self,
                ConfirmDialog.onClick
            )

        self.yes.internal =
            "YES"

        self.yes:initialise()
        self.yes:instantiate()
        self.yes:enableAcceptColor()
        self:addChild(self.yes)

        self.no =
            ISButton:new(
                (self:getWidth() + CONFIRM_BORDER_SPACING) / 2,
                btnY,
                btnWid,
                CONFIRM_BUTTON_HGT,
                getText("UI_No"),
                self,
                ConfirmDialog.onClick
            )

        self.no.internal =
            "NO"

        self.no:initialise()
        self.no:instantiate()
        self.no:enableCancelColor()
        self:addChild(self.no)

    else

        self.ok =
            ISButton:new(
                (self:getWidth() / 2) - btnWid / 2,
                btnY,
                btnWid,
                CONFIRM_BUTTON_HGT,
                getText("UI_Ok"),
                self,
                ConfirmDialog.onClick
            )

        self.ok.internal =
            "OK"

        self.ok:initialise()
        self.ok:instantiate()
        self.ok:enableAcceptColor()
        self:addChild(self.ok)

    end

end

function ConfirmDialog:onClick(button)

    self:setVisible(false)
    self:removeFromUIManager()

    if self.onclick ~= nil then

        button.player =
            self.player

        self.onclick(
            self.target,
            button,
            self.param1,
            self.param2
        )
    end

end

function ConfirmDialog:prerender()

    self:drawRect(
        0, 0, self.width, self.height,
        self.backgroundColor.a, self.backgroundColor.r,
        self.backgroundColor.g, self.backgroundColor.b
    )

    self:drawRectBorder(
        0, 0, self.width, self.height,
        self.borderColor.a, self.borderColor.r,
        self.borderColor.g, self.borderColor.b
    )

    local textY = 20

    for _, textLine in ipairs(self.lines or {}) do

        self:drawTextCentre(
            textLine, self:getWidth() / 2, textY,
            1, 1, 1, 1, UIFont.Small
        )

        textY = textY + CONFIRM_FONT_HGT

    end

end

function ConfirmDialog:new(
    x, y, width, height,
    text, yesno, target, onclick,
    player, param1, param2
)

    local o =
        ISPanel:new(x, y, width, height)

    setmetatable(o, self)
    self.__index = self

    o.text = text
    o.yesno = yesno
    o.target = target
    o.onclick = onclick
    o.player = player
    o.param1 = param1
    o.param2 = param2

    o.lines =
        wrapConfirmText(
            text,
            UIFont.Small,
            width - (CONFIRM_BORDER_SPACING * 2)
        )

    -- Grow (never shrink) to fit however many lines the wrapped text
    -- needed, so a long message can no longer push the Yes/No/OK
    -- buttons off the bottom of a caller-specified fixed height.
    local neededHeight =
        20
        + (#o.lines * CONFIRM_FONT_HGT)
        + CONFIRM_BORDER_SPACING
        + CONFIRM_BUTTON_HGT
        + CONFIRM_BORDER_SPACING
        + 1

    if neededHeight > o.height then
        o.height = neededHeight
    end

    o.moveWithMouse =
        false

    o.backgroundColor =
        { r = 0, g = 0, b = 0, a = 0.8 }

    o.borderColor =
        { r = 0.4, g = 0.4, b = 0.4, a = 1 }

    return o

end

-- Matches ISModalDialog:new()'s signature exactly. Returns an
-- initialised, UIManager-attached window -- callers do not need to
-- call :initialise() or :addToUIManager() themselves.
function KIPN.UI.CreateConfirmDialog(
    x, y, width, height,
    text, yesno, target, onclick,
    player, param1, param2
)

    local dialog =
        ConfirmDialog:new(
            x, y, width, height,
            text, yesno, target, onclick,
            player, param1, param2
        )

    dialog:initialise()
    dialog:addToUIManager()

    return dialog

end

--------------------------------------------------------------------
-- STATUS MESSAGE
--
-- Unified centered message for loading / timed-out / empty / error
-- states.
--
-- state    - "loading" | "timeout" | "empty" | "error"
-- mainText - primary line
-- subText  - optional secondary line
--------------------------------------------------------------------

local STATUS_COLORS = {

    loading =
        Theme.warning,

    timeout =
        Theme.error,

    empty =
        Theme.dimText,

    error =
        Theme.error,
}

function KIPN.UI.DrawStatusMessage(
    self,
    state,
    mainText,
    subText
)

    if not self then
        return
    end

    local color =
        STATUS_COLORS[state]
        or Theme.text

    local centerY =
        math.floor(
            self.height / 2
        ) - 20

    if mainText then

        local textWidth =
            getTextManager():MeasureStringX(
                Theme.fontTitle,
                mainText
            )

        local x =
            math.floor(
                (self.width - textWidth) / 2
            )

        self:drawText(
            mainText,
            x,
            centerY,
            color.r,
            color.g,
            color.b,
            color.a,
            Theme.fontTitle
        )
    end

    if subText then

        local subWidth =
            getTextManager():MeasureStringX(
                Theme.fontBody,
                subText
            )

        local x =
            math.floor(
                (self.width - subWidth) / 2
            )

        self:drawText(
            subText,
            x,
            centerY + 26,
            Theme.dimText.r,
            Theme.dimText.g,
            Theme.dimText.b,
            Theme.dimText.a,
            Theme.fontBody
        )
    end
end

--------------------------------------------------------------------
-- TABLE RENDERER
--
-- Generic column/row table with header row and zebra striping.
--
-- columns:
--
-- {
--     { label = "NAME", width = 200 },
--     { label = "PRICE", width = 100 },
-- }
--
-- rows:
--
-- {
--     { "Item A", "$10" },
--     { "Item B", "$25" },
-- }
--
-- rowHeight:
--     Optional. Defaults to 24.
--
-- opts:
--
--     hoverY
--         Current mouse Y in this panel's local space.
--
--     selectedIndex
--         Optional row index to render with the table highlight.
--
-- Returns an array of hit rectangles:
--
-- {
--     {
--         y1 = ...,
--         y2 = ...,
--         index = 1
--     }
-- }
--
-- Callers own click handling.
--------------------------------------------------------------------

function KIPN.UI.DrawTable(
    self,
    x,
    y,
    columns,
    rows,
    rowHeight,
    opts
)

    if not self or not columns then
        return {}
    end

    opts =
        opts or {}

    rowHeight =
        rowHeight or 24

    local totalWidth =
        0

    for _, col in ipairs(columns) do

        totalWidth =
            totalWidth
            + (col.width or 100)
    end

    ---------------------------------------------------------------
    -- HEADER
    ---------------------------------------------------------------

    self:drawRect(
        x,
        KIPN.UI.ScrollY(self, y),
        totalWidth,
        rowHeight,
        Theme.tableHeaderBg.a,
        Theme.tableHeaderBg.r,
        Theme.tableHeaderBg.g,
        Theme.tableHeaderBg.b
    )

    local colX =
        x

    for _, col in ipairs(columns) do

        self:drawText(
            col.label or "",
            colX + 6,
            KIPN.UI.ScrollY(self, y + 4),
            Theme.accent.r,
            Theme.accent.g,
            Theme.accent.b,
            Theme.accent.a,
            Theme.fontHeader
        )

        colX =
            colX
            + (col.width or 100)
    end

    y =
        y + rowHeight

    local hitRects =
        {}

    if not rows or #rows == 0 then
        return hitRects
    end

    ---------------------------------------------------------------
    -- ROWS
    ---------------------------------------------------------------

    for rowIndex, row in ipairs(rows) do

        local rowY1 =
            y

        local rowY2 =
            y + rowHeight

        -----------------------------------------------------------
        -- VISUAL ROW POSITION
        --
        -- opts.hoverY and the returned hitRects are both compared
        -- against real mouse coordinates by callers, so they must
        -- be expressed in the same (scrolled) space actually drawn
        -- to, not the logical/unscrolled layout space.
        -----------------------------------------------------------

        local rowY1v =
            KIPN.UI.ScrollY(self, rowY1)

        local rowY2v =
            rowY1v + rowHeight

        local isHovered =
            opts.hoverY
            and opts.hoverY >= rowY1v
            and opts.hoverY < rowY2v

        local isSelected =
            opts.selectedIndex == rowIndex

        local zebra =
            (rowIndex % 2 == 0)
            and Theme.zebraA
            or Theme.zebraB

        local bg =
            (isHovered or isSelected)
            and Theme.tableHover
            or zebra

        self:drawRect(
            x,
            rowY1v,
            totalWidth,
            rowHeight,
            bg.a,
            bg.r,
            bg.g,
            bg.b
        )

        colX =
            x

        for colIndex, col in ipairs(columns) do

            local cellText =
                row[colIndex]
                or ""

            local textA = row.disabled and (Theme.text.a * 0.4) or Theme.text.a

            self:drawText(
                tostring(cellText),
                colX + 6,
                rowY1v + 4,
                Theme.text.r,
                Theme.text.g,
                Theme.text.b,
                textA,
                Theme.fontBody
            )

            colX =
                colX
                + (col.width or 100)
        end

        hitRects[#hitRects + 1] = {

            y1 = rowY1v,
            y2 = rowY2v,
            index = rowIndex,
        }

        y =
            rowY2
    end

    return hitRects
end

--------------------------------------------------------------------
-- WEATHER ICON
--
-- IMPORTANT:
--
-- No font glyphs. No emoji/Unicode pictographs. Every condition is
-- drawn live from filled rectangles (self:drawRect()) so it renders
-- identically on every client regardless of font/glyph support.
--------------------------------------------------------------------

function KIPN.UI.DrawWeatherIcon(
    self,
    condition,
    x,
    y,
    size
)

    if not self then
        return
    end

    local r, g, b =
        0.2, 1.0, 0.2

    local function block(bx, by, bw, bh, alpha)

        self:drawRect(
            x + bx,
            y + by,
            bw,
            bh,
            alpha or 1,
            r,
            g,
            b
        )
    end

    condition =
        condition or "unknown"

    if condition == "clear" then

        -- Sun: core square with four rays.

        block(size * 0.30, size * 0.30, size * 0.40, size * 0.40, 1)
        block(size * 0.42, 0,           size * 0.16, size * 0.20, 0.8)
        block(size * 0.42, size * 0.80, size * 0.16, size * 0.20, 0.8)
        block(0,            size * 0.42, size * 0.20, size * 0.16, 0.8)
        block(size * 0.80,  size * 0.42, size * 0.20, size * 0.16, 0.8)

    elseif condition == "partly_cloudy" then

        -- Small sun behind a cloud.

        block(size * 0.55, size * 0.05, size * 0.30, size * 0.30, 0.7)
        block(size * 0.05, size * 0.55, size * 0.70, size * 0.30, 1)
        block(size * 0.15, size * 0.40, size * 0.35, size * 0.25, 1)

    elseif condition == "cloudy" then

        -- Layered cloud puffs.

        block(size * 0.05, size * 0.55, size * 0.90, size * 0.30, 1)
        block(size * 0.20, size * 0.35, size * 0.35, size * 0.30, 1)
        block(size * 0.50, size * 0.25, size * 0.40, size * 0.35, 1)

    elseif condition == "fog"
        or condition == "fog_likely" then

        -- Horizontal fog bands.

        block(0, size * 0.20, size, size * 0.14, 0.9)
        block(0, size * 0.48, size, size * 0.14, 0.6)
        block(0, size * 0.76, size, size * 0.14, 0.35)

    elseif condition == "rain"
        or condition == "heavy_rain" then

        -- Cloud with falling rain.

        block(size * 0.05, size * 0.10, size * 0.90, size * 0.32, 1)

        local dropCount =
            condition == "heavy_rain"
            and 4
            or 3

        local spacing =
            size / (dropCount + 1)

        for i = 1, dropCount do

            block(
                (spacing * i) - size * 0.03,
                size * 0.55,
                size * 0.06,
                size * 0.40,
                0.85
            )
        end

    elseif condition == "storm" then

        -- Cloud with a blocky lightning bolt.

        block(size * 0.05, size * 0.05, size * 0.90, size * 0.32, 1)
        block(size * 0.50, size * 0.40, size * 0.14, size * 0.20, 1)
        block(size * 0.36, size * 0.55, size * 0.14, size * 0.20, 1)
        block(size * 0.50, size * 0.70, size * 0.14, size * 0.24, 1)

    elseif condition == "snow" then

        -- Cloud with falling snow.

        block(size * 0.05, size * 0.10, size * 0.90, size * 0.32, 1)
        block(size * 0.15, size * 0.60, size * 0.12, size * 0.12, 0.85)
        block(size * 0.44, size * 0.75, size * 0.12, size * 0.12, 0.85)
        block(size * 0.73, size * 0.60, size * 0.12, size * 0.12, 0.85)

    elseif condition == "blizzard" then

        -- Dense cloud with heavy, wind-driven snow.

        block(size * 0.05, size * 0.05, size * 0.90, size * 0.34, 1)

        for i = 1, 5 do

            block(
                (size * 0.14 * i) - size * 0.04,
                size * 0.50 + ((i % 2) * size * 0.14),
                size * 0.10,
                size * 0.10,
                0.9
            )
        end

    elseif condition == "tropical_storm" then

        -- Cloud with lightning and slanted heavy rain.

        block(size * 0.05, size * 0.05, size * 0.90, size * 0.32, 1)
        block(size * 0.46, size * 0.40, size * 0.14, size * 0.18, 1)
        block(size * 0.34, size * 0.54, size * 0.14, size * 0.18, 1)

        for i = 1, 4 do

            block(
                (size * 0.20 * i) - size * 0.10,
                size * 0.55,
                size * 0.07,
                size * 0.38,
                0.85
            )
        end

    else

        -- UNKNOWN: dim outline box.

        block(0, 0,            size, size * 0.10, 0.5)
        block(0, size * 0.90,  size, size * 0.10, 0.5)
        block(0, 0,            size * 0.10, size, 0.5)
        block(size * 0.90, 0,  size * 0.10, size, 0.5)
    end
end

--------------------------------------------------------------------
-- WEATHER READOUT / FORECAST STRIP
--
-- Two widgets designed to live in KIPN_Terminal's chrome bar,
-- alongside the HOME/CLOSE buttons and the date/time text, so they
-- can be drawn every frame regardless of which child screen is
-- currently active:
--
--   DrawWeatherReadout()       -- bigger "current conditions" block
--   DrawWeatherForecastStrip() -- multi-day icon + temperature row
--
-- forecastData is the raw FORECAST_DATA payload (or nil):
--
--   forecastData.current -- richer live snapshot (preferred)
--       .condition
--       .temperature
--       .wind
--       .precipitation
--       .cloud
--   forecastData.periods[1] -- fallback if .current is absent
--       (older cached payload, same field names)
--   forecastData.days -- array of per-day forecasts
--       .label
--       .condition
--       .temperatureMin / .temperatureMax
--
-- These functions are presentation-only. They do not request, cache,
-- or own forecast state -- that belongs to whichever caller owns the
-- data (KIPN_Terminal).
--
-- IMPORTANT -- NO DEGREE SYMBOL:
--
-- formatTemperature()/formatTemperatureRounded() below render as
-- e.g. "20C" / "68F" rather than "20°C" / "68°F". PZ's bitmap fonts
-- do not contain a glyph for U+00B0 (°) -- it draws as a missing
-- glyph ("?") on affected clients, the same class of problem
-- KIPN_SplashScreen's art works around for box-drawing characters.
--------------------------------------------------------------------

-- Unit choice (F/C) comes from the player's KIPN display
-- preferences, which default to the vanilla Celsius option. See
-- KIPN_Preferences.lua.

local function formatTemperature(celsiusValue)
    return KIPN.Client.Preferences.FormatTemperature(celsiusValue)
end

local function formatTemperatureRounded(celsiusValue)
    return KIPN.Client.Preferences.FormatTemperature(celsiusValue, true)
end

local function displayConditionLabel(condition)

    return string.upper(
        tostring(
            condition or "UNKNOWN"
        ):gsub(
            "_",
            " "
        )
    )
end

--------------------------------------------------------------------

function KIPN.UI.DrawWeatherReadout(
    self,
    x,
    y,
    w,
    h,
    forecastData
)

    if not self then
        return
    end

    local current =
        forecastData
        and (
            forecastData.current
            or (
                type(forecastData.periods) == "table"
                and forecastData.periods[1]
            )
        )

    if not current then

        self:drawText(
            "NO FORECAST DATA",
            x,
            y,
            0.3,
            0.7,
            0.3,
            0.7,
            UIFont.Small
        )

        return
    end

    ----------------------------------------------------------------
    -- ICON
    ----------------------------------------------------------------

    local iconSize =
        math.min(40, h or 40)

    KIPN.UI.DrawWeatherIcon(
        self,
        current.condition,
        x,
        y,
        iconSize
    )

    ----------------------------------------------------------------
    -- LINE 1: CONDITION + TEMPERATURE
    ----------------------------------------------------------------

    local textX =
        x + iconSize + 8

    self:drawText(
        displayConditionLabel(current.condition)
        .. "  "
        .. formatTemperature(current.temperature),
        textX,
        y,
        0,
        1,
        0,
        1,
        UIFont.Medium
    )
end

--------------------------------------------------------------------
-- FORECAST STRIP
--
-- Horizontal row of small icon + high/low temperature cells, one
-- per day in forecastData.days (see KIPN_ForecastService.lua).
-- Evenly divides the available width w across however many days are
-- actually present, so it degrades gracefully with fewer days.
--
-- VERTICAL FIT:
--
-- Each cell stacks four rows (day label, icon, high, low) inside the
-- available height h. Row heights are measured from the actual font
-- metrics (getTextManager():getFontHeight()) rather than guessed
-- fixed pixel offsets, and the icon is sized to whatever vertical
-- space is left over after the three text rows -- so the stack
-- always totals to (at most) h and the low-temperature reading can
-- never fall outside the widget pane this strip was given, no
-- matter what font/UI-scale settings are active on the client.
--------------------------------------------------------------------

function KIPN.UI.DrawWeatherForecastStrip(
    self,
    x,
    y,
    w,
    h,
    days
)

    if not self then
        return
    end

    if type(days) ~= "table"
        or #days == 0 then

        self:drawText(
            "NO FORECAST DATA",
            x,
            y,
            0.3,
            0.7,
            0.3,
            0.7,
            UIFont.Small
        )

        return
    end

    h =
        h or 44

    local MIN_CELL_WIDTH =
        60

    local dayCount =
        math.min(
            #days,
            math.max(
                1,
                math.floor((w or 0) / MIN_CELL_WIDTH)
            )
        )

    local cellWidth =
        (w or 0) / dayCount

    ------------------------------------------------------------------
    -- SIZING
    --
    -- days[1] is "today" (see KIPN_ForecastService.lua's DAY_LABELS)
    -- and is drawn with a larger font/icon ceiling. Every day after
    -- that is a genuine future-forecast cell and is drawn smaller --
    -- both to read as visually secondary to today and, in practice,
    -- to leave enough width for the low-temp reading once several
    -- days are split evenly across w.
    ------------------------------------------------------------------

    local TODAY_ICON_MAX =
        20

    local FUTURE_ICON_MAX =
        14

    local ICON_MIN =
        8

    local TODAY_FONT =
        UIFont.Small

    local FUTURE_FONT =
        UIFont.NewSmall

    local ROW_GAP =
        2

    for i = 1, dayCount do

        local day =
            days[i]

        local isToday =
            (i == 1)

        local iconMax =
            isToday and TODAY_ICON_MAX or FUTURE_ICON_MAX

        local font =
            isToday and TODAY_FONT or FUTURE_FONT

        local cellX =
            x + ((i - 1) * cellWidth)

        --------------------------------------------------------
        -- VERTICAL STACK
        --
        -- label -> icon -> high -> low, each separated by
        -- ROW_GAP. The icon gets whatever height remains after
        -- the three measured text rows, clamped to a sane range,
        -- so the whole stack fits inside h.
        --------------------------------------------------------

        local textRowHeight =
            getTextManager():getFontHeight(font)

        local iconSize =
            h
            - (textRowHeight * 3)
            - (ROW_GAP * 3)

        iconSize =
            math.max(
                ICON_MIN,
                math.min(iconMax, iconSize)
            )

        local labelY =
            y

        local iconY =
            labelY + textRowHeight + ROW_GAP

        local highY =
            iconY + iconSize + ROW_GAP

        local lowY =
            highY + textRowHeight + ROW_GAP

        --------------------------------------------------------
        -- DAY LABEL
        --------------------------------------------------------

        local labelText =
            tostring(day.label or ("+" .. (i - 1) .. "d"))

        local labelWidth =
            getTextManager():MeasureStringX(
                font,
                labelText
            )

        self:drawText(
            labelText,
            cellX + (cellWidth - labelWidth) / 2,
            labelY,
            0.2,
            0.8,
            0.2,
            0.9,
            font
        )

        --------------------------------------------------------
        -- ICON
        --------------------------------------------------------

        KIPN.UI.DrawWeatherIcon(
            self,
            day.condition,
            cellX + (cellWidth - iconSize) / 2,
            iconY,
            iconSize
        )

        ------------------------------------------------------------
        -- HIGH / LOW
        --
        -- Stacked vertically (high on top, low underneath) rather
        -- than side-by-side, so the strip stays narrow enough to
        -- fit alongside the rest of the terminal chrome.
        ------------------------------------------------------------

        local highText =
            formatTemperatureRounded(day.temperatureMax)

        local lowText =
            formatTemperatureRounded(day.temperatureMin)

        local highWidth =
            getTextManager():MeasureStringX(
                font,
                highText
            )

        local lowWidth =
            getTextManager():MeasureStringX(
                font,
                lowText
            )

        self:drawText(
            highText,
            cellX + (cellWidth - highWidth) / 2,
            highY,
            0,
            1,
            0,
            0.9,
            font
        )

        self:drawText(
            lowText,
            cellX + (cellWidth - lowWidth) / 2,
            lowY,
            0.2,
            0.8,
            0.2,
            0.9,
            font
        )
    end
end

--------------------------------------------------------------------
-- SCREEN FACTORY
--
-- Replaces repeated ISPanel derive/new boilerplate.
--
-- Usage:
--
--     KIPN_PropertyRecords =
--         KIPN.UI.CreateScreen(
--             "KIPN_PropertyRecords"
--         )
--
--     function KIPN_PropertyRecords:initialise()
--         ...
--     end
--------------------------------------------------------------------

function KIPN.UI.CreateScreen(name)

    if not name or name == "" then

        error(
            "[KIPN_UI] "
            .. "CreateScreen() requires a class name."
        )
    end

    local cls =
        ISPanel:derive(name)

    function cls:new(
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

    return cls
end

--------------------------------------------------------------------
-- SET SCREEN
--
-- Convenience wrapper so a child application doesn't need to know
-- how to reach its own hosting KIPN_Terminal instance. Any screen
-- opened through KIPN_Terminal:setScreen() already has `.terminal`
-- set on it (KIPN_Terminal does this immediately after creating
-- the screen) -- this simply forwards to that terminal.
--
-- Per this file's header, navigation itself remains owned by
-- KIPN_Terminal. KIPN.UI.SetScreen is an adapter only, not a
-- second navigation implementation.
--------------------------------------------------------------------

function KIPN.UI.SetScreen(caller, screenClass)

    if not caller then

        log:Error(
            "SetScreen(): caller is nil."
        )

        return false
    end

    if not screenClass then

        log:Error(
            "SetScreen(): screenClass is nil."
        )

        return false
    end

    local terminal =
        caller.terminal

    if not terminal
        or type(terminal.setScreen) ~= "function"
    then

        log:Error(
            "SetScreen(): caller has no hosting KIPN_Terminal "
            .. "(caller.terminal missing or invalid)."
        )

        return false
    end

    return terminal:setScreen(screenClass)
end

--------------------------------------------------------------------
-- REGISTRATION FLAVOR MESSAGES
--
-- Purely cosmetic filler text shown while a claim item "crafting"
-- wait plays out at a KIPN desk (see client/KIPN_GovernmentServices
-- .lua / client/KIPN_VehicleRegistration.lua's requestClaim()-style
-- flows). NOT real server messages, NOT status information -- just
-- flavor to make the wait feel like a clerk is actually doing
-- something, since the computer screen fills the player's view and
-- an actual character animation isn't visible.
--------------------------------------------------------------------

KIPN.UI.RegistrationFlavorMessages = {

    "Shuffling paperwork...",
    "Finding your pen...",
    "Oops, dropped your pen...",
    "Engaging in small talk...",
    "Getting a glass of water...",
    "Looking at the ceiling...",
    "Signing documents...",
    "Dotting the i's...",
    "Crossing the t's...",
    "Adding your initials...",
    "Scribbled out last entry...",
    "Flipping pages...",
    "Filling out forms...",
    "Calling your agent...",
    "Reading the fine print...",
    "Asking about a clause...",
    "Looking at the floor...",
    "Stamping the form...",
    "Misplacing the stapler...",
    "Double-checking your ID...",
    "Whistling idly...",
    "Sharpening a pencil...",
    "Straightening the paperwork...",
    "Yawning...",
    "Cross-referencing a ledger...",
    "Licking an envelope...",
    "Adjusting their glasses...",
    "Muttering under their breath...",
    "Checking the clock...",
    "Photocopying a form...",
    "Searching for a rubber stamp...",
    "Refilling the inkwell...",
    "Straining to read your handwriting...",
    "Alphabetizing a file...",
}

--------------------------------------------------------------------
-- PICK RANDOM REGISTRATION FLAVOR MESSAGE
--
-- Repeats are fine -- see the header above. Uses ZombRand when
-- available (matches the rest of the codebase's RNG convention) and
-- falls back to math.random otherwise.
--------------------------------------------------------------------

function KIPN.UI.PickRandomFlavorMessage()

    local messages =
        KIPN.UI.RegistrationFlavorMessages

    if type(messages) ~= "table"
        or #messages == 0
    then

        return "Processing..."
    end

    local index

    if type(ZombRand) == "function" then

        index =
            ZombRand(1, #messages + 1)

    else

        index =
            math.random(#messages)
    end

    return messages[index]
        or "Processing..."
end

--------------------------------------------------------------------
-- CRT MONITOR HOUSING
--
-- A single top-level "physical monitor" window -- beige plastic
-- bezel, recessed glass, curved-tube vignette and glare -- that the
-- full-size KIPN screens (KIPN_BootScreen, KIPN_SplashScreen,
-- KIPN_Terminal) mount INTO as a child, instead of each adding
-- themselves to the UIManager directly:
--
--     KIPN.UI.CRT.Mount(screen)     -- instead of screen:addToUIManager()
--     KIPN.UI.CRT.Unmount(screen)   -- instead of screen:removeFromUIManager()
--
-- Because there is only ever one housing, Boot -> Splash -> Terminal
-- handoffs (unmount + mount in the same tick) swap the picture
-- inside a monitor that stays put, rather than closing one window
-- and centering another. When the last screen unmounts the housing
-- plays a CRT power-off collapse and then removes itself.
--
-- Draw order per frame:
--
--   prerender()  black tube face (the overscan border around the
--                picture)
--   children     the mounted screen draws its content
--   render()     power on/off effects, rolling refresh band,
--                glass overlay, then the bezel on top -- so the
--                bezel's rounded opening crops the picture's
--                corners and the glass sits over all text/buttons
--                without intercepting any mouse input
--
-- Textures are generated (see crt_bezel.png / crt_glass.png in
-- media/ui/KIPN); the geometry below MUST match what they were
-- generated with.
--------------------------------------------------------------------

KIPN.UI.CRT = {

    -- Whole housing, in pixels.
    WIDTH = 896,
    HEIGHT = 712,

    -- Where a mounted 800x600 screen sits inside the housing.
    SCREEN_X = 48,
    SCREEN_Y = 40,

    -- Glass opening (screen grown by an 8px overscan border).
    GLASS_X = 40,
    GLASS_Y = 32,
    GLASS_W = 816,
    GLASS_H = 616,

    -- Chin details.
    LED_X = 786,
    LED_Y = 687,
    LABEL_X = 62,
    LABEL_Y = 676,

    BEZEL_TEXTURE = "media/ui/KIPN/crt_bezel.png",
    GLASS_TEXTURE = "media/ui/KIPN/crt_glass.png",

    POWER_ON_MS = 280,
    POWER_OFF_MS = 460,

    -- An unmount followed by a mount within this window is a screen
    -- handoff, not the player switching the monitor back on.
    HANDOFF_MS = 100,

    -- Rolling refresh band (the bright bar you see on a CRT when
    -- sitting close to it).
    REFRESH_PERIOD_MS = 7000,
    REFRESH_BAND_H = 140,
    REFRESH_ALPHA = 0.022,

    -- Max per-frame brightness flicker.
    FLICKER_ALPHA = 0.012,

    instance = nil,
}

local CRT = KIPN.UI.CRT

local function crtNowMs()

    if getTimestampMs then

        local ok, result =
            pcall(getTimestampMs)

        if ok and type(result) == "number" then
            return result
        end
    end

    return os.time() * 1000
end

local function crtRandom()

    if type(ZombRandFloat) == "function" then
        return ZombRandFloat(0, 1)
    end

    return math.random()
end

-- path -> Texture, or false once a load has failed (logged once).
local crtTextures = {}

local function crtTexture(path)

    if crtTextures[path] == nil then

        crtTextures[path] =
            getTexture(path) or false

        if not crtTextures[path] then
            log:Warn("CRT texture missing: " .. path)
        end
    end

    return crtTextures[path] or nil
end

local CRTMonitor =
    ISPanel:derive(
        "KIPN_CRTMonitor"
    )

function CRTMonitor:new(x, y)

    local o =
        ISPanel.new(
            self,
            x,
            y,
            CRT.WIDTH,
            CRT.HEIGHT
        )

    setmetatable(o, self)
    self.__index = self

    -- The housing draws itself entirely from textures; the rounded
    -- case corners must stay see-through.
    o.background = false

    -- Grabbing the plastic drags the whole monitor.
    o.moveWithMouse = true

    o.screen = nil
    o.powerOnAt = nil
    o.powerOffAt = nil

    return o
end

function CRTMonitor:prerender()

    self:drawRect(
        CRT.GLASS_X,
        CRT.GLASS_Y,
        CRT.GLASS_W,
        CRT.GLASS_H,
        1,
        0.012,
        0.016,
        0.013
    )
end

-- Glass-rect-clipped horizontal band, for effects that must never
-- paint over the bezel.
function CRTMonitor:drawGlassBand(y, h, a, r, g, b)

    local top = math.max(y, CRT.GLASS_Y)
    local bottom = math.min(y + h, CRT.GLASS_Y + CRT.GLASS_H)

    if bottom <= top or a <= 0 then
        return
    end

    self:drawRect(
        CRT.GLASS_X,
        top,
        CRT.GLASS_W,
        bottom - top,
        a,
        r,
        g,
        b
    )
end

-- Warm-up: the picture opens out from a bright horizontal line.
function CRTMonitor:drawPowerOn(t)

    local ease = 1 - (1 - t) * (1 - t)

    local centerY = CRT.GLASS_Y + CRT.GLASS_H / 2
    local half = math.max(1, (CRT.GLASS_H / 2) * ease)

    self:drawGlassBand(CRT.GLASS_Y, centerY - half - CRT.GLASS_Y, 1, 0, 0, 0)
    self:drawGlassBand(centerY + half, CRT.GLASS_H, 1, 0, 0, 0)
    self:drawGlassBand(centerY - half, half * 2, 0.55 * (1 - t) * (1 - t), 0.85, 1, 0.9)
end

-- Switch-off: picture collapses to a line, the line to a dot, the
-- dot fades.
function CRTMonitor:drawPowerOff(t)

    local centerX = CRT.GLASS_X + CRT.GLASS_W / 2
    local centerY = CRT.GLASS_Y + CRT.GLASS_H / 2

    if t < 0.3 then

        local p = t / 0.3
        local h = math.max(2, CRT.GLASS_H * 0.8 * (1 - p) * (1 - p))

        self:drawGlassBand(centerY - h / 2, h, 0.25 + 0.6 * p, 0.8, 1, 0.85)

    elseif t < 0.65 then

        local p = (t - 0.3) / 0.35
        local w = math.max(4, (CRT.GLASS_W - 40) * (1 - p) * (1 - p))

        self:drawRect(centerX - w / 2, centerY - 1, w, 2, 0.9, 0.85, 1, 0.9)
        self:drawRect(centerX - w / 2, centerY - 4, w, 8, 0.15, 0.6, 1, 0.7)

    else

        local p = (t - 0.65) / 0.35
        local a = 1 - p

        self:drawRect(centerX - 2, centerY - 2, 4, 4, 0.95 * a, 0.9, 1, 0.95)
        self:drawRect(centerX - 7, centerY - 7, 14, 14, 0.12 * a, 0.6, 1, 0.7)
    end
end

function CRTMonitor:drawRefreshBand(now)

    local travel = CRT.GLASS_H + CRT.REFRESH_BAND_H
    local phase = (now % CRT.REFRESH_PERIOD_MS) / CRT.REFRESH_PERIOD_MS
    local top = CRT.GLASS_Y - CRT.REFRESH_BAND_H + phase * travel

    -- Soft-edged: a stack of slices peaking in the middle.
    local slices = 7
    local sliceH = CRT.REFRESH_BAND_H / slices

    for i = 0, slices - 1 do

        local k = 1 - math.abs((i + 0.5) / slices * 2 - 1)

        self:drawGlassBand(
            top + i * sliceH,
            sliceH,
            CRT.REFRESH_ALPHA * k,
            0.7,
            1,
            0.75
        )
    end
end

function CRTMonitor:drawChin(ledLevel)

    ---------------------------------------------------------------
    -- Embossed maker's label
    ---------------------------------------------------------------

    local brand = "KIPN"
    local tagline = "KNOX COUNTY INFORMATION AND PROPERTY NETWORK"

    local brandW =
        getTextManager():MeasureStringX(
            UIFont.Medium,
            brand
        )

    local x = CRT.LABEL_X
    local y = CRT.LABEL_Y

    self:drawText(brand, x + 1, y + 1, 1, 1, 0.95, 0.35, UIFont.Medium)
    self:drawText(brand, x, y, 0.30, 0.28, 0.24, 0.85, UIFont.Medium)

    local tx = x + brandW + 14
    local ty = y + 4

    self:drawText(tagline, tx + 1, ty + 1, 1, 1, 0.95, 0.30, UIFont.Small)
    self:drawText(tagline, tx, ty, 0.36, 0.34, 0.29, 0.75, UIFont.Small)

    ---------------------------------------------------------------
    -- Power LED
    ---------------------------------------------------------------

    if ledLevel > 0 then

        local lx = CRT.LED_X
        local ly = CRT.LED_Y

        self:drawRect(lx - 9, ly - 9, 18, 18, 0.06 * ledLevel, 0.3, 1, 0.3)
        self:drawRect(lx - 6, ly - 6, 12, 12, 0.12 * ledLevel, 0.3, 1, 0.3)
        self:drawRect(lx - 3, ly - 2, 6, 4, 0.95 * ledLevel, 0.35, 1, 0.35)
        self:drawRect(lx - 2, ly - 3, 4, 6, 0.95 * ledLevel, 0.35, 1, 0.35)
        self:drawRect(lx - 1, ly - 2, 2, 1, 0.8 * ledLevel, 0.9, 1, 0.9)
    end
end

function CRTMonitor:render()

    local now = crtNowMs()
    local ledLevel = 1

    if self.screen then

        if self.powerOnAt then

            local t = (now - self.powerOnAt) / CRT.POWER_ON_MS

            if t >= 1 then
                self.powerOnAt = nil
            else
                self:drawPowerOn(t)
            end
        end

        self:drawRefreshBand(now)

        self:drawGlassBand(
            CRT.GLASS_Y,
            CRT.GLASS_H,
            crtRandom() * CRT.FLICKER_ALPHA,
            0,
            0,
            0
        )

    elseif self.powerOffAt then

        local t = math.min(1, (now - self.powerOffAt) / CRT.POWER_OFF_MS)

        self:drawPowerOff(t)

        ledLevel = 1 - t
    end

    local glass = crtTexture(CRT.GLASS_TEXTURE)

    if glass then

        self:drawTextureScaled(
            glass,
            CRT.GLASS_X,
            CRT.GLASS_Y,
            CRT.GLASS_W,
            CRT.GLASS_H,
            1
        )
    end

    local bezel = crtTexture(CRT.BEZEL_TEXTURE)

    if bezel then

        self:drawTextureScaled(
            bezel,
            0,
            0,
            self.width,
            self.height,
            1
        )

    else

        self:drawRectBorder(0, 0, self.width, self.height, 1, 0.6, 0.58, 0.5)
    end

    self:drawChin(ledLevel)
end

function CRTMonitor:update()

    ISPanel.update(self)

    if self.screen then
        return
    end

    if not self.powerOffAt
        or crtNowMs() - self.powerOffAt >= CRT.POWER_OFF_MS then

        self:removeFromUIManager()

        if CRT.instance == self then
            CRT.instance = nil
        end
    end
end

--------------------------------------------------------------------
-- MOUNT
--
-- Places a full-size (800x600) KIPN screen inside the housing,
-- creating and centering the housing on first use. The screen must
-- already be initialise()d/instantiate()d.
--------------------------------------------------------------------

function CRT.Mount(screen)

    if not screen then
        return nil
    end

    local now = crtNowMs()
    local monitor = CRT.instance

    if not monitor then

        local x =
            math.max(
                0,
                math.floor(
                    (getCore():getScreenWidth() - CRT.WIDTH) / 2
                )
            )

        local y =
            math.max(
                0,
                math.floor(
                    (getCore():getScreenHeight() - CRT.HEIGHT) / 2
                )
            )

        monitor = CRTMonitor:new(x, y)
        monitor:initialise()
        monitor:instantiate()
        monitor:addToUIManager()

        monitor.powerOnAt = now

        CRT.instance = monitor

    elseif monitor.powerOffAt then

        -- Same-tick unmount/mount is a Boot -> Splash -> Terminal
        -- handoff: keep the picture live. Anything slower is the
        -- player turning it straight back on mid switch-off.
        if now - monitor.powerOffAt > CRT.HANDOFF_MS then
            monitor.powerOnAt = now
        end

        monitor.powerOffAt = nil
    end

    if monitor.screen
        and monitor.screen ~= screen then

        monitor:removeChild(monitor.screen)
        monitor.screen.parent = nil
    end

    screen:setX(CRT.SCREEN_X)
    screen:setY(CRT.SCREEN_Y)
    screen:setVisible(true)

    if screen.parent ~= monitor then
        monitor:addChild(screen)
    end

    monitor.screen = screen

    monitor:setVisible(true)
    monitor:bringToTop()

    return monitor
end

--------------------------------------------------------------------
-- UNMOUNT
--
-- Detaches a screen from the housing and starts the power-off
-- effect. A screen that was never mounted (e.g. Mount() failed) is
-- simply removed from the UIManager, as before.
--------------------------------------------------------------------

function CRT.Unmount(screen)

    if not screen then
        return
    end

    local monitor = CRT.instance

    if not monitor
        or screen.parent ~= monitor then

        screen:removeFromUIManager()
        return
    end

    monitor:removeChild(screen)
    screen.parent = nil

    if monitor.screen == screen then

        monitor.screen = nil
        monitor.powerOffAt = crtNowMs()
        monitor.powerOnAt = nil
    end
end

--------------------------------------------------------------------
-- MODULE LOAD
--------------------------------------------------------------------

print(
    "[KIPN] UI framework loaded"
)
