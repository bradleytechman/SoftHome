//
// SoftHome — floating, draggable software Home button for iPhone OS 1.0–1.1.5.
//
// iPhone OS 1 UIKit has no UIColor, no -[UIView center], no UITouch,
// no -[UIApplication sharedApplication], and no makeKeyAndVisible.
// Touch is GSEvent mouseDown:/mouseDragged:/mouseUp:. The running
// application is the UIApp global. Home in SpringBoard is menuButtonDown:/Up:;
// in apps it is suspendWithAnimation: (the hardware Home behavior).
//

#include <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <UIKit/UIKit.h>
#include <GraphicsServices/GraphicsServices.h>
#include <CydiaSubstrate.h>
#include <objc/runtime.h>
#include <string.h>

#define kButtonSize 52.0f
#define kDragThreshold 10.0f
#define kMargin 4.0f
#define kStatusBar 20.0f
#define kDefaultsX @"SoftHomeX"
#define kDefaultsY @"SoftHomeY"

extern UIApplication *UIApp;
extern CGContextRef UICurrentContext(void);

@interface UIApplication (SoftHome)
- (void)menuButtonDown:(GSEvent *)event;
- (void)menuButtonUp:(GSEvent *)event;
- (void)suspendWithAnimation:(BOOL)animate;
- (void)reportAppLaunchFinished;
@end

@interface UIWindow (SoftHome)
+ (id)keyWindow;
- (void)makeKey:(id)sender;
- (void)orderFront:(id)sender;
- (void)setContentView:(id)view;
@end

@interface UIAlertSheet (SoftHome)
+ (BOOL)atLeastOneAlertVisible;
- (void)_performPopup:(BOOL)animated;
- (void)popupAlertAnimated:(BOOL)animated atOffset:(float)offset;
- (void)dismissAnimated:(BOOL)animated;
- (void)presentSheetInView:(id)view;
@end

@interface SoftHomeButton : UIView {
    BOOL _dragging;
    BOOL _moved;
    CGPoint _grabOffset;
    CGPoint _touchStart;
}
- (void)hb_keepFront;
@end

static SoftHomeButton *g_button = nil;
static BOOL g_hooked = NO;
static BOOL g_hiddenForAlert = NO;
static CGPoint g_lastCenter;
static BOOL g_hasLastCenter = NO;

static CGPoint SoftHomeViewCenter(UIView *view) {
    CGRect frame = [view frame];
    return CGPointMake(frame.origin.x + (frame.size.width * 0.5f),
                       frame.origin.y + (frame.size.height * 0.5f));
}

static void SoftHomeSetViewCenter(UIView *view, CGPoint center) {
    CGRect frame = [view frame];
    frame.origin.x = center.x - (frame.size.width * 0.5f);
    frame.origin.y = center.y - (frame.size.height * 0.5f);
    [view setFrame:frame];
}

static CGColorRef SoftHomeCreateColor(float red, float green, float blue, float alpha) {
    float rgba[4];
    rgba[0] = red;
    rgba[1] = green;
    rgba[2] = blue;
    rgba[3] = alpha;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGColorRef color = CGColorCreate(space, rgba);
    CGColorSpaceRelease(space);
    return color;
}

static BOOL SoftHomeIsSpringBoard(void) {
    Class springBoard = objc_getClass("SpringBoard");
    if (springBoard == Nil || UIApp == nil) {
        return NO;
    }
    return [UIApp isKindOfClass:springBoard];
}

static void SoftHomeSimulateHome(void) {
    if (UIApp == nil) {
        return;
    }

    if (SoftHomeIsSpringBoard()) {
        [UIApp menuButtonDown:NULL];
        [UIApp menuButtonUp:NULL];
        return;
    }

    /* Hardware Home in a 1.x app suspends back to SpringBoard. */
    [UIApp suspendWithAnimation:YES];
}

static CGPoint SoftHomeClamp(UIView *host, CGPoint center) {
    CGRect bounds = [host bounds];
    float half = kButtonSize / 2.0f;
    float minX = CGRectGetMinX(bounds) + half + kMargin;
    float maxX = CGRectGetMaxX(bounds) - half - kMargin;
    float minY = CGRectGetMinY(bounds) + half + kMargin + kStatusBar;
    float maxY = CGRectGetMaxY(bounds) - half - kMargin;
    if (minX > maxX) {
        minX = maxX = CGRectGetMidX(bounds);
    }
    if (minY > maxY) {
        minY = maxY = CGRectGetMidY(bounds);
    }
    if (center.x < minX) {
        center.x = minX;
    }
    if (center.x > maxX) {
        center.x = maxX;
    }
    if (center.y < minY) {
        center.y = minY;
    }
    if (center.y > maxY) {
        center.y = maxY;
    }
    return center;
}

