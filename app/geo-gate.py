#!/usr/bin/env python3
"""
geo-gate — a SOCKS5 gate that only allows traffic while the Tuxler exit IP
geolocates to the US.

Chain:  browser -> geo-gate (127.0.0.1:23322, SOCKS5) -> Tuxler (127.0.0.1:23321, SOCKS5) -> phone -> internet

Every CHECK_INTERVAL seconds the gate opens a FRESH connection through Tuxler
to https://ip-api.com/json/?fields=status,country,countryCode,city,isp,proxy and
records the country. If the exit is not US, the gate HARD-DROPS everything:
all live client flows get an immediate RST and new connections are refused
until the exit is US again.

The gate never talks to the internet itself for traffic — every byte a client
sends goes through Tuxler, so no leak path exists.
"""

import json
import os
import select
import signal
import socket
import ssl
import struct
import sys
import threading
import time
from datetime import datetime, timezone

# ---------------- config ----------------
GATE_HOST = os.environ.get("GATE_HOST", "127.0.0.1")
GATE_PORT = int(os.environ.get("GATE_PORT", "23322"))
TUXLER_HOST = os.environ.get("TUXLER_HOST", "127.0.0.1")
TUXLER_PORT = int(os.environ.get("TUXLER_PORT", "23321"))
CHECK_INTERVAL = float(os.environ.get("CHECK_INTERVAL", "3"))
ALLOWED_COUNTRY = os.environ.get("ALLOWED_COUNTRY", "US")
# ip-api.com free tier is HTTP-only (HTTPS => 403). ipwho.is is the HTTPS fallback.
GEO_ENDPOINTS = [
    ("http",  os.environ.get("GEO_HOST", "ip-api.com"), 80,
     os.environ.get("GEO_PATH", "/json/?fields=status,message,country,countryCode,city,isp,proxy,query")),
    ("https", "ipwho.is", 443, "/"),
    ("https", "ipapi.co", 443, "/json/"),
]
# Cheap "what is my IP" probes — used to detect rotation without spending a
# full geo lookup. If the IP is unchanged we reuse the cached verdict.
IP_ENDPOINTS = [
    ("https", "api.ipify.org", 443, "/"),
    ("http",  "ip-api.com", 80, "/json/?fields=query"),
]
GEO_TIMEOUT = float(os.environ.get("GEO_TIMEOUT", "8"))
# only re-ask the geo API when the exit IP changes; this is the rate-limit fix
GEO_CACHE_MAX = int(os.environ.get("GEO_CACHE_MAX", "64"))
STATE_LOG = os.environ.get("STATE_LOG", "/var/log/tuxler/geo-gate.log")
FAIL_CLOSED_AFTER = int(os.environ.get("FAIL_CLOSED_AFTER", "3"))
STATE_FILE = os.environ.get("GATE_STATE_FILE", "/var/log/tuxler/geo-gate.state")
# create this file to force an immediate re-check (and, if non-US, a hard drop)
RECHECK_TRIGGER = os.environ.get("GATE_RECHECK_TRIGGER", "/tmp/geo-gate.recheck")
# create this file to force the gate CLOSED regardless of geo (panic switch)
PANIC_FILE = os.environ.get("GATE_PANIC_FILE", "/tmp/geo-gate.panic")

# ---------------- shared state ----------------
class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.allow = False          # gate verdict (fail-closed until first check)
        self.reason = "startup: not yet verified"
        self.ip = None
        self.country = None
        self.country_code = None
        self.city = None
        self.isp = None
        self.checked_at = None
        self.fail_streak = 0
        # live client connections: conn-id -> (client_sock, upstream_sock)
        self.conns = {}
        # ip -> ("allow"/"deny", geo-dict, timestamp); one geo lookup per IP
        self.geo_cache = {}
        self.cache_hits = 0
        self.cache_misses = 0
        # True once the current exit has had a real (non-failure) verdict
        self.verified = False

state = State()
_stop = threading.Event()


