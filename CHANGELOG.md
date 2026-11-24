# Changelog

All notable changes to Solo+ are documented here.
The project is an unofficial runtime enhancement layer for Solo 1.0.1.

## 1.3.25 — 2026-11-25（锁屏左列活跟随胶囊"锁屏可见"开关）

用户澄清胶囊有独立"锁屏可见"设置：ON 时锁屏左列由胶囊替换（Lunora 自渲染）；
OFF 时锁屏左列默认原生——但当前实测仍被压制隐藏。此前 1.3.21 的静态归属规则
（1.3.24 已撤）无法表达这个开关。1.0.1-39/40 实测确认的成果全部保留：keep=1
主屏全量保活 ✓、关 Lunora 恢复 ✓、锁屏右列原生 ✓。

- **锁屏还原扩展为左右双簇**（`sp_restore_lock_bar`，原右簇还原改名扩展）：
  - 右簇（x≥195）恒还原，语义不变；
  - 左簇活跟随：本实例 overlay 存在**有效左胶囊**（可见+真 frame+左半区，
    即"锁屏可见=ON"的活证据）→ 压制原生左列（胶囊替换语义）；无左胶囊且
    无第三方内容在场 → 还原原生左列（hidden/lh/alpha 全套）；
- **第三方内容保护**：左半区存在类名首字母小写的可见视图（混淆类名特征，
  如电话助手的 tZBkQAHVLGPTQwXC；系统/Lunora 类均大写开头）→ 左列归它，
  不还原不压制——避免 1.3.19 叠放回归；
- 已知边界维持：App 内胶囊×电话助手重合延后/配置规避（用户拍板）；Lunora
  切换胶囊配置需其引擎自刷新（用户实测开关一次）。

**验证矩阵**：胶囊开+锁屏可见 ON → 锁屏左列=胶囊；胶囊开+锁屏可见 OFF →
锁屏左列=原生；胶囊关 → 锁屏左列=原生/电话助手替换；主屏双胶囊、关 Lunora
恢复、App 内回归不变。

## 1.3.24 — 2026-11-25（锁屏左列归属规则撤销：锁屏永不随胶囊）

1.0.1-39 实测三态：关闭 Lunora 主屏恢复 ✓；Lunora 开+胶囊关全正常 ✓；锁屏
右列原生 ✓。**剩余问题定位**：开启左胶囊时锁屏左列原生被隐藏——那是 1.3.21
的"左胶囊在场→锁屏压制原生左列"规则在生效，而用户本轮期望已明确：**锁屏
左列永远该是原生/电话助手替换态，胶囊不进锁屏**（Lunora 本就不在锁屏渲染
胶囊）。1.3.21 那条规则按当时"叠加"现象反推，方向反了，整体撤销。

- **撤销锁屏左列归属**：删除 `gThemeLeftCapsuleSeen` 标记、
  `sp_note_capsules_gone()` 及全部调用点、`sp_restore_right_cluster` 的左列
  压制块——锁屏还原回到 1.3.20 语义（只动 x≥195 右簇，左列不碰）。
- 锁屏左列最终语义：**原生为底，电话助手"锁屏可见"时由其替换**（in-place，
  自己管理），任何情况下不受 Lunora 胶囊配置影响。
- 已知边界不变：App 内左胶囊×电话助手重合 = 进程边界（App 状态栏由 App
  进程渲染），非 SpringBoard 侧可修； Lunora 关闭/切换左胶囊后需其自身
  状态刷新（用户实测需开关一次 Lunora，属其引擎行为）。
- 1.3.23 的 keep=1 主屏全量保活继续生效（报告(11) L242-249 实证拦截正常）。

**验证要点**：开启左胶囊时锁屏左列恢复原生/电话助手替换显示；主屏双胶囊、
关闭 Lunora 主屏恢复、App 内（已知重合）回归不变。

## 1.3.23 — 2026-11-25（keep=1 主屏全量保活：修关闭 Lunora 后主屏无状态栏）

用户三态实测判读：Lunora 开+胶囊关 ✓（共存成立）；锁屏左胶囊右原生 ✓（归属
模型成立）；**Lunora 关 → 主屏状态栏整体消失** ✗。

根因：关闭 Lunora 只是它的 overlay 消失，引擎与钩子仍在运行、压暗指令照发
（dylib 无法卸载）。此前主屏 hide 路径的最终分支把"caller=other 且无主题覆盖"
当作系统自身行为**放行**——Lunora 的压暗恰好落到这个分支 → 原生栏被隐藏且
无任何状态栏可看（报告(8) L160/260/401 实证）。

- **keep=1 主屏全量保活**：主屏语境的整条隐藏（alpha→0）一律拦回（caller=
  solo/other 一视同仁），主题在场时照旧附带让位。keep=0 不受影响（更早放行
  归 Solo）。日志改为 `blocked statusbar hide ... (no theme, keep=1)`。
- 已知边界（非本包可修）：**App 内**左胶囊与电话助手内容重合——App 状态栏
  由 App 进程渲染，SpringBoard 注入的 SoloPlus/Lunora-电话助手仲裁都够不到；
  属 Lunora×电话助手的 App 内冲突，需其二者配置规避或未来做按 App 注入的
  独立模块。

**验证要点**：关闭 Lunora（不注销）后主屏状态栏立即恢复且稳定；开启后双胶囊
照常；锁屏/App 内回归不变。

## 1.3.22 — 2026-11-25（三者归属模型定案：护栏语境收口 + 胶囊态解除自愈）

用户定案三层形态语义——**Solo**＝原生栏总开关（keepStatusBar 门控其整条隐藏）；
**电话助手**＝在原生栏内 in-place 修改，改哪侧替哪侧（原生载体保持可见即是其
显示形态，对 SoloPlus 透明，无需特殊处理）；**Lunora**＝压制原生 + 悬浮胶囊，
按侧生效。对 SoloPlus 而言每侧只有两态：Lunora 占有（压原生）与非 Lunora
（原生载体不动）。优先级 Lunora > 电话助手 > 原生。

- **护栏语境收口**：1.3.18 把 SBMainSwitcherWindow 无条件纳入锁屏护栏，解锁
  状态下把 Lunora 的主屏样式（整条压暗+胶囊悬浮）也拦死了（报告(6) L487-496
  ×10 实证）。1.3.22 起护栏与还原共用同一判定 `sp_should_restore_lock_bar`：
  CoverSheet 恒定，MainSwitcher/StatusBarWindow 仅 UI 锁定时——解锁态切换器
  回归主屏规则（keep=1 按共存规则拦+让位；keep=0 放行归 Solo）。
- **胶囊态解除自愈**：`sp_sb_assert_on_layout` 主屏路径"overlay 在但胶囊失效
  且不在宽限"此前什么都不做，让位 alpha=0 滞留——这就是"关闭 Lunora 后右侧
  不显示原生"的直接原因。现在该分支收回让位；show/attach 的主屏无覆盖层路径
  同步补齐。
- **左列归属标记精确化**：新增 `sp_note_capsules_gone()`，只在主屏语境观测到
  胶囊态解除时清 `gThemeLeftCapsuleSeen`；语境切换类 restore（App 内/锁屏）
  不清——否则锁屏期间左列压制被误解除（叠加回归）。
- 1.3.21 的锁屏左列归属、右簇还原 x≥195、锁定闸右半区限定、双点取证全部
  继续生效。

**验证要点**：① 关闭 Lunora（建议注销一次）后主屏右列原生回归；② 主屏双胶囊
照常（含切换器手势时的切换器栏）；③ 锁屏右列原生 + 左列随归属（左胶囊启用压
原生左列 / 左列电话助手时显示其内容）；④ App 内状态栏完整。

## 1.3.21 — 2026-11-25（锁屏左列归属：Lunora 左胶囊启用时压制原生左列）

用户澄清三层形态与优先级模型：纯原生 < 电话助手修改（in-place 替换语义）<
Lunora 自绘（隐藏语义）；**Lunora > 电话助手 > 原生**。左列从电话助手切换为
Lunora 胶囊后，锁屏左侧出现原生叠加——1.3.19 的锁定让位闸 blanket restore
把左簇也收回来了（左胶囊启用后左列内容同样被让位过），原生左列与胶囊同屏。
1.3.20 的右列修复（x≥195）保持不变且继续有效。

