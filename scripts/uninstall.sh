#!/bin/sh
# =======================================================
# ZLT-X28 Sing-Box VPN Manager - uninstall.sh
# Fully removes sing-box, sb-manager, and its LuCI UI.
# =======================================================
set -eu

log() { echo "[uninstall] $*"; }

log "Stopping sb-manager and sing-box..."
/usr/bin/sb-manager stop 2>/dev/null || true
killall -9 sing-box sb-manager 2>/dev/null || true
rm -f /var/run/singbox.pid /var/run/sb_watchdog.pid /tmp/sb_wd_status

log "Removing iptables rules..."
for t in nat mangle; do
    iptables -t "$t" -D PREROUTING -p tcp -j SB_TRANS 2>/dev/null || true
    iptables -t "$t" -F SB_TRANS 2>/dev/null || true
    iptables -t "$t" -X SB_TRANS 2>/dev/null || true
done
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

log "Removing files..."
rm -rf /data/singbox_core /etc/singbox
rm -f /usr/bin/sb-manager
rm -f /usr/lib/lua/luci/controller/singbox.lua
rm -f /usr/lib/lua/luci/view/singbox_panel.htm

log "Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

log "Sing-Box VPN Manager removed."