def log(msg):
    line = "[%s] %s" % (datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S"), msg)
    print(line, flush=True)
    try:
        with open(STATE_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def write_state_file():
    try:
        with open(STATE_FILE + ".tmp", "w") as f:
            json.dump({
                "allow": state.allow,
                "reason": state.reason,
                "exit_ip": state.ip,
                "country": state.country,
                "country_code": state.country_code,
                "city": state.city,
                "isp": state.isp,
                "checked_at": state.checked_at,
                "fail_streak": state.fail_streak,
                "conns": len(state.conns),
                "cache_hits": state.cache_hits,
                "cache_misses": state.cache_misses,
                "cached_ips": len(state.geo_cache),
            }, f)
        os.replace(STATE_FILE + ".tmp", STATE_FILE)
    except OSError:
        pass


# ---------------- SOCKS5 helpers ----------------
def socks5_open(host, port, dst_host, dst_port):
    """Open a connection to host:port and run a SOCKS5 CONNECT to dst_host:dst_port.
    Returns the connected socket, or raises OSError."""
    s = socket.create_connection((host, port), timeout=GEO_TIMEOUT)
    s.settimeout(GEO_TIMEOUT)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)

    s.sendall(b"\x05\x01\x00")
    rep = _recv_exact(s, 2)
    if len(rep) != 2 or rep[0] != 5 or rep[1] != 0:
        raise OSError("socks5 greeting rejected: %r" % (rep,))

    try:
        ip = socket.inet_aton(dst_host)
        req = b"\x05\x01\x00\x01" + ip + struct.pack("!H", dst_port)
    except OSError:
        hb = dst_host.encode("idna") if isinstance(dst_host, str) else dst_host
        if len(hb) > 255:
            raise OSError("hostname too long")
        req = b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + struct.pack("!H", dst_port)

    s.sendall(req)
    head = _recv_exact(s, 4)
    if len(head) != 4 or head[0] != 5:
        raise OSError("socks5 reply malformed: %r" % (head,))
    if head[1] != 0:
        raise OSError("socks5 connect failed, REP=%d" % head[1])
    atyp = head[3]
    if atyp == 1:
        _recv_exact(s, 4 + 2)
    elif atyp == 4:
        _recv_exact(s, 16 + 2)
    elif atyp == 3:
        n = _recv_exact(s, 1)[0]
        _recv_exact(s, n + 2)
    else:
        raise OSError("socks5 bad ATYP %d" % atyp)
    s.settimeout(None)
    return s


def _recv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


# ---------------- verdict publisher ----------------
def drop_all(reason):
    """HARD DROP: RST every live client flow immediately."""
    with state.lock:
        victims = list(state.conns.items())
        state.conns.clear()
    for cid, (csock, usock) in victims:
        for s in (csock, usock):
            try:
                # SO_LINGER with timeout 0 => close() sends RST, not FIN
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                             struct.pack("ii", 1, 0))
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass
    if victims:
        log("HARD-DROP: reset %d live connection(s) — %s" % (len(victims), reason))


def set_verdict(allow, reason, geo=None, failures=False):
    prev = state.allow
    with state.lock:
        state.allow = allow
        state.reason = reason
        if geo:
            state.ip = geo.get("query") or state.ip
            state.country = geo.get("country")
            state.country_code = geo.get("countryCode")
            state.city = geo.get("city")
            state.isp = geo.get("isp")
            state.checked_at = datetime.now(timezone.utc).isoformat(timespec="seconds")
        if not failures:
            # a real (cache or fresh) verdict means the current exit is verified
            state.verified = True
    write_state_file()
    if prev and not allow:
        log("GATE CLOSING (%s): exit=%s %s / %s" % (
            reason, state.ip, state.country_code, state.isp))
        drop_all(reason)
    elif allow and not prev:
        log("GATE OPEN (%s): exit=%s %s %s / %s" % (
            reason, state.ip, state.country_code, state.city, state.isp))


