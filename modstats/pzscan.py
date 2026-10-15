#!/usr/bin/env python3
"""Scan public Project Zomboid servers for your mods (Steam Web API server list + A2S rules).

Usage: python3 pzscan.py   (the dashboard's "Scan servers now" button runs this)
Mods and the Steam key come from collect.py. Results go to scan.json in the data
directory, which the dashboard's Servers tab reads.

Limits worth knowing: the API returns at most 10,000 servers per query, and most servers
only advertise the first ~127 characters of their mod list, so a miss proves nothing.
"""
import bz2, json, os, re, socket, struct, sys, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

import alerts
import collect

APPID = 108600
API = "https://api.steampowered.com/IGameServersService/GetServerList/v1/"


def master_list(key):
    base = f"\\appid\\{APPID}"
    # The API caps each response, so union a few overlapping slices.
    filters = [base, base + "\\empty\\1", base + "\\noplayers\\1", base + "\\dedicated\\1"]
    seen = {}
    for f in filters:
        q = urllib.parse.urlencode({"key": key, "filter": f, "limit": 20000})
        try:
            with urllib.request.urlopen(f"{API}?{q}", timeout=60) as r:
                servers = json.load(r).get("response", {}).get("servers", [])
        except Exception as e:
            print(f"list {f}: {e}", file=sys.stderr)
            continue
        for s in servers:
            ip, _, port = s["addr"].rpartition(":")
            seen[(ip, int(port))] = True
        print(f"list {f}: {len(servers)} (total {len(seen)})", file=sys.stderr)
    return list(seen)


def a2s(addr, payload, timeout=3.0):
    """Send an A2S request, handle the challenge dance and split packets."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        req = payload
        for _ in range(3):
            s.sendto(b"\xff\xff\xff\xff" + req, addr)
            data = recv_all(s)
            if data[:1] == b"\x41":  # challenge
                chal = data[1:5]
                req = (payload[:-4] + chal) if payload[:1] == b"\x56" else payload + chal
                continue
            return data
    finally:
        s.close()
    return b""


def recv_all(s):
    data, _ = s.recvfrom(65535)
    if data[:4] == b"\xff\xff\xff\xff":
        return data[4:]
    if data[:4] != b"\xfe\xff\xff\xff":
        return b""
    parts, compressed = {}, False
    while True:
        pid, total, num = struct.unpack("<lBB", data[4:10])
        compressed = bool(pid & 0x80000000)
        off = 12  # header + 2 byte max packet size
        if compressed and num == 0:
            off += 8
        parts[num] = data[off:]
        if len(parts) >= total:
            break
        data, _ = s.recvfrom(65535)
    blob = b"".join(parts[i] for i in sorted(parts))
    if compressed:
        blob = bz2.decompress(blob)
    return blob[4:] if blob[:4] == b"\xff\xff\xff\xff" else blob


def cstr(b, i):
    j = b.index(b"\x00", i)
    return b[i:j].decode("utf-8", "replace"), j + 1


def probe(addr):
    out = {"ip": addr[0], "qport": addr[1]}
    try:
        info = a2s(addr, b"\x54Source Engine Query\x00")
        if info[:1] == b"\x49":
            i = 2
            out["name"], i = cstr(info, i)
            out["map"], i = cstr(info, i)
            _, i = cstr(info, i)
            _, i = cstr(info, i)
            i += 2
            out["players"], out["max"] = info[i], info[i + 1]
    except Exception:
        pass
    try:
        r = a2s(addr, b"\x56\xff\xff\xff\xff")
        if r[:1] == b"\x45":
            n = struct.unpack("<H", r[1:3])[0]
            i, rules = 3, {}
            for _ in range(n):
                try:
                    k, i = cstr(r, i)
                    v, i = cstr(r, i)
                except ValueError:
                    break
                rules[k] = v
            out["rules"] = rules
    except Exception as e:
        out["err"] = type(e).__name__
    return out


def advertised_mods(rules):
    """Mod IDs a server advertises. Long lists arrive as mods:1/3, mods:2/3, ... chunks."""
    chunks = sorted((int(k.split(":")[1].split("/")[0]), v) for k, v in rules.items() if re.match(r"mods:\d+/\d+$", k))
    raw = rules.get("mods", "") + "".join(v for _, v in chunks)
    return {t for t in re.split(r"[;,\s\\]+", raw) if t}


def main():
    key = collect.api_key()
    mine = collect.local_mods()  # workshop id -> {folder, mod_ids}
    servers = master_list(key)
    print(f"probing {len(servers)} servers", file=sys.stderr)
    with ThreadPoolExecutor(128) as ex:
        results = list(ex.map(probe, servers))
    answered = [r for r in results if r.get("rules")]
    print(f"{len(answered)}/{len(servers)} returned rules", file=sys.stderr)

    hits, partial = [], 0
    for r in answered:
        mods = advertised_mods(r["rules"])
        count = int(r["rules"].get("modCount", "0") or 0)
        if count > len(mods):
            partial += 1
        found = [wid for wid, m in mine.items() if any(mid in mods for mid in m["mod_ids"])]
        if found:
            hits.append({"name": r.get("name", "?"), "ip": r["ip"], "qport": r["qport"], "players": r.get("players"),
                         "max": r.get("max"), "mod_count": count, "shown": len(mods), "mods": found,
                         "description": r["rules"].get("description", "")})
    hits.sort(key=lambda h: -(h.get("players") or 0))
    data = collect.load("data.json", None) or {}
    meta = {wid: {**mine[wid], **data.get("meta", {}).get(wid, {})} for wid in mine}
    new = alerts.check_servers(hits, meta, (data.get("owner") or {}).get("name", ""))
    collect.save("scan.json", {"scanned_at": int(time.time()), "listed": len(servers), "answered": len(answered),
                               "partial": partial, "hits": hits})
    for h in hits:
        print(f"{h['name']} | {h['ip']}:{h['qport']} | {h.get('players')}/{h.get('max')} | "
              f"{', '.join(mine[w]['folder'] for w in h['mods'])}")
    print(f"\n{len(hits)} servers matched, {new} new; {partial} of {len(answered)} servers advertise only part of their mod list")


if __name__ == "__main__":
    main()
