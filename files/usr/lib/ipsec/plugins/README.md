# Bundled strongSwan plugins (aarch64)

OEM ZLT-X28 OpenWrt feeds do **not** ship `strongswan-mod-x509` / `pkcs1`.
Amnezia IKEv2 cert auth needs them, so these binaries live in-repo:

| File | Purpose |
|------|---------|
| `libstrongswan-x509.so` | Parse X.509 PEM certificates |
| `libstrongswan-pkcs1.so` | Load RSA private keys |
| `libstrongswan-pkcs8.so` | Load PKCS#8 private keys |
| `libstrongswan-gcm.so` | ESP `aes128gcm16` (Amnezia default) |

Source: OpenWrt 21.02.7 `aarch64_cortex-a53` strongSwan **5.9.2** plugin packages
(compatible with device strongSwan **5.9.1**).

## How they get onto the router

1. `scripts/install.sh` embeds `files/usr/bin/sb-install-ss-plugins` and runs it
2. That script openssl-decodes the `.so` files into `/usr/lib/ipsec/plugins/`
3. Copies are kept in `/etc/singbox/ss-plugins/` for recovery
4. `sb-manager` **never downloads** plugins from the internet

## Manual copy (if install decode fails)

From this repo, SCP the four `.so` files to the router:

```sh
scp files/usr/lib/ipsec/plugins/libstrongswan-*.so root@ROUTER:/usr/lib/ipsec/plugins/
scp files/etc/strongswan.d/charon/{x509,pkcs1,pkcs8,gcm}.conf root@ROUTER:/etc/strongswan.d/charon/
```

Then: `ipsec restart` (or activate VPN again from LuCI).
