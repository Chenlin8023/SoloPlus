// SPDX-License-Identifier: MIT
// Solo+ 1.0.0 — 状态栏 / Duo 展示 / 数据标识 / 轮播铺满 / Dockicon（内容缩放、6 图标、自动迁回）
// 伴随 Solo.dylib 注入 SpringBoard；Settings 进程只负责把 Solo+ 分组注入 Solo 面板。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <pthread.h>
#include <math.h>
#include <stdint.h>

static NSString *const kSoloDomain = @"com.oakstheawesome.solo";
static NSString *const kKeepStatusBarKey = @"soloPlusKeepStatusBar";
static NSString *const kDebugKey = @"soloPlusDebug";
static NSString *const kShowDuoKey = @"soloPlusShowDuo";
static NSString *const kDataFontScaleKey = @"soloPlusDataFontScale";
static NSString *const kDataFontWeightKey = @"soloPlusDataFontWeight";
static NSString *const kSoloLogPath = @"/var/jb/var/mobile/Library/Preferences/Solo/Logs/Solo.log";

static BOOL gKeepStatusBar = YES;
static BOOL gDebug = NO;
static BOOL gShowDuo = YES;
static BOOL gShowDuoTime = YES;
static BOOL gShowDuoBattery = YES;
static double gDuoBatteryOffset = 0.0;
static BOOL gHideDuoIcons = YES;
static double gDataFontScale = 1.0;
static double gDataFontWeight = 0.0; // 0=跟随 1=细 2=常规 3=中粗 4=粗
static double gDockMaxIcons = 5.0;
static BOOL gCarouselFill = YES;

static __weak UIView *gDuoAnchorView = nil;   // Duo 容器（106x88 小挂件）
static __weak UIView *gDuoBatteryHost = nil;
static UILabel *gDuoBatteryLabel = nil;
static char spDuoTimeTextKey = 0;             // 被我们清空/隐藏的 Duo 时间原文

static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static int gBlockedLogBudget = 8;
static int gUnmatchedStatusLogBudget = 8;
static int gLockGuardLogBudget = 24; // 锁屏护栏/还原（1.3.21 扩容）：深会话 8 条会被烧光导致日志失明
static int gSbDumpLaterBudget = 8;  // 锁屏栏终态取证：0.6s+2.5s 双点，每轮 2 个
static int gForcedLogBudget = 8;
static int gSbDumpBudget = 6;   // 一次性状态栏层级 dump 预算（诊断用，1.3.21 扩容防深会话失明）
static NSHashTable *gKeptViews = nil; // 被 Solo 隐藏又被我们拦回的视图（weak）

static void sp_log(NSString *fmt, ...) {
    if (!gDebug) return;
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (body.length == 0) return;
    NSString *line = [NSString stringWithFormat:@"[Solo+] %@", body];
    line = [line stringByAppendingString:@"\n"];
    NSLog(@"[Solo+] %@", body);
    const char *path = kSoloLogPath.fileSystemRepresentation;
    const char *utf8 = line.UTF8String;
    if (!path || !utf8) return;
    pthread_mutex_lock(&gLogLock);
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) { write(fd, utf8, strlen(utf8)); close(fd); }
    pthread_mutex_unlock(&gLogLock);
}

static BOOL sp_read_bool(NSString *key, BOOL fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSoloDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kSoloDomain);
    BOOL out = fallback;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) out = CFBooleanGetValue((CFBooleanRef)v);
        else if (CFGetTypeID(v) == CFStringGetTypeID()) out = CFStringGetIntValue((CFStringRef)v) != 0;
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int n = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n); out = n != 0;
        }
        CFRelease(v);
    }
    return out;
}

static double sp_read_double(NSString *key, double fallback) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kSoloDomain);
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)kSoloDomain);
    double out = fallback;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, &out);
        else if (CFGetTypeID(v) == CFStringGetTypeID()) out = CFStringGetDoubleValue((CFStringRef)v);
        CFRelease(v);
    }
    return out;
}

static void sp_load_prefs(void) {
    gKeepStatusBar = sp_read_bool(kKeepStatusBarKey, YES);
    gDebug = sp_read_bool(kDebugKey, NO) || sp_read_bool(@"debugLogging", NO);
    gShowDuo = sp_read_bool(kShowDuoKey, YES);
    gShowDuoTime = sp_read_bool(@"soloPlusShowDuoTime", YES);
    gShowDuoBattery = sp_read_bool(@"soloPlusShowDuoBattery", YES);
    gDuoBatteryOffset = sp_read_double(@"soloPlusDuoBatteryOffset", 0.0);
    if (gDuoBatteryOffset < -16.0) gDuoBatteryOffset = -16.0;
    if (gDuoBatteryOffset > 24.0) gDuoBatteryOffset = 24.0;
    gHideDuoIcons = sp_read_bool(@"soloPlusHideDuoIcons", YES);
    gDataFontScale = sp_read_double(kDataFontScaleKey, 1.0);
    if (gDataFontScale < 0.6) gDataFontScale = 0.6;
    if (gDataFontScale > 1.8) gDataFontScale = 1.8;
    gDataFontWeight = sp_read_double(kDataFontWeightKey, 0.0);
    gDockMaxIcons = sp_read_double(@"soloPlusDockMaxIcons", 5.0);
    if (gDockMaxIcons < 5.0) gDockMaxIcons = 5.0;
    if (gDockMaxIcons > 8.0) gDockMaxIcons = 8.0;
    gCarouselFill = sp_read_bool(@"soloPlusCarouselFill", YES);
}

#pragma mark - 调用方镜像判定

static BOOL sp_caller_is_solo(void *ret) {
    Dl_info info;
    if (!dladdr(ret, &info) || !info.dli_fname) return NO;
    return strstr(info.dli_fname, "Solo.dylib") != NULL;
}

// 与 Solo 评估器同源的锁态读取（SBLockScreenManager isUILocked）。故意同源：
// 日志里才能对照"评估器以为的锁态"与"护栏看到的锁态"是否一致（调试报告(23)
// 行159/167 已实证 UI locked 与 device lock state 两层语义会错位）。
// 私有类无头文件，选择器全部走 objc_msgSend 直调。
static BOOL sp_device_ui_locked(void) {
    Class cls = objc_getClass("SBLockScreenManager");
    if (!cls) return NO;
    SEL shared = NSSelectorFromString(@"sharedInstance");
    if (![cls respondsToSelector:shared]) return NO;
    id mgr = ((id (*)(id, SEL))objc_msgSend)((id)cls, shared);
    if (!mgr || ![(id)mgr respondsToSelector:@selector(isUILocked)]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)((id)mgr, @selector(isUILocked)) ? YES : NO;
}

#pragma mark - 状态栏

static BOOL sp_window_is_home_context(UIWindow *window) {
    if (!window) return NO;
    NSString *cls = NSStringFromClass([window class]);
    // iOS 16.5 实测：主屏可见状态栏前景视图在 UIStatusBarWindow；锁屏/切换器
    // 还会出现 SBMainSwitcherWindow。17.2 上是 SBStatusBarWindow/SBHomeScreenWindow。
    // 注意：SBStatusBarReusePoolWindow 是 App 状态栏复用池，故意不加入。
    return [cls isEqualToString:@"SBStatusBarWindow"]
        || [cls isEqualToString:@"SBHomeScreenWindow"]
        || [cls isEqualToString:@"SBMainSwitcherWindow"]
        || [cls isEqualToString:@"UIStatusBarWindow"];
}

static BOOL sp_is_statusbar_foreground(UIView *view) {
    NSString *cls = NSStringFromClass([view class]);
    return [cls isEqualToString:@"_UIStatusBarForegroundView"]
        || [cls isEqualToString:@"STUIStatusBarForegroundView"];
}

// 锁屏/切换器语境（1.3.18）：NC 下拉时露出的栏可能在 SBCoverSheetWindow，
// 也可能在 SBMainSwitcherWindow（报告(27)：护栏保住了 CoverSheet 实例，
// 用户肉眼仍见右列消失——可见栏疑似切换器实例）。两处一律纳入护栏。
static BOOL sp_window_is_lock_context(UIWindow *window) {
    if (!window) return NO;
    NSString *cls = NSStringFromClass([window class]);
    return [cls isEqualToString:@"SBCoverSheetWindow"]
        || [cls isEqualToString:@"SBMainSwitcherWindow"];
}

static void sp_force_show_view(UIView *view) {
    if (!view) return;
    if (sp_is_statusbar_foreground(view)) {
        // 只恢复我们拦过的视图（gKeptViews）。绝不无差别 alpha=1：
        // 美化插件自己藏掉的原生状态栏不能被我们拉出来。
        if (gKeptViews && [gKeptViews containsObject:view] && view.alpha < 0.01f) {
            view.alpha = 1.0f;
            if (gForcedLogBudget > 0) {
                gForcedLogBudget--;
                sp_log(@"force show kept view: view=%@ superview=%@ win=%@",
                       NSStringFromClass([view class]),
                       NSStringFromClass([view.superview class]),
                       view.window ? NSStringFromClass([view.window class]) : @"(nil)");
            }
        }
        return; // 只处理状态栏前景视图，绝不改动其它 alpha=0 的 UI（例如被 Solo 隐藏的 Dock 背景）
    }
    for (UIView *sub in view.subviews) sp_force_show_view(sub);
}

static void sp_force_show_all(void) {
    if (!gKeepStatusBar) return;
    @autoreleasepool {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!sp_window_is_home_context(w)) continue;
            sp_force_show_view(w);
        }
    }
}

// 诊断：递归打印状态栏子树（类名/指针/frame/alpha/hidden/z 序/layer 级 hidden+mask），
// 限行数防刷屏。lh/mask（1.3.17）：layer.mask 非空 + alpha/hidden 全正常但不可见 =
// Lunora mask 所有权压制的直接证据（view 级字段看不见 mask）。
static void sp_sb_dump_node(UIView *v, int depth, int *remaining) {
    if (!v || *remaining <= 0 || depth > 6) return;
    (*remaining)--;
    NSUInteger z = v.superview ? [v.superview.subviews indexOfObjectIdenticalTo:v] : 0;
    sp_log(@"sbdump d%d %@ %p frame=%@ alpha=%.2f hidden=%d z=%lu lh=%d mask=%d",
           depth, NSStringFromClass([v class]), (__bridge void *)v,
           NSStringFromCGRect(v.frame), (double)v.alpha, v.isHidden ? 1 : 0,
           (unsigned long)z, v.layer.hidden ? 1 : 0, v.layer.mask ? 1 : 0);
    for (UIView *sub in v.subviews) sp_sb_dump_node(sub, depth + 1, remaining);
}

// 首次遇到“非 Solo 的压制”时调用：dump 该前景视图的 superview 子树 + 窗口子视图列表，
// 用于确定左右簇结构与美化条视图的位置/z 序。
static void sp_sb_dump_around(UIView *view) {
    if (gSbDumpBudget <= 0) return;
    gSbDumpBudget--;
    UIView *container = view.superview;
    UIWindow *win = view.window;
    sp_log(@"sbdump begin view=%p container=%@ win=%@",
           (__bridge void *)view,
           container ? NSStringFromClass([container class]) : @"(nil)",
           win ? NSStringFromClass([win class]) : @"(nil)");
    int remaining = 60;
    if (container) sp_sb_dump_node(container, 0, &remaining);
    if (win && remaining > 0) {
        for (UIView *sub in win.subviews) {
            if (remaining <= 0) break;
            remaining--;
            NSUInteger z = [win.subviews indexOfObjectIdenticalTo:sub];
            sp_log(@"sbdump win-child %@ %p frame=%@ alpha=%.2f hidden=%d z=%lu",
                   NSStringFromClass([sub class]), (__bridge void *)sub,
                   NSStringFromCGRect(sub.frame), (double)sub.alpha,
                   sub.isHidden ? 1 : 0, (unsigned long)z);
        }
    }
    sp_log(@"sbdump end (lines left %d)", remaining);
}

// 终态取证（1.3.17→1.3.18 双点）：attach 时刻 item 还没组装完（报告(26) L1109
// 零尺寸空壳），"闪现后被藏"只存在于终态；报告(27) +0.6s 采样一切可见但肉眼
// 仍见消失 → 追加 +2.5s 第二采样点（捕更晚到的压制），并加祖先链行（从栏向上
// 到窗口逐级 alpha/hidden/lh/mask，堵"上级视图被藏"盲区）。
// CFRunLoopTimer C 回调，零 block 字面量；每槽 weak 单持，后到覆盖先到。
static __weak UIView *gSbDumpLaterView[2] = {nil, nil};
static const double gSbDumpLaterDelay[2] = {0.6, 2.5};
static void sp_sb_dump_later_cb(CFRunLoopTimerRef timer, void *info) {
    CFRunLoopTimerInvalidate(timer);
    CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
    NSInteger slot = (NSInteger)(intptr_t)info;
    if (slot < 0 || slot > 1) return;
    UIView *view = gSbDumpLaterView[slot];
    gSbDumpLaterView[slot] = nil;
    if (!view || gSbDumpLaterBudget <= 0) return;
    gSbDumpLaterBudget--;
    UIWindow *win = view.window;
    sp_log(@"sbdump-later[%ld] begin view=%p win=%@ (end-state +%.1fs)",
           (long)slot, (__bridge void *)view,
           win ? NSStringFromClass([win class]) : @"(nil)", gSbDumpLaterDelay[slot]);
    UIView *anc = view.superview;
    int remaining = 60;
    while (anc && remaining > 0) {
        remaining--;
        sp_log(@"sbdump-up %@ %p frame=%@ alpha=%.2f hidden=%d lh=%d mask=%d",
               NSStringFromClass([anc class]), (__bridge void *)anc,
               NSStringFromCGRect(anc.frame), (double)anc.alpha,
               anc.isHidden ? 1 : 0, anc.layer.hidden ? 1 : 0,
               anc.layer.mask ? 1 : 0);
        if (anc == win) break;
        anc = anc.superview;
    }
    if (view.superview) sp_sb_dump_node(view.superview, 0, &remaining);
    if (win && remaining > 0) {
        for (UIView *sub in win.subviews) {
            if (remaining <= 0) break;
            remaining--;
            NSUInteger z = [win.subviews indexOfObjectIdenticalTo:sub];
            sp_log(@"sbdump-later win-child %@ %p frame=%@ alpha=%.2f hidden=%d z=%lu lh=%d mask=%d",
                   NSStringFromClass([sub class]), (__bridge void *)sub,
                   NSStringFromCGRect(sub.frame), (double)sub.alpha,
                   sub.isHidden ? 1 : 0, (unsigned long)z,
                   sub.layer.hidden ? 1 : 0, sub.layer.mask ? 1 : 0);
        }
    }
    sp_log(@"sbdump-later[%ld] end (lines left %d)", (long)slot, remaining);
}
static void sp_sb_schedule_dump_later(UIView *view) {
    if (gSbDumpLaterBudget <= 0) return; // 单点回调内各自再查预算，允许半轮取证
    for (int i = 0; i < 2; i++) {
        gSbDumpLaterView[i] = view;
        CFRunLoopTimerContext ctx = {0, (void *)(intptr_t)i, NULL, NULL, NULL};
        CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                                   CFAbsoluteTimeGetCurrent() + gSbDumpLaterDelay[i],
                                                   0, 0, 0, sp_sb_dump_later_cb, &ctx);
        if (t) CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
    }
}

static void (*sp_orig_setAlpha_ui)(id, SEL, CGFloat) = NULL;
static void (*sp_orig_setAlpha_st)(id, SEL, CGFloat) = NULL;

// ---- 主题状态栏共存（Lunora / LNV2 等）----
// Lunora 的结构（17.2 实测 dump）：STUIStatusBar 里 z0=LNV2OverlayView（玻璃胶囊，
// frame 即"美化区域声明"），z1=原生 STUIStatusBarForegroundView。它靠把原生前景视图
// alpha→0 露出胶囊，连带没启用胶囊的区域（左侧）也被藏掉。
// 共存规则（1.3.6）：覆盖层"存在"即算主题在场（Lunora 转场时会瞬时 hidden 自己的
// overlay 却继续压制原生条，可见性不能作判据）；整条保活交给 Solo，胶囊"有效可见"
// 时才让位，覆盖层藏掉期间整条原生条都听 Solo。
// 宽限期修正（1.3.9）：CC 收起窗口期改按"胶囊已声明"让位、不恢复整条（消原生右列
// 闪现），事件源=SBControlCenterController _didDismiss/_didEndTransition 四回调，
// 超时回退本规则。逆向依据：analysis/lunora-2b38/REPORT.md。
static char spSbYieldedKey = 0;      // 前景视图上记录被让位的子视图
static int gYieldLogBudget = 12;

