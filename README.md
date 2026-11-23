# Solo+（Solo 1.0.1 增强包）

Solo+ 是 **Solo 1.0.1** 的运行时增强层，不修改 Solo 本体。

发布形态：

- **合并完整版「Solo1.0.1优化」**（`com.chenlin8023.solo.full`，`1.0.1-24`）——Solo 1.0.1 本体 + Solo+ 1.3.8 合为单包，已上架越狱源 `https://chenlin8023.github.io/`；
- **独立增强包**（`com.chenlin8023.soloplus`，`1.3.8`）——只含增强层，需自备官方 Solo 1.0.1，本地自用。

> 本项目是非官方增强包，与 Solo 作者 OaksTheAwesome、Atria 作者 ren7995 均无隶属关系。
> 源码仓库**不包含** Solo 原包或合并产物；合并版 deb 由打包方在自有源站发布，未获上游再分发授权，请勿二次转载。

## 功能

| 入口 | 功能 | 说明 |
|---|---|---|
| 增强 → 状态栏 | 保留系统状态栏 | Solo 在主页隐藏状态栏时强制保持可见；与 Lunora 等自绘状态栏的美化插件共存——未美化区域听 Solo 强制显示，美化插件渲染的区域（按其覆盖层胶囊配置识别）自动让位 |
| 增强 → Duo | 显示 Duo | 独立隐藏 Duo 状态环/读数，不影响轮播 |
| 增强 → Duo → 数据标识 | 5G 小号同基线 A | 仅 Duo 读数里的 `5G` 显示为 `5G` + 小号大写 `A`，A 与 5G 底部对齐；其余 LTE/3G/E/Wi-Fi 不变 |
| 增强 → Duo → Duo 细节 | 显示 Duo 时间 | 只隐藏 Duo 容器内的时间文字（大时钟/轮播时钟页不受影响）；默认开 |
| 增强 → Duo → Duo 细节 | Duo 下方电量 | Duo 整行下方显示剩余电量百分比；与读数同字族字重；≤20% 红色、充电绿色；默认开 |
| 增强 → Duo → Duo 细节 | 隐藏 Duo 下方图标 | 隐藏读数下方的定位箭头等图片类符号（≤44pt），不碰电量标签；默认开 |
| 增强 → Duo → Duo 细节 | 电量上下微调 | -8 / -4 / 0 / +4 / +8 pt，位置不合适时手动推一档 |
| 增强 → Dockicon | Dock 6 图标 | 竖排 Dock 上限 5/6；6 个图标需手动拖入；切回 5 后注销会自动把最后一个图标迁回主屏 |
| 增强 → Dockicon | 图标大小 | 0.85–1.0，使用 `iconContentScale` 只缩图标内容，不改 Dock 列表几何 |
| 增强 → Dockicon | 自动下移 | 6 图标时 Dock 列表下移，避免与上方内容拥挤 |
| 增强 → 轮播铺满 | 轮播挂件铺满 | 复位 Solo 的 content scale fix（约 0.83），让小组件铺满 364×170 轮播背景；可能裁切小组件边缘 |

所有功能均为运行时 hook，不修改 `Solo.dylib`。面板注入到 Solo 自带设置页的「增强」分组。

## 兼容性

- **Solo 1.0.1**（`com.oakstheawesome.solo`）
- iPhone 15 Pro · iOS 17.2.1 · RootHide（roothide Bootstrap）；iPhone 14 Pro Max · iOS 16.5
- 与 **Lunora** 美化插件的状态栏共存已实测（未美化区域听 Solo、美化区域让位，区域随其胶囊配置自适应）
- rootless 包（`/var/jb`，`iphoneos-arm64`）
- Dock 6 图标/竖排布局依赖 **Atria**（实测 1.4.1-11）；未安装 Atria 时只保留基础功能

## 安装

### 方式一：从源站装合并版（推荐）

1. 添加源 `https://chenlin8023.github.io/`；
2. 安装 **Solo1.0.1优化**（`com.chenlin8023.solo.full`，1.0.1-24）——包内含 Solo 1.0.1，安装时自动替换官方 Solo 与旧独立增强包（`Conflicts/Replaces`），不会双注入；
3. respring。

卸载合并包会一并移除 Solo 本体；需要时再从 Solo 官方源装回。后续升级只递增修订号（`1.0.1-2` …），`Package:` 不变。

### 方式二：官方 Solo + 独立增强包

