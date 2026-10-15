#!/usr/bin/env python3
"""Visitor reports for the showcase / test server, built from its own log files.

Reads <server-data>/Logs (MODSTATS_SERVER, default ~/kipn-docker-dev-server/server-data):
  *_user.txt             joins, spawns, disconnects, anti-cheat kicks -> sessions
  *_DebugLog-server.txt  the Mod Tester's console lines -> which tests were tried and how they went
  *_cmd.txt              client commands sent to each mod
  *_ClientActionLog.txt, *_PerkLog.txt, *_chat.txt, *_admin.txt, *_pvp.txt -> other activity

The owner (the Workshop author's Steam ID, plus SERVER_OWNER names) is never reported on, and
no report is built while the owner is connected: the last one stays up, marked as paused.

Usage: python3 server.py            print a summary
       python3 server.py --as-visitor   treat the owner as a visitor, to check the parsing (nothing is saved)
"""
import datetime, glob, math, os, re, sys, time
from zoneinfo import ZoneInfo

import collect

SERVER = os.environ.get("MODSTATS_SERVER") or os.path.expanduser("~/kipn-docker-dev-server/server-data")
TZ = ZoneInfo(os.environ.get("SERVER_TZ") or os.environ.get("TZ") or "America/Toronto")
LINE = re.compile(r"^\[(\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.\d+\]\s?(.*?)\s*$")
POLLS = {"status", "state"}  # the test panel asking the server for its state: presence, not a test
# Client commands a mod sends by itself on a timer. They show the player was there, not that they did anything.
AUTO = re.compile(r"^(submit\w*|get\w*|check\w*|request\w*|\w*sync\w*|\w*update\w*|state|status|\w*snapshot|save\w*|\w*lightstate)$", re.I)
# Tester module / command module name -> the mod folder it exercises.
MODULES = [("SVSBT", "SVSBoobyTraps"), ("SVSBoobyTraps", "SVSBoobyTraps"), ("SVSSignals", "SVSBoobyTraps"),
           ("SatanicTemples", "SatanicTemples"), ("SacrificialOffering", "SatanicTemples"), ("Skylights", "Skylights"), ("GovSvc", "KIPNGovernmentServices"),
           ("VehSvc", "KIPNVehicleServices"), ("DMM", "DeadMansMap"), ("DeadMansMap", "DeadMansMap"),
           ("Whisperers", "TheWhisperers"), ("Postal", "ThePostOffice"), ("Bonk", "BonkZone"),
           ("DynamicEvents", "DynamicEvents"), ("Blacksmith", "CareersBlacksmith"), ("Dealer", "CareersDrugDealer"),
           ("Mechanic", "CareersMechanic"), ("Careers", "KIPN_Careers"), ("lord", "KIPNLegendOfTheRedDragon"),
           ("RedDragon", "KIPNLegendOfTheRedDragon"), ("KIPN", "KIPN"), ("LilBubby", "LilBubbyModTester"),
           ("TestHarness", "BonkZone")]
_cache = {}


def folder_for(module):
    low = module.lower()
    for needle, folder in MODULES:
        if needle.lower() in low:
            return folder
    return ""


def log_files(kind):
    """(boot prefix, path) for one log type, oldest boot first. A boot's files share a date prefix."""
    paths = glob.glob(os.path.join(SERVER, "Logs", f"*_{kind}.txt")) + glob.glob(os.path.join(SERVER, "Logs", "*", f"*_{kind}.txt"))
    return sorted((os.path.basename(p)[:16], p) for p in paths)


def lines(path_):
    """(timestamp, text) per line, cached until the file changes."""
    st = os.stat(path_)
    hit = _cache.get(path_)
    if hit and hit[0] == (st.st_size, st.st_mtime):
        return hit[1]
    out = []
    with open(path_, errors="replace") as f:
        for raw in f:
            m = LINE.match(raw)
            if m:
                d, mo, y, h, mi, s, text = m.groups()
                out.append((datetime.datetime(2000 + int(y), int(mo), int(d), int(h), int(mi), int(s), tzinfo=TZ).timestamp(), text))
    _cache[path_] = ((st.st_size, st.st_mtime), out)
    return out


