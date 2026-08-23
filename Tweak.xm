#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#import <notify.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "LiquidGlassView.h"

// =============================================================================
// Clock26 — 锁屏大时间「字体拉伸」小插件
//
// 原理：把锁屏时间数字换成 Apple 可变字体 axs66（内部 .SF Adaptive Soft Numeric，
// 已改名为 AXS66Clock 避免与系统冲突），并驱动它的可变轴：
//   · 大小(Size)  —— 在原始点数上乘一个倍数，整体放大（矢量，清晰不糊）
//   · 拉高(HGHT)  —— 纵向拉伸，数字变高（100..500）
//   · 宽度(wdth)  —— 横向宽窄，60=最窄、100=最宽（字体原生宽度轴，矢量变形）
//   · 粗细(wght)  —— 笔画粗细，1=最细、400=常规、1000=最粗（字体原生粗细轴）
//
// 位置：数字的「文字顶部」始终锚定在系统给的原始顶部（也就是日期正下方），随大小/
// 拉高只向下生长，绝不上顶、也不居中。之前"看着像屏幕居中"是因为把标签框撑得过高，
// 而 UILabel 默认会把文字纵向居中——文字就掉到大框中间去了。现在标签框贴合文字实际
// 尺寸、顶部锚定，文字就稳稳贴在日期下方，越大越往下长。
//
// 通知自适应：锁屏通知一多，系统会把时间容器压矮；我们检测到容器明显变矮（进入紧凑
// 态）就把时钟缩回接近原始大小，避免放大的数字被下面的通知盖住（阈值 kCompactRatio 可调）。
//
// 防裁剪：放大/拉高后字形会超出系统给的窄框，所以每次 layoutSubviews 里都沿祖先链
// 关掉 clipsToBounds / masksToBounds（并清掉最近几层 layer.mask），字形不会被时间
// 区域的边框裁掉。字体每次布局都重新贴回，系统刷新冲不掉；签名守卫让重复调用很廉价。
// =============================================================================

#pragma mark - Private framework stubs

typedef NS_OPTIONS(NSUInteger, SBSRelaunchActionOptions) {
    SBSRelaunchActionOptionsNone                  = 0,
    SBSRelaunchActionOptionsRestartRenderServer   = 1 << 0,
    SBSRelaunchActionOptionsFadeToBlackTransition = 1 << 1,
};

@interface NSObject (C26PrivateAPI)
+ (instancetype)actionWithReason:(NSString *)reason options:(SBSRelaunchActionOptions)options targetURL:(NSURL *)targetURL;
+ (instancetype)sharedService;
- (void)sendActions:(NSSet *)actions withResult:(id)result;
@end

#pragma mark - Constants

static NSString *const kPrefsDomain              = @"com.mcclock26.locktime";
static NSString *const kPrefsChangedNotification = @"com.mcclock26.locktime/prefsChanged";
static CFStringRef     kDoRespringNotification   = CFSTR("com.mcclock26.locktime/doRespring");

// The renamed family/PostScript name we ship (see rename_font.py).
static NSString *const kFontPSName = @"AXS66Clock";

// Variable-font axis identifiers (four-char codes as UInt32).
#define C26_FOURCC(a,b,c,d) (((UInt32)(a)<<24)|((UInt32)(b)<<16)|((UInt32)(c)<<8)|(UInt32)(d))
static const UInt32 kAxisHGHT = C26_FOURCC('H','G','H','T'); // height  100..500
static const UInt32 kAxisWDTH = C26_FOURCC('w','d','t','h'); // width    60..100
static const UInt32 kAxisWGHT = C26_FOURCC('w','g','h','t'); // weight    1..1000
static const UInt32 kAxisSOFT = C26_FOURCC('S','O','F','T'); // softness  0..100

#pragma mark - Preference values

static BOOL    pEnabled = YES;
static CGFloat pHeight  = 300.0f;  // HGHT axis value (100 = original, 500 = tallest)
static CGFloat pWidth   = 100.0f;  // wdth axis value (60 = narrowest, 100 = widest)
static CGFloat pWeight  = 400.0f;  // wght axis value (1 = thinnest, 400 = regular, 1000 = boldest)
static CGFloat pScale   = 1.0f;    // point-size multiplier (1.0 = original size)