# ---------------- checker thread ----------------
def fetch_via_tuxler(scheme, host, port, path):
    """One HTTP(S) request through a fresh Tuxler SOCKS5 connection.
    Returns the parsed JSON body. Raises OSError on any failure."""
    s = socks5_open(TUXLER_HOST, TUXLER_PORT, host, port)
    try:
        if scheme == "https":
            ctx = ssl.create_default_context()
            ctx.check_hostname = True
            ctx.verify_mode = ssl.CERT_REQUIRED
            s = ctx.wrap_socket(s, server_hostname=host)
        s.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\n"
                   "Accept: application/json\r\n"
                   "User-Agent: geo-gate/1.0\r\n"
                   "Connection: close\r\n\r\n" % (path, host)).encode())
        raw = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            raw += chunk
            if len(raw) > 65536:
                break
    finally:
        try:
            s.close()
        except OSError:
            pass
    head, _, body = raw.partition(b"\r\n\r\n")
    line = head.split(b"\r\n", 1)[0] if head else b""
    if b"200" not in line:
        raise OSError("%s %s status: %r" % (scheme, host, line))
    return json.loads(body.decode("utf-8", "replace"))


def geo_from_ip_response(data):
    """Normalise ipwho.is / ipapi.co / ip-api field names into ip-api's shape."""
    if "country_code" in data and "countryCode" not in data:
        data["countryCode"] = data.get("country_code")
    if "success" in data and "status" not in data:
        data["status"] = "success" if data.get("success") else "fail"
    conn = data.get("connection")
    if isinstance(conn, dict):
        data.setdefault("isp", conn.get("isp") or conn.get("org"))
    for k in ("ip", "query"):
        v = data.get(k)
        if isinstance(v, str) and v:
            data["query"] = v
            break
    return data


def probe_exit_ip():
    """Cheap 'what is my IP' probe through Tuxler. No geo lookup, so it does
    not consume the geo API's rate limit."""
    last_err = None
    for scheme, host, port, path in IP_ENDPOINTS:
        try:
            txt = None
            data = fetch_via_tuxler(scheme, host, port, path)
            if isinstance(data, dict):
                txt = data.get("query") or data.get("ip")
            else:
                txt = str(data).strip()
            if isinstance(txt, str) and txt:
                return txt.strip()
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    raise OSError("ip probe failed, last: %s" % last_err)


def geo_lookup():
    """Full geo lookup — only called when the exit IP actually changes."""
    last_err = None
    for scheme, host, port, path in GEO_ENDPOINTS:
        try:
            return geo_from_ip_response(fetch_via_tuxler(scheme, host, port, path))
        except Exception as e:  # noqa: BLE001
            last_err = e
            continue
    raise OSError("all geo endpoints failed, last: %s" % last_err)


