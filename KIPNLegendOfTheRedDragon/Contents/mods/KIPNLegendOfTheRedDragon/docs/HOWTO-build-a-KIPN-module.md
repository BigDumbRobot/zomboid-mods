# How to build a KIP Network module

A walkthrough for third-party creators, using **KIPN: Legend of the Red Dragon**
(this mod) as a complete, working worked example.

KIPN Terminal is a *host*. It owns transport, accounts, sessions, the in-world
computer, and the server-driven main menu. A "module" is a **separate Workshop
mod** that `require=KIPN`, registers itself with KIPN at load, and shows up as a
program on the terminal main menu. You never edit a KIPN file.

The full registration contract is `KIPN/docs/README-SERVICE-API.md`. This guide
is the shortest path through it for a menu-only feature (no claims, no world
zones, no item scripts) — which is most add-ons.

---

## 0. What we're building

A classic BBS door game. One menu entry, **Play LORD**, that appears on *every*
computer for *any* logged-in KIPN account regardless of zone. Clicking it opens a
terminal screen with a full LORD loop — a Town Square hub leading to the forest,
King Arthur's Weapons, Abdul's Armour, the Healer, the Bank, the Inn, Turgon's
Warrior Training (a named master per level), and finally the Red Dragon. All game
state is server-authoritative and persisted in the save.

The game's own design (combat maths, the economy, difficulty tuning) is its own
concern; what matters for this guide is that **every KIPN touch-point is small**:
one command, one response event, one data domain, one screen. A bank add-on would
have exactly the same shape.

That exercises every piece a typical module needs:

| Piece | KIPN API used |
|---|---|
| Its own mod that loads after KIPN | `mod.info` `require=KIPN` |
| Shared wire names both realms agree on | `KIPN.Shared.RegisterCommand` / `RegisterResponseEvent` |
| A menu entry, gated however you want | `KIPN.Server.ApplicationRegistry.Register` |
| Server logic that runs after KIPN is up | `KIPN.Server.RegisterService` |
| Client → server requests | `KIPN.Server.RegisterCommandHandler` + `sendClientCommand` |
| Server → client responses | `KIPN.Server.SendToPlayer` → screen `:receiveResponse` |
| Its own persisted data | `KIPN.Server.RegisterDataDomain` + `GetData()` / `Save()` |
| A terminal screen | `KIPN.UI.CreateScreen` |
| Server-owner configuration | `media/sandbox-options.txt` on the `KIPN` page |
| Compatibility safety | `KIPN.API.Require` |

---

## 1. Mod layout

```
KIPNLegendOfTheRedDragon/
  42/
    mod.info
    media/
      sandbox-options.txt                         # your options, KIPN page
      lua/
        shared/
          KIPN_LORDShared.lua                      # wire names + static tables
          Translate/EN/Sandbox.json               # option labels
        server/
          KIPN_LORDGame.lua                        # pure game logic + data domain
          KIPN_LORDInit.lua                        # registration: service, handlers, menu
        client/
          KIPN_LORDScreen.lua                      # the terminal screen
```

`mod.info`:

```ini
name=KIPN: Legend of the Red Dragon
id=KIPNLegendOfTheRedDragon
description=A classic BBS door game for the KIP Network. Adds a "Play LORD" ...
author=lilBubby
require=KIPN
versionMin=42.0
```

`require=KIPN` is the whole trick: the game loads KIPN's files **before** yours
and refuses to load your mod at all if KIPN is missing.

### Load order

* **Between mods** — `require=KIPN` in `mod.info`.
* **Within your mod** — Project Zomboid auto-loads every file under
  `media/lua/{server,client}` (and `shared` first). You control order *inside*
  your mod with `require "..."` at the top of each file:

  ```lua
  require "KIPN_Shared"      -- KIPN's shared contract + KIPN.API
  require "KIPN_Server"      -- KIPN's server framework
  require "KIPN_LORDShared"  -- your own shared file
  ```

  > **Use the bare file name**, not a path. `require "KIPN_Server"` works;
  > `require "KIPN/KIPN_Server"` does **not** (KIPN's files are not under a
  > `KIPN/` subfolder). The README-SERVICE-API examples that show the slash
  > form are wrong — the shipped companion mods all use the bare form.

---

## 2. The shared contract — `KIPN_LORDShared.lua`

Both realms load this before anything else of yours. It does exactly one thing:
extend KIPN's shared enums with your wire names, so `KIPN.Shared.Commands.X` and
`KIPN.Shared.ResponseEvents.Y` resolve on both client and server without editing
`KIPN_Shared.lua`.

