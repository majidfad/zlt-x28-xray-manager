#!/bin/sh
# ZLT-X28 IPsec manager installer (zi-*) — Amnezia IKEv2 tunnel only.
# Usage on router:
#   wget -q -T 60 -O /tmp/zi-install.sh https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/install.sh && sh /tmp/zi-install.sh
# NOTE: do not use set -e — a mid-fail must not leave uhttpd stopped.

REPO_RAW="${ZI_REPO_RAW:-https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main}"
BIN_DIR=/data/zi-bin
LUCI_DIR=/data/zi-luci
STATE=/etc/zlt-ipsec

echo "[zi-install] ZLT IPsec manager"
mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw,exec /data 2>/dev/null || true
mkdir -p "$BIN_DIR" "$LUCI_DIR/controller" "$LUCI_DIR/view" "$STATE" /tmp/zi-bin \
         /usr/lib/lua/luci/controller /usr/lib/lua/luci/view 2>/dev/null || true

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

ensure_web() {
    echo "[zi-install] ensuring web server is up"
    if [ -x /etc/init.d/uhttpd ]; then
        if ! pidof uhttpd >/dev/null 2>&1; then
            /etc/init.d/uhttpd start 2>/dev/null || true
        else
            # soft reload only — never leave process dead
            killall -HUP uhttpd 2>/dev/null || true
        fi
        sleep 1
        if ! pidof uhttpd >/dev/null 2>&1; then
            /etc/init.d/uhttpd start 2>/dev/null || true
        fi
    fi
    pidof uhttpd >/dev/null 2>&1 && echo "[zi-install] uhttpd OK" || echo "[zi-install] WARN: uhttpd not running — run fix-web.sh"
}