static CGPoint SoftHomeSavedCenter(UIView *host) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kDefaultsX] == nil || [defaults objectForKey:kDefaultsY] == nil) {
        CGRect bounds = [host bounds];
        return CGPointMake(CGRectGetMaxX(bounds) - 36.0f, CGRectGetMaxY(bounds) - 96.0f);
    }
    CGPoint point;
    point.x = [defaults floatForKey:kDefaultsX];
    point.y = [defaults floatForKey:kDefaultsY];
    return SoftHomeClamp(host, point);
}

static void SoftHomeSaveCenter(CGPoint center) {
    g_lastCenter = center;
    g_hasLastCenter = YES;
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setFloat:center.x forKey:kDefaultsX];
    [defaults setFloat:center.y forKey:kDefaultsY];
    [defaults synchronize];
}

static BOOL SoftHomeWindowIsAlertOverlay(UIWindow *window) {
    if (window == nil) {
        return YES;
    }

    /* Apple's 1.x class name is misspelled "Ovelay". */
    Class overlay = objc_getClass("_UIAlertOvelayWindow");
    if (overlay != Nil && [window isKindOfClass:overlay]) {
        return YES;
    }

    const char *name = object_getClassName(window);
    if (name != NULL && strstr(name, "Alert") != NULL) {
        return YES;
    }

    return NO;
}

static BOOL SoftHomeAlertVisible(void) {
    Class sheet = objc_getClass("UIAlertSheet");
    if (sheet == Nil) {
        return NO;
    }
    if (![sheet respondsToSelector:@selector(atLeastOneAlertVisible)]) {
        return NO;
    }
    return [sheet atLeastOneAlertVisible];
}

static CGPoint SoftHomeCenterForHost(UIView *host) {
    if (g_hasLastCenter) {
        return SoftHomeClamp(host, g_lastCenter);
    }
    return SoftHomeSavedCenter(host);
}

static void SoftHomeHideForAlert(void) {
    if (g_button != nil && [g_button superview] != nil) {
        g_lastCenter = SoftHomeViewCenter(g_button);
        g_hasLastCenter = YES;
        [g_button removeFromSuperview];
    }
    g_hiddenForAlert = YES;
}

static void SoftHomeAttachToWindow(UIWindow *window);

static void SoftHomeShowAfterAlert(void) {
    g_hiddenForAlert = NO;
    UIWindow *key = [UIWindow keyWindow];
    if (key == nil || SoftHomeWindowIsAlertOverlay(key)) {
        return;
    }
    SoftHomeAttachToWindow(key);
}

static CGPoint SoftHomePointFromEvent(GSEvent *event, UIView *view) {
    CGPoint point = GSEventGetLocationInWindow(event);
    UIView *host = [view superview];
    if (host == nil) {
        return point;
    }
    if ([host isKindOfClass:objc_getClass("UIWindow")]) {
        return point;
    }
    return [host convertPoint:point fromView:nil];
}

@implementation SoftHomeButton

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self != nil) {
        [self setOpaque:NO];
        CGColorRef clear = SoftHomeCreateColor(0.0f, 0.0f, 0.0f, 0.0f);
        [self setBackgroundColor:clear];
        CGColorRelease(clear);
        _dragging = NO;
        _moved = NO;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef ctx = UICurrentContext();
    if (ctx == NULL) {
        return;
    }

    CGRect bounds = [self bounds];
    CGRect outer = CGRectInset(bounds, 1.0f, 1.0f);

    CGContextSetRGBFillColor(ctx, 0.12f, 0.12f, 0.14f, 0.82f);
    CGContextAddEllipseInRect(ctx, outer);
    CGContextFillPath(ctx);

    CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.55f);
    CGContextSetLineWidth(ctx, 1.5f);
    CGContextAddEllipseInRect(ctx, CGRectInset(outer, 1.0f, 1.0f));
    CGContextStrokePath(ctx);

    CGRect inner = CGRectInset(bounds, 16.0f, 16.0f);
    CGContextSetRGBStrokeColor(ctx, 1.0f, 1.0f, 1.0f, 0.92f);
    CGContextSetLineWidth(ctx, 2.0f);
    CGContextStrokeRect(ctx, inner);
}

- (BOOL)pointInside:(CGPoint)point forEvent:(GSEvent *)event {
    (void)event;
    CGRect bounds = [self bounds];
    float dx = point.x - (bounds.size.width * 0.5f);
    float dy = point.y - (bounds.size.height * 0.5f);
    float radius = bounds.size.width * 0.5f;
    return ((dx * dx) + (dy * dy)) <= (radius * radius);
}