- **左胶囊在场标记**（`gThemeLeftCapsuleSeen`）：主屏让位时记录最近一次
  Lunora 胶囊布局是否含左半区（x<195）有效胶囊——作为"左列归属 Lunora"的
  配置观测（关闭左胶囊后标记自动清除，电话助手 in-place 内容照常显示）。
- **锁屏左列随归属**：`sp_restore_right_cluster` 在还原语境下，若左胶囊在场
  则压制原生左列（alpha→0，只压 alpha 不动 hidden）；无左胶囊时不触碰左半区。
- **锁定闸改右半区限定**：`sp_apply_theme_yield` 锁定期间只收回 x≥195 的
  让位子视图，左簇保持让位态，由还原函数统一裁决——消除 blanket restore
  造成的叠加。
- **日志预算扩容**（防深会话失明）：lock guard 8→24、attach dump 2→6、
  终态取证 4→8；`lock restore` 行追加 `leftCaps=` 字段。

**验证要点**：锁屏左列只显示 Lunora 胶囊（无原生叠放）；右列原生继续正常；
左列切回电话助手后锁屏左列恢复其内容；回主屏双胶囊照常。若锁屏左列变为
空白（Lunora 不在锁屏渲染胶囊），反馈后把左列归属改为"锁屏保持原生"。

## 1.3.20 — 2026-11-25（右簇还原收窄到 x≥195：修左列叠放）

1.3.19 实机反馈：锁屏右列原生已正常显示（右簇修复成立），但**左列叠放**——
还原把左列 STUIStatusBar*（时间 StringView 等）也一并复位了，而该用户的
Lunora 配置（左原生/右胶囊）下，左列被 Solo 锁屏内容"替换原生"是正常形态
（报告(29) L363：主屏样式实例里左 StringView 本就是 hidden=1）。

- **还原范围收窄**：`sp_restore_right_cluster` 的 STUIStatusBar* 分支加
  `frame.origin.x >= 195` 门槛——只还原右簇（信号 x=282 / 网络类型 x=308 /
  电池 x=333）；左列保持各语境自己的样式（Solo 替换态/原生态互不打架）。
  cell 容器与 Luma 背板分支本来就是 x≥195，不变。
- 其余（让位闸、三点位、护栏、取证）随 1.3.19 继续生效。

**验证要点**：锁屏右列仍正常；锁屏左列不再叠放（只显示 Solo 修改内容）；
回主屏 Lunora 右胶囊照常。

## 1.3.19 — 2026-11-25（锁屏右簇还原：修"从主屏锁屏右列消失"）

报告(29) 定案机制：**锁屏栏显示的是"锁屏前语境"样式的实例**。同一前景视图
实例在 CoverSheet（被护栏保住、全原生可见）与 SBMainSwitcherWindow 之间迁移；
后者被抓拍到完整主屏样式包：右列信号/网络类型/电池 `hidden=1 lh=1`、右 cell
容器与右 Luma 背板 `alpha=0`、Lunora 右胶囊可见（带自己的电池 widget）。从主屏
锁屏 → 实例带主屏样式（右簇被压制）→ 锁屏场景 Lunora 不画胶囊 → 右侧干净彻底
消失；从 App 锁屏 → 实例是 App 样式（原生完整）→ 正常。左列不受影响（用户配置
左列=原生）。另有自伤实证：锁定边缘我们的让位把 x=333（锁屏布局）电池 alpha0
（报告(29) L324）。

- **右簇还原**（`sp_restore_right_cluster`）：锁屏语境下把右列恢复成原生可见
  ——`STUIStatusBar*` 直接子级 hidden/lh/alpha 复位；右半区（x≥195）cell 容器
  与 Luma 背板 alpha<0.01 复位 1.0；不碰 `LNV2*`；`UIVectorLabel`（合法备选
  渲染，嵌在 item 内部）不动。
- **还原语境判定**（`sp_should_restore_lock_bar`）：CoverSheet 恒还原；
  MainSwitcher/StatusBarWindow 仅 UI 锁定时还原（解锁状态下它们承载主屏/
  切换器样式，还原会砸掉 Lunora 胶囊态）。
- **三个点位接线**：attach、layoutSubviews（单向重申，对打 Lunora 引擎的
  重申压制）、护栏拦回之后。
- **让位闸**：`sp_apply_theme_yield` 在 UI 锁定时改为顺手 restore 并返回——
  锁定期间不让位（自伤路径封死）；解锁后由 show/layout 重新套用，自愈。
- 独立于保留系统栏开关；1.3.18 的护栏/dump/祖先链全部继续生效。

**验证要点**：主屏下拉锁屏、主屏真锁屏后亮屏，右列（信号/网络/电池）均应
稳定显示；从 App 锁屏回归不变；回主屏后 Lunora 右胶囊照常；解锁瞬间无闪烁。

## 1.3.18 — 2026-11-25（护栏覆盖切换器语境 + 终态双点采样 + 祖先链）

报告(27) 判读（1.0.1-33/1.3.17 实机）：护栏实锤 **Lunora 反复压暗锁屏栏**
（`lock guard: kept hide ... caller=other` ×8，全被顶回）；两次 `sbdump-later`
（+0.6s）里右列信号/网络类型/电池全部 alpha=1/hidden=0/lh=0/mask=0，且
LNV2OverlayView 全幅骑进锁屏栏（z=1，胶囊 hidden）——视图级状态与肉眼观察
矛盾。两个盲区：采样只到 +0.6s；可见栏可能是 `SBMainSwitcherWindow` 实例
（1.3.17 只护 CoverSheet，其 alpha→0 在非主屏语境照样放行）。

- **护栏扩窗口**：新增 `sp_window_is_lock_context()`（SBCoverSheetWindow ∪
  SBMainSwitcherWindow），两个锁屏语境的任何来源 alpha→0 一律保活+归因
  （日志带 win=）。
- **终态双点采样**：`sbdump-later` 由单点 0.6s 改为 0.6s/2.5s 双点（预算 4），
  捕更晚到的压制；CFRunLoopTimer C 回调零 block。
- **祖先链**：每轮终态 dump 先从栏向上逐级打印到窗口（alpha/hidden/lh/mask），
  堵"上级视图被藏"盲区。
- 1.3.17 的 any-source 拦截、lh/mask 字段、attach dump 继续生效。

**下一轮判定**：MainSwitcher 栏的 guard 触发 + 右列恢复 → 收案；+2.5s 采样
出现异常（mask=1 / lh=1 / alpha<1）→ 定位到具体机制；祖先链出现非 1 值 →
上级视图级压制；全部正常而肉眼仍消失 → 转视觉层（LNV2OverlayView 玻璃盖
覆盖）与 Lunora 配置方向。

## 1.3.17 — 2026-11-25（锁屏护栏扩权 + 终态取证）

报告(26) 判读（1.0.1-32/1.3.16 实机）：护栏版在跑（`sbhook ownership: top=ours`），
锁屏栏容器 `alpha=1 hidden=0` 完整可见，但**右列 item 缺席**（attach 时刻只剩零尺寸
空壳），且全程**零 caller=solo alpha 调用**——1.3.16 的 caller=solo 拦截无从发力，
真凶未定（caller=other 的 alpha 调用，或 Lunora 的 layer mask 所有权——dump 的
view 级字段看不见 mask）。

- **护栏扩权**：CoverSheet 语境对**任何来源**的 alpha→0 一律保活（`alpha` 强制
  1.0）并记归因（`caller=solo/other` + `uiLocked`）。Lunora 转场级 alpha 交接
  嫌疑最大（它在锁屏栏不画 overlay 却疑似照压原生右列）。
- **dump 加 layer 字段**：每行追加 `lh=<layer.hidden> mask=<layer.mask 非空>`；
  view 级 alpha/hidden 全正常但 mask=1 = Lunora mask 所有权压制的直接证据。
- **终态二次取证**：CoverSheet 前景视图 attach 后 0.6s 对同一视图再 dump 一次
  （`sbdump-later`，预算 2）——attach 时刻 item 尚未组装（报告(26) L1109 实证
  零尺寸空壳），"闪现后被藏"只存在于终态。CFRunLoopTimer C 回调，零 block 字面量。
