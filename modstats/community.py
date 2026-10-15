#!/usr/bin/env python3
"""Community monitor: reads your Discord server through a bot and summarises it for the dashboard.

Off until DISCORD_BOT_TOKEN is set (environment or ./.env). The bot needs View Channels and
Read Message History in the server, plus the Message Content and Server Members intents.
DISCORD_GUILD is optional: without it the server is taken from the alerts webhook.

Files written to the data directory:
  discord.json          messages seen so far (newest 3000), read positions, member list, daily counts
  discord_report.json   the summary the page shows
"""
import datetime, json, os, sys, time, urllib.error, urllib.request

import alerts
import collect

TOKEN = os.environ.get("DISCORD_BOT_TOKEN", "")
GUILD = os.environ.get("DISCORD_GUILD", "")
API = "https://discord.com/api/v10"
UA = "DiscordBot (https://theblb.zapto.org/lilPZmods, 1.0)"
KEEP = 3000
TEXT_CHANNELS = (0, 5, 11, 12)  # text, announcement, public and private threads
SYSTEM_JOIN = 7


class Forbidden(Exception):
    pass


def api(path_):
    for _ in range(4):
        req = urllib.request.Request(API + path_, headers={"Authorization": f"Bot {TOKEN}", "User-Agent": UA})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code == 429:
                try:
                    time.sleep(min(15, float(json.load(e).get("retry_after", 2))))
                except Exception:
                    time.sleep(2)
                continue
            if e.code in (403, 404):
                raise Forbidden(path_)
            raise
    raise RuntimeError("Discord kept rate limiting " + path_)


def webhook_target():
    """Server and channel the alerts webhook posts to; that channel is left out of the stats."""
    if not alerts.WEBHOOK:
        return "", ""
    try:
        req = urllib.request.Request(alerts.WEBHOOK, headers={"User-Agent": UA})
        with urllib.request.urlopen(req, timeout=20) as r:
            d = json.load(r)
        return d.get("guild_id", ""), d.get("channel_id", "")
    except Exception:
        return "", ""


def stamp(iso):
    return int(datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()) if iso else 0


def display(user, member=None):
    return (member or {}).get("nick") or user.get("global_name") or user.get("username") or "?"


