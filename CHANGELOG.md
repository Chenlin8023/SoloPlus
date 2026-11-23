# Changelog

All notable changes to Solo+ are documented here.
The project is an unofficial runtime enhancement layer for Solo 1.0.1.

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
