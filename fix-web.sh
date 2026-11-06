#!/bin/sh
# Emergency: restore router web UI (ERR_CONNECTION_REFUSED on :4153 / LuCI).
# Run via SSH:
#   wget -q -T 60 -O /tmp/fix-web.sh https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/fix-web.sh
#   sh /tmp/fix-web.sh
echo "[fix-web] diagnosing…"

mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw,exec /data 2>/dev/null || true

echo "=== disk ==="
df -h / /overlay /data 2>/dev/null || df -h

echo "=== stop VPN that may hold routes/NAT ==="
/data/zi-bin/zi-manager stop 2>/dev/null || true
/usr/bin/zi-manager stop 2>/dev/null || true
killall charon starter 2>/dev/null || true
iptables -t nat -D POSTROUTING -j ZI_NAT 2>/dev/null || true
iptables -t nat -F ZI_NAT 2>/dev/null || true
iptables -t nat -X ZI_NAT 2>/dev/null || true

echo "=== remove broken LuCI controller (safe; restores menu) ==="
# Bad .lua in controller/ can blank LuCI; connection-refused is uhttpd dead,
# but we still remove ours so CGI can load after web is back.
rm -f /usr/lib/lua/luci/controller/zlt_ipsec.lua 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null || true
# clean glob without harming other /tmp
for d in /tmp/luci-modulecache /tmp/luci-indexcache; do rm -rf "$d" 2>/dev/null; done

echo "=== free a little overlay if full ==="
rm -f /tmp/zi_*.log /tmp/zi_import* /tmp/zi_charon.log /tmp/zi_start.log 2>/dev/null || true
rm -rf /tmp/zi_swan_dl /tmp/zi_swanctl 2>/dev/null || true

echo "=== restart web server ==="
# ZLT often uses uhttpd on a custom port (e.g. 4153)
if [ -x /etc/init.d/uhttpd ]; then
    /etc/init.d/uhttpd stop 2>/dev/null || true
    killall uhttpd 2>/dev/null || true
    sleep 1
    /etc/init.d/uhttpd start
    sleep 1
    /etc/init.d/uhttpd restart 2>/dev/null || true
fi

# Some OEM images also ship a second httpd
for s in httpd lighttpd nginx goahead; do
    [ -x "/etc/init.d/$s" ] && "/etc/init.d/$s" restart 2>/dev/null || true
done

echo "=== listen ports ==="
netstat -lntp 2>/dev/null | grep -E 'uhttpd|httpd|:80|:443|:4153' || \
    ss -lntp 2>/dev/null | grep -E 'uhttpd|httpd|:80|:443|:4153' || \
    echo "(no netstat/ss — try: uci show uhttpd)"

echo "=== uhttpd config (listen) ==="
uci show uhttpd 2>/dev/null | grep -E 'listen|port|home' || true
ps w 2>/dev/null | grep -E '[u]httpd|[h]ttpd' || ps | grep -E '[u]httpd|[h]ttpd' || true

echo "[fix-web] DONE"
echo "  Open: http://192.168.70.1:4153/cgi-bin/luci/"
echo "  Also try: http://192.168.70.1/cgi-bin/luci/"
echo "  If still refused: reboot the router, then re-run this script."
echo "  After web is back, reinstall UI only:"
echo "    sh /tmp/zi-install.sh   # or wget install.sh again"
exit 0
