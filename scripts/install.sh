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
mkdir -p /etc/singbox
mkdir -p /usr/lib/lua/luci/controller/ /usr/lib/lua/luci/view/
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

get_active_node_path() { echo "$DIR_SB/node_$(cat "$ACTIVE_NODE_POINTER" 2>/dev/null).json"; }
get_mode() { cat "$MODE_POINTER" 2>/dev/null || echo "tunnel"; }

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

parse_link_to_json() {
    FILE="$1"
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

get_server_ip() { ACTIVE_NODE=$(get_active_node_path); if [ -f "$ACTIVE_NODE" ]; then awk -F'"' '/"server":/ {print $4; exit}' "$ACTIVE_NODE"; fi; }

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

stop_sb() {
    [ -f "$WATCHDOG_PID" ] && kill -9 "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
    rm -f "$WATCHDOG_PID" "$WATCHDOG_STATUS_FILE"
    [ -f "$PID_FILE" ] && kill -9 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
    killall -9 sing-box 2>/dev/null
    clean_iptables
    echo "[System] Sing-Box fully terminated." >> "$LOG_FILE"
}

start_sb() {
    if ! resolve_sb_bin || ! sb_bin_usable; then
        report_sb_bin_error
        return 1
    fi
    if ! build_final_config; then
        echo "[System] Aborting start: config build/validation failed." >> "$LOG_FILE"
        return 1
    fi
    SERVER_IP=$(get_server_ip)

    stop_sb >/dev/null 2>&1
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

    start-stop-daemon -S -b -m -p "$PID_FILE" -x /bin/sh -- -c "export GOMEMLIMIT=150MiB GOGC=100; exec $SB_BIN run -c '$CONFIG_FILE' >> '$LOG_FILE' 2>&1"
    start_watchdog
}

maint_run() {
    sync; echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    if is_sb_running; then stop_sb; sleep 2; start_sb; fi
}

daemon_watchdog() {
    echo $$ > "$WATCHDOG_PID"
    while true; do
        sleep 15
        if is_sb_running; then echo "green" > "$WATCHDOG_STATUS_FILE"
        else echo "offline" > "$WATCHDOG_STATUS_FILE"; exit 0; fi
    done
}

start_watchdog() {
    [ -f "$WATCHDOG_PID" ] && kill -9 "$(cat "$WATCHDOG_PID" 2>/dev/null)" 2>/dev/null
    if [ "$(cat "$WATCHDOG_FLAG" 2>/dev/null)" = "1" ]; then /usr/bin/sb-manager daemon_watchdog & fi
}

case "$1" in
    start) start_sb; exit 0 ;;
    stop) stop_sb; exit 0 ;;
    restart) stop_sb; sleep 1; start_sb; exit 0 ;;
    status) if is_sb_running; then echo "Running"; else echo "Stopped"; fi; exit 0 ;;
    active) cat "$ACTIVE_NODE_POINTER" 2>/dev/null; exit 0 ;;
    switch) echo "$2" > "$ACTIVE_NODE_POINTER"; exit 0 ;;
    addnode)
        if [ -z "$2" ] || [ -z "$3" ] || [ ! -f "$3" ]; then
            echo "Usage: sb-manager addnode <id> <linkfile>" >&2
            exit 1
        fi
        parse_link_to_json "$3" > "$DIR_SB/node_$2.json"
        if [ ! -s "$DIR_SB/node_$2.json" ]; then
            rm -f "$DIR_SB/node_$2.json"
            echo "Failed to parse link (expected a vless:// URL)" >&2
            exit 1
        fi
        exit 0
        ;;
    delnode) rm -f "$DIR_SB/node_$2.json"; exit 0 ;;
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
    mode_toggle) echo "$2" > "$MODE_POINTER"; exit 0 ;;
    mode_status) get_mode; exit 0 ;;
    maint_run) maint_run; exit 0 ;;
    watchdog_toggle) echo "$2" > "$WATCHDOG_FLAG"; exit 0 ;;
    watchdog_status) cat "$WATCHDOG_FLAG" 2>/dev/null || echo "0"; exit 0 ;;
    led_status) cat "$WATCHDOG_STATUS_FILE" 2>/dev/null || echo "offline"; exit 0 ;;
    daemon_watchdog) daemon_watchdog; exit 0 ;;
    *)
        echo "Usage: sb-manager {start|stop|restart|status|active|switch <id>|addnode <id> <linkfile>|delnode <id>|listnodes|mode_toggle <tunnel|proxy>|mode_status|watchdog_toggle <0|1>|watchdog_status|led_status}"
        exit 1
        ;;
