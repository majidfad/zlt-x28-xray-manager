#!/bin/sh
# =======================================================
# ZLT-X28 Sing-Box VPN Manager - install.sh
# Clean install / reinstall for OpenWrt (ZLT-X28 and similar ARM64 routers)
#
# Self-contained: safe to run as `curl -L <url> | sh` with no other files
# on disk. The canonical, reviewable source for the embedded files lives in
# files/ in this repo; keep this script in sync with that directory.
# =======================================================
set -eu

SINGBOX_VERSION="1.14.3"

log() { echo "[install] $*"; }

# Detect userspace arch. Many aarch64 kernels still run a 32-bit OpenWrt rootfs.
detect_arch() {
    _bits="$(getconf LONG_BIT 2>/dev/null || echo "")"
    if [ "$_bits" = "32" ]; then
        case "$(uname -m)" in
            aarch64|arm64|armv7*|armv6*|arm*) echo "armv7"; return ;;
            x86_64|i386|i686) echo "386"; return ;;
        esac
    fi
    # Prefer dynamic linker presence over uname (more accurate for mixed systems).
    if [ -e /lib/ld-musl-aarch64.so.1 ] || [ -e /lib/ld-linux-aarch64.so.1 ]; then
        echo "arm64"; return
    fi
    if [ -e /lib/ld-musl-armhf.so.1 ] || [ -e /lib/ld-linux-armhf.so.3 ] || [ -e /lib/ld-linux.so.3 ]; then
        echo "armv7"; return
    fi
    if [ -e /lib/ld-musl-x86_64.so.1 ] || [ -e /lib/ld-linux-x86-64.so.2 ]; then
        echo "amd64"; return
    fi
    case "$(uname -m)" in
        aarch64|arm64) echo "arm64" ;;
        armv7*|armv6*|arm) echo "armv7" ;;
        x86_64|amd64) echo "amd64" ;;
        i386|i686) echo "386" ;;
        *) echo "" ;;
    esac
}

if [ -z "${SINGBOX_ARCH:-}" ]; then
    SINGBOX_ARCH="$(detect_arch)"
    if [ -z "$SINGBOX_ARCH" ]; then
        log "ERROR: unsupported machine '$(uname -m)'."
        log "Set SINGBOX_ARCH explicitly (arm64, armv7, amd64, 386) and re-run."
        exit 1
    fi
fi

# OpenWrt is musl. Upstream now ships separate -musl / -glibc builds; the
# unsuffixed linux-*.tar.gz often won't exec (BusyBox reports "not found").
SINGBOX_LIBC="${SINGBOX_LIBC:-musl}"

# Prefer a writable directory that allows executing binaries (/data is often noexec).
pick_core_dir() {
    for d in /data/singbox_core /opt/singbox_core /usr/local/singbox_core; do
        mkdir -p "$d" 2>/dev/null || continue
        _t="$d/.sb_exec_test"
        printf '#!/bin/sh\nexit 0\n' > "$_t"
        chmod +x "$_t" 2>/dev/null || true
        if "$_t" 2>/dev/null; then
            rm -f "$_t"
            echo "$d"
            return 0
        fi
        rm -f "$_t"
        log "Skipping $d (cannot execute binaries there)."
    done
    mkdir -p /usr/bin
    echo "/usr/bin"
}

asset_name() {
    _arch="$1"
    _libc="$2"
    if [ -n "$_libc" ]; then
        echo "sing-box-${SINGBOX_VERSION}-linux-${_arch}-${_libc}.tar.gz"
    else
        echo "sing-box-${SINGBOX_VERSION}-linux-${_arch}.tar.gz"
    fi
}

download_and_extract() {
    _arch="$1"
    _libc="$2"
    _asset="$(asset_name "$_arch" "$_libc")"
    _url="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${_asset}"
    log "Downloading ${_asset}..."
    rm -f "/tmp/${_asset}"
    if ! curl -k -L --connect-timeout 20 --fail -o "/tmp/${_asset}" "$_url"; then
        log "Download failed: $_url"
        return 1
    fi
    EXTRACT_DIR="$CORE_DIR"
    if [ "$CORE_DIR" = "/usr/bin" ]; then
        EXTRACT_DIR="/tmp/singbox_extract"
        rm -rf "$EXTRACT_DIR"
        mkdir -p "$EXTRACT_DIR"
    else
        # Clear previous extract leftovers in core dir.
        rm -rf "$CORE_DIR"/sing-box-*
    fi
    rm -f "$SB_BIN_PATH"
    if ! tar -xzf "/tmp/${_asset}" -C "$EXTRACT_DIR"; then
        log "Extract failed for ${_asset}"
        rm -f "/tmp/${_asset}"
        return 1
    fi
    EXTRACTED=""
    for f in "$EXTRACT_DIR"/sing-box-*/sing-box; do
        if [ -f "$f" ]; then
            EXTRACTED="$f"
            break
        fi
    done
    if [ -z "$EXTRACTED" ]; then
        log "sing-box binary not found inside ${_asset}"
        rm -f "/tmp/${_asset}"
        return 1
    fi
    mv "$EXTRACTED" "$SB_BIN_PATH"
    chmod +x "$SB_BIN_PATH"
    rm -rf "$CORE_DIR"/sing-box-* /tmp/singbox_extract "/tmp/${_asset}" 2>/dev/null || true

    # Also try executing from /tmp in case CORE_DIR is noexec for ELF only.
    if ! "$SB_BIN_PATH" version >/tmp/sb_ver.out 2>&1; then
        cp -f "$SB_BIN_PATH" /tmp/sing-box.test 2>/dev/null || true
        chmod +x /tmp/sing-box.test 2>/dev/null || true
        if /tmp/sing-box.test version >/tmp/sb_ver.out 2>&1; then
            log "NOTE: binary runs from /tmp but not $CORE_DIR — moving to /usr/bin"
            mv /tmp/sing-box.test /usr/bin/sing-box
            chmod +x /usr/bin/sing-box
            SB_BIN_PATH="/usr/bin/sing-box"
            CORE_DIR="/usr/bin"
            return 0
        fi
        rm -f /tmp/sing-box.test
        log "Binary not executable with arch=${_arch} libc=${_libc:-default}: $(cat /tmp/sb_ver.out 2>/dev/null)"
        return 1
    fi
    return 0
}

try_install_binary() {
    # Candidate list: preferred first, then fallbacks for mixed aarch64/armv7 OpenWrt.
    # Format: arch:libc  (libc empty = unsuffixed upstream asset)
    _candidates=""
    if [ -n "${SINGBOX_ARCH:-}" ] && [ -n "${SINGBOX_LIBC:-}" ]; then
        _candidates="${SINGBOX_ARCH}:${SINGBOX_LIBC}"
    fi
    _candidates="$_candidates ${SINGBOX_ARCH}:musl ${SINGBOX_ARCH}: ${SINGBOX_ARCH}:glibc"
    case "$SINGBOX_ARCH" in
        arm64) _candidates="$_candidates armv7:musl armv7:" ;;
        armv7) _candidates="$_candidates arm64:musl arm64:" ;;
    esac

    _tried=""
    for _pair in $_candidates; do
        _arch="${_pair%%:*}"
        _libc="${_pair#*:}"
        _key="${_arch}:${_libc}"
        case " $_tried " in
            *" $_key "*) continue ;;
        esac
        _tried="$_tried $_key"
        if download_and_extract "$_arch" "$_libc"; then
            SINGBOX_ARCH="$_arch"
            SINGBOX_LIBC="${_libc:-default}"
            return 0
        fi
    done
    return 1
}

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

log "2. Preparing directories..."
rm -rf /data/xray_core /etc/xray
mkdir -p /etc/singbox /etc/singbox/ipsec
mkdir -p /usr/lib/lua/luci/controller/ /usr/lib/lua/luci/view/
[ -f /etc/singbox/active_proto ] || printf 'none' > /etc/singbox/active_proto

# Optional IKEv2/IPsec backend. OEM ZLT feeds often lack strongSwan entirely.
log "2b. Checking strongSwan (IPsec/IKEv2)..."
if command -v swanctl >/dev/null 2>&1 || command -v ipsec >/dev/null 2>&1; then
    log "strongSwan already present."
elif command -v opkg >/dev/null 2>&1; then
    opkg update >/tmp/sb_opkg_update.log 2>&1 || true
    # Real OpenWrt package names (not "strongswan-full" / bare "swanctl").
    for _pkg in \
        openssl-util \
        strongswan \
        strongswan-default \
        strongswan-swanctl \
        strongswan-charon \
        strongswan-mod-kernel-netlink \
        strongswan-mod-openssl \
        strongswan-mod-pem \
        strongswan-mod-pkcs12 \
        strongswan-mod-socket-default \
        strongswan-mod-vici \
        strongswan-mod-nonce \
        strongswan-mod-random \
        strongswan-mod-stroke \
        strongswan-ipsec
    do
        opkg install "$_pkg" >/tmp/sb_opkg_ss.log 2>&1 && log "Installed $_pkg" || true
    done
    if command -v swanctl >/dev/null 2>&1 || command -v ipsec >/dev/null 2>&1; then
        log "strongSwan ready for Amnezia IPsec nodes."
    else
        log "NOTE: strongSwan packages are not in this firmware's opkg feeds."
        log "      Common on OEM ZLT-X28 builds. VLESS (sing-box) still works."
        log "      Amnezia IPsec needs swanctl/ipsec + kernel XFRM (kmod-ipsec)."
        log "      Check: opkg list | grep -i swan ; lsmod | grep xfrm"
    fi
else
    log "NOTE: no opkg — install strongSwan manually if you need IPsec."
fi

# python3 optional: CLI vpn:// decode. LuCI decodes vpn:// in the browser.
log "2c. Checking python3 (optional CLI vpn:// decode)..."
if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    log "python3 available for CLI vpn:// decode."
elif command -v opkg >/dev/null 2>&1; then
    for _pkg in python3-light python3; do
        opkg install "$_pkg" >/tmp/sb_opkg_py.log 2>&1 && log "Installed $_pkg" && break || true
    done
    if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
        log "NOTE: no python3 in feeds — use LuCI to paste vpn:// (browser decode),"
        log "      or paste flat IPsec JSON. CLI: sb-vpn-decode needs python3."
    fi
fi
CORE_DIR="$(pick_core_dir)"
SB_BIN_PATH="$CORE_DIR/sing-box"
# When falling back to /usr/bin, binary name is just sing-box there already.
if [ "$CORE_DIR" = "/usr/bin" ]; then
    SB_BIN_PATH="/usr/bin/sing-box"
fi
log "Core install dir: $CORE_DIR (machine=$(uname -m), long_bit=$(getconf LONG_BIT 2>/dev/null || echo ?), arch=$SINGBOX_ARCH, libc=$SINGBOX_LIBC)"

log "3. Installing sing-box ${SINGBOX_VERSION}..."
CURRENT_VERSION=""
if [ -f "$SB_BIN_PATH" ]; then
    # Only trust version if the binary actually runs on this CPU.
    CURRENT_VERSION=$("$SB_BIN_PATH" version 2>/dev/null | head -n1 | awk '{print $3}') || CURRENT_VERSION=""
fi

if [ "$CURRENT_VERSION" = "$SINGBOX_VERSION" ]; then
    log "sing-box $SINGBOX_VERSION already installed and runnable, skipping download."
else
    if [ -n "$CURRENT_VERSION" ]; then
        log "Found existing sing-box $CURRENT_VERSION, replacing with $SINGBOX_VERSION..."
    elif [ -f "$SB_BIN_PATH" ]; then
        log "Existing binary at $SB_BIN_PATH does not run; trying musl/arch fallbacks..."
    fi
    if ! try_install_binary; then
        log "ERROR: could not install a runnable sing-box binary."
        log "Diagnostics:"
        log "  uname -m: $(uname -m)"
        log "  LONG_BIT: $(getconf LONG_BIT 2>/dev/null || echo unknown)"
        log "  linkers: $(ls /lib/ld-* 2>/dev/null || echo none)"
        log "  tried musl/glibc for $SINGBOX_ARCH (and arm fallback)."
        log "Manual override examples:"
        log "  SINGBOX_ARCH=armv7 SINGBOX_LIBC=musl sh install.sh"
        log "  SINGBOX_ARCH=arm64 SINGBOX_LIBC=musl sh install.sh"
        exit 1
    fi
fi

if [ ! -f "$SB_BIN_PATH" ]; then
    log "ERROR: sing-box binary missing after extraction ($SB_BIN_PATH). Aborting."
    exit 1
fi

if ! "$SB_BIN_PATH" version >/tmp/sb_ver.out 2>&1; then
    log "ERROR: $SB_BIN_PATH exists but cannot execute on this device."
    log "Kernel says: $(cat /tmp/sb_ver.out 2>/dev/null)"
    exit 1
fi
log "sing-box OK: $(head -n1 /tmp/sb_ver.out 2>/dev/null) (arch=$SINGBOX_ARCH libc=$SINGBOX_LIBC path=$SB_BIN_PATH)"
printf '%s\n' "$SB_BIN_PATH" > /etc/singbox/sb_bin.path