// 液态玻璃效果参数
static BOOL    pGlassEnabled    = NO;    // 玻璃效果总开关（默认关）
static CGFloat pGlassBlur       = 20.0f; // 模糊半径 0-50
static CGFloat pGlassThickness  = 12.0f; // 玻璃厚度 0-30
static CGFloat pGlassRefraction = 1.0f;  // 折射强度 0-3
static CGFloat pGlassSpecular   = 0.6f;  // 高光不透明度 0-1
static CGFloat pGlassDispersion = 0.5f;  // 色散强度 0-1

// When the lock screen fills with notifications, the system compresses the
// prominent-time container. Below this fraction of the roomiest height we've seen
// we start easing the clock back toward its stock size so notifications don't
// bury an enlarged clock (see the layoutSubviews hook).
static const CGFloat kCompactFloor = 0.55f;

#pragma mark - Associated object keys

static char kC26OrigFontKey;   // UILabel -> original UIFont (to restore when off)
static char kC26SigKey;        // UILabel -> last-applied signature string
static char kC26OrigBoundsKey; // UILabel -> original FRAME (NSValue CGRect) reference
static char kC26MaxHKey;       // CSProminentTimeView -> max container height seen (NSNumber)
static char kC26GlassViewKey;  // CSProminentTimeView -> LiquidGlassView

#pragma mark - Runtime font state

static BOOL gFontRegistered = NO;

#pragma mark - Forward declarations

static void loadPrefs(void);
static void C26ReapplyAll(void);

#pragma mark - Preferences