- 1.3.16 的锁屏护栏、`sp_device_ui_locked()`、锁屏 attach dump 继续生效。

**判定树（下一轮日志）**：`lock guard: kept hide ... caller=other` 有触发且右列
恢复 → alpha 级压制实锤已修；归因=other 拦了仍被藏 → 看 `sbdump-later` 的
mask=1（mask 级，Lunora 内部，需另行评估）；item 始终零尺寸 → 工厂级
（Lunora `viewForIdentifier:` 压制，Solo 已排除——其 hook 表无 item 工厂钩子）。

## 1.3.16 — 2026-11-25（锁屏护栏：锁屏系统栏不再被 Solo 渐隐，独立于保留系统栏开关）

调试报告(23) 用户报障：**锁屏上的右侧系统栏被强制隐藏**，且关闭「保留系统栏」
也不恢复。逆向定位（Solo 1.0.1 反编译 FUN_00052bf4 + 报告(23) 行 159/167）：

- Solo 的 stockstatusbar 评估器在 `isUILocked==0 && !CC && 无前台 App` 时对
  **全部已跟踪状态栏**（含 `SBCoverSheetWindow` 里锁屏那条，weak 表不分类）
  做 `setAlpha:0` 渐隐；锁屏左边为空，视觉上就是"右列消失"。
- `isUILocked` 与 CoverSheet 呈现有错位窗口期（报告(23)：息屏瞬间
  `UI locked=0`，亮屏瞬间 `device lock state=0, UI locked=1`——两层锁语义错位）。
- 旧代码两种模式都不设防：`keepStatusBar=0` 时 hide 路径整体放行；
  `keepStatusBar=1` 时非主屏语境（含锁屏）也放行。

改动：

- **锁屏护栏**（`sp_common_set_alpha`）：窗口类为 `SBCoverSheetWindow` 时，
  `caller=solo` 的隐藏一律拦回（`alpha` 强制 1.0），**独立于 keepStatusBar 开关**；
  非 Solo 来源（系统/Lunora 转场）仍放行，不与其转场对抗。
- **锁屏取证**：CoverSheet 前景视图 attach 时 dump 子树（预算 2 次，两种开关
  模式下都生效）。若护栏日志零触发而锁屏仍被藏，即为 Lunora 工厂层压制
  （item 视图根本不创建，alpha 钩子不可见）的实锤——下一轮转向 Lunora 侧。
- 新增 `sp_device_ui_locked()`（与 Solo 评估器同源读 `SBLockScreenManager
  isUILocked`，仅供日志对照锁态口径）与 `gLockGuardLogBudget`（8 条）。

**待实机验证**：锁屏亮屏后右列（电池/WiFi/信号）始终可见；锁→解锁→再锁
循环无残留；保留系统栏开/关两种模式下行为一致。

## 1.3.15 — 2026-11-25（Dock 功能瘦身：只保留图标上限，扩展到 5–8）

用户定案：发现第三方插件（Atria 等）可完成 Solo Dock 图标的大小/间距/上下位置
调节，Solo+ 侧重复实现会互相覆盖。**Dock 模块瘦身为只保留「图标上限」**，
上限从 5/6 扩展到 **5–8**。

- **删除**：`soloPlusDockIconScale` 全链（`iconContentScale` 应用、父层 transform、
  `UnduoDockScale` 动画补偿、1.3.13 的 CFRunLoopTimer 合并重应用）与
  `soloPlusDockAutoShift`（`setCenter:` 下移）；面板「图标大小」「自动下移」两项；
  `sp_model_location` 死代码与全部缩放日志预算。
- **保留**：`sp_dock_layoutIconsNow` / `sp_dock_layoutSubviews` 钩子本身——它们
  现在只剩一个职责：刷新 `gDockListView` / `gDockModel`（模型层严格指针身份的
  唯一数据源，删掉会让文件夹 model 误判回归，即调试报告(20) 的 count=5 错位）；
  上限容量链（视图 `maximumIconCount`/`iconRows`，模型 `maxNumberOfIcons`/
  `numberOfFreeSlots`/`gridSize`/`isFull`/insert 边界）、6→5 自动迁回、
  `addPlaceholder` 终点防护与 NSNotFound 前置拒绝。
- **上限 5–8**：`sp_load_prefs` 夹取上限 8；面板新增 7/8 档位；7/8 为超出实测
  范围的实验档（6 为双机实测档）。
- 面板 footer 与 control/README/发布描述注明：Dock 图标大小、间距、上下位置
  请用第三方插件（如 Atria）调节。
- 1.3.14 的严格指针身份与 NSNotFound 前置拒绝随本版继续生效。

**待实机验证**：8 图标档可用性；缩放/下移移除后 Dock 视觉由 Atria 接管无回归；
文件夹首页满拖入不再错位（1.3.14 修复的延续验证）。

## 1.3.14 — 2026-11-25（文件夹错位根因：Dock model 严格指针身份；1.0.1-29 实机回执驱动）

调试报告(20)（1.0.1-29 上机）实锤两件事：

- **安全模式已修成**：`[Solo+] placeholder: caught invalid grid cell index 9223372036854775807` × 6，
  正是 `.ips` 里 `addPlaceholderAtGridCellIndex:` 的 NSAssert 异常被 1.3.13 的
  终点 `@try/@catch` 拦下，拖移不再 abort。用户回执「托移不会进入安全模式」与此一致。
- **错位根因定位**：日志出现 `dock model gridSize: count=5 cols=1 rows=6 -> {1,6}` ——
  该行只在 `sp_model_is_dock()` 为真时打印，但 Dock 实为 6 图标；`count=5` 来自
  **被误判的文件夹内部 model**。旧 `sp_model_is_dock()` 在 `gDockListView` weak 变 nil
  时回落 `_atriaLocation` 含 "Dock" 就认，于是文件夹 model 的 `gridSize` 被套成
  竖排 `{1,6}`、`freeSlots/isFull/maxIcons` 一起放大 → 已满首页认为还有一行槽 →
  拖入应用排到「下一行」而非新建一页 → 坐标 NSNotFound → 异常（旧包 abort 进安全模式）
  / 图标错位持久化（注销不回滚，因状态已落盘）。

本版修改（一个变量：只认真正的 Dock model）：

- `sp_model_is_dock()` 改为**严格指针身份**，只匹配 `gDockModel`；未就绪时
  model 层一律不改，视图层 `sp_dock_max`/`sp_dock_rows` 已兜底，绝不误伤文件夹；
  `sp_dock_model()` 不再扫窗口（避免拿到残旧列表的过期 model），由
  `sp_note_dock_list()` 在每次 Dock 布局钩子里刷新 `gDockModel`；
- 终点 hook 增加 **NSNotFound 前置拒绝**：系统算出 `0x7FFFFFFFFFFFFFFF` 落点时
  直接返回 nil，不进 SpringBoardHome、不抛异常、不留半状态（比 `@try/@catch`
  更干净）；原有全列表 `@try/@catch` 兜底保留。

**预期**：新拖入不再产生错位；已经错位的历史图标状态由用户手动拖入下一页恢复
（用户已实机验证该操作有效），插件不主动改写用户图标布局数据。
**待实机验证**：文件夹首页满时重复拖入不再错位、Dock 6 图标能力不回退。

## 1.3.13 — 2026-11-24（Dock 模型-视图一致性 + 缩放合并；未实机验证）

状态栏方向：结合 owngoal-dev/SingleVPN 开源源码（纯 item 级 hook，无 CC 转场/
overlay 杠杆）、Lunora V2 逆向报告与 1.3.9–1.3.12 四轮补丁材料复核，确认
CC 收起闪切残留源头在 Lunora 自身转场内部，SoloPlus 边界已到，**无突破性
优化可做，本版不动状态栏代码**。

转向 Dock 两处遗留问题，依据新附的 SpringBoard-2026-11-24-175924.ips：

- 崩溃链：`SBIconDragManager iconView:willAnimateDragLift…` →
  `SBIconListView addPlaceholderRepresentingIcon:` →
  `addPlaceholderAtGridCellIndex:` 内 NSAssert 抛异常 → `SIGABRT`；
  `consecutiveCrashCount=3` → 安全模式。异常栈全在系统框架内、无 tweak 帧，
  是模型容量/网格索引与视图槽位不一致引发的间接断言。