log "4. Generating base configuration..."
cat << 'SB_CFG_EOF' > /etc/singbox/base_config.json
{
  "log": { "level": "warn", "output": "/var/log/singbox.log" },
  "dns": {
    "servers": [
      { "tag": "dns_proxy", "address": "1.1.1.1", "strategy": "ipv4_only" },
      { "tag": "dns_direct", "address": "8.8.8.8", "strategy": "ipv4_only", "detour": "direct" },
      { "tag": "dns_block", "address": "rcode://success" }
    ],
    "rules": [
      { "outbound": "any", "server": "dns_direct" },
      { "domain_suffix": [".ir"], "server": "dns_direct" }
    ],
    "final": "dns_proxy"
  },
  "inbounds": [
    { "type": "mixed", "tag": "mixed-in", "listen": "0.0.0.0", "listen_port": 1080, "sniff": true, "set_system_proxy": false },
    { "type": "tproxy", "tag": "tproxy-in", "listen": "0.0.0.0", "listen_port": 1081, "sniff": true, "sniff_override_destination": true },
    { "type": "tproxy", "tag": "dns-in", "listen": "0.0.0.0", "listen_port": 1053 }
  ],
  "outbounds": [
__NODE_PLACEHOLDER__
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" },
    { "type": "dns", "tag": "dns-out" }
  ],
  "route": {
    "rules": [
      { "protocol": "dns", "outbound": "dns-out" },
      { "inbound": ["dns-in"], "outbound": "dns-out" },
      { "ip_is_private": true, "outbound": "direct" },
      { "domain_suffix": [".ir"], "outbound": "direct" }
    ],
    "auto_detect_interface": true
  }
}
SB_CFG_EOF

log "5. Installing sb-manager..."
cat << 'SB_MGR_EOF' > /usr/bin/sb-manager
#!/bin/sh
# =======================================================
# sb-manager - Sing-Box Enterprise VPN Manager
# Core control daemon for ZLT-X28 Sing-Box VPN Manager
# Supports VLESS (sing-box) and IKEv2/IPsec (strongSwan)
# =======================================================
DIR_SB="/etc/singbox"
ACTIVE_NODE_POINTER="$DIR_SB/active_node"
MODE_POINTER="$DIR_SB/routing_mode"
BASE_CONFIG="$DIR_SB/base_config.json"
CONFIG_FILE="$DIR_SB/config.json"
LOG_FILE="/var/log/singbox.log"
PID_FILE="/var/run/singbox.pid"
WATCHDOG_FLAG="$DIR_SB/watchdog.flag"
MAINT_FLAG="$DIR_SB/maint.flag"
WATCHDOG_PID="/var/run/sb_watchdog.pid"
WATCHDOG_STATUS_FILE="/tmp/sb_wd_status"
BYPASS_LIST="$DIR_SB/bypass.list"
SB_BIN_POINTER="$DIR_SB/sb_bin.path"
SB_BIN="/data/singbox_core/sing-box"
IPSEC_DIR="$DIR_SB/ipsec"
IPSEC_CONN="sbvpn"
IPSEC_SWANCTL="/etc/swanctl/conf.d/sbvpn.conf"
# Isolated swanctl tree — avoids broken OEM /etc/swanctl configs breaking --load-all.
IPSEC_SWANCTL_DIR="/tmp/sb_swanctl"
PROTO_POINTER="$DIR_SB/active_proto"
SB_MANAGER_VERSION="2026.11.01-ipsec6"

# Resolve a sing-box binary that actually executes on this device.
# A file can be -x yet still "not found" at runtime (wrong CPU arch / corrupt).
resolve_sb_bin() {
    SB_BIN="/data/singbox_core/sing-box"
    if [ -f "$SB_BIN_POINTER" ]; then
        _p=$(cat "$SB_BIN_POINTER" 2>/dev/null)
        if [ -n "$_p" ] && [ -f "$_p" ]; then
            SB_BIN="$_p"
        fi
    fi
    for _p in \
        "$SB_BIN" \
        "/data/singbox_core/sing-box" \
        "/opt/singbox_core/sing-box" \
        "/usr/local/bin/sing-box" \
        "/usr/bin/sing-box"
    do
        [ -n "$_p" ] && [ -f "$_p" ] || continue
        if "$_p" version >/dev/null 2>&1; then
            SB_BIN="$_p"
            return 0
        fi
        # Keep first existing path for a clearer error if none run.
        [ "$SB_BIN" = "/data/singbox_core/sing-box" ] && [ ! -f "$SB_BIN" ] && SB_BIN="$_p"
    done
    return 1
}

sb_bin_usable() {
    [ -n "$SB_BIN" ] && [ -f "$SB_BIN" ] && "$SB_BIN" version >/dev/null 2>&1
}

report_sb_bin_error() {
    _mach=$(uname -m 2>/dev/null || echo unknown)
    if [ -f "$SB_BIN" ]; then
        echo "[System] sing-box at $SB_BIN exists but cannot run (wrong CPU arch or corrupt binary)." >> "$LOG_FILE"
        echo "[System] Device arch: $_mach. Re-run install.sh (try SINGBOX_ARCH=armv7 if this is 32-bit ARM)." >> "$LOG_FILE"
    else
        echo "[System] sing-box binary missing (looked for $SB_BIN). Re-run scripts/install.sh to download it." >> "$LOG_FILE"
    fi
}

is_sb_running() {
    # Prefer PID file (survives BusyBox ps cmdline truncation).
    if [ -f "$PID_FILE" ]; then
        _pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
            return 0
        fi
    fi
    # Fall back to process list; match binary name only (args often truncated).
    if ps 2>/dev/null | grep "[s]ing-box" >/dev/null 2>&1; then return 0; fi
    if ps w 2>/dev/null | grep "[s]ing-box" >/dev/null 2>&1; then return 0; fi
    return 1
}

is_ipsec_running() {
    if command -v swanctl >/dev/null 2>&1; then
        swanctl --list-sas 2>/dev/null | grep -q "$IPSEC_CONN" && return 0
    fi
    if command -v ipsec >/dev/null 2>&1; then
        ipsec status 2>/dev/null | grep -q "$IPSEC_CONN" && return 0
    fi
    return 1
}

is_vpn_running() {
    if [ "$(cat "$PROTO_POINTER" 2>/dev/null)" = "ipsec" ]; then
        is_ipsec_running
    else
        is_sb_running
    fi
}

get_active_node_path() { echo "$DIR_SB/node_$(cat "$ACTIVE_NODE_POINTER" 2>/dev/null).json"; }
get_mode() { cat "$MODE_POINTER" 2>/dev/null || echo "tunnel"; }

node_proto() {
    _n="$1"
    [ -f "$_n" ] || { echo "none"; return; }
    if grep -q '"type"[[:space:]]*:[[:space:]]*"ipsec"' "$_n" 2>/dev/null; then
        echo "ipsec"
    elif grep -q '"type"[[:space:]]*:[[:space:]]*"ikev2-cert"' "$_n" 2>/dev/null; then
        echo "ipsec"
    elif grep -q '"type"[[:space:]]*:[[:space:]]*"vless"' "$_n" 2>/dev/null; then
        echo "vless"
    elif grep -q '"hostName"' "$_n" 2>/dev/null && grep -q '"cert"' "$_n" 2>/dev/null; then
        echo "ipsec"
    elif grep -q '"p12"' "$_n" 2>/dev/null && grep -q '"addr"' "$_n" 2>/dev/null; then
        # Amnezia strongswan.profile / .sswan style
        echo "ipsec"
    else
        echo "vless"
    fi
}

# Decode percent-encoded URI components (full range, not a hardcoded subset).
# Using awk because BusyBox ash has no printf '%b' / no native URL decode.
urldecode() {
    _in="$1"
    # Replace '+' with space first (query string convention), then decode %XX.
    _in=$(echo "$_in" | sed 's/+/ /g')
    printf '%s' "$_in" | awk '
    {
        s = $0
        out = ""
        n = length(s)
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c == "%" && i + 2 <= n) {
                hex = substr(s, i + 1, 2)
                if (hex ~ /^[0-9A-Fa-f][0-9A-Fa-f]$/) {
                    dec = index("0123456789ABCDEF", toupper(substr(hex,1,1))) - 1
                    dec = dec * 16 + index("0123456789ABCDEF", toupper(substr(hex,2,1))) - 1
                    out = out sprintf("%c", dec)
                    i += 2
                    continue
                }
            }
            out = out c
        }
        printf "%s", out
    }'
}

