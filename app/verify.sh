#!/bin/bash
# /opt/tuxler-wine/app/verify.sh — one-shot health check for the whole stack.
#   1. Tuxler (wine32) running on Xvfb :99, egress via phone SOCKS :49070
#   2. Geo gate on :23322 -> Tuxler :23321, US-only, one geo lookup per IP
#   3. Chromium on the real profile with its extensions loaded
#   4. Browser egress really is a US residential IP through the gate
set -u
export DISPLAY=:99
unset LD_PRELOAD
ok=0; bad=0
chk() { if [ "$2" = "0" ]; then echo "  ✅ $1"; ok=$((ok+1)); else echo "  ❌ $1"; bad=$((bad+1)); fi; }

echo "=== 1. Tuxler under wine ==="
pgrep -x 'tuxlerVPN.exe' >/dev/null; chk "tuxlerVPN.exe running (pid $(pgrep -x 'tuxlerVPN.exe' | head -1))" $?
pgrep -x wineserver64 >/dev/null; chk "wineserver64 running" $?
ss -tln 2>/dev/null | grep -q ':23321'; chk "Tuxler SOCKS listening on 127.0.0.1:23321" $?
pgrep -x Xvfb >/dev/null; chk "Xvfb :99 running" $?
grep -q PROXIED /var/log/tuxler/socks5shim.log 2>/dev/null; chk "LD_PRELOAD shim is proxying connects" $?
ss -tln 2>/dev/null | grep -q ':49070'; chk "phone SOCKS tunnel listening on :49070" $?

echo "=== 2. Geo gate ==="
pgrep -f 'geo-gate[.]py' >/dev/null; chk "geo-gate.py running (pid $(pgrep -f 'geo-gate[.]py' | head -1))" $?
ss -tln 2>/dev/null | grep -q ':23322'; chk "gate listening on 127.0.0.1:23322" $?
python3 - <<'PY'
import json,sys
d=json.load(open('/var/log/tuxler/geo-gate.state'))
print("  ℹ️  gate=%s exit=%s cc=%s hits=%s misses=%s cached_ips=%s"
      % ("OPEN" if d["allow"] else "CLOSED", d["exit_ip"], d["country_code"],
         d.get("cache_hits"), d.get("cache_misses"), d.get("cached_ips")))
sys.exit(0 if d["allow"] and d["country_code"]=="US" else 1)
PY
chk "gate state = OPEN and exit IP is US" $?

echo "=== 3. Chromium ==="
pgrep -x chromium >/dev/null; chk "chromium running ($(pgrep -x chromium | wc -l) procs)" $?
PID=$(pgrep -x chromium | head -1)
tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null | grep -q -- '--user-data-dir=/root/.config/chromium'
chk "using the REAL profile (/root/.config/chromium, extensions live here)" $?
# NOTE: Chromium zeroes its own /proc/PID/environ, so we cannot read
# DBUS_SESSION_BUS_ADDRESS back from it. Check the bus itself instead — this
# is the bus the launcher hands to Chromium.
SOCK=$(ls /tmp/dbus-* 2>/dev/null | head -1)
[ -n "$SOCK" ]; chk "D-Bus session bus socket present ($SOCK)" $?
DBUS_SESSION_BUS_ADDRESS="unix:path=$SOCK" timeout 8 dbus-send --session --print-reply \
  --dest=org.freedesktop.DBus / org.freedesktop.DBus.ListNames 2>/dev/null | grep -q 'org.freedesktop.portal.Desktop'
chk "xdg-desktop-portal registered on the session bus (menus/clicks work)" $?
curl -s --max-time 8 http://127.0.0.1:9222/json/list 2>/dev/null | grep -q 'gmfolejjobkicnlkiapkcdplcmkggbgk'
chk "webrtc-control extension running (blocks WebRTC IP leaks)" $?
# SwitchyOmega is an MV3 extension: its service worker is started on demand and
# then goes dormant, so "is the SW target up right now" is not a reliable
# signal. Check it is installed AND enabled in the real profile instead.
python3 - <<'PY'
import json, sys
sid = "hihblcmlaaademjlakdpicchbjnnnkbo"
d = json.load(open("/root/.config/chromium/Default/Preferences"))
s = d.get("extensions", {}).get("settings", {}).get(sid, {})
ok = bool(s) and not s.get("disable_reasons")
print("  ℹ️  SwitchyOmega installed=%s enabled=%s" % (bool(s), ok))
sys.exit(0 if ok else 1)
PY
chk "SwitchyOmega V3 installed and enabled in the real profile" $?

echo "=== 4. Egress ==="
G=$(timeout 25 curl -s --socks5-hostname 127.0.0.1:23322 "http://ip-api.com/json/?fields=query,countryCode,city,isp" 2>/dev/null)
echo "  ℹ️  via gate :23322 -> $G"
python3 -c "
import json,sys
d=json.loads('''$G''')
sys.exit(0 if d.get('countryCode')=='US' else 1)" 2>/dev/null
chk "gate egress geolocates to the US" $?

echo "=== 5. Memory ==="
CUR=$(cat /sys/fs/cgroup/memory.current); MAX=$(cat /sys/fs/cgroup/memory.max)
echo "  ℹ️  cgroup $((CUR/1048576))MB / $((MAX/1048576))MB   /tmp $(du -sh /tmp 2>/dev/null | cut -f1) (tmpfs)"
[ "$CUR" -lt $((MAX*92/100)) ]; chk "memory below 92% of the cgroup limit" $?

echo
echo "RESULT: $ok passed, $bad failed"
[ "$bad" -eq 0 ]