def collect_discord():
    if not TOKEN:
        return {"available": False}
    st = collect.load("discord.json", None) or {"messages": [], "cursor": {}, "members": None, "history": [], "guild": "", "skip": ""}
    if not st.get("guild"):
        st["guild"], st["skip"] = webhook_target()
    gid = GUILD or st["guild"]
    if not gid:
        return {"available": False, "error": "no server: set DISCORD_GUILD"}

    guild = api(f"/guilds/{gid}?with_counts=true")
    owner = guild.get("owner_id", "")
    channels = [c for c in api(f"/guilds/{gid}/channels") if c["type"] in TEXT_CHANNELS]
    try:
        channels += [t for t in api(f"/guilds/{gid}/threads/active").get("threads", []) if t["type"] in TEXT_CHANNELS]
    except Forbidden:
        pass
    channels = [c for c in channels if c["id"] != st.get("skip")]
    names = {c["id"]: c["name"] for c in channels}

    members = {}
    try:
        for m in api(f"/guilds/{gid}/members?limit=1000"):
            u = m["user"]
            members[u["id"]] = {"name": display(u, m), "bot": bool(u.get("bot")), "joined": stamp(m.get("joined_at"))}
    except Forbidden:
        pass
    if st["members"] is not None:  # the first run only records who is already there
        for uid, m in members.items():
            if uid not in st["members"] and not m["bot"]:
                alerts.raise_alert(f"member:{uid}", "member", f"{m['name']} joined your Discord",
                                   f"The server now has {guild.get('approximate_member_count', len(members))} members.", ts=m["joined"] or None, tab="community")
    st["members"] = members

    known = {m["id"] for m in st["messages"]}
    for c in channels:
        after = st["cursor"].get(c["id"])
        try:
            for _ in range(10):  # at most 1000 messages per channel per run
                page = api(f"/channels/{c['id']}/messages?limit=100" + (f"&after={after}" if after else ""))
                for m in page:
                    if m["id"] in known:
                        continue
                    known.add(m["id"])
                    a = m.get("author", {})
                    embed = (m.get("embeds") or [{}])[0]
                    st["messages"].append({
                        "id": m["id"], "ch": c["id"], "uid": a.get("id", ""), "author": display(a, m.get("member")),
                        "bot": bool(a.get("bot") or m.get("webhook_id")), "ts": stamp(m.get("timestamp")), "type": m.get("type", 0),
                        "text": (m.get("content") or embed.get("title") or embed.get("description") or "")[:600],
                        "files": len(m.get("attachments") or []), "reply": bool(m.get("referenced_message")),
                    })
                if page:
                    after = max(page, key=lambda m: int(m["id"]))["id"]
                if len(page) < 100 or not st["cursor"].get(c["id"]):
                    break  # caught up; a channel seen for the first time only takes its latest 100
            if after:
                st["cursor"][c["id"]] = after
        except Forbidden:
            continue  # a channel the bot cannot read
    st["messages"] = sorted(st["messages"], key=lambda m: -m["ts"])[:KEEP]
    msgs = [m for m in st["messages"] if m["ch"] in names]
    people_msgs = [m for m in msgs if not m["bot"] and m["type"] != SYSTEM_JOIN]

    # Waiting on you: what members wrote in a channel after your latest message there.
    waiting, answered = set(), set()
    for m in people_msgs:  # newest first
        if m["uid"] == owner:
            answered.add(m["ch"])
        elif m["ch"] not in answered:
            waiting.add(m["id"])

    now = int(time.time())
    week = now - 7 * 86400
    today = datetime.date.today().isoformat()
    day_start = int(datetime.datetime.combine(datetime.date.today(), datetime.time()).timestamp())
    st["history"] = [h for h in st["history"] if h["date"] != today] + [{
        "date": today, "members": guild.get("approximate_member_count", len(members)), "online": guild.get("approximate_presence_count", 0),
        "messages": sum(1 for m in people_msgs if m["ts"] >= day_start), "writers": len({m["uid"] for m in people_msgs if m["ts"] >= day_start})}]
    collect.save("discord.json", st)

    people = {}
    for m in people_msgs:
        p = people.setdefault(m["uid"], {"id": m["uid"], "name": m["author"], "messages": 0, "week": 0, "last": 0})
        p["messages"] += 1
        p["week"] += m["ts"] >= week
        p["last"] = max(p["last"], m["ts"])
    for uid, mem in members.items():
        if not mem["bot"]:
            people.setdefault(uid, {"id": uid, "name": mem["name"], "messages": 0, "week": 0, "last": 0})
    for uid, p in people.items():
        p["joined"] = members.get(uid, {}).get("joined", 0)
        p["you"] = uid == owner
        p["here"] = uid in members if members else True

    rep = {"available": True, "checked": now, "guild": gid, "name": guild.get("name", ""),
           "members": guild.get("approximate_member_count", len(members)), "online": guild.get("approximate_presence_count", 0),
           "humans": sum(1 for m in members.values() if not m["bot"]) if members else None,
           "week_messages": sum(1 for m in people_msgs if m["ts"] >= week), "week_writers": len({m["uid"] for m in people_msgs if m["ts"] >= week}),
           "waiting": len(waiting), "history": st["history"][-120:],
           "channels": sorted(({"id": cid, "name": n, "week": sum(1 for m in people_msgs if m["ch"] == cid and m["ts"] >= week),
                                "total": sum(1 for m in people_msgs if m["ch"] == cid),
                                "last": max((m["ts"] for m in people_msgs if m["ch"] == cid), default=0),
                                "waiting": sum(1 for m in people_msgs if m["ch"] == cid and m["id"] in waiting)} for cid, n in names.items()),
                              key=lambda c: -c["last"]),
           "people": sorted(people.values(), key=lambda p: (-p["week"], -p["messages"], -p["last"])),
           "messages": [{**m, "channel": names[m["ch"]], "you": m["uid"] == owner, "waiting": m["id"] in waiting} for m in people_msgs[:300]]}
    collect.save("discord_report.json", rep)
    return rep


if __name__ == "__main__":
    r = collect_discord()
    if not r.get("available"):
        sys.exit("Discord monitoring is off: " + r.get("error", "set DISCORD_BOT_TOKEN in .env"))
    # Counts only: this never prints names or message text.
    print(f"{r['name']}: {r['members']} members, {r['online']} online, {len(r['channels'])} channels read, "
          f"{r['week_messages']} messages this week from {r['week_writers']} people, {r['waiting']} waiting on you")