static void loadPrefs(void) {
    // Flush cfprefs cache: Settings writes in a different process; without
    // synchronize, SpringBoard can read a stale snapshot and slider changes
    // silently fail to apply. Cheap and safe.
    CFPreferencesAppSynchronize((CFStringRef)kPrefsDomain);
    CFArrayRef keyList = CFPreferencesCopyKeyList(
        (CFStringRef)kPrefsDomain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keyList) {
        NSDictionary *prefs = (NSDictionary *)CFBridgingRelease(
            CFPreferencesCopyMultiple(keyList, (CFStringRef)kPrefsDomain,
                                      kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        CFRelease(keyList);
        if (prefs) {
            pEnabled = prefs[@"Enabled"] ? [prefs[@"Enabled"] boolValue]  : YES;
            pHeight  = prefs[@"Height"]  ? [prefs[@"Height"] floatValue]  : 300.0f;
            pWidth   = prefs[@"Width"]   ? [prefs[@"Width"] floatValue]   : 100.0f;
            pWeight  = prefs[@"Weight"]  ? [prefs[@"Weight"] floatValue]  : 400.0f;
            pScale   = prefs[@"Scale"]   ? [prefs[@"Scale"] floatValue]   : 1.0f;
            pGlassEnabled    = prefs[@"GlassEnabled"]    ? [prefs[@"GlassEnabled"] boolValue]    : NO;
            pGlassBlur       = prefs[@"GlassBlur"]       ? [prefs[@"GlassBlur"] floatValue]       : 20.0f;
            pGlassThickness  = prefs[@"GlassThickness"]  ? [prefs[@"GlassThickness"] floatValue]  : 12.0f;
            pGlassRefraction = prefs[@"GlassRefraction"] ? [prefs[@"GlassRefraction"] floatValue] : 1.0f;
            pGlassSpecular   = prefs[@"GlassSpecular"]   ? [prefs[@"GlassSpecular"] floatValue]   : 0.6f;
            pGlassDispersion = prefs[@"GlassDispersion"] ? [prefs[@"GlassDispersion"] floatValue] : 0.5f;
        }
    }
    pHeight = MAX(100.0f, MIN(500.0f,  pHeight));   // HGHT axis range
    pWidth  = MAX(60.0f,  MIN(100.0f,  pWidth));    // wdth axis range
    pWeight = MAX(1.0f,   MIN(1000.0f, pWeight));   // wght axis range
    pScale  = MAX(0.5f,   MIN(3.0f,    pScale));    // sane point-size multiplier
}

#pragma mark - Font install path resolution

// Find AXS66Clock.otf across rootful / rootless (/var/jb) / roothide (randomised
// jbroot). Strategy: ask dladdr for the ABSOLUTE path this code was loaded from,
// then walk up parent directories probing the two logical sub-paths the deb
// installs into. Anchoring on the real load path makes it work even when the
// jailbreak root is randomised (roothide), without hard-coding any prefix.
static NSString *C26FontPath(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *rels = @[ @"Library/MobileSubstrate/DynamicLibraries/AXS66Clock.otf",
                       @"Library/Application Support/McClock26/AXS66Clock.otf" ];

    Dl_info info; memset(&info, 0, sizeof(info));
    if (dladdr((const void *)&C26FontPath, &info) && info.dli_fname) {
        NSString *dir = [[NSString stringWithUTF8String:info.dli_fname]
                         stringByDeletingLastPathComponent];
        // co-located next to the dylib (rootful DynamicLibraries case)
        NSString *sibling = [dir stringByAppendingPathComponent:@"AXS66Clock.otf"];
        if ([fm fileExistsAtPath:sibling]) return sibling;
        // climb up to the jailbreak root and probe the logical install paths
        NSString *root = dir;
        for (int i = 0; i < 8 && root.length > 1; i++) {
            for (NSString *rel in rels) {
                NSString *cand = [root stringByAppendingPathComponent:rel];
                if ([fm fileExistsAtPath:cand]) return cand;
            }
            root = [root stringByDeletingLastPathComponent];
        }
    }
    // absolute fallbacks for the common schemes
    NSArray *roots = @[ @"", @"/var/jb", @"/var/LIB" ];
    for (NSString *r in roots) {
        for (NSString *rel in rels) {
            NSString *cand = [r stringByAppendingFormat:@"/%@", rel];
            if ([fm fileExistsAtPath:cand]) return cand;
        }
    }
    return nil;   // not found
}

// Register the shipped font with CoreText once, so UIFont(name:) can find it.
static void C26RegisterFontIfNeeded(void) {
    if (gFontRegistered) return;
    // Already available (e.g. re-registered by another process)?
    if ([UIFont fontWithName:kFontPSName size:12.0f]) { gFontRegistered = YES; return; }

    NSString *path = C26FontPath();
    if (!path) return;
    NSURL *url = [NSURL fileURLWithPath:path];
    CFErrorRef err = NULL;
    if (CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                         kCTFontManagerScopeProcess, &err)) {
        gFontRegistered = YES;
    } else {
        // "already registered" is fine — treat as success.
        if (err) {
            CFIndex code = CFErrorGetCode(err);
            if (code == kCTFontManagerErrorAlreadyRegistered) gFontRegistered = YES;
            CFRelease(err);
        }
    }
}

#pragma mark - Variable font construction

// Build an axs66 UIFont at the given point size, driving the HGHT (height),
// wdth (width) and wght (weight) axes; softness left at Apple's default. All
// three axes are native to the font, so the result stays razor-sharp vector art.
static UIFont *C26AxsFontOfSize(CGFloat size, CGFloat height, CGFloat width, CGFloat weight) {
    if (size <= 0) size = 12.0f;
    CGFloat wdth = MAX(60.0f, MIN(100.0f,  width));    // horizontal width 60..100
    CGFloat wght = MAX(1.0f,  MIN(1000.0f, weight));   // stroke weight 1..1000
    NSDictionary *variations = @{
        @(kAxisHGHT) : @(height),
        @(kAxisWDTH) : @(wdth),
        @(kAxisWGHT) : @(wght),     // stroke thickness (1 thin .. 400 regular .. 1000 bold)
        @(kAxisSOFT) : @(70),       // Apple's default softness
    };
    UIFontDescriptor *desc = [UIFontDescriptor fontDescriptorWithFontAttributes:@{
        UIFontDescriptorNameAttribute        : kFontPSName,
        (__bridge NSString *)kCTFontVariationAttribute : variations,
    }];
    UIFont *f = [UIFont fontWithDescriptor:desc size:size];
    // Guard: if the name didn't resolve, fontWithDescriptor may hand back a
    // system fallback whose family isn't ours — reject it so we don't lie.
    if (!f) return nil;
    return f;
}

#pragma mark - View helpers

static NSArray<UILabel *> *C26LabelsInView(UIView *v) {
    NSMutableArray *out = [NSMutableArray array];
    for (UIView *sub in v.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) [out addObject:sub];
        [out addObjectsFromArray:C26LabelsInView(sub)];
    }
    return out;
}

