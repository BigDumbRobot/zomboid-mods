#!/usr/bin/env python3
"""Snapshot Steam Workshop stats and comments for every mod in ../, log what changed, rebuild the dashboard.

Usage: python3 collect.py            (key from STEAM_API_KEY, in the environment or ./.env)
serve.py calls collect() on a timer; running this by hand does the same thing once.

Files written to the data directory (./data, or MODSTATS_DATA):
  mods.json      the mod list last read from the Workshop folder, used when that folder is not mounted
  history.json   one stats snapshot per calendar day (the trend lines)
  state.json     the last stats seen, so each run can tell what changed
  events.json    the change log behind the Activity tab
  comments.json  every comment ever seen, including ones later deleted on Steam
  server.json    the last visitor report for the test server (written by server.py)
  alerts.json    alerts raised so far and the servers already known (written by alerts.py)
  data.json      everything the page needs; serve.py hands it to the browser after sign-in
"""
import base64, datetime, html, json, os, re, subprocess, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def load_env():
    """Read KEY=VALUE lines from ./.env so a hand run sees the same settings as the container."""
    try:
        for line in open(os.path.join(HERE, ".env")):
            k, sep, v = line.strip().partition("=")
            if sep and k and not k.startswith("#"):
                os.environ.setdefault(k.strip(), v.strip())
    except OSError:
        pass


load_env()
WORKSHOP = os.environ.get("MODSTATS_WORKSHOP") or os.path.dirname(HERE)
DATA_DIR = os.environ.get("MODSTATS_DATA") or os.path.join(HERE, "data")
os.makedirs(DATA_DIR, exist_ok=True)
API = "https://api.steampowered.com/"
COMMENTS = "https://steamcommunity.com/comment/PublishedFile_Public/render/{owner}/{fid}/"
VISIBILITY = {0: "public", 1: "friends", 2: "private", 3: "unlisted"}
UA = {"User-Agent": "Mozilla/5.0 modstats"}
MAX_EVENTS = 2000


def path(name):
    return os.path.join(DATA_DIR, name)


def load(name, default):
    try:
        with open(path(name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(name, data):
    tmp = path(name) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, path(name))


def api_key():
    key = os.environ.get("STEAM_API_KEY")
    if not key:
        raise SystemExit("set STEAM_API_KEY in the environment or in modstats/.env")
    return key


def get_json(url, params):
    with urllib.request.urlopen(url + "?" + urllib.parse.urlencode(params), timeout=60) as r:
        return json.load(r)


def local_mods():
    """Workshop id -> {folder, mod_ids} for every uploaded mod folder in the Workshop directory.

    The result is cached in mods.json, which is what gets used when the folder is not there.
    """
    mods = {}
    for folder in sorted(os.listdir(WORKSHOP)) if os.path.isdir(WORKSHOP) else []:
        wtxt = os.path.join(WORKSHOP, folder, "workshop.txt")
        if not os.path.isfile(wtxt):
            continue
        m = re.search(r"^id=(\d+)", open(wtxt, errors="replace").read(), re.M)
        if not m:
            continue
        ids = set()
        for root, _, files in os.walk(os.path.join(WORKSHOP, folder, "Contents", "mods")):
            if "mod.info" in files:
                mi = re.search(r"^id=(.+)$", open(os.path.join(root, "mod.info"), errors="replace").read(), re.M)
                if mi:
                    ids.add(mi.group(1).strip())
        mods[m.group(1)] = {"folder": folder, "mod_ids": sorted(ids)}
    if not mods:
        return load("mods.json", {})
    save("mods.json", mods)
    return mods


def fetch_details(key, ids):
    q = {"key": key, "includevotes": "true", "includetags": "true", "short_description": "true"}
    for i, fid in enumerate(ids):
        q[f"publishedfileids[{i}]"] = fid
    files = get_json(API + "IPublishedFileService/GetDetails/v1/", q)["response"]["publishedfiledetails"]
    return [f for f in files if f.get("result") == 1]


def fetch_owner(key, steamid):
    try:
        p = get_json(API + "ISteamUser/GetPlayerSummaries/v2/", {"key": key, "steamids": steamid})["response"]["players"][0]
        return {"id": steamid, "name": p.get("personaname", ""), "url": p.get("profileurl", "")}
    except Exception:
        return {"id": steamid, "name": "", "url": ""}


def fetch_comments(owner, fid):
    out, start = [], 0
    while True:
        body = urllib.parse.urlencode({"start": start, "count": 100}).encode()
        req = urllib.request.Request(COMMENTS.format(owner=owner, fid=fid), data=body, headers=UA)
        with urllib.request.urlopen(req, timeout=60) as r:
            page = json.load(r)
        if not page.get("success"):
            break
        chunks = re.split(r'class="commentthread_comment [^"]*"\s+id="comment_(\d+)"', page.get("comments_html", ""))
        for cid, chunk in zip(chunks[1::2], chunks[2::2]):
            author = re.search(r'commentthread_author_link"[^>]*href="([^"]*)"[^>]*>\s*<bdi>(.*?)</bdi>', chunk, re.S)
            ts = re.search(r'data-timestamp="(\d+)"', chunk)
            text = re.search(r'id="comment_content_%s"[^>]*>(.*?)</div>' % cid, chunk, re.S)
            body_txt = re.sub(r"<br\s*/?>", "\n", text.group(1) if text else "")
            body_txt = html.unescape(re.sub(r"<[^>]+>", "", body_txt)).strip()
            out.append({
                "id": cid,
                "author": html.unescape(author.group(2)).strip() if author else "?",
                "author_url": author.group(1) if author else "",
                "ts": int(ts.group(1)) if ts else 0,
                "text": body_txt,
            })
        start += 100
        if start >= int(page.get("total_count", 0)) or len(chunks) < 3:
            break
        time.sleep(0.5)
    return out


def thumb(fid, url, stamp):
    """Small JPEG data URI of the Workshop preview image, cached until the image changes."""
    os.makedirs(path("thumbs"), exist_ok=True)
    out = path(f"thumbs/{fid}_{stamp}.jpg")
    try:
        if not os.path.exists(out):
            src = path(f"thumbs/{fid}.src")
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r, open(src, "wb") as f:
                f.write(r.read())
            try:  # Pillow in the container, sips when run by hand on a Mac
                from PIL import Image
                im = Image.open(src).convert("RGB")
                im.thumbnail((160, 160))
                im.save(out, "JPEG", quality=70)
            except ImportError:
                subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "70", "-Z", "160", src, "--out", out],
                               check=True, capture_output=True)
            os.remove(src)
        return "data:image/jpeg;base64," + base64.b64encode(open(out, "rb").read()).decode()
    except Exception as e:
        print(f"thumb {fid}: {e}", file=sys.stderr)
        return ""