**A 组：桌面图标错误 / 安全模式（一个变量：收敛模型与视图的索引账本）**

- `gDockModel` 直接记住 Dock model 指针：`gDockListView` 是 weak，CC 转场/
  编辑态重建列表时短暂变 nil 会回落 `_atriaLocation` 误判身份；
- `gridSize`：Atria 哨兵值（>1000）不再覆盖；视图报告 cols/rows 时长轴必须
  容纳有效槽数（6 图标时旧实现照抄视图 1×5）；列表不可得时兜底严格竖排
  `1×want`，不再把 `1×6` 写成横排 `6×1`；
- `numberOfFreeSlots` 由 `NSUIntegerMax` 改为真实剩余槽数（定长网格不能报无限）；
- `canAddIcon:atIndex:` / `insertIcon:atIndex:` / `insertIcons:atIndex:options:`
  统一以 `idx < 有效槽数` 为硬边界，insert 再加 `@try/@catch` 兜底闸门，
  模型内部断言绝不冒泡到 CFRunLoop；
- 崩溃栈终点防护：钩 `SBIconListView addPlaceholderAtGridCellIndex:
  representingIcon:reason:options:`（arity=6 + 返回对象守卫，签名漂移不装），
  仅对 Dock 列表拦越界 index 并 `@try/@catch`，其它列表原样转发。

**B 组：Dock 六图标动画卡顿（独立变量：缩放重应用时机）**

- 旧实现在 `layoutSubviews` / `layoutIconsNow` 回调栈内同步递归整棵 Dock 视图树
  写 `iconContentScale`，写入又触发新布局，形成「布局→遍历+写→再布局」反馈循环；
- 改为 CFRunLoopTimer 合并同一轮次多次请求、延后到 runloop 空闲一次性应用；
  布局回调在 `spApplyingDockListScale` 期间跳过 arm 断开环路；
  启动/列表未挂载时有界重试（6×0.25s）；缩放值与几何行为不变；
- 全程 C 回调，无 block 字面量（1.2.0 安全模式硬教训）。

**状态：仅本地编译自检，未实机验证。不发包、不推 GitHub、不推源站。**

## 1.3.12 — 2026-11-24（桌面语境自证武装：attach 就地开宽限，不再追事件时序）

1.3.11 实机日志（attach 带 grace 状态）实锤：SBStatusBarWindow 的 attach 全部
`grace=0`——**收起转场中途的实例挂载早于一切事件信号**，靠事件武装宽限（四回调、
兜底信号）在时序上永远赶不上。转而采用 Lunora 同款的前台信号方案：

- **新增 `SpringBoard frontDisplayDidChange:` 钩**（Lunora 用它做场景判定）：只判
  参数 nil 与非 nil 得到确定的「App 前台 vs 桌面/CC」状态，不解参数类型避开 ABI
  漂移；该钩至少触发过一次才启用自证（未触发时回退 1.3.11 行为，不误伤）。
- **桌面语境自证武装**：attach / 隐藏 / 显示 / 布局四个入口，只要「无前台 App +
  主题在场 + overlay 声明了胶囊」就**当场开 2.5s 宽限并让位**——收起转场中途
  重建的实例在首次渲染前即被记忆/声明 rect 让位，时序差不再存在。
- **主题在场证据保鲜**：`gThemeSeenAt` 原先只在胶囊真实生效时更新，CC 开久了会
  过期导致收起瞬间自证失败；现在声明态检查也刷新。
- 进 App（frontDisplay 变化）立即清宽限并恢复让位，App 状态栏完整由前台信号硬
  保护；CC 窗口条的隐藏也刷新兜底信号时间锚。

## 1.3.11 — 2026-11-24（转场起点武装宽限：修收起转场中途重建实例的时序差）

1.3.10 实机日志（`cc diag: attach`）定位到真正根因：`_willBeginTransition` 在**收起
转场开始时**同样触发，此前把它当「CC 打开」清掉了宽限 → 收起转场**中途**系统重建
桌面状态栏实例时宽限为空 → 实例按 1.3.6 规则渲染原生右列 → 等转场结束
`_didEndTransition`/`_didDismiss` 才武装宽限，晚了一个转场。日志证据：attach 诊断
全部落在 CC 打开期间（兜底信号误武装、无害），收起瞬间的新实例 attach 反而没有
诊断行（宽限未武装）。

修复：

- `_willBeginTransition` 改为**武装**宽限（转场起点即覆盖）。打开方向随后由
  `_willPresent` 清掉；收起方向从转场开始到结束再到 2.5s 宽限全程有让位保护，
  转场中途重建的实例在首次渲染前就被记忆/声明 rect 让位；
- `_didEndTransition` / `_didDismiss` 保持武装（收尾续期）；
- attach 诊断放宽为「宽限内或主题 10s 内在场」即打印，并附带 grace 状态——
  收起期 attach 是否抢在宽限武装之前，日志里直接可见。

## 1.3.10 — 2026-11-24（宽限期加固：记忆 rect 让位 + CC 收起兜底信号）

1.3.9 实机（iPhone 15 Pro / 17.2.1 + Lunora）反馈闪切依旧。复盘出宽限期三个未覆盖
的洞，全部补上：

- **记忆 rect 让位**：每次成功让位记住胶囊 rect（前景视图坐标系，跨实例几何一致）。
  CC 收起窗口期若 overlay 尚未挂回条里（新实例挂载早于 Lunora 重新挂 overlay，
  `sp_theme_overlay_for` 拿到 nil，1.3.9 的宽限分支根本没机会跑）或声明态也拿不到
  （胶囊子视图被转场期隐藏），用记忆 rect 继续让位。仅在宽限内且主题最近在场
  （10s 内见过胶囊）时生效，Lunora 被禁用不会误让。
- **CC 收起兜底信号**：`SBControlCenterController` 四回调万一未装上/签名漂移时，
  用「CC 窗口条（SBControlCenterWindow）最近走过显示路径 + 主屏出现隐藏调用 +
  主题最近在场」推断 CC 刚收起，照样开宽限（无 CC 场景不会误触发）。
- **宽限 1.2s → 2.5s**：覆盖 Lunora 姿态等待（40ms 轮询 deadline）+ 8×125ms 恢复
  的最坏叠加；布局重申路径在宽限过期且 overlay 仍缺失时回收记忆让位恢复原生。
- **诊断独立预算**：CC 窗口期专用日志预算（32 条），不再与 blocked/ignored 共享
  耗尽；attach 时输出 overlay/声明态快照，便于下一轮实机定位。

## 1.3.9 — 2026-11-24（CC 收起宽限期：消 CC→主屏原生条闪现）

1.3.7 时机同步实测后仅剩一处残留：CC 关闭回主屏的瞬间，Lunora 会先瞬时藏掉自己的
overlay（胶囊不可见）但压制不停，1.3.6 的「胶囊无效→恢复整条」规则在此窗口把原生
右列放出来，等 overlay 亮出再让位 → 呈现一次「原生右列 ↔ 胶囊」闪现。

逆向 Lunora V2 2.0.0~beta38 定案其转场时序后（`analysis/lunora-2b38/REPORT.md`），
本版加入**CC 收起宽限期**：

- **事件源**：与 Lunora 同款钩 `SBControlCenterController` 的
  `_didDismiss` / `_didEndTransition` / `_willPresent` / `_willBeginTransition`
  四回调（ABI 守卫：2 参、返回 void；签名漂移时退回 1.3.6 行为）。收起即开启
  1.2s 宽限（≈ Lunora 自身 8×125ms 有界恢复上限 + 余量），重新打开 CC 即退出。
- **宽限期内**：让位判据从「胶囊有效可见」放宽为「胶囊已声明」（overlay 被藏但
  胶囊 frame 仍在——Lunora 转场不清 frame）。保持让位、不恢复整条，CC 回主屏
  瞬间右侧短暂留白，胶囊亮出后无缝衔接；超时回退 1.3.6 的恢复整条规则。
- 挂载同步（didMoveToWindow）、布局重申（layoutSubviews）、setAlpha: 显示/隐藏
  路径全部统一走宽限感知的让位函数；无主题时行为不变（宽限只在覆盖层存在时生效）。

## 1.3.8 — 2026-11-24（iOS 16.5 加固：主题覆盖层误判防护）

