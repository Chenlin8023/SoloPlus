# Solo1.0.1优化 · 1.0.1-16 — Release Notes

日期：2026-11-23
包名：`com.chenlin8023.solo.full`（显示名 **Solo1.0.1优化**）
形态：Solo 1.0.1 本体 + Solo+ 1.3.0 增强层合并的 **rootless 单包**（`iphoneos-arm64`，`/var/jb`）
源站：<https://chenlin8023.github.io/>（**本版已上架**）

## 1.0.1-16（已上架）：摘除桌面歌词模块，Duo 时间 / 标识 / 电量整理

按要求**放弃桌面歌词**：这一版把「增强 → 桌面歌词」整块下线，包体回到只做 Duo / 状态栏 /
Dockicon / 轮播铺满的形态。

移除的内容（都不再编译进 dylib，包内也搜不到任何 lyrics 字样）：

- 悬浮歌词窗：UIWindow、单/双行样式、字体 / 字号 / 颜色 / 描边 / 半透明背景、位置滑杆、测试显示；
- LRCLIB 拉词：`/api/get`、`/api/search`、LRC 解析、后台队列与重试；
- SpringBoard 侧媒体探测：probe3 / probe4、类名枚举、选择器扫描，以及 `SBMediaController` 的
  `setNowPlayingInfo:` / `_mediaRemoteNowPlayingInfoDidChange:` 两个 hook；
- 上一版刚加的「只读 Solo 媒体缓存」（含 IMP 指纹校验与 block 复用）。

面板同步收缩为 4 项：**状态栏 / Duo / 轮播铺满 / Dockicon**（另有调试日志开关），
`SoloPlusLyrics.plist` 已删除。先前写入 `com.oakstheawesome.solo` 域的 `soloPlusLyrics*` 旧键
不会再被读取，留在偏好里也无影响。

### Duo：时间 / 标识 / 电量

- **Duo 时间**（面板：增强 → Duo → Duo 细节 → 显示 Duo 时间，默认开）
  关掉后不只 `hidden`：在 `setText:` / `setAttributedText:` 里直接把文字换成空串，并对
  `setHidden:` / `setAlpha:` / `setTextColor:` 三处一起压制，Solo 之后重建玻璃 / 快照层时
  也抓不到时间文字，不会再「糊」出来；恢复时只动自己打过标记的视图，不碰大时钟与状态栏。
- **数据标识**（面板：增强 → Duo → 数据标识）
  Duo 读数里的 `5G` 显示为「5G + 小号大写 A」：A 用 62% 字号、底部与 5G 同基线，字重跟随原标签；
  `LTE / 3G / E / Wi-Fi` 保持原样。标识字号 0.8–1.4、字重 跟随 / 细 / 常规 / 中粗 / 粗 五档。
- **Duo 电量**（面板：增强 → Duo → Duo 细节 → Duo 下方电量，默认开）
  64×22 的百分比标签挂在 Duo 容器同一层、按容器 frame 水平居中，修掉了先前贴近屏幕右缘时被
  系统夹回左边约 14pt 的偏移；纵向 = 容器底 + 2pt + 微调（−8 / −4 / 0 / +4 / +8）。
  ≤20% 红色、充电绿色；数据源 `UIDevice.batteryLevel`，取不到时走 IOKit.ps，10 秒刷新。

本轮详情页首图就是这台机器的实机主屏：Duo 读数「5G + 小号 A」、环下 97% 电量、Duo 时间已在
面板关掉（图为 720×1561 的截图压缩版）。

### 产物

```
com.chenlin8023.solo.full_1.0.1-16_iphoneos-arm64.deb
SHA-256: 9038f24d4571ef0f43337e92b20d133d4bd46d9a56c7046b4778c966342bd420
大小：451316 字节
```

上架信息：源站 `https://chenlin8023.github.io/` 的 Packages 已写入
`Version: 1.0.1-16`、同名 deb 直链与上述 SHA-256；Sileo / Zebra 详情页首屏带截图，
网页详情页 `depictions/com.chenlin8023.solo.full/index.html` 同步。

