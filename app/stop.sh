#!/bin/bash
# /opt/tuxler-wine/app/stop.sh — stop all Tuxler-Wine processes

echo "Stopping Tuxler-Wine processes..."

# Stop processes by PID
for pidfile in /var/run/tuxler-wine-*.pid; do
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile")
        if ps -p $pid >/dev/null 2>&1; then
            echo "Stopping process $pid ($(basename $pidfile .pid | sed 's/tuxler-wine-//'))"
            kill -TERM $pid
            sleep 1
            if ps -p $pid >/dev/null 2>&1; then
                kill -KILL $pid
            fi
        fi
        rm -f "$pidfile"
    fi
done

# Kill remaining processes by name
pkill -x 'tuxlerVPN.exe' 2>/dev/null || true
pkill -x 'geo-gate.py' 2>/dev/null || true
pkill -x 'watchdog.sh' 2>/dev/null || true
pkill -x 'memguard.sh' 2>/dev/null || true
pkill -x wineserver64 2>/dev/null || true
pkill -x wineserver 2>/dev/null || true

# Kill Xvfb if it's running
if pgrep -x Xvfb >/dev/null; then
    pkill -x Xvfb
fi

echo "All Tuxler-Wine processes stopped."