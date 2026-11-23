// SPDX-License-Identifier: MIT
// Solo+ 1.0.0 — 状态栏 / Duo 展示 / 数据标识 / 轮播铺满 / Dockicon（内容缩放、6 图标、自动迁回）
// 伴随 Solo.dylib 注入 SpringBoard；Settings 进程只负责把 Solo+ 分组注入 Solo 面板。

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <pthread.h>
#include <math.h>

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
static double gDataFontScale = 1.0;
static double gDataFontWeight = 0.0; // 0=跟随 1=细 2=常规 3=中粗 4=粗
static double gDockMaxIcons = 5.0;
static double gDockIconScale = 1.0;
static BOOL gDockAutoShift = YES;
static BOOL gCarouselFill = YES;

static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;
static int gBlockedLogBudget = 3;

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
    gDataFontScale = sp_read_double(kDataFontScaleKey, 1.0);
    if (gDataFontScale < 0.6) gDataFontScale = 0.6;
    if (gDataFontScale > 1.8) gDataFontScale = 1.8;
    gDataFontWeight = sp_read_double(kDataFontWeightKey, 0.0);
    gDockMaxIcons = sp_read_double(@"soloPlusDockMaxIcons", 5.0);
    if (gDockMaxIcons < 5.0) gDockMaxIcons = 5.0;
    if (gDockMaxIcons > 7.0) gDockMaxIcons = 7.0;
    gDockIconScale = sp_read_double(@"soloPlusDockIconScale", 1.0);
    if (gDockIconScale < 0.7) gDockIconScale = 0.7;
    if (gDockIconScale > 1.0) gDockIconScale = 1.0;
    gDockAutoShift = sp_read_bool(@"soloPlusDockAutoShift", YES);
    gCarouselFill = sp_read_bool(@"soloPlusCarouselFill", YES);
}

#pragma mark - 调用方镜像判定

static BOOL sp_caller_is_solo(void *ret) {
    Dl_info info;
    if (!dladdr(ret, &info) || !info.dli_fname) return NO;
    return strstr(info.dli_fname, "Solo.dylib") != NULL;
}

#pragma mark - 状态栏

static BOOL sp_window_is_home_context(UIWindow *window) {
    if (!window) return NO;
    NSString *cls = NSStringFromClass([window class]);
    return [cls isEqualToString:@"SBStatusBarWindow"] || [cls isEqualToString:@"SBHomeScreenWindow"];
}

static BOOL sp_is_statusbar_foreground(UIView *view) {
    NSString *cls = NSStringFromClass([view class]);
    return [cls isEqualToString:@"_UIStatusBarForegroundView"]
        || [cls isEqualToString:@"STUIStatusBarForegroundView"];
}

