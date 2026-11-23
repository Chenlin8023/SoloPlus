# Solo+（Solo 1.0.1 增强包）

Solo+ 是 **Solo 1.0.1** 的运行时增强层，不修改 Solo 本体。
当前版本：**1.0.0**（iPhone 15 Pro / iOS 17.2.1 / RootHide 实机验收）。

> 本项目是非官方增强包，与 Solo 作者 OaksTheAwesome、Atria 作者 ren7995 均无隶属关系。
> 仓库**不包含** Solo 原包、Solo 原 dylib 或任何合并后的二进制；使用前需自行安装正式版 Solo 1.0.1。

## 功能

| 入口 | 功能 | 说明 |
|---|---|---|
| 增强 → 状态栏 | 保留系统状态栏 | Solo 在主页隐藏状态栏时，强制保持可见 |
| 增强 → Duo | 显示 Duo | 独立隐藏 Duo 状态环/读数，不影响轮播 |
| 增强 → Duo → 数据标识 | 5G 小号同基线 A | 仅 Duo 读数里的 `5G` 显示为 `5G` + 小号大写 `A`，A 与 5G 底部对齐；其余 LTE/3G/E/Wi-Fi 不变 |
| 增强 → Dockicon | Dock 6 图标 | 竖排 Dock 上限 5/6；6 个图标需手动拖入；切回 5 后注销会自动把最后一个图标迁回主屏 |
| 增强 → Dockicon | 图标大小 | 0.85–1.0，使用 `iconContentScale` 只缩图标内容，不改 Dock 列表几何 |
| 增强 → Dockicon | 自动下移 | 6 图标时 Dock 列表下移，避免与上方内容拥挤 |
| 增强 → 轮播铺满 | 轮播挂件铺满 | 复位 Solo 的 content scale fix（约 0.83），让小组件铺满 364×170 轮播背景；可能裁切小组件边缘 |

所有功能均为运行时 hook，不修改 `Solo.dylib`。面板注入到 Solo 自带设置页的「增强」分组。

## 兼容性

- **Solo 1.0.1**（`com.oakstheawesome.solo`）
- iPhone 15 Pro · iOS 17.2.1 · RootHide（roothide Bootstrap）
- rootless 包（`/var/jb`，`iphoneos-arm64`）
- Dock 6 图标/竖排布局依赖 **Atria**（实测 1.4.1-11）；未安装 Atria 时只保留基础功能

## 安装

### 推荐：伴随包 + 官方 Solo

1. 从 Solo 官方渠道安装 `com.oakstheawesome.solo` 1.0.1；
2. 安装 `com.chenlin8023.soloplus_1.0.0_iphoneos-arm64.deb`；
3. respring。

伴随包不改 Solo 文件，卸载 Solo+ 不会移除 Solo。

### 本地合并包（不随仓库分发）

`build_merged.sh` 可把 Solo 原包与 Solo+ 合并为单包，便于本地测试：

```bash
# 先准备 vendor/Solo_1.0.1.deb（自行从官方渠道获取，不要提交到仓库）
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build.sh
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build_merged.sh
```

合并包内含 Solo 原文件，**是否可再分发取决于 Solo 的授权**；开源仓库不包含合并包。

## 已知限制

- Dock 拖动/换位仍有可感知卡顿，当前版本不再继续优化。
- Dock 内放文件夹时不建议同时开启 6 图标；Atria/Solo 的文件夹布局与 6 槽组合存在不稳定风险。
- 切回 5 图标并注销后，约 3 秒会把 Dock 最后一个图标迁回主屏第一处可放页面；若主屏无处可放，会保持 6 图标并写日志，不会强制踢出。
- 轮播铺满会让小组件按原生尺寸填充背景，边缘可能被裁切；可在「轮播铺满」页关闭。
- 数据标识替换只作用于 Duo 读数，不改系统状态栏。
- 依赖 Solo 私有实现（`UnduoWidgetCarousel`、`SBDockIconListView`、`SBIconListModel` 等），Solo 或 iOS 升级后可能需要适配。

## 构建

依赖：

- WSL2 Ubuntu 22.04
- Theos
- clang19 工具链（`~/tc19/linux/iphone/bin`）
- Python 3（PAC 补丁/校验脚本）

```bash
# 1) 构建伴随包
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build.sh

# 2) 可选：本地合并包（需 vendor/Solo_1.0.1.deb）
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build_merged.sh
```

构建流程：FAT `arm64 + arm64e` → arm64e `__cfstring` isa PAC 补丁 → `ldid -S` → 断言
`isa: auth>0 plain=0` → `dpkg-deb -b -Zxz`。

若要让 SpringBoard 加载 arm64e 切片，必须保持 FAT 双切片；单 arm64 切片会被 dyld 静默拒载。

## 仓库结构

```
SoloPlus.xm                 # 全部增强逻辑（C/ObjC runtime + Substrate）
SoloPlus.plist              # SpringBoard / Preferences 注入过滤
Makefile                    # Theos tweak（rootless）
control                     # 伴随包元信息
layout/.../SoloPrefs.bundle # 注入 Solo 设置页的面板 plist
build.sh                    # 伴随包构建 + PAC 补丁/断言
build_merged.sh             # 本地合并包（需自备 vendor/Solo_1.0.1.deb）
tools/patch_arm64e.py       # arm64e CFString isa PAC 补丁
tools/verify_fixups.py      # 终审断言
```

`vendor/`、`packages/`、`.theos/` 均被 `.gitignore` 排除。

## 反馈

请附：

- 设备型号、iOS 版本、越狱形态（RootHide/rootless）
- Solo 版本
- Solo 调试报告中的 `[Solo+]` 行（尤其 `dock` / `carousel fill` / `auto-evict`）

## 致谢与许可

- Solo：OaksTheAwesome
- Atria：ren7995
- Solo+ 代码：MIT License，见 [LICENSE](LICENSE)

Solo、Atria 的原二进制与商标归各自作者所有；本仓库不包含、也不授权分发它们。