// 前景视图同层里"非系统前缀"的覆盖层（LNV2OverlayView 等）。不看 hidden/alpha：
// Lunora 会瞬时藏 overlay 但压制不停，存在性才是稳定判据。
// 16.5 加固：跳过 MT（系统材质）等前缀，且覆盖层须横贯状态栏（≥60% 宽）——
// 防止旧 _UIStatusBar 里的系统辅助视图被误判成美化覆盖层。
static UIView *sp_theme_overlay_for(UIView *fgview) {
    UIView *parent = fgview.superview;
    if (!parent) return nil;
    CGFloat minW = fgview.frame.size.width * 0.6f;
    for (UIView *sib in parent.subviews) {
        if (sib == fgview) continue;
        NSString *cls = NSStringFromClass([sib class]);
        if ([cls hasPrefix:@"STUI"] || [cls hasPrefix:@"_UI"] ||
            [cls hasPrefix:@"UI"] || [cls hasPrefix:@"MT"]) continue;
        if (sib.frame.size.width > 1.0f && sib.frame.size.width >= minW) return sib;
    }
    return nil;
}

// 覆盖层此刻是否真的在显示胶囊：overlay 自身可见 + 至少一个可见、有实际 frame 的胶囊。
static BOOL sp_theme_capsules_effective(UIView *overlay) {
    if (!overlay || overlay.hidden || overlay.alpha < 0.01f) return NO;
    for (UIView *cap in overlay.subviews)
        if (!cap.hidden && cap.frame.size.width > 1.0f && cap.frame.size.height > 1.0f) return YES;
    return NO;
}

// ---- CC 收起宽限期（1.3.9 引入，1.3.10 加固）----
// Lunora 转场时序（逆向定案，analysis/lunora-2b38/REPORT.md）：_didDismiss 后它把
// ccReturnWaiting 置位、走 40ms 有界轮询等「姿态停稳」才重申压制（最坏 ~2s），
// 期间自己的 overlay 会瞬时 hidden 但胶囊 frame 仍在（声明态）。1.3.9 实测仍有闪切，
// 复盘出三个洞，1.3.10 全堵：
//   ① 新前景实例挂载早于 overlay 挂回条里 → sp_theme_overlay_for 返回 nil，
//      宽限分支没机会跑 → 改为「记忆 rect 让位」：成功让位时记住胶囊 rect，
//      overlay 缺失/声明失效时也照让；
//   ② 胶囊子视图可能被 Lunora 转场期隐藏 → 声明态收集不再跳过 hidden；
//   ③ 1.2s 宽限短于 Lunora 姿态等待 → 2.5s；另加「CC 收起兜底信号」（四回调钩
//      万一失效时用 CC 窗口条最近可见 + 主屏隐藏调用推断收起）。
static double gCcGraceUntil = 0.0;         // CACurrentMediaTime 截止；0=无宽限
static const double kCcGraceSeconds = 2.5; // Lunora 姿态等待 + 8×125ms 恢复，留足余量
static int gCcGraceLogBudget = 12;
static int gCcDiagLogBudget = 32;          // CC 窗口期专用诊断（独立于其它预算防耗尽）
static double gCcBarSeenAt = -1e9;         // 最近一次 CC 窗口条走显示路径的时刻（兜底信号源）
// 主题最近在场证据 + 最后一次成功让位的胶囊 rect（fgview 坐标系，跨实例几何一致）。
static double gThemeSeenAt = -1e9;
static CGRect gLastCapsRects[8];
static int gLastCapsCount = 0;
// 左胶囊在场标记（1.3.21）：最近一次主屏让位时 Lunora 左半区（x<195）胶囊有效。
// 锁屏语境左列归属的判定依据——用户优先级模型 Lunora > 电话助手 > 原生：
// 左胶囊启用时，锁屏左列随 Lunora（压制原生左列），不随还原回到原生。

static BOOL gThemeSeenRecent(void) {
    return CACurrentMediaTime() - gThemeSeenAt < 10.0;
}

// 覆盖层是否仍"声明"着胶囊：不看 overlay 可见性，只看胶囊 frame。
// Lunora 转场藏 overlay 时不清 frame（frame 即美化区域声明），转场结束后亮回。
static BOOL sp_theme_capsules_declared(UIView *overlay) {
    if (!overlay) return NO;
    for (UIView *cap in overlay.subviews)
        if (cap.frame.size.width > 1.0f && cap.frame.size.height > 1.0f) return YES;
    return NO;
}

static BOOL sp_cc_grace_active(void) {
    if (gCcGraceUntil <= 0.0) return NO;
    if (CACurrentMediaTime() >= gCcGraceUntil) { gCcGraceUntil = 0.0; return NO; }
    return YES;
}

// ---- 前台语境（1.3.12）：Lunora 同款钩 SpringBoard frontDisplayDidChange: ----
// 事件武装（四回调/兜底）实测永远赶不上收起转场中途的 attach（报告 17：SBStatusBarWindow
// 的 attach 全部 grace=0）。改为"桌面语境自证武装"：attach/hide/display 时只要
// 「无前台 App + 主题在场 + overlay 声明了胶囊」就当场开宽限并让位，不再依赖任何
// 事件先到。App 语境由 frontDisplay 硬保护（该钩触发过才启用，防版本漂移误伤）。
static BOOL gAppForeground = NO;    // frontDisplayDidChange 观测的前台 App 状态
static BOOL gFrontDisplaySeen = NO; // 该钩至少触发过一次才启用自证武装

// 桌面语境自证：就地武装宽限。顺带把主题在场证据保鲜（gThemeSeenAt 原先只在
// 胶囊真实生效时更新，CC 开久了会过期导致收起瞬间自证失败）。
static void sp_arm_grace_if_desktop(UIView *fgview, UIView *overlay) {
    if (!overlay || !sp_theme_capsules_declared(overlay)) return;
    gThemeSeenAt = CACurrentMediaTime();
    if (gCcGraceUntil > 0.0 && CACurrentMediaTime() < gCcGraceUntil) return;
    if (!gFrontDisplaySeen || gAppForeground) return;
    gCcGraceUntil = CACurrentMediaTime() + kCcGraceSeconds;
    if (gCcDiagLogBudget > 0) {
        gCcDiagLogBudget--;
        sp_log(@"cc diag: self-arm (desktop context, overlay=%@)",
               NSStringFromClass([overlay class]));
    }
}

// 把与可见胶囊重叠的原生内容子视图 alpha 压 0，并记录到关联对象。
// 胶囊当前"无效可见"（overlay 被藏）时不让位并恢复，避免右/左侧双空。
static void sp_restore_theme_yield(UIView *fgview); // 前向声明（下方定义）