def read_sessions():
    """Every connection attempt, from the user logs."""
    sessions, last_boot = [], None
    for boot, p in log_files("user"):
        if boot != last_boot:  # server restarted: anyone still marked connected was dropped
            for s in sessions:
                if s["end"] is None:
                    s["end"], s["how"] = s["seen"], "server restarted"
            last_boot = boot
        opened = {}
        for s in sessions:
            if s["end"] is None:
                opened[s["sid"]] = s
        for ts, text in lines(p):
            m = re.match(r'(\d{17}) "([^"]*)" (attempting to join|allowed to join|fully connected|disconnected player)(?: \((\d+),(\d+),(\d+)\))?', text)
            if m:
                sid, name, what = m.group(1), m.group(2), m.group(3)
                s = opened.get(sid)
                if s is None and what != "disconnected player":
                    s = opened[sid] = {"sid": sid, "name": name, "start": ts, "end": None, "seen": ts, "joined": None,
                                       "spawn": None, "kick": "", "how": "", "boot": boot}
                    sessions.append(s)
                if s:
                    s["seen"] = ts
                    if what == "fully connected" and s["joined"] is None:
                        s["joined"], s["spawn"] = ts, [int(m.group(4)), int(m.group(5))]
                continue
            m = re.match(r"Connection disconnect index=\d+ guid=\d+ id=(\d{17})", text)
            if m and m.group(1) in opened:
                s = opened.pop(m.group(1))
                s["end"] = ts
                continue
            m = re.match(r'Anti-cheat="([^"]+)" is triggered for connection="([^"]+)".*?reason="([^"]+)".*?action="([^"]+)"', text)
            if m:
                for s in opened.values():
                    if s["name"] == m.group(2):
                        s["kick"] = f"{m.group(3)} ({m.group(4).lower()} by anti-cheat {m.group(1)})"
    return sessions


def owner_ids():
    ids = {x.strip() for x in os.environ.get("SERVER_OWNER", "").split(",") if x.strip()}
    owner = (collect.load("data.json", None) or {}).get("owner") or {}
    if owner.get("id"):
        ids.add(owner["id"])
    if owner.get("name"):
        ids.add(owner["name"])
    return ids or {"lilBubby"}


