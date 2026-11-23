# Solo+ 1.0.0 — Release Notes

日期：2026-11-23
适用：Solo 1.0.1 · iPhone 15 Pro / iOS 17.2.1 / RootHide

Solo+ 1.0.0 是首个功能完整版本，作为 Solo 1.0.1 的运行时增强层，不修改 Solo 本体。

## 功能

- 状态栏：Solo 隐藏系统状态栏时强制保留。
- Duo：独立显示/隐藏 Duo 状态环与读数。
- 数据标识：Duo 内 `5G` 显示为 `5G` + 小号大写 `A`（同基线，62% 字号），其他制式不变。
- Dockicon：
  - 竖排 Dock 图标上限 5/6（依赖 Atria）。
  - 图标大小 0.85–1.0，使用 `iconContentScale`，不改变 Dock 列表几何。
  - 6 图标自动下移。
  - 6→5 注销后自动把最后一个图标迁回主屏；失败回滚并保持 6 图标，不强制弹出。
- 轮播铺满：复位 Solo 的 content scale fix，让轮播小组件铺满 364×170 背景，可在面板关闭。

## 已知限制

- Dock 拖动/换位仍有卡顿。
- Dock 内文件夹不建议与 6 图标同时使用。
- 轮播铺满可能裁切小组件边缘。
- 依赖 Solo 1.0.1 私有实现，Solo/iOS 升级后可能需要适配。

## 产物

伴随包（推荐发布/安装）：

```
com.chenlin8023.soloplus_1.0.0_iphoneos-arm64.deb
SHA-256: 422feec96c774a7bae226ef80c43064245c53cfc984adb44069e7323db1d14fa
```

本地合并包（内含 Solo 原文件，仅本地测试，不随仓库分发）：

```
Solo_1.0.1+sp1.0.0_iphoneos-arm64.deb
SHA-256: 2d262f5cd5dbe32b77d1ced0b26b1fb45ea72ec1079383f4c7d92f009757c54c
```

## 安装

1. 从 Solo 官方渠道安装 `com.oakstheawesome.solo` 1.0.1。
2. 安装伴随包。
3. respring。

## 许可

Solo+ 源码使用 MIT License；Solo 与 Atria 的二进制、源码和商标归各自作者所有。
本发行说明不构成对 Solo 原包再分发的授权。