# Escape a value for safe embedding inside a JSON string literal.
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Extract a top-level JSON string field.
# IMPORTANT: BusyBox awk often truncates very long lines (~4KB). Amnezia
# PKCS#12 certs are 6KB+, so prefer Lua (always on LuCI routers) for extraction.
extract_json_str() {
    _file="$1"
    _key="$2"
    if command -v lua >/dev/null 2>&1; then
        lua -e '
            local key = select(1, ...)
            local path = select(2, ...)
            local f = io.open(path, "rb")
            if not f then os.exit(1) end
            local s = f:read("*a") or ""
            f:close()
            -- Match "key" : "value" with simple escapes
            local pat = "\"" .. key .. "\"%s*:%s*\""
            local i, j = s:find(pat)
            if not i then os.exit(2) end
            local out = {}
            local k = j + 1
            while k <= #s do
                local c = s:sub(k, k)
                if c == "\\" then
                    k = k + 1
                    out[#out+1] = s:sub(k, k)
                elseif c == "\"" then
                    break
                else
                    out[#out+1] = c
                end
                k = k + 1
            end
            io.write(table.concat(out))
        ' "$_key" "$_file" 2>/dev/null && return 0
    fi
    # Fallback: awk (may truncate huge cert values on BusyBox).
    tr '\n\r' '  ' < "$_file" | awk -v key="$_key" '
    {
        s = $0
        qkey = "\"" key "\""
        p = index(s, qkey)
        if (p == 0) exit
        rest = substr(s, p + length(qkey))
        sub(/^[[:space:]]*:[[:space:]]*/, "", rest)
        if (substr(rest, 1, 1) != "\"") exit
        rest = substr(rest, 2)
        out = ""
        n = length(rest)
        for (i = 1; i <= n; i++) {
            c = substr(rest, i, 1)
            if (c == "\\") {
                i++
                if (i > n) break
                out = out substr(rest, i, 1)
                continue
            }
            if (c == "\"") break
            out = out c
        }
        printf "%s", out
    }'
}

parse_ipsec_json() {
    FILE="$1"
    OUT="$2"
    # Amnezia client export: { cert, hostName, userName, password }
    # Amnezia strongswan.profile / .sswan: { type:ikev2-cert, remote.addr, local.p12, ... }
    host=$(extract_json_str "$FILE" hostName)
    [ -z "$host" ] && host=$(extract_json_str "$FILE" addr)
    user=$(extract_json_str "$FILE" userName)
    [ -z "$user" ] && user=$(extract_json_str "$FILE" clientId)
    pass=$(extract_json_str "$FILE" password)
    cert=$(extract_json_str "$FILE" cert)
    [ -z "$cert" ] && cert=$(extract_json_str "$FILE" p12)
    if [ -z "$host" ] || [ -z "$cert" ]; then
        return 1
    fi
    ike_prop=$(extract_json_str "$FILE" ike-proposal)
    esp_prop=$(extract_json_str "$FILE" esp-proposal)
    [ -z "$ike_prop" ] && ike_prop="aes256-sha256-modp2048"
    [ -z "$esp_prop" ] && esp_prop="aes128gcm16"
    host_e=$(json_escape "$host")
    user_e=$(json_escape "$user")
    pass_e=$(json_escape "$pass")
    cert_e=$(json_escape "$cert")
    ike_e=$(json_escape "$ike_prop")
    esp_e=$(json_escape "$esp_prop")
    cat > "$OUT" << EOF
{
  "type": "ipsec",
  "tag": "proxy",
  "protocol": "amnezia-ikev2",
  "hostName": "$host_e",
  "userName": "$user_e",
  "password": "$pass_e",
  "cert": "$cert_e",
  "ikeProposal": "$ike_e",
  "espProposal": "$esp_e"
}
EOF
    return 0
}

# Decode Amnezia vpn:// share link → JSON file. Needs python3 (sb-vpn-decode).
decode_vpn_link_file() {
    _in="$1"
    _out="$2"
    _dec=""
    for _c in /usr/bin/sb-vpn-decode /usr/local/bin/sb-vpn-decode; do
        [ -x "$_c" ] && _dec="$_c" && break
    done
    if [ -z "$_dec" ]; then
        echo "[System] sb-vpn-decode missing; cannot import vpn:// links." >> "$LOG_FILE"
        return 1
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 "$_dec" "$_in" > "$_out" 2>/tmp/sb_vpn_decode.err
    elif command -v python >/dev/null 2>&1; then
        python "$_dec" "$_in" > "$_out" 2>/tmp/sb_vpn_decode.err
    else
        # shebang may still work if env python3 exists
        "$_dec" "$_in" > "$_out" 2>/tmp/sb_vpn_decode.err
    fi
    if [ ! -s "$_out" ]; then
        echo "[System] vpn:// decode failed:" >> "$LOG_FILE"
        cat /tmp/sb_vpn_decode.err >> "$LOG_FILE" 2>/dev/null
        echo "vpn:// decode failed (need python3 + sb-vpn-decode). See /var/log/singbox.log" >&2
        return 1
    fi
    return 0
}

parse_link_to_json() {
    FILE="$1"
    # Amnezia share link: vpn:// + Base64URL(qCompress(JSON))
    _head=$(head -c 16 "$FILE" 2>/dev/null | tr -d '\r\n\t ')
    case "$_head" in
        vpn://*|VPN://*)
            if ! decode_vpn_link_file "$FILE" /tmp/sb_vpn_decoded.json; then
                return
            fi
            # Decoded payload may be flat IPsec JSON or still a server object —
            # parse_ipsec_json + decoder already prefers ikev2 last_config.
            if parse_ipsec_json /tmp/sb_vpn_decoded.json /tmp/sb_parse_out.json; then
                cat /tmp/sb_parse_out.json
            else
                # If decoder returned full server JSON without extract, try raw fields
                echo "Failed to extract IPsec config from vpn:// link" >&2
            fi
            rm -f /tmp/sb_vpn_decoded.json /tmp/sb_parse_out.json
            return
            ;;
    esac

    # Detect Amnezia IKEv2/IPsec JSON (export, server JSON, or .sswan)
    _head=$(head -c 256 "$FILE" 2>/dev/null | tr -d '\r\n\t ')
    case "$_head" in
        \{*)
            if grep -qE '"hostName"|"addr"|"ikev2-cert"|"p12"|"amnezia-ipsec"|"ikev2"|"last_config"' "$FILE" 2>/dev/null \
                && grep -qE '"cert"|"p12"|"last_config"' "$FILE" 2>/dev/null; then
                # Full Amnezia server JSON → extract via sb-vpn-decode
                if grep -q '"containers"' "$FILE" 2>/dev/null; then
                    if decode_vpn_link_file "$FILE" /tmp/sb_vpn_decoded.json \
                        && parse_ipsec_json /tmp/sb_vpn_decoded.json /tmp/sb_parse_out.json; then
                        cat /tmp/sb_parse_out.json
                        rm -f /tmp/sb_vpn_decoded.json /tmp/sb_parse_out.json
                        return
                    fi
                    rm -f /tmp/sb_vpn_decoded.json /tmp/sb_parse_out.json
                fi
                parse_ipsec_json "$FILE" /tmp/sb_parse_out.json && cat /tmp/sb_parse_out.json
                rm -f /tmp/sb_parse_out.json
                return
            fi
            ;;
    esac

    link=$(cat "$FILE" | tr -d '\r\n ')
    if echo "$link" | grep -q "^vless://"; then
        link="${link#*://}"; link="${link%%#*}"
        uuid_addrport="${link%%\?*}"; query="${link#*\?}"; [ "$query" = "$link" ] && query=""
        uuid="${uuid_addrport%%@*}"; addrport="${uuid_addrport#*@}"
        # Support IPv6 literal addresses in [::1]:port form as well as host:port.
        case "$addrport" in
            \[*\]:*)
                address="${addrport%%]:*}"; address="${address#\[}"
                port="${addrport##*]:}"
                ;;
            *)
                address="${addrport%%:*}"; port="${addrport#*:}"
                ;;
        esac
        [ -z "$port" ] && port=443; port=$(echo "$port" | tr -dc '0-9'); [ -z "$port" ] && port=443

        security="none"; type="tcp"; flow=""; host=""; sni=""; fp="chrome"; pbk=""; sid=""; path=""; serviceName=""
        old_ifs="$IFS"; IFS="&"
        for param in $query; do
            key="${param%%=*}"; val="${param#*=}"
            val=$(urldecode "$val")
            case "$key" in
                security) security="$val" ;;
                type) type="$val" ;;
                flow) flow="$val" ;;
                host) host="$val" ;;
                sni) sni="$val" ;;
                fp) fp="$val" ;;
                pbk) pbk="$val" ;;
                sid) sid="$val" ;;
                path) path="$val" ;;
                serviceName) serviceName="$val" ;;
            esac
        done
        IFS="$old_ifs"
        [ -z "$sni" ] && sni="$host"

        uuid=$(json_escape "$uuid")
        address=$(json_escape "$address")
        sni=$(json_escape "$sni")
        fp=$(json_escape "$fp")
        pbk=$(json_escape "$pbk")
        sid=$(json_escape "$sid")
        flow=$(json_escape "$flow")
        path_esc=$(json_escape "$path")
        host_esc=$(json_escape "$host")
        serviceName_esc=$(json_escape "$serviceName")

        echo "    {"
        echo "      \"type\": \"vless\","
        echo "      \"tag\": \"proxy\","
        echo "      \"server\": \"$address\","
        echo "      \"server_port\": $port,"
        echo "      \"uuid\": \"$uuid\","
        if [ -n "$flow" ]; then echo "      \"flow\": \"$flow\","; fi

        if [ "$security" = "reality" ]; then
            echo "      \"tls\": {"
            echo "        \"enabled\": true,"
            echo "        \"server_name\": \"$sni\","
            echo "        \"reality\": {"
            echo "          \"enabled\": true,"
            echo "          \"public_key\": \"$pbk\","
            echo "          \"short_id\": \"$sid\""
            echo "        },"
            echo "        \"utls\": { \"enabled\": true, \"fingerprint\": \"$fp\" }"
            echo "      },"
        elif [ "$security" = "tls" ]; then
            echo "      \"tls\": { \"enabled\": true, \"server_name\": \"$sni\", \"utls\": { \"enabled\": true, \"fingerprint\": \"$fp\" } },"
        fi

        # Emit transport when the share link is not plain TCP (was previously ignored).
        case "$type" in
            ws)
                [ -z "$path_esc" ] && path_esc="/"
                echo "      \"transport\": {"
                echo "        \"type\": \"ws\","
                echo "        \"path\": \"$path_esc\""
                if [ -n "$host_esc" ]; then
                    echo "        ,\"headers\": { \"Host\": \"$host_esc\" }"
                fi
                echo "      },"
                ;;
            grpc)
                echo "      \"transport\": { \"type\": \"grpc\", \"service_name\": \"$serviceName_esc\" },"
                ;;
            http|h2)
                [ -z "$path_esc" ] && path_esc="/"
                echo "      \"transport\": { \"type\": \"http\", \"path\": [\"$path_esc\"] },"
                ;;
        esac

        echo "      \"tcp_fast_open\": true"
        echo "    }"
    fi
}

build_final_config() {
    ACTIVE_NODE=$(get_active_node_path)
    if [ ! -f "$ACTIVE_NODE" ]; then
        echo '    {"type":"block","tag":"proxy"}' > /tmp/sb_node_tmp.json
    else
        sed 's/\r//g' "$ACTIVE_NODE" > /tmp/sb_node_tmp.json
    fi

    awk '
    /__NODE_PLACEHOLDER__/ {
        while ((getline line < "/tmp/sb_node_tmp.json") > 0) {
            print line
        }
        print ","
        next
    }
    {print}
    ' "$BASE_CONFIG" > "$CONFIG_FILE"
    rm -f /tmp/sb_node_tmp.json

    # Validate with sing-box check when a runnable binary is available.
    if sb_bin_usable; then
        if ! "$SB_BIN" check -c "$CONFIG_FILE" >/tmp/sb_check.log 2>&1; then
            echo "[System] Generated config failed validation:" >> "$LOG_FILE"
            cat /tmp/sb_check.log >> "$LOG_FILE"
            rm -f /tmp/sb_check.log
            return 1
        fi
        rm -f /tmp/sb_check.log
    fi
    return 0
}

get_server_ip() {
    ACTIVE_NODE=$(get_active_node_path)
    [ -f "$ACTIVE_NODE" ] || return
    _proto=$(node_proto "$ACTIVE_NODE")
    if [ "$_proto" = "ipsec" ]; then
        extract_json_str "$ACTIVE_NODE" hostName
    else
        awk -F'"' '/"server":/ {print $4; exit}' "$ACTIVE_NODE"
    fi
}

have_strongswan() {
    command -v swanctl >/dev/null 2>&1 || command -v ipsec >/dev/null 2>&1
}

clean_iptables() {
    iptables -t mangle -D PREROUTING -j SB_TRANS 2>/dev/null
    iptables -t nat -D PREROUTING -p tcp -j SB_TRANS 2>/dev/null
    iptables -t mangle -F SB_TRANS 2>/dev/null
    iptables -t mangle -X SB_TRANS 2>/dev/null
    iptables -t nat -F SB_TRANS 2>/dev/null
    iptables -t nat -X SB_TRANS 2>/dev/null
    ip rule del fwmark 1 table 100 2>/dev/null
    ip route del local default dev lo table 100 2>/dev/null
}

clean_ipsec_nat() {
    iptables -t nat -D POSTROUTING -j SB_IPSEC_NAT 2>/dev/null
    iptables -t nat -F SB_IPSEC_NAT 2>/dev/null
    iptables -t nat -X SB_IPSEC_NAT 2>/dev/null
}

stop_ipsec() {
    clean_ipsec_nat
    if command -v swanctl >/dev/null 2>&1; then
        SWANCTL_DIR="$IPSEC_SWANCTL_DIR" swanctl --terminate --ike "$IPSEC_CONN" >/dev/null 2>&1 || true
        swanctl --terminate --ike "$IPSEC_CONN" >/dev/null 2>&1 || true
        rm -f "$IPSEC_SWANCTL" /etc/swanctl/conf.d/sbvpn.conf
        rm -rf "$IPSEC_SWANCTL_DIR"
    fi
    if command -v ipsec >/dev/null 2>&1; then
        ipsec down "$IPSEC_CONN" >/dev/null 2>&1 || true
        rm -f /etc/ipsec.d/sbvpn.conf /etc/ipsec.conf.sbvpn 2>/dev/null
        if [ -f /etc/ipsec.conf ] && grep -q "sbvpn-begin" /etc/ipsec.conf 2>/dev/null; then
            awk '/# sbvpn-begin/{skip=1} /# sbvpn-end/{skip=0; next} !skip{print}' /etc/ipsec.conf > /tmp/ipsec.conf.new
            mv /tmp/ipsec.conf.new /etc/ipsec.conf
            ipsec reload >/dev/null 2>&1 || true
        fi
    fi
    echo "[System] IPsec/IKEv2 terminated." >> "$LOG_FILE"
}

stop_sb() {
    [ -f "$WATCHDOG_PID" ] && kill -9 "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
    rm -f "$WATCHDOG_PID" "$WATCHDOG_STATUS_FILE"
    [ -f "$PID_FILE" ] && kill -9 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
    killall -9 sing-box 2>/dev/null
    clean_iptables
    stop_ipsec >/dev/null 2>&1
    echo "none" > "$PROTO_POINTER"
    echo "[System] VPN fully terminated." >> "$LOG_FILE"
}

# Decode base64 (std or url-safe) to a binary file.
b64_decode_to_file() {
    _b64="$1"
    _out="$2"
    # URL-safe → standard; BusyBox-safe (no GNU tr --).
    printf '%s' "$_b64" | sed 's/-/+/g; s/_/\//g' > /tmp/sb_b64.norm
    _len=$(wc -c < /tmp/sb_b64.norm | tr -dc '0-9')
    _pad=$(( _len % 4 ))
    if [ "$_pad" = "2" ]; then printf '==' >> /tmp/sb_b64.norm
    elif [ "$_pad" = "3" ]; then printf '=' >> /tmp/sb_b64.norm
    fi
    if command -v base64 >/dev/null 2>&1; then
        base64 -d < /tmp/sb_b64.norm > "$_out" 2>/dev/null \
            || base64 -d -i < /tmp/sb_b64.norm > "$_out" 2>/dev/null \
            || openssl base64 -d -A -in /tmp/sb_b64.norm -out "$_out" 2>/dev/null
    else
        openssl base64 -d -A -in /tmp/sb_b64.norm -out "$_out" 2>/dev/null
    fi
    rm -f /tmp/sb_b64.norm
    [ -s "$_out" ]
}