```lua
require "KIPN_Shared"

KIPN.LORD = KIPN.LORD or {}
KIPN.LORD.API_VERSION = 1               -- the KIPN service contract you built against

KIPN.Shared.RegisterCommand("LORD_GET_STATE", "lordGetState")
KIPN.Shared.RegisterCommand("LORD_ACTION",    "lordAction")
KIPN.Shared.RegisterResponseEvent("LORD_STATE", "lordState")
```

* First arg = the **key** you'll write in code (`KIPN.Shared.Commands.LORD_ACTION`).
* Second arg = the **wire string** actually sent on the network.
* Re-registering the same key/value is a no-op (so it's safe to load on both
  realms). Re-registering a key with a *different* value is rejected and logged —
  two mods can't silently collide.

Prefix your wire names (`lord…`) so they're globally unique.

This mod uses **one** request command carrying an `action` field, and **one**
response event carrying the whole game snapshot back. That keeps the surface
tiny; you don't need a command per button.

---

## 3. Compatibility guard — `KIPN.API.Require`

`KIPN.Shared.API_VERSION` is the contract version. Put this near the top of your
init file (and your screen file) so an incompatible KIPN produces **one clean log
line instead of a stack trace**:

```lua
local ok, why = KIPN.API.Require(KIPN.LORD.API_VERSION)
if not ok then
    print("[KIPN LORD] disabled: " .. tostring(why))
    return
end
```

For features that might not exist on older KIPN builds, feature-detect instead of
version-sniffing:

```lua
if KIPN.API.Has("dataDomains") then ... end
```

---

## 4. The menu entry — `ApplicationRegistry.Register`

Registered at **module load** (top level of your init file), not inside a service
`initialize`:

```lua
KIPN.Server.ApplicationRegistry.Register("play_lord", {
    name            = "Play LORD",
    description     = "Legend of the Red Dragon -- the classic BBS door game.",
    order           = 80,                 -- sort position in the menu
    screen          = "KIPN_LORDScreen",  -- the _G name of your CreateScreen class
    requiresSession = true,               -- must be a logged-in KIPN account
    permissions     = {},                 -- no permission gate
    capabilities    = {},                 -- no computer-capability gate
    classifications = {},                 -- no zone gate -> shows for EVERY zone
})
```

**How gating works** — the server (`GET_APPLICATIONS`) decides the whole menu; the
client shows exactly what it's sent, no client-side filtering:

| Field | Empty / false | Non-empty |
|---|---|---|
| `permissions` | anyone | account must hold every listed permission |
| `capabilities` | any computer | the computer's zone must grant every listed capability |
| `classifications` | **every zone, and no zone at all** | only computers inside a zone of a matching type |
| `requiresSession` | shown pre-login too | filtered out until the account resolves |

So "a main-menu option for any zone" = **all three lists empty**. If instead you
wanted it only at a Government building, you'd register a zone type and pass
`classifications = { "GOVERNMENT" }` (see README-SERVICE-API §2.5).

An entry with no `screen` is a capability marker only and never renders as a row.

---

## 5. The server service — `RegisterService`

`RegisterService` gives you an `initialize()` that runs **once, after every KIPN
built-in service is up**, in dependency order. Register your command handlers
here.

```lua
KIPN.Server.RegisterService("LegendOfTheRedDragon", {
    apiVersion = KIPN.LORD.API_VERSION,   -- advisory: mismatch is logged, not fatal
    dependsOn  = { "ApplicationRegistry" },
    order      = 700,                      -- tie-breaker within a dependency tier
    initialize = function()
        KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.LORD_GET_STATE, handleGetState)
        KIPN.Server.RegisterCommandHandler(KIPN.Shared.Commands.LORD_ACTION,    handleAction)
        return true                        -- return false to signal failure
    end,
})
```

`dependsOn` names other registered add-on services or KIPN built-ins
(`WorldRegistry`, `ClaimService`, `ArtifactService`, `Permissions`,
`ApplicationRegistry`, …) — built-ins are treated as already-ready. Cycles and
missing deps are logged and your service is skipped.

---

## 6. Client → server → client

### Command handler (server)

The router calls your handler as `handler(player, args)`. Validate everything —
the client only *requests*.

```lua
local function handleAction(player, args)
    local action = args and args.action
    if type(action) ~= "string" or action == "" then
        return false, "NO_ACTION"        -- false + reason = decline (router sends an ERROR)
    end
    local snapshot, err = KIPN.LORD.Server.HandleAction(player, action)
    if not snapshot then
        KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.ERROR,
            { code = err or "LORD_ERROR", message = "..." })
        return true
    end
    KIPN.Server.SendToPlayer(player, KIPN.Shared.ResponseEvents.LORD_STATE, snapshot)
    return true
end
```

