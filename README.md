# ZLT-X28 Sing-Box VPN Manager

Transparent-proxy VPN manager for the ZLT-X28 (and similar OpenWrt/ARM64
routers), built on [sing-box](https://github.com/SagerNet/sing-box). Supports
VLESS + REALITY / TLS nodes, full-tunnel (tproxy) or SOCKS/HTTP proxy-only
routing modes, a watchdog, and a LuCI web UI.

## Status

Functional. REALITY connectivity bug (see below) is fixed by pinning a
current sing-box release. UI is a minimal first pass — see
[Roadmap](#roadmap) for planned improvements.

## Requirements

- OpenWrt router, ARM64 (tested target: ZLT-X28)
- `iptables` + `ip` (standard OpenWrt iptables-legacy stack)
- `curl`, `tar`
- LuCI + `uhttpd` (optional, only needed for the web UI)

## Install

```sh
# On the router:
curl -L -o install.sh https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/scripts/install.sh
sh install.sh
```

Or clone the repo onto the router and run `sh scripts/install.sh` from the
repo root (the script locates `files/` relative to itself).

By default it targets `arm64`. Override for other platforms:

```sh
SINGBOX_ARCH=amd64 sh scripts/install.sh
```

## Uninstall

```sh
sh scripts/uninstall.sh
```

## Usage

Add a node from a `vless://` share link (REALITY or plain TLS):

```sh
echo 'vless://uuid@host:port?...' > /tmp/link.txt
sb-manager addnode home1 /tmp/link.txt
sb-manager switch home1
sb-manager start
```

Common commands:

```sh
sb-manager status            # Running / Stopped
sb-manager restart
sb-manager listnodes
sb-manager delnode home1
sb-manager mode_toggle proxy # or: tunnel
sb-manager mode_status
sb-manager watchdog_toggle 1 # auto-restart sing-box if it dies
```

Routing modes:

- `tunnel` — transparent proxy via iptables TPROXY/REDIRECT, routes all LAN
  traffic through the active node.
- `proxy` — sing-box only listens on `0.0.0.0:1080` (SOCKS/HTTP mixed inbound);
  no iptables rules are touched. Useful for testing a node without affecting
  the whole LAN.

The LuCI panel is under **Services → Sing-Box VPN** once installed.

## The REALITY bug and its fix

The original script pinned **sing-box v1.9.3** (June 2024). Against modern
REALITY servers, that build consistently logs:

```
inbound/tproxy[tproxy-in]: process connection ...: reality verification failed
```

This was diagnosed by elimination, not guesswork:

- The `vless://` link parser was traced by hand against a real affected link —
  `pbk`, `sid`, `sni`, `fp` all decoded correctly, so this was not a parsing
  bug on values without percent-encoding (though a real latent parsing bug
  existed and is fixed below).
- Router clock was confirmed accurate (`date -u` matched real time) — not a
  clock-skew issue.
- The same link was confirmed working from another (modern) client — the
  server and credentials are not at fault.
- sing-box v1.9.3 bundles `sagernet/utls v1.5.4` and an early REALITY
  implementation. Later sing-box releases bumped uTLS through several major
  versions with REALITY/ClientHello compatibility fixes, and the VLESS/REALITY
  config schema did not change in the process — so upgrading the pinned
  binary is a drop-in fix.

**Fix applied:** the installer now downloads **sing-box v1.14.3** instead of
v1.9.3. No config changes were needed since the schema is unchanged.

### Other correctness fixes made while auditing the script

- `urldecode()` in `sb-manager` previously decoded only 7 hardcoded `%XX`
  sequences. Any REALITY/TLS link with an unlisted encoded character in a
  query value (e.g. `%26`, encoded `spx` paths, etc.) would silently produce a
  wrong value. Replaced with a full percent-decoder.
- Parsed values are now JSON-escaped before being embedded in the generated
  node config, so a `"` or `\` in `sni`/`host` can't produce invalid JSON.
- `sb-manager start` now runs `sing-box check` on the generated config before
  launching it, and aborts with a logged reason instead of starting a broken
  process silently.
- Added IPv6 literal address support (`[::1]:port`) in the link parser.
- Added a `listnodes` command (needed by the UI to show existing nodes after
  a page reload) and a `restart` command.
- The LuCI controller shell-quotes and validates every HTTP parameter before
  it reaches the shell (node ids are restricted to `[A-Za-z0-9_-]+`), closing
  a command-injection gap in the admin panel.

## Project layout

```
scripts/
  install.sh       # clean install / reinstall
  uninstall.sh      # full removal
files/
  etc/singbox/
    base_config.json      # sing-box config template (outbounds injected here)
  usr/bin/
    sb-manager             # core control script (start/stop/node mgmt/watchdog)
  usr/lib/lua/luci/
    controller/singbox.lua # LuCI backend (AJAX endpoints)
    view/singbox_panel.htm # LuCI frontend panel
```

## Roadmap

Functionality is stable; these are the planned next improvements, roughly in
priority order:

1. **Multi-protocol support** — currently only `vless`. Add `trojan`,
   `hysteria2`, `shadowsocks` parsing to `sb-manager addnode`.
2. **Subscription import** — fetch a base64 subscription URL and expand it
   into multiple nodes instead of pasting links one at a time.
3. **Latency/health check per node** — periodic TCP connect + HTTP probe
   through each node, shown in the UI, so you can pick the fastest one.
4. **Config persistence across sing-box upgrades** — store nodes/mode state
   independent of `/etc/singbox` so re-running `install.sh` doesn't require
   re-adding nodes (it already preserves `/etc/singbox` today, but this
   should be made explicit/tested with an upgrade path, not just clean
   install).
5. **UI**: replace the plain HTML table with a proper LuCI CBI form, add a
   per-node latency badge, add a "test before activate" button, and show
   decoded node details (server/port/security) instead of just the id.
6. **Structured logging** — JSON log output from sing-box plus a filtered
   LuCI log view (errors only / connections only).
7. **Firewall integration** — register the tproxy rules via UCI/firewall
   includes instead of raw iptables calls in `sb-manager`, so they survive
   `/etc/init.d/firewall reload` and show up in `fw4`/`fw3` status correctly.
8. **Automated tests** — a POSIX-sh test harness (e.g. with `bats-core`) for
   `parse_link_to_json` and `urldecode` against a fixture set of link formats.

## Contributing

Issues and PRs welcome. Run `shellcheck scripts/*.sh files/usr/bin/sb-manager`
before submitting; CI runs the same check.

## License

MIT — see [LICENSE](LICENSE).