- (void)hb_keepFront {
    if (g_hiddenForAlert || SoftHomeAlertVisible()) {
        return;
    }
    UIView *parent = [self superview];
    if (parent != nil) {
        if (!SoftHomeWindowIsAlertOverlay((UIWindow *)parent)) {
            NSArray *subs = [parent subviews];
            if ([subs count] == 0 || [subs lastObject] != self) {
                [parent bringSubviewToFront:self];
            }
        }
        return;
    }
    UIWindow *key = [UIWindow keyWindow];
    if (key != nil && !SoftHomeWindowIsAlertOverlay(key)) {
        SoftHomeSetViewCenter(self, SoftHomeCenterForHost(key));
        [key addSubview:self];
    }
}

- (void)hb_beginAt:(CGPoint)point {
    _touchStart = point;
    CGPoint center = SoftHomeViewCenter(self);
    _grabOffset = CGPointMake(point.x - center.x, point.y - center.y);
    _dragging = YES;
    _moved = NO;
    [self setAlpha:0.7f];
}

- (void)hb_moveTo:(CGPoint)point {
    if (!_dragging) {
        return;
    }
    float dx = point.x - _touchStart.x;
    float dy = point.y - _touchStart.y;
    if ((dx * dx) + (dy * dy) > (kDragThreshold * kDragThreshold)) {
        _moved = YES;
    }
    if (_moved) {
        UIView *host = [self superview];
        if (host != nil) {
            CGPoint center = CGPointMake(point.x - _grabOffset.x, point.y - _grabOffset.y);
            SoftHomeSetViewCenter(self, SoftHomeClamp(host, center));
        }
    }
}

- (void)hb_end {
    if (!_dragging) {
        return;
    }
    _dragging = NO;
    [self setAlpha:1.0f];
    if (_moved) {
        SoftHomeSaveCenter(SoftHomeViewCenter(self));
    } else {
        SoftHomeSimulateHome();
    }
    _moved = NO;
}

- (void)mouseDown:(GSEvent *)event {
    [self hb_beginAt:SoftHomePointFromEvent(event, self)];
}

- (void)mouseDragged:(GSEvent *)event {
    [self hb_moveTo:SoftHomePointFromEvent(event, self)];
}

- (void)mouseUp:(GSEvent *)event {
    (void)event;
    [self hb_end];
}

@end

static void SoftHomeAttachToWindow(UIWindow *window) {
    if (window == nil || g_hiddenForAlert || SoftHomeWindowIsAlertOverlay(window)) {
        return;
    }
    if (g_button == nil) {
        g_button = [[SoftHomeButton alloc] initWithFrame:CGRectMake(0.0f, 0.0f, kButtonSize, kButtonSize)];
        [NSTimer scheduledTimerWithTimeInterval:1.0 target:g_button selector:@selector(hb_keepFront) userInfo:nil repeats:YES];
    }
    UIView *currentHost = [g_button superview];
    if (currentHost != nil && currentHost != window && !SoftHomeWindowIsAlertOverlay((UIWindow *)currentHost)) {
        /* Stay on the real app window; alert dim/overlay windows must not steal it. */
        return;
    }
    if (currentHost == window) {
        NSArray *subs = [window subviews];
        if ([subs count] == 0 || [subs lastObject] == g_button) {
            return;
        }
        [window bringSubviewToFront:g_button];
        return;
    }
    if (currentHost != nil) {
        g_lastCenter = SoftHomeViewCenter(g_button);
        g_hasLastCenter = YES;
        [g_button removeFromSuperview];
    }
    SoftHomeSetViewCenter(g_button, SoftHomeCenterForHost(window));
    [window addSubview:g_button];
}

static void (*UIWindow_makeKey_orig)(id, SEL, id) = NULL;
static void UIWindow_makeKey_hook(id self, SEL _cmd, id sender) {
    UIWindow_makeKey_orig(self, _cmd, sender);
    SoftHomeAttachToWindow(self);
}

static void (*UIWindow_orderFront_orig)(id, SEL, id) = NULL;
static void UIWindow_orderFront_hook(id self, SEL _cmd, id sender) {
    UIWindow_orderFront_orig(self, _cmd, sender);
    SoftHomeAttachToWindow(self);
}

static void (*UIWindow_setContentView_orig)(id, SEL, id) = NULL;
static void UIWindow_setContentView_hook(id self, SEL _cmd, id view) {
    UIWindow_setContentView_orig(self, _cmd, view);
    SoftHomeAttachToWindow(self);
}

