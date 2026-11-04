# ZLT-X28 IPsec Manager (`zi-*`)

Amnezia **IKEv2 / IPsec** tunnel for ZLT-X28 (OpenWrt). No sing-box / VLESS.

## Features

- Import `vpn://` link, flat JSON, or manual host + PKCS#12
- Matched **strongSwan 5.9.2** on `/data` + bind-mount (tiny overlay safe)
- RSA-PSS (`ike:rsa/pss-sha256`) for Amnezia Libreswan peers
- Tunnel mode with SNAT; **LAN CIDRs + VPN server IP** auto-excepted
- Health ping every **5 minutes**; **10** consecutive fails → disconnect (WAN fallback)
- One active profile; LuCI under **Services → ZLT IPsec**

## Install (on router)

```sh
wget -q -T 60 -O /tmp/zi-install.sh \
  https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/install.sh
sh /tmp/zi-install.sh
```

Then open LuCI → **Services → ZLT IPsec**, paste `vpn://` or JSON, **Save** → **Connect**.

## CLI

```sh
zi-manager import /tmp/cfg.txt    # vpn:// file or JSON
zi-manager start
zi-manager status
zi-manager ss_check
zi-manager stop
```

## Uninstall

```sh
wget -q -O /tmp/zi-un.sh \
  https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/uninstall.sh
sh /tmp/zi-un.sh
```

## Notes

- Stack lives under `/data/zi-swan` (or `/customer/zi-swan`). Never `rm -rf /usr/lib/ipsec` while the bind is mounted.
- Proxy / VLESS / sing-box are intentionally not supported.
