#!/usr/bin/env python3
"""Alerts: things worth interrupting you for. Each one is shown in the dashboard and posted to Discord.

Raised for:
  server    a public server starts advertising one of your mods (after each scan)
  comment   a player comments on a Workshop page
  visitor   someone reaches the game on the test server, and a report when they leave
  member    someone joins your Discord server (raised by community.py)

Nothing that happened before alerts were switched on is ever sent: the first run records a
start time and treats every server already in scan.json as known.

Settings (environment or ./.env):
  DISCORD_WEBHOOK   webhook URL to post to; without it alerts are dashboard only
  DASH_URL          public address of the dashboard, used for links in the messages
"""
import json, os, sys, threading, time, urllib.error, urllib.request

import collect

WEBHOOK = os.environ.get("DISCORD_WEBHOOK", "")
DASH_URL = os.environ.get("DASH_URL", "").rstrip("/")
COLORS = {"server": 0x8DB554, "comment": 0x86A7A3, "visitor": 0xDBA63A, "member": 0xC9573C, "info": 0x9D947D}
KEEP = 400
_lock = threading.Lock()


def _state():
    st = collect.load("alerts.json", None)
    if st is None:  # first run: start the clock and take the current scan as the baseline
        scan = collect.load("scan.json", None) or {}
        st = {"since": int(time.time()), "alerts": [],
              "servers": {f"{h['ip']}:{h['qport']}|{wid}": scan.get("scanned_at", 0) for h in scan.get("hits", []) for wid in h["mods"]}}
        collect.save("alerts.json", st)
    return st


def since():
    return _state()["since"]


def recent(n=60):
    return _state()["alerts"][:n]


def post(alert):
    """Send one alert to Discord. Returns '' on success, otherwise why it failed."""
    if not WEBHOOK:
        return "no webhook set"
    embed = {"title": alert["title"][:250], "description": alert["text"][:3500], "color": COLORS.get(alert["kind"], COLORS["info"]),
             "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(alert["ts"]))}
    if alert.get("url"):
        embed["url"] = alert["url"]
    body = json.dumps({"username": "Mod Desk", "embeds": [embed], "allowed_mentions": {"parse": []}}).encode()
    for _ in range(3):
        req = urllib.request.Request(WEBHOOK, data=body, headers={"Content-Type": "application/json",
                                                                 "User-Agent": "lilPZmods-dashboard (https://theblb.zapto.org, 1.0)"})
        try:
            urllib.request.urlopen(req, timeout=20).read()
            return ""
        except urllib.error.HTTPError as e:
            if e.code == 429:  # rate limited: Discord says how long to wait
                try:
                    time.sleep(min(10, float(json.load(e).get("retry_after", 2))))
                except Exception:
                    time.sleep(2)
                continue
            return f"Discord answered {e.code}"
        except Exception as e:
            return str(e)
    return "rate limited"


def raise_alert(key, kind, title, text, url="", ts=None, tab=""):
    """Record an alert once (by key) and send it. Safe to call again with the same key."""
    with _lock:
        st = _state()
        if any(a["key"] == key for a in st["alerts"]):
            return False
        alert = {"key": key, "kind": kind, "title": title, "text": text, "ts": int(ts or time.time()),
                 "url": url or (f"{DASH_URL}/#{tab}" if DASH_URL and tab else DASH_URL), "tab": tab}
        alert["error"] = post(alert)
        time.sleep(0.6)  # stay well under Discord's webhook rate limit when several fire together
        st = _state()  # re-read: the scanner runs as a separate process and may have saved meanwhile
        st["alerts"] = sorted([alert] + st["alerts"], key=lambda a: -a["ts"])[:KEEP]
        collect.save("alerts.json", st)
        if alert["error"]:
            print(f"alert not delivered ({alert['error']}): {title}", file=sys.stderr, flush=True)
        return True


def retry_unsent():
    with _lock:
        st, changed = _state(), False
        for a in st["alerts"]:
            if a.get("error") and a["error"] != "no webhook set" and time.time() - a["ts"] < 86400:
                a["error"] = post(a)
                changed = True
        if changed:
            collect.save("alerts.json", st)


def check_servers(hits, meta, owner_name=""):
    """Called after a scan. Marks each hit with when it was first seen and alerts on new ones."""
    with _lock:
        st = _state()
        known = st["servers"]
    fresh, now = [], int(time.time())
    for h in hits:
        firsts = []
        for wid in h["mods"]:
            k = f"{h['ip']}:{h['qport']}|{wid}"
            if k not in known:
                known[k] = now
                fresh.append((h, wid))
            firsts.append(known[k])
        h["first_seen"] = min(firsts) if firsts else now
    with _lock:
        st = _state()
        st["servers"] = known
        collect.save("alerts.json", st)
    for h, wid in fresh:
        if owner_name and owner_name.lower() in h["name"].lower():
            continue  # your own server
        m = meta.get(wid, {})
        title = m.get("title") or (m.get("mod_ids") or [wid])[0]
        text = (f"**{h['name']}** is advertising `{(m.get('mod_ids') or ['?'])[0]}`.\n"
                f"Players {h.get('players', '?')}/{h.get('max', '?')} · {h['mod_count']} mods · `{h['ip']}:{h['qport']}`")
        if m.get("visibility") != "public":
            text += "\nThis mod is not public, so this is probably another author's mod with the same Mod ID."
        raise_alert(f"server:{h['ip']}:{h['qport']}|{wid}", "server", f"New server running {title}", text, tab="servers")
    return len(fresh)


def check_comments(new_comments, meta):
    """new_comments: (workshop id, comment) pairs first seen on this run."""
    start = since()
    for wid, c in new_comments:
        if c.get("own") or c["ts"] < start:
            continue
        raise_alert(f"comment:{c['id']}", "comment", f"New comment on {meta.get(wid, {}).get('title', wid)}",
                    f"**{c['author']}**: {c['text'][:900]}", ts=c["ts"],
                    url=f"https://steamcommunity.com/sharedfiles/filedetails/comments/{wid}")


def _dur(s):
    s = int(s)
    return f"{s} s" if s < 60 else f"{s // 60} min" if s < 3600 else f"{s // 3600} h {s % 3600 // 60} min"


def check_visitors(rep):
    """rep: server.report() output. Alerts when a visitor spawns, and again with a summary when they leave."""
    if not rep or rep.get("paused") or not rep.get("available"):
        return
    start = since()
    for s in rep.get("sessions", []):
        if s["end"] < start and not s["open"]:
            continue
        key = f"{s['sid']}:{s['start']}"
        if s["open"] and s["joined"]:
            raise_alert(f"visitor-on:{key}", "visitor", f"{s['name']} is on your test server", "They just spawned in.", tab="server")
        elif not s["open"]:
            if s["joined"]:
                mods = ", ".join(m["folder"] or m["module"] for m in s["modules"]) or "no mod"
                text = (f"{s['label']} · in game {_dur(s['in_game_secs'])} · active {s['active_min']} min · engagement {s['engagement']}%\n"
                        f"Tests tried: {s['tests']} · touched: {mods}")
            else:
                text = f"{s['label']} after {_dur(s['secs'])}" + (f": {s['kick']}" if s["kick"] else ", before reaching the game.")
            raise_alert(f"visitor-off:{key}", "visitor", f"Visitor report: {s['name']}", text, ts=s["end"], tab="server")
