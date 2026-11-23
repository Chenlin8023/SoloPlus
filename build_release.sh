#!/bin/bash
# 发布版：Solo 1.0.1 + Solo+ 合并单包 ——「Solo1.0.1优化」
#
# 与 build_merged.sh 默认（本地测试）口径的区别：
#   * 独立 Package ID com.chenlin8023.solo.full —— 不改写官方 com.oakstheawesome.solo，
#     也不会把官方包在别的源里“顶版本”；安装时用 Conflicts/Replaces 替换官方 Solo 与
#     独立增强包 com.chenlin8023.soloplus，避免双注入。
#   * 显示名 Solo1.0.1优化（Package id 稳定，后续只递增 -N 修订号）。
#
# 用法（Git Bash 里记得 MSYS_NO_PATHCONV=1）：
#   wsl -d Ubuntu-22.04 -- bash /mnt/d/WorkBudy/iOS-Tweaks/SoloPlus/build_release.sh
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
RELEASE_DIR="${RELEASE_DIR:-$(cd "$SRC/.." && pwd)/release}"
VERSION="${PKG_VERSION:-1.0.1-1}"

export PKG_ID="com.chenlin8023.solo.full"
export PKG_NAME="Solo1.0.1优化"
export PKG_VERSION="$VERSION"
export PKG_MAINTAINER="Chenlin8023"
export PKG_AUTHOR="OaksTheAwesome & Chenlin8023"
export PKG_DEPENDS="mobilesubstrate (>= 0.9.5000), preferenceloader"
export PKG_CONFLICTS="com.oakstheawesome.solo, com.chenlin8023.soloplus"
export PKG_REPLACES="com.oakstheawesome.solo, com.chenlin8023.soloplus"
export OUT_DEB="com.chenlin8023.solo.full_${VERSION}_iphoneos-arm64.deb"
export PKG_DESCRIPTION='Solo 1.0.1 与 Solo+ 增强层合并的完整单包（安装即用）。
增强：系统状态栏保留 / Duo 独立开关与时间开关 / 5G 小号 A /
Duo 圆环下方电量 / 桌面歌词悬浮窗 / Dockicon 6 图标与内容缩放 / 轮播铺满；入口在 Solo 面板「增强」。
基于 Solo 1.0.1（OaksTheAwesome）；增强层 MIT，见项目仓库。
已知限制：Dock 重排偶有卡顿；Dock 内文件夹不建议同时开 6 图标；
轮播铺满可能裁切小组件边缘。'

echo "=== 1/2 构建伴随包（clang19 + arm64e PAC 补丁/断言）==="
bash "$SRC/build.sh"

echo "=== 2/2 合并成发布版单包 ==="
bash "$SRC/build_merged.sh"

DEB="$SRC/packages/$OUT_DEB"
[ -f "$DEB" ] || { echo "!! 没有生成 $DEB"; exit 1; }
mkdir -p "$RELEASE_DIR"
cp -f "$DEB" "$RELEASE_DIR/"

echo "=== 交付 ==="
ls -l "$DEB" "$RELEASE_DIR/$OUT_DEB"
sha256sum "$DEB"