1.3.7 双机验收通过后，针对 16.5 旧状态栏（`_UIStatusBar`）补一条防护：主题覆盖层识别
增加两个收窄条件——

- 跳过 `MT` 前缀（`MTMaterialView` 等系统材质视图）；
- 覆盖层必须横贯状态栏（宽度 ≥ 前景视图 60%；Lunora 的 overlay 为整条 393×54，不受影响）。

防止旧状态栏同层的系统辅助视图被误判成美化覆盖层、错误触发让位。严格收窄判定，
17.2.1 + Lunora 的已验收行为不变；1.3.7 其余说明见下。

## 1.3.7 — 2026-11-24（挂载/布局时机同步让位：消 CC→主屏识别闪切）

1.3.6 实测（iPhone 15 Pro / iOS 17.2.1 + Lunora）：主屏/App/锁屏/换边配置全部正确
（换边后让位自动跟随胶囊 frame，日志实证左胶囊启用时让位左侧子视图），仅剩
**CC 关闭回主屏时的"识别切换"闪动**：系统为主屏新建前景视图实例（默认整条可见、
无 setAlpha 调用可介入），Lunora 压制稍后才到，中间窗口期呈现"原生右列 ↔ 胶囊"切换。

修复：给两个前景视图类加 `didMoveToWindow` / `layoutSubviews` 钩子（与 Solo 的注册钩子
链式共存）：

- **挂载时全量同步**：主屏 + 主题在场 + 胶囊有效 → 立即让位；非主屏 → 恢复。新实例在
  首次渲染前即为目标状态，闪切消失；跨窗口复用的实例随挂载自动同步；
- **布局时单向重申**：只让位不恢复，避免 Lunora 瞬藏 overlay 的窗口期引起内容抖动。

## 1.3.6 — 2026-11-24（主题在场判据去掉可见性：修 CC 开合后左侧原生条被放行隐藏）

1.3.5 实测（iPhone 15 Pro / iOS 17.2.1 + Lunora）：解锁进主屏的共存路径正常（blocked +
让位 ×3，左侧时间显示），但**控制中心开合后** Lunora 会瞬时把自己的 overlay
`hidden=1`——而它对原生条的压制不停。1.3.5 用"覆盖层可见"判定主题在场，这一瞬间判定
失败 → 压制被放行 → 整条原生 alpha→0 → 左侧原生条闪现后被隐藏；之后每次主屏隐藏都因此
放行。换边测试"另一侧正常"只是没碰到该时序，与左右无关。

修复：

- **主题在场判据 = 覆盖层存在**（同层非 `STUI/_UI/UI` 前缀、frame 真实，不看 hidden/
  alpha）——Lunora 藏 overlay 不再导致放行；
- **让位判据 = 胶囊"有效可见"**（overlay 自身可见 + 至少一个可见胶囊）：有效 → 让位；
  无效（overlay 被藏）→ 恢复让位，整条原生条都听 Solo；
- `blocked` 日志带 `caps=0/1` 便于对号；其余路径（App 内完整、无主题整条保活、16.5）
  不变。

## 1.3.5 — 2026-11-24（状态栏与美化插件共存：未美化区域听 Solo、美化区域让步）

1.3.4 的 dump（iPhone 15 Pro / iOS 17.2.1 + **Lunora**）把结构定死了：

```text
STUIStatusBar (393×54)
 ├─ z0 LNV2OverlayView          ← Lunora 覆盖层；胶囊 frame 就是"美化区域声明"
 │    ├─ LNV2CapsuleView {{0,0},{0,0}} hidden=1      ← 左侧胶囊未启用
 │    └─ LNV2CapsuleView {{263,12},{107×30}} visible ← 右侧胶囊启用
 └─ z1 STUIStatusBarForegroundView（原生）            ← 在 Lunora 之上
      ├─ 左列内容 x=6..195（时间/运营商）
      └─ 右列内容 x=199..388 + 右 Luma 背景（电量/信号）
```

Lunora 靠把原生前景视图整条 alpha→0 露出胶囊，没启用胶囊的左侧也被带走；
ownership 探测 `top=ours`（启动+5s）证实它没 hook 同一方法，`caller=other` 全部是它的
压制（Lunora 抢先把新实例压暗，Solo 的动画循环因此跳过，无 caller=solo 调用）。

**共存规则（1.3.5）**：

- **检测**：前景视图同层出现"非 `STUI/_UI/UI` 前缀、带可见子视图"的覆盖层 → 主题接管中
  （日志 `theme=LNV2OverlayView`）；
- **让位**：覆盖层可见时，主屏上下文里对前景视图的任何 alpha→0（Solo 或 Lunora 发起）
  都拦回 alpha=1——未美化区域（左侧时间/运营商）听 Solo 恢复显示；随后把 frame 与可见
  胶囊重叠的原生内容子视图 alpha 压 0——美化区域让位（右列内容、右 Luma 背景、电池视图）；
- **恢复**：覆盖层不可见（进出 App/控制中心 Lunora 会藏自己的 overlay）或非主屏上下文时，
  让位的子视图恢复 alpha=1，App 内状态栏完整；
- **无主题时行为不变**：iOS 16.5 / 无美化 17.2.1 仍是整条保活；胶囊全关时也不让位。

区域规则由胶囊 frame 驱动，左右胶囊开关任意组合都自适应。

## 1.3.4 — 2026-11-24（诊断版：hook 归属探测 + 状态栏层级 dump）

iPhone 15 Pro / iOS 17.2.1 + 美化插件实测 1.3.3：本会话 **0 条 caller=solo**——Solo 自己的
`hidden=1` 隐藏动画全部被记成 caller=other，而同一会话里数据标识的同一套 caller 判定工作
正常。最可能解释：**美化插件同样 hook 了这两个类的 `setAlpha:` 且排在我们上面**，所有调用
经它的蹦床转发，caller 归因失效；它的压制（alpha→0）因此全部被 1.3.3 放行 → 原生条完全
听美化插件的（右侧美化条正常、左侧原生条被压制）。

同时确认 `STUIStatusBar` 是 **iOS 17 原生 StatusBarUI 框架**（tracked 视图遍布
SBStatusBarWindow/SBMainSwitcherWindow/SBControlCenterWindow/SBCoverSheetWindow 全部原生
窗口；iOS 16.5 是旧 `_UIStatusBar`），美化插件没有替换该类。

本版不改任何行为（与 1.3.3 一致），只加三件诊断：

- **hook 归属探测**：安装时 + 5 秒后各查一次两个类 `setAlpha:` 顶层 IMP 是否仍是我们的
  （`sbhook ownership: ... top=ours/other`）；
- **层级一次性 dump**：首次遇到主屏上下文的 caller=other 压制时，dump 该视图的 superview
  子树 + 所在窗口子视图列表（类名/指针/frame/alpha/hidden/z 序，限 60 行、预算 2 次，
  `sbdump` 前缀），用于确定左右簇结构与美化条视图位置；
- `blocked/ignored` 日志补视图指针。

后续 1.3.5 依据 dump 落“未美化区域听 Solo、美化区域让步”的区域级逻辑。

## 1.3.3 — 2026-11-24（状态栏保留改为只拦 Solo 调用方，兼容美化插件状态栏）

iPhone 15 Pro / iOS 17.2.1 + 美化插件实机发现：1.3.2 的“保留”会把**原生**状态栏也复活到
美化插件状态栏之上。日志里 Solo 跟踪的状态栏前景视图全部挂在 `STUIStatusBar` 下（美化插件
自己的容器，iOS 16.5 无美化时是 `_UIStatusBar`），tracked 数在 20–26 间增减；Solo 的
stockstatusbar 把美化条和原生条一起 alpha→0，1.3.2 按窗口白名单一律拦回 1，结果原生条被
拉到可见位置。

修复：

- `setAlpha:` 钩子改为**只拦调用方是 Solo.dylib 的 alpha→0**（`__builtin_return_address`
  + `dladdr`，与数据标识替换同一套 `sp_caller_is_solo`，实机已验证）；美化插件/系统自己
  隐藏状态栏的动作一律放行；
- 新增弱表 `gKeptViews`：只记录被我们拦过的视图；`sp_force_show_all` 不再无差别扫窗口，
  只恢复这些视图——美化插件藏掉的原生条永远不会被我们拉出来；
