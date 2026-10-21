#!/bin/sh
# Verifies that the heredoc-embedded files in scripts/install.sh are
# byte-identical to their canonical sources in files/. Prevents the
# installer from silently drifting out of sync with the reviewable files.
set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_SH="$REPO_DIR/scripts/install.sh"
FAIL=0

check_block() {
    marker="$1"
    canonical="$2"
    tmp="/tmp/sb_check_$marker.txt"
    start_pat="cat << '$marker'"
    awk -v start="$start_pat" -v end="$marker" '
        index($0, start) == 1 { capture=1; next }
        $0 == end { capture=0 }
        capture { print }
    ' "$INSTALL_SH" > "$tmp"

    if ! diff -u "$canonical" "$tmp" > /tmp/sb_check_diff.txt; then
        echo "MISMATCH: embedded $marker block differs from $canonical"
        cat /tmp/sb_check_diff.txt
        FAIL=1
    else
        echo "OK: $marker matches $canonical"
    fi
    rm -f "$tmp" /tmp/sb_check_diff.txt
}

check_block "SB_CFG_EOF" "$REPO_DIR/files/etc/singbox/base_config.json"
check_block "SB_MGR_EOF" "$REPO_DIR/files/usr/bin/sb-manager"
check_block "SB_LUA_EOF" "$REPO_DIR/files/usr/lib/lua/luci/controller/singbox.lua"
check_block "SB_HTM_EOF" "$REPO_DIR/files/usr/lib/lua/luci/view/singbox_panel.htm"

exit $FAIL
