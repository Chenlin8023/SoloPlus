#!/bin/bash
# 把 Solo 原包 + 当前 SoloPlus 增强包合并成“一个包”：
#   - 包 id 保持 com.oakstheawesome.solo（升级链不断）
#   - 版本 = 1.0.1+sp<companion 版本>
#   - 内含 Solo 原文件 + SoloPlus.dylib + SoloPrefs.bundle/SoloPlus.plist
#   - 与独立的 com.chenlin8023.soloplus 冲突（安装前需卸载它，避免双注入）
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

echo "=== 合并 control（Solo 原 control + Solo+ 说明）==="
python3 - "$DST/merged/DEBIAN/control" "1.0.1+sp$COMP_VER" <<'PY'
import sys, re, io
path, newver = sys.argv[1], sys.argv[2]
raw = open(path, encoding='utf-8').read()
lines = raw.splitlines()
out = []
desc_done = False
for ln in lines:
    if ln.startswith('Version:'):
        out.append('Version: ' + newver); continue
    if ln.startswith('Name:'):
        out.append('Name: Solo+（增强）'); continue
    if ln.startswith('Conflicts:'):
        continue
    if ln.startswith('Replaces:'):
        continue
    out.append(ln)
    if ln.startswith('Description:'):
        out.append(' Solo+ 已集成：设置 → Solo → 状态栏（保留系统状态栏开关）。')
        out.append(' 本地增强包，非上游官方；卸载本包会一并移除 Solo。')
        out.append(' Conflicts 独立补丁包 com.chenlin8023.soloplus。')
        desc_done = True
# insert Conflicts/Replaces after Depends block
final = []
for ln in out:
    final.append(ln)
    if ln.startswith('Depends:') and not any(x.startswith('Conflicts:') for x in final):
        final.append('Conflicts: com.chenlin8023.soloplus')
        final.append('Replaces: com.chenlin8023.soloplus')
if not any(x.startswith('Conflicts:') for x in final):
    final.append('Conflicts: com.chenlin8023.soloplus')
    final.append('Replaces: com.chenlin8023.soloplus')
open(path, 'w', encoding='utf-8').write('\n'.join(final) + '\n')
print('\n'.join(final[:16]))
PY

# Installed-Size 重算
SIZE=$(du -sk "$DST/merged" | awk '{print $1}')
python3 - "$DST/merged/DEBIAN/control" "$SIZE" <<'PY'
import sys
p, size = sys.argv[1], sys.argv[2]
lines = open(p, encoding='utf-8').read().splitlines()
out = []
done = False
for ln in lines:
    if ln.startswith('Installed-Size:'):
        out.append('Installed-Size: ' + size); done = True
    else:
        out.append(ln)
if not done:
    out.append('Installed-Size: ' + size)
open(p, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
PY

chmod 755 "$DL/SoloPlus.dylib"
chmod 644 "$DL/SoloPlus.plist" "$PB/"SoloPlus*.plist
find "$DST/merged/var/jb" -type d -exec chmod 755 {} +
find "$DST/merged/var/jb" -type f -name "*.dylib" -exec chmod 755 {} +

OUT="$SRC/packages/Solo_1.0.1+sp${COMP_VER}_iphoneos-arm64.deb"
rm -f "$OUT"
dpkg-deb --root-owner-group -b -Zxz "$DST/merged" "$OUT" >/dev/null || die "合并打包失败"
echo "=== 完成: $OUT ==="
dpkg-deb -I "$OUT" | sed -n '1,18p'
echo "--- 关键文件 ---"
dpkg-deb -c "$OUT" | grep -E "SoloPlus|SoloPrefs.bundle/(Root|SoloPlus)" || true