- 窗口白名单只保留给启动/刷新时的扫描兜底，不再是拦截条件（Solo 只在主屏上下文发起隐藏，
  调用方判定天然等价于上下文判定，且不受 iOS 版本窗口层级变化影响）；
- 诊断日志升级：`blocked/ignored` 带 `view= superview= win= caller=solo|other`，新增
  `force show kept view` 行；下一份日志可直接看清是谁在藏谁。

## 1.3.2 — 2026-11-24（iOS 16.5 状态栏：补 UIStatusBarWindow）

1.3.1 实机日志（iOS 16.5）确认了真正的放行窗口：

- `[Solo+] ignored statusbar hide in UIStatusBarWindow (superview=_UIStatusBar)` 出现在
  解锁进主屏和从 App 回主屏两个时点，紧接着就是 Solo 的 `hidden=1`；同一轮里
  `SBHomeScreenWindow` 的隐藏是被拦住的，说明用户看到的可见状态栏在 `UIStatusBarWindow`。
- 1.3.1 已加入的 `SBMainSwitcherWindow` 在这份日志里没有触发，但作为锁屏/切换器窗口保留。

修复：

- `sp_window_is_home_context()` 再加入 `UIStatusBarWindow`；
- **不加入** `SBStatusBarReusePoolWindow`：它是 App 状态栏复用池，保活可能影响 App 内
  本该隐藏状态栏的场景；日志里出现的该窗口 ignored 属于预期放行；
- 待实机确认：主屏 `UIStatusBarWindow` 的隐藏应出现 `[Solo+] blocked statusbar hide in
  UIStatusBarWindow`，且不再有 `ignored statusbar hide in UIStatusBarWindow`。

## 1.3.1 — 2026-11-24（iOS 16.5 状态栏窗口兼容）

针对 iOS 16.5 用户反馈：开启“保留系统状态栏”后，主屏状态栏闪一下仍被 Solo 渐隐；App 内和控制中心正常。

- **根因**：iOS 16.5 主屏状态栏前景视图挂在 `SBMainSwitcherWindow`，而 1.3.0 及更早版本的
  `sp_window_is_home_context()` 只认 `SBStatusBarWindow` / `SBHomeScreenWindow`，`setAlpha:` 钩子
  因此放行 Solo 的 `alpha=0` 动画；`sp_force_show_all()` 也不会扫描这个窗口。
- **修复**：主页窗口判定加入 `SBMainSwitcherWindow`；`setAlpha:` 拦截与启动/刷新时的强制显示
  共用同一判定，自动覆盖。
- **诊断**：窗口类未命中时新增限流日志 `ignored statusbar hide in <window> (superview=<view>)`，
  避免以后再出现“静默放行”。
- **待实机**：iOS 16.5 主屏 / App 内 / 控制中心 / 锁屏；确认主屏不再渐隐且不影响其它场景。

## 1.3.0 — 2026-11-23（摘除桌面歌词模块；Duo 时间 / 标识 / 电量整理并上架）

按要求放弃桌面歌词：这一版把「增强 → 桌面歌词」整块下线，包体回到只做 Duo / 状态栏 /
Dockicon / 轮播铺满的形态，并把这轮在实机截图里确认的 Duo 效果写进发布说明。

移除范围（全部不再编译进 dylib）：

- 悬浮歌词窗（UIWindow、样式、位置 / 字体 / 颜色 / 描边 / 半透明背景、测试显示）；
- LRCLIB 拉词（`/api/get`、`/api/search`、LRC 解析、后台队列）；
- SpringBoard 侧媒体探测（probe3 / probe4、类名枚举、选择器扫描）与 `SBMediaController` 的
  `setNowPlayingInfo:` / `_mediaRemoteNowPlayingInfoDidChange:` hook；
- 上一版新加的「只读 Solo 媒体缓存」通道（含 IMP 指纹校验与 block 复用）。

面板同步收缩为 4 项：状态栏 / Duo / 轮播铺满 / Dockicon（+ 调试日志）；
`SoloPlusLyrics.plist` 删除，`prefs reload` 日志不再带歌词字段。

Duo 三件事按本轮实机截图对齐：

- **时间**：关掉后 `setText:` / `setAttributedText:` 直接换空串，`setHidden:` / `setAlpha:` /
  `setTextColor:` 三处压制，Solo 重建玻璃 / 快照层也不会再糊出时间；只恢复自己打过标记的视图。
- **标识**：5G 显示为「5G + 小号大写 A」（62% 字号、底部同基线），其余制式原样；
  标识字号 0.8–1.4、字重 跟随 / 细 / 常规 / 中粗 / 粗 五档。
- **电量**：64×22 标签挂在 Duo 容器同层、按容器 frame 水平居中（修掉贴近右缘被夹回左边约 14pt），
  上下微调 −8 / −4 / 0 / +4 / +8，≤20% 红 / 充电绿，UIDevice + IOKit.ps 双源、10 秒刷新。

发布版合并包 `1.0.1-16` 已上架 `https://chenlin8023.github.io/`，详情页首图为本轮实机截图。

产物：

```
com.chenlin8023.solo.full_1.0.1-16_iphoneos-arm64.deb
SHA-256: 9038f24d4571ef0f43337e92b20d133d4bd46d9a56c7046b4778c966342bd420
大小：451316 字节
```

## 1.2.9 — 2026-11-23（歌词：改读 Solo 自己的 now-playing 缓存）

报告 32 里曲目依旧 `title=(nil)`：`SBMediaController` 在 17.2 只存控制位
（`isFirstTrack,isLastTrack`）、`MPNowPlayingInfoCenter` 在 SpringBoard 里恒为 nil、
`CPUINowPlayingManager` 只有空的 `lastContentItemTitle`。

本轮把 Solo 1.0.1 的媒体链路反编译了一遍，结论很直接：

- Solo 走的是 `MRMediaRemoteGetNowPlayingInfo(queue, block)`；它的 block 回调在
  `Solo.dylib 0x282ec`，按 8 个 `kMRMediaRemoteNowPlayingInfo*` 键取值，然后把
  **标题 / 歌手 / 专辑 / 时长** 写进 `__DATA` 全局 `0x89028 / 0x89030 / 0x89038 / 0x89868`；
- 播放进度另存 `0x880fb8`(elapsed)、`0x880fc0`(timestamp)、`0x890838`(playing)，
  Solo 自己的 `0x27c24` 就是按 `elapsed + (now − timestamp)` 算位置；
- 两个通知入口 `unduoNowPlayingInfoChanged:` / `…ApplicationIsPlayingChanged:` 只是
  尾巴跳到共用的取数体 `0xbf5c`。

所以本版**不再自己造 block**（本工具链生成的 block isa 缺 `pacda` 认证，1.0.1-6 就是栽在
这里），改成只读上面那几处缓存：

- `src=solo` = 曲目来自 Solo 缓存；`src=sb` = 仍走 `SBMediaController` 兜底。
- 每 5 个 tick（1 秒）读一次；还没有曲目时每 10 秒催一次：把 Solo 自己的全局 block
  （`0x78fb0`，isa 由 Solo 用 `pacda` 签好，`Block_copy` 对 global block 原样返回）交给
  `MRMediaRemoteGetNowPlayingInfo`，回调仍是 Solo 的、写的就是我们要读的全局；
  这条路不通时退回调 Solo 的取数体 `0xbf5c`，再不行就发
  `kMRMediaRemoteNowPlayingInfoDidChangeNotification`。
- **偏移指纹**：启动时校验
  `-[UnduoMediaRemoteObserver unduoNowPlayingInfoChanged:]` 的 IMP 是否等于
  `base + 0xbf58`；不等就放弃这条数据源并写日志（Solo 换版本不会误读内存）。
- 位置用 `elapsed + (now − timestamp) × playing` 推算，暂停时冻结。
- `SBMediaController` 兜底扫描降频到 5 秒一次（Solo 缓存就绪且已有曲目时基本不扫），
  省掉每秒一次的 `class_copyMethodList`。

歌词拉取也顺手改了两处：

- 先 `/api/get`，取不到再 `/api/search?q=歌手 标题`（两段同步请求，仍然零 block）。
- 失败记录 20 秒后重试，同一首最多 3 次；旧版失败一次就把这首永久跳过。

