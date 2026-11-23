#!/bin/bash
# 开发辅助：dump Solo 的媒体/歌词相关字符串（一次跑完，避免 /tmp 跨会话丢失）。
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT=/tmp/solo-media
rm -rf "$OUT"; mkdir -p "$OUT"
dpkg-deb -x "$SRC/vendor/Solo_1.0.1.deb" "$OUT/root"
DYLIB="$OUT/root/var/jb/Library/MobileSubstrate/DynamicLibraries/Solo.dylib"

echo "== media / now playing / lyrics =="
strings -a "$DYLIB" | grep -Ei "SBMedia|NowPlaying|MRMedia|MPNowPlaying|lrclib|lyric" | sort -u | head -80

echo
echo "== urls =="
strings -a "$DYLIB" | grep -Ei "https?://" | sort -u | head -30