def collect():
    key = api_key()
    local = local_mods()
    details = fetch_details(key, list(local))
    now = int(time.time())
    today = datetime.date.today().isoformat()

    state = load("state.json", {})
    events = load("events.json", [])
    comments = load("comments.json", {})
    seen = {e["key"] for e in events}
    owner = fetch_owner(key, details[0]["creator"]) if details else {"id": "", "name": "", "url": ""}
    owner_names = set(load("owner.json", {}).get("names", [])) | ({owner["name"]} if owner["name"] else set())

    def emit(key_, ts, mod, kind, **extra):
        if key_ in seen:
            return False
        seen.add(key_)
        events.append({"key": key_, "ts": ts, "mod": mod, "kind": kind, **extra})
        return True

    new_comments = []

    meta, snap = {}, {}
    for f in details:
        fid = f["publishedfileid"]
        votes = f.get("vote_data", {})
        vis = VISIBILITY.get(f.get("visibility"), "?")
        created, updated = f.get("time_created", 0), f.get("time_updated", 0)
        meta[fid] = {
            "title": f.get("title", fid),
            "folder": local[fid]["folder"],
            "mod_ids": local[fid]["mod_ids"],
            "visibility": vis,
            "created": created,
            "updated": updated,
            "tags": [t.get("display_name", t.get("tag")) for t in f.get("tags", [])],
            "desc": f.get("short_description", ""),
            "size": int(f.get("file_size", 0) or 0),
            "thumb": thumb(fid, f["preview_url"], f.get("hcontent_preview", "0")) if f.get("preview_url") else "",
        }
        s = snap[fid] = {
            "subs": f.get("subscriptions", 0),
            "life_subs": f.get("lifetime_subscriptions", 0),
            "favs": f.get("favorited", 0),
            "life_favs": f.get("lifetime_favorited", 0),
            "views": f.get("views", 0),
            "up": votes.get("votes_up", 0),
            "down": votes.get("votes_down", 0),
            "comments": f.get("num_comments_public", 0),
        }

        old = state.get(fid)
        if old is None:
            emit(f"pub:{fid}", created, fid, "published")
            if updated - created > 3600:
                emit(f"upd:{fid}:{updated}", updated, fid, "update")
        else:
            for k in ("subs", "favs", "views"):
                d = s[k] - old.get(k, 0)
                if d:
                    emit(f"{k}:{fid}:{now}", now, fid, k, delta=d, value=s[k])
            du, dd = s["up"] - old.get("up", 0), s["down"] - old.get("down", 0)
            if du or dd:
                emit(f"votes:{fid}:{now}", now, fid, "votes", up=du, down=dd, value=[s["up"], s["down"]])
            if updated != old.get("updated"):
                emit(f"upd:{fid}:{updated}", updated, fid, "update")
            if vis != old.get("visibility"):
                emit(f"vis:{fid}:{now}", now, fid, "visibility", value=vis, was=old.get("visibility"))
        state[fid] = {**s, "updated": updated, "visibility": vis}

        try:
            known = {c["id"]: c for c in comments.get(fid, [])}
            for c in fetch_comments(f["creator"], fid):
                c["own"] = c["author_url"].rstrip("/").endswith(str(f["creator"])) or c["author"] in owner_names
                known[c["id"]] = c
                if emit(f"c:{c['id']}", c["ts"], fid, "comment", author=c["author"], text=c["text"][:280], own=c["own"]):
                    new_comments.append((fid, c))
            comments[fid] = sorted(known.values(), key=lambda c: -c["ts"])
        except Exception as e:  # stats still get recorded when the comment page is unreachable
            print(f"comments {fid}: {e}", file=sys.stderr)

    history = [h for h in load("history.json", []) if h["date"] != today]
    history.append({"date": today, "ts": now, "mods": snap})
    history.sort(key=lambda h: h["date"])
    events = sorted(events, key=lambda e: -e["ts"])[:MAX_EVENTS]
    save("history.json", history)
    save("state.json", state)
    save("events.json", events)
    save("comments.json", comments)

    data = {"generated": now, "owner": owner, "meta": meta, "history": history, "comments": comments,
            "events": events[:600], "scan": load("scan.json", None), "server": load("server.json", None),
            "discord": load("discord_report.json", None)}
    import alerts  # imported here because alerts.py itself imports this module
    alerts.check_comments(new_comments, meta)
    data["alerts"] = alerts.recent()
    save("data.json", data)
    return data


if __name__ == "__main__":
    d = collect()
    print(f"{datetime.date.today()}: {len(d['meta'])} mods, {sum(len(v) for v in d['comments'].values())} comments, "
          f"{len(d['history'])} day(s) of history, {len(d['events'])} events")
