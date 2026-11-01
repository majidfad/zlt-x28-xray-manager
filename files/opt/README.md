# Matched strongSwan stack (GitHub download)

`sb-swan.tgz` is fetched by `sb-install-ss-plugins` / `install.sh` from:

```
https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/files/opt/sb-swan.tgz
```

No OpenWrt CDN. No full `git clone`. Only this one archive (~750KB).

On ZLT-X28 the root overlay is tiny (~23MB). The installer extracts the
stack onto **`/data/sb-swan` or `/customer/sb-swan`** and **bind-mounts**
it to `/usr/lib/ipsec` (no big copy onto `/`).

## Free overlay space first (if install failed with "No space left")

```sh
rm -rf /opt/sb-swan /etc/singbox/ss-plugins /etc/singbox/ss-oem-ipsec-bak /tmp/sb_swan_dl
df -h /
```

## Router install (WAN to GitHub required)

```sh
wget -O /tmp/install.sh \
  'https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/scripts/install.sh'
sh /tmp/install.sh
```

Or only the stack (script itself can live in `/tmp` if `/` is full):

```sh
wget -O /tmp/sb-install-ss-plugins \
  'https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/files/usr/bin/sb-install-ss-plugins'
chmod +x /tmp/sb-install-ss-plugins
/tmp/sb-install-ss-plugins
```

Check: `ping -c1 raw.githubusercontent.com`
`df -h / /data /customer`
`mount | grep ipsec`