安装后 **respring**；面板路径 设置 → Solo → 增强，里面应只剩 状态栏 / Duo / 轮播铺满 / Dockicon。

## 1.0.1-15（本地构建，未上架）：歌词改读 Solo 自己的媒体缓存

报告 32 的结论：**窗口没问题**（`lyrics window created level=1100` / `window shown`，测试文字
可见），卡点仍在「取不到曲目」——`SBMediaController` 只有 `isFirstTrack,isLastTrack`，
`MPNowPlayingInfoCenter` 恒为 nil，`CPUINowPlayingManager` 的 `lastContentItemTitle` 也是空。

这一版不再猜持有者，而是把 Solo 1.0.1 的媒体链路拆开看：

- Solo 用的是 `MRMediaRemoteGetNowPlayingInfo(queue, block)`（它自己的 dylib 里 block 签名是
  `pacda` + diversity `0x6ae1`，所以能安全用）；回调落在 `Solo.dylib 0x282ec`，
  按 8 个 `kMRMediaRemoteNowPlayingInfo*` 键取出 **标题 / 歌手 / 专辑 / 时长**，
  写进 `__DATA` 全局 `0x89028 / 0x89030 / 0x89038 / 0x89868`。
- 播放进度另外存：`elapsed 0x880fb8`、`timestamp 0x880fc0`、`playing 0x890838`；
  Solo 自己的位置函数 `0x27c24` 就是 `elapsed + (now − timestamp)`。
- 两个通知入口只是尾巴跳到共用取数体 `0xbf5c`。

本版做法：

1. **只读缓存**（不造 block、不写 Solo 内存）：每 1 秒读一次标题/歌手/专辑/时长 + 进度，
   有曲目就覆盖本地 now-playing 状态，日志 `lyrics solo: 歌手 - 标题 dur=… el=… ts=… play=…`。
2. **主动催一次**：还没有曲目时，每 10 秒把 Solo 自己的全局 block（`0x78fb0`，isa 是 Solo
   用 `pacda` + diversity `0x6ae1` 签过的；global block 的 `Block_copy` 原样返回）交给
   `MRMediaRemoteGetNowPlayingInfo`，回调仍然是 Solo 的回调、写的就是我们要读的全局；
   这条路不通时退回调 Solo 的取数体 `0xbf5c`，再不行发
   `kMRMediaRemoteNowPlayingInfoDidChangeNotification`。
3. **偏移指纹**：启动时用 `-[UnduoMediaRemoteObserver unduoNowPlayingInfoChanged:]` 的 IMP
   是否等于 `base + 0xbf58` 校验；不匹配就放弃这条源并写
   `lyrics solo: offsets mismatch …`（Solo 换版本不会误读内存）。
4. **歌词两段拉取**：`/api/get` 取不到就再查 `/api/search?q=歌手 标题`；
   失败 20 秒后重试，同一首最多 3 次（旧版失败一次就永久跳过这首）。
5. 日志加料：`lyrics tick: … src=solo|sb|- … pos=…/… play=…`，
   `lyrics fetch: get=… search=… synced=… plain=… lines=…`，`lyrics miss: … (attempt N)`。

### 怎么看这次成没成

装好后播一首歌、回主屏，`/var/jb/var/mobile/Library/Preferences/Solo/Logs/Solo.log` 里：

- `lyrics solo: cache ready base=0x…` → 数据源接上了；
- `lyrics solo: 歌手 - 标题 …` → 拿到曲目了；
- `lyrics fetch: get=200 synced=1 lines=N` → 拿到同步歌词；
- `lyrics tick: … src=solo … lines=31 win=1 cur=…` → 窗口在按行滚动。

若仍是 `src=-`、`title=(nil)`：说明这台机器上 `com.soda.music` 压根没把 now-playing
发布给 MediaRemote（锁屏/控制中心也不会显示这首歌），那就不是读取方式的问题，
下一版得改成「往 App 内注入 + 跨进程传 meta」。日志里 `lyrics solo:` 有没有值可以直接区分这两种情况。

产物：

