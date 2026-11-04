#!/bin/sh
# Remove ZLT IPsec manager (zi-*). Does not wipe /data/zi-swan by default.
set -e
echo "[zi-uninstall] stopping"
/etc/init.d/zi-vpn stop 2>/dev/null || true
/usr/bin/zi-manager stop 2>/dev/null || true
/data/zi-bin/zi-manager stop 2>/dev/null || true
killall charon starter 2>/dev/null || true

if mount | grep -q ' on /usr/lib/ipsec '; then
    umount /usr/lib/ipsec 2>/dev/null || umount -l /usr/lib/ipsec 2>/dev/null || true
fi

/etc/init.d/zi-vpn disable 2>/dev/null || true
/etc/init.d/zi-swan-bind disable 2>/dev/null || true
rm -f /etc/init.d/zi-vpn /etc/init.d/zi-swan-bind /etc/rc.d/*zi-* 2>/dev/null || true

rm -f /usr/bin/zi-manager /usr/bin/zi-install-stack /usr/bin/zi-vpn-decode
rm -rf /data/zi-bin
rm -f /usr/lib/lua/luci/controller/zlt_ipsec.lua \
      /usr/lib/lua/luci/view/zlt_ipsec_panel.htm
rm -rf /etc/zlt-ipsec /tmp/zi-bin /tmp/zi_swanctl

rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null || true
killall -HUP uhttpd 2>/dev/null || true

echo "[zi-uninstall] DONE (stack tarball on /data/zi-swan left in place)"
echo "  To also remove stack: rm -rf /data/zi-swan"
exit 0
