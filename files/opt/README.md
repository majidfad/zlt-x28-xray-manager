# Matched strongSwan stack (GitHub download)

`sb-swan.tgz` is fetched by `sb-install-ss-plugins` / `install.sh` from:

```
https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/files/opt/sb-swan.tgz
```

No OpenWrt CDN. No full `git clone`. Only this one archive (~750KB).

## Router install (WAN to GitHub required)

```sh
wget -O /tmp/install.sh \
  'https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/scripts/install.sh'
sh /tmp/install.sh
```

Or only the stack:

```sh
wget -O /usr/bin/sb-install-ss-plugins \
  'https://raw.githubusercontent.com/majidfad/zlt-x28-xray-manager/main/files/usr/bin/sb-install-ss-plugins'
chmod +x /usr/bin/sb-install-ss-plugins
/usr/bin/sb-install-ss-plugins
```

Check: `ping -c1 raw.githubusercontent.com`