// CC 收起宽限期的"记忆 rect 让位"：overlay 缺失（挂载早于 Lunora 挂回）或声明态
// 也拿不到时，用最近一次成功让位记住的胶囊 rect 继续 yield 右列。只在宽限内且
// 主题最近在场时生效（Lunora 真被禁用不会误让）。
static BOOL sp_grace_recall_yield(UIView *fgview) {
    if (!sp_cc_grace_active() || !gThemeSeenRecent() || gLastCapsCount == 0) return NO;
    NSMutableArray *yielded = objc_getAssociatedObject(fgview, &spSbYieldedKey)
                              ?: [NSMutableArray array];
    BOOL changed = NO;
    for (UIView *sub in fgview.subviews) {
        if (sub.hidden || sub.alpha < 0.01f) continue;
        if ([yielded containsObject:sub]) continue;
        BOOL hit = NO;
        for (int i = 0; i < gLastCapsCount; i++)
            if (CGRectIntersectsRect(sub.frame, gLastCapsRects[i])) { hit = YES; break; }
        if (!hit) continue;
        sub.alpha = 0.0f;
        [yielded addObject:sub];
        changed = YES;
    }
    if (changed || yielded.count)
        objc_setAssociatedObject(fgview, &spSbYieldedKey, yielded,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (changed && gCcDiagLogBudget > 0) {
        gCcDiagLogBudget--;
        sp_log(@"cc diag: recall yield %lu sub(s) (overlay absent/undeclared, theme %.1fs ago)",
               (unsigned long)yielded.count, CACurrentMediaTime() - gThemeSeenAt);
    }
    return YES;
}

static void sp_apply_theme_yield(UIView *fgview, UIView *overlay) {
    // 锁定期间不让位（1.3.19），且只收回右半区（1.3.21）：左簇保持让位态。
    if (sp_device_ui_locked()) {
        NSMutableArray *yielded = objc_getAssociatedObject(fgview, &spSbYieldedKey);
        for (UIView *sub in yielded) {
            if (sub.frame.origin.x >= 195.0f && sub.alpha < 0.01f) sub.alpha = 1.0f;
        }
        return;
    }
    BOOL effective = sp_theme_capsules_effective(overlay);
    BOOL graceDeclared = NO;
    if (!effective) {
        if (sp_cc_grace_active() && sp_theme_capsules_declared(overlay)) {
            // CC 收起宽限期：胶囊尚不可见但 frame 仍声明 → 保持让位，不恢复整条。
            graceDeclared = YES;
            if (gCcGraceLogBudget > 0) {
                gCcGraceLogBudget--;
                sp_log(@"cc grace: yield by declared capsules (overlay=%@)",
                       NSStringFromClass([overlay class]));
            }
        } else if (sp_cc_grace_active() && gThemeSeenRecent() && gLastCapsCount > 0) {
            // 声明态也拿不到（转场期胶囊被藏/frame 被清）→ 记忆 rect 让位。
            if (gCcDiagLogBudget > 0) {
                gCcDiagLogBudget--;
                sp_log(@"cc diag: declared missing on %@, recall",
                       NSStringFromClass([overlay class]));
            }
            if (!sp_grace_recall_yield(fgview)) sp_restore_theme_yield(fgview);
            return;
        } else {
            sp_restore_theme_yield(fgview);
            return;
        }
    }
    NSMutableArray *caps = [NSMutableArray array];
    for (UIView *cap in overlay.subviews) {
        // 宽限声明态不跳过 hidden：Lunora 转场可能整链隐藏，frame 才是有效声明。
        if (!graceDeclared && cap.hidden) continue;
        if (cap.frame.size.width < 1.0f || cap.frame.size.height < 1.0f) continue;
        [caps addObject:[NSValue valueWithCGRect:[fgview convertRect:cap.frame fromView:overlay]]];
    }
    if (caps.count == 0) return;
    // 记录主题在场证据与胶囊 rect（记忆让位与兜底信号的依据）。
    gThemeSeenAt = CACurrentMediaTime();
    int n = 0;
    for (NSValue *v in caps) {
        if (n >= 8) break;
        gLastCapsRects[n++] = [v CGRectValue];
    }
    gLastCapsCount = n;
    NSMutableArray *yielded = objc_getAssociatedObject(fgview, &spSbYieldedKey)
                              ?: [NSMutableArray array];
    BOOL changed = NO;
    for (UIView *sub in fgview.subviews) {
        if (sub.hidden || sub.alpha < 0.01f) continue;
        BOOL hit = NO;
        for (NSValue *v in caps)
            if (CGRectIntersectsRect(sub.frame, [v CGRectValue])) { hit = YES; break; }
        if (!hit) continue;
        sub.alpha = 0.0f;
        [yielded addObject:sub];
        changed = YES;
        if (gYieldLogBudget > 0) {
            gYieldLogBudget--;
            sp_log(@"sb yield: %@ %@ -> alpha0 (theme=%@)",
                   NSStringFromClass([sub class]), NSStringFromCGRect(sub.frame),
                   NSStringFromClass([overlay class]));
        }
    }
    if (changed || yielded.count)
        objc_setAssociatedObject(fgview, &spSbYieldedKey, yielded,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// 覆盖层不可见 / 离开主屏：恢复被让位的子视图（App 内状态栏要完整）。
static void sp_restore_theme_yield(UIView *fgview) {
    NSMutableArray *yielded = objc_getAssociatedObject(fgview, &spSbYieldedKey);
    if (!yielded.count) return;
    NSUInteger n = 0;
    for (UIView *sub in yielded)
        if (!sub.hidden && sub.alpha < 0.01f) { sub.alpha = 1.0f; n++; }
    objc_setAssociatedObject(fgview, &spSbYieldedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gYieldLogBudget > 0) {
        gYieldLogBudget--;
        sp_log(@"sb yield restore: %lu subview(s) on %@",
               (unsigned long)n, NSStringFromClass([fgview class]));
    }
}

// 锁屏还原语境判定（1.3.19）：CoverSheet 恒为还原语境；MainSwitcher/StatusBarWindow
// 仅在 UI 锁定时算（解锁状态下它们承载主屏/切换器样式，还原会砸掉 Lunora 胶囊态）。
static BOOL sp_should_restore_lock_bar(UIWindow *win) {
    if (!win) return NO;
    NSString *cls = NSStringFromClass([win class]);
    if ([cls isEqualToString:@"SBCoverSheetWindow"]) return YES;
    if ([cls isEqualToString:@"SBMainSwitcherWindow"]
        || [cls isEqualToString:@"SBStatusBarWindow"]) {
        return sp_device_ui_locked() ? YES : NO;
    }
    return NO;
}

// 左胶囊"锁屏可见"活检测（1.3.25）：本实例 overlay 上是否存在有效左胶囊
// （可见、有实际尺寸、落在左半区）。锁屏可见=ON 时 Lunora 会在锁屏实例的
// overlay 上挂真 frame 胶囊；OFF 时是零尺寸隐藏壳（历次 dump 一致）。
static BOOL sp_theme_has_left_capsule(UIView *fgview) {
    UIView *overlay = sp_theme_overlay_for(fgview);
    if (!overlay) return NO;
    for (UIView *cap in overlay.subviews) {
        if (![NSStringFromClass([cap class]) hasPrefix:@"LNV2"]) continue;
        if (cap.hidden || cap.frame.size.width < 1.0f || cap.frame.size.height < 1.0f) continue;
        CGRect r = [fgview convertRect:cap.frame fromView:overlay];
        if (r.origin.x < 195.0f) return YES;
    }
    return NO;
}

// 左半区第三方内容视图在场检测（1.3.25）：电话助手"锁屏可见"替换态的标志。
// 特征 = 类名首字母小写（混淆类名，如 tZBkQAHVLGPTQwXC；系统/Lunora 类均大写
// 开头）、左半区、可见、有实际尺寸。在场 → 左列归它管，我们不还原（避免
// 1.3.19 的叠放回归）。
static BOOL sp_left_has_foreign_content(UIView *fgview) {
    for (UIView *sub in fgview.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if (cls.length == 0) continue;
        unichar c = [cls characterAtIndex:0];
        if ([[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:c]) continue;
        if (sub.frame.origin.x < 195.0f && !sub.hidden && sub.alpha > 0.01f
            && sub.frame.size.width >= 1.0f && sub.frame.size.height >= 1.0f) return YES;
    }
    return NO;
}

// 锁屏栏还原（1.3.25，原右簇还原扩展为左右双簇）：锁屏栏实例携带的是"锁屏前
// 语境"的样式。右簇恒还原（x≥195：hidden/lh/alpha，1.3.19/1.3.20 语义不变）；
// 左簇活跟随胶囊"锁屏可见"——本实例 overlay 有有效左胶囊 → 压制原生左列
// （胶囊替换语义，优先级 Lunora 最高）；无左胶囊且无第三方内容在场 → 还原
// 原生左列（含电话助手未替换时的默认态）；有第三方内容在场（电话助手替换态）
// → 不碰左列。解锁回主屏后让位机制在下一次 show/layout 重新套用，自愈。
// 不碰 LNV2*；UIVectorLabel 是合法备选渲染（嵌在 item 内部，不动）。
static void sp_restore_lock_bar(UIView *fgview) {
    if (!fgview) return;
    BOOL leftCaps = sp_theme_has_left_capsule(fgview);
    BOOL leftForeign = leftCaps ? NO : sp_left_has_foreign_content(fgview);
    int nr = 0, nl = 0;
    for (UIView *sub in fgview.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls hasPrefix:@"LNV2"]) continue;
        BOOL isRight = (sub.frame.origin.x >= 195.0f);
        BOOL isLeft = !isRight;
        BOOL changed = NO;
        if ([cls hasPrefix:@"STUIStatusBar"]
            || [cls isEqualToString:@"UIView"]
            || [cls isEqualToString:@"_UILumaTrackingBackdropView"]) {
            if (isRight) {
                if (sub.hidden || sub.layer.hidden) {
                    sub.hidden = NO;
                    sub.layer.hidden = NO;
                    changed = YES;
                }
                if (sub.alpha < 0.01f) { sub.alpha = 1.0f; changed = YES; }
            } else if (leftCaps) {
                // 胶囊锁屏可见：压制原生左列（胶囊替换语义）
                if (sub.alpha > 0.01f) { sub.alpha = 0.0f; changed = YES; }
            } else if (!leftForeign) {
                // 无胶囊无第三方：还原原生左列
                if (sub.hidden || sub.layer.hidden) {
                    sub.hidden = NO;
                    sub.layer.hidden = NO;
                    changed = YES;
                }
                if (sub.alpha < 0.01f) { sub.alpha = 1.0f; changed = YES; }
            }
        }
        if (changed) {
            if (isRight) nr++; else nl++;
        }
    }
    if ((nr > 0 || nl > 0) && gLockGuardLogBudget > 0) {
        gLockGuardLogBudget--;
        sp_log(@"lock restore: right=%d left=%d (%s) on %@",
               nr, nl,
               leftCaps ? "capsule" : (leftForeign ? "foreign" : "native"),
               fgview.window ? NSStringFromClass([fgview.window class]) : @"(nil)");
    }
}

// ---- 挂载/布局时机同步（修 CC→主屏的识别闪切）----
// CC 关闭回主屏时系统会新建前景视图实例（默认整条可见），Lunora 的压制稍后才到，
// 中间窗口期就是"原生右列 ↔ 胶囊"的闪切。在 didMoveToWindow 就同步让位状态，
// layoutSubviews 单向重申（只让位不恢复，避免 overlay 瞬藏窗口期引起内容抖动）。
static void sp_sb_sync_on_attach(UIView *view) {
    UIWindow *win = view.window;
    // 锁屏取证（1.3.16→1.3.18）：锁屏/切换器语境的前景视图 attach 时 dump 子树 +
    // 终态双点（0.6s/2.5s），放在 keepStatusBar 门控之前，两种开关模式下都取证。
    if (win && sp_window_is_lock_context(win)) {
        sp_sb_dump_around(view);
        sp_sb_schedule_dump_later(view);
        if (sp_should_restore_lock_bar(win)) sp_restore_lock_bar(view);
    }
    if (!gKeepStatusBar) return;
    if (!win || !sp_window_is_home_context(win)) {
        sp_restore_theme_yield(view);
        return;
    }
    UIView *overlay = sp_theme_overlay_for(view);
    // 桌面语境自证武装（1.3.12）：attach 就地开宽限，收起转场中途的实例也能
    // 首渲染前让位——不再依赖任何事件信号先到。
    sp_arm_grace_if_desktop(view, overlay);
    BOOL grace = sp_cc_grace_active();
    // 主题在场就打印（不只宽限内）：收起转场中途的 attach 是否赶在宽限武装之前，
    // 只有靠它才能看见（1.3.10 实测教训）。
    if ((grace || gThemeSeenRecent()) && gCcDiagLogBudget > 0) {
        gCcDiagLogBudget--;
        sp_log(@"cc diag: attach win=%@ overlay=%@ caps=%d grace=%d",
               NSStringFromClass([win class]),
               overlay ? NSStringFromClass([overlay class]) : @"(nil)",
               overlay ? (sp_theme_capsules_declared(overlay) ? 1 : 0) : -1,
               grace ? 1 : 0);
    }
    // 统一走 apply：胶囊有效 → 让位；无效 → 宽限期内按声明/记忆 rect 让位，否则恢复。
    if (overlay) {
        sp_apply_theme_yield(view, overlay);
    } else if (!sp_grace_recall_yield(view)) {
        sp_restore_theme_yield(view);
    }
}

static void sp_sb_assert_on_layout(UIView *view) {
    UIWindow *win = view.window;
    // 锁屏语境右簇还原（1.3.19）：layoutSubviews 单向重申，独立于保留系统栏开关
    // （Lunora 引擎会重申压制，这里每次布局对打回去）。
    if (win && sp_should_restore_lock_bar(win)) {
        sp_restore_lock_bar(view);
        return;
    }
    if (!gKeepStatusBar) return;
    if (!win || !sp_window_is_home_context(win)) return;
    UIView *overlay = sp_theme_overlay_for(view);
    if (overlay) {
        sp_arm_grace_if_desktop(view, overlay);
        if (sp_theme_capsules_effective(overlay) ||
            (sp_cc_grace_active() && sp_theme_capsules_declared(overlay))) {
            sp_apply_theme_yield(view, overlay);
        } else {
            // 覆盖层在但胶囊失效（Lunora 关闭/瞬藏且宽限不在）：收回让位，
            // 原生回归——修"关闭 Lunora 后右列不显示"的滞留态（1.3.22）。
            // 此前该分支什么都不做，alpha=0 滞留到下一次有效胶囊才被处理。
            sp_restore_theme_yield(view);
        }
    } else if (gThemeSeenRecent() && objc_getAssociatedObject(view, &spSbYieldedKey)) {
        // overlay 暂不可得：宽限内持续记忆让位（补后到的子视图）；宽限过期恢复原生。
        if (sp_cc_grace_active()) sp_grace_recall_yield(view);
        else sp_restore_theme_yield(view);
    }
}

static void (*sp_orig_didMove_ui)(id, SEL) = NULL;
static void (*sp_orig_didMove_st)(id, SEL) = NULL;
static void (*sp_orig_layout_ui)(id, SEL) = NULL;
static void (*sp_orig_layout_st)(id, SEL) = NULL;

static void sp_fg_didMove_ui(id self, SEL _cmd) {
    if (sp_orig_didMove_ui) sp_orig_didMove_ui(self, _cmd);
    sp_sb_sync_on_attach((UIView *)self);
}
static void sp_fg_didMove_st(id self, SEL _cmd) {
    if (sp_orig_didMove_st) sp_orig_didMove_st(self, _cmd);
    sp_sb_sync_on_attach((UIView *)self);
}
static void sp_fg_layout_ui(id self, SEL _cmd) {
    if (sp_orig_layout_ui) sp_orig_layout_ui(self, _cmd);
    sp_sb_assert_on_layout((UIView *)self);
}
static void sp_fg_layout_st(id self, SEL _cmd) {
    if (sp_orig_layout_st) sp_orig_layout_st(self, _cmd);
    sp_sb_assert_on_layout((UIView *)self);
}

static void sp_common_set_alpha(id self, SEL _cmd, CGFloat alpha,
                                void (*orig)(id, SEL, CGFloat), void *caller) {
    if (!orig) return;
    UIView *view = (UIView *)self;
    UIWindow *win = view.window;

    // 主题覆盖层"存在"即算接管候选（不看可见性），胶囊"有效可见"才让位。
    UIView *overlay = sp_theme_overlay_for(view);
    BOOL capsOn = sp_theme_capsules_effective(overlay);

    // 显示路径（alpha>=0.01）：主屏且主题在场 → 让位；CC 窗口条可见记兜底信号；
    // 宽限期内 overlay 未挂回也按记忆 rect 让位（消 CC 收起闪切）。
    if (alpha >= 0.01f) {
        if (win) {
            NSString *wcls = NSStringFromClass([win class]);
            if ([wcls isEqualToString:@"SBControlCenterWindow"]) {
                gCcBarSeenAt = CACurrentMediaTime();
            }
        }
        if (sp_window_is_home_context(win) && overlay) {
            sp_arm_grace_if_desktop(view, overlay);
            sp_apply_theme_yield(view, overlay);
        } else if (sp_window_is_home_context(win) && !overlay &&
                   sp_cc_grace_active() && gThemeSeenRecent()) {
            sp_grace_recall_yield(view);
        } else {
            sp_restore_theme_yield(view);
        }
        orig(self, _cmd, alpha);
        return;
    }

    // 锁屏护栏（1.3.22 收口）：只在"锁屏还原语境"整条保活——CoverSheet 恒定；
    // MainSwitcher/StatusBarWindow 仅 UI 锁定时。解锁状态的 MainSwitcher 属主屏
    // 语境，Lunora 的主屏样式（整条压暗+胶囊悬浮）必须按主屏规则处理——1.3.18
    // 的无条件覆盖把它拦死（报告(6) L487-496 ×10 实证）。护栏与还原共用
    // sp_should_restore_lock_bar 同一语境判定。
    if (win && sp_should_restore_lock_bar(win)) {
        if (!gKeptViews) gKeptViews = [NSHashTable weakObjectsHashTable];
        [gKeptViews addObject:view];
        if (gLockGuardLogBudget > 0) {
            gLockGuardLogBudget--;
            sp_log(@"lock guard: kept hide view=%@ %p win=%@ caller=%s uiLocked=%d",
                   NSStringFromClass([view class]), (__bridge void *)view,
                   NSStringFromClass([win class]),
                   sp_caller_is_solo(caller) ? "solo" : "other",
                   sp_device_ui_locked() ? 1 : 0);
        }
        orig(self, _cmd, 1.0f);
        if (sp_should_restore_lock_bar(win)) sp_restore_lock_bar(view);
        return;
    }

    if (!gKeepStatusBar) {
        orig(self, _cmd, alpha);
        return;
    }

    BOOL fromSolo = sp_caller_is_solo(caller);
    BOOL home = sp_window_is_home_context(win);

    if (!home) {
        // 非主屏上下文（控制中心/锁屏/App）：交给系统与主题，顺手恢复让位。
        // CC 窗口条的隐藏也是 CC 活动证据（刷新兜底信号的时间锚）。
        if (win) {
            NSString *wcls = NSStringFromClass([win class]);
            if ([wcls isEqualToString:@"SBControlCenterWindow"]) {
                gCcBarSeenAt = CACurrentMediaTime();
            }
        }
        sp_restore_theme_yield(view);
        orig(self, _cmd, alpha);
        return;
    }

    // 桌面语境自证武装（1.3.12）：收起时对既有实例的隐藏调用也当场开宽限。
    sp_arm_grace_if_desktop(view, overlay);

    // CC 收起兜底信号（1.3.10）：四回调钩万一没装上/签名漂移时，用「CC 窗口条
    // 最近走过显示路径 + 主屏出现隐藏调用 + 主题最近在场」推断 CC 刚收起，照样开宽限。
    double nowCc = CACurrentMediaTime();
    if (home && nowCc - gCcBarSeenAt < 3.0 && gThemeSeenRecent() && gCcGraceUntil < nowCc) {
        gCcGraceUntil = nowCc + kCcGraceSeconds;
        if (gCcDiagLogBudget > 0) {
            gCcDiagLogBudget--;
            sp_log(@"cc grace: fallback arm (cc bar %.1fs ago, caller=%s)",
                   nowCc - gCcBarSeenAt, fromSolo ? "solo" : "other");
        }
    }

    if (overlay) {
        // 主题接管中：整条保活。胶囊有效 → 让位（未美化区域可见、美化区域让位）；
        // 胶囊无效（overlay 被藏）→ 恢复让位，整条都听 Solo。
        if (!gKeptViews) gKeptViews = [NSHashTable weakObjectsHashTable];
        [gKeptViews addObject:view];
        if (gBlockedLogBudget > 0) {
            gBlockedLogBudget--;
            sp_log(@"blocked statusbar hide: view=%@ %p win=%@ caller=%s theme=%@ caps=%d",
                   NSStringFromClass([view class]), (__bridge void *)view,
                   win ? NSStringFromClass([win class]) : @"(nil)",
                   fromSolo ? "solo" : "other",
                   NSStringFromClass([overlay class]), capsOn ? 1 : 0);
        }
        orig(self, _cmd, 1.0f);
        sp_apply_theme_yield(view, overlay);
        return;
    }

    if (fromSolo) {
        // 无主题覆盖：整条保活（iOS 16.5 / 无美化 17.2 的既有行为）。
        if (!gKeptViews) gKeptViews = [NSHashTable weakObjectsHashTable];
        [gKeptViews addObject:view];
        if (gBlockedLogBudget > 0) {
            gBlockedLogBudget--;
            sp_log(@"blocked statusbar hide: view=%@ %p superview=%@ win=%@ caller=solo",
                   NSStringFromClass([view class]), (__bridge void *)view,
                   NSStringFromClass([view.superview class]),
                   win ? NSStringFromClass([win class]) : @"(nil)");
        }
        orig(self, _cmd, 1.0f);
        if (sp_cc_grace_active() && gThemeSeenRecent()) sp_grace_recall_yield(view);
        return;
    }

    if (sp_cc_grace_active() && gThemeSeenRecent()) {
        // CC 收起窗口期 overlay 尚未挂回：主题插件的压制调用先拦住，记忆 rect 让位，
        // 避免"放行隐藏 → Solo 再拉回"的整条抖动。
        if (!gKeptViews) gKeptViews = [NSHashTable weakObjectsHashTable];
        [gKeptViews addObject:view];
        orig(self, _cmd, 1.0f);
        sp_grace_recall_yield(view);
        return;
    }

    // caller=other 且主屏无主题覆盖：keep=1 语义下整条保活（1.3.23）。
    // 此前放行（当作"系统自身行为"）——但 Lunora 关闭后其引擎仍在压暗
    // （overlay 已消失、主题判定失效），放行 = 主屏原生栏被隐藏且无状态栏
    // 可看（报告(8) L160/260/401 实证）。keep=1 的语义就是主屏原生栏不隐藏；
    // keep=0 到不了这里（更早已放行归 Solo）。
    if (!gKeptViews) gKeptViews = [NSHashTable weakObjectsHashTable];
    [gKeptViews addObject:view];
    if (gUnmatchedStatusLogBudget > 0) {
        gUnmatchedStatusLogBudget--;
        sp_log(@"blocked statusbar hide: view=%@ %p win=%@ caller=%s (no theme, keep=1)",
               NSStringFromClass([view class]), (__bridge void *)view,
               win ? NSStringFromClass([win class]) : @"(nil)",
               fromSolo ? "solo" : "other");
    }
    sp_sb_dump_around(view);
    orig(self, _cmd, 1.0f);
}

static void sp_setAlpha_ui(id self, SEL _cmd, CGFloat alpha) {
    sp_common_set_alpha(self, _cmd, alpha, sp_orig_setAlpha_ui, __builtin_return_address(0));
}
static void sp_setAlpha_st(id self, SEL _cmd, CGFloat alpha) {
    sp_common_set_alpha(self, _cmd, alpha, sp_orig_setAlpha_st, __builtin_return_address(0));
}

// 诊断：检查两个类的 setAlpha: 顶层 IMP 是否仍是我们的钩子。若美化插件同样
// hook 且排在我们上面，caller 归因会全部变成 other（蹦床效应）。
static void sp_probe_status_hook_ownership(void) {
    SEL sel = @selector(setAlpha:);
    Class ui = objc_getClass("_UIStatusBarForegroundView");
    Class st = objc_getClass("STUIStatusBarForegroundView");
    if (ui) {
        Method m = class_getInstanceMethod(ui, sel);
        IMP imp = m ? method_getImplementation(m) : NULL;
        sp_log(@"sbhook ownership: _UIStatusBarForegroundView top=%s",
               (imp == (IMP)sp_setAlpha_ui) ? "ours" : "other");
    }
    if (st) {
        Method m = class_getInstanceMethod(st, sel);
        IMP imp = m ? method_getImplementation(m) : NULL;
        sp_log(@"sbhook ownership: STUIStatusBarForegroundView top=%s",
               (imp == (IMP)sp_setAlpha_st) ? "ours" : "other");
    }
}

static void sp_ownership_reprobe_cb(CFRunLoopTimerRef timer, void *info) {
    sp_probe_status_hook_ownership();
    CFRunLoopTimerInvalidate(timer);
    CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
    CFRelease(timer);
}

static void sp_schedule_ownership_reprobe(void) {
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                               CFAbsoluteTimeGetCurrent() + 5.0,
                                               0, 0, 0, sp_ownership_reprobe_cb, &ctx);
    if (t) CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
}

// ---- CC 收起事件（1.3.9）：与 Lunora 同款钩 SBControlCenterController 四回调 ----
// 进入（_willPresent/_willBeginTransition）：先转发后清宽限；退出（_didEndTransition/
// _didDismiss）：先转发后开宽限。两插件在同一选择器上各挂一层互不影响（都会被调），
// 这是从 alpha 风暴里猜"CC 收起了没"拿不到的确定性信号。
static void (*sp_orig_cc_present)(id, SEL) = NULL;
static void (*sp_orig_cc_begin_transition)(id, SEL) = NULL;
static void (*sp_orig_cc_end_transition)(id, SEL) = NULL;
static void (*sp_orig_cc_dismiss)(id, SEL) = NULL;

static void sp_cc_will_present(id self, SEL _cmd) {
    if (sp_orig_cc_present) sp_orig_cc_present(self, _cmd);
    gCcGraceUntil = 0.0; // CC 打开：退出宽限（宽限只服务收起）
}
static void sp_cc_will_begin_transition(id self, SEL _cmd) {
    if (sp_orig_cc_begin_transition) sp_orig_cc_begin_transition(self, _cmd);
    // 转场开始（打开/收起都可能）：先武装宽限。打开方向随后 _willPresent 会清；
    // 收起方向必须在这里就有宽限——收起转场中途系统就重建桌面条实例，等到
    // _didEndTransition/_didDismiss 才武装就晚了一个转场（1.3.10 实测闪切根因）。
    gCcGraceUntil = CACurrentMediaTime() + kCcGraceSeconds;
}
static void sp_cc_did_end_transition(id self, SEL _cmd) {
    if (sp_orig_cc_end_transition) sp_orig_cc_end_transition(self, _cmd);
    gCcGraceUntil = CACurrentMediaTime() + kCcGraceSeconds;
    if (gCcGraceLogBudget > 0) {
        gCcGraceLogBudget--;
        sp_log(@"cc grace: start %.1fs (didEndTransition)", kCcGraceSeconds);
    }
}
static void sp_cc_did_dismiss(id self, SEL _cmd) {
    if (sp_orig_cc_dismiss) sp_orig_cc_dismiss(self, _cmd);
    gCcGraceUntil = CACurrentMediaTime() + kCcGraceSeconds;
    if (gCcGraceLogBudget > 0) {
        gCcGraceLogBudget--;
        sp_log(@"cc grace: start %.1fs (didDismiss)", kCcGraceSeconds);
    }
}

// 前台语境（1.3.12）：Lunora 同款钩 SpringBoard frontDisplayDidChange:。
// 只判 nil 与非 nil（App 前台 vs 桌面/CC），不解参数类型，避开版本 ABI 漂移。
static void (*sp_orig_front_display)(id, SEL, id) = NULL;

static void sp_front_display_did_change(id self, SEL _cmd, id display) {
    if (sp_orig_front_display) sp_orig_front_display(self, _cmd, display);
    if (!gFrontDisplaySeen) {
        gFrontDisplaySeen = YES;
        if (gCcDiagLogBudget > 0) {
            gCcDiagLogBudget--;
            sp_log(@"cc diag: frontDisplay hook verified");
        }
    }
    BOOL app = (display != nil);
    if (app != gAppForeground) {
        gAppForeground = app;
        if (app) gCcGraceUntil = 0.0; // 进 App：立即退出让位语境，状态栏完整
        if (gCcDiagLogBudget > 0) {
            gCcDiagLogBudget--;
            sp_log(@"cc diag: frontDisplay -> %@", app ? @"app" : @"home");
        }
    }
}

static BOOL sp_cc_selector_ok_arity(Class cls, NSString *name, int wantArgs) {
    if (!cls || name.length == 0) return NO;
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != wantArgs) return NO;
    char ret[4] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == 'v';
}