// The big time digits are the largest label in the time view.
static UILabel *C26LargestLabelInView(UIView *v) {
    UILabel *best = nil; CGFloat maxSize = 0;
    for (UILabel *l in C26LabelsInView(v)) {
        if (l.text.length > 0 && l.font.pointSize > maxSize) {
            maxSize = l.font.pointSize; best = l;
        }
    }
    return best;
}

static void C26PreserveOriginalFont(UILabel *label) {
    if (!label || objc_getAssociatedObject(label, &kC26OrigFontKey)) return;
    objc_setAssociatedObject(label, &kC26OrigFontKey, label.font, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Stop ancestors clipping the taller/bigger digits. iOS clips the time both via
// clipsToBounds AND via an explicit CALayer mask on the time container, so we
// disable both up the chain to the window. Clearing the mask on the nearest few
// layers is what actually lets glyphs spill past the stock time rectangle.
static void C26UnclipChain(UIView *view, int levels) {
    UIView *v = view;
    for (int i = 0; v && i < levels; i++) {
        v.clipsToBounds = NO;
        v.layer.masksToBounds = NO;
        // Only strip explicit masks on the nearest few layers (the time-region
        // clip lives here); leave higher containers' masks alone so we don't
        // break unrelated rounded-corner shapes on the lock screen.
        if (i < 3 && v.layer.mask) v.layer.mask = nil;
        v = v.superview;
    }
}

// Size the label to its digits and TOP-ANCHOR it right under the date, growing
// only downward.
//
// Why the clock looked "centred on screen" before: we grew the label's frame far
// taller than the text (1.6x) and a UILabel *vertically centres* its single line —
// so the digits dropped to the middle of that oversized box. The fix is to make
// the box hug the text height, pin its TOP to the stock top (origTop, i.e. just
// under the date) and grow downward. With a tight box, "centred in box" == "at the
// top", so the digits stay anchored under the date no matter how big/tall they get.
//
// We snapshot the stock FRAME once (never feed a grown frame back in, or it would
// grow unbounded) and derive the needed size from the font's own metrics. All
// width/weight variation is now baked into the font itself, so no affine transform
// is applied here — the box just hugs whatever the current variable font measures.
static void C26GrowLabelBounds(UILabel *label) {
    if (!label) return;

    NSValue *origVal = objc_getAssociatedObject(label, &kC26OrigBoundsKey);
    CGRect origFrame;
    if (origVal) {
        origFrame = [origVal CGRectValue];
    } else {
        // Snapshot the stock frame with any transform temporarily cleared so we
        // store the untransformed geometry.
        CGAffineTransform t = label.transform;
        label.transform = CGAffineTransformIdentity;
        origFrame = label.frame;
        label.transform = t;
        if (origFrame.size.width < 1 || origFrame.size.height < 1) return; // not laid out yet
        objc_setAssociatedObject(label, &kC26OrigBoundsKey,
            [NSValue valueWithCGRect:origFrame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Natural size the current variable font needs (width/weight already applied).
    CGSize fit = [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
    CGFloat textW = MAX(origFrame.size.width, fit.width);
    // Small vertical breathing room so soft/round glyph tops aren't shaved, but
    // NOT so much that vertical centring visibly drops the digits.
    CGFloat boxH  = MAX(origFrame.size.height, fit.height * 1.04f);

    // Bounds hug the text; centre pins the TOP to the stock top and grows down.
    // (Use bounds+centre, not frame, so any inherited transform is respected.)
    CGFloat origCenterX = origFrame.origin.x + origFrame.size.width * 0.5f;
    CGFloat origTop     = origFrame.origin.y;

    label.bounds = CGRectMake(0, 0, textW, boxH);
    label.center = CGPointMake(origCenterX, origTop + boxH * 0.5f);
    label.transform = CGAffineTransformIdentity;
    label.textAlignment = NSTextAlignmentCenter;
}

#pragma mark - Apply / restore

// compactFactor: 1.0 = full requested size; < 1.0 eases the clock back toward
// stock size when notifications have squeezed the time container (so an enlarged
// clock isn't buried under the notification stack).
static void C26ApplyToLabel(UILabel *label, CGFloat compactFactor) {
    if (!label) return;
    C26PreserveOriginalFont(label);
    UIFont *orig = objc_getAssociatedObject(label, &kC26OrigFontKey) ?: label.font;

    if (!pEnabled) {                       // restore stock font + box
        if (orig && label.font != orig) label.font = orig;
        label.transform = CGAffineTransformIdentity;
        NSValue *origVal = objc_getAssociatedObject(label, &kC26OrigBoundsKey);
        if (origVal) {
            label.frame = [origVal CGRectValue];   // put the stock frame back
        }
        objc_setAssociatedObject(label, &kC26SigKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    C26RegisterFontIfNeeded();
    CGFloat baseSize = orig.pointSize > 0 ? orig.pointSize : label.font.pointSize;

    // Ease the *extra* size (above 1.0) down by compactFactor, not the whole size,
    // so even in a very tight layout the clock never shrinks below stock. Weight is
    // eased back toward regular (400) and width back toward full (100) likewise.
    CGFloat cf = MAX(0.0f, MIN(1.0f, compactFactor));
    CGFloat effScale  = 1.0f + (pScale  - 1.0f)   * cf;
    CGFloat effHeight = 100.0f + (pHeight - 100.0f) * cf;   // ease HGHT back to 100
    CGFloat effWidth  = 100.0f + (pWidth  - 100.0f) * cf;   // ease wdth back to 100
    CGFloat effWeight = 400.0f + (pWeight - 400.0f) * cf;   // ease wght back to 400
    CGFloat size = baseSize * effScale;

    // Skip work if nothing changed since last pass (font is re-asserted every
    // layoutSubviews, so this guard keeps it cheap and avoids fighting layout).
    NSString *sig = [NSString stringWithFormat:@"%@|%.1f|%.1f|%.1f|%.1f|%.2f",
                     kFontPSName, size, effHeight, effWidth, effWeight, cf];
    NSString *cur = objc_getAssociatedObject(label, &kC26SigKey);
    BOOL fontOk = ([label.font.fontName rangeOfString:@"AXS66"].location != NSNotFound);
    if ([cur isEqualToString:sig] && fontOk) {
        // Even when the font is unchanged, keep asserting unclip + bounds because
        // layout may have reset them.
        C26UnclipChain(label, 8);
        C26GrowLabelBounds(label);
        return;
    }

    UIFont *vf = C26AxsFontOfSize(size, effHeight, effWidth, effWeight);
    if (!vf) return;                       // font not ready yet; try again next pass
    label.font = vf;
    label.adjustsFontSizeToFitWidth = NO;  // let it grow, don't auto-shrink
    label.numberOfLines = 1;
    C26UnclipChain(label, 8);
    C26GrowLabelBounds(label);
    objc_setAssociatedObject(label, &kC26SigKey, sig, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *C26FindClass(UIView *v, const char *clsName) {
    Class cls = objc_getClass(clsName);
    if (cls && [v isKindOfClass:cls]) return v;
    for (UIView *sub in v.subviews) {
        UIView *r = C26FindClass(sub, clsName);
        if (r) return r;
    }
    return nil;
}

#pragma mark - Liquid glass
// 在时间数字上叠加液态玻璃层。玻璃视图的大小/位置与数字 label 一致，
// 用 label 的 alpha 作为形状 mask。只在 pGlassEnabled 时创建，禁用时移除。
static void C26UpdateGlassView(UIView *timeView, UILabel *timeLabel) {
    if (!timeView) return;
    LiquidGlassView *glass = objc_getAssociatedObject(timeView, &kC26GlassViewKey);

    if (!pGlassEnabled || !pEnabled || !timeLabel) {
        if (glass) { [glass removeFromSuperview]; glass = nil; }
        objc_setAssociatedObject(timeView, &kC26GlassViewKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(timeView, &kC26GlassViewKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 玻璃层放在数字 label 上面
    CGRect labelFrame = [timeView convertRect:timeLabel.bounds fromView:timeLabel];
    glass.frame = labelFrame;
    glass.maskView = timeLabel;
    glass.blurRadius = pGlassBlur;
    glass.glassThickness = pGlassThickness;
    glass.refractionScale = pGlassRefraction;
    glass.specularOpacity = pGlassSpecular;
    glass.dispersion = pGlassDispersion;

    if (glass.superview != timeView) {
        [timeView addSubview:glass];
        [timeView bringSubviewToFront:glass];
    }
    [glass setNeedsUpdate];
}

#pragma mark - Notification-aware compaction

// Return a 0..1 factor for how much of the *extra* (above-stock) size we should
// apply, based on how squeezed the time container is. When notifications pile up,
// the system shrinks CSProminentTimeView; we track the tallest height we've ever
// seen it at (the roomy, no-notification state) and, once it drops below
// kCompactFloor of that, ease the enlargement back toward stock so an oversized
// clock isn't buried under the notification stack.
static CGFloat C26CompactFactorForView(UIView *timeView) {
    if (!timeView) return 1.0f;
    CGFloat h = timeView.bounds.size.height;
    if (h < 1) return 1.0f;

    NSNumber *maxN = objc_getAssociatedObject(timeView, &kC26MaxHKey);
    CGFloat maxH = maxN ? [maxN floatValue] : 0.0f;
    if (h > maxH) {                    // remember the roomiest height we've seen
        maxH = h;
        objc_setAssociatedObject(timeView, &kC26MaxHKey, @(maxH),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (maxH < 1) return 1.0f;

    CGFloat ratio = h / maxH;                 // 1.0 = roomy, smaller = squeezed
    if (ratio >= kCompactFloor) return 1.0f;  // still roomy enough: full size
    // Below the floor, ramp linearly from 1.0 down to 0.0 as the container
    // collapses from kCompactFloor*maxH toward 0. Quantise to 0.05 steps so tiny
    // layout jitter during the notification animation doesn't rebuild the font.
    CGFloat f = MAX(0.0f, MIN(1.0f, ratio / kCompactFloor));
    return roundf(f * 20.0f) / 20.0f;
}

#pragma mark - Reapply

static void C26ReapplyAll(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                UIView *t = C26FindClass(w, "CSProminentTimeView");
                if (t) {
                    UILabel *lbl = C26LargestLabelInView(t);
                    C26ApplyToLabel(lbl, C26CompactFactorForView(t));
                    C26UpdateGlassView(t, lbl);
                }
            }
        }
    });
}

#pragma mark - Respring + prefs callbacks

static void performRespring(void) {
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    Class actionClass  = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;
    id restartAction = [actionClass actionWithReason:@"Clock26Prefs"
        options:(SBSRelaunchActionOptionsRestartRenderServer | SBSRelaunchActionOptionsFadeToBlackTransition)
        targetURL:nil];
    if (!restartAction) return;
    [[serviceClass sharedService] sendActions:[NSSet setWithObject:restartAction] withResult:nil];
}

static void doRespringCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ performRespring(); });
}

static void prefsChangedCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    loadPrefs();
    C26ReapplyAll();
}

#pragma mark - Hooks

%hook CSProminentTimeView

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;   // self is a forward-declared %hook class
    // Re-assert the variable font + top-anchored downward growth every layout pass
    // so a system refresh can't revert it. The signature guard keeps repeat calls
    // cheap. The label's top stays pinned under the date and grows downward; when
    // notifications squeeze the time container we ease the size back so the clock
    // isn't buried (C26CompactFactorForView).
    C26ApplyToLabel(C26LargestLabelInView(self_), C26CompactFactorForView(self_));
    // 液态玻璃层：叠加在时间数字上（仅在启用时）
    C26UpdateGlassView(self_, C26LargestLabelInView(self_));
}

%end

%ctor {
    @autoreleasepool {
        loadPrefs();
        C26RegisterFontIfNeeded();
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, prefsChangedCallback,
            (CFStringRef)kPrefsChangedNotification, NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, doRespringCallback,
            kDoRespringNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
    }
}