def checker_loop():
    while not _stop.is_set():
        t0 = time.time()
        try:
            # panic switch: force closed without even asking the geo API
            if os.path.exists(PANIC_FILE):
                set_verdict(False, "panic file %s present" % PANIC_FILE, failures=True)
                log("panic switch active — gate forced CLOSED")
                time.sleep(1)
                _stop.wait(max(0.5, CHECK_INTERVAL))
                continue
            # 1) cheap IP probe — do NOT spend a geo lookup until the IP changes
            ip = probe_exit_ip()
            state.fail_streak = 0

            with state.lock:
                cached = state.geo_cache.get(ip)
            if cached:
                verdict, geo, ts = cached
                state.cache_hits += 1
                cc = geo.get("countryCode")
                if verdict == "allow":
                    set_verdict(True, "cached: exit %s is %s" % (ip, cc), geo)
                else:
                    set_verdict(False, "cached: exit %s not %s (got %s)" % (
                        ip, ALLOWED_COUNTRY, cc), geo)
                log("check cached (%.2fs): ip=%s cc=%s -> %s [hits=%d misses=%d]" % (
                    time.time() - t0, ip, cc,
                    "ALLOW" if state.allow else "DROP",
                    state.cache_hits, state.cache_misses))
            else:
                # 2) new IP → one geo lookup, then memoise the verdict
                state.cache_misses += 1
                geo = geo_lookup()
                cc = geo.get("countryCode")
                if geo.get("status") != "success" or not cc:
                    raise OSError("geo api returned status=%r message=%r" % (
                        geo.get("status"), geo.get("message")))
                geo["query"] = geo.get("query") or ip
                allow = (cc == ALLOWED_COUNTRY)
                with state.lock:
                    state.geo_cache[ip] = ("allow" if allow else "deny", geo,
                                           datetime.now(timezone.utc).isoformat(timespec="seconds"))
                    if len(state.geo_cache) > GEO_CACHE_MAX:
                        # evict the oldest entry
                        oldest = min(state.geo_cache,
                                     key=lambda k: state.geo_cache[k][2])
                        if oldest != ip:
                            state.geo_cache.pop(oldest, None)
                if allow:
                    set_verdict(True, "new exit is %s" % cc, geo)
                else:
                    set_verdict(False, "new exit not %s (got %s)" % (ALLOWED_COUNTRY, cc), geo)
                log("check NEW ip (%.2fs): ip=%s cc=%s city=%s isp=%s -> %s "
                    "[hits=%d misses=%d cached_ips=%d]" % (
                        time.time() - t0, ip, cc, geo.get("city"), geo.get("isp"),
                        "ALLOW" if state.allow else "DROP",
                        state.cache_hits, state.cache_misses, len(state.geo_cache)))
        except Exception as e:  # noqa: BLE001 - could not even probe the IP
            state.fail_streak += 1
            msg = "probe failed (%d/%d): %s: %s" % (
                state.fail_streak, FAIL_CLOSED_AFTER, type(e).__name__, e)
            # Transient probe failures must NOT flap the gate: if we already
            # verified the current exit, keep that verdict. Only close once the
            # failures are persistent enough that we can no longer trust it.
            if state.fail_streak >= FAIL_CLOSED_AFTER:
                if state.verified and state.allow:
                    log("holding OPEN through probe failures (last verified %s, %d fails)"
                        % (state.ip, state.fail_streak))
                else:
                    set_verdict(False, msg, failures=True)
            log(msg)

        # sleep the remainder of the interval, but wake early on the recheck trigger
        dt = time.time() - t0
        deadline = time.time() + max(0.5, CHECK_INTERVAL - dt)
        while time.time() < deadline and not _stop.is_set():
            if os.path.exists(RECHECK_TRIGGER):
                try:
                    os.unlink(RECHECK_TRIGGER)
                except OSError:
                    pass
                break
            _stop.wait(0.25)


# ---------------- relay ----------------
def pump(a, b, cid, stop_flag):
    """Copy a->b until EOF/error. Returns bytes copied."""
    total = 0
    try:
        while not stop_flag.is_set():
            r, _, _ = select.select([a], [], [], 1.0)
            if not r:
                continue
            data = a.recv(65536)
            if not data:
                break
            b.sendall(data)
            total += len(data)
    except OSError:
        pass
    finally:
        stop_flag.set()
    return total


def drop_conn(cid, reason, rst=False):
    with state.lock:
        pair = state.conns.pop(cid, None)
    if not pair:
        return
    csock, usock = pair
    for s in (csock, usock):
        if rst:
            try:
                s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                             struct.pack("ii", 1, 0))
            except OSError:
                pass
        try:
            s.close()
        except OSError:
            pass
    log("closed conn %s (%s)" % (cid, reason))


_next_cid = 0
_cid_lock = threading.Lock()


def new_cid():
    global _next_cid
    with _cid_lock:
        _next_cid += 1
        return _next_cid