// ABI 守卫：实例方法存在、2 参（self+_cmd）、返回 void——仿 Lunora 对同一批回调的
// 校验；系统签名漂移时宁可不安钩（漂移只会退回 1.3.6 行为，不会崩溃）。
static BOOL sp_cc_selector_ok(Class cls, NSString *name) {
    if (!cls || name.length == 0) return NO;
    SEL sel = NSSelectorFromString(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    if (method_getNumberOfArguments(m) != 2) return NO;
    char ret[4] = {0};
    method_getReturnType(m, ret, sizeof(ret));
    return ret[0] == 'v';
}

static BOOL gCcHooksInstalled = NO;

static void sp_install_cc_hooks(void) {
    if (gCcHooksInstalled) return;
    int n = 0;
    Class cc = objc_getClass("SBControlCenterController");
    if (cc) {
        if (sp_cc_selector_ok(cc, @"_didDismiss")) {
            MSHookMessageEx(cc, NSSelectorFromString(@"_didDismiss"),
                            (IMP)sp_cc_did_dismiss, (IMP *)&sp_orig_cc_dismiss);
            n++;
        }
        if (sp_cc_selector_ok(cc, @"_didEndTransition")) {
            MSHookMessageEx(cc, NSSelectorFromString(@"_didEndTransition"),
                            (IMP)sp_cc_did_end_transition, (IMP *)&sp_orig_cc_end_transition);
            n++;
        }
        if (sp_cc_selector_ok(cc, @"_willPresent")) {
            MSHookMessageEx(cc, NSSelectorFromString(@"_willPresent"),
                            (IMP)sp_cc_will_present, (IMP *)&sp_orig_cc_present);
            n++;
        }
        if (sp_cc_selector_ok(cc, @"_willBeginTransition")) {
            MSHookMessageEx(cc, NSSelectorFromString(@"_willBeginTransition"),
                            (IMP)sp_cc_will_begin_transition, (IMP *)&sp_orig_cc_begin_transition);
            n++;
        }
    }
    // 前台语境钩独立安装（CC 类缺失也不影响自证武装）。
    int front = 0;
    Class sb = objc_getClass("SpringBoard");
    if (sb && sp_cc_selector_ok_arity(sb, @"frontDisplayDidChange:", 3)) {
        MSHookMessageEx(sb, NSSelectorFromString(@"frontDisplayDidChange:"),
                        (IMP)sp_front_display_did_change, (IMP *)&sp_orig_front_display);
        front = 1;
    }
    if (n > 0 || front) {
        gCcHooksInstalled = YES;
        sp_log(@"cc hooks: cc=%d frontDisplay=%d", n, front);
    }
}

static BOOL gStatusHooksInstalled = NO;

static void sp_install_status_hooks(void) {
    sp_install_cc_hooks();
    if (gStatusHooksInstalled) return;
    SEL sel = @selector(setAlpha:);
    SEL dmw = @selector(didMoveToWindow);
    SEL lay = @selector(layoutSubviews);
    Class ui = objc_getClass("_UIStatusBarForegroundView");
    Class st = objc_getClass("STUIStatusBarForegroundView");
    BOOL any = NO;
    if (ui) {
        MSHookMessageEx(ui, sel, (IMP)sp_setAlpha_ui, (IMP *)&sp_orig_setAlpha_ui);
        MSHookMessageEx(ui, dmw, (IMP)sp_fg_didMove_ui, (IMP *)&sp_orig_didMove_ui);
        MSHookMessageEx(ui, lay, (IMP)sp_fg_layout_ui, (IMP *)&sp_orig_layout_ui);
        any = YES;
    }
    if (st) {
        MSHookMessageEx(st, sel, (IMP)sp_setAlpha_st, (IMP *)&sp_orig_setAlpha_st);
        MSHookMessageEx(st, dmw, (IMP)sp_fg_didMove_st, (IMP *)&sp_orig_didMove_st);
        MSHookMessageEx(st, lay, (IMP)sp_fg_layout_st, (IMP *)&sp_orig_layout_st);
        any = YES;
    }
    gStatusHooksInstalled = any;
    if (any) {
        sp_log(@"statusbar hooks installed");
        sp_probe_status_hook_ownership();
        sp_schedule_ownership_reprobe();
    }
}

static void sp_status_retry_cb(CFRunLoopTimerRef timer, void *info) {
    sp_install_status_hooks();
    if (gStatusHooksInstalled) {
        CFRunLoopTimerInvalidate(timer);
        CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
        CFRelease(timer);
        sp_load_prefs();
        sp_force_show_all();
    }
}

static void sp_schedule_status_retry(void) {
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                               CFAbsoluteTimeGetCurrent() + 1.5,
                                               1.0, 0, 0, sp_status_retry_cb, &ctx);
    if (t) CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
}


#pragma mark - Dock（图标上限；大小/间距/位移由第三方插件 Atria 等调节）

static char spModelLocationKey = 0;
static __weak id gDockListView = nil;
static __weak id gDockModel = nil;   // 直接记住 Dock model：列表视图重建/转场时仍可判身份
static int gDockModelLogBudget = 4;