static void sp_force_show_view(UIView *view) {
    if (!view) return;
    if (sp_is_statusbar_foreground(view)) {
        if (view.alpha < 0.01f) view.alpha = 1.0f;
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

static void (*sp_orig_setAlpha_ui)(id, SEL, CGFloat) = NULL;
static void (*sp_orig_setAlpha_st)(id, SEL, CGFloat) = NULL;

static void sp_common_set_alpha(id self, SEL _cmd, CGFloat alpha,
                                void (*orig)(id, SEL, CGFloat)) {
    if (!orig) return;
    if (gKeepStatusBar && alpha < 0.01f) {
        UIView *view = (UIView *)self;
        UIWindow *win = view.window;
        if (sp_window_is_home_context(win)) {
            if (gBlockedLogBudget > 0) {
                gBlockedLogBudget--;
                sp_log(@"blocked statusbar hide in %@", NSStringFromClass([win class]));
            }
            orig(self, _cmd, 1.0f);
            return;
        }
    }
    orig(self, _cmd, alpha);
}

static void sp_setAlpha_ui(id self, SEL _cmd, CGFloat alpha) {
    sp_common_set_alpha(self, _cmd, alpha, sp_orig_setAlpha_ui);
}
static void sp_setAlpha_st(id self, SEL _cmd, CGFloat alpha) {
    sp_common_set_alpha(self, _cmd, alpha, sp_orig_setAlpha_st);
}

static BOOL gStatusHooksInstalled = NO;

static void sp_install_status_hooks(void) {
    if (gStatusHooksInstalled) return;
    SEL sel = @selector(setAlpha:);
    Class ui = objc_getClass("_UIStatusBarForegroundView");
    Class st = objc_getClass("STUIStatusBarForegroundView");
    BOOL any = NO;
    if (ui) { MSHookMessageEx(ui, sel, (IMP)sp_setAlpha_ui, (IMP *)&sp_orig_setAlpha_ui); any = YES; }
    if (st) { MSHookMessageEx(st, sel, (IMP)sp_setAlpha_st, (IMP *)&sp_orig_setAlpha_st); any = YES; }
    gStatusHooksInstalled = any;
    if (any) sp_log(@"statusbar hooks installed");
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


#pragma mark - Dock（图标上限 / 大小 / 自动下移）

static char spModelLocationKey = 0;
static char spDockImageBaseKey = 0;
static char spDockImageScaleKey = 0;
static NSHashTable *gDockImageViews = nil;
static __weak id gDockListView = nil;
static int gDockModelLogBudget = 4;
static int gDockScaleLogBudget = 6;

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

static NSString *sp_model_location(id model) {
    if (!model) return nil;
    id loc = objc_getAssociatedObject(model, &spModelLocationKey);
    if (![loc isKindOfClass:[NSString class]]) {
        SEL s = NSSelectorFromString(@"_atriaLocation");
        if ([model respondsToSelector:s]) {
            loc = ((id (*)(id, SEL))objc_msgSend)(model, s);
        }
    }
    return [loc isKindOfClass:[NSString class]] ? loc : nil;
}

static id sp_dock_model(void) {
    id list = gDockListView;
    if (list && [list respondsToSelector:@selector(model)]) {
        return ((id (*)(id, SEL))objc_msgSend)(list, @selector(model));
    }
    return nil;
}

static BOOL sp_model_is_dock(id model) {
    // 以 Dock 列表当前的 model 指针为准；文件夹内部模型即使 location
    // 字符串里带 Dock，也不会被误判、误改 gridSize/容量。
    id dm = sp_dock_model();
    if (dm) return model == dm;
    NSString *loc = sp_model_location(model);
    return loc && [loc containsString:@"Dock"];
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
    sp_mark_model_location(model, @"SBIconLocationDock");
}

static NSUInteger (*sp_orig_dock_max)(id, SEL) = NULL;
static NSUInteger (*sp_orig_dock_rows)(id, SEL) = NULL;
static void (*sp_orig_dock_layoutIconsNow)(id, SEL) = NULL;
static void (*sp_orig_dock_layoutSubviews)(id, SEL) = NULL;
static BOOL spApplyingDockListScale = NO;
static void (*sp_orig_dock_setCenter)(id, SEL, CGPoint) = NULL;
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
static void (*sp_orig_view_setTransform)(id, SEL, CGAffineTransform) = NULL;
static void (*sp_orig_layer_addAnimation)(id, SEL, CAAnimation *, NSString *) = NULL;
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
        } else {
            if (g.width >= g.height) {
                if (g.width < want) g.width = want;
            } else {
                if (g.height < want) g.height = want;
            }
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
        // 与 Atria 对 root 的处理一致：先让模型不要用“满槽”挡住投放，
        // 真正的上限由 maxNumberOfIcons 卡住。
        return NSUIntegerMax;
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
    if (gDockMaxIcons >= 5.5 && sp_model_is_dock(self)
        && sp_model_icon_count(self) < (NSUInteger)gDockMaxIcons
        && sp_icon_is_app(icon)) {
        base = YES;
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
    id result = sp_orig_model_insert ? sp_orig_model_insert(self, _cmd, icon, idx) : nil;
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
    id result = sp_orig_model_insertMany
        ? sp_orig_model_insertMany(self, _cmd, icons, idx, options) : nil;
    if (gDockMaxIcons >= 5.5 && sp_model_is_dock(self) && gDockDropLogBudget > 0) {
        gDockDropLogBudget--;
        sp_log(@"dock insertIcons: idx=%lu count=%lu -> %lu options=%lu result=%p",
               (unsigned long)idx, (unsigned long)before,
               (unsigned long)sp_model_icon_count(self), (unsigned long)options,
               (__bridge void *)result);
    }
    return result;
}

static BOOL sp_tf_close(CGAffineTransform a, CGAffineTransform b) {
    return fabs(a.a - b.a) < 1e-4 && fabs(a.b - b.b) < 1e-4
        && fabs(a.c - b.c) < 1e-4 && fabs(a.d - b.d) < 1e-4
        && fabs(a.tx - b.tx) < 1e-4 && fabs(a.ty - b.ty) < 1e-4;
}

static CGAffineTransform sp_tf_with_scale(CGAffineTransform base, CGFloat scale) {
    return CGAffineTransformConcat(base, CGAffineTransformMakeScale(scale, scale));
}

// 判断某个 view 是否是 Dock 图标内部的 _iconImageView。
static BOOL sp_is_dock_icon_image_view(UIView *v) {
    if (!v) return NO;
    NSString *cn = NSStringFromClass([v class]);
    UIView *sv = v.superview;
    NSString *sn = sv ? NSStringFromClass([sv class]) : nil;
    if (![cn containsString:@"Image"] && ![sn containsString:@"IconView"]) return NO;

    UIView *iconView = nil;
    UIView *p = sv;
    for (int i = 0; p && i < 4; i++) {
        if ([NSStringFromClass([p class]) containsString:@"IconView"]) {
            iconView = p;
            break;
        }
        p = p.superview;
    }
    if (!iconView) return NO;

    SEL locSel = @selector(location);
    if ([iconView respondsToSelector:locSel]) {
        id loc = ((id (*)(id, SEL))objc_msgSend)(iconView, locSel);
        if ([loc isKindOfClass:[NSString class]] && [loc containsString:@"Dock"]) {
            return YES;
        }
    }
    SEL iconSel = @selector(icon);
    if ([iconView respondsToSelector:iconSel]) {
        id icon = ((id (*)(id, SEL))objc_msgSend)(iconView, iconSel);
        if (icon && [icon respondsToSelector:locSel]) {
            id loc = ((id (*)(id, SEL))objc_msgSend)(icon, locSel);
            if ([loc isKindOfClass:[NSString class]] && [loc containsString:@"Dock"]) {
                return YES;
            }
        }
    }
    UIView *q = iconView.superview;
    while (q) {
        if ([NSStringFromClass([q class]) isEqualToString:@"SBDockIconListView"]) return YES;
        q = q.superview;
    }
    return NO;
}

static void sp_view_setTransform(id self, SEL _cmd, CGAffineTransform t) {
    if ([self isKindOfClass:[UIView class]] && sp_is_dock_icon_image_view((UIView *)self)) {
        if (!gDockImageViews) gDockImageViews = [NSHashTable weakObjectsHashTable];
        [gDockImageViews addObject:self];

        CGAffineTransform base = t;
        NSValue *oldBaseV = objc_getAssociatedObject(self, &spDockImageBaseKey);
        if (oldBaseV) {
            CGAffineTransform oldBase;
            [oldBaseV getValue:&oldBase];
            // 只接受 Solo 的正常基准（约 0.83）或旧基准；动画中间值不覆盖基准，
            // 否则会出现 0.829 -> 0.704 -> 0.599 -> 0.433 的连环缩小。
            if (t.a >= 0.75 || sp_tf_close(t, oldBase)) base = t;
            else base = oldBase;
        }
        if (base.a < 0.1) base = CGAffineTransformIdentity;
        objc_setAssociatedObject(self, &spDockImageBaseKey,
                                 [NSValue valueWithCGAffineTransform:base],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(self, &spDockImageScaleKey, @(gDockIconScale),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGAffineTransform out = sp_tf_with_scale(base, gDockIconScale);
        if (gDockScaleLogBudget > 0) {
            gDockScaleLogBudget--;
            sp_log(@"dock icon image scale: cls=%@ base=%.3f -> %.3f (slider=%.2f)",
                   NSStringFromClass([self class]), base.a, out.a, gDockIconScale);
        }
        if (sp_orig_view_setTransform) sp_orig_view_setTransform(self, _cmd, out);
        return;
    }
    if (sp_orig_view_setTransform) sp_orig_view_setTransform(self, _cmd, t);
}

static void sp_scale_dock_icon_view(UIView *iconView) {
    if (!iconView) return;
    SEL imgSel = @selector(_iconImageView);
    if (![iconView respondsToSelector:imgSel]) return;
    UIView *img = ((id (*)(id, SEL))objc_msgSend)(iconView, imgSel);
    if (!img) return;

    CGAffineTransform base;
    NSValue *baseV = objc_getAssociatedObject(img, &spDockImageBaseKey);
    if (baseV) {
        [baseV getValue:&base];
    } else {
        base = img.transform;
        if (base.a < 0.1) base = CGAffineTransformIdentity;
        objc_setAssociatedObject(img, &spDockImageBaseKey,
                                 [NSValue valueWithCGAffineTransform:base],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CGAffineTransform out = sp_tf_with_scale(base, gDockIconScale);
    if (sp_orig_view_setTransform) {
        sp_orig_view_setTransform(img, @selector(setTransform:), out);
    }
    objc_setAssociatedObject(img, &spDockImageScaleKey, @(gDockIconScale),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!gDockImageViews) gDockImageViews = [NSHashTable weakObjectsHashTable];
    [gDockImageViews addObject:img];
}

static void sp_apply_dock_scale_in_view(UIView *v, int depth) {
    if (!v || depth > 3) return;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"IconView"]) {
        sp_scale_dock_icon_view(v);
        return;
    }
    for (UIView *sub in v.subviews) sp_apply_dock_scale_in_view(sub, depth + 1);
}

static UIView *sp_find_dock_list_in_view(UIView *v, int depth) {
    if (!v || depth > 6) return nil;
    if ([NSStringFromClass([v class]) isEqualToString:@"SBDockIconListView"]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = sp_find_dock_list_in_view(sub, depth + 1);
        if (r) return r;
    }
    return nil;
}

static void sp_apply_dock_scale_to_all(void) {
    id list = gDockListView;
    if (!list) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            UIView *found = sp_find_dock_list_in_view(w, 0);
            if (found) { list = found; gDockListView = found; break; }
        }
    }
    if (!list) return;
    sp_apply_dock_scale_in_view((UIView *)list, 0);
}

static void sp_apply_dock_content_scale_in_view(UIView *v, int depth) {
    if (!v || depth > 3) return;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"IconView"]) {
        SEL setSel = @selector(setIconContentScale:);
        SEL getSel = @selector(iconContentScale);
        if ([v respondsToSelector:setSel]) {
            CGFloat cur = 1.0;
            if ([v respondsToSelector:getSel]) {
                cur = ((CGFloat (*)(id, SEL))objc_msgSend)(v, getSel);
            }
            if (fabs(cur - gDockIconScale) > 0.001) {
                @try {
                    ((void (*)(id, SEL, CGFloat))objc_msgSend)(v, setSel, gDockIconScale);
                } @catch (__unused NSException *e) {}
            }
        }
        return;
    }
    for (UIView *sub in v.subviews) sp_apply_dock_content_scale_in_view(sub, depth + 1);
}

static void sp_apply_dock_list_scale(void) {
    id list = gDockListView;
    if (!list) {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            UIView *found = sp_find_dock_list_in_view(w, 0);
            if (found) { list = found; gDockListView = found; break; }
        }
    }
    if (!list || spApplyingDockListScale) return;
    // 只缩图标内容，不改 SBDockIconListView 的 frame/transform；
    // 这样打开 App/文件夹的动画落点仍按原始 Dock 几何计算，不会被二次纠正。
    spApplyingDockListScale = YES;
    sp_apply_dock_content_scale_in_view((UIView *)list, 0);
    spApplyingDockListScale = NO;
    if (gDockScaleLogBudget > 0) {
        gDockScaleLogBudget--;
        sp_log(@"dock icon content scale applied: %.2f (view=%@)",
               gDockIconScale, NSStringFromClass([list class]));
    }
}

