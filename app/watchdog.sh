#!/bin/bash
# Tuxler watchdog v4 — calls /opt/tuxler-wine/app/start.sh (single source of truth).
# Checks the PHONE TUNNEL first: if it's down, waiting is all we can do.
# PID-safe kills only (never pkill -f).

TUNNEL_PORT=49070
SOCKS_PORT=23321
LOG=/var/log/tuxler/watchdog.log

while true; do
  # rotate shim log if huge
  [ -f /var/log/tuxler/socks5shim.log ] && [ "$(stat -c%s /var/log/tuxler/socks5shim.log 2>/dev/null || echo 0)" -gt 20971520 ] && \
    tail -c 2097152 /var/log/tuxler/socks5shim.log > /var/log/tuxler/socks5shim.log.tmp && mv /var/log/tuxler/socks5shim.log.tmp /var/log/tuxler/socks5shim.log

  # 1. phone tunnel alive?
  if ! timeout 5 curl -s -x socks5h://127.0.0.1:$TUNNEL_PORT --max-time 4 https://api.ipify.org >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] phone tunnel :$TUNNEL_PORT down — waiting" >> $LOG
    sleep 30; continue
  fi

  # 2. process gone → relaunch
  if ! pgrep -x 'tuxlerVPN.exe' >/dev/null; then
    echo "[$(date '+%F %T')] tuxler dead — relaunching via start.sh" >> $LOG
    TUNNEL_PORT=$TUNNEL_PORT DISPLAY=:99 /opt/tuxler-wine/app/start.sh >> $LOG 2>&1
    sleep 30; continue
  fi

  # 3. alive but SOCKS not answering → hard restart
  if ! timeout 8 curl -s -x socks5h://127.0.0.1:$SOCKS_PORT --max-time 6 https://api.ipify.org >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] SOCKS :$SOCKS_PORT unresponsive — restart via start.sh" >> $LOG
    TUNNEL_PORT=$TUNNEL_PORT DISPLAY=:99 /opt/tuxler-wine/app/start.sh >> $LOG 2>&1
    sleep 30; continue
  fi

  sleep 30
done