static NSUInteger sp_dock_icon_count(id listView) {
    if (!listView || ![listView respondsToSelector:@selector(icons)]) return 0;
    id icons = ((id (*)(id, SEL))objc_msgSend)(listView, @selector(icons));
    if (!icons || ![icons respondsToSelector:@selector(count)]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(icons, @selector(count));
}

static void sp_mark_model_location(id model, NSString *loc) {
    if (!model || ![loc isKindOfClass:[NSString class]]) return;
    id old = objc_getAssociatedObject(model, &spModelLocationKey);
    if ([old isKindOfClass:[NSString class]] && [old isEqualToString:loc]) return;
    objc_setAssociatedObject(model, &spModelLocationKey, [loc copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id sp_dock_model(void) {
    // gDockModel 由 sp_note_dock_list() 在每次 Dock 布局钩子（maximumIconCount /
    // iconRows/layoutIconsNow/layoutSubviews）里刷新，Dock 有任何活动即已就绪。
    // 不在这里扫窗口：残旧的 Dock 列表视图若被扫到，反而会拿到过期 model。
    return gDockModel;
}

static BOOL sp_model_is_dock(id model) {
    // 严格指针身份：只认 gDockModel 记住的那一枚 Dock model。
    // 旧的 location 回落会误判文件夹内部 model（Atria 的 _atriaLocation 可能含
    // "Dock"）：调试报告(20) 里 "dock model gridSize: count=5" 就是实锤证据——
    // Dock 实为 6 图标，count=5 的日志只会来自被误判的文件夹 model。误判后
    // 文件夹 gridSize 被套成竖排 {1,6}、freeSlots/isFull/maxIcons 一起放大 →
    // 已满首页拖入应用时排到"下一行"而非新建一页 → 坐标变 NSNotFound →
    // addPlaceholderAtGridCellIndex: 断言（安全模式）/ 图标错位持久化。
    // gDockModel 未就绪时宁可不改任何 model 层行为（视图层 sp_dock_max /
    // sp_dock_rows 已兜底），绝不误伤文件夹。
    id dm = sp_dock_model();
    return dm && model == dm;
}

// 防呆：配置值不能低于当前已有图标数，避免 6 -> 5 时强制挤出。
static NSUInteger sp_effective_dock_max(NSUInteger count) {
    NSUInteger want = (NSUInteger)gDockMaxIcons;
    if (want < 5) want = 5;
    if (count > want) want = count;
    return want;
}

// 记录 Dock 列表的 model 位置；Solo/Atria 都可能先于我们初始化列表。
static void sp_note_dock_list(id listView) {
    if (!listView) return;
    gDockListView = listView;
    SEL ms = @selector(model);
    if (![listView respondsToSelector:ms]) return;
    id model = ((id (*)(id, SEL))objc_msgSend)(listView, ms);
    gDockModel = model;
    sp_mark_model_location(model, @"SBIconLocationDock");
}

static NSUInteger (*sp_orig_dock_max)(id, SEL) = NULL;
static NSUInteger (*sp_orig_dock_rows)(id, SEL) = NULL;
static void (*sp_orig_dock_layoutIconsNow)(id, SEL) = NULL;
static void (*sp_orig_dock_layoutSubviews)(id, SEL) = NULL;
static NSUInteger (*sp_orig_model_max)(id, SEL) = NULL;
static NSUInteger (*sp_orig_model_maxCount)(id, SEL) = NULL;
static NSUInteger (*sp_orig_model_free)(id, SEL) = NULL;
typedef struct { unsigned short width; unsigned short height; } sp_icon_grid_size;
static sp_icon_grid_size (*sp_orig_model_gridSize)(id, SEL) = NULL;
static BOOL (*sp_orig_model_isFull)(id, SEL) = NULL;
static BOOL (*sp_orig_model_canAdd)(id, SEL, id) = NULL;
static BOOL (*sp_orig_model_canAddAt)(id, SEL, id, NSUInteger) = NULL;
static id (*sp_orig_model_insert)(id, SEL, id, NSUInteger) = NULL;
static id (*sp_orig_model_insertMany)(id, SEL, id, NSUInteger, NSUInteger) = NULL;
static int gDockDropLogBudget = 12;

static NSUInteger sp_model_icon_count(id model) {
    SEL s = @selector(icons);
    if (!model || ![model respondsToSelector:s]) return 0;
    id icons = ((id (*)(id, SEL))objc_msgSend)(model, s);
    if (!icons || ![icons respondsToSelector:@selector(count)]) return 0;
    return ((NSUInteger (*)(id, SEL))objc_msgSend)(icons, @selector(count));
}

static NSUInteger sp_dock_max(id self, SEL _cmd) {
    sp_note_dock_list(self);
    NSUInteger base = sp_orig_dock_max ? sp_orig_dock_max(self, _cmd) : 5;
    NSUInteger effective = sp_effective_dock_max(sp_dock_icon_count(self));
    if (base < effective) return effective;
    return base;
}

static NSUInteger sp_dock_rows(id self, SEL _cmd) {
    sp_note_dock_list(self);
    NSUInteger base = sp_orig_dock_rows ? sp_orig_dock_rows(self, _cmd) : 5;
    // 不能等“已经有 6 个图标”才返回 6：模型没有第 6 个槽就永远拖不进第 6 个。
    NSUInteger effective = sp_effective_dock_max(sp_dock_icon_count(self));
    if (base < effective) return effective;
    return base;
}

static NSUInteger sp_model_max_icons(id self, SEL _cmd) {
    NSUInteger base = sp_orig_model_max ? sp_orig_model_max(self, _cmd) : 0;
    if (sp_model_is_dock(self)) {
        NSUInteger effective = sp_effective_dock_max(sp_model_icon_count(self));
        if (gDockModelLogBudget > 0) {
            gDockModelLogBudget--;
            sp_log(@"dock model max: base=%lu -> %lu (count=%lu configured=%.0f)",
                   (unsigned long)base, (unsigned long)(base < effective ? effective : base),
                   (unsigned long)sp_model_icon_count(self), gDockMaxIcons);
        }
        if (base < effective) return effective;
    }
    return base;
}

static NSUInteger sp_model_max_count_alias(id self, SEL _cmd) {
    NSUInteger base = sp_orig_model_maxCount ? sp_orig_model_maxCount(self, _cmd) : 0;
    if (sp_model_is_dock(self)) {
        NSUInteger effective = sp_effective_dock_max(sp_model_icon_count(self));
        if (base < effective) return effective;
    }
    return base;
}

static sp_icon_grid_size sp_model_grid_size(id self, SEL _cmd) {
    sp_icon_grid_size g = {0, 0};
    if (sp_orig_model_gridSize) g = sp_orig_model_gridSize(self, _cmd);
    if (sp_model_is_dock(self)) {
        // Atria 对 root 会返回 0x7FFF×0x7FFF 这类哨兵值防挤走；Dock 若也拿到
        // 这种值不要覆盖，交给原实现，避免破坏它的布局账本。
        if (g.width > 1000 || g.height > 1000) return g;
        unsigned short want = (unsigned short)sp_effective_dock_max(sp_model_icon_count(self));
        // 关键：gridSize 的方向必须跟 Solo/Atria 实际布局一致（竖排 1×N）。
        id list = gDockListView;
        NSUInteger cols = 0, rows = 0;
        SEL colsSel = @selector(iconColumnsForCurrentOrientation);
        SEL rowsSel = @selector(iconRowsForCurrentOrientation);
        if (list && [list respondsToSelector:colsSel]) {
            cols = ((NSUInteger (*)(id, SEL))objc_msgSend)(list, colsSel);
        }
        if (list && [list respondsToSelector:rowsSel]) {
            rows = ((NSUInteger (*)(id, SEL))objc_msgSend)(list, rowsSel);
        }
        if (cols > 0 && rows > 0) {
            g.width = (unsigned short)cols;
            g.height = (unsigned short)rows;
            // 长轴必须能容纳 want 个槽。此前只照抄视图值：6 图标时视图仍报
            // 1×5，拖起第 6 个图标的 placeholder 索引越界 → SBIconListView
            // addPlaceholderAtGridCellIndex: 断言 abort → 连续崩溃进安全模式
            // （2026-11-24 SpringBoard-175924.ips 实锤）。
            if (g.width >= g.height) {
                if (g.width < want) g.width = want;
            } else {
                if (g.height < want) g.height = want;
            }
        } else {
            // gDockListView 在 CC 转场/编辑态重建列表时会短暂为 nil：此时必须
            // 按竖排 1×N 兜底，绝不能把 1×6 写成横排 6×1（旧 fallback 的洞）。
            g.width = 1;
            g.height = want;
        }
        if (gDockDropLogBudget > 0) {
            gDockDropLogBudget--;
            sp_log(@"dock model gridSize: count=%lu cols=%lu rows=%lu -> {%u,%u}",
                   (unsigned long)sp_model_icon_count(self),
                   (unsigned long)cols, (unsigned long)rows, g.width, g.height);
        }
    }
    return g;
}

static NSUInteger sp_model_free_slots(id self, SEL _cmd) {
    NSUInteger base = sp_orig_model_free ? sp_orig_model_free(self, _cmd) : 0;
    if (sp_model_is_dock(self)) {
        // 旧实现返回 NSUIntegerMax（照抄 Atria 对 root 列表的“无限槽”策略）。
        // Dock 是定长网格，无限槽会让拖放系统按不存在的索引创建 placeholder，
        // 在 addPlaceholderAtGridCellIndex: 里断言 abort。改为报告真实剩余槽数：
        // 6 图标配置下还剩 1 个槽就报 1，满了就报 0（同时不挡住第 6 个投放）。
        NSUInteger n = sp_model_icon_count(self);
        NSUInteger effective = sp_effective_dock_max(n);
        return effective > n ? effective - n : 0;
    }
    return base;
}

static BOOL sp_model_is_full(id self, SEL _cmd) {
    BOOL base = sp_orig_model_isFull ? sp_orig_model_isFull(self, _cmd) : NO;
    if (sp_model_is_dock(self)) {
        NSUInteger n = sp_model_icon_count(self);
        NSUInteger effective = sp_effective_dock_max(n);
        if (n < effective) base = NO;
        if (gDockDropLogBudget > 0) {
            gDockDropLogBudget--;
            sp_log(@"dock isFull: count=%lu effective=%lu -> %d",
                   (unsigned long)n, (unsigned long)effective, base ? 1 : 0);
        }
    }
    return base;
}

static BOOL sp_icon_is_app(id icon) {
    Class app = NSClassFromString(@"SBApplicationIcon");
    if (!app) return YES;
    return icon && [icon isKindOfClass:app];
}

static BOOL sp_model_can_add(id self, SEL _cmd, id icon) {
    BOOL base = sp_orig_model_canAdd ? sp_orig_model_canAdd(self, _cmd, icon) : NO;
    if (gDockMaxIcons >= 5.5 && sp_model_is_dock(self)
        && sp_model_icon_count(self) < (NSUInteger)gDockMaxIcons
        && sp_icon_is_app(icon)) {
        base = YES;
    }
    if (gDockDropLogBudget > 0 && sp_model_is_dock(self)) {
        gDockDropLogBudget--;
        sp_log(@"dock canAddIcon: %@ count=%lu -> %d",
               NSStringFromClass([icon class]), (unsigned long)sp_model_icon_count(self),
               base ? 1 : 0);
    }
    return base;
}

static BOOL sp_model_can_add_at(id self, SEL _cmd, id icon, NSUInteger idx) {
    BOOL base = sp_orig_model_canAddAt ? sp_orig_model_canAddAt(self, _cmd, icon, idx) : NO;
    if (sp_model_is_dock(self)) {
        NSUInteger n = sp_model_icon_count(self);
        NSUInteger effective = sp_effective_dock_max(n);
        // 6 图标配置下，只有 idx < 有效槽数才是合法投放点。旧实现只看
        // count < gDockMaxIcons，拖放系统传来的越界 idx 也放行 → placeholder
        // 按越界 gridCellIndex 创建时断言 abort（见 gridSize 处的 .ips 说明）。
        if (idx >= effective) {
            base = NO;
        } else if (gDockMaxIcons >= 5.5 && n < effective && sp_icon_is_app(icon)) {
            base = YES;
        }
    }
    if (gDockDropLogBudget > 0 && sp_model_is_dock(self)) {
        gDockDropLogBudget--;
        sp_log(@"dock canAddIcon:atIndex: %@ idx=%lu count=%lu -> %d",
               NSStringFromClass([icon class]), (unsigned long)idx,
               (unsigned long)sp_model_icon_count(self), base ? 1 : 0);
    }
    return base;
}

static id sp_model_insert_one(id self, SEL _cmd, id icon, NSUInteger idx) {
    NSUInteger before = sp_model_icon_count(self);
    if (sp_model_is_dock(self)) {
        NSUInteger effective = sp_effective_dock_max(before);
        if (idx >= effective) {
            // 越界 idx 直接拒绝并留日志：不把坏索引交给 SpringBoardHome，
            // 其 addPlaceholderAtGridCellIndex: 断言会 abort（见 gridSize 注释）。
            if (gDockDropLogBudget > 0) {
                gDockDropLogBudget--;
                sp_log(@"dock insertIcon: rejected out-of-range idx=%lu count=%lu cap=%lu",
                       (unsigned long)idx, (unsigned long)before, (unsigned long)effective);
            }
            return nil;
        }
    }
    id result = nil;
    @try {
        result = sp_orig_model_insert ? sp_orig_model_insert(self, _cmd, icon, idx) : nil;
    } @catch (NSException *e) {
        // 兜底闸门：模型内部断言异常绝不冒泡到 CFRunLoop（会 terminate 进安全模式）。
        sp_log(@"dock insertIcon: caught %@ idx=%lu count=%lu", e.reason ?: @"(nil)",
               (unsigned long)idx, (unsigned long)before);
        return nil;
    }
    if (gDockMaxIcons >= 5.5 && sp_model_is_dock(self) && gDockDropLogBudget > 0) {
        gDockDropLogBudget--;
        sp_log(@"dock insertIcon: %@ idx=%lu count=%lu -> %lu result=%p",
               NSStringFromClass([icon class]), (unsigned long)idx,
               (unsigned long)before, (unsigned long)sp_model_icon_count(self),
               (__bridge void *)result);
    }
    return result;
}

static id sp_model_insert_many(id self, SEL _cmd, id icons, NSUInteger idx,
                               NSUInteger options) {
    NSUInteger before = sp_model_icon_count(self);
    if (sp_model_is_dock(self)) {
        NSUInteger effective = sp_effective_dock_max(before);
        if (idx >= effective) {
            if (gDockDropLogBudget > 0) {
                gDockDropLogBudget--;
                sp_log(@"dock insertIcons: rejected out-of-range idx=%lu count=%lu cap=%lu",
                       (unsigned long)idx, (unsigned long)before, (unsigned long)effective);
            }
            return nil;
        }
    }
    id result = nil;
    @try {
        result = sp_orig_model_insertMany
            ? sp_orig_model_insertMany(self, _cmd, icons, idx, options) : nil;
    } @catch (NSException *e) {
        sp_log(@"dock insertIcons: caught %@ idx=%lu count=%lu", e.reason ?: @"(nil)",
               (unsigned long)idx, (unsigned long)before);
        return nil;
    }
    if (gDockMaxIcons >= 5.5 && sp_model_is_dock(self) && gDockDropLogBudget > 0) {
        gDockDropLogBudget--;
        sp_log(@"dock insertIcons: idx=%lu count=%lu -> %lu options=%lu result=%p",
               (unsigned long)idx, (unsigned long)before,
               (unsigned long)sp_model_icon_count(self), (unsigned long)options,
               (__bridge void *)result);
    }
    return result;
}

// 崩溃栈终点防护（SpringBoard-2026-11-24-175924.ips）：
// SBIconDragManager 抬升完成 → addPlaceholderRepresentingIcon: →
// addPlaceholderAtGridCellIndex: 内 NSAssert 抛异常 → 冒泡到 CFRunLoop →
// abort / 连续 3 次崩溃进安全模式。上面把模型容量、gridSize、投放索引全部
// 收敛后仍可能有上游（Solo/Atria 的 hook 链）算出越界 index，这里在最后一环
// 拦住：Dock 列表的越界索引直接拒绝，并用 @try/@catch 兜住任何内部断言，
// 不让异常冒泡到 runloop。其它列表（主屏/文件夹）原样转发，零影响。
// reason / options 在私有头文件里可能是对象或枚举，用 uintptr_t 保持 ABI 中立：
// arm64 下与 id / NSUInteger 同为 8 字节寄存器传递，转发原实现完全等价。
static id (*sp_orig_add_placeholder_at)(id, SEL, NSUInteger, id,
                                        uintptr_t, uintptr_t) = NULL;

static id sp_add_placeholder_at(id self, SEL _cmd, NSUInteger idx,
                                id icon, uintptr_t reason, uintptr_t options) {
    // 调试报告(20) 实机：文件夹首页满时系统下发 idx=NSNotFound
    // (0x7FFFFFFFFFFFFFFF = 9223372036854775807)。前置拒绝，不让
    // SpringBoardHome 抛断言异常，也不给半状态留机会。
    if (idx == (NSUInteger)NSNotFound) {
        static int sentinelBudget = 12;
        if (sentinelBudget > 0) {
            sentinelBudget--;
            sp_log(@"placeholder: rejected NSNotFound on %@",
                   NSStringFromClass([self class]));
        }
        return nil;
    }
    BOOL isDock = objc_getClass("SBDockIconListView")
               && [self isKindOfClass:objc_getClass("SBDockIconListView")];
    if (isDock) {
        NSUInteger cap = sp_effective_dock_max(sp_dock_icon_count(self));
        if (idx >= cap) {
            sp_log(@"dock placeholder: rejected idx=%lu cap=%lu (icon=%@)",
                   (unsigned long)idx, (unsigned long)cap,
                   NSStringFromClass([icon class]));
            return nil;
        }
        @try {
            return sp_orig_add_placeholder_at
                ? sp_orig_add_placeholder_at(self, _cmd, idx, icon, reason, options) : nil;
        } @catch (NSException *e) {
            sp_log(@"dock placeholder: caught %@ idx=%lu cap=%lu",
                   e.reason ?: @"(nil)", (unsigned long)idx, (unsigned long)cap);
            return nil;
        }
    }
    // .ips 未记录拖拽发生在哪一页列表：非 Dock 列表也做异常兜底，
    // 保证任何来源的 addPlaceholder 断言都不会冒泡到 CFRunLoop 触发 abort。
    @try {
        return sp_orig_add_placeholder_at
            ? sp_orig_add_placeholder_at(self, _cmd, idx, icon, reason, options) : nil;
    } @catch (NSException *e) {
        static int budget = 12;
        if (budget > 0) {
            budget--;
            sp_log(@"placeholder: caught %@ on %@ idx=%lu",
                   e.reason ?: @"(nil)", NSStringFromClass([self class]),
                   (unsigned long)idx);
        }
        return nil;
    }
}

static void sp_dock_layoutIconsNow(id self, SEL _cmd) {
    if (sp_orig_dock_layoutIconsNow) sp_orig_dock_layoutIconsNow(self, _cmd);
    // 缩放/位移已移交第三方插件（Atria 等），本钩子只剩一个职责：
    // 刷新 gDockListView / gDockModel —— 模型层严格指针身份的唯一数据源。
    // 删掉这里，文件夹 model 误判（调试报告(20) count=5 错位）就会回归。
    sp_note_dock_list(self);
}

static void sp_dock_layoutSubviews(id self, SEL _cmd) {
    if (sp_orig_dock_layoutSubviews) sp_orig_dock_layoutSubviews(self, _cmd);
    sp_note_dock_list(self);
}

static int spEvictAttempts = 0;
static BOOL spEvictRunning = NO;
static CFRunLoopTimerRef spEvictTimer = NULL;

static id sp_icon_controller(void) {
    Class c = NSClassFromString(@"SBIconController");
    if (!c) return nil;
    SEL sel = @selector(sharedInstance);
    if (![c respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)((id)c, sel);
}

static NSArray *sp_root_list_views(void) {
    id c = sp_icon_controller();
    if (!c) return nil;
    SEL rfcSel = @selector(_rootFolderController);
    if (![c respondsToSelector:rfcSel]) return nil;
    id rfc = ((id (*)(id, SEL))objc_msgSend)(c, rfcSel);
    SEL rfvSel = @selector(rootFolderView);
    if (!rfc || ![rfc respondsToSelector:rfvSel]) return nil;
    id rfv = ((id (*)(id, SEL))objc_msgSend)(rfc, rfvSel);
    SEL listsSel = @selector(iconListViews);
    if (!rfv || ![rfv respondsToSelector:listsSel]) return nil;
    id lists = ((id (*)(id, SEL))objc_msgSend)(rfv, listsSel);
    return [lists isKindOfClass:[NSArray class]] ? lists : nil;
}

static BOOL sp_icon_editing(void) {
    id c = sp_icon_controller();
    if (!c) return NO;
    SEL mgrSel = @selector(iconManager);
    if (![c respondsToSelector:mgrSel]) return NO;
    id mgr = ((id (*)(id, SEL))objc_msgSend)(c, mgrSel);
    SEL editSel = @selector(isEditing);
    if (!mgr || ![mgr respondsToSelector:editSel]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(mgr, editSel);
}

static void sp_layout_list_view(id listView) {
    if (!listView) return;
    SEL sel = @selector(layoutIconsNow);
    if ([listView respondsToSelector:sel]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(listView, sel); } @catch (__unused NSException *e) {}
    }
}

// 配置切回 5 且 Dock 还有 6 个图标时，把多出的图标迁移到主屏第一个可放下的列表。
// 先加入主屏成功后才从 Dock 移除；任何一步失败都回滚，绝不依赖 SpringBoard 强踢。
static void sp_auto_evict_dock_icons(void) {
    if (gDockMaxIcons >= 5.5 || spEvictRunning) return;
    id dock = gDockListView;
    if (!dock) return;
    SEL modelSel = @selector(model);
    if (![dock respondsToSelector:modelSel]) return;
    id dockModel = ((id (*)(id, SEL))objc_msgSend)(dock, modelSel);
    if (!dockModel) return;
    SEL iconsSel = @selector(icons);
    if (![dockModel respondsToSelector:iconsSel]) return;
    id icons = ((id (*)(id, SEL))objc_msgSend)(dockModel, iconsSel);
    if (![icons isKindOfClass:[NSArray class]] || [icons count] <= 5) return;
    if (sp_icon_editing()) return;

    NSArray *rootViews = sp_root_list_views();
    if (!rootViews.count) return;
    NSMutableArray *rootModels = [NSMutableArray array];
    for (id lv in rootViews) {
        SEL ms = @selector(model);
        if (![lv respondsToSelector:ms]) continue;
        id m = ((id (*)(id, SEL))objc_msgSend)(lv, ms);
        if (m && m != dockModel) [rootModels addObject:m];
    }
    if (!rootModels.count) return;
    SEL removeSel = @selector(removeIcon:);
    SEL addSel = @selector(addIcon:);
    if (![dockModel respondsToSelector:removeSel]) return;

    spEvictRunning = YES;
    NSUInteger moved = 0;
    NSArray *snapshot = [icons copy];
    NSUInteger over = snapshot.count - 5;
    if (over > snapshot.count) over = snapshot.count;
    for (NSUInteger i = 0; i < over; i++) {
        id icon = snapshot[snapshot.count - 1 - i];
        BOOL removed = NO;
        BOOL added = NO;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(dockModel, removeSel, icon);
            removed = YES;
        } @catch (__unused NSException *e) {}
        if (!removed) break;

        for (id rm in rootModels) {
            if (![rm respondsToSelector:addSel]) continue;
            SEL canSel = @selector(canAddIcon:);
            if ([rm respondsToSelector:canSel]) {
                BOOL can = ((BOOL (*)(id, SEL, id))objc_msgSend)(rm, canSel, icon);
                if (!can) continue;
            }
            SEL freeSel = @selector(numberOfFreeSlots);
            if ([rm respondsToSelector:freeSel]) {
                NSUInteger freeSlots = ((NSUInteger (*)(id, SEL))objc_msgSend)(rm, freeSel);
                if (freeSlots == 0) continue;
            }
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(rm, addSel, icon);
            } @catch (__unused NSException *e) {}
            id ri = nil;
            if ([rm respondsToSelector:iconsSel]) {
                ri = ((id (*)(id, SEL))objc_msgSend)(rm, iconsSel);
            }
            if ([ri isKindOfClass:[NSArray class]] && [ri containsObject:icon]) {
                added = YES;
                break;
            }
        }
        if (!added) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(dockModel, addSel, icon);
            } @catch (__unused NSException *e) {}
            break;
        }
        moved++;
    }
    spEvictRunning = NO;

    if (moved > 0) {
        spEvictAttempts = 0;
        id movedIcon = snapshot.count ? snapshot[snapshot.count - 1] : nil;
        sp_log(@"auto-evict: moved %lu icon(s) from dock to root (last=%@)",
               (unsigned long)moved, movedIcon ? NSStringFromClass([movedIcon class]) : @"(nil)");
        sp_layout_list_view(dock);
        for (id lv in rootViews) sp_layout_list_view(lv);
        id c = sp_icon_controller();
        SEL mgrSel = @selector(iconManager);
        if (c && [c respondsToSelector:mgrSel]) {
            id mgr = ((id (*)(id, SEL))objc_msgSend)(c, mgrSel);
            SEL imSel = @selector(iconModel);
            if (mgr && [mgr respondsToSelector:imSel]) {
                id im = ((id (*)(id, SEL))objc_msgSend)(mgr, imSel);
                SEL layoutSel = @selector(layout);
                if (im && [im respondsToSelector:layoutSel]) {
                    @try { ((void (*)(id, SEL))objc_msgSend)(im, layoutSel); }
                    @catch (__unused NSException *e) {}
                }
                SEL saveSel = @selector(saveIconStateIfNeeded);
                if (im && [im respondsToSelector:saveSel]) {
                    @try { ((void (*)(id, SEL))objc_msgSend)(im, saveSel); }
                    @catch (__unused NSException *e) {}
                }
            }
        }
    } else {
        spEvictAttempts++;
        sp_log(@"auto-evict: no icon moved (attempt %d)", spEvictAttempts);
    }
}

static void sp_evict_timer_cb(CFRunLoopTimerRef timer, void *info) {
    (void)info;
    sp_auto_evict_dock_icons();
    BOOL need = NO;
    if (gDockMaxIcons < 5.5) {
        need = YES; // Dock 尚未就绪时继续重试
        id dock = gDockListView;
        SEL ms = @selector(model);
        if (dock && [dock respondsToSelector:ms]) {
            id m = ((id (*)(id, SEL))objc_msgSend)(dock, ms);
            SEL is = @selector(icons);
            if (m && [m respondsToSelector:is]) {
                id icons = ((id (*)(id, SEL))objc_msgSend)(m, is);
                if ([icons isKindOfClass:[NSArray class]] && [icons count] <= 5) need = NO;
            }
        }
    }
    if (!need || spEvictAttempts >= 6) {
        if (spEvictTimer) {
            CFRunLoopTimerInvalidate(spEvictTimer);
            CFRunLoopRemoveTimer(CFRunLoopGetMain(), spEvictTimer, kCFRunLoopCommonModes);
            CFRelease(spEvictTimer);
            spEvictTimer = NULL;
        }
    }
}

static void sp_schedule_evict(double delay) {
    if (spEvictTimer) return;
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    spEvictTimer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                        CFAbsoluteTimeGetCurrent() + delay,
                                        1.0, 0, 0, sp_evict_timer_cb, &ctx);
    if (spEvictTimer) {
        CFRunLoopAddTimer(CFRunLoopGetMain(), spEvictTimer, kCFRunLoopCommonModes);
    }
}