# Try openssl pkcs12 unpack with a given password into key/cert/ca PEMs.
# Uses -clcerts so we never mistake the CA for the client cert.
pkcs12_unpack() {
    _p12="$1"
    _pass="$2"
    _dir="$3"
    _err="$4"
    rm -f "$_dir/client.key" "$_dir/client.pem" "$_dir/ca.pem" "$_dir/all.pem"
    # Prefer split extract (client cert vs CA).
    if openssl pkcs12 -in "$_p12" -nodes -nocerts -passin "pass:$_pass" \
            -out "$_dir/client.key" >"$_err" 2>&1 \
        && openssl pkcs12 -in "$_p12" -nodes -clcerts -nokeys -passin "pass:$_pass" \
            -out "$_dir/client.pem" >>"$_err" 2>&1; then
        openssl pkcs12 -in "$_p12" -nodes -cacerts -nokeys -passin "pass:$_pass" \
            -out "$_dir/ca.pem" >>"$_err" 2>&1 || true
        if [ -s "$_dir/client.key" ] && [ -s "$_dir/client.pem" ]; then
            return 0
        fi
    fi
    # OpenSSL 3 legacy ciphers (ignore failure on 1.1.x).
    if openssl pkcs12 -help 2>&1 | grep -q -- '-legacy'; then
        if openssl pkcs12 -in "$_p12" -nodes -legacy -nocerts -passin "pass:$_pass" \
                -out "$_dir/client.key" >"$_err" 2>&1 \
            && openssl pkcs12 -in "$_p12" -nodes -legacy -clcerts -nokeys -passin "pass:$_pass" \
                -out "$_dir/client.pem" >>"$_err" 2>&1; then
            openssl pkcs12 -in "$_p12" -nodes -legacy -cacerts -nokeys -passin "pass:$_pass" \
                -out "$_dir/ca.pem" >>"$_err" 2>&1 || true
            if [ -s "$_dir/client.key" ] && [ -s "$_dir/client.pem" ]; then
                return 0
            fi
        fi
    fi
    return 1
}

# Prepare PKCS#12 material for an IPsec node id.
prepare_ipsec_material() {
    _id="$1"
    _node="$DIR_SB/node_${_id}.json"
    _dir="$IPSEC_DIR/$_id"
    mkdir -p "$_dir"
    _cert=$(extract_json_str "$_node" cert)
    _pass=$(extract_json_str "$_node" password)
    _host=$(extract_json_str "$_node" hostName)
    _user=$(extract_json_str "$_node" userName)

    if [ -z "$_cert" ] || [ -z "$_host" ]; then
        echo "[System] IPsec node $_id missing cert/hostName (cert_len=${#_cert})." >> "$LOG_FILE"
        echo "[System] If cert_len is tiny, BusyBox truncated it — need lua for extract." >> "$LOG_FILE"
        return 1
    fi
    echo "[System] IPsec material: host=$_host user=$_user cert_b64_len=${#_cert}" >> "$LOG_FILE"

    if ! command -v openssl >/dev/null 2>&1; then
        echo "[System] openssl required to unpack IPsec PKCS#12. Install openssl-util." >> "$LOG_FILE"
        return 1
    fi

    if ! b64_decode_to_file "$_cert" "$_dir/client.p12"; then
        echo "[System] Failed to base64-decode IPsec certificate (len=${#_cert})." >> "$LOG_FILE"
        return 1
    fi
    echo "[System] PKCS#12 bytes: $(wc -c < "$_dir/client.p12")" >> "$LOG_FILE"
    # Debug header (MIACAQM... = BER PFX)
    echo "[System] PKCS#12 asn1 header:" >> "$LOG_FILE"
    openssl asn1parse -inform DER -in "$_dir/client.p12" 2>&1 | head -n 8 >> "$LOG_FILE" || true

    # Try passwords: configured, empty, username (some panels).
    _unpacked=0
    for _try in "$_pass" "" "$_user"; do
        if pkcs12_unpack "$_dir/client.p12" "$_try" "$_dir" /tmp/sb_p12.err; then
            _pass="$_try"
            _unpacked=1
            echo "[System] PKCS#12 unpacked OK (pass_len=${#_try})" >> "$LOG_FILE"
            break
        fi
    done

    if [ "$_unpacked" != "1" ]; then
        echo "[System] openssl pkcs12 extract failed for all passwords:" >> "$LOG_FILE"
        cat /tmp/sb_p12.err >> "$LOG_FILE" 2>/dev/null
        openssl pkcs12 -info -in "$_dir/client.p12" -noout -passin pass: >> "$LOG_FILE" 2>&1 || true
        return 1
    fi

    # Refuse CA-as-client (Amnezia bags put CA alongside client).
    if openssl x509 -in "$_dir/client.pem" -noout -text 2>/dev/null \
        | grep -q 'CA:TRUE'; then
        echo "[System] client.pem looks like a CA — picking wrong cert from bag." >> "$LOG_FILE"
        openssl x509 -in "$_dir/client.pem" -noout -subject >> "$LOG_FILE" 2>&1
        return 1
    fi
    openssl x509 -in "$_dir/client.pem" -noout -subject >> "$LOG_FILE" 2>&1 || true

    chmod 600 "$_dir/client.key" "$_dir/client.p12"
    printf '%s\n' "$_host" > "$_dir/host"
    printf '%s\n' "$_user" > "$_dir/user"
    printf '%s\n' "$_pass" > "$_dir/pass"
    return 0
}

