#!/usr/bin/env python3
"""Live feed: posts what visitors do on the test server to Discord, as it happens.

  #server-joins   someone spawns in, fails to get in, or leaves
  #test-runs      each test a visitor starts
  #test-results   each test outcome (pass, fail, error)
  #session-summaries   one message per visit, from login to logout, posted when they leave

The channels are created under a "Test Server" category if they are missing, which needs the bot
to have Manage Channels. Until they exist, everything goes to the alerts webhook channel instead.

The owner is never posted about, and nothing that happens while the owner is connected is posted,
then or later, unless FEED_INCLUDE_OWNER=1 is set, in which case the owner is posted like any visitor.
Only the current server boot's logs are read, so this is cheap to run every few seconds.
"""
import json, os, sys, time, urllib.error, urllib.request

import alerts
import collect
import community
import server

CATEGORY = "Test Server"
CHANNELS = {"joins": ("server-joins", "Who joins and leaves the mod test server. Posted automatically."),
            "runs": ("test-runs", "Each test a visitor starts on the mod test server. Posted automatically."),
            "results": ("test-results", "The outcome of each test on the mod test server. Posted automatically."),
            "summaries": ("session-summaries", "One summary per visit to the mod test server, posted when the visitor leaves.")}
COLORS = {"summary": 0xDBA63A, "join": 0x8DB554, "leave": 0x9D947D, "bounce": 0xC9573C, "run": 0x86A7A3, "pass": 0x8DB554, "fail": 0xE4604B, "error": 0xE4604B}
MAX_PER_TICK = 15
status = {"channels": {}, "error": "", "paused": False}


def bot_post(path_, payload):
    req = urllib.request.Request(community.API + path_, data=json.dumps(payload).encode(), method="POST",
                                 headers={"Authorization": f"Bot {community.TOKEN}", "User-Agent": community.UA, "Content-Type": "application/json"})
    for _ in range(3):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                try:
                    time.sleep(min(10, float(json.load(e).get("retry_after", 2))))
                except Exception:
                    time.sleep(2)
                continue
            if e.code in (403, 404):
                raise community.Forbidden(path_)
            raise
    raise RuntimeError("rate limited")


def ensure_channels(st):
    """Find the three feed channels by name, creating whatever is missing. Returns key -> channel id."""
    if not community.TOKEN:
        status["error"] = "no bot token"
        return {}
    age = time.time() - st.get("channels_checked", 0)
    if age < 60 or (len(st.get("channels", {})) == len(CHANNELS) and age < 600):
        status["error"] = st.get("channels_error", "")
        return st.get("channels", {})
    gid = community.GUILD or (collect.load("discord.json", None) or {}).get("guild") or community.webhook_target()[0]
    if not gid:
        status["error"] = "no Discord server known"
        return {}
    existing = community.api(f"/guilds/{gid}/channels")
    by_name = {c["name"]: c["id"] for c in existing if c["type"] in (0, 5)}
    found = {k: by_name[name] for k, (name, _) in CHANNELS.items() if name in by_name}
    status["error"] = ""
    if len(found) < len(CHANNELS):
        try:
            cat = next((c["id"] for c in existing if c["type"] == 4 and c["name"].lower() == CATEGORY.lower()), None)
            if not cat:
                cat = bot_post(f"/guilds/{gid}/channels", {"name": CATEGORY, "type": 4})["id"]
            for k, (name, topic) in CHANNELS.items():
                if k not in found:
                    found[k] = bot_post(f"/guilds/{gid}/channels", {"name": name, "type": 0, "parent_id": cat, "topic": topic})["id"]
        except community.Forbidden:
            missing = ", ".join("#" + CHANNELS[k][0] for k in CHANNELS if k not in found)
            status["error"] = f"The bot is not allowed to create channels ({missing} missing). Give its role Manage Channels, or create them by hand."
    st["channels"], st["channels_checked"], st["channels_error"] = found, time.time(), status["error"]
    return found


def send(channels, key, color, title, text="", fallback=True):
    embed = {"title": title[:250], "color": COLORS[color]}
    if text:
        embed["description"] = text[:1500]
    if key in channels:
        try:
            bot_post(f"/channels/{channels[key]}/messages", {"embeds": [embed], "allowed_mentions": {"parse": []}})
            return
        except community.Forbidden:
            status["error"] = f"The bot cannot post in #{CHANNELS[key][0]}. It needs Send Messages and Embed Links there."
    if fallback:
        alerts.post({"title": title, "text": text, "kind": "visitor", "ts": time.time()})  # the alerts channel


def mod_title(module, meta):
    folder = server.folder_for(module)
    return next((m["title"] for m in meta.values() if m.get("folder") == folder), folder or module.split(".")[0])


