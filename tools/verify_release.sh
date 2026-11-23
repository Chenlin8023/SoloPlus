#!/bin/bash
# 发布前核验：合并包 vs 官方 Solo 原包（只增不改）+ arm64e PAC + 架构/权限/control。
# 用法: bash tools/verify_release.sh [deb路径] [vendor deb路径]
set -eu

SRC="$(cd "$(dirname "$0")/.." && pwd)"
DEB="${1:-$SRC/packages/com.chenlin8023.solo.full_1.0.1-1_iphoneos-arm64.deb}"
ORIG="${2:-$SRC/vendor/Solo_1.0.1.deb}"
WORK="$(mktemp -d /tmp/sp-verify.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$DEB" ] || { echo "!! 找不到 $DEB"; exit 1; }
[ -f "$ORIG" ] || { echo "!! 找不到 $ORIG"; exit 1; }

dpkg-deb -R "$DEB" "$WORK/root"
dpkg-deb -R "$ORIG" "$WORK/orig"

DL=var/jb/Library/MobileSubstrate/DynamicLibraries
PB=var/jb/Library/PreferenceBundles/SoloPrefs.bundle
fail=0

echo "== control =="
dpkg-deb -f "$DEB" | sed -n '1,14p'

echo
echo "== 原包文件是否逐字节不变 =="
for rel in "$DL/Solo.dylib" "$DL/Solo.plist" "$PB/SoloPrefs" "$PB/Root.plist" \
           "$PB/HomeScreen.plist" "$PB/Info.plist" \
           var/jb/Library/PreferenceLoader/Preferences/SoloPrefs.plist; do
  a=$(sha256sum "$WORK/orig/$rel" | cut -d" " -f1)
  b=$(sha256sum "$WORK/root/$rel" | cut -d" " -f1)
  if [ "$a" = "$b" ]; then echo "  OK   $rel"; else echo "  DIFF $rel"; fail=1; fi
done

echo
echo "== 新增文件 =="
diff -rq "$WORK/orig" "$WORK/root" | sed 's/^/  /' || true

echo
echo "== arm64e 切片与 PAC =="
python3 - "$WORK/root/$DL/SoloPlus.dylib" <<'PY'
import struct, sys
path = sys.argv[1]
data = open(path, "rb").read()
magic = struct.unpack(">I", data[:4])[0]
if magic not in (0xCAFEBABE, 0xCAFEBABF):
    raise SystemExit("!! 不是 FAT 双切片二进制（SpringBoard 会静默拒载 arm64 单切片）")
count = struct.unpack(">I", data[4:8])[0]
slices = []
for i in range(count):
    cputype, cpusub, off, size, _ = struct.unpack(">IIIII", data[8 + i * 20: 8 + (i + 1) * 20])
    if cputype == 0x0100000C:
        # arm64e 带指针认证时 cpusubtype = 0x80000002（PTRAUTH_ABI 位 + ARM64E）
        name = "arm64e" if (cpusub & 0x00FFFFFF) == 2 else "arm64"
    else:
        name = hex(cputype)
    slices.append(name)
    print("  slice %d: cputype=0x%08x cpusub=0x%08x -> %s" % (i, cputype, cpusub, name))
print("  slices: %s" % ", ".join(slices))
if sorted(slices) != ["arm64", "arm64e"]:
    raise SystemExit("!! 切片不是 arm64 + arm64e")
PY
python3 "$SRC/tools/verify_fixups.py" "$WORK/root/$DL/SoloPlus.dylib" || fail=1

echo
echo "== 权限位 =="
for f in "$DL/Solo.dylib" "$DL/SoloPlus.dylib" "$PB/SoloPrefs"; do
  mode=$(stat -c '%a' "$WORK/root/$f")
  echo "  $mode  $f"
  [ -x "$WORK/root/$f" ] || { echo "  !! 可执行位丢失"; fail=1; }
done

echo
echo "== 面板 plist =="
grep -l "soloPlus" "$WORK/root/$PB"/*.plist | sed 's/^/  /'

echo
if [ "$fail" -ne 0 ]; then echo "!! 核验未通过"; exit 1; fi
echo "== 核验通过 =="
sha256sum "$DEB"