def player_events(names, alone_at, boot=None):
    """Everything a named player did, from every log type: (ts, name, kind, module, text, status, xy)."""
    ev = []
    name_re = re.compile(r"(?<![\w-])(" + "|".join(re.escape(n) for n in sorted(names, key=len, reverse=True)) + r")(?![\w-])") if names else None

    files = lambda kind: [(b, p) for b, p in log_files(kind) if not boot or b == boot]  # boot: only that server run
    for _, p in files("cmd"):
        for ts, text in lines(p):
            m = re.match(r'\d{17} "([^"]*)" ([\w.]+) @ (\d+),(\d+),', text)
            if m and folder_for(m.group(2)):  # other authors' mods and vanilla chatter are not reported
                command = m.group(2).split(".")[-1]
                kind = "poll" if AUTO.match(command) else "command"
                ev.append((ts, m.group(1), kind, m.group(2), command, "", (int(m.group(3)), int(m.group(4)))))
    for _, p in files("ClientActionLog"):
        for ts, text in lines(p):
            m = re.match(r"\[\d{17}\]\[([^\]]+)\]\[([^\]]+)\]\[(\d+),(\d+),\d+\](?:\[(.*?)\])?", text)
            if m:
                ev.append((ts, m.group(2), "action", "", m.group(1) + (f" {m.group(5)}" if m.group(5) else ""), "", (int(m.group(3)), int(m.group(4)))))
    for _, p in files("PerkLog"):
        for ts, text in lines(p):
            m = re.match(r"\[\d{17}\]\[([^\]]+)\]\[(\d+),(\d+),\d+\]\[([^\]=]+)\](?:\[([^\]]*)\])?(?:\[([^\]]*)\])?", text)
            if m and m.group(4) not in ("Login", "Hours Survived"):
                ev.append((ts, m.group(1), "skill", "", " ".join(x for x in m.group(4, 5, 6) if x), "", (int(m.group(2)), int(m.group(3)))))
    for _, p in files("chat"):
        for ts, text in lines(p):
            m = re.search(r"author='([^']*)'.*?text='(.*?)'\}?\.?$", text)
            if m:
                ev.append((ts, m.group(1), "chat", "", m.group(2), "", None))
    for kind in ("admin", "pvp"):
        for _, p in files(kind):
            for ts, text in lines(p):
                m = name_re.search(text) if name_re and not text.startswith("[LOG] Safety") else None
                if m:
                    ev.append((ts, m.group(1), kind, "", text.rstrip(".")[:160], "", None))

    for _, p in files("DebugLog-server"):
        for ts, text in lines(p):
            m = re.search(r"> ((?:\[[^\]]+\])+)(.*)$", text)
            if not m or not re.search(r"Test|Harness|LilBubby", m.group(1)) or "harness loaded" in m.group(2):
                continue
            tags, body = re.findall(r"\[([^\]]+)\]", m.group(1)), m.group(2)
            if body.startswith("  ") or body.strip().startswith("---"):
                continue  # indented detail under a test heading
            body = body.strip().rstrip(".").strip()
            module = "BonkZone" if "TestHarness" in tags else next((t for t in tags if re.search(r"Test|LilBubby", t)), tags[0])
            who, action, status = "", body, ""
            m2 = re.match(r"player=(\S+) weapon=(\S+) hit=(\d+)/(\d+) blocked=(\d+) hp=\S+ (PASS|FAIL)", body)
            m3 = re.match(r"(\S+) \| (.*)$", body)
            m4 = re.match(r"(\w+) (\S+?)(?: (error|refused): (.*)| (.*))?$", body)
            if m2:
                who, action, status = m2.group(1), f"PvP shot with {m2.group(2).split('.')[-1]}, {m2.group(3)}/{m2.group(4)} hits", m2.group(6).lower()
            elif m3 and m3.group(1) in names:
                who, action = m3.group(1), m3.group(2)
            elif m4 and m4.group(2) in names:
                who, action = m4.group(2), m4.group(1) + (f" ({m4.group(5)})" if m4.group(5) else "")
                if m4.group(3):
                    status, action = "error", f"{m4.group(1)}: {m4.group(4)}"
            else:
                found = name_re.search(body) if name_re else None
                who = found.group(1) if found else alone_at(ts)
                if not who:
                    continue
            if not status:
                status = "fail" if re.search(r"\bFAIL", action) else "pass" if re.search(r"\bPASS\b", action) else ""
            kind = "poll" if action.split(" ")[0].lower() in POLLS else "test"
            ev.append((ts, who, kind, module, action[:200], status, None))
    return sorted(ev, key=lambda e: e[0])