static void (*UIApplication_reportAppLaunchFinished_orig)(id, SEL) = NULL;
static void UIApplication_reportAppLaunchFinished_hook(id self, SEL _cmd) {
    UIApplication_reportAppLaunchFinished_orig(self, _cmd);
    SoftHomeAttachToWindow([UIWindow keyWindow]);
}

static void (*SpringBoard_applicationDidFinishLaunching_orig)(id, SEL, id) = NULL;
static void SpringBoard_applicationDidFinishLaunching_hook(id self, SEL _cmd, id arg) {
    SpringBoard_applicationDidFinishLaunching_orig(self, _cmd, arg);
    SoftHomeAttachToWindow([UIWindow keyWindow]);
}

static void (*UIAlertSheet_performPopup_orig)(id, SEL, BOOL) = NULL;
static void UIAlertSheet_performPopup_hook(id self, SEL _cmd, BOOL animated) {
    SoftHomeHideForAlert();
    UIAlertSheet_performPopup_orig(self, _cmd, animated);
}

static void (*UIAlertSheet_popupAlertAnimated_atOffset_orig)(id, SEL, BOOL, float) = NULL;
static void UIAlertSheet_popupAlertAnimated_atOffset_hook(id self, SEL _cmd, BOOL animated, float offset) {
    SoftHomeHideForAlert();
    UIAlertSheet_popupAlertAnimated_atOffset_orig(self, _cmd, animated, offset);
}

static void (*UIAlertSheet_presentSheetInView_orig)(id, SEL, id) = NULL;
static void UIAlertSheet_presentSheetInView_hook(id self, SEL _cmd, id view) {
    SoftHomeHideForAlert();
    UIAlertSheet_presentSheetInView_orig(self, _cmd, view);
}

static void (*UIAlertSheet_dismissAnimated_orig)(id, SEL, BOOL) = NULL;
static void UIAlertSheet_dismissAnimated_hook(id self, SEL _cmd, BOOL animated) {
    UIAlertSheet_dismissAnimated_orig(self, _cmd, animated);
    SoftHomeShowAfterAlert();
}

static void SoftHomeTryHook(Class cls, SEL sel, IMP imp, IMP *orig) {
    if (cls == Nil) {
        return;
    }
    if (class_getInstanceMethod(cls, sel) == NULL) {
        return;
    }
    MSHookMessageEx(cls, sel, imp, orig);
}

__attribute__((constructor)) static void init(void) {
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    if (g_hooked) {
        [pool release];
        return;
    }
    g_hooked = YES;

    Class windowClass = objc_getClass("UIWindow");
    SoftHomeTryHook(windowClass, @selector(makeKey:), (IMP)UIWindow_makeKey_hook, (IMP *)&UIWindow_makeKey_orig);
    SoftHomeTryHook(windowClass, @selector(orderFront:), (IMP)UIWindow_orderFront_hook, (IMP *)&UIWindow_orderFront_orig);
    SoftHomeTryHook(windowClass, @selector(setContentView:), (IMP)UIWindow_setContentView_hook, (IMP *)&UIWindow_setContentView_orig);

    SoftHomeTryHook(objc_getClass("UIApplication"), @selector(reportAppLaunchFinished), (IMP)UIApplication_reportAppLaunchFinished_hook, (IMP *)&UIApplication_reportAppLaunchFinished_orig);

    Class springBoard = objc_getClass("SpringBoard");
    if (springBoard != Nil) {
        SoftHomeTryHook(springBoard, @selector(applicationDidFinishLaunching:), (IMP)SpringBoard_applicationDidFinishLaunching_hook, (IMP *)&SpringBoard_applicationDidFinishLaunching_orig);
    }

    Class alertSheet = objc_getClass("UIAlertSheet");
    SoftHomeTryHook(alertSheet, @selector(_performPopup:), (IMP)UIAlertSheet_performPopup_hook, (IMP *)&UIAlertSheet_performPopup_orig);
    SoftHomeTryHook(alertSheet, @selector(popupAlertAnimated:atOffset:), (IMP)UIAlertSheet_popupAlertAnimated_atOffset_hook, (IMP *)&UIAlertSheet_popupAlertAnimated_atOffset_orig);
    SoftHomeTryHook(alertSheet, @selector(presentSheetInView:), (IMP)UIAlertSheet_presentSheetInView_hook, (IMP *)&UIAlertSheet_presentSheetInView_orig);
    SoftHomeTryHook(alertSheet, @selector(dismissAnimated:), (IMP)UIAlertSheet_dismissAnimated_hook, (IMP *)&UIAlertSheet_dismissAnimated_orig);

    UIWindow *key = [UIWindow keyWindow];
    if (key != nil) {
        SoftHomeAttachToWindow(key);
    }

    [pool release];
}
