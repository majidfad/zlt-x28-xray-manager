#!/bin/sh
# Emergency: free tiny overlay + restart OEM web (ZLT has NO uhttpd).
#   wget -q -T 60 -O /tmp/fix-web.sh https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/fix-web.sh
#   sh /tmp/fix-web.sh
echo "[fix-web] ZLT web recovery"

mount -o remount,rw / 2>/dev/null || true
mount -o remount,rw,exec /data 2>/dev/null || true

echo "=== BEFORE disk ==="
df -h / /overlay /data 2>/dev/null || df -h

# Stop VPN / NAT
killall charon starter 2>/dev/null || true
iptables -t nat -D POSTROUTING -j ZI_NAT 2>/dev/null || true
iptables -t nat -F ZI_NAT 2>/dev/null || true
iptables -t nat -X ZI_NAT 2>/dev/null || true

echo "=== free overlay (move zi-* off /, drop caches) ==="
# Never keep manager/LuCI on tiny overlay — /data only
rm -f /usr/lib/lua/luci/controller/zlt_ipsec.lua \
      /usr/lib/lua/luci/view/zlt_ipsec_panel.htm \
      /usr/lib/lua/luci/controller/singbox.lua \
      /usr/lib/lua/luci/view/singbox_panel.htm 2>/dev/null || true
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/zi_* /tmp/sb_* 2>/dev/null || true

# Real files on /usr/bin (not symlinks to /data) waste overlay
for b in zi-manager zi-install-stack zi-vpn-decode sb-manager sb-vpn-decode sb-update-manager \
         sb-fix-ss-stack sb-install-ss-plugins; do
    p="/usr/bin/$b"
    if [ -e "$p" ] && [ ! -L "$p" ]; then
        echo "  rm overlay binary $p"
        rm -f "$p"
    elif [ -L "$p" ]; then
        # keep symlink if target on /data; else remove broken link
        t=$(readlink "$p" 2>/dev/null)
        case "$t" in
            /data/*) ;;
            *) rm -f "$p" ;;
        esac
    fi
done

# Init scripts on overlay are tiny but drop if /data copy exists
rm -f /etc/init.d/zi-vpn /etc/rc.d/*zi-vpn 2>/dev/null || true

# Old stack copies left on overlay under /usr/lib/ipsec when bind is down
if ! mount | grep -q ' on /usr/lib/ipsec '; then
    # only remove large leftover plugin copies we may have dropped (keep OEM if tiny)
    for f in /usr/lib/ipsec/plugins/libstrongswan-*.so \
             /usr/lib/ipsec/charon /usr/lib/ipsec/starter \
             /usr/lib/ipsec/libcharon.so* /usr/lib/ipsec/libstrongswan.so*; do
        [ -f "$f" ] || continue
        # skip if clearly OEM and small? delete large leftovers (>50KB) to free space
        sz=$(wc -c < "$f" 2>/dev/null || echo 0)
        if [ "$sz" -gt 50000 ]; then
            echo "  rm large overlay $f ($sz)"
            rm -f "$f"
        fi
    done
fi

# State can live on /data
if [ -d /etc/zlt-ipsec ] && [ ! -L /etc/zlt-ipsec ]; then
    mkdir -p /data/zlt-ipsec
    cp -a /etc/zlt-ipsec/. /data/zlt-ipsec/ 2>/dev/null || true
    rm -rf /etc/zlt-ipsec
    ln -sf /data/zlt-ipsec /etc/zlt-ipsec
fi

# Drop www probe if on overlay
rm -f /www/zi-status.html 2>/dev/null || true

sync
echo "=== AFTER disk ==="
df -h / /overlay /data 2>/dev/null || df -h

echo "=== find OEM web (not uhttpd) ==="
ls /etc/init.d/ 2>/dev/null
echo "---"
ps w 2>/dev/null || ps
echo "---"
grep -r "4153" /etc/init.d /etc/config /customer /usr/sbin /usr/bin 2>/dev/null | head -n 40
echo "---"
netstat -lntp 2>/dev/null || ss -lntp 2>/dev/null || true

echo "=== try common OEM web starters ==="
for s in web webui www httpd lighttpd nginx goahead zhttpd webserver \
         zlt_web router_web luci network; do
    if [ -x "/etc/init.d/$s" ]; then
        echo "  restart /etc/init.d/$s"
        "/etc/init.d/$s" restart 2>/dev/null || "/etc/init.d/$s" start 2>/dev/null || true
    fi
done

# Direct binaries sometimes used on ZLT
for b in /usr/sbin/httpd /usr/sbin/uhttpd /usr/bin/httpd /customer/*/httpd \
         /usr/sbin/lighttpd /usr/sbin/goahead; do
    [ -x "$b" ] || continue
    echo "  found binary $b"
done

echo "[fix-web] If / still shows Use% 100%, reboot after this script."
echo "  Then paste: ls /etc/init.d/; df -h /; netstat -lntp"
echo "  Browser: http://192.168.70.1:4153/"
exit 0