static void sp_dock_layoutIconsNow(id self, SEL _cmd) {
    if (sp_orig_dock_layoutIconsNow) sp_orig_dock_layoutIconsNow(self, _cmd);
    sp_note_dock_list(self);
    sp_apply_dock_list_scale();
}

static void sp_dock_layoutSubviews(id self, SEL _cmd) {
    if (sp_orig_dock_layoutSubviews) sp_orig_dock_layoutSubviews(self, _cmd);
    sp_note_dock_list(self);
    sp_apply_dock_list_scale();
}

static void sp_reapply_dock_icon_scale(void) {
    sp_apply_dock_list_scale();
}

static id sp_scaled_catransform_value(id v, CGFloat scale) {
    if (![v isKindOfClass:[NSValue class]]) return v;
    CATransform3D t;
    [v getValue:&t];
    t = CATransform3DScale(t, scale, scale, 1.0);
    return [NSValue valueWithCATransform3D:t];
}

static void sp_layer_addAnimation(id self, SEL _cmd, CAAnimation *anim, NSString *key) {
    if (gDockIconScale < 0.999 && [key isEqualToString:@"UnduoDockScale"]
        && [anim isKindOfClass:[CABasicAnimation class]]) {
        CABasicAnimation *a = (CABasicAnimation *)anim;
        a.fromValue = sp_scaled_catransform_value(a.fromValue, gDockIconScale);
        a.toValue = sp_scaled_catransform_value(a.toValue, gDockIconScale);
        if (gDockScaleLogBudget > 0) {
            gDockScaleLogBudget--;
            sp_log(@"dock scale animation: from/to multiplied by %.2f", gDockIconScale);
        }
    }
    if (sp_orig_layer_addAnimation) sp_orig_layer_addAnimation(self, _cmd, anim, key);
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

static void sp_dock_setCenter(id self, SEL _cmd, CGPoint c) {
    if (gDockAutoShift && gDockMaxIcons >= 5.5 && sp_dock_icon_count(self) >= 6) {
        c.y += 12.0;
    }
    if (sp_orig_dock_setCenter) sp_orig_dock_setCenter(self, _cmd, c);
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
    MSHookMessageEx(dock, @selector(setCenter:), (IMP)sp_dock_setCenter, (IMP *)&sp_orig_dock_setCenter);
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

    // 图标缩放改由 SBDockIconListView 父层 transform 完成；不再逐图标 hook
    // UIView setTransform / CALayer addAnimation，避免重排时回弹与卡顿。

    installed = YES;
    sp_log(@"dock hooks installed (max=%.0f scale=%.2f shift=%d max=%d maxCount=%d free=%d grid=%d full=%d canAdd=%d canAddAt=%d insert=%d insertMany=%d anim=%d)",
           gDockMaxIcons, gDockIconScale, gDockAutoShift,
           sp_orig_model_max != NULL, sp_orig_model_maxCount != NULL,
           sp_orig_model_free != NULL, sp_orig_model_gridSize != NULL,
           sp_orig_model_isFull != NULL, sp_orig_model_canAdd != NULL,
           sp_orig_model_canAddAt != NULL, sp_orig_model_insert != NULL,
           sp_orig_model_insertMany != NULL, sp_orig_layer_addAnimation != NULL);
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

static void sp_label_setText(id self, SEL _cmd, NSString *text) {
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
    sp_refresh_carousel();
    if (gKeepStatusBar) sp_force_show_all();
    sp_apply_data_label_live();
    sp_reapply_dock_icon_scale();
    sp_apply_duo_visibility();
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
        sp_log(@"loaded (keep=%d duo=%d dataScale=%.2f weight=%.0f)",
               gKeepStatusBar, gShowDuo, gDataFontScale, gDataFontWeight);
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