```
com.chenlin8023.solo.full_1.0.1-15_iphoneos-arm64.deb
SHA-256: d3358a2abfb443e6368aa46661b57a5c0b9aa00a9eacb13ec5ef6ad886349dcb
大小：475856 字节
```

## 1.0.1-14（本地构建，未上架）：标题兜底

报告 31 结论：公共 API 在 SpringBoard 里是 nil；`SOMediaNowPlayingObserver` 无实例且取词接口是
block 版；`CPUINowPlayingManager` 只有 `lastContentItemTitle`；`MRUNowPlayingController` 等无实例。

本版：

- 每 5 个 tick 轮询 `CPUINowPlayingManager.lastContentItemTitle`，有值就当标题（日志 `lastContentItemTitle=`）。
- 只有标题时改走 LRCLIB **搜索**接口 `/api/search?q=<标题>`，数组里优先取带 `syncedLyrics` 的结果。
- 读取 `SBMediaController` 失败时不再清空已有曲目（避免覆盖 hook 写入的数据）。
- 新增 `lyrics sync APIs:` 探测：dlsym 检查 `MRMediaRemoteCopyNowPlayingInfo` /
  `…GetNowPlayingInfoSync` / `…CopyNowPlayingInfoForClient` / `…GetNowPlayingInfoForClient` 是否存在。

产物：

```
com.chenlin8023.solo.full_1.0.1-14_iphoneos-arm64.deb
SHA-256: 38fd80d7688f72b052a2ccfafc3bff02d1e8404f79947ea15c2dddc38eed0a85
大小：473276 字节
```

## 1.0.1-13（本地构建，未上架）：换元数据持有者

报告 30：`ingest cls=__NSDictionaryM keys=isFirstTrack,isLastTrack` —— `SBMediaController`
在 17.2 只存控制位，不存曲目 meta。本版改为**逐个持有者探测**：

- 公共框架：`MPNowPlayingInfoCenter.defaultCenter`（`nowPlayingInfo`）、
  `MPMusicPlayerController.systemMusicPlayer`（`nowPlayingItem`）。
- 系统类（仅有 `sharedInstance/sharedObserver/sharedManager/sharedController/localClient/
  defaultController` 时才取实例，绝不主动 new）：`SOMediaNowPlayingObserver`、
  `CPUINowPlayingManager`、`CSNowPlayingController`、`MRUNowPlayingController`、
  `MRNowPlayingClient`、`SBLockScreenNowPlayingController`。
- 每个实例都用「零参 getter 扫描 + 字典键扫描」提取 `title/artist/duration/elapsed`；
  **一旦取到就直接喂进歌词链路**，所以这版有可能直接就出词。
- 日志：`lyrics probe4 <类>: title=… artist=… info=…`，以及各类选择器清单。

产物：

```
com.chenlin8023.solo.full_1.0.1-13_iphoneos-arm64.deb
SHA-256: 0f6d95e4facea68d34082dc1dbc3210cc235de892201add67e787c0a53429f1d
大小：472256 字节
```

## 1.0.1-12（本地构建，未上架）：从系统入口截媒体 meta

报告 29 证实：窗口正常（测试文字可见），`SBMediaController` 只剩
`_nowPlayingInfo` / `setNowPlayingInfo:` / `_mediaRemoteNowPlayingInfoDidChange:` 这些入口，
没有 title/artist getter，而且 `_nowPlayingInfo` 里只有 `isFirstTrack,isLastTrack`。

本版改为**挂系统自己的入口**取数据（依旧零 block）：

- 钩 `-[SBMediaController setNowPlayingInfo:]`：MediaRemote 推 now-playing 时 SpringBoard 必然走这里，
  在钩子里从参数提取 `title/artist/album/duration/elapsed/rate`（字典按键名 / 对象按 getter 两路都试）。
- 钩 `-[SBMediaController _mediaRemoteNowPlayingInfoDidChange:]`：回调后再读一次 `_nowPlayingInfo` 兜底。
- 新增 `lyrics classes:` 一次性枚举：列出进程内所有含 `NowPlaying / MediaRemote / MediaController /
  MRNowPlaying` 的类名——若这次还取不到，下一版直接按清单换数据源。

产物：