1. 从 Solo 官方渠道安装 `com.oakstheawesome.solo` 1.0.1；
2. 安装 `com.chenlin8023.soloplus_1.3.8_iphoneos-arm64.deb`；
3. respring。

伴随包不改 Solo 文件，卸载 Solo+ 不会移除 Solo。

### 合并包构建（发布口径）

```bash
# 一次跑完：伴随包 → 合并 → 发布元信息 → 交付到 ../release/
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build_release.sh

# 发布前核验：Solo 原文件逐字节未改 / arm64+arm64e 双切片 / PAC 断言 / 权限位
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/tools/verify_release.sh
```

- `build_release.sh`：发布口径，`PKG_ID=com.chenlin8023.solo.full`、显示名 `Solo1.0.1优化`、`Conflicts/Replaces` 官方 Solo 与独立增强包；
- `build_merged.sh`：本地测试口径（id 沿用 `com.oakstheawesome.solo`，版本 `1.0.1+sp*`），可用 `PKG_ID`/`PKG_NAME`/`PKG_VERSION` 等环境变量覆盖；
- `tools/rewrite_control.py`：按 JSON 规格重写 control（新增/覆盖/删除字段，Description 置尾）。

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

# 2) 发布版合并包（Solo1.0.1优化，需 vendor/Solo_1.0.1.deb）
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/build_release.sh

# 3) 发布前核验
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-22.04 -- bash /mnt/d/path/to/SoloPlus/tools/verify_release.sh
```

构建流程：FAT `arm64 + arm64e` → arm64e `__cfstring` isa PAC 补丁 → `ldid -S` → 断言
`isa: auth>0 plain=0` → 与 Solo 原包合并（原文件不动）→ `dpkg-deb -b -Zxz`。

若要让 SpringBoard 加载 arm64e 切片，必须保持 FAT 双切片；单 arm64 切片会被 dyld 静默拒载。

## 仓库结构

```
SoloPlus.xm                 # 全部增强逻辑（C/ObjC runtime + Substrate）
SoloPlus.plist              # SpringBoard / Preferences 注入过滤
Makefile                    # Theos tweak（rootless）
control                     # 伴随包元信息
layout/.../SoloPrefs.bundle # 注入 Solo 设置页的面板 plist
build.sh                    # 伴随包构建 + PAC 补丁/断言
build_merged.sh             # 合并包（需 vendor/Solo_1.0.1.deb；元信息可用环境变量覆盖）
build_release.sh            # 发布版：Solo1.0.1优化（独立 id + Conflicts/Replaces）
tools/patch_arm64e.py       # arm64e CFString isa PAC 补丁
tools/verify_fixups.py      # 终审断言
tools/rewrite_control.py    # 按 JSON 规格重写 control
tools/verify_release.sh     # 发布前核验（原文件未改 / 双切片 / PAC / 权限）
```

`vendor/`、`packages/`、`.theos/` 均被 `.gitignore` 排除。

## 发布（越狱源）

| 项 | 值 |
|---|---|
| 源 | `https://chenlin8023.github.io/` |
| 显示名 | Solo1.0.1优化 |
| Package | `com.chenlin8023.solo.full` |
| 版本 | `1.0.1-24`（首个上架版 1.0.1-1；后续只递增修订号） |
| 架构 | `iphoneos-arm64`（rootless，`/var/jb`） |
| 替换 | `Conflicts/Replaces: com.oakstheawesome.solo, com.chenlin8023.soloplus` |
| deb | `debs/com.chenlin8023.solo.full_1.0.1-24_iphoneos-arm64.deb` |

源站索引只由 `root-site/tools/make_repo.py` 生成（`repo-meta.json` 为唯一元信息来源）；
上架/更新流程：`build_release.sh` → `tools/verify_release.sh` → deb 入 `root-site/debs/` →
`repo-meta.json` 加变体 → `make_repo.py --check` → 提交推送 → 线上回抓哈希校验。

## 反馈

请附：

- 设备型号、iOS 版本、越狱形态（RootHide/rootless）
- Solo 版本（合并版为 1.0.1 基线）
- Solo 调试报告中的 `[Solo+]` 行（尤其 `dock` / `carousel fill` / `auto-evict`）

## 致谢与许可

- Solo：OaksTheAwesome
- Atria：ren7995
- Solo+ 代码：MIT License，见 [LICENSE](LICENSE)

Solo、Atria 的原二进制与商标归各自作者所有；本源码仓库不包含它们。
合并版 deb 中的 Solo 原文件由打包方本机整合，仅在本源站发布，不构成上游再分发授权。
