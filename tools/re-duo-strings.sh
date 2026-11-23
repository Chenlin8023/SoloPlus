#!/bin/bash
# 开发辅助：从官方 Solo 包里抽 dylib 并 dump 与 Duo 相关的类名/选择器。
set -eu
SRC="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-/tmp/solo-re}"
rm -rf "$OUT"; mkdir -p "$OUT"
dpkg-deb -x "$SRC/vendor/Solo_1.0.1.deb" "$OUT/root"
cp "$OUT/root/var/jb/Library/MobileSubstrate/DynamicLibraries/Solo.dylib" "$OUT/Solo.dylib"
chmod 644 "$OUT/Solo.dylib"

echo "== file =="
file "$OUT/Solo.dylib"

echo
echo "== class-like names =="
strings -a "$OUT/Solo.dylib" | grep -E '^Unduo|^SOL|^Solo|^ATR|^Atria' | sort -u | head -120

echo
echo "== battery / time selectors =="
strings -a "$OUT/Solo.dylib" | grep -iE 'battery|percent|time|date|clock|remain' | grep -vE '^[A-Za-z0-9+/=]{24,}$' | sort -u | head -120
