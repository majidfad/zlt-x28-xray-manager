#!/usr/bin/env python3
"""Sync files/ into scripts/install.sh heredocs WITHOUT truncating the script tail.

Usage:
  python scripts/sync-embedded.py
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

BLOCKS = {
    "SB_CFG_EOF": ROOT / "files/etc/singbox/base_config.json",
    "SB_MGR_EOF": ROOT / "files/usr/bin/sb-manager",
    "SB_VPNDEC_EOF": ROOT / "files/usr/bin/sb-vpn-decode",
    "SB_LUA_EOF": ROOT / "files/usr/lib/lua/luci/controller/singbox.lua",
    "SB_HTM_EOF": ROOT / "files/usr/lib/lua/luci/view/singbox_panel.htm",
}


def replace_heredoc(text: str, marker: str, body: str) -> str:
    start = f"cat << '{marker}'"
    i = text.find(start)
    if i < 0:
        raise SystemExit(f"missing start for {marker}")
    nl = text.find("\n", i)
    if nl < 0:
        raise SystemExit(f"no newline after start for {marker}")
    end = f"\n{marker}\n"
    j = text.find(end, nl + 1)
    if j < 0:
        raise SystemExit(f"missing end marker {marker} — refusing to truncate")
    # Critical: keep everything AFTER the closing marker
    return text[: nl + 1] + body.rstrip("\n") + end + text[j + len(end) :]


def main() -> None:
    path = ROOT / "scripts/install.sh"
    text = path.read_text(encoding="utf-8")
    # Sanity: installer must already have a post-manager tail
    if "chmod +x /usr/bin/sb-manager" not in text.split("\nSB_MGR_EOF\n", 1)[-1]:
        raise SystemExit(
            "install.sh is truncated after SB_MGR_EOF — restore from git before syncing"
        )
    for marker, src in BLOCKS.items():
        body = src.read_text(encoding="utf-8")
        text = replace_heredoc(text, marker, body)
        print(f"OK {marker} <- {src.relative_to(ROOT)}")
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