```
com.chenlin8023.solo.full_1.0.1-12_iphoneos-arm64.deb
SHA-256: a54ba569e3450616d4a94e1c6e58d9794c5e2cf739293ad506992b156d0cef91
大小：469552 字节
```

## 1.0.1-10（本地构建，未上架）：媒体读取自适配

报告 28 结论：

- **窗口没问题**：`lyrics window created level=1100`、`window shown`、`tick … win=1`，
  测试文字在主屏显示正常；
- **卡在媒体数据**：`probe: ctrl=1 title=0 artist=0 elapsed=0 playing=1` ——
  iOS 17.2 的 `SBMediaController` 已没有 `nowPlayingTitle/Artist/elapsedTime`，
  只剩播放状态，所以取不到歌名 → 不会去查歌词。

本版把媒体读取改成运行时自适配：

1. `nowPlayingInfo` 字典优先：按键名包含 `title/artist/album/duration/elapsed/rate`
   取值（兼容 `kMRMediaRemoteNowPlayingInfo*` 这类键名）。
2. 字典没有就**扫描类里所有零参 getter**（含父类），按名字含 `title/artist/elapsed/duration/playing`
   过滤、优先 `nowplaying` 前缀，按返回类型编码安全调用（`@ / d / f / q / i / B` 才调用，
   其它类型直接跳过），取第一个非空值。
3. 最后回退到旧 KVC 候选名。

探测日志 `lyrics probe3` 会打印：选中的字典/getter 名、`info keys`、以及类里所有
含 title/artist/elapsed/duration/media 的选择器清单——即使这次仍取不到，下一版可照单点菜。

产物：

```
com.chenlin8023.solo.full_1.0.1-10_iphoneos-arm64.deb
SHA-256: a874ff7cd42d41239449100269fbf73ba79ca64907a191c5647fee8cde149bde
大小：467368 字节
```

## 1.0.1-8（本地构建，未上架）：歌词可观测化

1.0.1-7 能正常启动、也能启用歌词，但窗口没出现，日志里一条 `lyrics:` 都没有——
说明链路在报错之前就静默返回了。本版把它拆成可验证的两段：

1. **测试显示**（面板里新增，默认关）：不依赖媒体与网络，直接渲染两行示例；
   能显示 → 窗口/样式没问题，问题在媒体数据；不能显示 → 问题在窗口场景层级。
2. **全链路日志**：
   - `lyrics: enabled=… test=…`（启动时读到开关）
   - `prefs reload: lyrics=… test=…`（面板改动是否送达 SpringBoard）
   - `lyrics window created level=…` / `lyrics window shown` / `lyrics window failed: …`
   - `lyrics probe: ctrl=… title=… artist=… elapsed=… playing=…`（`SBMediaController` 能力探测）
   - `lyrics tick: test=… title=… lines=… win=… cur=…`（每 5s 一条，预算 10 条）
   - `lyrics: now playing …` / `lyrics fetch: HTTP … lines=…` / `lyrics ready: … lines`

产物：

```
com.chenlin8023.solo.full_1.0.1-8_iphoneos-arm64.deb
SHA-256: 6fbfca71dd96372f9a239fafa7da9b7a725f372212d4b4991b57437403e89d0c
大小：462016 字节
```

## 1.0.1-7（本地构建，未上架）：修 1.0.1-6 的安全模式

**根因**：1.0.1-6 里有两处 block 字面量——

1. `MRMediaRemoteGetNowPlayingInfo(queue, ^(CFDictionaryRef info){…})`：MediaRemote 会 copy/持有
   这个 block，SpringBoard 对 block 做 isa 认证时 SIGBUS（clang19 本地链不生成 block 的 PAC）。
2. `[pairs sortUsingComparator:^…]`：排序同样会持有 block。

**修法**：

- 不再调用 MediaRemote 的 block API；改读 `SBMediaController` 的同步属性
  （`nowPlayingTitle/Artist/Album/elapsedTime/duration/isPlaying`，KVC + `@try` 兜底）。
