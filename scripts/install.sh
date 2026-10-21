#!/bin/sh
# =======================================================
# ZLT-X28 Sing-Box VPN Manager - install.sh
# Clean install / reinstall for OpenWrt (ZLT-X28 and similar ARM64 routers)
# =======================================================
set -eu

SINGBOX_VERSION="1.14.3"
SINGBOX_ARCH="${SINGBOX_ARCH:-arm64}"
SINGBOX_ASSET="sing-box-${SINGBOX_VERSION}-linux-${SINGBOX_ARCH}.tar.gz"
SINGBOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${SINGBOX_ASSET}"

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FILES_DIR="$REPO_DIR/files"

log() { echo "[install] $*"; }

log "1. Stopping services and cleaning up..."
killall -9 xray sing-box sb-manager xr-manager 2>/dev/null || true
rm -f /var/run/xray.pid /var/run/singbox.pid /var/run/sb_watchdog.pid /tmp/sb_wd_status /usr/bin/xr-manager 2>/dev/null || true

# Clean up all possible iptables rules
for t in nat mangle; do
    iptables -t "$t" -D PREROUTING -p tcp -j XRAY_TRANS 2>/dev/null || true
    iptables -t "$t" -D PREROUTING -p tcp -j SB_TRANS 2>/dev/null || true
    iptables -t "$t" -F XRAY_TRANS 2>/dev/null || true
    iptables -t "$t" -F SB_TRANS 2>/dev/null || true
    iptables -t "$t" -X XRAY_TRANS 2>/dev/null || true
    iptables -t "$t" -X SB_TRANS 2>/dev/null || true
done
ip rule del fwmark 1 table 100 2>/dev/null || true
ip route del local default dev lo table 100 2>/dev/null || true

log "2. Removing old core directories..."
rm -rf /data/xray_core /etc/xray
mkdir -p /data/singbox_core /etc/singbox
mkdir -p /usr/lib/lua/luci/controller/ /usr/lib/lua/luci/view/

log "3. Downloading sing-box ${SINGBOX_VERSION} (${SINGBOX_ARCH})..."
if [ ! -x "/data/singbox_core/sing-box" ]; then
    rm -f "/tmp/${SINGBOX_ASSET}"
    if ! curl -k -L --connect-timeout 20 --fail -o "/tmp/${SINGBOX_ASSET}" "$SINGBOX_URL"; then
        log "ERROR: download failed from $SINGBOX_URL"
        log "Check connectivity or set SINGBOX_ARCH if this router is not arm64."
        exit 1
    fi
    tar -xzf "/tmp/${SINGBOX_ASSET}" -C /data/singbox_core/ >/dev/null 2>&1
    mv /data/singbox_core/sing-box-*/sing-box /data/singbox_core/sing-box 2>/dev/null || true
    chmod +x /data/singbox_core/sing-box
    rm -rf /data/singbox_core/sing-box-* "/tmp/${SINGBOX_ASSET}" 2>/dev/null || true
fi

if [ ! -x /data/singbox_core/sing-box ]; then
    log "ERROR: sing-box binary missing after extraction. Aborting."
    exit 1
fi
/data/singbox_core/sing-box version || true

log "4. Installing base configuration..."
cp "$FILES_DIR/etc/singbox/base_config.json" /etc/singbox/base_config.json

log "5. Installing sb-manager..."
cp "$FILES_DIR/usr/bin/sb-manager" /usr/bin/sb-manager
chmod +x /usr/bin/sb-manager

log "6. Installing LuCI UI..."
cp "$FILES_DIR/usr/lib/lua/luci/controller/singbox.lua" /usr/lib/lua/luci/controller/singbox.lua
cp "$FILES_DIR/usr/lib/lua/luci/view/singbox_panel.htm" /usr/lib/lua/luci/view/singbox_panel.htm
rm -f /usr/lib/lua/luci/controller/xray.lua /usr/lib/lua/luci/view/xray_panel.htm 2>/dev/null || true

log "7. Initializing state files..."
rm -f /etc/singbox/node_*.json
: > /etc/singbox/nodes.list
printf 'none' > /etc/singbox/active_node
printf 'tunnel' > /etc/singbox/routing_mode
printf '0' > /etc/singbox/watchdog.flag

log "8. Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

log "======================================================="
log "Sing-Box VPN Manager ${SINGBOX_VERSION} installed."
log "Add a node with: sb-manager addnode <id> <path-to-file-containing-vless-link>"
log "Then activate it: sb-manager switch <id> && sb-manager start"
log "======================================================="