def handle_client(csock, addr):
    cid = new_cid()
    usock = None
    stop_flag = threading.Event()
    try:
        # --- gate check #1: refuse fast while closed ---
        with state.lock:
            allow, reason = state.allow, state.reason
        if not allow:
            log("refused conn %s from %s:%d — %s" % (cid, addr[0], addr[1], reason))
            try:
                csock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                                 struct.pack("ii", 1, 0))
            except OSError:
                pass
            csock.close()
            return

        csock.settimeout(30)
        head = _recv_exact(csock, 2)
        if len(head) != 2 or head[0] != 5:
            csock.close()
            return
        nmeth = head[1]
        methods = _recv_exact(csock, nmeth)
        if b"\x00" not in methods:
            csock.sendall(b"\x05\xff")
            csock.close()
            return
        csock.sendall(b"\x05\x00")

        req = _recv_exact(csock, 4)
        if len(req) != 4 or req[0] != 5 or req[1] != 1:
            csock.close()
            return
        atyp = req[3]
        if atyp == 1:
            dst_host = socket.inet_ntoa(_recv_exact(csock, 4))
        elif atyp == 3:
            n = _recv_exact(csock, 1)[0]
            dst_host = _recv_exact(csock, n).decode("latin-1")
        elif atyp == 4:
            dst_host = socket.inet_ntop(socket.AF_INET6, _recv_exact(csock, 16))
        else:
            csock.close()
            return
        dst_port = struct.unpack("!H", _recv_exact(csock, 2))[0]

        # --- gate check #2: race-free right before dialing upstream ---
        with state.lock:
            allow, reason = state.allow, state.reason
        if not allow:
            log("refused conn %s -> %s:%d — %s" % (cid, dst_host, dst_port, reason))
            csock.sendall(b"\x05\x05\x00\x01" + b"\x00\x00\x00\x00\x00\x00")
            csock.close()
            return

        try:
            usock = socks5_open(TUXLER_HOST, TUXLER_PORT, dst_host, dst_port)
        except OSError as e:
            log("upstream failed conn %s -> %s:%d: %s" % (cid, dst_host, dst_port, e))
            csock.sendall(b"\x05\x01\x00\x01" + b"\x00\x00\x00\x00\x00\x00")
            csock.close()
            return

        csock.settimeout(None)
        # register so a non-US verdict can hard-drop it
        with state.lock:
            if not state.allow:
                usock.close(); csock.close()
                log("conn %s dropped at registration — %s" % (cid, state.reason))
                return
            state.conns[cid] = (csock, usock)
        write_state_file()

        csock.sendall(b"\x05\x00\x00\x01" + b"\x00\x00\x00\x00\x00\x00")
        log("open conn %s %s:%d -> %s:%d" % (cid, addr[0], addr[1],
                                             dst_host, dst_port))

        t1 = threading.Thread(target=pump, args=(csock, usock, cid, stop_flag), daemon=True)
        t2 = threading.Thread(target=pump, args=(usock, csock, cid, stop_flag), daemon=True)
        t1.start(); t2.start()
        t1.join(); t2.join()
    except Exception as e:  # noqa: BLE001
        log("conn %s error: %s: %s" % (cid, type(e).__name__, e))
    finally:
        drop_conn(cid, "done")


# ---------------- main ----------------
def main():
    signal.signal(signal.SIGTERM, lambda *_: (_stop.set(), sys.exit(0)))
    signal.signal(signal.SIGINT, lambda *_: (_stop.set(), sys.exit(0)))

    log("geo-gate starting: listen %s:%d -> tuxler %s:%d | allow=%s | every %.1fs | "
        "geo=%s" % (GATE_HOST, GATE_PORT, TUXLER_HOST, TUXLER_PORT,
                    ALLOWED_COUNTRY, CHECK_INTERVAL,
                    ", ".join("%s//%s%s" % (s, h, p) for s, h, _, p in GEO_ENDPOINTS)))

    t = threading.Thread(target=checker_loop, daemon=True)
    t.start()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((GATE_HOST, GATE_PORT))
    srv.listen(128)
    log("listening on %s:%d (fail-closed until first successful check)" % (GATE_HOST, GATE_PORT))

    while not _stop.is_set():
        try:
            r, _, _ = select.select([srv], [], [], 1.0)
        except OSError:
            continue
        if not r:
            continue
        try:
            csock, addr = srv.accept()
        except OSError:
            continue
        threading.Thread(target=handle_client, args=(csock, addr), daemon=True).start()


if __name__ == "__main__":
    main()