日志新增：`lyrics solo: … dur/el/ts/play`、`lyrics solo: cache ready / offsets mismatch`、
`lyrics fetch: get=… search=…`、`lyrics miss: … (attempt N)`，
`lyrics tick:` 行补 `src/artist/pos/play`。

## 1.2.8 — 2026-11-23（歌词：标题兜底 + 搜索接口 + 同步 API 探测）

报告 31 的 probe4：

- `MPNowPlayingInfoCenter` / `MPMusicPlayerController` 在 SpringBoard 里都是 nil；
- `SOMediaNowPlayingObserver` 无共享实例，且取歌词的接口是 block 版
  （`getNowPlayingInfoForCurrentItemWithCompletion:`），本工具链不能用；
- `CPUINowPlayingManager` 有实例，但只暴露 `lastContentItemTitle`（探测时为空）；
- `MRUNowPlayingController` / `MRNowPlayingClient` / `CSNowPlayingController` 均无实例。

本版：

- **轮询 `lastContentItemTitle`**：每 5 个 tick 读一次，有值就当作标题（并在日志里打一次）。
- **只有标题也能查词**：artist 为空时走 `https://lrclib.net/api/search?q=<title>`，
  数组结果里优先取带 `syncedLyrics` 的一条；`/get` 的结果解析保持不变。
- **不再误清空**：读 `SBMediaController` 找不到标题时只 return，不会覆盖 hook 已经写入的曲目。
- 探测新增：`lyrics sync APIs:`（dlsym 查 `MRMediaRemoteCopyNowPlayingInfo`、
  `…GetNowPlayingInfoSync`、`…CopyNowPlayingInfoForClient`、`…GetNowPlayingInfoForClient`）
  与 `MPCMediaRemoteController` 实例/选择器。

## 1.2.7 — 2026-11-23（歌词：换元数据持有者）

报告 30 证明 `setNowPlayingInfo:` 收到的是 `__NSDictionaryM{isFirstTrack,isLastTrack}`，
即 `SBMediaController` 在 17.2 不持有曲目元数据。改为逐个探测可能的持有者：

- 公共框架：`MPNowPlayingInfoCenter.defaultCenter`（读 `nowPlayingInfo`）、
  `MPMusicPlayerController.systemMusicPlayer`（读 `nowPlayingItem`）。
- 系统类（有共享入口才试，不主动 new）：`SOMediaNowPlayingObserver`、`CPUINowPlayingManager`、
  `CSNowPlayingController`、`MRUNowPlayingController`、`MRNowPlayingClient`、
  `SBLockScreenNowPlayingController`。
- 每个实例都用「getter 扫描 + 字典键扫描」取 title/artist/duration/elapsed，
  一旦拿到就直接喂进歌词链路（本版可能不需要下一轮就能出词）。
- 日志：`lyrics probe4 <类>: title=… artist=… info=…`，以及各类的选择器清单。

## 1.2.6 — 2026-11-23（歌词：挂系统 setter 抓媒体 meta）

报告 29 的 `probe3` 给出结论：`SBMediaController` 没有 title/artist getter，只有

```
nowPlayingApplication, nowPlayingProcessPID, _nowPlayingInfo,
setNowPlayingInfo:, _mediaRemoteNowPlayingInfoDidChange:,
_mediaRemoteNowPlayingApplicationDidChange:, _sendMediaCommand:options:, _nowPlayingAppDidExit:
```

且 `_nowPlayingInfo` 里只有 `isFirstTrack,isLastTrack`（控制位），meta 是 MediaRemote 推给
SpringBoard 后才有的。所以不再“猜 getter”，改为**挂系统自己的入口**：

- `-[SBMediaController setNowPlayingInfo:]`：系统收到 now-playing 时必然经过这里，
  钩子里取参数（字典或对象，按 key/getter 双路提取 title/artist/album/duration/elapsed/rate）。
- `-[SBMediaController _mediaRemoteNowPlayingInfoDidChange:]`：通知回调里补读 `_nowPlayingInfo`。
- 提取沿用此前的 `sp_dict_find` / `sp_first_string` / `sp_first_number`（类型编码安全调用）。
- 新增 `lyrics classes:`：一次性枚举进程内所有含 `NowPlaying / MediaRemote / MediaController /
  MRNowPlaying` 的类名，万一仍取不到，可照单换数据源。

## 1.2.4 — 2026-11-23（歌词：媒体读取自适配）

报告 28 验证：测试文字能显示（`lyrics window created level=1100` / `window shown`），
但 `probe: ctrl=1 title=0 artist=0 elapsed=0 playing=1` —— iOS 17.2 的 `SBMediaController`
已经没有 `nowPlayingTitle/Artist/elapsedTime` 这些属性，只有播放状态。

### Changed

- 媒体读取改为**运行时自适配**：
  1. 先看 `nowPlayingInfo` 字典，按键名包含 `title/artist/album/duration/elapsed/rate`
     取值（兼容 `kMRMediaRemoteNowPlayingInfo*` 这类键）；
  2. 字典没有就走**选择器扫描**：把 `SBMediaController`（含父类）里零参 getter 按
     “名字含 needle、优先 nowplaying”排序，用返回类型编码安全调用（`@ / d / f / q / i / B`，
     其它类型不调用），拿到第一个非空值；
  3. 最后才回退到旧的 KVC 候选名。
- 探测日志升级为 `lyrics probe3`：打印选中字典、选中 getter 名、`info keys`、
  以及类里所有含 title/artist/elapsed/duration/media 的选择器清单（各一次）。

## 1.2.3 — 2026-11-23（未发布中间版）

- 排查用：`probe2` 打印 `nowPlayingInfo` 是否存在、`info keys`、类选择器清单。
  本地构建 1.0.1-9，未交付使用。

## 1.2.2 — 2026-11-23（歌词：加测试开关与全链路日志）

1.2.1 装好后启用歌词，悬浮窗没出现，且日志里没有任何 `lyrics:` 行——把链路拆开验证。

### Added

- **测试显示**（`soloPlusLyricsTest`，默认关）：不依赖媒体/网络，直接显示两行示例文字，
  用来单独验证「窗口能不能显示 / 能不能盖住 App」。
- 全链路日志：启动时 `lyrics: enabled=… test=…`、prefs 重载 `prefs reload: lyrics=…`、
  `lyrics window created` / `lyrics window shown`、`lyrics probe: ctrl=… title=…`、
  每 5s 一条 `lyrics tick: test=… title=… lines=… win=… cur=…`（预算 10 条）、
  `lyrics: now playing …` / `lyrics fetch …` / `lyrics ready …`。

### Changed

- tick 在 `enabled || test` 任一为真时运行；测试模式跳过媒体轮询。

## 1.2.1 — 2026-11-23（修 1.2.0 安全模式：清掉全部 block）

1.2.0（1.0.1-6）一装就进安全模式。定位到两处 block 字面量——clang19 本地链不给 block 的
`isa` 补 PAC，SpringBoard 一旦 retain/invoke 就 SIGBUS：

- `MRMediaRemoteGetNowPlayingInfo(queue, ^(CFDictionaryRef){…})`：改为 **完全不调该 API**；
  正在播放信息改读 SpringBoard 自己的 `SBMediaController`（KVC 同步属性，全 `@try` 包住）。
- `[pairs sortUsingComparator:^…]`：改为 `sortUsingFunction:context:` 的 C 比较器。

其它加固：

- 歌词定时器延后到 8s 启动，整段 tick 用 `@try/@catch` 包住；窗口创建也单独 `@try`。
- **默认关闭**（`soloPlusLyricsEnabled` 默认 NO）：新包先干净启动，确认稳定后在面板里手动打开。
- 日志：`lyrics: SBMediaController unavailable`、`lyrics: now playing 歌手 - 歌名`、
  `lyrics fetch: HTTP … lines=…`、`lyrics ready: … lines`。

## 1.2.0 — 2026-11-23（桌面歌词悬浮窗）

### Added

- **桌面歌词悬浮窗**：独立于 Solo 轮播的 `UIWindow`（SpringBoard 进程，高 windowLevel、不接管触摸），
  数据源与 Solo 一致——MediaRemote 正在播放信息 + LRCLIB（`https://lrclib.net/api/`）的
  `syncedLyrics`；0.2s 跟随播放位置（Elapsed + Timestamp × PlaybackRate）刷新；无同步歌词时自动隐藏。
