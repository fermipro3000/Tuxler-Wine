#!/bin/bash
# /opt/tuxler-wine/app/start.sh — single-command relaunch of the Tuxler client.
# Safe kills only (exact name / PID, never pkill -f).
# Usage: TUNNEL_PORT=49070 DISPLAY=:99 /opt/tuxler-wine/app/start.sh

TUNNEL_PORT=${TUNNEL_PORT:-49070}
export WINEPREFIX=/root/.config/tuxler-wine/wine32
export DISPLAY=${DISPLAY:-:99}
export WINEDEBUG=-all
export LD_PRELOAD="/opt/tuxler-wine/app/socks5shim.so /opt/tuxler-wine/app/socks5shim64.so"
export SHIM_SOCKS_PORT=$TUNNEL_PORT
export SHIM_LOG=/var/log/tuxler/socks5shim.log

# Kill existing processes
pkill -x 'tuxlerVPN.exe' 2>/dev/null
for p in $(pgrep -x wineserver64; pgrep -x wineserver); do kill -9 $p 2>/dev/null; done
sleep 2

cd /opt/tuxler-wine/app || exit 1

# Start Xvfb if not already running
if ! pgrep -x Xvfb >/dev/null; then
    Xvfb :99 -screen 0 1280x720x24 -ac +extension GLX +render -noreset &
    sleep 2
fi

# Start geo-gate
nohup python3 geo-gate.py >>/var/log/tuxler/geo-gate.log 2>&1 &
GEO_GATE_PID=$!
echo "geo-gate launched pid $!"

# Start Tuxler
nohup wine tuxlerVPN.exe >>/var/log/tuxler/tuxler.log 2>&1 &
TUXLER_PID=$!
echo "tuxler launched pid $TUXLER_PID (all egress via phone tunnel :$TUNNEL_PORT)"

# Start watchdog
nohup ./watchdog.sh >>/var/log/tuxler/watchdog.log 2>&1 &
WATCHDOG_PID=$!
echo "watchdog launched pid $WATCHDOG_PID"

# Start memory guard
nohup ./memguard.sh >>/var/log/tuxler/memguard.log 2>&1 &
MEMGUARD_PID=$!
echo "memory guard launched pid $MEMGUARD_PID"

# Save PIDs
echo $GEO_GATE_PID > /var/run/tuxler-wine-geogate.pid
echo $TUXLER_PID > /var/run/tuxler-wine-tuxler.pid
echo $WATCHDOG_PID > /var/run/tuxler-wine-watchdog.pid
echo $MEMGUARD_PID > /var/run/tuxler-wine-memguard.pid