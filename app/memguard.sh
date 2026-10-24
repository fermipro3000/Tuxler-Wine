#!/bin/bash
# /opt/tuxler-wine/app/memguard.sh — keep the container under its 2GB cgroup limit.
#
# WHY: /tmp is a tmpfs, so every byte left there is unreclaimable RAM charged
# to the cgroup. Chromium + wine + the agent harness routinely push us into
# the OOM killer, and the kernel SIGKILLs tuxlerVPN.exe along with Chromium
# (which then needs the phone tunnel up again to recover).
#
# WHAT: every 60s, if the cgroup is above the threshold, trim only known-safe
# stale temp artefacts. It never kills a process and never touches live files.
#
LOG=/var/log/tuxler/memguard.log
MAX=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo 2147483648)
THRESH=$(( MAX * 90 / 100 ))
STALE_MIN=10

note() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

while true; do
  CUR=$(cat /sys/fs/cgroup/memory.current 2>/dev/null || echo 0)
  if [ "$CUR" -gt "$THRESH" ]; then
    freed=0
    # 1. stale Chromium scratch dirs (scoped dirs, extension unzip dirs)
    for d in /tmp/org.chromium.Chromium.scoped_dir.* \
             /tmp/org.chromium.Chromium.chromium_chrome_Unzipping.* \
             /tmp/org.chromium.Chromium.chromium_chrome_Unpacker_BeginUnzipping.* \
             /tmp/.org.chromium.Chromium.* \
             /tmp/chromium-test /tmp/chromium-test2 /tmp/chromium-test3 \
             /tmp/tmp.* /tmp/obtest /tmp/lwex; do
      [ -e "$d" ] || continue
      # only if nothing has it open and it is not brand new
      if [ -z "$(ls -l /proc/*/fd/* 2>/dev/null | grep -F " $d" 2>/dev/null | head -1)" ]; then
        sz=$(du -sk "$d" 2>/dev/null | cut -f1)
        old=$(find "$d" -maxdepth 0 -mmin +$STALE_MIN 2>/dev/null | head -1)
        [ -n "$old" ] || continue
        rm -rf "$d" 2>/dev/null && freed=$((freed + ${sz:-0}))
      fi
    done
    # 2. cap the growing logs (now on disk, not tmpfs, but still bounded)
    for f in /var/log/tuxler/geo-gate.log /var/log/tuxler/tuxler.log \
             /var/log/tuxler/socks5shim.log /var/log/tuxler/chromium.log; do
      [ -f "$f" ] || continue
      sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
      if [ "$sz" -gt 20971520 ]; then
        tail -c 2097152 "$f" > "$f.trim" && mv "$f.trim" "$f"
        freed=$((freed + sz / 1024))
      fi
    done
    if [ "$freed" -gt 0 ]; then
      note "high mem $((CUR / 1048576))MB — trimmed $((freed / 1024))MB"
    fi
  fi
  sleep 60
done