static BOOL sp_install_dock_hooks(void) {
    static BOOL installed = NO;
    if (installed) return YES;
    Class dock = objc_getClass("SBDockIconListView");
    Class model = objc_getClass("SBIconListModel");
    Class uiv = objc_getClass("UIView");
    if (!dock || !model || !uiv) return NO;

    MSHookMessageEx(dock, @selector(maximumIconCount), (IMP)sp_dock_max, (IMP *)&sp_orig_dock_max);
    MSHookMessageEx(dock, @selector(iconRowsForCurrentOrientation), (IMP)sp_dock_rows, (IMP *)&sp_orig_dock_rows);
    MSHookMessageEx(dock, @selector(layoutIconsNow), (IMP)sp_dock_layoutIconsNow, (IMP *)&sp_orig_dock_layoutIconsNow);
    SEL layoutSubviewsSel = @selector(layoutSubviews);
    if (class_getInstanceMethod(dock, layoutSubviewsSel)) {
        MSHookMessageEx(dock, layoutSubviewsSel, (IMP)sp_dock_layoutSubviews,
                        (IMP *)&sp_orig_dock_layoutSubviews);
    }

    SEL modelMaxSel = @selector(maxNumberOfIcons);
    if (class_getInstanceMethod(model, modelMaxSel)) {
        MSHookMessageEx(model, modelMaxSel, (IMP)sp_model_max_icons, (IMP *)&sp_orig_model_max);
    }
    SEL modelFreeSel = @selector(numberOfFreeSlots);
    if (class_getInstanceMethod(model, modelFreeSel)) {
        MSHookMessageEx(model, modelFreeSel, (IMP)sp_model_free_slots, (IMP *)&sp_orig_model_free);
    }
    SEL maxCountSel = @selector(maximumIconCount);
    if (class_getInstanceMethod(model, maxCountSel)) {
        MSHookMessageEx(model, maxCountSel, (IMP)sp_model_max_count_alias,
                        (IMP *)&sp_orig_model_maxCount);
    } else {
        SEL maxCountSel2 = @selector(maxIconCount);
        if (class_getInstanceMethod(model, maxCountSel2)) {
            MSHookMessageEx(model, maxCountSel2, (IMP)sp_model_max_count_alias,
                            (IMP *)&sp_orig_model_maxCount);
        }
    }
    SEL gridSizeSel = @selector(gridSize);
    if (class_getInstanceMethod(model, gridSizeSel)) {
        MSHookMessageEx(model, gridSizeSel, (IMP)sp_model_grid_size,
                        (IMP *)&sp_orig_model_gridSize);
    }
    SEL isFullSel = @selector(isFull);
    if (class_getInstanceMethod(model, isFullSel)) {
        MSHookMessageEx(model, isFullSel, (IMP)sp_model_is_full, (IMP *)&sp_orig_model_isFull);
    }
    SEL canAddSel = @selector(canAddIcon:);
    if (class_getInstanceMethod(model, canAddSel)) {
        MSHookMessageEx(model, canAddSel, (IMP)sp_model_can_add, (IMP *)&sp_orig_model_canAdd);
    }
    SEL canAddAtSel = @selector(canAddIcon:atIndex:);
    if (class_getInstanceMethod(model, canAddAtSel)) {
        MSHookMessageEx(model, canAddAtSel, (IMP)sp_model_can_add_at, (IMP *)&sp_orig_model_canAddAt);
    }
    SEL insertSel = @selector(insertIcon:atIndex:);
    if (class_getInstanceMethod(model, insertSel)) {
        MSHookMessageEx(model, insertSel, (IMP)sp_model_insert_one, (IMP *)&sp_orig_model_insert);
    }
    SEL insertManySel = @selector(insertIcons:atIndex:options:);
    if (class_getInstanceMethod(model, insertManySel)) {
        MSHookMessageEx(model, insertManySel, (IMP)sp_model_insert_many, (IMP *)&sp_orig_model_insertMany);
    }

    // 崩溃栈终点：SBIconListView addPlaceholderAtGridCellIndex:representingIcon:
    // reason:options:（挂在其父类 SBIconListView 上，Dock 列表继承）。
    // ABI 守卫：必须 self+_cmd+4 参 = 6，且返回对象；签名漂移时不装，
    // 退回前面各层容量/索引收敛，绝不匹配错误原型。
    SEL placeholderSel = @selector(addPlaceholderAtGridCellIndex:representingIcon:reason:options:);
    Method placeholderMethod = class_getInstanceMethod(objc_getClass("SBIconListView"),
                                                      placeholderSel);
    if (placeholderMethod && method_getNumberOfArguments(placeholderMethod) == 6) {
        char ret[16] = {0};
        method_getReturnType(placeholderMethod, ret, sizeof(ret));
        if (ret[0] == '@') {
            MSHookMessageEx(objc_getClass("SBIconListView"), placeholderSel,
                            (IMP)sp_add_placeholder_at,
                            (IMP *)&sp_orig_add_placeholder_at);
        }
    }

    // Dock 图标大小/间距/上下移交给第三方插件（Atria 等）调节，本插件不再
    // hook setCenter / UIView setTransform / CALayer addAnimation。

    installed = YES;
    sp_log(@"dock hooks installed (max=%.0f max=%d maxCount=%d free=%d grid=%d full=%d canAdd=%d canAddAt=%d insert=%d insertMany=%d placeholder=%d)",
           gDockMaxIcons,
           sp_orig_model_max != NULL, sp_orig_model_maxCount != NULL,
           sp_orig_model_free != NULL, sp_orig_model_gridSize != NULL,
           sp_orig_model_isFull != NULL, sp_orig_model_canAdd != NULL,
           sp_orig_model_canAddAt != NULL, sp_orig_model_insert != NULL,
           sp_orig_model_insertMany != NULL, sp_orig_add_placeholder_at != NULL);
    return YES;
}

static void sp_dock_retry_cb(CFRunLoopTimerRef timer, void *info) {
    if (sp_install_dock_hooks()) {
        CFRunLoopTimerInvalidate(timer);
        CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
        CFRelease(timer);
    }
}

static void sp_schedule_dock_retry(void) {
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                               CFAbsoluteTimeGetCurrent() + 1.0,
                                               1.0, 0, 0, sp_dock_retry_cb, &ctx);
    if (t) CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
}

#pragma mark - 轮播挂件铺满

static BOOL spCarouselApplying = NO;
static int gCarouselLogBudget = 6;
static __weak id gCarouselListView = nil;

static BOOL sp_is_carousel_list(id list) {
    if (!list || ![list respondsToSelector:@selector(model)]) return NO;
    id model = ((id (*)(id, SEL))objc_msgSend)(list, @selector(model));
    if (!model || ![model respondsToSelector:@selector(uniqueIdentifier)]) return NO;
    id uid = ((id (*)(id, SEL))objc_msgSend)(model, @selector(uniqueIdentifier));
    return [uid isKindOfClass:[NSString class]] && [uid isEqualToString:@"UnduoWidgetCarousel"];
}

static id sp_carousel_icon_view(id list) {
    id icons = nil;
    if ([list respondsToSelector:@selector(icons)]) {
        icons = ((id (*)(id, SEL))objc_msgSend)(list, @selector(icons));
    }
    if ([icons isKindOfClass:[NSArray class]] && [icons count] > 0
        && [list respondsToSelector:@selector(iconViewForIcon:)]) {
        id icon = [icons firstObject];
        id v = ((id (*)(id, SEL, id))objc_msgSend)(list, @selector(iconViewForIcon:), icon);
        if (v) return v;
    }
    Class iconViewClass = NSClassFromString(@"SBIconView");
    for (UIView *sub in ((UIView *)list).subviews) {
        if (iconViewClass && [sub isKindOfClass:iconViewClass]) return sub;
    }
    return nil;
}

static void sp_reset_scaled_transform(UIView *v, const char *tag) {
    if (!v) return;
    CGAffineTransform t = v.transform;
    if (fabs(t.a - 1.0) < 0.001 && fabs(t.d - 1.0) < 0.001) return;
    if (spCarouselApplying) return;
    spCarouselApplying = YES;
    v.transform = CGAffineTransformIdentity;
    spCarouselApplying = NO;
    if (gDebug) {
        sp_log(@"carousel fill: reset %s %@ %.3f -> 1.000",
               tag, NSStringFromClass([v class]), t.a);
    }
}

static void sp_apply_carousel_fill(id list) {
    if (!gCarouselFill) return;
    gCarouselListView = list;
    id iconView = sp_carousel_icon_view(list);
    if (!iconView) return;

    if (gCarouselLogBudget > 0) {
        gCarouselLogBudget--;
        UIView *lv = (UIView *)list;
        UIView *iv = (UIView *)iconView;
        CGFloat ccScale = -1, imgScale = -1, iconScale = iv.transform.a;
        SEL ccSel = @selector(contentContainerView);
        if ([iconView respondsToSelector:ccSel]) {
            id cc = ((id (*)(id, SEL))objc_msgSend)(iconView, ccSel);
            if ([cc isKindOfClass:[UIView class]]) ccScale = ((UIView *)cc).transform.a;
        }
        SEL imgSel = @selector(_iconImageView);
        if ([iconView respondsToSelector:imgSel]) {
            id img = ((id (*)(id, SEL))objc_msgSend)(iconView, imgSel);
            if ([img isKindOfClass:[UIView class]]) imgScale = ((UIView *)img).transform.a;
        }
        sp_log(@"carousel fill: list=%.0fx%.0f icon=%.0fx%.0f scales icon=%.3f cc=%.3f img=%.3f",
               lv.bounds.size.width, lv.bounds.size.height,
               iv.bounds.size.width, iv.bounds.size.height,
               iconScale, ccScale, imgScale);
    }

    // Solo 的 content scale fix 通常落在 contentContainerView 或图标内容视图上；
    // 逐个复位到 1.0，让小组件铺满轮播列表的 364×170 背景。
    SEL ccSel = @selector(contentContainerView);
    if ([iconView respondsToSelector:ccSel]) {
        id cc = ((id (*)(id, SEL))objc_msgSend)(iconView, ccSel);
        if ([cc isKindOfClass:[UIView class]]) sp_reset_scaled_transform(cc, "content");
    }
    SEL imgSel = @selector(_iconImageView);
    if ([iconView respondsToSelector:imgSel]) {
        id img = ((id (*)(id, SEL))objc_msgSend)(iconView, imgSel);
        if ([img isKindOfClass:[UIView class]]) sp_reset_scaled_transform(img, "image");
    }
    // 有些系统版本把 scale fix 直接放在 iconView 上
    sp_reset_scaled_transform(iconView, "iconView");
    SEL setCS = @selector(setIconContentScale:);
    if ([iconView respondsToSelector:setCS]) {
        CGFloat cur = 1.0;
        SEL getCS = @selector(iconContentScale);
        if ([iconView respondsToSelector:getCS]) {
            cur = ((CGFloat (*)(id, SEL))objc_msgSend)(iconView, getCS);
        }
        if (fabs(cur - 1.0) > 0.001) {
            @try { ((void (*)(id, SEL, CGFloat))objc_msgSend)(iconView, setCS, 1.0); }
            @catch (__unused NSException *e) {}
        }
    }
}

static UIView *sp_find_carousel_in_view(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    if (sp_is_carousel_list(v)) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = sp_find_carousel_in_view(sub, depth + 1);
        if (r) return r;
    }
    return nil;
}

static void sp_refresh_carousel(void) {
    id list = gCarouselListView;
    if (!list) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            UIView *found = sp_find_carousel_in_view(w, 0);
            if (found) { list = found; gCarouselListView = found; break; }
        }
    }
    if (list && [list respondsToSelector:@selector(layoutIconsNow)]) {
        ((void (*)(id, SEL))objc_msgSend)(list, @selector(layoutIconsNow));
    }
}

static void (*sp_orig_list_layoutIconsNow)(id, SEL) = NULL;
static void (*sp_orig_list_layoutSubviews)(id, SEL) = NULL;

static void sp_list_layoutIconsNow(id self, SEL _cmd) {
    if (sp_orig_list_layoutIconsNow) sp_orig_list_layoutIconsNow(self, _cmd);
    if (gCarouselFill && sp_is_carousel_list(self)) sp_apply_carousel_fill(self);
}

static void sp_list_layoutSubviews(id self, SEL _cmd) {
    if (sp_orig_list_layoutSubviews) sp_orig_list_layoutSubviews(self, _cmd);
    if (gCarouselFill && sp_is_carousel_list(self)) sp_apply_carousel_fill(self);
}

static void sp_install_carousel_hooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class list = objc_getClass("SBIconListView");
    if (!list) return;
    SEL li = @selector(layoutIconsNow);
    if (class_getInstanceMethod(list, li)) {
        MSHookMessageEx(list, li, (IMP)sp_list_layoutIconsNow, (IMP *)&sp_orig_list_layoutIconsNow);
    }
    SEL ls = @selector(layoutSubviews);
    if (class_getInstanceMethod(list, ls)) {
        MSHookMessageEx(list, ls, (IMP)sp_list_layoutSubviews, (IMP *)&sp_orig_list_layoutSubviews);
    }
    installed = YES;
    sp_log(@"carousel fill hooks installed (enabled=%d layoutIconsNow=%d layoutSubviews=%d)",
           gCarouselFill, sp_orig_list_layoutIconsNow != NULL, sp_orig_list_layoutSubviews != NULL);
}

#pragma mark - Duo 展示 / 数据标识

static char spDataBaseSizeKey = 0;
static char spDataOriginalKey = 0;
static __weak UILabel *gDataLabel = nil;
static __weak UIView *gDataContainer = nil; // 状态环/读数容器（Duo）

static void (*sp_orig_label_setText)(id, SEL, NSString *) = NULL;
static void (*sp_orig_label_setAttributedText)(id, SEL, NSAttributedString *) = NULL;
static NSString *(*sp_orig_label_text)(id, SEL) = NULL;
static char spDataSuperscriptKey = 0;

static BOOL sp_is_marked_data_label(id self) {
    return self == gDataLabel
        || objc_getAssociatedObject(self, &spDataOriginalKey) != nil;
}

static BOOL sp_looks_like_duo_label(id self) {
    if (![NSStringFromClass([self class]) isEqualToString:@"UILabel"]) return NO;
    NSString *wcls = [(UIView *)self window] ? NSStringFromClass([[(UIView *)self window] class]) : nil;
    return wcls && [wcls containsString:@"HomeScreen"];
}

static BOOL sp_is_data_text(NSString *t) {
    return [t isEqualToString:@"5G"] || [t isEqualToString:@"LTE"]
        || [t isEqualToString:@"3G"] || [t isEqualToString:@"E"]
        || [t isEqualToString:@"Wi-Fi"] || [t isEqualToString:@"WiFi"]
        || [t isEqualToString:@"WIFI"];
}

static NSString *sp_mapped_data_text(NSString *t) {
    // 只固定替换 5G -> 5GA，其余保持不变。
    // 5G 的正常显示走 sp_apply_superscript_5GA()（A 小号上标）；
    // 这里的纯文本只在没有 attributedText 能力时兜底。
    if ([t isEqualToString:@"5G"]) return @"5GA";
    return t;
}

static CGFloat sp_selected_weight(void) {
    double v = gDataFontWeight;
    if (v < 1.5) return -0.4;  // 1 细
    if (v < 2.5) return 0.0;   // 2 常规
    if (v < 3.5) return 0.23;  // 3 中粗
    return 0.4;                // 4 粗
}