Identify the caller with `KIPN.Shared.GetPlayerId(player)` (a stable Steam64
string; `"SINGLEPLAYER"` in SP). Never trust a name as an identifier.

### Sending a request (client)

```lua
sendClientCommand("KIPN", KIPN.Shared.Commands.LORD_ACTION, { action = "forest" })
```

Always module `"KIPN"` — that's the channel KIPN's router listens on.

### Receiving a response (client)

You do **not** register `OnServerCommand`. KIPN_Terminal is the single client-side
router; it forwards every KIPN response to the **active** screen's
`receiveResponse`:

```lua
function KIPN_LORDScreen:receiveResponse(event, data)
    if event == KIPN.Shared.ResponseEvents.LORD_STATE and type(data) == "table" then
        self.snap = data          -- store the snapshot; prerender() renders from it
        self.loading = false
    end
end
```

---

## 7. Persisted data — `RegisterDataDomain`

KIPN owns all persistence (in the save's `ModData`). To get your own slice, call
this at **module load** (before KIPN's server init runs):

```lua
KIPN.Server.RegisterDataDomain("lordDragon", { chars = {}, hall = {} })
```

Then:

```lua
local data = KIPN.Server.GetData()      -- the whole KIPN store
data.lordDragon.chars[steamId] = { ... }
KIPN.Server.Save("lordDragon")          -- persists AND transmits only this slice
```

`Save("lordDragon")` is scoped — it doesn't rewrite the rest of KIPN's data. Your
domain is per-save; switching saves gives you a fresh empty table.

For claims / ownership specifically, prefer the generic `ClaimService` /
`ArtifactService` stores instead of a raw domain (README-SERVICE-API §2.6–2.7).

---

## 8. The terminal screen — `KIPN.UI.CreateScreen`

```lua
require "KIPN_UI"
require "KIPN_LORDShared"

KIPN_LORDScreen = KIPN.UI.CreateScreen("KIPN_LORDScreen")   -- registers _G["KIPN_LORDScreen"]
```

The global name must match the `screen = "..."` you passed to
`ApplicationRegistry.Register`.

**Lifecycle** (KIPN_Terminal drives it):

| Method | When | Use it for |
|---|---|---|
| `:new(x,y,w,h)` | construction | supplied by `CreateScreen`, don't override |
| `:initialise()` | once | `ISPanel.initialise(self)`, `KIPN.UI.SetupScreen(self)`, state fields |
| `:onShow()` | becomes active | first server request; create buttons here (javaObject exists now) |
| `:prerender()` | every frame | draw content — the terminal owns the chrome/clock/HOME/CLOSE |
| `:update()` | every frame | timeouts, periodic refresh |
| `:receiveResponse(event,data)` | server message | store payload |
| `:onLeaveScreen()` | navigating away | cleanup |

**Rules:**

* The terminal owns the shell. Draw *content only*. Don't touch `UIManager`,
  don't add HOME/CLOSE, don't register `OnServerCommand`.
* Create child widgets (buttons) in `onShow`, not `initialise` — see the long
  comment in KIPN's own `KIPN_ServerStats.lua` for why (`javaObject` doesn't
  exist yet at `initialise` time).
* ASCII only in drawn text. PZ's bitmap fonts have no box-drawing glyphs, no `°`,
  no emoji — they render as `?`. Use `KIPN.UI.DrawBanner` / `DrawTable` /
  `DrawSectionHeader`, which are built from `+ = |`.
* `KIPN.UI` gives you the theme, `CreateButton`, `DrawTable`, `DrawBanner`,
  `DrawStatusMessage`, `EnableScroll` + `ScrollY` + `SetContentHeight`. Read
  colours/fonts from `KIPN.UI.Theme`, never hard-code `{r=0,g=1,b=0}`.

This mod keeps a fixed set of buttons created once in `onShow` and just toggles
`:setVisible()` / repositions them each frame based on `snap.place`
(`"town"` / `"fight"` / `"dead"`).

### 8a. Extending one of KIPN's *own* screens (no formal hook)

Sometimes you want your data on a screen KIPN already ships — e.g. this mod adds a
**Legend of the Red Dragon** panel to the built-in **Server Statistics** screen.
KIPN has no "register a section" API for that, so the mod wraps methods on the
`KIPN_ServerStats` class from a client file that loads after KIPN:

```lua
-- media/lua/client/KIPN_LORDServerStatsPatch.lua
local SS = _G.KIPN_ServerStats
if type(SS) ~= "table" then return end            -- bail quietly if it's gone/renamed

local _render = SS.renderServerTab
function SS:renderServerTab(y)
    local endY = _render and _render(self, y) or y  -- let KIPN draw its content first
    -- ...draw your own section from endY downward, return the new bottom y...
    return endY2
end
```

Same pattern for `requestStatistics` (piggy-back your own `sendClientCommand`) and
`receiveResponse` (capture your event, then call the original). Rules of thumb:

* **Wrap, don't replace** — always call the captured original.
* **Guard everything** — `if type(SS) ~= "table"` and `if _render` — so a future
  KIPN refactor degrades to "my panel doesn't show", never a stack trace.
* Return a larger `y` and the host screen's `SetContentHeight` grows its
  scrollbar for you.
* Use a **read-only** server command for the data (this mod's `LORD_LEADERBOARD`
  never creates a character) so merely opening Server Stats has no side effects.

This is a soft contract, not a supported API — but it's how you put your feature
where players already look.

---

## 9. Server-owner configuration — sandbox options

All KIPN configuration is sandbox-only (there is no in-terminal admin screen).
Ship your options on the **shared `KIPN` page**:

`media/sandbox-options.txt`:

```
VERSION = 1,

option KIPN.LORDForestFightsPerDay
{
    type = integer, default = 15, min = 1, max = 100,
    page = KIPN,
    translation = KIPN_LORDForestFightsPerDay,
}
```

`media/lua/shared/Translate/EN/Sandbox.json`:

```json
{
  "Sandbox_KIPN_LORDForestFightsPerDay": "LORD: Forest Turns Per Day",
  "Sandbox_KIPN_LORDForestFightsPerDay_tooltip": "How many forest encounters ..."
}
```

Read it server-side off the flat table, keyed by option name only:

```lua
local sv = SandboxVars and SandboxVars.KIPN or {}
local perDay = tonumber(sv.LORDForestFightsPerDay) or 15
```

Sandbox options are read at **server boot only** — changes need a restart.

---

## 10. Testing on the docker dev server

This repo (`kipn-docker-dev-server`) auto-mounts every folder under `workshop/`
into the server's `mods/` and adds it to `Mods=`. So:

1. Put your mod at `workshop/<ModId>/42/...` (same shape as `workshop/KIPN`).
2. `node manage.mjs stop` **first** — a running server rewrites its `.ini` on
   shutdown and would clobber manual edits.
3. Edit the active `server-data/Server/<SERVER_NAME>.ini`:
   `Mods=\KIPN;\KIPNLegendOfTheRedDragon` and clear `WorkshopItems=`.
4. `node manage.mjs up`, then `docker compose logs -f`.

Look for, in order:

```
[KIPN] Legend of the Red Dragon shared contract loaded
[KIPN LORD] game logic loaded (full LORD loop)
[KIPN] Legend of the Red Dragon init module loaded
[KIPN LORD] Legend of the Red Dragon initialized.
*** SERVER STARTED ****
```

Then in game: right-click a powered computer → **Access KIP Network** → log in →
**Play LORD** is in the menu.

> To isolate a local-only test from cached Workshop copies, wipe the workshop
> volume: `node manage.mjs down && docker volume rm kipn-dev_server-workshop`.

### Kahlua (PZ Lua) gotchas

* PZ's Lua is a 5.1-ish dialect (Kahlua). `next()` is missing — use `pairs()`.
* `getFileWriter` needs a `.txt` path.
* A 17-digit Steam64 exceeds double precision — always use the *string* from
  `KIPN.Shared.GetPlayerId`, never the raw number.

---

## 11. Checklist for your own module

- [ ] `mod.info` has `id=`, `require=KIPN`, `versionMin=42.0`
- [ ] Shared file registers wire names with a unique prefix, loaded via `require` from both realms
- [ ] `KIPN.API.Require(N)` guard at the top of server init **and** client screen
- [ ] `ApplicationRegistry.Register` at module load, `screen` = your `_G` class name
- [ ] Gating lists (`permissions` / `capabilities` / `classifications`) set deliberately — empty = everywhere
- [ ] `RegisterService` with `initialize()` registering your command handlers; `apiVersion` declared
- [ ] Command handlers validate identity + every argument server-side
- [ ] `RegisterDataDomain` at module load; mutate `GetData().<domain>`; `Save("<domain>")` after writes
- [ ] Screen: content-only, buttons built in `onShow`, ASCII text, `KIPN.UI` helpers, no `UIManager`
- [ ] Options on the `KIPN` sandbox page with a `Translate/EN/Sandbox.json` entry
- [ ] Boot log shows your init line and no stack trace
```