- LRC 排序改为 `sortUsingFunction:context:`（C 比较器）。
- 全文件已确认 **0 个 block**（`^(` 与 `sortUsingComparator` 均无命中）。
- 定时器延后到 8s，tick 与窗口创建各自 `@try`；**歌词默认关闭**，先保证干净启动。

产物：

```
com.chenlin8023.solo.full_1.0.1-7_iphoneos-arm64.deb
SHA-256: 20a54d00245747b2025d7ab8f5b4abaf4b213d55a7b924c46b5acfd7487522a8
大小：461572 字节
```

## 1.0.1-6（本地构建，未上架）：桌面歌词

- **独立悬浮窗**：不再受「轮播 / 主屏 / 媒体页」限制。窗口建在 SpringBoard，高 `windowLevel`、
  `userInteractionEnabled = NO`（点按穿透）。
- **数据源与 Solo 同源**：MediaRemote 的 Title/Artist/Album/Duration/Elapsed/PlaybackRate/Timestamp
  + LRCLIB `https://lrclib.net/api/get` 的 `syncedLyrics`；0.2s 按
  `Elapsed + (now − Timestamp) × PlaybackRate` 跟随播放位置，无同步歌词自动隐藏。
- **样式**（面板：增强 → 桌面歌词）：
  - 行数：单行 / 双行（第二行为下一句，字号 0.9×、透明度 72%）
  - 字体：系统 / 圆体 / 宋体 / 楷体；字号 12 – 24
  - 颜色：白 / 黑 / 粉 / 蓝 / 绿 / 黄；描边开关（深/浅背景都清楚）；半透明背景开关
  - 位置：水平 5%–95%、垂直 5%–95% 两个滑杆
- 网络走后台队列 + 同步请求（不引入 block 回调），解析在后台、赋值回主线程；
  歌词按 `Title|Artist|Duration` 去重，同一首不重复请求。

### 待实机确认

- SpringBoard 的窗口场景能否盖在第三方 App 上：iOS 的跨场景合成由系统决定，
  如果只在主屏可见，下一版改成「按 App 注入 + 共享样式/歌词」的形态。
- 冷门曲目 LRCLIB 可能没有同步歌词，此时窗口自动隐藏（可先用 Solo 轮播歌词确认曲目是否有词）。

产物：

```
com.chenlin8023.solo.full_1.0.1-6_iphoneos-arm64.deb
SHA-256: 335b179787384a8ffb5e4d5d1d27e235647cf890a67ed58b5e6def7df75a3d02
大小：461484 字节
```

## 1.0.1-5（本地构建，未上架）

针对「轮播切时钟页 → Duo 上浮 → 模糊时间复现」：

- **文字直接清空**：Duo 容器内的时间标签在 `setText:` / `setAttributedText:` 里换成空串
  （原文存起来，开关关掉时还原）。Solo 的玻璃/快照层抓不到文字，就不会再糊出时间。
- **跨容器压制**：被隐藏过的标签打标记，即使 Solo 上浮时重建容器，旧标签也会继续被压住。
- **玻璃背板刷新**：首次清空时让 `UnduoGlass*` / `*Backdrop*` / `*Blur*` 重排，冲掉旧快照。
- **锚点变更即时补刀**：Duo 容器换了立刻重跑隐藏/图标，不等 1s tick。
- 新增 `duo float dy=…` 与上浮瞬间的视图/layer 两层 dump（最多 3 次）——如果模糊时间仍在，
  这份 dump 能直接指出是哪个视图或哪个 layer 画的。

产物：

```
com.chenlin8023.solo.full_1.0.1-5_iphoneos-arm64.deb
SHA-256: d8d0e65b844ec0dafd3fcb7a1e1ed31daa4bfacd26a033a2d1d53ad3eb42d1eb
大小：450976 字节
```

## 1.0.1-4（本地构建，未上架）

按 `Solo 调试报告(24)` 的层级 dump 修正：

- **Duo 时间**：dump 显示 Duo 容器是 `UIView 106x88 @298,70`，顶部那行时间是
  **普通 UILabel 106x22**，不是 `UnduoClockMirroredLabel`（后者属于轮播时钟页，
  隐藏它会连大时钟一起弄没）。本版只隐藏「Duo 容器内 + 文本是时间形状」的 UILabel，
  大时钟保持原样。