def summary_text(r, meta):
    """One visit, login to logout, as a Discord message body."""
    head = (f"**{r['label']}** · connected {alerts._dur(r['secs'])} · in game {alerts._dur(r['in_game_secs'])}\n"
            f"Active {r['active_min']} min · engagement {r['engagement']}% · {r['tests']} test{'' if r['tests'] == 1 else 's'} tried · "
            f"{r['walked']} tiles walked · {r['chat']} chat line{'' if r['chat'] == 1 else 's'}")
    mods = []
    for m in r["modules"]:
        score = f", {m['pass']} pass, {m['fail'] + m['error']} fail" if m["pass"] or m["fail"] or m["error"] else ""
        mods.append(f"• {mod_title(m['folder'] or m['module'], meta)}: {m['actions']} action{'' if m['actions'] == 1 else 's'}{score}")
    lines = []
    for e in r["timeline"]:
        if e["kind"] not in ("test", "command", "chat"):
            continue
        what = (mod_title(e["folder"] or e["module"], meta) + ": " if e["module"] else "") + e["text"]
        lines.append(f"`+{e['at'] // 60}:{e['at'] % 60:02d}` {what[:90]}" + (f" ×{e['n']}" if e["n"] > 1 else "") + (f" — **{e['status'].upper()}**" if e["status"] else ""))
    shown = lines[:25]
    if len(lines) > 25:
        shown.append(f"…and {len(lines) - 25} more steps")
    return head + ("\n\n**Mods touched**\n" + "\n".join(mods) if mods else "\n\nTouched no mod and ran no test.") + ("\n\n**What they did**\n" + "\n".join(shown) if shown else "")


def tick():
    st = collect.load("livefeed.json", None) or {"since": time.time(), "posted": []}
    channels = ensure_channels(st)
    status["channels"] = {CHANNELS[k][0]: v for k, v in channels.items()}
    include_owner = os.environ.get("FEED_INCLUDE_OWNER", "").strip().lower() in ("1", "true", "yes")
    owners = set() if include_owner else server.owner_ids()
    sessions = server.read_sessions()
    owner_sids = {s["sid"] for s in sessions if s["sid"] in owners or s["name"] in owners}
    mine = lambda s: s["sid"] in owner_sids
    newest = max((b for b, _ in server.log_files("user")), default="")
    status["paused"] = any(s["end"] is None and s["boot"] == newest and mine(s) for s in sessions)
    if status["paused"]:
        st["since"] = time.time()  # whatever happens while the owner is on is never posted
        collect.save("livefeed.json", st)
        return
    since, posted, out = st["since"], set(st["posted"]), []
    meta = (collect.load("data.json", None) or {}).get("meta", {})
    visits = [s for s in sessions if not mine(s)]
    seen_before = {}
    for s in sorted(visits, key=lambda s: s["start"]):
        n = seen_before[s["sid"]] = seen_before.get(s["sid"], 0) + 1
        key = f"{s['sid']}:{int(s['start'])}"
        if s["joined"] and s["joined"] >= since:
            out.append((s["joined"], f"join:{key}", "joins", "join", f"{s['name']} joined the test server", "First visit." if n == 1 else f"Visit number {n}."))
        if s["end"] and s["end"] >= since:
            if s["joined"]:
                out.append((s["end"], f"leave:{key}", "joins", "leave", f"{s['name']} left", f"In game for {alerts._dur(s['end'] - s['joined'])}."))
                if f"summary:{key}" not in posted and "summaries" in channels:
                    one = {s["name"]}
                    here = lambda ts, s=s: s["name"] if s["joined"] <= ts <= s["end"] + 5 and not any(
                        o is not s and o["joined"] and o["boot"] == s["boot"] and o["joined"] <= ts <= (o["end"] or time.time()) + 5 for o in sessions) else ""
                    r = server.summarise(s, [e for e in server.player_events(one, here, boot=s["boot"]) if e[1] in one])
                    out.append((s["end"] + 1, f"summary:{key}", "summaries", "summary", f"{s['name']}: visit summary", summary_text(r, meta)))
            else:
                why = s["kick"] or "dropped while loading"
                out.append((s["end"], f"bounce:{key}", "joins", "bounce", f"{s['name']} could not get in", f"{why[:1].upper() + why[1:]}, {alerts._dur(s['end'] - s['start'])} after connecting."))

    names = {s["name"] for s in visits if (s["end"] or time.time()) >= since}
    if names:
        joined = [s for s in sessions if s["joined"] and s["boot"] == newest]

        def alone_at(ts):
            here = {s["name"] for s in joined if s["joined"] <= ts <= (s["end"] or time.time()) + 5}
            return here.pop() if len(here) == 1 else ""

        for ts, who, kind, module, text, result, _ in server.player_events(names, alone_at, boot=newest):
            if kind != "test" or who not in names or ts < since:
                continue
            key = f"test:{int(ts)}:{who}:{module}:{text[:60]}"
            mod = mod_title(module, meta)
            if result:
                out.append((ts, key, "results", result, f"{result.upper()}: {mod}", f"**{who}** · {text}"))
            else:
                out.append((ts, key, "runs", "run", f"{who} ran a {mod} test", text))

    sent = 0
    for ts, key, channel, color, title, text in sorted(out):
        if key in posted:
            continue
        if sent >= MAX_PER_TICK:
            break  # the rest go out on the next tick
        send(channels, channel, color, title, text, fallback=channel != "summaries")  # the alerts channel already gets a visitor report
        posted.add(key)
        sent += 1
        time.sleep(0.4)
    st["posted"] = sorted(posted)[-3000:]
    collect.save("livefeed.json", st)
    return sent


if __name__ == "__main__":
    n = tick()
    print("paused: owner connected" if status["paused"] else f"posted {n or 0}", "| channels:", status["channels"], "|", status["error"] or "ok")