# Write a known-good strongswan.conf. Missing or broken includes cause:
#   "no files found matching '/etc/strongswan.conf'"
#   "abort initialization due to invalid configuration"
# even for `swanctl --version` / `ipsec version`.
write_strongswan_conf_file() {
    _sc="$1"
    _sdir=$(dirname "$_sc")
    mkdir -p "$_sdir" 2>/dev/null || true
    # Prefer absolute plugin includes that exist on OpenWrt; keep body minimal.
    cat > "$_sc" << 'SCONF'
# Generated by sb-manager — required for swanctl/charon (do not delete).
charon {
    load_modular = yes
    install_routes = yes
    install_virtual_ip = yes
    plugins {
        include /etc/strongswan.d/charon/*.conf
    }
}
SCONF
}

strongswan_tools_ok() {
    # Return 0 only if tools no longer abort on init.
    _out=$(swanctl --version 2>&1 || true)
    echo "$_out" | grep -q 'abort initialization' && return 1
    _out=$(ipsec version 2>&1 || true)
    echo "$_out" | grep -q 'abort initialization' && return 1
    return 0
}

ensure_strongswan_conf() {
    mkdir -p /etc/strongswan.d/charon /etc/swanctl/conf.d /etc/ipsec.d/cacerts \
             /etc/ipsec.d/certs /etc/ipsec.d/private /etc/ipsec.d/aacerts \
             /etc/strongswan/strongswan.d/charon 2>/dev/null || true
    [ -f /etc/strongswan.d/charon/sb-manager.conf ] \
        || echo "# sb-manager placeholder" > /etc/strongswan.d/charon/sb-manager.conf

    # Always ensure both common paths exist (OEM builds differ on compile-time path).
    for _sc in /etc/strongswan.conf /etc/strongswan/strongswan.conf; do
        if [ ! -f "$_sc" ]; then
            echo "[System] Creating missing $_sc" >> "$LOG_FILE"
            write_strongswan_conf_file "$_sc"
        fi
    done

    if strongswan_tools_ok; then
        echo "[System] strongswan.conf OK (swanctl/ipsec init)." >> "$LOG_FILE"
        return 0
    fi

    echo "[System] strongSwan tools abort on init — rewriting strongswan.conf" >> "$LOG_FILE"
    for _sc in /etc/strongswan.conf /etc/strongswan/strongswan.conf; do
        # Backup once
        [ -f "$_sc" ] && [ ! -f "${_sc}.sb-bak" ] && cp -f "$_sc" "${_sc}.sb-bak" 2>/dev/null || true
        write_strongswan_conf_file "$_sc"
    done

    if strongswan_tools_ok; then
        echo "[System] strongswan.conf rewrite fixed tool init." >> "$LOG_FILE"
        return 0
    fi

    # Last resort: empty file (NixOS/RHEL fix for missing path).
    echo "[System] Falling back to empty strongswan.conf" >> "$LOG_FILE"
    for _sc in /etc/strongswan.conf /etc/strongswan/strongswan.conf; do
        echo "# sb-manager empty strongswan.conf" > "$_sc"
    done
    if strongswan_tools_ok; then
        echo "[System] Empty strongswan.conf accepted." >> "$LOG_FILE"
        return 0
    fi
    echo "[System] WARNING: swanctl/ipsec still abort after conf fix:" >> "$LOG_FILE"
    swanctl --version >> "$LOG_FILE" 2>&1 || true
    ipsec version >> "$LOG_FILE" 2>&1 || true
    ls -la /etc/strongswan.conf /etc/strongswan/strongswan.conf >> "$LOG_FILE" 2>&1 || true
    return 1
}

# Stop any half-dead starter/charon so we can start clean.
stop_strongswan_daemons() {
    ipsec stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/ipsec ] && /etc/init.d/ipsec stop >/dev/null 2>&1 || true
    [ -x /etc/init.d/swanctl ] && /etc/init.d/swanctl stop >/dev/null 2>&1 || true
    killall -q charon starter charon-systemd 2>/dev/null || true
    sleep 1
}

# Start charon so swanctl has a vici socket.
start_charon_daemon() {
    ensure_strongswan_conf
    # Prefer swanctl init (vici), then ipsec starter, then raw charon binary.
    if [ -x /etc/init.d/swanctl ]; then
        /etc/init.d/swanctl enable >/dev/null 2>&1 || true
        /etc/init.d/swanctl start >>"$LOG_FILE" 2>&1 || true
    fi
    if [ -x /etc/init.d/ipsec ]; then
        /etc/init.d/ipsec enable >/dev/null 2>&1 || true
        /etc/init.d/ipsec start >>"$LOG_FILE" 2>&1 || true
    fi
    ipsec start >>"$LOG_FILE" 2>&1 || true
    # Raw charon if still no vici socket
    if [ ! -S /var/run/charon.vici ] && [ ! -S /var/run/charon.ctl ]; then
        _charon=""
        for _c in /usr/lib/ipsec/charon /usr/libexec/ipsec/charon /usr/sbin/charon; do
            [ -x "$_c" ] && _charon="$_c" && break
        done
        if [ -n "$_charon" ]; then
            echo "[System] Starting $_charon directly..." >> "$LOG_FILE"
            "$_charon" >>"$LOG_FILE" 2>&1 &
            sleep 2
        fi
    fi
    sleep 1
    if [ -S /var/run/charon.vici ] || [ -S /var/run/charon.ctl ]; then
        echo "[System] charon vici socket is up." >> "$LOG_FILE"
        return 0
    fi
    echo "[System] WARNING: no charon vici socket after start attempts." >> "$LOG_FILE"
    ls -la /var/run/charon* >> "$LOG_FILE" 2>&1 || true
    return 1
}

# Build an isolated SWANCTL_DIR so OEM /etc/swanctl junk cannot break --load-all.
prepare_swanctl_dir() {
    _id="$1"
    _dir="$IPSEC_DIR/$_id"
    rm -rf "$IPSEC_SWANCTL_DIR"
    mkdir -p "$IPSEC_SWANCTL_DIR/x509" "$IPSEC_SWANCTL_DIR/private" \
             "$IPSEC_SWANCTL_DIR/x509ca" "$IPSEC_SWANCTL_DIR/conf.d"
    cp -f "$_dir/client.pem" "$IPSEC_SWANCTL_DIR/x509/sbvpn_client.pem"
    cp -f "$_dir/client.key" "$IPSEC_SWANCTL_DIR/private/sbvpn_client.key"
    if [ -s "$_dir/ca.pem" ]; then
        cp -f "$_dir/ca.pem" "$IPSEC_SWANCTL_DIR/x509ca/sbvpn_ca.pem"
    fi
    chmod 600 "$IPSEC_SWANCTL_DIR/private/sbvpn_client.key"
    # Minimal main file — only our connection.
    echo "include conf.d/*.conf" > "$IPSEC_SWANCTL_DIR/swanctl.conf"
    # Also mirror into system conf.d for visibility/debugging.
    mkdir -p /etc/swanctl/conf.d
    # System swanctl.conf must exist and include conf.d
    if [ ! -f /etc/swanctl/swanctl.conf ] || ! grep -q 'conf.d' /etc/swanctl/swanctl.conf 2>/dev/null; then
        echo "include conf.d/*.conf" > /etc/swanctl/swanctl.conf
    fi
}

# Write a minimal Amnezia-compatible swanctl conn into the isolated dir.
write_swanctl_conn() {
    _id="$1"
    _dir="$IPSEC_DIR/$_id"
    _node="$DIR_SB/node_${_id}.json"
    _host=$(cat "$_dir/host")
    _user=$(cat "$_dir/user")
    _ike=$(extract_json_str "$_node" ikeProposal)
    _esp=$(extract_json_str "$_node" espProposal)
    _use_pss="${2:-0}"
    _variant="${3:-full}"
    [ -z "$_ike" ] && _ike="aes256-sha256-modp2048"
    [ -z "$_esp" ] && _esp="aes128gcm16"

    prepare_swanctl_dir "$_id"
    _cfg="$IPSEC_SWANCTL_DIR/conf.d/sbvpn.conf"
    IPSEC_SWANCTL="$_cfg"

    {
        echo "connections {"
        echo "    ${IPSEC_CONN} {"
        echo "        version = 2"
        echo "        remote_addrs = ${_host}"
        # Variants strip options that older/OEM strongSwan reject as "invalid configuration".
        if [ "$_variant" = "full" ] || [ "$_variant" = "vip" ]; then
            echo "        vips = 0.0.0.0"
        fi
        if [ "$_variant" = "full" ] || [ "$_variant" = "vip" ] || [ "$_variant" = "basic" ]; then
            echo "        proposals = ${_ike}"
        fi
        if [ "$_variant" = "full" ]; then
            echo "        encap = yes"
        fi
        echo "        local {"
        echo "            auth = pubkey"
        echo "            certs = sbvpn_client.pem"
        [ -n "$_user" ] && echo "            id = ${_user}"
        [ "$_use_pss" = "1" ] && echo "            rsa_pss = yes"
        echo "        }"
        echo "        remote {"
        echo "            auth = pubkey"
        if [ "$_variant" = "full" ] || [ "$_variant" = "vip" ]; then
            [ -n "$_host" ] && echo "            id = ${_host}"
        fi
        [ -s "$_dir/ca.pem" ] && echo "            cacerts = sbvpn_ca.pem"
        echo "        }"
        echo "        children {"
        echo "            ${IPSEC_CONN} {"
        echo "                remote_ts = 0.0.0.0/0"
        if [ "$_variant" = "full" ] || [ "$_variant" = "vip" ] || [ "$_variant" = "basic" ]; then
            echo "                esp_proposals = ${_esp}"
        fi
        echo "                start_action = none"
        echo "            }"
        echo "        }"
        echo "    }"
        echo "}"
        echo "secrets {"
        echo "    private-sbvpn {"
        echo "        file = sbvpn_client.key"
        echo "    }"
        echo "}"
    } > "$_cfg"

    cp -f "$_cfg" /etc/swanctl/conf.d/sbvpn.conf 2>/dev/null || true
    echo "[System] sb-manager $SB_MANAGER_VERSION swanctl variant=$_variant ike=$_ike esp=$_esp pss=$_use_pss" >> "$LOG_FILE"
}

write_ipsec_conf_conn() {
    _id="$1"
    _dir="$IPSEC_DIR/$_id"
    _host=$(cat "$_dir/host")
    _user=$(cat "$_dir/user")
    mkdir -p /etc/ipsec.d/certs /etc/ipsec.d/private /etc/ipsec.d/cacerts
    cp -f "$_dir/client.pem" /etc/ipsec.d/certs/sbvpn_client.pem
    cp -f "$_dir/client.key" /etc/ipsec.d/private/sbvpn_client.key
    [ -s "$_dir/ca.pem" ] && cp -f "$_dir/ca.pem" /etc/ipsec.d/cacerts/sbvpn_ca.pem
    chmod 600 /etc/ipsec.d/private/sbvpn_client.key

    _leftid="%any"
    [ -n "$_user" ] && _leftid="$_user"

    # Prefer PKCS#12 in secrets (works for RSA/EC). Fall back to key file.
    _p12abs="$IPSEC_DIR/$_id/client.p12"
    _pass=$(cat "$_dir/pass" 2>/dev/null)
    {
        echo "# sbvpn-secrets-begin"
        if [ -s "$_p12abs" ]; then
            echo ": P12 ${_p12abs} \"${_pass}\""
        else
            echo ": RSA sbvpn_client.key"
            echo ": ECDSA sbvpn_client.key"
        fi
        echo "# sbvpn-secrets-end"
    } > /tmp/sb_ipsec.secrets.frag
    if [ -f /etc/ipsec.secrets ]; then
        awk '/# sbvpn-secrets-begin/{skip=1} /# sbvpn-secrets-end/{skip=0; next} !skip{print}' \
            /etc/ipsec.secrets > /tmp/ipsec.secrets.base 2>/dev/null \
            || cp /etc/ipsec.secrets /tmp/ipsec.secrets.base
        cat /tmp/ipsec.secrets.base /tmp/sb_ipsec.secrets.frag > /etc/ipsec.secrets
    else
        cp /tmp/sb_ipsec.secrets.frag /etc/ipsec.secrets
    fi
    chmod 600 /etc/ipsec.secrets

    # Inject / replace conn block in ipsec.conf
    if [ -f /etc/ipsec.conf ]; then
        awk '/# sbvpn-begin/{skip=1} /# sbvpn-end/{skip=0; next} !skip{print}' /etc/ipsec.conf > /tmp/ipsec.conf.base
    else
        echo "config setup" > /tmp/ipsec.conf.base
        echo "  uniqueids=never" >> /tmp/ipsec.conf.base
    fi
    cat >> /tmp/ipsec.conf.base << EOF

# sbvpn-begin
conn $IPSEC_CONN
  keyexchange=ikev2
  auto=start
  type=tunnel
  left=%defaultroute
  leftauth=pubkey
  leftcert=sbvpn_client.pem
  leftid=$_leftid
  leftsourceip=%config
  right=$_host
  rightauth=pubkey
  rightid=%any
  rightsubnet=0.0.0.0/0
  ike=aes256-sha256-modp2048
  esp=aes128gcm16
  dpdaction=restart
  dpddelay=30s
  fragmentation=yes
  forceencaps=yes
# sbvpn-end
EOF
    mv /tmp/ipsec.conf.base /etc/ipsec.conf
}

setup_ipsec_lan_nat() {
    # SNAT LAN clients to the IPsec virtual IP so policy-based tunnel covers them.
    clean_ipsec_nat
    _vip=""
    # Prefer address from swanctl / xfrm / ipsec
    if command -v swanctl >/dev/null 2>&1; then
        _vip=$(swanctl --list-sas 2>/dev/null | awk '/local.*SPI|vip|===/{next} /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/{
            for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
        }')
    fi
    if [ -z "$_vip" ]; then
        _vip=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ && $2 !~ /^192\.168\./ && $2 !~ /^10\./ {
            split($2,a,"/"); print a[1]; exit
        }')
    fi
    # Also try XFRM interface
    if [ -z "$_vip" ]; then
        _vip=$(ip -4 addr show 2>/dev/null | awk '/xfrm|ipsec|vti/ {getline; if ($1=="inet"){split($2,a,"/"); print a[1]; exit}}')
    fi

    SERVER_IP=$(get_server_ip)
    iptables -t nat -N SB_IPSEC_NAT 2>/dev/null
    iptables -t nat -F SB_IPSEC_NAT
    # Bypass private / VPN server
    iptables -t nat -A SB_IPSEC_NAT -d 0.0.0.0/8 -j RETURN
    iptables -t nat -A SB_IPSEC_NAT -d 10.0.0.0/8 -j RETURN
    iptables -t nat -A SB_IPSEC_NAT -d 127.0.0.0/8 -j RETURN
    iptables -t nat -A SB_IPSEC_NAT -d 169.254.0.0/16 -j RETURN
    iptables -t nat -A SB_IPSEC_NAT -d 172.16.0.0/12 -j RETURN
    iptables -t nat -A SB_IPSEC_NAT -d 192.168.0.0/16 -j RETURN
    iptables -t nat -A SB_IPSEC_NAT -d 224.0.0.0/4 -j RETURN
    [ -n "$SERVER_IP" ] && iptables -t nat -A SB_IPSEC_NAT -d "$SERVER_IP" -j RETURN 2>/dev/null

    if [ -n "$_vip" ]; then
        iptables -t nat -A SB_IPSEC_NAT -j SNAT --to-source "$_vip"
        echo "[System] IPsec LAN SNAT to VIP $_vip" >> "$LOG_FILE"
    else
        iptables -t nat -A SB_IPSEC_NAT -j MASQUERADE
        echo "[System] IPsec LAN MASQUERADE (VIP not detected yet)" >> "$LOG_FILE"
    fi
    iptables -t nat -I POSTROUTING -j SB_IPSEC_NAT
}

# Run swanctl against our isolated SWANCTL_DIR only.
# Force STRONGSWAN_CONF so OEM path mismatches cannot re-trigger init abort.
swanctl_iso() {
    STRONGSWAN_CONF="${STRONGSWAN_CONF:-/etc/strongswan.conf}" \
    SWANCTL_DIR="$IPSEC_SWANCTL_DIR" swanctl "$@"
}

try_start_ipsec_stroke() {
    _id="$1"
    command -v ipsec >/dev/null 2>&1 || return 1
    echo "[System] Trying classic ipsec/stroke backend..." >> "$LOG_FILE"
    write_ipsec_conf_conn "$_id"
    : > /tmp/sb_ipsec.err
    stop_strongswan_daemons
    start_charon_daemon >>/tmp/sb_ipsec.err 2>&1 || true
    # starter must be running ("Reloading ... starter is not running")
    if [ -x /etc/init.d/ipsec ]; then
        /etc/init.d/ipsec enable >>/tmp/sb_ipsec.err 2>&1 || true
        /etc/init.d/ipsec start >>/tmp/sb_ipsec.err 2>&1 || true
    fi
    ipsec start >>/tmp/sb_ipsec.err 2>&1 || true
    sleep 1
    ipsec rereadall >>/tmp/sb_ipsec.err 2>&1 || true
    ipsec reload >>/tmp/sb_ipsec.err 2>&1 || true
    ipsec up "$IPSEC_CONN" >>/tmp/sb_ipsec.err 2>&1 || true
    sleep 3
    if is_ipsec_running; then
        echo "[System] ipsec/stroke connected." >> "$LOG_FILE"
        return 0
    fi
    echo "[System] ipsec/stroke failed:" >> "$LOG_FILE"
    cat /tmp/sb_ipsec.err >> "$LOG_FILE" 2>/dev/null
    ipsec statusall >> "$LOG_FILE" 2>&1 || true
    return 1
}

try_start_ipsec_swanctl() {
    _id="$1"
    command -v swanctl >/dev/null 2>&1 || return 1
    echo "[System] Trying swanctl backend (isolated SWANCTL_DIR=$IPSEC_SWANCTL_DIR)..." >> "$LOG_FILE"

    stop_strongswan_daemons
    start_charon_daemon || true

    # Validate PEMs before load.
    if ! openssl x509 -in "$IPSEC_DIR/$_id/client.pem" -noout >/tmp/sb_pem.err 2>&1; then
        echo "[System] client.pem invalid:" >> "$LOG_FILE"
        cat /tmp/sb_pem.err >> "$LOG_FILE"
        return 1
    fi
    openssl x509 -in "$IPSEC_DIR/$_id/client.pem" -noout -subject -dates >> "$LOG_FILE" 2>&1 || true

    _loaded=0
    # Try increasingly compatible config variants.
    for _variant in min basic vip full; do
        for _pss in 0 1; do
            # rsa_pss only meaningful on fuller variants
            [ "$_pss" = "1" ] && [ "$_variant" = "min" ] && continue
            write_swanctl_conn "$_id" "$_pss" "$_variant"
            : > /tmp/sb_swan.err
            if swanctl_iso --load-all >>/tmp/sb_swan.err 2>&1 \
                || { swanctl_iso --load-creds >>/tmp/sb_swan.err 2>&1 \
                     && swanctl_iso --load-conns >>/tmp/sb_swan.err 2>&1; }; then
                if swanctl_iso --list-conns 2>/dev/null | grep -q "$IPSEC_CONN"; then
                    _loaded=1
                    echo "[System] swanctl loaded OK (variant=$_variant pss=$_pss)" >> "$LOG_FILE"
                    break 2
                fi
            fi
            # If still aborting on strongswan.conf, stop wasting variants.
            if grep -q 'abort initialization' /tmp/sb_swan.err 2>/dev/null; then
                echo "[System] swanctl still aborts on init (strongswan.conf):" >> "$LOG_FILE"
                cat /tmp/sb_swan.err >> "$LOG_FILE"
                ensure_strongswan_conf || true
                # Retry once after rewrite
                : > /tmp/sb_swan.err
                if swanctl_iso --load-all >>/tmp/sb_swan.err 2>&1; then
                    if swanctl_iso --list-conns 2>/dev/null | grep -q "$IPSEC_CONN"; then
                        _loaded=1
                        echo "[System] swanctl loaded OK after conf rewrite (variant=$_variant)" >> "$LOG_FILE"
                        break 2
                    fi
                fi
                echo "[System] swanctl load rejected variant=$_variant pss=$_pss:" >> "$LOG_FILE"
                cat /tmp/sb_swan.err >> "$LOG_FILE"
                echo "[System] --- config dump ---" >> "$LOG_FILE"
                cat "$IPSEC_SWANCTL_DIR/conf.d/sbvpn.conf" >> "$LOG_FILE" 2>/dev/null
                break 2
            fi
            echo "[System] swanctl load rejected variant=$_variant pss=$_pss:" >> "$LOG_FILE"
            cat /tmp/sb_swan.err >> "$LOG_FILE"
            echo "[System] --- config dump ---" >> "$LOG_FILE"
            cat "$IPSEC_SWANCTL_DIR/conf.d/sbvpn.conf" >> "$LOG_FILE" 2>/dev/null
        done
    done

    if [ "$_loaded" != "1" ]; then
        echo "[System] All swanctl variants failed to load." >> "$LOG_FILE"
        return 1
    fi

    if ! is_ipsec_running; then
        : > /tmp/sb_swan_init.err
        swanctl_iso --initiate --child "$IPSEC_CONN" >>/tmp/sb_swan_init.err 2>&1 \
            || swanctl_iso --initiate --ike "$IPSEC_CONN" >>/tmp/sb_swan_init.err 2>&1 \
            || true
        sleep 3
    fi
    if is_ipsec_running; then
        echo "[System] swanctl connected." >> "$LOG_FILE"
        return 0
    fi
    echo "[System] swanctl initiate failed:" >> "$LOG_FILE"
    cat /tmp/sb_swan_init.err >> "$LOG_FILE" 2>/dev/null
    SWANCTL_DIR="$IPSEC_SWANCTL_DIR" swanctl --list-conns >> "$LOG_FILE" 2>&1 || true
    SWANCTL_DIR="$IPSEC_SWANCTL_DIR" swanctl --list-creds >> "$LOG_FILE" 2>&1 || true
    return 1
}

start_ipsec() {
    echo "[System] Amnezia IPsec start via sb-manager $SB_MANAGER_VERSION" >> "$LOG_FILE"

    if ! have_strongswan; then
        echo "[System] strongSwan not installed (no swanctl/ipsec in PATH)." >> "$LOG_FILE"
        return 1
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        echo "[System] openssl not found. Install openssl-util." >> "$LOG_FILE"
        return 1
    fi

    # MUST fix strongswan.conf before any swanctl/ipsec call — otherwise every
    # backend fails with identical "abort initialization due to invalid configuration".
    ensure_strongswan_conf || true

    _id=$(cat "$ACTIVE_NODE_POINTER" 2>/dev/null)
    if [ -z "$_id" ]; then
        echo "[System] No active node for IPsec." >> "$LOG_FILE"
        return 1
    fi
    if ! prepare_ipsec_material "$_id"; then
        return 1
    fi

    # Prefer swanctl (vici) after conf fix; stroke as fallback for OEM starter builds.
    _ok=0
    if try_start_ipsec_swanctl "$_id"; then
        _ok=1
    elif try_start_ipsec_stroke "$_id"; then
        _ok=1
    fi

    if [ "$_ok" != "1" ]; then
        echo "[System] Amnezia IPsec failed on both swanctl and ipsec backends." >> "$LOG_FILE"
        echo "[System] Diagnostics: swanctl=$(command -v swanctl) ipsec=$(command -v ipsec)" >> "$LOG_FILE"
        echo "[System] strongswan.conf paths:" >> "$LOG_FILE"
        ls -la /etc/strongswan.conf /etc/strongswan/strongswan.conf >> "$LOG_FILE" 2>&1 || true
        swanctl --version >> "$LOG_FILE" 2>&1 || true
        ipsec version >> "$LOG_FILE" 2>&1 || true
        return 1
    fi

    echo "ipsec" > "$PROTO_POINTER"
    if [ "$(get_mode)" = "tunnel" ]; then
        setup_ipsec_lan_nat
    fi
    echo "[System] Amnezia IPsec/IKEv2 connected to $(cat "$IPSEC_DIR/$_id/host")." >> "$LOG_FILE"
    start_watchdog
    return 0
}

start_sb() {
    ACTIVE_NODE=$(get_active_node_path)
    _proto=$(node_proto "$ACTIVE_NODE")

    # Always tear down the other engine first.
    stop_sb >/dev/null 2>&1

    if [ "$_proto" = "ipsec" ]; then
        start_ipsec
        return $?
    fi

    if ! resolve_sb_bin || ! sb_bin_usable; then
        report_sb_bin_error
        return 1
    fi
    if ! build_final_config; then
        echo "[System] Aborting start: config build/validation failed." >> "$LOG_FILE"
        return 1
    fi
    SERVER_IP=$(get_server_ip)

    sysctl -w net.core.netdev_max_backlog=10000 >/dev/null 2>&1
    ulimit -n 65535 >/dev/null 2>&1

    CURRENT_MODE=$(get_mode)
    if [ "$CURRENT_MODE" = "tunnel" ]; then
        iptables -t mangle -N SB_TRANS
        iptables -t nat -N SB_TRANS

        ip rule add fwmark 1 table 100 2>/dev/null
        ip route add local default dev lo table 100 2>/dev/null

        # Bypass Local Ranges
        iptables -t mangle -A SB_TRANS -d 0.0.0.0/8 -j RETURN
        iptables -t mangle -A SB_TRANS -d 127.0.0.0/8 -j RETURN
        iptables -t mangle -A SB_TRANS -d 169.254.0.0/16 -j RETURN
        iptables -t mangle -A SB_TRANS -d 172.16.0.0/12 -j RETURN
        iptables -t mangle -A SB_TRANS -d 192.168.0.0/16 -j RETURN
        iptables -t mangle -A SB_TRANS -d 224.0.0.0/4 -j RETURN
        iptables -t mangle -A SB_TRANS -d 240.0.0.0/4 -j RETURN
        [ -n "$SERVER_IP" ] && iptables -t mangle -A SB_TRANS -d "$SERVER_IP" -j RETURN 2>/dev/null

        iptables -t nat -A SB_TRANS -d 0.0.0.0/8 -j RETURN
        iptables -t nat -A SB_TRANS -d 127.0.0.0/8 -j RETURN
        iptables -t nat -A SB_TRANS -d 169.254.0.0/16 -j RETURN
        iptables -t nat -A SB_TRANS -d 172.16.0.0/12 -j RETURN
        iptables -t nat -A SB_TRANS -d 192.168.0.0/16 -j RETURN
        iptables -t nat -A SB_TRANS -d 224.0.0.0/4 -j RETURN
        iptables -t nat -A SB_TRANS -d 240.0.0.0/4 -j RETURN
        [ -n "$SERVER_IP" ] && iptables -t nat -A SB_TRANS -d "$SERVER_IP" -j RETURN 2>/dev/null

        iptables -t mangle -A SB_TRANS -p udp --dport 53 -j TPROXY --on-port 1053 --tproxy-mark 1
        iptables -t mangle -A SB_TRANS -p udp -j TPROXY --on-port 1081 --tproxy-mark 1
        iptables -t nat -A SB_TRANS -p tcp --dport 53 -j REDIRECT --to-ports 1053
        iptables -t nat -A SB_TRANS -p tcp -j REDIRECT --to-ports 1081

        iptables -t mangle -A PREROUTING -j SB_TRANS
        iptables -t nat -A PREROUTING -p tcp -j SB_TRANS
        echo "[System] Sing-Box Routing Active." >> "$LOG_FILE"
    fi

    echo "vless" > "$PROTO_POINTER"
    start-stop-daemon -S -b -m -p "$PID_FILE" -x /bin/sh -- -c "export GOMEMLIMIT=150MiB GOGC=100; exec $SB_BIN run -c '$CONFIG_FILE' >> '$LOG_FILE' 2>&1"
    start_watchdog
}

maint_run() {
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    if is_vpn_running; then stop_sb; sleep 2; start_sb; fi
}

daemon_watchdog() {
    echo $$ > "$WATCHDOG_PID"
    while true; do
        sleep 15
        if is_vpn_running; then echo "green" > "$WATCHDOG_STATUS_FILE"
        else echo "offline" > "$WATCHDOG_STATUS_FILE"; exit 0; fi
    done
}

start_watchdog() {
    [ -f "$WATCHDOG_PID" ] && kill -9 "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
    if [ "$(cat "$WATCHDOG_FLAG" 2>/dev/null)" = "1" ]; then /usr/bin/sb-manager daemon_watchdog & fi
}

case "$1" in
    version) echo "$SB_MANAGER_VERSION"; exit 0 ;;
    start) start_sb; exit 0 ;;
    stop) stop_sb; exit 0 ;;
    restart) stop_sb; sleep 1; start_sb; exit 0 ;;
    status)
        if [ "$(cat "$PROTO_POINTER" 2>/dev/null)" = "ipsec" ]; then
            if is_ipsec_running; then echo "Running (Amnezia IPsec)"; else echo "Stopped"; fi
        else
            if is_sb_running; then echo "Running"; else echo "Stopped"; fi
        fi
        exit 0
        ;;
    active) cat "$ACTIVE_NODE_POINTER" 2>/dev/null; exit 0 ;;
    proto) cat "$PROTO_POINTER" 2>/dev/null || echo "none"; exit 0 ;;
    switch) echo "$2" > "$ACTIVE_NODE_POINTER"; exit 0 ;;
    addnode)
        if [ -z "$2" ] || [ -z "$3" ] || [ ! -f "$3" ]; then
            echo "Usage: sb-manager addnode <id> <linkfile>" >&2
            exit 1
        fi
        parse_link_to_json "$3" > "$DIR_SB/node_$2.json"
        if [ ! -s "$DIR_SB/node_$2.json" ]; then
            rm -f "$DIR_SB/node_$2.json"
            echo "Failed to parse config (expected vless://, vpn://, or Amnezia IPsec JSON)" >&2
            exit 1
        fi
        # For IPsec: unpack PKCS#12 now so Activate does not depend on re-parsing
        # a huge cert line (and so we fail early with a clear error).
        if [ "$(node_proto "$DIR_SB/node_$2.json")" = "ipsec" ]; then
            if ! prepare_ipsec_material "$2"; then
                rm -f "$DIR_SB/node_$2.json"
                echo "Failed to unpack Amnezia PKCS#12 (see /var/log/singbox.log)" >&2
                exit 1
            fi
        fi
        exit 0
        ;;
    delnode)
        rm -f "$DIR_SB/node_$2.json"
        rm -rf "$IPSEC_DIR/$2"
        exit 0
        ;;
    listnodes)
        for f in "$DIR_SB"/node_*.json; do
            [ -f "$f" ] || continue
            base=$(basename "$f")
            base="${base#node_}"
            base="${base%.json}"
            echo "$base"
        done
        exit 0
        ;;
    nodetype)
        # Print protocol of a node id (or active node if none given)
        if [ -n "$2" ]; then
            node_proto "$DIR_SB/node_$2.json"
        else
            node_proto "$(get_active_node_path)"
        fi
        exit 0
        ;;
    mode_toggle) echo "$2" > "$MODE_POINTER"; exit 0 ;;
    mode_status) get_mode; exit 0 ;;
    maint_run) maint_run; exit 0 ;;
    watchdog_toggle) echo "$2" > "$WATCHDOG_FLAG"; exit 0 ;;
    watchdog_status) cat "$WATCHDOG_FLAG" 2>/dev/null || echo "0"; exit 0 ;;
    led_status) cat "$WATCHDOG_STATUS_FILE" 2>/dev/null || echo "offline"; exit 0 ;;
    daemon_watchdog) daemon_watchdog; exit 0 ;;
    *)
        echo "Usage: sb-manager {start|stop|restart|status|active|switch <id>|addnode <id> <linkfile>|delnode <id>|listnodes|nodetype [id]|mode_toggle <tunnel|proxy>|mode_status|watchdog_toggle <0|1>|watchdog_status|led_status}"
        exit 1
        ;;
esac
SB_MGR_EOF
chmod +x /usr/bin/sb-manager
log "sb-manager installed: $(/usr/bin/sb-manager version 2>/dev/null || echo unknown)"

log "5b. Installing sb-vpn-decode (Amnezia vpn:// decoder)..."
cat << 'SB_VPNDEC_EOF' > /usr/bin/sb-vpn-decode
#!/usr/bin/env python3
"""Decode Amnezia vpn:// share links (qCompress + Base64URL) to JSON on stdout.

Usage:
  sb-vpn-decode 'vpn://AAA...'
  sb-vpn-decode /path/to/file.txt
  echo 'vpn://...' | sb-vpn-decode
"""
from __future__ import print_function

import base64
import json
import sys
import zlib


def read_input(argv):
    if len(argv) >= 2:
        arg = argv[1]
        if arg.startswith("vpn://") or arg.startswith("VPN://"):
            return ("vpn", arg.strip())
        try:
            with open(arg, "r") as fh:
                data = fh.read().strip()
        except IOError as exc:
            sys.stderr.write("cannot read %s: %s\n" % (arg, exc))
            sys.exit(2)
        if data.lower().startswith("vpn://"):
            return ("vpn", data)
        return ("json", data)
    data = sys.stdin.read().strip()
    if not data:
        sys.stderr.write("usage: sb-vpn-decode <vpn://...|file>\n")
        sys.exit(2)
    if data.lower().startswith("vpn://"):
        return ("vpn", data)
    return ("json", data)


def b64url_decode(s):
    s = s.replace("-", "+").replace("_", "/")
    pad = (-len(s)) % 4
    if pad:
        s += "=" * pad
    return base64.b64decode(s)


def quncompress(blob):
    """Qt qUncompress: 4-byte big-endian size + zlib payload."""
    if len(blob) < 6:
        raise ValueError("payload too short")
    # Prefer Qt layout; fall back to raw zlib / plain JSON.
    try:
        return zlib.decompress(blob[4:])
    except zlib.error:
        try:
            return zlib.decompress(blob)
        except zlib.error:
            return blob


def extract_ipsec_payload(obj):
    """Prefer IKEv2 last_config / nested config from Amnezia server JSON."""
    if not isinstance(obj, dict):
        return obj

    # Already a flat IPsec export
    if "cert" in obj and ("hostName" in obj or "addr" in obj):
        return obj

    containers = obj.get("containers") or []
    default = obj.get("defaultContainer") or ""

    def from_container(c):
        if not isinstance(c, dict):
            return None
        ike = c.get("ikev2") or c.get("ipsec") or {}
        if not isinstance(ike, dict):
            return None
        last = ike.get("last_config")
        if not last:
            return None
        if isinstance(last, str):
            try:
                last_obj = json.loads(last)
            except ValueError:
                return None
        elif isinstance(last, dict):
            last_obj = last
        else:
            return None
        # Nested "config" string is the canonical Amnezia client export.
        nested = last_obj.get("config")
        if isinstance(nested, str) and nested.strip().startswith("{"):
            try:
                return json.loads(nested)
            except ValueError:
                pass
        # Promote top-level fields; fill host from server if missing.
        out = dict(last_obj)
        if "hostName" not in out and obj.get("hostName"):
            out["hostName"] = obj["hostName"]
        if "password" not in out:
            out["password"] = ""
        if "userName" not in out and out.get("clientId"):
            out["userName"] = out["clientId"]
        return out

    # Prefer defaultContainer match
    preferred = None
    for c in containers:
        name = (c or {}).get("container") or ""
        if default and name == default:
            preferred = from_container(c)
            if preferred:
                return preferred
        if name in ("amnezia-ipsec", "amnezia-ikev2", "ipsec"):
            preferred = preferred or from_container(c)

    if preferred:
        return preferred

    for c in containers:
        got = from_container(c)
        if got:
            return got

    return obj


def main():
    kind, raw = read_input(sys.argv)
    try:
        if kind == "vpn":
            if raw.lower().startswith("vpn://"):
                raw = raw[6:]
            blob = b64url_decode(raw)
            plain = quncompress(blob)
            if isinstance(plain, bytes):
                text = plain.decode("utf-8")
            else:
                text = plain
            obj = json.loads(text)
        else:
            obj = json.loads(raw)
    except Exception as exc:
        sys.stderr.write("failed to decode Amnezia config: %s\n" % exc)
        sys.exit(1)

    payload = extract_ipsec_payload(obj)
    if not isinstance(payload, dict) or not payload.get("cert"):
        sys.stderr.write("no IPsec/IKEv2 cert found in Amnezia config\n")
        sys.exit(1)
    json.dump(payload, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
SB_VPNDEC_EOF
chmod +x /usr/bin/sb-vpn-decode

log "6. Installing LuCI UI..."
cat << 'SB_LUA_EOF' > /usr/lib/lua/luci/controller/singbox.lua
-- LuCI controller for Sing-Box VPN Manager
-- api_version bumped when breaking UI/controller fixes ship (check status JSON).
module("luci.controller.singbox", package.seeall)

local SB_API_VERSION = 4

function index()
    if not nixio.fs.access("/usr/bin/sb-manager") then
        return
    end

    entry({"admin", "services", "singbox"}, template("singbox_panel"), _("Sing-Box VPN"), 60).dependent = false

    entry({"admin", "services", "singbox", "status"}, call("action_status")).leaf = true
    entry({"admin", "services", "singbox", "start"}, call("action_start")).leaf = true
    entry({"admin", "services", "singbox", "stop"}, call("action_stop")).leaf = true
    entry({"admin", "services", "singbox", "restart"}, call("action_restart")).leaf = true
    entry({"admin", "services", "singbox", "switch"}, call("action_switch")).leaf = true
    entry({"admin", "services", "singbox", "addnode"}, call("action_addnode")).leaf = true
    entry({"admin", "services", "singbox", "delnode"}, call("action_delnode")).leaf = true
    entry({"admin", "services", "singbox", "listnodes"}, call("action_listnodes")).leaf = true
    entry({"admin", "services", "singbox", "mode"}, call("action_mode")).leaf = true
    entry({"admin", "services", "singbox", "watchdog"}, call("action_watchdog")).leaf = true
    entry({"admin", "services", "singbox", "log"}, call("action_log")).leaf = true
end

-- Run a shell command; return trimmed stdout as a SINGLE string.
-- IMPORTANT: never return string.gsub(...) directly — gsub returns
-- (result, nsubs), and callers like tonumber(run(...)) would treat nsubs
-- as the numeric base (e.g. tonumber("0", 1) → "base out of range").
local function run(cmd)
    local f = io.popen(cmd)
    local out = f and f:read("*a") or ""
    if f then f:close() end
    out = tostring(out or "")
    out = out:gsub("%s+$", "")
    return out
end

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local data = f:read("*a") or ""
    f:close()
    data = data:gsub("%s+$", "")
    return data
end

local function write_file(path, data)
    local fh = io.open(path, "w")
    if not fh then return false end
    fh:write(data or "")
    fh:close()
    return true
end

-- Parse an integer from a string safely (ignore gsub secondary returns, junk).
local function to_int(s, default)
    if s == nil then return default end
    if type(s) == "number" then
        if s ~= s then return default end -- NaN
        return math.floor(s)
    end
    s = tostring(s):match("^%s*([-+]?%d+)") or ""
    if s == "" then return default end
    return tonumber(s, 10) or default
end

-- Shell-quote a single argument to prevent command injection via LuCI params.
local function shq(s)
    s = s or ""
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Node ids are restricted to safe filename characters only.
local function valid_id(id)
    return id ~= nil and id ~= "" and id:match("^[A-Za-z0-9_%-]+$") ~= nil
end

function action_status()
    local running = run("/usr/bin/sb-manager status")
    local active = run("/usr/bin/sb-manager active")
    local mode = run("/usr/bin/sb-manager mode_status")
    local led = run("/usr/bin/sb-manager led_status")
    local watchdog = run("/usr/bin/sb-manager watchdog_status")
    local proto = run("/usr/bin/sb-manager nodetype")
    local mgr_ver = run("/usr/bin/sb-manager version")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        running = running,
        active_node = active,
        mode = mode,
        led = led,
        watchdog = watchdog,
        proto = proto,
        api_version = SB_API_VERSION,
        manager_version = mgr_ver,
    })
end

function action_start()
    run("/usr/bin/sb-manager start >/dev/null 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_stop()
    run("/usr/bin/sb-manager stop >/dev/null 2>&1")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_restart()
    run("/usr/bin/sb-manager restart >/dev/null 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({ ok = true })
end

function action_switch()
    local id = luci.http.formvalue("id")
    luci.http.prepare_content("application/json")
    if not valid_id(id) then
        luci.http.write_json({ ok = false, error = "invalid node id" })
        return
    end
    run("/usr/bin/sb-manager switch " .. shq(id))
    luci.http.write_json({ ok = true })
end

function action_addnode()
    local id = luci.http.formvalue("id")
    local link = luci.http.formvalue("link")
    luci.http.prepare_content("application/json")
    if not valid_id(id) then
        luci.http.write_json({ ok = false, error = "invalid node id" })
        return
    end
    if not link or link == "" then
        luci.http.write_json({ ok = false, error = "empty config (use POST; GET truncates long payloads)" })
        return
    end

    -- Accept vless://, Amnezia vpn:// share links, or IPsec JSON.
    local trimmed = link:match("^%s*(.-)%s*$") or link
    local is_ipsec = trimmed:sub(1, 1) == "{"
    local is_vless = trimmed:match("^[Vv][Ll][Ee][Ss][Ss]://") ~= nil
    local is_vpn = trimmed:match("^[Vv][Pp][Nn]://") ~= nil
    if not is_ipsec and not is_vless and not is_vpn then
        luci.http.write_json({
            ok = false,
            error = "paste vless://, vpn:// (Amnezia), or IPsec JSON ({cert, hostName, ...})"
        })
        return
    end

    local payload = link
    if is_vless or is_vpn then
        -- Strip whitespace/newlines inside share links (vpn:// is one token).
        payload = link:gsub("^[%s\"']+", ""):gsub("[%s\"']+$", ""):gsub("%s+", "")
    else
        -- Keep JSON structure; only trim outer whitespace.
        payload = trimmed
    end

    -- Guard against truncated POSTs (uhttpd body limits) for Amnezia JSON.
    if is_ipsec then
        local opens = select(2, payload:gsub("%{", ""))
        local closes = select(2, payload:gsub("%}", ""))
        if opens ~= closes or not payload:find('"cert"') then
            luci.http.write_json({
                ok = false,
                error = "IPsec JSON looks truncated or incomplete (missing cert / unbalanced braces). Try vpn:// in LuCI (browser decode) or a smaller paste."
            })
            return
        end
    end

    local tmp = "/tmp/sb_link_" .. id .. ".txt"
    local rc_file = "/tmp/sb_addnode_" .. id .. ".rc"
    local err_file = "/tmp/sb_addnode_" .. id .. ".err"
    if not write_file(tmp, payload) then
        luci.http.write_json({ ok = false, error = "failed to write temp file" })
        return
    end

    -- Unique rc/err paths avoid races if two adds overlap.
    run("/usr/bin/sb-manager addnode " .. shq(id) .. " " .. shq(tmp)
        .. " >" .. shq(err_file) .. " 2>&1; echo $? > " .. shq(rc_file))
    os.remove(tmp)

    local rc = to_int(read_file(rc_file), 1)
    os.remove(rc_file)

    if rc ~= 0 then
        local err = read_file(err_file)
        os.remove(err_file)
        if err == "" then
            err = "failed to parse config (rc=" .. tostring(rc) .. ")"
        end
        -- Keep error message bounded for the UI.
        if #err > 400 then
            err = err:sub(1, 400) .. "..."
        end
        luci.http.write_json({ ok = false, error = err })
        return
    end
    os.remove(err_file)

    -- Activate the new node so Start/Restart actually uses it.
    run("/usr/bin/sb-manager switch " .. shq(id))
    local ntype = run("/usr/bin/sb-manager nodetype " .. shq(id))
    luci.http.write_json({ ok = true, activated = id, proto = ntype })
end

function action_delnode()
    local id = luci.http.formvalue("id")
    luci.http.prepare_content("application/json")
    if not valid_id(id) then
        luci.http.write_json({ ok = false, error = "invalid node id" })
        return
    end
    run("/usr/bin/sb-manager delnode " .. shq(id))
    luci.http.write_json({ ok = true })
end

function action_listnodes()
    local out = run("/usr/bin/sb-manager listnodes")
    local nodes = {}
    for id in out:gmatch("[^\n]+") do
        table.insert(nodes, id)
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ nodes = nodes })
end

function action_mode()
    local mode = luci.http.formvalue("mode")
    luci.http.prepare_content("application/json")
    if mode ~= "tunnel" and mode ~= "proxy" then
        luci.http.write_json({ ok = false, error = "mode must be 'tunnel' or 'proxy'" })
        return
    end
    run("/usr/bin/sb-manager mode_toggle " .. shq(mode))
    luci.http.write_json({ ok = true })
end

function action_watchdog()
    local state = luci.http.formvalue("state")
    luci.http.prepare_content("application/json")
    if state ~= "0" and state ~= "1" then
        luci.http.write_json({ ok = false, error = "state must be 0 or 1" })
        return
    end
    run("/usr/bin/sb-manager watchdog_toggle " .. shq(state))
    luci.http.write_json({ ok = true })
end

function action_log()
    -- Return JSON so LuCI XHR.get can parse it (text/plain left data=null in the UI).
    local text = ""
    local f = io.open("/var/log/singbox.log", "r")
    if f then
        local size = f:seek("end")
        if size and size > 8000 then
            f:seek("set", size - 8000)
        else
            f:seek("set", 0)
        end
        text = f:read("*a") or ""
        f:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ log = text })
end
SB_LUA_EOF

cat << 'SB_HTM_EOF' > /usr/lib/lua/luci/view/singbox_panel.htm
<%+header%>

<div class="cbi-map">
	<h2 name="content">Sing-Box VPN Manager</h2>

	<div class="cbi-section">
		<div class="cbi-section-node">
			<table class="table">
				<tr>
					<td class="td" style="width:40%"><strong>Status</strong></td>
					<td class="td"><span id="sb_status">Loading...</span></td>
				</tr>
				<tr>
					<td class="td"><strong>Active Node</strong></td>
					<td class="td"><span id="sb_active_node">-</span></td>
				</tr>
				<tr>
					<td class="td"><strong>Routing Mode</strong></td>
					<td class="td">
						<select id="sb_mode_select">
							<option value="tunnel">Full Tunnel (transparent proxy)</option>
							<option value="proxy">Proxy Only (SOCKS/HTTP on :1080)</option>
						</select>
					</td>
				</tr>
				<tr>
					<td class="td"><strong>Watchdog</strong></td>
					<td class="td">
						<input type="checkbox" id="sb_watchdog_toggle" /> Auto-restart if sing-box crashes
					</td>
				</tr>
				<tr>
					<td class="td"><strong>Panel build</strong></td>
					<td class="td"><span id="sb_api_version">?</span></td>
				</tr>
			</table>

			<div class="cbi-page-actions">
				<button class="cbi-button cbi-button-apply" id="sb_btn_start">Start</button>
				<button class="cbi-button cbi-button-reset" id="sb_btn_stop">Stop</button>
				<button class="cbi-button cbi-button-action" id="sb_btn_restart">Restart</button>
			</div>
		</div>
	</div>

	<div class="cbi-section">
		<h3>Nodes</h3>
		<div class="cbi-section-node">
			<table class="table" id="sb_node_table">
				<tr><th class="th">ID</th><th class="th">Actions</th></tr>
			</table>
			<div class="cbi-page-actions">
				<input type="text" id="sb_new_node_id" placeholder="node id (e.g. home1)" style="width:150px" />
				<textarea id="sb_new_node_link" placeholder="vless://...  OR  vpn://... (Amnezia)  OR  IPsec JSON" rows="4" style="width:60%"></textarea>
				<button class="cbi-button cbi-button-add" id="sb_btn_addnode">Add Node</button>
			</div>
			<p style="opacity:0.75;margin-top:4px"><strong>VLESS</strong>: <code>vless://</code> &nbsp;|&nbsp; <strong>Amnezia IPsec</strong>: <code>vpn://</code> (decoded in your browser), export JSON, or <code>.sswan</code>. Connecting IPsec needs <code>strongswan</code>/<code>swanctl</code> on the router (often missing on OEM ZLT firmware).</p>
		</div>
	</div>

	<div class="cbi-section">
		<h3>Log (last 8 KB)</h3>
		<pre id="sb_log" style="max-height:300px; overflow:auto; background:#111; color:#ccc; padding:8px;"></pre>
	</div>
</div>

<script type="text/javascript">
	var sb_url = "<%=luci.dispatcher.build_url("admin", "services", "singbox")%>";
	var sb_token = "<%=luci.dispatcher.context.authtoken%>";
	var sb_known_nodes = [];

	function sb_api(action, params, cb, usePost) {
		params = params || {};
		var handle = function(x, data) {
			if (!data && x) {
				var raw = x.responseText || "";
				if (raw) {
					try { data = JSON.parse(raw); } catch (e) {}
				}
				if (!data) {
					data = {
						ok: false,
						error: "HTTP " + (x.status || 0) +
							(raw ? (": " + raw.replace(/\s+/g, " ").substring(0, 180)) : " (empty/no JSON)")
					};
				}
			}
			cb(data || { ok: false, error: "no response from router" });
		};
		if (usePost) {
			var body = {};
			for (var k in params) body[k] = params[k];
			if (sb_token) body.token = sb_token;
			XHR.post(sb_url + "/" + action, body, handle);
		} else {
			var qs = "";
			for (var k in params) {
				qs += (qs ? "&" : "") + encodeURIComponent(k) + "=" + encodeURIComponent(params[k]);
			}
			XHR.get(sb_url + "/" + action + (qs ? "?" + qs : ""), null, handle);
		}
	}

	function sb_refresh_status() {
		sb_api("status", null, function(data) {
			if (!data) return;
			var status = data.running || "Unknown";
			if (data.proto && data.proto !== "none" && data.proto !== "vless") {
				status = status + " [" + data.proto + "]";
			}
			document.getElementById("sb_status").textContent = status;
			document.getElementById("sb_active_node").textContent =
				(data.active_node || "none") + (data.proto && data.proto !== "none" ? " (" + data.proto + ")" : "");
			document.getElementById("sb_mode_select").value = data.mode || "tunnel";
			document.getElementById("sb_watchdog_toggle").checked = (data.watchdog === "1");
			var verEl = document.getElementById("sb_api_version");
			if (verEl) {
				var ver = data.api_version || 0;
				var mgr = data.manager_version || "?";
				verEl.textContent = "API v" + ver + " / manager " + mgr;
				verEl.style.color = (ver >= 3 && String(mgr).indexOf("ipsec4") >= 0) ? "" : "#c00";
			}
		});
	}

	function sb_refresh_log() {
		sb_api("log", null, function(data) {
			var el = document.getElementById("sb_log");
			el.textContent = (data && data.log) ? data.log : "";
			el.scrollTop = el.scrollHeight;
		});
	}

	function sb_refresh_after_start() {
		// start/restart run in background; give sing-box a moment before polling.
		setTimeout(function() {
			sb_refresh_status();
			sb_refresh_log();
		}, 1500);
	}

	function sb_render_nodes() {
		var table = document.getElementById("sb_node_table");
		while (table.rows.length > 1) table.deleteRow(1);
		sb_known_nodes.forEach(function(id) {
			var row = table.insertRow(-1);
			var idCell = row.insertCell(0);
			var actCell = row.insertCell(1);
			idCell.textContent = id;

			var switchBtn = document.createElement("button");
			switchBtn.className = "cbi-button cbi-button-apply";
			switchBtn.textContent = "Activate";
			switchBtn.onclick = function() {
				sb_api("switch", { id: id }, function() {
					sb_api("restart", null, sb_refresh_after_start);
				});
			};

			var delBtn = document.createElement("button");
			delBtn.className = "cbi-button cbi-button-remove";
			delBtn.textContent = "Delete";
			delBtn.onclick = function() {
				if (!confirm("Delete node " + id + "?")) return;
				sb_api("delnode", { id: id }, function() {
					sb_known_nodes = sb_known_nodes.filter(function(n) { return n !== id; });
					sb_render_nodes();
				});
			};

			actCell.appendChild(switchBtn);
			actCell.appendChild(delBtn);
		});
	}

	document.getElementById("sb_btn_start").onclick = function() { sb_api("start", null, sb_refresh_after_start); };
	document.getElementById("sb_btn_stop").onclick = function() { sb_api("stop", null, sb_refresh_status); };
	document.getElementById("sb_btn_restart").onclick = function() { sb_api("restart", null, sb_refresh_after_start); };

	document.getElementById("sb_mode_select").onchange = function(e) {
		sb_api("mode", { mode: e.target.value }, function() {
			if (confirm("Mode changed. Restart sing-box now to apply?")) {
				sb_api("restart", null, sb_refresh_status);
			}
		});
	};

	document.getElementById("sb_watchdog_toggle").onchange = function(e) {
		sb_api("watchdog", { state: e.target.checked ? "1" : "0" }, sb_refresh_status);
	};

	/* Amnezia vpn:// = Base64URL(qCompress(JSON)). Decode in-browser so the
	   router does not need python3 (OEM ZLT feeds often lack it). */
	function sb_b64url_to_u8(s) {
		s = s.replace(/-/g, "+").replace(/_/g, "/");
		while (s.length % 4) s += "=";
		var bin = atob(s);
		var out = new Uint8Array(bin.length);
		for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
		return out;
	}

	function sb_inflate_zlib(u8) {
		return new Promise(function(resolve, reject) {
			if (typeof DecompressionStream === "undefined") {
				reject(new Error("Browser lacks DecompressionStream; use Chrome/Firefox/Edge, or paste IPsec JSON"));
				return;
			}
			var ds = new DecompressionStream("deflate");
			var stream = new Blob([u8]).stream().pipeThrough(ds);
			new Response(stream).arrayBuffer().then(function(buf) {
				resolve(new TextDecoder("utf-8").decode(buf));
			}).catch(reject);
		});
	}

	function sb_extract_ipsec(obj) {
		if (!obj || typeof obj !== "object") return null;
		if (obj.cert && (obj.hostName || obj.addr)) return obj;
		var containers = obj.containers || [];
		var def = obj.defaultContainer || "";
		function fromContainer(c) {
			if (!c) return null;
			var ike = c.ikev2 || c.ipsec || {};
			var last = ike.last_config;
			if (!last) return null;
			var lastObj = (typeof last === "string") ? JSON.parse(last) : last;
			if (lastObj && typeof lastObj.config === "string" && lastObj.config.charAt(0) === "{") {
				try { return JSON.parse(lastObj.config); } catch (e) {}
			}
			if (!lastObj.hostName && obj.hostName) lastObj.hostName = obj.hostName;
			if (lastObj.password == null) lastObj.password = "";
			if (!lastObj.userName && lastObj.clientId) lastObj.userName = lastObj.clientId;
			return lastObj;
		}
		var i, c, got = null;
		for (i = 0; i < containers.length; i++) {
			c = containers[i];
			if (def && c.container === def) {
				got = fromContainer(c);
				if (got) return got;
			}
		}
		for (i = 0; i < containers.length; i++) {
			got = fromContainer(containers[i]);
			if (got) return got;
		}
		return null;
	}

	function sb_decode_vpn_link(link) {
		var raw = link.replace(/^vpn:\/\//i, "");
		var blob = sb_b64url_to_u8(raw);
		var zlibPart = blob.slice(4);
		return sb_inflate_zlib(zlibPart).then(function(text) {
			var obj = JSON.parse(text);
			var ipsec = sb_extract_ipsec(obj);
			if (!ipsec || !ipsec.cert) throw new Error("No Amnezia IPsec/IKEv2 cert in vpn:// payload");
			return JSON.stringify(ipsec);
		});
	}

	function sb_do_addnode(id, payload) {
		sb_api("addnode", { id: id, link: payload }, function(data) {
			if (data && data.ok) {
				if (sb_known_nodes.indexOf(id) === -1) sb_known_nodes.push(id);
				sb_render_nodes();
				document.getElementById("sb_new_node_id").value = "";
				document.getElementById("sb_new_node_link").value = "";
				sb_api("restart", null, sb_refresh_after_start);
			} else {
				alert("Failed to add node: " + ((data && data.error) || "unknown error"));
			}
		}, true);
	}

	document.getElementById("sb_btn_addnode").onclick = function() {
		var id = document.getElementById("sb_new_node_id").value.trim();
		var link = document.getElementById("sb_new_node_link").value.trim();
		if (!/^[A-Za-z0-9_-]+$/.test(id)) {
			alert("Node id must be alphanumeric (letters, digits, -, _ only).");
			return;
		}
		if (!link) {
			alert("Paste a vless://, vpn:// (Amnezia), or IPsec JSON config first.");
			return;
		}
		var isJson = link.charAt(0) === "{";
		var low = link.toLowerCase();
		var isVless = low.indexOf("vless://") === 0;
		var isVpn = low.indexOf("vpn://") === 0;
		if (!isJson && !isVless && !isVpn) {
			alert("Config must be vless://, vpn://, or JSON starting with {");
			return;
		}
		if (isVpn) {
			sb_decode_vpn_link(link.replace(/\s+/g, "")).then(function(jsonPayload) {
				sb_do_addnode(id, jsonPayload);
			}).catch(function(err) {
				alert("Failed to decode vpn:// in browser: " + (err && err.message ? err.message : err));
			});
			return;
		}
		sb_do_addnode(id, isVless ? link.replace(/\s+/g, "") : link);
	};

	function sb_load_nodes() {
		sb_api("listnodes", null, function(data) {
			sb_known_nodes = (data && data.nodes) || [];
			sb_render_nodes();
		});
	}

	sb_refresh_status();
	sb_load_nodes();
	sb_refresh_log();
	setInterval(sb_refresh_status, 5000);
	setInterval(sb_refresh_log, 8000);
</script>

<%+footer%>
SB_HTM_EOF
rm -f /usr/lib/lua/luci/controller/xray.lua /usr/lib/lua/luci/view/xray_panel.htm 2>/dev/null || true

log "7. Initializing state files (preserving existing nodes)..."
: > /etc/singbox/nodes.list
[ -f /etc/singbox/active_node ] || printf 'none' > /etc/singbox/active_node
[ -f /etc/singbox/routing_mode ] || printf 'tunnel' > /etc/singbox/routing_mode
[ -f /etc/singbox/watchdog.flag ] || printf '0' > /etc/singbox/watchdog.flag
# Keep sb_bin.path written during binary install.
[ -f /etc/singbox/sb_bin.path ] || printf '%s\n' "$SB_BIN_PATH" > /etc/singbox/sb_bin.path

log "8. Clearing LuCI cache..."
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache /tmp/luci-templatecache 2>/dev/null || true
/etc/init.d/uhttpd restart 2>/dev/null || true

log "======================================================="
log "Sing-Box VPN Manager ${SINGBOX_VERSION} installed."
log "VLESS:   echo 'vless://...' > /tmp/link.txt && sb-manager addnode home1 /tmp/link.txt"
log "Amnezia: echo 'vpn://...' > /tmp/a.txt && sb-manager addnode ike1 /tmp/a.txt"
log "         (or paste vpn:// / IPsec JSON in LuCI)"
log "Then:    sb-manager switch <id> && sb-manager start"
log "======================================================="