- **电量左右**：120 宽标签在屏幕右缘触发水平夹取，被往左推（截图里偏左约 14pt）。
  宽度收到 64、去掉水平夹取，按 Duo 容器 frame 居中——和容器同一坐标空间。
- `battery host` 日志补 `at x,y -> frame x,y`；`duo row dump` 的 UILabel 行带文本。

关于参考图：Solo 在「轮播停在时钟页」时会自己隐藏 Duo 时间并把整体上浮。查了 Solo 1.0.1 的
Darwin 通知只有 `ReloadPrefs` / `RequestCalendars` / `CalendarsPublished` / `lyrics` /
`.clocktimer`，没有轮播页通知可伪造；本轮改为「按容器内标签精确隐藏」，**没有做上浮位移**
（避免与 Solo 自己的布局/入场动画打架）。若需要上浮，请说明，我再单独做位移并跟随布局。

产物：

```
com.chenlin8023.solo.full_1.0.1-4_iphoneos-arm64.deb
SHA-256: 26046fe75f6a01d8f09d3a37d5254b5c88560e4edc4fd1c8e3c4e2d143a166b7
大小：449620 字节
```

## 1.0.1-3（本地构建，未上架）

按实机调试报告（`Solo 调试报告(23)`）修正：

- **时间关不掉**：Solo 会重新显示时钟标签。改为在 `setHidden:` / `setAlpha:` / `setTextColor:`
  三个 setter 上强制隐藏，并把文字色压成透明；紧贴标签的包裹容器一并隐藏。恢复只动自己打过标记的视图。
- **电量没对准**：原来把 106×88 的读数小栈当圆环。现在向上取「宽度 ≥ 半屏、高度 < 整页」的
  Duo 整行容器作锚点，横向按该行居中，纵向行底 +2pt。
- **字重不一致**：电量直接复用 5G 读数标签的 `font`（同字族/字重，尺寸 ×0.95）。
- 新增 **隐藏 Duo 下方图标**（默认开，去掉定位箭头等 ≤44pt 图片类符号）与
  **电量上下微调**（-8 / -4 / 0 / +4 / +8）。
- 诊断日志新增：`clock label hooks installed` / `duo anchor` / `duo row dump` / `duo icon hide`。

产物：

```
com.chenlin8023.solo.full_1.0.1-3_iphoneos-arm64.deb
SHA-256: ae62749b350f632d0810845f81e9de51b47cdae0ddee249bccc8d00d549b85f6
大小：450924 字节
```

## 1.0.1-2 新增：Duo 细节

- **显示 Duo 时间**（面板：增强 → Duo → Duo 细节）：单独关掉 Duo 上方的时间文字；
  状态栏已有时间，不想重复显示时用。默认开。
- **Duo 下方电量**：在圆环下方显示剩余电量百分比（例如 `87%`），≤20% 红色、充电绿色；
  不再把数字塞进圆环里。数据源 `UIDevice.batteryLevel`，取不到时走 IOKit.ps 兜底。默认开。
- 两处都按运行时视图特征定位（Solo 时钟文字类 `UnduoClockMirroredLabel` + 从数据读数
  向上推断的圆环视图），并新增 `duo ring` / `duo time hide` / `battery host` 调试日志行。

## 这是什么

把官方 Solo 1.0.1 与 Solo+ 增强层合成 **一个 deb**：装一次就同时得到 Solo 与全部增强项，
不用先装官方包。包 id 独立，安装时通过 `Conflicts/Replaces` 自动替换官方
`com.oakstheawesome.solo` 与旧独立增强包 `com.chenlin8023.soloplus`，不会双注入。

## 优化说明

### 体验

- **状态栏**：Solo 在主屏把系统状态栏渐隐；增强层接管该行为并强制保留，面板可随时关掉。
- **Duo 独立开关**：隐藏 Duo 状态环/读数时轮播仍可单独使用（Duo 尺寸与轮播硬绑定，故不做单独调节）。
- **数据标识**：Duo 读数里的 `5G` 显示为 `5G` + 小号大写 `A`（62% 字号、底部与 5G 同基线）；
  `LTE / 3G / E / Wi-Fi` 保持原样；标识字号 0.8–1.4、字重 跟随/细/常规/中粗/粗。
