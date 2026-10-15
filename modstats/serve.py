#!/usr/bin/env python3
"""The dashboard server. In Docker: docker compose up -d. By hand: python3 serve.py

It re-reads Steam every 30 minutes, so the Activity tab and trend lines fill in on their own.

Settings (environment or ./.env):
  STEAM_API_KEY   required, your Steam Web API key
  DASH_KEY        sign-in key for the page. When empty the page is open to anyone who can
                  reach it, but the Refresh and Scan buttons are switched off.
  BASE_PATH       URL prefix the reverse proxy forwards, default /lilPZmods
  MODSTATS_HOST / MODSTATS_PORT   bind address, default 127.0.0.1:8642
"""
import hmac, json, os, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import alerts
import collect
import community
import livefeed
import server

HOST = os.environ.get("MODSTATS_HOST", "127.0.0.1")
PORT = int(os.environ.get("MODSTATS_PORT", 8642))
BASE = "/" + os.environ.get("BASE_PATH", "/lilPZmods").strip("/")
DASH_KEY = os.environ.get("DASH_KEY", "")
EVERY = 30 * 60
SERVER_EVERY = 2 * 60
FEED_EVERY = 15
SCAN_EVERY = float(os.environ.get("SCAN_EVERY_HOURS", 24)) * 3600  # 0 switches the automatic scan off
MIN_REFRESH, MIN_SCAN = 60, 30 * 60
lock = threading.Lock()
status = {"scanning": False, "scan_error": "", "refresh_error": "", "can_write": bool(DASH_KEY)}
last = {"refresh": 0.0, "scan": 0.0}


def refresh():
    with lock:
        if time.time() - last["refresh"] < MIN_REFRESH:
            return
        last["refresh"] = time.time()
        try:
            collect.collect()
            status["refresh_error"] = ""
        except BaseException as e:  # collect raises SystemExit when the key is missing
            status["refresh_error"] = str(e) or type(e).__name__
            print("refresh failed:", status["refresh_error"], file=sys.stderr, flush=True)


def scan():
    """Ask every public server which mods it runs. pzscan.py raises the alerts for new ones."""
    try:
        r = subprocess.run([sys.executable, os.path.join(collect.HERE, "pzscan.py")], capture_output=True, text=True, timeout=1500)
        status["scan_error"] = "" if r.returncode == 0 else (r.stderr.strip().splitlines() or ["scan failed"])[-1]
        patch_alerts()
    except Exception as e:
        status["scan_error"] = str(e)
    finally:
        status["scanning"] = False


def timer():
    while True:
        refresh()
        time.sleep(EVERY)


def patch_alerts():
    with lock:
        data = collect.load("data.json", None)
        if data:
            data["alerts"], data["scan"] = alerts.recent(), collect.load("scan.json", None)
            collect.save("data.json", data)


def feed_timer():
    """Post visitor joins, tests and outcomes to Discord within a few seconds of them happening."""
    while True:
        try:
            livefeed.tick()
        except Exception as e:
            livefeed.status["error"] = str(e)
            print("live feed failed:", e, file=sys.stderr, flush=True)
        status["feed"] = livefeed.status
        time.sleep(FEED_EVERY)


def server_timer():
    """Re-read the test server's logs. server.report() itself holds off while the owner is connected."""
    while True:
        try:
            rep = server.report()
            with lock:
                data = collect.load("data.json", None)
                if data:
                    data["server"] = rep
                    collect.save("data.json", data)
            alerts.check_visitors(rep)
            try:
                disc = community.collect_discord()
                with lock:
                    data = collect.load("data.json", None)
                    if data:
                        data["discord"] = disc
                        collect.save("data.json", data)
            except Exception as e:
                print("discord check failed:", e, file=sys.stderr, flush=True)
            alerts.retry_unsent()
            patch_alerts()
            due = SCAN_EVERY and time.time() - ((collect.load("scan.json", None) or {}).get("scanned_at", 0)) > SCAN_EVERY
            if due and not status["scanning"] and time.time() - last["scan"] > MIN_SCAN:
                status["scanning"], last["scan"] = True, time.time()
                threading.Thread(target=scan, daemon=True).start()
        except Exception as e:
            print("server report failed:", e, file=sys.stderr, flush=True)
        time.sleep(SERVER_EVERY)


def shell():
    """The page without any data in it; the browser fetches data from the API after sign-in."""
    return open(os.path.join(collect.HERE, "dashboard.template.html")).read()


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="text/plain", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Robots-Tag", "noindex")
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def route(self):
        p = self.path.split("?")[0]
        if p == BASE or p.startswith(BASE + "/"):  # the proxy may or may not strip the prefix
            p = p[len(BASE):] or "/"
        return p

    def allowed(self):
        if not DASH_KEY:
            return True
        given = self.headers.get("X-Dash-Key", "")
        if hmac.compare_digest(given.encode(), DASH_KEY.encode()):
            return True
        if given:
            time.sleep(1)  # slows down guessing
        self.send(401, b'{"error":"key"}', "application/json")
        return False

    def data(self):
        d = collect.load("data.json", None) or {}
        self.send(200, json.dumps({**d, "status": status}).encode(), "application/json")

    def do_GET(self):
        p = self.route()
        if p in ("/", "/index.html"):
            if self.path.split("?")[0] == BASE:  # relative links need the trailing slash
                return self.send(308, b"", headers=[("Location", BASE + "/")])
            page = ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="robots" content="noindex">'
                    '<meta name="viewport" content="width=device-width,initial-scale=1"></head><body>' + shell() + "</body></html>")
            self.send(200, page.encode(), "text/html; charset=utf-8")
        elif p == "/healthz":
            self.send(200, b"ok")
        elif p == "/api/data":
            if self.allowed():
                self.data()
        else:
            self.send(404, b"not found")

    def do_POST(self):
        p = self.route()
        if p not in ("/api/refresh", "/api/scan"):
            return self.send(404, b"not found")
        if not DASH_KEY:  # no sign-in key means no way to tell the owner from a stranger
            return self.send(403, b'{"error":"read only"}', "application/json")
        if not self.allowed():
            return
        if p == "/api/refresh":
            refresh()
        elif not status["scanning"] and time.time() - last["scan"] > MIN_SCAN:
            status["scanning"], last["scan"] = True, time.time()
            threading.Thread(target=scan, daemon=True).start()
        self.data()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=timer, daemon=True).start()
    threading.Thread(target=server_timer, daemon=True).start()
    threading.Thread(target=feed_timer, daemon=True).start()
    print(f"Workshop dashboard on http://{HOST}:{PORT}{BASE}/  sign-in key {'set' if DASH_KEY else 'NOT set (read only)'}", flush=True)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