- 样式：单行 / 双行（第二行显示下一句）、字体（系统 / 圆体 / 宋体 / 楷体）、字号 12–24、
  颜色（白 / 黑 / 粉 / 蓝 / 绿 / 黄）、描边、半透明背景、水平/垂直百分比定位（5%–95%）。
- 面板新增「桌面歌词」分组（增强 → 桌面歌词）；改动走 `com.chenlin8023.soloplus/reload` 即时生效。
- 日志：`lyrics window created` / `lyrics fetch: HTTP … synced=… lines=…` / `lyrics ready: … lines`。

### 已知 / 待确认

- 悬浮窗建在 SpringBoard 的窗口场景里；能否盖在第三方 App 上取决于系统场景合成层级，
  需实机确认。若只在主屏可见，下一版改为「按 App 注入 + 共享样式」的形态。
- 歌词走 LRCLIB 在线匹配（与 Solo 同源）：冷门曲目可能没有同步歌词，此时不显示。

## 1.1.3 — 2026-11-23（Duo 时间复现：改清空文字 + 玻璃刷新）

针对「轮播切到时钟页、Duo 上浮后模糊时间复现」。

### Fixed

- **文字级清空**：在 `UILabel setText:` / `setAttributedText:` 里，把 Duo 容器内的时间文字
  直接换成空串（原文存 associated object，关开关时还原）。这样 Solo 的玻璃/快照层抓不到时间，
  不会再从缓存里糊出一份。
- **跨容器压制**：给已隐藏的时间标签打标记；即使 Solo 重建/换容器（上浮时常见），
  标记过的标签仍继续隐藏，不依赖当前 anchor 命中。
- **玻璃背板刷新**：首次清空文字时让 `UnduoGlass*` / `*Backdrop*` / `*Blur*` 视图重排一次，
  冲掉旧快照里的模糊时间。
- **锚点变更即时补刀**：Duo 容器重建时立刻重跑隐藏/图标，不再等下一个 1s tick。

### Added

- 上浮检测：Duo `center.y` 变化 > 20pt 时打印 `duo float dy=…`，并 dump 视图两层 +
  `layer` 两层（最多 3 次），用于确认模糊时间到底是哪个视图/图层画的。

## 1.1.2 — 2026-11-23（Duo 时间只认容器内标签 / 电量去掉夹取）

按 `Solo 调试报告(24)` 的层级 dump 定位。

### Fixed

- **时间仍未隐藏**：dump 显示 Duo 容器顶部的 106×22 是**普通 UILabel**，不是
  `UnduoClockMirroredLabel`（后者是轮播时钟页的字，隐藏它会把大时钟一起干掉）。
  改为只隐藏「Duo 容器内、文本是时间形状」的 UILabel，不再碰 `UnduoClockMirroredLabel`。
- **电量左右偏移**：120 宽的标签在屏幕右缘触发水平 clamp，被夹回左侧（截图里偏左约 14pt）。
  宽度收到 64、删掉水平 clamp，按 Duo 容器 `frame` 居中——与容器同一坐标空间，天然对齐。
- `battery host` 日志补上锚点坐标与最终 frame，方便核对。

### Changed

- `duo row dump` 的 UILabel 行带文本，下次可直接点名。

## 1.1.1 — 2026-11-23（Duo 细节修正：时间真关掉 / 电量对齐 / 下方图标）

按实机调试报告（Solo 调试报告(23)）修的三处问题。

### Fixed

- **时间关不掉**：只把 `UnduoClockMirroredLabel` 设 `hidden` 会被 Solo 重新显示。
  现在在 `setHidden:` / `setAlpha:` / `setTextColor:` 三个 setter 上强制压住（隐藏 + alpha 0 +
  文字色透明），并把紧贴标签的包裹容器一并隐藏；恢复时只恢复自己打过标记的视图。
- **电量没对准 Duo 正下方**：原来把 106×88 的读数小栈当成圆环。改为向上取
  「宽度 ≥ 半屏、高度 < 整页」的 Duo 整行容器作为锚点，横向按该行居中，纵向行底 +2pt。
- **电量字重和读数不一致**：直接复用 5G 读数标签的 `font`（同字族/字重，尺寸 ×0.95），
  不再写死 13pt semibold。

### Added

- **隐藏 Duo 下方图标**（`soloPlusHideDuoIcons`，默认开）：锚定行内、读数下方、≤44pt 的
  图片类视图（定位箭头等）隐藏，不影响电量标签。
- **电量上下微调**（`soloPlusDuoBatteryOffset`，-8 / -4 / 0 / +4 / +8）：位置仍不合适时手动推。
- 诊断日志：`clock label hooks installed` / `duo anchor` / `duo row dump`（一次性层级 dump）/
  `duo icon hide`。

## 1.1.0 — 2026-11-23（Duo 细节：时间开关 + 环下电量）

针对 Duo 组件的两个点改：上方时间可单独关掉（状态栏已有时间），圆环下方补电量百分比。

### Added

- **显示 Duo 时间**（`soloPlusShowDuoTime`，默认开）：命中 Solo 时钟文字类
  `UnduoClockMirroredLabel` 的“时间形”文本后隐藏；同时对「Duo 挂件容器内、圆环上方」
  的普通时间标签兜底。只恢复自己打过标记的标签，不碰 Solo 的透明度/隐藏动画。
- **Duo 下方电量**（`soloPlusShowDuoBattery`，默认开）：从数据读数向上推断圆环视图，
  把自建 `UILabel` 挂到圆环宿主层下方（横向居中、4pt 间距）；≤20% 红色、充电绿色。
  电量优先 `UIDevice.batteryLevel`，取不到时 `dlsym` 调 IOKit.ps（不新增链接依赖）。
- 面板新增「Duo 细节」分组（显示 Duo 时间 / Duo 下方电量），改动即时生效。
- 调试日志新增 `duo ring` / `duo time hide` / `battery host` 三类自证行（需开调试日志）。

### Changed

- 伴随包版本 1.0.0 → 1.1.0；合并包对应 1.0.1-2（Package id 不变）。

### 说明

- 圆环定位与时间标签都按运行时视图特征推断，未在真机核过；若位置或命中不对，
  开调试日志后把 `duo ring` / `duo time hide` / `battery host` 行发出来即可定点修。

## 1.0.1 — 2026-11-23（合并版上架：Solo1.0.1优化）

把 Solo 1.0.1 本体与 Solo+ 1.0.0 合为单包，以独立 Package ID 上架越狱源。

### Added

- `build_release.sh`：发布口径合并——`com.chenlin8023.solo.full`、显示名 `Solo1.0.1优化`，
  `Conflicts/Replaces: com.oakstheawesome.solo, com.chenlin8023.soloplus`，产物同时交付到 `release/`。
- `build_merged.sh`：元信息支持 `PKG_ID` / `PKG_NAME` / `PKG_VERSION` / `PKG_MAINTAINER` /
  `PKG_AUTHOR` / `PKG_DEPENDS` / `PKG_CONFLICTS` / `PKG_REPLACES` / `PKG_DESCRIPTION` / `OUT_DEB`
  覆盖；默认值仍是本地测试口径（id 沿用官方、版本 `1.0.1+sp*`）。
- `tools/rewrite_control.py`：按 JSON 规格重写 control（覆盖/新增/空值删除，Description 置尾）。
- `tools/verify_release.sh`：发布前核验——原包文件逐字节未改、新增文件清单、
  `arm64 + arm64e` FAT 双切片、`isa: auth>0 plain=0`、可执行位、面板 plist。

### Changed

- 发布形态改为独立包 id，不再占用官方 `com.oakstheawesome.solo`：装本包时替换官方 Solo
  与旧独立增强包（避免双注入，也不把官方包在别的源里顶版本）。
- README 安装章节改为两条路径（源站合并版 / 官方 Solo + 独立增强包），并补发布流程与核验命令。

### 验证

- Solo+ 1.0.0 已在 iPhone 15 Pro / iOS 17.2.1 / RootHide 验收；合并包内 Solo 原文件逐字节未改。
- 合并包 1.0.1-1 由上述二进制重组，本版未单独跑机；发布前全部走 `tools/verify_release.sh`。

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
