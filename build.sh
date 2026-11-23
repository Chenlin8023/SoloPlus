#!/bin/bash
# Solo+ rootless 构建脚本（WSL 内运行）
#   wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build.sh
# 与 LSTimeSeconds rootless 流水线一致：
#   1) 拷到 WSL 家目录构建（避开 /mnt/d 的 777 权限与 CRLF）
#   2) clang19 + ld64，arm64 + arm64e，rootless /var/jb
#   3) 解包 → arm64e __cfstring isa PAC 补丁 → ldid -S → chmod → 重打包
#   4) 终审断言 arm64e __cfstring isa: auth>0, plain=0
set -u

export THEOS="$HOME/theos"
export PATH="$HOME/tc19/linux/iphone/bin:$THEOS/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

SRC="$(cd "$(dirname "$0")" && pwd)"
DST="$HOME/soloplus_build"
TC19="$HOME/tc19/linux/iphone/bin"

die() { echo "!! $*"; exit 1; }
[ -x "$TC19/clang" ] || die "clang19 不存在: $TC19/clang"

rm -rf "$DST"; mkdir -p "$DST"
cp -r "$SRC"/. "$DST"/
rm -rf "$DST/.git" "$DST/packages" "$DST/.theos"
find "$DST" -type f \( -name "*.xm" -o -name "*.m" -o -name "*.h" -o -name "*.plist" \
    -o -name "*.strings" -o -name "*.sh" -o -name "Makefile" -o -name "control" \) \
    -exec sed -i 's/\r$//' {} \; 2>/dev/null

cd "$DST" || die "无法进入 $DST"
make clean >/dev/null 2>&1 || true
rm -rf packages .theos

echo "=== 编译（clang19，arm64 + arm64e，rootless /var/jb）==="
make package FINALPACKAGE=1 \
    THEOS_PACKAGE_INSTALL_PREFIX=/var/jb \
    TARGET_CC="$TC19/clang" TARGET_CXX="$TC19/clang++" TARGET_LD="$TC19/clang++" \
    TARGET_CODESIGN="$TC19/ldid" 2>&1 | tail -40 || die "编译失败"

DEB=$(ls -1t packages/*.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || die "没有生成 deb"
echo "生成 deb: $DEB"

echo "=== 解包 + arm64e PAC 补丁 + 重签 ==="
rm -rf "$DST/repack"; mkdir -p "$DST/repack"
dpkg-deb -R "$DEB" "$DST/repack" || die "dpkg-deb -R 失败"

DYLIB="$DST/repack/var/jb/Library/MobileSubstrate/DynamicLibraries/SoloPlus.dylib"
[ -f "$DYLIB" ] || die "包里没有 SoloPlus.dylib（检查 /var/jb 前缀）"

python3 "$DST/tools/patch_arm64e.py" "$DYLIB" || die "arm64e PAC 补丁失败"
python3 "$DST/tools/verify_fixups.py" "$DYLIB" || die "arm64e 终审断言失败"
"$TC19/ldid" -S "$DYLIB" || die "ldid 签名失败"
chmod 755 "$DYLIB"

find "$DST/repack/var/jb" -type d -exec chmod 755 {} +
find "$DST/repack/var/jb" -type f ! -path "$DYLIB" -exec chmod 644 {} +

OUT="$SRC/packages"
mkdir -p "$OUT"
FINAL="$OUT/com.chenlin8023.soloplus_$(grep '^Version:' "$DST/control" | awk '{print $2}')_iphoneos-arm64.deb"
rm -f "$FINAL"
dpkg-deb -b -Zxz "$DST/repack" "$FINAL" >/dev/null || die "重打包失败"
echo "=== 完成: $FINAL ==="
dpkg-deb -c "$FINAL" | sed -n '1,40p'