esac
SB_MGR_EOF
chmod +x /usr/bin/sb-manager

log "6. Installing LuCI UI..."
cat << 'SB_LUA_EOF' > /usr/lib/lua/luci/controller/singbox.lua
-- LuCI controller for Sing-Box VPN Manager
module("luci.controller.singbox", package.seeall)

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

local function run(cmd)
    local f = io.popen(cmd)
    local out = f and f:read("*a") or ""
    if f then f:close() end
    return (out or ""):gsub("%s+$", "")
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
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        running = running,
        active_node = active,
        mode = mode,
        led = led,
        watchdog = watchdog,
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
        luci.http.write_json({ ok = false, error = "empty link (use POST; GET truncates long vless URLs)" })
        return
    end
    -- Normalize pasted links: strip whitespace and optional surrounding quotes.
    link = link:gsub("^[%s\"']+", ""):gsub("[%s\"']+$", ""):gsub("%s+", "")
    if not link:match("^vless://") then
        luci.http.write_json({ ok = false, error = "link must start with vless://" })
        return
    end
    local tmp = "/tmp/sb_link_" .. id .. ".txt"
    local fh = io.open(tmp, "w")
    if not fh then
        luci.http.write_json({ ok = false, error = "failed to write temp file" })
        return
    end
    fh:write(link)
    fh:close()
    run("/usr/bin/sb-manager addnode " .. shq(id) .. " " .. shq(tmp) .. " >/tmp/sb_addnode.err 2>&1; echo $? > /tmp/sb_addnode.rc")
    os.remove(tmp)
    local rc = tonumber(run("cat /tmp/sb_addnode.rc 2>/dev/null")) or 1
    if rc ~= 0 then
        local err = run("cat /tmp/sb_addnode.err 2>/dev/null")
        luci.http.write_json({ ok = false, error = (err ~= "" and err) or "failed to parse vless link" })
        return
    end
    -- Activate the new node so Start/Restart actually uses it.
    run("/usr/bin/sb-manager switch " .. shq(id))
    luci.http.write_json({ ok = true, activated = id })
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
				<textarea id="sb_new_node_link" placeholder="vless://..." rows="2" style="width:60%"></textarea>
				<button class="cbi-button cbi-button-add" id="sb_btn_addnode">Add Node</button>
			</div>
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
			document.getElementById("sb_status").textContent = data.running || "Unknown";
			document.getElementById("sb_active_node").textContent = data.active_node || "none";
			document.getElementById("sb_mode_select").value = data.mode || "tunnel";
			document.getElementById("sb_watchdog_toggle").checked = (data.watchdog === "1");
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

	document.getElementById("sb_btn_addnode").onclick = function() {
		var id = document.getElementById("sb_new_node_id").value.trim();
		var link = document.getElementById("sb_new_node_link").value.trim();
		if (!/^[A-Za-z0-9_-]+$/.test(id)) {
			alert("Node id must be alphanumeric (letters, digits, -, _ only).");
			return;
		}
		if (!link) {
			alert("Paste a vless:// link first.");
			return;
		}
		// POST: vless links are too long/fragile for GET query strings (caused "unknown error").
		sb_api("addnode", { id: id, link: link }, function(data) {
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
log "Add a node with: sb-manager addnode <id> <path-to-file-containing-vless-link>"
log "Then activate it: sb-manager switch <id> && sb-manager start"
log "======================================================="
