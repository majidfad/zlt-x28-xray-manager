#!/bin/sh
# ZLT-X28 IPsec manager installer (zi-*) — Amnezia IKEv2 tunnel only.
# Usage on router:
#   wget -q -O /tmp/zi-install.sh https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/install.sh && sh /tmp/zi-install.sh
set -e

REPO_RAW="${ZI_REPO_RAW:-https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main}"
BIN_DIR=/data/zi-bin
STATE=/etc/zlt-ipsec

echo "[zi-install] ZLT IPsec manager"
mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw,exec /data 2>/dev/null || true
mkdir -p "$BIN_DIR" "$STATE" /tmp/zi-bin /usr/lib/lua/luci/controller /usr/lib/lua/luci/view

http_get() {
    _url="$1"; _out="$2"; rm -f "$_out"
    if command -v wget >/dev/null 2>&1; then
        wget -q -T 60 -O "$_out" "$_url" && [ -s "$_out" ] && return 0
        wget -q -T 60 --no-check-certificate -O "$_out" "$_url" && [ -s "$_out" ] && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 --max-time 120 -o "$_out" "$_url" && [ -s "$_out" ] && return 0
    fi
    return 1
}

wipe_legacy() {
    echo "[zi-install] removing legacy sb-*/sing-box bits (if any)"
    /etc/init.d/sb-vpn stop 2>/dev/null || true
    /etc/init.d/singbox stop 2>/dev/null || true
    killall charon starter sing-box sb-manager 2>/dev/null || true
    # Never rm through a live bind on /usr/lib/ipsec
    if mount | grep -q ' on /usr/lib/ipsec '; then
        umount /usr/lib/ipsec 2>/dev/null || umount -l /usr/lib/ipsec 2>/dev/null || true
        sleep 1
    fi
    rm -f /usr/bin/sb-manager /usr/bin/sb-install-stack /usr/bin/sb-vpn-decode \
          /usr/bin/sb-ctl /data/zi-bin/sb-* /tmp/sb-* 2>/dev/null || true
    rm -f /usr/lib/lua/luci/controller/sb_*.lua \
          /usr/lib/lua/luci/view/sb_*.htm \
          /usr/lib/lua/luci/controller/zlt_xray*.lua \
          /usr/lib/lua/luci/view/zlt_xray*.htm 2>/dev/null || true
    rm -f /etc/init.d/sb-vpn /etc/init.d/sb-swan-bind /etc/rc.d/*sb-* 2>/dev/null || true
    # Do NOT delete /data/sb-swan here if still in use as source — zi-install-stack uses /data/zi-swan
}

fetch_bin() {
    _name="$1"; _rel="$2"
    _dst="$BIN_DIR/$_name"
    echo "[zi-install] $_name"
    http_get "$REPO_RAW/$_rel" "$_dst" || {
        echo "[zi-install] ERROR: failed $_rel" >&2
        return 1
    }
    chmod 755 "$_dst"
    ln -sf "$_dst" "/usr/bin/$_name" 2>/dev/null || cp -f "$_dst" "/usr/bin/$_name"
    ln -sf "$_dst" "/tmp/zi-bin/$_name" 2>/dev/null || true
}

wipe_legacy

fetch_bin zi-manager       files/usr/bin/zi-manager
fetch_bin zi-install-stack files/usr/bin/zi-install-stack
fetch_bin zi-vpn-decode    files/usr/bin/zi-vpn-decode

echo "[zi-install] LuCI"
http_get "$REPO_RAW/files/usr/lib/lua/luci/controller/zlt_ipsec.lua" \
    /usr/lib/lua/luci/controller/zlt_ipsec.lua
http_get "$REPO_RAW/files/usr/lib/lua/luci/view/zlt_ipsec_panel.htm" \
    /usr/lib/lua/luci/view/zlt_ipsec_panel.htm

echo "[zi-install] init"
http_get "$REPO_RAW/files/etc/init.d/zi-vpn" /etc/init.d/zi-vpn
chmod 755 /etc/init.d/zi-vpn
/etc/init.d/zi-vpn enable 2>/dev/null || ln -sf ../init.d/zi-vpn /etc/rc.d/S95zi-vpn 2>/dev/null || true

echo "[zi-install] strongSwan 5.9.2 stack"
"$BIN_DIR/zi-install-stack" || /usr/bin/zi-install-stack

rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
killall -HUP uhttpd 2>/dev/null || true

echo "[zi-install] DONE"
echo "  LuCI: Services → ZLT IPsec"
echo "  CLI:  zi-manager import <vpn-or-json> && zi-manager start"
echo "  Check: zi-manager ss_check"
exit 0