- **轮播铺满**：复位 Solo 的 content scale fix（约 0.83），小组件内容铺满 364×170 轮播背景，
  可在面板关闭（铺满可能裁切小组件边缘）。
- **面板**：入口注入 Solo 设置页「增强」分组——状态栏 / Duo / 轮播铺满 / Dockicon + 调试日志，
  开关写在 Solo 自己的域（`com.oakstheawesome.solo`），注销后保持。

### Dockicon（本轮主要工程量）

- 竖排 Dock 上限 **5 / 6**；6 个图标需手动拖入，依赖 Atria（实测 1.4.1-11）。
- 图标大小 0.85–1.0 走 `SBIconView.iconContentScale`：**只缩图标内容、不改 Dock 列表几何**，
  打开/关闭 App 与文件夹不再出现落点回拉。
- 6 图标时 Dock 列表自动下移，避免与上方内容挤压。
- **6→5 防呆**：注销后约 3 秒把 Dock 最后一个图标迁回主屏第一处可放页面；迁移失败则保持
  6 图标并写日志，不强制弹出（旧方案会因 SpringBoard 强踢进安全模式）。
- 有效上限不低于当前图标数；Dock model 用指针身份匹配，文件夹内部模型不会误套 Dock 容量/`gridSize`。

### 工程

- `arm64 + arm64e` FAT 双切片（SpringBoard 只加载 arm64e 切片，单 arm64 会被 dyld 静默拒载）。
- arm64e `__cfstring` isa PAC 补丁（diversity `0x6AE1`、addrDiv=1、key=2）+ `ldid -S`，
  产物断言 `isa: auth>0 plain=0`。
- **Solo 原文件逐字节未改**：只新增 `SoloPlus.dylib` / `SoloPlus.plist` 与 5 个面板 plist；
  `tools/verify_release.sh` 会逐文件比对官方包。

## 安装 / 升级

1. 添加源 `https://chenlin8023.github.io/`；
2. 安装 **Solo1.0.1优化**（会自动卸掉官方 Solo 与旧增强包）；
3. respring；确认 设置 → Solo → 增强 可进入。

后续版本只递增修订号（`1.0.1-2` …），`Package:` 不变，升级链不断。
卸载本包会一并移除 Solo 本体；需要时从 Solo 官方源装回。

## 已知限制

- Dock 拖动/换位仍有可感知卡顿。
- Dock 内放文件夹时不建议同时开 6 图标。
- 轮播铺满可能裁切小组件边缘。
- 依赖 Solo 1.0.1 私有实现（`UnduoWidgetCarousel`、`SBDockIconListView`、`SBIconListModel` 等），
  Solo 或 iOS 升级后可能需要适配。

## 验证状态

- Solo+ 1.0.0 / 1.1.0 已在 iPhone 15 Pro / iOS 17.2.1 / RootHide 验收（1.1.0 的两处 Duo 细节
  为新增，UI 定位待真机确认）；官方 Solo 1.0.1 原文件未改。
- 合并包 `1.0.1-2` 由上述二进制重组，**本版未单独跑机**；发布前已跑
  `tools/verify_release.sh`（文件指纹 / 双切片 / PAC / 权限）与源站索引自检。

## 产物

```
com.chenlin8023.solo.full_1.0.1-2_iphoneos-arm64.deb
SHA-256: 254b3b18b0d06da5a4f49e7df0524d4954bf603fbe200ce6b9e285fec44c7b22
大小：448728 字节
```

历史（仍可在源站装回）：

```
1.0.1-1  SHA-256: 3c12055e9e9af4544b2b3d2264e038fdb4b8c265316800185bc3eee34c4b8553
```

## 许可

Solo+ 源码 MIT；Solo 的二进制与商标归 OaksTheAwesome，Atria 归 ren7995。
本包内含 Solo 1.0.1 原文件，打包方未获上游再分发授权，仅在本源站发布，请勿二次转载。