wipe_legacy() {
    echo "[zi-install] removing legacy sb-*/sing-box bits (if any)"
    /etc/init.d/sb-vpn stop 2>/dev/null || true
    /etc/init.d/singbox stop 2>/dev/null || true
    killall charon starter sing-box sb-manager 2>/dev/null || true
    if mount | grep -q ' on /usr/lib/ipsec '; then
        umount /usr/lib/ipsec 2>/dev/null || umount -l /usr/lib/ipsec 2>/dev/null || true
        sleep 1
    fi
    rm -f /usr/bin/sb-manager /usr/bin/sb-install-stack /usr/bin/sb-vpn-decode \
          /usr/bin/sb-ctl 2>/dev/null || true
    rm -f /usr/lib/lua/luci/controller/sb_*.lua \
          /usr/lib/lua/luci/view/sb_*.htm \
          /usr/lib/lua/luci/controller/singbox.lua \
          /usr/lib/lua/luci/view/singbox_panel.htm \
          /usr/lib/lua/luci/controller/zlt_xray*.lua \
          /usr/lib/lua/luci/view/zlt_xray*.htm 2>/dev/null || true
    rm -f /etc/init.d/sb-vpn /etc/init.d/sb-swan-bind /etc/rc.d/*sb-* 2>/dev/null || true
}

fetch_bin() {
    _name="$1"; _rel="$2"
    _dst="$BIN_DIR/$_name"
    echo "[zi-install] $_name"
    if ! http_get "$REPO_RAW/$_rel" "$_dst"; then
        echo "[zi-install] ERROR: failed $_rel" >&2
        return 1
    fi
    # strip CR if any (Windows)
    tr -d '\r' < "$_dst" > "$_dst.lf" 2>/dev/null && mv -f "$_dst.lf" "$_dst"
    chmod 755 "$_dst"
    ln -sf "$_dst" "/usr/bin/$_name" 2>/dev/null || cp -f "$_dst" "/usr/bin/$_name"
    ln -sf "$_dst" "/tmp/zi-bin/$_name" 2>/dev/null || true
}

install_luci() {
    echo "[zi-install] LuCI panel → $LUCI_DIR (symlink into overlay)"
    _c="$LUCI_DIR/controller/zlt_ipsec.lua"
    _v="$LUCI_DIR/view/zlt_ipsec_panel.htm"
    if ! http_get "$REPO_RAW/files/usr/lib/lua/luci/controller/zlt_ipsec.lua" "$_c"; then
        echo "[zi-install] ERROR: controller download failed" >&2
        return 1
    fi
    if ! http_get "$REPO_RAW/files/usr/lib/lua/luci/view/zlt_ipsec_panel.htm" "$_v"; then
        echo "[zi-install] ERROR: view download failed" >&2
        return 1
    fi
    tr -d '\r' < "$_c" > "$_c.lf" && mv -f "$_c.lf" "$_c"
    tr -d '\r' < "$_v" > "$_v.lf" && mv -f "$_v.lf" "$_v"
    # reject HTML error pages from GitHub/CDN
    if ! grep -q 'luci.controller.zlt_ipsec' "$_c"; then
        echo "[zi-install] ERROR: controller file invalid (not Lua module)" >&2
        rm -f "$_c"
        return 1
    fi
    if ! grep -q 'ZLT IPsec' "$_v"; then
        echo "[zi-install] ERROR: view file invalid" >&2
        rm -f "$_v"
        return 1
    fi
    # Prefer symlink (saves tiny overlay). Fallback to copy.
    rm -f /usr/lib/lua/luci/controller/zlt_ipsec.lua \
          /usr/lib/lua/luci/view/zlt_ipsec_panel.htm 2>/dev/null || true
    if ln -sf "$_c" /usr/lib/lua/luci/controller/zlt_ipsec.lua 2>/dev/null \
       && ln -sf "$_v" /usr/lib/lua/luci/view/zlt_ipsec_panel.htm 2>/dev/null; then
        echo "[zi-install] LuCI symlinked from /data"
    else
        cp -f "$_c" /usr/lib/lua/luci/controller/zlt_ipsec.lua
        cp -f "$_v" /usr/lib/lua/luci/view/zlt_ipsec_panel.htm
        echo "[zi-install] LuCI copied into /usr (symlink failed)"
    fi
    rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
}

wipe_legacy

fetch_bin zi-manager       files/usr/bin/zi-manager || true
fetch_bin zi-install-stack files/usr/bin/zi-install-stack || true
fetch_bin zi-vpn-decode    files/usr/bin/zi-vpn-decode || true

install_luci || echo "[zi-install] WARN: LuCI panel not installed"

echo "[zi-install] init"
if http_get "$REPO_RAW/files/etc/init.d/zi-vpn" /etc/init.d/zi-vpn; then
    tr -d '\r' < /etc/init.d/zi-vpn > /tmp/zi-vpn.lf && mv -f /tmp/zi-vpn.lf /etc/init.d/zi-vpn
    chmod 755 /etc/init.d/zi-vpn
    /etc/init.d/zi-vpn enable 2>/dev/null || ln -sf ../init.d/zi-vpn /etc/rc.d/S95zi-vpn 2>/dev/null || true
fi

echo "[zi-install] strongSwan 5.9.2 stack"
if [ -x "$BIN_DIR/zi-install-stack" ]; then
    "$BIN_DIR/zi-install-stack" || echo "[zi-install] WARN: stack install failed"
elif [ -x /usr/bin/zi-install-stack ]; then
    /usr/bin/zi-install-stack || echo "[zi-install] WARN: stack install failed"
fi

# Also drop a tiny static status page (works even if LuCI menu is broken)
mkdir -p /www 2>/dev/null || true
if [ -d /www ]; then
    cat > /www/zi-status.html << 'HTML'
<!DOCTYPE html><html><head><meta charset="utf-8"><title>ZLT IPsec</title></head>
<body>
<h1>ZLT IPsec</h1>
<p>If this page loads, the web server is alive.</p>
<p>Open LuCI: <a href="/cgi-bin/luci/admin/services/zlt_ipsec">Services → ZLT IPsec</a></p>
<p>Or: <a href="/cgi-bin/luci/">LuCI home</a></p>
</body></html>
HTML
fi

ensure_web

echo "[zi-install] DONE"
echo "  Disk:"; df -h / /data 2>/dev/null | head -n5
echo "  LuCI:  http://<router-ip>:4153/cgi-bin/luci/admin/services/zlt_ipsec"
echo "  Probe: http://<router-ip>:4153/zi-status.html"
echo "  If connection refused: wget …/fix-web.sh && sh /tmp/fix-web.sh"
echo "  CLI: zi-manager ss_check"
exit 0
