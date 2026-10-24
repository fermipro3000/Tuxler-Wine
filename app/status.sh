#!/bin/bash
# /opt/tuxler-wine/app/status.sh — show Tuxler-Wine service status

echo "Tuxler-Wine Service Status"
echo "=========================="

# Check processes by PID
for pidfile in /var/run/tuxler-wine-*.pid; do
    if [ -f "$pidfile" ]; then
        pid=$(cat "$pidfile")
        name=$(basename $pidfile .pid | sed 's/tuxler-wine-//')
        if ps -p $pid >/dev/null 2>&1; then
            echo "✓ $name (PID $pid) is running"
        else
            echo "✗ $name (PID $pid) is not running"
        fi
    else
        name=$(basename $pidfile .pid | sed 's/tuxler-wine-//')
        echo "✗ $name is not running (no PID file)"
    fi
done

# Check processes by name
echo ""
echo "Process Status:"
echo "=============="

if pgrep -x 'tuxlerVPN.exe' >/dev/null; then
    echo "✓ tuxlerVPN.exe is running"
else
    echo "✗ tuxlerVPN.exe is not running"
fi

if pgrep -x 'geo-gate.py' >/dev/null; then
    echo "✓ geo-gate.py is running"
else
    echo "✗ geo-gate.py is not running"
fi

if pgrep -x 'watchdog.sh' >/dev/null; then
    echo "✓ watchdog.sh is running"
else
    echo "✗ watchdog.sh is not running"
fi

if pgrep -x 'memguard.sh' >/dev/null; then
    echo "✓ memguard.sh is running"
else
    echo "✗ memguard.sh is not running"
fi

if pgrep -x Xvfb >/dev/null; then
    echo "✓ Xvfb is running"
else
    echo "✗ Xvfb is not running"
fi

# Check logs
echo ""
echo "Recent Log Entries:"
echo "=================="

echo "Geo-gate log (last 5 lines):"
if [ -f "/var/log/tuxler/geo-gate.log" ]; then
    tail -n 5 /var/log/tuxler/geo-gate.log
else
    echo "No geo-gate log file found"
fi

echo ""
echo "Tuxler log (last 5 lines):"
if [ -f "/var/log/tuxler/tuxler.log" ]; then
    tail -n 5 /var/log/tuxler/tuxler.log
else
    echo "No tuxler log file found"
fi

echo ""
echo "Memory usage:"
echo "============="
free -h