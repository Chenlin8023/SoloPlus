#!/bin/bash
# 把 Solo 原包 + 当前 SoloPlus 增强包合并成“一个包”。
#
# 默认（本地测试口径）：
#   - 包 id 保持 com.oakstheawesome.solo（升级链不断）
#   - 版本 = 1.0.1+sp<companion 版本>
#   - 内含 Solo 原文件 + SoloPlus.dylib + SoloPrefs.bundle/SoloPlus*.plist
#   - 与独立的 com.chenlin8023.soloplus 冲突（安装前需卸载它，避免双注入）
#
# 发布口径由 build_release.sh 用环境变量覆盖：PKG_ID / PKG_NAME / PKG_VERSION /
# PKG_MAINTAINER / PKG_AUTHOR / PKG_DEPENDS / PKG_CONFLICTS / PKG_REPLACES /
# PKG_DESCRIPTION / OUT_DEB。空字符串 = 删除该字段。
set -u

SRC="$(cd "$(dirname "$0")" && pwd)"
ORIG="$SRC/vendor/Solo_1.0.1.deb"
DST="$HOME/soloplus_merge"

die() { echo "!! $*"; exit 1; }
[ -f "$ORIG" ] || die "缺少 vendor/Solo_1.0.1.deb"

COMPANION=$(ls -1t "$SRC"/packages/com.chenlin8023.soloplus_*.deb 2>/dev/null | head -1)
[ -n "$COMPANION" ] || die "没有 companion deb，先运行 build.sh"
COMP_VER=$(dpkg-deb -f "$COMPANION" Version)
[ -n "$COMP_VER" ] || die "读不到 companion 版本"

PKG_ID="${PKG_ID:-com.oakstheawesome.solo}"
PKG_NAME="${PKG_NAME:-Solo+（增强）}"
PKG_VERSION="${PKG_VERSION:-1.0.1+sp$COMP_VER}"
PKG_MAINTAINER="${PKG_MAINTAINER:-OaksTheAwesome}"
PKG_AUTHOR="${PKG_AUTHOR:-OaksTheAwesome}"
PKG_DEPENDS="${PKG_DEPENDS:-mobilesubstrate (>= 0.9.5000), preferenceloader}"
PKG_CONFLICTS="${PKG_CONFLICTS-com.chenlin8023.soloplus}"
PKG_REPLACES="${PKG_REPLACES-com.chenlin8023.soloplus}"
PKG_DESCRIPTION="${PKG_DESCRIPTION:-An iPhone Duo inspired UI tweak
Solo+ 已集成：设置 → Solo → 增强（状态栏 / Duo / 轮播铺满 / Dockicon）。
本地增强层，非上游官方；卸载本包会一并移除 Solo。}"
OUT_DEB="${OUT_DEB:-Solo_1.0.1+sp${COMP_VER}_iphoneos-arm64.deb}"

rm -rf "$DST"; mkdir -p "$DST"
dpkg-deb -R "$ORIG" "$DST/merged" || die "解包 Solo 原包失败"
dpkg-deb -x "$COMPANION" "$DST/comp" || die "解包 companion 失败"

DL="$DST/merged/var/jb/Library/MobileSubstrate/DynamicLibraries"
PB="$DST/merged/var/jb/Library/PreferenceBundles/SoloPrefs.bundle"
[ -d "$DL" ] || die "原包结构异常（无 DynamicLibraries）"
[ -d "$PB" ] || die "原包结构异常（无 SoloPrefs.bundle）"

cp "$DST/comp/var/jb/Library/MobileSubstrate/DynamicLibraries/SoloPlus.dylib" "$DL/" || die "缺少 SoloPlus.dylib"
cp "$DST/comp/var/jb/Library/MobileSubstrate/DynamicLibraries/SoloPlus.plist" "$DL/" || die "缺少 SoloPlus.plist"
cp "$DST/comp/var/jb/Library/PreferenceBundles/SoloPrefs.bundle/"SoloPlus*.plist "$PB/" || die "缺少面板 SoloPlus*.plist"

echo "=== 合并 control ==="
SIZE=$(du -sk "$DST/merged" | awk '{print $1}')
export PKG_ID PKG_NAME PKG_VERSION PKG_MAINTAINER PKG_AUTHOR PKG_DEPENDS \
       PKG_CONFLICTS PKG_REPLACES PKG_DESCRIPTION SIZE
python3 - "$DST/control-spec.json" <<'PY'
import json, os, sys
env = os.environ
spec = {
    "Package": env["PKG_ID"],
    "Name": env["PKG_NAME"],
    "Version": env["PKG_VERSION"],
    "Maintainer": env["PKG_MAINTAINER"],
    "Author": env["PKG_AUTHOR"],
    "Depends": env["PKG_DEPENDS"],
    "Conflicts": env.get("PKG_CONFLICTS", ""),
    "Replaces": env.get("PKG_REPLACES", ""),
    "Installed-Size": env["SIZE"],
    "Description": env["PKG_DESCRIPTION"],
}
with open(sys.argv[1], "w", encoding="utf-8") as fp:
    json.dump(spec, fp, ensure_ascii=False, indent=2)
    fp.write("\n")
PY
python3 "$SRC/tools/rewrite_control.py" "$DST/merged/DEBIAN/control" "$DST/control-spec.json" \
    || die "control 重写失败"

chmod 755 "$DL/SoloPlus.dylib" "$DL/Solo.dylib" "$PB/SoloPrefs"
chmod 644 "$DL/SoloPlus.plist" "$DL/Solo.plist" "$PB/"SoloPlus*.plist
find "$DST/merged/var/jb" -type d -exec chmod 755 {} +
find "$DST/merged/var/jb" -type f -name "*.dylib" -exec chmod 755 {} +

echo "=== 合并产物终审（arm64e PAC 断言）==="
python3 "$SRC/tools/verify_fixups.py" "$DL/SoloPlus.dylib" || die "合并包 arm64e 终审断言失败"

OUT="$SRC/packages/$OUT_DEB"
rm -f "$OUT"
dpkg-deb --root-owner-group -b -Zxz "$DST/merged" "$OUT" >/dev/null || die "合并打包失败"
echo "=== 完成: $OUT ==="
dpkg-deb -I "$OUT" | sed -n '1,20p'
echo "--- 关键文件 ---"
dpkg-deb -c "$OUT" | grep -E "SoloPlus|/Solo\.dylib|SoloPrefs.bundle/(Root|SoloPlus|SoloPrefs$)" || true
