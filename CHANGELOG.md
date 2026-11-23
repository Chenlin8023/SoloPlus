# Changelog

All notable changes to Solo+ are documented here.
The project is an unofficial runtime enhancement layer for Solo 1.0.1.

## 1.0.0 — 2026-11-23

First feature-complete release, verified on iPhone 15 Pro / iOS 17.2.1 / RootHide.

### Added

- **状态栏**：Solo 在主页隐藏状态栏时强制保留系统状态栏。
- **Duo 展示**：独立开关隐藏 Duo 状态环/读数，轮播仍可单独使用。
- **数据标识**：Duo 读数中的 `5G` 显示为 `5G` + 小号大写 `A`（A 62% 字号、同基线）；其他制式不变。
- **Dockicon**：
  - 竖排 Dock 图标上限 5/6（依赖 Atria）。
  - 图标大小 0.85–1.0，使用 `SBIconView.iconContentScale`，不改 Dock 列表几何。
  - 6 图标时 Dock 自动下移。
  - 6→5 切换后注销，约 3 秒自动把 Dock 最后一个图标迁回主屏可放页面；失败回滚并保持 6 图标，不依赖 SpringBoard 强踢。
  - 有效上限不低于当前图标数，避免切换容量时进安全模式。
  - Dock model 使用指针身份匹配，文件夹内部模型不会误套 Dock 容量/gridSize。
- **轮播铺满**：复位 Solo 的轮播 content scale fix（约 0.83），让小组件铺满 364×170 轮播背景；可在面板关闭。

### Fixed during development

- 状态栏 alpha 动画被 Solo 重复隐藏。
- Dock 子页空白（重命名 Dockicon + 子页加载日志）。
- Dock 图标缩放命中错误对象、动画回拉、重复相乘。
- 6 图标拖动坐标方向错误（`gridSize` 6×1 → 1×6）。
- Dock 打开/关闭 App、文件夹时落点二次纠正（父层 transform → iconContentScale）。
- 切回 5 图标时 SpringBoard 强制弹出多余图标导致安全模式。

### Known limitations

- Dock 拖动/换位仍有卡顿。
- Dock 内文件夹 + 6 图标组合不建议同时使用。
- 轮播铺满可能裁切小组件边缘。
- 依赖 Solo 1.0.1 私有实现，Solo/iOS 升级后可能需要适配。

## 0.9.0 — 2026-11-23

- 新增「轮播铺满」页，复位轮播小组件 content scale fix。

## 0.8.7 — 2026-11-23

- Dock 缩放改用 `iconContentScale`，修复打开/关闭落点偏移。
- 6→5 注销后自动迁回多余图标；失败回滚。
- 有效上限不低于当前图标数。

## 0.8.6 — 2026-11-23

- Dock 防呆：容量不低于当前图标数；Dock model 指针身份匹配，隔离文件夹模型。

## 0.8.5 — 2026-11-23

- 修正 Dock `gridSize` 方向为竖排 1×N。

## 0.8.4 — 2026-11-23

- Dock 缩放改为父层 transform（后续被 0.8.7 的 iconContentScale 取代，以修复落点偏移）。

## 0.8.0–0.8.3 — 2026-11-23

- Dock 6 图标容量、图标大小、自动下移。
- 5G 角标 A、Dockicon 子页、`isFull/canAddIcon/gridSize` drop 校验。

## 0.1.0–0.7.2 — 2026-11-22/23

- 初始状态栏开关、Duo 展示、数据标识、面板注入、Dock 研究迭代。