def summarise(s, events):
    """Turn one in-game session's events into the numbers the dashboard shows."""
    end = s["end"] or s["seen"]
    mine = [e for e in events if e[1] == s["name"] and s["start"] <= e[0] <= end + 5]
    minutes, modules, timeline, tests, dist, last_xy, polls = set(), {}, [], set(), 0.0, None, set()
    repeats, last_cmd = {}, None
    for e in mine:
        if e[2] == "command":
            repeats[(e[3], e[4])] = repeats.get((e[3], e[4]), 0) + 1
    for ts, _, kind, module, text, status, xy in mine:
        if kind == "command" and repeats[(module, text)] > 60:
            kind = "poll"  # fired far too often to be a person clicking
        if xy:
            if last_xy:
                step = math.dist(xy, last_xy)
                dist += step if step < 150 else 0  # bigger jumps are teleports, not walking
            last_xy = xy
        if kind == "poll":
            polls.add(int(ts // 60))
            continue
        minutes.add(int(ts // 60))
        folder = folder_for(module) if module else ""
        # The tester logs each request twice: the client command, then its own console line. Keep the richer one.
        if kind == "test" and last_cmd and ts - last_cmd[0] <= 2 and last_cmd[1] == folder and text.lower().startswith(last_cmd[2].lower()):
            modules[folder]["actions"] -= 1
            if timeline and timeline[-1][2] == "command":
                timeline[-1][6] -= 1
                if timeline[-1][6] < 1:
                    timeline.pop()
        last_cmd = (ts, folder, text) if kind == "command" else None
        if kind in ("test", "command") and (folder or module):
            mm = modules.setdefault(folder or module, {"module": module.split(".")[0], "folder": folder, "actions": 0, "pass": 0, "fail": 0, "error": 0})
            mm["actions"] += 1
            if status:
                mm[status] += 1
        if kind == "test":
            tests.add((module, re.sub(r"\d+", "#", text)[:60]))
        if timeline and timeline[-1][2:6] == [kind, module, text, status]:
            timeline[-1][6] += 1
        else:
            timeline.append([int(ts), int(ts - s["start"]), kind, module, text, status, 1, folder])
    secs = int(end - s["start"])
    in_game = int(end - s["joined"]) if s["joined"] else 0
    active = len(minutes)
    out = {"sid": s["sid"], "name": s["name"], "start": int(s["start"]), "end": int(end), "open": s["end"] is None,
           "secs": secs, "in_game_secs": in_game, "joined": bool(s["joined"]), "kick": s["kick"], "how": s["how"],
           "active_min": active, "panel_min": len(polls | minutes), "tests": len(tests), "modules": list(modules.values()),
           "actions": sum(t[6] for t in timeline), "chat": sum(1 for e in mine if e[2] == "chat"),
           "walked": int(dist), "timeline": [dict(zip(("ts", "at", "kind", "module", "text", "status", "n", "folder"), t)) for t in timeline[:250]]}
    # Engagement: share of in-game minutes with at least one logged action.
    out["engagement"] = min(100, round(100 * active / max(1, math.ceil(in_game / 60)))) if in_game else 0
    if not s["joined"]:
        out["label"] = "Kicked while joining" if s["kick"] else "Left while loading"
    elif out["tests"] >= 3 or len(modules) >= 3 or active >= 10:
        out["label"] = "Deep dive"
    elif out["tests"] or modules:
        out["label"] = "Tried tests"
    elif in_game >= 300:
        out["label"] = "Looked around"
    else:
        out["label"] = "Quick look"
    return out


def report(as_visitor=False):
    if not os.path.isdir(os.path.join(SERVER, "Logs")):
        return {"available": False, "generated": int(time.time())}
    owners = set() if as_visitor else owner_ids()
    sessions = read_sessions()
    is_owner = lambda s: s["sid"] in owners or s["name"] in owners
    owner_sids = {s["sid"] for s in sessions if is_owner(s)}
    is_owner = lambda s, base=is_owner: base(s) or s["sid"] in owner_sids  # the owner under any character name
    newest = max((b for b, _ in log_files("user")), default="")
    online = [s for s in sessions if s["end"] is None and s["boot"] == newest]
    owner_online = any(is_owner(s) for s in online)
    for s in online:  # still connected: their session runs up to this moment
        s["seen"] = time.time()
    if owner_online and not as_visitor:
        prev = collect.load("server.json", None) or {"available": True, "sessions": [], "visitors": [], "tests": []}
        return {**prev, "paused": True, "checked": int(time.time())}

    visits = [s for s in sessions if not is_owner(s)]
    names = {s["name"] for s in visits}
    joined = [s for s in sessions if s["joined"]]

    def alone_at(ts):  # lines with no name on them belong to whoever was the only player in game
        here = {s["name"] for s in joined if s["joined"] <= ts <= (s["end"] or s["seen"]) + 5}
        return here.pop() if len(here) == 1 else ""

    events = [e for e in player_events(names, alone_at) if e[1] in names] if names else []
    owner_spans = [(s["start"], s["end"] or s["seen"]) for s in sessions if is_owner(s)]
    out = []
    for s in visits:
        r = summarise(s, events)
        r["with_owner"] = any(a <= r["end"] and r["start"] <= b for a, b in owner_spans)
        out.append(r)
    out.sort(key=lambda r: -r["start"])

    people = {}
    for r in out:
        p = people.setdefault(r["sid"], {"sid": r["sid"], "name": r["name"], "visits": 0, "got_in": 0, "secs": 0, "in_game_secs": 0,
                                         "active_min": 0, "tests": 0, "modules": set(), "first": r["start"], "last": r["end"], "best": ""})
        p["visits"] += 1
        p["got_in"] += r["joined"]
        p["secs"] += r["secs"]
        p["in_game_secs"] += r["in_game_secs"]
        p["active_min"] += r["active_min"]
        p["tests"] += r["tests"]
        p["modules"] |= {m["folder"] or m["module"] for m in r["modules"]}
        p["first"], p["last"] = min(p["first"], r["start"]), max(p["last"], r["end"])
        order = ["Left while loading", "Kicked while joining", "Quick look", "Looked around", "Tried tests", "Deep dive"]
        if not p["best"] or order.index(r["label"]) > order.index(p["best"]):
            p["best"] = r["label"]
    for p in people.values():
        p["modules"] = sorted(p["modules"])

    tests = {}
    for r in out:
        for m in r["modules"]:
            t = tests.setdefault(m["folder"] or m["module"], {"folder": m["folder"], "module": m["module"], "users": set(), "sessions": 0,
                                                              "actions": 0, "pass": 0, "fail": 0, "error": 0})
            t["users"].add(r["sid"])
            t["sessions"] += 1
            for k in ("actions", "pass", "fail", "error"):
                t[k] += m[k]
    for t in tests.values():
        t["users"] = len(t["users"])

    stamps = [ts for _, p in log_files("user") for ts, _ in lines(p)[:1] + lines(p)[-1:]]
    rep = {"available": True, "paused": False, "generated": int(time.time()), "checked": int(time.time()),
           "online": sorted({s["name"] for s in online if not is_owner(s)}), "boots": len({b for b, _ in log_files("DebugLog-server")}),
           "since": int(min(stamps)) if stamps else 0, "sessions": out[:300],
           "visitors": sorted(people.values(), key=lambda p: -p["last"]),
           "tests": sorted(tests.values(), key=lambda t: -t["actions"])}
    if not as_visitor:
        collect.save("server.json", rep)
    return rep


if __name__ == "__main__":
    r = report(as_visitor="--as-visitor" in sys.argv)
    if not r.get("available"):
        sys.exit(f"no Logs folder under {SERVER}")
    if r.get("paused"):
        print("paused: the owner is connected")
    print(f"{len(r['visitors'])} visitors, {len(r['sessions'])} sessions, {r['boots']} server boots, online now: {r.get('online')}")
    for s in r["sessions"][:12]:
        when = datetime.datetime.fromtimestamp(s["start"], TZ).strftime("%b %d %H:%M")
        print(f"  {when} {s['name']:<12} {s['label']:<20} {s['secs']:>6}s  active {s['active_min']}m  tests {s['tests']}  "
              f"engagement {s['engagement']}%  mods {[m['folder'] or m['module'] for m in s['modules']]} {s['kick']}")
    for t in r["tests"][:15]:
        print(f"  test area {t['folder'] or t['module']:<24} users {t['users']} sessions {t['sessions']} actions {t['actions']} pass {t['pass']} fail {t['fail']} error {t['error']}")