static void sp_apply_data_font(UILabel *lab) {
    if (!lab) return;
    NSNumber *base = objc_getAssociatedObject(lab, &spDataBaseSizeKey);
    if (!base) {
        UIFont *f = ((id (*)(id, SEL))objc_msgSend)(lab, @selector(font));
        if (f && f.pointSize > 0) {
            base = @(f.pointSize);
            objc_setAssociatedObject(lab, &spDataBaseSizeKey, base,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (!base) return;
    CGFloat target = base.doubleValue * gDataFontScale;
    UIFont *f = ((id (*)(id, SEL))objc_msgSend)(lab, @selector(font));
    if (!f) return;

    UIFont *nf = nil;
    if (gDataFontWeight < 0.5) {
        if (fabs(f.pointSize - target) > 0.01) nf = [f fontWithSize:target];
    } else {
        nf = [UIFont systemFontOfSize:target weight:sp_selected_weight()];
    }
    if (nf && ![nf isEqual:f]) {
        ((void (*)(id, SEL, id))objc_msgSend)(lab, @selector(setFont:), nf);
    }
}

static void sp_apply_superscript_5GA(UILabel *lab) {
    if (!lab) return;
    UIFont *f = ((id (*)(id, SEL))objc_msgSend)(lab, @selector(font));
    if (!f) return;
    UIColor *color = ((id (*)(id, SEL))objc_msgSend)(lab, @selector(textColor));
    if (!color) color = [UIColor labelColor];
    CGFloat size = f.pointSize;
    CGFloat smallSize = size * 0.62;
    if (smallSize < 5.0) smallSize = 5.0;
    UIFont *small = [f fontWithSize:smallSize];
    NSMutableAttributedString *m = [[NSMutableAttributedString alloc]
        initWithString:@"5GA"
            attributes:@{NSFontAttributeName: f,
                         NSForegroundColorAttributeName: color}];
    // 参考运营商样式：A 缩小、底部与 5G 对齐（不改变基线）
    [m addAttributes:@{NSFontAttributeName: small,
                       NSBaselineOffsetAttributeName: @0}
              range:NSMakeRange(2, 1)];
    objc_setAssociatedObject(lab, &spDataSuperscriptKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sp_orig_label_setAttributedText) {
        sp_orig_label_setAttributedText(lab, @selector(setAttributedText:), m);
    } else if (sp_orig_label_setText) {
        sp_orig_label_setText(lab, @selector(setText:), @"5GA");
    }
}

// 统一入口：记录原始文本、应用字号/字重，再决定 5G 上标或普通文本
static void sp_apply_data_text(UILabel *lab, NSString *original) {
    if (!lab || !original) return;
    objc_setAssociatedObject(lab, &spDataOriginalKey, original,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    sp_apply_data_font(lab);
    if ([original isEqualToString:@"5G"]) {
        sp_apply_superscript_5GA(lab);
        return;
    }
    objc_setAssociatedObject(lab, &spDataSuperscriptKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSString *mapped = sp_mapped_data_text(original);
    if (sp_orig_label_setText) {
        sp_orig_label_setText(lab, @selector(setText:), mapped);
    } else {
        ((void (*)(id, SEL, id))objc_msgSend)(lab, @selector(setText:), mapped);
    }
}

static void sp_apply_duo_visibility(void) {
    UIView *v = gDataContainer;
    if (v) v.hidden = !gShowDuo;
}

static void sp_locate_duo_anchor(void);
static void sp_apply_duo_time_visibility(void);
static void sp_apply_duo_battery(void);
static void sp_apply_duo_icons(void);

static void sp_apply_data_label_live(void) {
    UILabel *lab = gDataLabel;
    if (lab) {
        NSString *orig = objc_getAssociatedObject(lab, &spDataOriginalKey);
        if (orig) {
            sp_apply_data_text(lab, orig);
        } else {
            sp_apply_data_font(lab);
        }
    }
    sp_apply_duo_visibility();
}

static int gDataLogBudget = 4;

static BOOL sp_text_is_clock_time(NSString *t);

static void sp_label_setText(id self, SEL _cmd, NSString *text) {
    // Duo 时间：在 setter 里把文字直接换空串，Solo 的玻璃/快照层也就抓不到时间了。
    if (!gShowDuoTime && text.length > 0 && gDuoAnchorView
        && [(UIView *)self isDescendantOfView:(UIView *)gDuoAnchorView]
        && sp_text_is_clock_time(text)) {
        objc_setAssociatedObject(self, &spDuoTimeTextKey, text,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (sp_orig_label_setText) sp_orig_label_setText(self, _cmd, @"");
        return;
    }
    void *ret = __builtin_return_address(0);
    BOOL marked = sp_is_marked_data_label(self);
    BOOL fromSolo = sp_caller_is_solo(ret);
    if (text && (marked || (fromSolo && sp_is_data_text(text))
                 || (sp_looks_like_duo_label(self) && sp_is_data_text(text)))) {
        gDataLabel = (UILabel *)self;
        UIView *sv = [(UIView *)self superview];
        UIView *sv2 = sv ? sv.superview : nil;
        if (sv2 && sv2 != gDataContainer) {
            gDataContainer = sv2;
            sp_apply_duo_visibility();
            if (gDebug) {
                NSMutableString *chain = [NSMutableString string];
                UIView *v = (UIView *)self;
                for (int i = 0; i < 5 && v; i++) {
                    [chain appendFormat:@"%@(%.0fx%.0f) <- ", NSStringFromClass([v class]),
                        v.bounds.size.width, v.bounds.size.height];
                    v = v.superview;
                }
                sp_log(@"data container chain: %@", chain);
            }
        }
        if (gDataLogBudget > 0) {
            gDataLogBudget--;
            sp_log(@"data text %@ -> %@", text,
                   [text isEqualToString:@"5G"] ? @"5G^A" : sp_mapped_data_text(text));
        }
        sp_apply_data_text((UILabel *)self, text);
        return;
    }
    sp_orig_label_setText(self, _cmd, text);
}

static void sp_label_setAttributedText(id self, SEL _cmd, NSAttributedString *attr) {
    if (!gShowDuoTime && attr.length > 0 && gDuoAnchorView
        && [(UIView *)self isDescendantOfView:(UIView *)gDuoAnchorView]
        && sp_text_is_clock_time(attr.string)) {
        objc_setAssociatedObject(self, &spDuoTimeTextKey, attr.string,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (sp_orig_label_setAttributedText) {
            sp_orig_label_setAttributedText(self, _cmd,
                [[NSAttributedString alloc] initWithString:@""]);
        }
        return;
    }
    void *ret = __builtin_return_address(0);
    NSString *str = attr.string;
    BOOL marked = sp_is_marked_data_label(self);
    BOOL fromSolo = sp_caller_is_solo(ret);
    if (str && (marked || (fromSolo && sp_is_data_text(str))
                || (sp_looks_like_duo_label(self) && sp_is_data_text(str)))) {
        if ([str isEqualToString:@"5G"]) {
            sp_apply_data_text((UILabel *)self, str);
            return;
        }
        NSMutableAttributedString *m = [attr mutableCopy];
        [m replaceCharactersInRange:NSMakeRange(0, str.length)
                         withString:sp_mapped_data_text(str)];
        if (sp_orig_label_setAttributedText) {
            sp_orig_label_setAttributedText(self, _cmd, m);
        }
        return;
    }
    if (sp_orig_label_setAttributedText) {
        sp_orig_label_setAttributedText(self, _cmd, attr);
    }
}

static NSString *sp_label_text(id self, SEL _cmd) {
    NSString *t = sp_orig_label_text ? sp_orig_label_text(self, _cmd) : nil;
    // 存储层是 5GA（attributed 显示 5G^A），但对 Solo 的读取返回 5G，
    // 让 Solo 认为文本没变，避免每秒重置造成闪烁/重排。
    if (t && [t isEqualToString:@"5GA"]
        && objc_getAssociatedObject(self, &spDataSuperscriptKey)) {
        return @"5G";
    }
    return t;
}

static void sp_install_data_hook(void) {
    Class label = objc_getClass("UILabel");
    if (!label) return;
    MSHookMessageEx(label, @selector(setText:), (IMP)sp_label_setText,
                    (IMP *)&sp_orig_label_setText);
    MSHookMessageEx(label, @selector(setAttributedText:), (IMP)sp_label_setAttributedText,
                    (IMP *)&sp_orig_label_setAttributedText);
    MSHookMessageEx(label, @selector(text), (IMP)sp_label_text,
                    (IMP *)&sp_orig_label_text);
    sp_log(@"data hook installed");
}

static int gScanLogBudget = 2;

static void sp_scan_view_for_data(UIView *v) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lab = (UILabel *)v;
        NSString *t = lab.text;
        NSString *wcls = lab.window ? NSStringFromClass([lab.window class]) : nil;
        NSString *lcls = NSStringFromClass([lab class]);
        BOOL duoWindow = wcls && [wcls containsString:@"HomeScreen"];
        BOOL stockStatusView = lcls && ([lcls containsString:@"StatusBar"] || [lcls containsString:@"STUI"]);
        if (t && sp_is_data_text(t) && duoWindow && !stockStatusView) {
            CGFloat area = lab.bounds.size.width * lab.bounds.size.height;
            if (area > 1 && lab.window) {
                gDataLabel = lab;
                UIView *sv = lab.superview;
                UIView *sv2 = sv ? sv.superview : nil;
                if (sv2) gDataContainer = sv2;
            }
            // 已经是 5G^A 上标时不要每秒重设，避免 attributed 文本反复重排；
            // 字号/字重变化由 sp_apply_data_label_live 即时处理。
            BOOL alreadySuperscript = [t isEqualToString:@"5G"]
                && objc_getAssociatedObject(lab, &spDataSuperscriptKey) != nil;
            if (!alreadySuperscript) sp_apply_data_text(lab, t);
            sp_apply_duo_visibility();
            if (gScanLogBudget > 0) {
                gScanLogBudget--;
                sp_log(@"data label enforced: win=%@ cls=%@ %@ -> %@ %.0fx%.0f",
                       lab.window ? NSStringFromClass([lab.window class]) : @"(nil)",
                       NSStringFromClass([lab class]), t,
                       [t isEqualToString:@"5G"] ? @"5G^A" : sp_mapped_data_text(t),
                       lab.bounds.size.width, lab.bounds.size.height);
            }
        }
    }
    for (UIView *sub in v.subviews) sp_scan_view_for_data(sub);
}

static void sp_scan_data_labels(void) {
    @autoreleasepool {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            sp_scan_view_for_data(w);
        }
    }
    sp_apply_duo_visibility();
    sp_locate_duo_anchor();
    sp_apply_duo_time_visibility();
    sp_apply_duo_battery();
    sp_apply_duo_icons();
}

static void sp_data_scan_cb(CFRunLoopTimerRef timer, void *info) {
    sp_scan_data_labels();
}

static void sp_schedule_data_scan(void) {
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                               CFAbsoluteTimeGetCurrent() + 1.5,
                                               1.0, 0, 0, sp_data_scan_cb, &ctx);
    if (t) CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
}

#pragma mark - Duo 时间开关 / 下方电量

// Duo 是 Solo 主屏的状态环：上方一行时间（时钟文字），环内是数据读数。
// 这里只做两件事：① 单独开关上方时间（状态栏已有时间）；② 环下方显示剩余电量。

static int gBatteryPct = -1;
static void sp_dump_view_level(UIView *v, int depth, int maxDepth);
static void sp_dump_layer_level(CALayer *l, int depth, int maxDepth);
static BOOL gBatteryCharging = NO;
static NSTimeInterval gBatteryReadAt = 0;
static int gDuoTimeLogBudget = 4;
static int gDuoBatteryLogBudget = 6;
static int gDuoIconLogBudget = 6;
static int gDuoDumpBudget = 1;
static int gDuoRowDumpBudget = 1;
static int gDuoHideRevision = 0;
static BOOL gClockHooksInstalled = NO;

static BOOL sp_class_has_prefix(id obj, NSString *prefix) {
    NSString *cls = NSStringFromClass([obj class]);
    return cls && [cls hasPrefix:prefix];
}

// 9:41 / 09:41 / 9:41 AM / 9:41:05 都算时间；"18°"、"5G"、"11月23日" 不算。
static BOOL sp_text_is_clock_time(NSString *t) {
    if (![t isKindOfClass:[NSString class]]) return NO;
    if (t.length < 3 || t.length > 10) return NO;
    NSUInteger digits = 0, colons = 0;
    for (NSUInteger i = 0; i < t.length; i++) {
        unichar c = [t characterAtIndex:i];
        if (c >= '0' && c <= '9') { digits++; continue; }
        if (c == ':' || c == 0xFF1A) { colons++; continue; }
        if (c == ' ' || c == 'A' || c == 'P' || c == 'M'
            || c == 'a' || c == 'p' || c == 'm') continue;
        return NO;
    }
    return (colons == 1 || colons == 2) && digits >= 3 && digits <= 6;
}

static BOOL sp_view_inside_status_bar(UIView *v) {
    UIView *cur = v;
    for (int i = 0; i < 4 && cur; i++) {
        NSString *cls = NSStringFromClass([cur class]);
        if ([cls containsString:@"StatusBar"] || [cls containsString:@"STUI"]) return YES;
        cur = cur.superview;
    }
    return NO;
}

// 圆环整行：从读数容器往上找“宽度至少半屏、高度不是整页”的最大容器。
// 实测读数小栈只有 106x88，直接拿它当圆环会把电量塞进环内。
static UIView *sp_duo_anchor_view(UIView *from) {
    CGSize screen = [UIScreen mainScreen].bounds.size;
    UIView *best = nil;
    CGFloat bestArea = 0;
    UIView *cur = from;
    for (int i = 0; i < 8 && cur; i++) {
        CGSize s = cur.bounds.size;
        BOOL fullPage = (s.height >= screen.height * 0.6);
        if (!fullPage && s.width >= screen.width * 0.5 && s.height >= 60) {
            CGFloat area = s.width * s.height;
            if (area > bestArea) { bestArea = area; best = cur; }
        }
        cur = cur.superview;
    }
    return best;
}

static void sp_locate_duo_anchor(void) {
    UIView *from = gDataContainer ? (UIView *)gDataContainer : (UIView *)gDataLabel;
    if (!from) return;
    UIView *anchor = sp_duo_anchor_view(from);
    if (!anchor) anchor = (UIView *)gDataContainer;
    if (!anchor || anchor == gDuoAnchorView) return;
    gDuoAnchorView = anchor;
    if (gDuoBatteryLogBudget > 0) {
        gDuoBatteryLogBudget--;
        sp_log(@"duo anchor %@ %.0fx%.0f win=%@", NSStringFromClass([anchor class]),
               anchor.bounds.size.width, anchor.bounds.size.height,
               anchor.window ? NSStringFromClass([anchor.window class]) : @"(nil)");
    }
    // 换容器（Solo 重建/上浮）时立刻补一次隐藏，别等下一个 1s tick。
    if (!gShowDuoTime) sp_apply_duo_time_visibility();
    if (gHideDuoIcons) sp_apply_duo_icons();
}

// IOKit.ps 兜底（SpringBoard 里 UIDevice.batteryLevel 可能返回 -1）；不新增链接依赖。
typedef CFTypeRef (*spIOPSInfoFn)(void);
typedef CFArrayRef (*spIOPSListFn)(CFTypeRef);
typedef CFDictionaryRef (*spIOPSDescFn)(CFTypeRef, CFTypeRef);

static void sp_read_battery_level(void) {
    gBatteryPct = -1;
    gBatteryCharging = NO;
    UIDevice *dev = [UIDevice currentDevice];
    if (!dev.batteryMonitoringEnabled) dev.batteryMonitoringEnabled = YES;
    float lvl = dev.batteryLevel;
    if (lvl >= 0.0f) {
        gBatteryPct = (int)lroundf(lvl * 100.0f);
        UIDeviceBatteryState st = dev.batteryState;
        gBatteryCharging = (st == UIDeviceBatteryStateCharging
                            || st == UIDeviceBatteryStateFull);
    }
    if (gBatteryPct < 0) {
        static spIOPSInfoFn infoFn = NULL;
        static spIOPSListFn listFn = NULL;
        static spIOPSDescFn descFn = NULL;
        static BOOL resolved = NO;
        if (!resolved) {
            resolved = YES;
            void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
            if (h) {
                infoFn = (spIOPSInfoFn)dlsym(h, "IOPSCopyPowerSourcesInfo");
                listFn = (spIOPSListFn)dlsym(h, "IOPSCopyPowerSourcesList");
                descFn = (spIOPSDescFn)dlsym(h, "IOPSGetPowerSourceDescription");
            }
            if (!infoFn || !listFn || !descFn) {
                sp_log(@"battery: IOKit.ps unavailable");
            }
        }
        if (infoFn && listFn && descFn) {
            CFTypeRef blob = infoFn();
            if (blob) {
                CFArrayRef list = listFn(blob);
                if (list) {
                    for (CFIndex i = 0; i < CFArrayGetCount(list); i++) {
                        CFDictionaryRef d = descFn(blob, CFArrayGetValueAtIndex(list, i));
                        if (!d) continue;
                        int cap = -1, maxc = -1;
                        CFNumberRef cRef = (CFNumberRef)CFDictionaryGetValue(
                            d, CFSTR("Current Capacity"));
                        CFNumberRef mRef = (CFNumberRef)CFDictionaryGetValue(
                            d, CFSTR("Max Capacity"));
                        if (cRef) CFNumberGetValue(cRef, kCFNumberIntType, &cap);
                        if (mRef) CFNumberGetValue(mRef, kCFNumberIntType, &maxc);
                        CFBooleanRef chg = (CFBooleanRef)CFDictionaryGetValue(
                            d, CFSTR("Is Charging"));
                        if (chg) gBatteryCharging = CFBooleanGetValue(chg);
                        if (cap >= 0 && maxc > 0) {
                            gBatteryPct = (int)lround(100.0 * (double)cap / (double)maxc);
                            break;
                        }
                    }
                    CFRelease(list);
                }
                CFRelease(blob);
            }
        }
    }
    gBatteryReadAt = CFAbsoluteTimeGetCurrent();
}

static UILabel *sp_duo_battery_label(void) {
    if (gDuoBatteryLabel) return gDuoBatteryLabel;
    UILabel *lab = [[UILabel alloc] initWithFrame:CGRectZero];
    lab.textAlignment = NSTextAlignmentCenter;
    lab.adjustsFontSizeToFitWidth = YES;
    lab.minimumScaleFactor = 0.75;
    lab.userInteractionEnabled = NO;
    lab.backgroundColor = [UIColor clearColor];
    lab.textColor = [UIColor secondaryLabelColor];
    gDuoBatteryLabel = lab;
    return lab;
}

// 跟 Duo 读数同字族/字重：直接取 5G 标签的 font 缩一档，避免“粗细不一致”。
static void sp_style_battery_label(UILabel *lab) {
    UILabel *data = gDataLabel;
    UIFont *base = data ? ((UIFont *(*)(id, SEL))objc_msgSend)(data, @selector(font)) : nil;
    CGFloat size = base ? base.pointSize * 0.95 : 13.0;
    if (size < 11.0) size = 11.0;
    if (size > 17.0) size = 17.0;
    UIFont *font = base ? [base fontWithSize:size]
                        : [UIFont monospacedDigitSystemFontOfSize:size
                                                          weight:UIFontWeightSemibold];
    if (font && ![font isEqual:lab.font]) lab.font = font;
}

static void sp_apply_duo_battery(void) {
    UILabel *lab = gDuoBatteryLabel;
    if (!gShowDuo || !gShowDuoBattery) {
        if (lab) lab.hidden = YES;
        return;
    }
    lab = sp_duo_battery_label();
    UIView *anchor = gDuoAnchorView;
    if (!anchor || !anchor.window) {
        lab.hidden = YES;
        return;
    }
    // 轮播切到时钟页时 Duo 会上浮；借位置变化把两层结构打出来（最多 3 次），
    // 用来抓“模糊时间复现”到底是谁画的。
    {
        static CGPoint lastCenter = {0, 0};
        static int floatDumpBudget = 3;
        CGPoint c = anchor.center;
        if (floatDumpBudget > 0 && lastCenter.y > 0.0 && fabs(c.y - lastCenter.y) > 20.0) {
            floatDumpBudget--;
            sp_log(@"duo float dy=%.0f (dump)", c.y - lastCenter.y);
            sp_dump_view_level(anchor, 0, 2);
            sp_dump_view_level(anchor.superview, 0, 2);
            sp_dump_layer_level(anchor.layer, 0, 2);
            sp_apply_duo_time_visibility();
            sp_apply_duo_icons();
        }
        lastCenter = c;
    }
    NSTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (gBatteryPct < 0 || now - gBatteryReadAt > 10.0) sp_read_battery_level();
    sp_style_battery_label(lab);

    if (gBatteryPct < 0) {
        lab.text = @"--";
        lab.textColor = [UIColor secondaryLabelColor];
    } else {
        lab.text = [NSString stringWithFormat:@"%d%%", gBatteryPct];
        if (gBatteryCharging) lab.textColor = [UIColor systemGreenColor];
        else if (gBatteryPct <= 20) lab.textColor = [UIColor systemRedColor];
        else lab.textColor = [UIColor labelColor];
    }

    // 与 Duo 容器同一层、按容器 frame 居中；宽度收到 64，避免右侧空间不足时被夹回左边。
    UIView *host = anchor.superview ?: anchor;
    CGRect ar = (host == anchor) ? anchor.bounds : anchor.frame;
    CGFloat w = 64.0, h = 22.0;
    CGFloat x = CGRectGetMidX(ar) - w * 0.5;
    CGFloat y = CGRectGetMaxY(ar) + 2.0 + (CGFloat)gDuoBatteryOffset;
    CGFloat maxY = CGRectGetMaxY(host.bounds) - h - 1.0;
    if (y > maxY) y = MAX(1.0, maxY);
    if (y < 1.0) y = 1.0;

    if (lab.superview != host) {
        [lab removeFromSuperview];
        [host addSubview:lab];
    }
    lab.frame = CGRectMake(x, y, w, h);
    lab.hidden = NO;
    [host bringSubviewToFront:lab];

    if (host != gDuoBatteryHost) {
        gDuoBatteryHost = host;
        if (gDuoBatteryLogBudget > 0) {
            gDuoBatteryLogBudget--;
            sp_log(@"battery host %@ anchor=%.0fx%.0f at %.0f,%.0f -> frame %.0f,%.0f off=%.0f pct=%d chg=%d",
                   NSStringFromClass([host class]), ar.size.width, ar.size.height,
                   ar.origin.x, ar.origin.y, x, y, gDuoBatteryOffset, gBatteryPct, gBatteryCharging);
        }
    }
}

static char spDuoTimeHiddenKey = 0;
static char spDuoIconHiddenKey = 0;

static void sp_dump_view_level(UIView *v, int depth, int maxDepth) {
    if (!v || depth > maxDepth) return;
    NSMutableString *line = [NSMutableString string];
    for (int i = 0; i < depth; i++) [line appendString:@"  "];
    NSString *extra = @"";
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = ((UILabel *)v).text;
        if (t.length) extra = [NSString stringWithFormat:@" text=%@", t];
    }
    [line appendFormat:@"%@ %.0fx%.0f @%.0f,%.0f%@", NSStringFromClass([v class]),
        v.frame.size.width, v.frame.size.height, v.frame.origin.x, v.frame.origin.y, extra];
    sp_log(@"  %@", line);
    if (depth == maxDepth) return;
    NSUInteger n = 0;
    for (UIView *sub in v.subviews) {
        if (n++ >= 12) {
            sp_log(@"  (… %lu more)", (unsigned long)(v.subviews.count - 12));
            break;
        }
        sp_dump_view_level(sub, depth + 1, maxDepth);
    }
}

static void sp_dump_layer_level(CALayer *l, int depth, int maxDepth) {
    if (!l || depth > maxDepth) return;
    NSMutableString *line = [NSMutableString string];
    for (int i = 0; i < depth; i++) [line appendString:@"  "];
    [line appendFormat:@"layer %@ %@ %.0fx%.0f", NSStringFromClass([l class]),
        l.name ?: @"", l.bounds.size.width, l.bounds.size.height];
    sp_log(@"  %@", line);
    for (CALayer *sub in l.sublayers) sp_dump_layer_level(sub, depth + 1, maxDepth);
}

// Solo 的玻璃背板会缓存一层模糊快照；改完文字后让它重新布局，避免旧快照里带着时间。
static void sp_refresh_duo_glass(UIView *root) {
    if (!root) return;
    for (UIView *sub in root.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        if ([cls hasPrefix:@"UnduoGlass"] || [cls containsString:@"Backdrop"]
            || [cls containsString:@"Blur"]) {
            [sub setNeedsLayout];
            [sub layoutIfNeeded];
        }
        sp_refresh_duo_glass(sub);
    }
}

// 只认 Duo 容器内部的时间文字（实测是容器顶部 106x22 的普通 UILabel）。
// 不去动 UnduoClockMirroredLabel：那是轮播时钟页的字，关了会把大时钟一起干掉。
static void sp_walk_duo_time(UIView *v, BOOL hide, UIView *anchor) {
    for (UIView *sub in v.subviews) {
        if (!hide && objc_getAssociatedObject(sub, &spDuoTimeHiddenKey)) {
            sub.hidden = NO;
            sub.alpha = 1.0;
            objc_setAssociatedObject(sub, &spDuoTimeHiddenKey, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!hide && [sub isKindOfClass:[UILabel class]]) {
            NSString *stored = objc_getAssociatedObject(sub, &spDuoTimeTextKey);
            if (stored) {
                ((void (*)(id, SEL, id))objc_msgSend)(sub, @selector(setText:), stored);
                objc_setAssociatedObject(sub, &spDuoTimeTextKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        if (hide && [sub isKindOfClass:[UILabel class]]) {
            UILabel *lab = (UILabel *)sub;
            BOOL marked = objc_getAssociatedObject(lab, &spDuoTimeHiddenKey) != nil;
            BOOL inAnchor = (anchor != nil && [sub isDescendantOfView:anchor]);
            BOOL match = (marked || (inAnchor && sp_text_is_clock_time(lab.text)));
            if (match) {
                NSString *curText = lab.text;
                lab.hidden = YES;
                lab.alpha = 0.0;
                if (!marked) {
                    objc_setAssociatedObject(lab, &spDuoTimeHiddenKey, @YES,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    // 已存在的标签也把文字清掉：快照/玻璃层抓不到时间
                    if (curText.length > 0) {
                        objc_setAssociatedObject(lab, &spDuoTimeTextKey, curText,
                                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                        if (sp_orig_label_setText) {
                            sp_orig_label_setText(lab, @selector(setText:), @"");
                        }
                    }
                    if (gDuoTimeLogBudget > 0) {
                        gDuoTimeLogBudget--;
                        sp_log(@"duo time hide %@ text=%@ %.0fx%.0f",
                               NSStringFromClass([lab class]), curText,
                               lab.frame.size.width, lab.frame.size.height);
                    }
                    gDuoHideRevision++;
                }
            }
        }
        sp_walk_duo_time(sub, hide, anchor);
    }
}

static void sp_apply_duo_time_visibility(void) {
    BOOL hide = !gShowDuoTime;
    UIView *anchor = gDuoAnchorView;
    @autoreleasepool {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            NSString *wc = NSStringFromClass([w class]);
            if (![wc containsString:@"HomeScreen"]) continue;
            sp_walk_duo_time(w, hide, anchor);
        }
    }
    // 有新标签被清空时，让玻璃背板重排一次，别留旧快照里的模糊时间。
    static int seenRevision = 0;
    if (hide && anchor && gDuoHideRevision != seenRevision) {
        seenRevision = gDuoHideRevision;
        sp_refresh_duo_glass(anchor.superview ?: anchor);
    }
}

// Duo 下方的小图标（定位箭头/装饰点等）：只认锚定容器内、读数下方、44pt 以内的图片类视图。
static void sp_walk_duo_icons(UIView *v, BOOL hide, CGRect dataWin) {
    for (UIView *sub in v.subviews) {
        NSString *cls = NSStringFromClass([sub class]);
        BOOL imageish = [sub isKindOfClass:[UIImageView class]]
            || [cls containsString:@"Image"] || [cls containsString:@"Icon"];
        if (imageish) {
            if (hide) {
                CGRect r = [sub convertRect:sub.bounds toView:nil];
                BOOL below = CGRectIsNull(dataWin)
                    || (CGRectGetMinY(r) >= CGRectGetMaxY(dataWin) - 8.0);
                BOOL small = (r.size.width <= 44.0 && r.size.height <= 44.0);
                if (below && small) {
                    sub.hidden = YES;
                    sub.alpha = 0.0;
                    objc_setAssociatedObject(sub, &spDuoIconHiddenKey, @YES,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (gDuoIconLogBudget > 0) {
                        gDuoIconLogBudget--;
                        sp_log(@"duo icon hide %@ %.0fx%.0f at %.0f,%.0f",
                               cls, r.size.width, r.size.height, r.origin.x, r.origin.y);
                    }
                }
            } else if (objc_getAssociatedObject(sub, &spDuoIconHiddenKey)) {
                sub.hidden = NO;
                sub.alpha = 1.0;
                objc_setAssociatedObject(sub, &spDuoIconHiddenKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        sp_walk_duo_icons(sub, hide, dataWin);
    }
}

static void sp_apply_duo_icons(void) {
    UIView *anchor = gDuoAnchorView;
    if (!anchor) return;
    if (gDuoRowDumpBudget > 0) {
        gDuoRowDumpBudget--;
        sp_log(@"duo row dump %@:", NSStringFromClass([anchor class]));
        sp_dump_view_level(anchor, 0, 2);
    }
    CGRect dataWin = CGRectNull;
    UILabel *data = gDataLabel;
    if (data && data.window) dataWin = [data convertRect:data.bounds toView:nil];
    sp_walk_duo_icons(anchor, gHideDuoIcons, dataWin);
}

#pragma mark - Solo 面板注入（Settings 进程）

static void sp_plog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[Solo+] %@", body);
    NSString *line = [NSString stringWithFormat:@"[Solo+] %@", body];
    line = [line stringByAppendingString:@"\n"];
    const char *utf8 = line.UTF8String;
    if (!utf8) return;
    int fd = open("/tmp/SoloPlusPrefs.log", O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) { write(fd, utf8, strlen(utf8)); close(fd); }
}

static NSArray *(*sp_orig_loadSpecs)(id, SEL, NSString *, id) = NULL;
static BOOL sp_injecting = NO;

static NSArray *sp_loadSpecs_hook(id self, SEL _cmd, NSString *name, id target) {
    NSArray *base = sp_orig_loadSpecs ? sp_orig_loadSpecs(self, _cmd, name, target) : nil;
    @autoreleasepool {
        if (![name isEqualToString:@"Root"]) {
            if ([name hasPrefix:@"SoloPlus"]) {
                NSString *bpath = @"(nil)";
                @try { bpath = [[self bundle] bundlePath] ?: @"(nil)"; } @catch (__unused NSException *e) {}
                sp_plog(@"panel load %@ on %@ -> %lu specs, bundle=%@",
                        name, NSStringFromClass([self class]),
                        (unsigned long)base.count, bpath);
            }
            return base;
        }
        if (![NSStringFromClass([self class]) isEqualToString:@"SOLRootListController"]) return base;
        if (sp_injecting || !base) return base;
        sp_injecting = YES;
        NSArray *extra = sp_orig_loadSpecs(self, _cmd, @"SoloPlus", target);
        sp_injecting = NO;
        if (extra.count == 0) {
            sp_plog(@"SoloPlus.plist not found in SoloPrefs.bundle");
            return base;
        }
        NSMutableArray *out = [base mutableCopy];
        NSUInteger idx = out.count;
        NSArray *anchors = @[@"调整兼容性", @"高级", @"故障排除"];
        for (NSString *anchor in anchors) {
            BOOL found = NO;
            for (NSUInteger i = 0; i < out.count; i++) {
                id label = ((id (*)(id, SEL, id))objc_msgSend)(out[i],
                                @selector(propertyForKey:), @"label");
                if ([label isKindOfClass:[NSString class]] && [label isEqualToString:anchor]) {
                    idx = i; found = YES; break;
                }
            }
            if (found) break;
        }
        for (id spec in extra) { [out insertObject:spec atIndex:idx]; idx++; }
        sp_plog(@"injected %lu Solo+ specifiers at %lu",
                (unsigned long)extra.count, (unsigned long)(idx - extra.count));
        return out;
    }
}

static void sp_install_prefs_hooks(void) {
    static BOOL installed = NO;
    if (installed) return;
    Class plc = NSClassFromString(@"PSListController");
    if (!plc) return;
    MSHookMessageEx(plc, @selector(loadSpecifiersFromPlistName:target:),
                    (IMP)sp_loadSpecs_hook, (IMP *)&sp_orig_loadSpecs);
    installed = YES;
    sp_plog(@"hooked PSListController in Preferences");
}

static void sp_prefs_retry_cb(CFRunLoopTimerRef timer, void *info) {
    sp_install_prefs_hooks();
    if (sp_orig_loadSpecs) {
        CFRunLoopTimerInvalidate(timer);
        CFRunLoopRemoveTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
        CFRelease(timer);
    }
}

static void sp_schedule_prefs_retry(void) {
    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef t = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                               CFAbsoluteTimeGetCurrent() + 1.0,
                                               1.0, 0, 0, sp_prefs_retry_cb, &ctx);
    if (t) CFRunLoopAddTimer(CFRunLoopGetMain(), t, kCFRunLoopCommonModes);
}

#pragma mark - 通知 / 入口

static void sp_notify_cb(CFNotificationCenterRef center, void *observer,
                         CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    sp_load_prefs();
    {
        static int reloadBudget = 3;
        if (reloadBudget > 0) {
            reloadBudget--;
            sp_log(@"prefs reload: duo=%d", gShowDuo);
        }
    }
    sp_refresh_carousel();
    if (gKeepStatusBar) sp_force_show_all();
    sp_apply_data_label_live();
    sp_apply_duo_visibility();
    sp_locate_duo_anchor();
    sp_apply_duo_time_visibility();
    sp_apply_duo_battery();
    sp_apply_duo_icons();
    sp_scan_data_labels();
}

static void sp_register_notifications(void) {
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(c, NULL, sp_notify_cb,
                                    CFSTR("com.chenlin8023.soloplus/reload"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

%ctor {
    @autoreleasepool {
        NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if ([bundleId isEqualToString:@"com.apple.Preferences"]) {
            sp_install_prefs_hooks();
            if (!sp_orig_loadSpecs) sp_schedule_prefs_retry();
            return;
        }
        [[NSFileManager defaultManager]
            createDirectoryAtPath:@"/var/jb/var/mobile/Library/Preferences/Solo/Logs"
            withIntermediateDirectories:YES attributes:nil error:nil];
        sp_load_prefs();
        sp_log(@"loaded (keep=%d duo=%d time=%d batt=%d dataScale=%.2f weight=%.0f)",
               gKeepStatusBar, gShowDuo, gShowDuoTime, gShowDuoBattery,
               gDataFontScale, gDataFontWeight);
        sp_log(@"duo extras: batteryOffset=%.0f hideIcons=%d", gDuoBatteryOffset, gHideDuoIcons);
        sp_install_status_hooks();
        sp_install_dock_hooks();
        sp_install_data_hook();
        sp_install_carousel_hooks();
        sp_schedule_data_scan();
        sp_schedule_evict(3.0);
        if (!sp_install_dock_hooks()) sp_schedule_dock_retry();
        sp_register_notifications();
        if (!gStatusHooksInstalled) sp_schedule_status_retry();
        else sp_force_show_all();
    }
}
