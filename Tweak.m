// AudioClear - Theos dylib (بدون جلبريك / بدون Substrate)
// يمنع التطبيق من تخريب جودة الصوت أثناء المحادثة الأونلاين.
// يعتمد على ObjC runtime swizzling فقط.

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>

#pragma mark - الإعدادات

static NSString *const kOn   = @"ac_on";    // تفعيل عام
static NSString *const kHFP  = @"ac_hfp";   // منع بلوتوث HFP
static NSString *const kVP   = @"ac_vp";    // منع VoiceProcessing
static NSString *const kSR   = @"ac_sr";    // فرض 48kHz
static NSString *const kMode = @"ac_mode";  // 0 تطبيق، 1 Default، 2 Measurement
static NSString *const kAU   = @"ac_au";    // تعطيل VoiceProcessingIO (AudioUnit)

static BOOL B(NSString *k) { return [[NSUserDefaults standardUserDefaults] boolForKey:k]; }
static NSInteger I(NSString *k) { return [[NSUserDefaults standardUserDefaults] integerForKey:k]; }

static NSString *ACMode(NSString *orig) {
    if (!B(kOn)) return orig;
    switch (I(kMode)) {
        case 1: return AVAudioSessionModeDefault;
        case 2: return AVAudioSessionModeMeasurement;
        default: return orig;
    }
}

static NSUInteger ACOpts(NSUInteger o) {
    if (B(kOn) && B(kHFP)) o &= ~(NSUInteger)AVAudioSessionCategoryOptionAllowBluetooth;
    return o;
}

#pragma mark - Hooks

static BOOL (*o_cmo)(id, SEL, NSString *, NSString *, NSUInteger, NSError **);
static BOOL n_cmo(id s, SEL c, NSString *cat, NSString *mode, NSUInteger opts, NSError **e) {
    return o_cmo(s, c, cat, ACMode(mode), ACOpts(opts), e);
}

static BOOL (*o_cmro)(id, SEL, NSString *, NSString *, NSInteger, NSUInteger, NSError **);
static BOOL n_cmro(id s, SEL c, NSString *cat, NSString *mode, NSInteger pol, NSUInteger opts, NSError **e) {
    return o_cmro(s, c, cat, ACMode(mode), pol, ACOpts(opts), e);
}

static BOOL (*o_cwo)(id, SEL, NSString *, NSUInteger, NSError **);
static BOOL n_cwo(id s, SEL c, NSString *cat, NSUInteger opts, NSError **e) {
    return o_cwo(s, c, cat, ACOpts(opts), e);
}

static BOOL (*o_mode)(id, SEL, NSString *, NSError **);
static BOOL n_mode(id s, SEL c, NSString *mode, NSError **e) {
    return o_mode(s, c, ACMode(mode), e);
}

static BOOL (*o_sr)(id, SEL, double, NSError **);
static BOOL n_sr(id s, SEL c, double rate, NSError **e) {
    if (B(kOn) && B(kSR)) rate = 48000.0;
    return o_sr(s, c, rate, e);
}

static BOOL (*o_vp)(id, SEL, BOOL, NSError **);
static BOOL n_vp(id s, SEL c, BOOL en, NSError **e) {
    if (B(kOn) && B(kVP) && en) return YES;   // نتجاهل التفعيل
    return o_vp(s, c, en, e);
}

static void hook(Class cls, SEL sel, IMP n, IMP *o) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *o = method_getImplementation(m);
    method_setImplementation(m, n);
}

#pragma mark - AudioUnit (VoiceProcessingIO) عبر rebind

static OSStatus (*o_ausp)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus (*o_auinit)(AudioUnit);

static OSStatus n_ausp(AudioUnit u, AudioUnitPropertyID pid, AudioUnitScope sc, AudioUnitElement el, const void *data, UInt32 size) {
    if (B(kOn) && B(kAU) && data && size >= sizeof(UInt32)) {
        if (pid == kAUVoiceIOProperty_BypassVoiceProcessing) {      // أجبره على Bypass
            UInt32 one = 1;
            return o_ausp(u, pid, sc, el, &one, sizeof(one));
        }
        if (pid == kAUVoiceIOProperty_VoiceProcessingEnableAGC) {   // طفّي AGC
            UInt32 zero = 0;
            return o_ausp(u, pid, sc, el, &zero, sizeof(zero));
        }
    }
    return o_ausp(u, pid, sc, el, data, size);
}

static OSStatus n_auinit(AudioUnit u) {
    if (B(kOn) && B(kAU)) {
        // على unit غير VPIO يرجع خطأ بسيط ونتجاهله
        UInt32 one = 1, zero = 0;
        o_ausp(u, kAUVoiceIOProperty_BypassVoiceProcessing, kAudioUnitScope_Global, 0, &one, sizeof(one));
        o_ausp(u, kAUVoiceIOProperty_VoiceProcessingEnableAGC, kAudioUnitScope_Global, 0, &zero, sizeof(zero));
    }
    return o_auinit(u);
}

// ---- rebind مصغّر (نفس فكرة fishhook) ----
struct ACRebind { const char *name; void *repl; };
static struct ACRebind gRebinds[2];

static void ACRebindSection(intptr_t slide, const struct section_64 *sect, const struct nlist_64 *symtab,
                            const char *strtab, const uint32_t *indirect, BOOL isConst) {
    const uint32_t *idx = indirect + sect->reserved1;
    void **slots = (void **)((uintptr_t)slide + sect->addr);
    size_t count = (size_t)(sect->size / sizeof(void *));
    for (size_t i = 0; i < count; i++) {
        uint32_t si = idx[i];
        if (si == INDIRECT_SYMBOL_ABS || si == INDIRECT_SYMBOL_LOCAL ||
            si == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[si].n_un.n_strx;
        if (name[0] != '_') continue;
        for (int r = 0; r < 2; r++) {
            if (strcmp(name + 1, gRebinds[r].name) == 0 && slots[i] != gRebinds[r].repl) {
                if (isConst) vm_protect(mach_task_self(), (uintptr_t)&slots[i], sizeof(void *), 0,
                                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                slots[i] = gRebinds[r].repl;
            }
        }
    }
}

static void ACImageAdded(const struct mach_header *mh, intptr_t slide) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)mh;
    if (h->magic != MH_MAGIC_64) return;
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dst = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const uint8_t *cur = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, cur += ((const struct load_command *)cur)->cmdsize) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == LC_SYMTAB) st = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dst = (const struct dysymtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        }
    }
    if (!st || !dst || !linkedit || dst->nindirectsyms == 0) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(base + st->symoff);
    const char *strtab = (const char *)(base + st->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dst->indirectsymoff);

    cur = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++, cur += ((const struct load_command *)cur)->cmdsize) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        BOOL isData = strcmp(seg->segname, "__DATA") == 0;
        BOOL isConst = strcmp(seg->segname, "__DATA_CONST") == 0;
        if (!isData && !isConst) continue;
        const struct section_64 *sec = (const struct section_64 *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++) {
            uint32_t t = sec[j].flags & SECTION_TYPE;
            if (t == S_LAZY_SYMBOL_POINTERS || t == S_NON_LAZY_SYMBOL_POINTERS)
                ACRebindSection(slide, &sec[j], symtab, strtab, indirect, isConst);
        }
    }
}

static void installAudioUnitHooks(void) {
    o_ausp   = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    o_auinit = dlsym(RTLD_DEFAULT, "AudioUnitInitialize");
    if (!o_ausp || !o_auinit) return;
    gRebinds[0] = (struct ACRebind){ "AudioUnitSetProperty", (void *)n_ausp };
    gRebinds[1] = (struct ACRebind){ "AudioUnitInitialize",  (void *)n_auinit };
    // يشتغل على الصور الحالية وعلى أي مكتبة تنحمّل لاحقاً
    _dyld_register_func_for_add_image(ACImageAdded);
}

static void installHooks(void) {
    Class S = [AVAudioSession class];
    hook(S, @selector(setCategory:mode:options:error:), (IMP)n_cmo, (IMP *)&o_cmo);
    hook(S, @selector(setCategory:mode:routeSharingPolicy:options:error:), (IMP)n_cmro, (IMP *)&o_cmro);
    hook(S, @selector(setCategory:withOptions:error:), (IMP)n_cwo, (IMP *)&o_cwo);
    hook(S, @selector(setMode:error:), (IMP)n_mode, (IMP *)&o_mode);
    hook(S, @selector(setPreferredSampleRate:error:), (IMP)n_sr, (IMP *)&o_sr);
    hook(NSClassFromString(@"AVAudioInputNode"), @selector(setVoiceProcessingEnabled:error:), (IMP)n_vp, (IMP *)&o_vp);
    installAudioUnitHooks();
}

// تطبيق الإعدادات فوراً على الجلسة الحالية
static void applyNow(void) {
    if (!B(kOn)) return;
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSError *e = nil;
    if (I(kMode) == 1) [s setMode:AVAudioSessionModeDefault error:&e];
    if (I(kMode) == 2) [s setMode:AVAudioSessionModeMeasurement error:&e];
    if (B(kSR)) [s setPreferredSampleRate:48000.0 error:&e];
}

#pragma mark - المنيو

static UIWindowScene *activeScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        if (sc.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)sc;
        if (!fallback) fallback = (UIWindowScene *)sc;
    }
    return fallback;
}

// نافذة شفافة فوق كل شي، تمرّر اللمس للعبة إلا إذا لمست المنيو
@interface ACWindow : UIWindow
@end
@implementation ACWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

@interface ACMenu : NSObject
@property (nonatomic, strong) UIButton *fab;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) ACWindow *win;
@property (nonatomic, strong) NSTimer *timer;
+ (instancetype)shared;
- (void)setup;
@end

@implementation ACMenu

+ (instancetype)shared {
    static ACMenu *m; static dispatch_once_t t;
    dispatch_once(&t, ^{ m = [ACMenu new]; });
    return m;
}

- (void)setup {
    if (!self.fab) {
        self.fab = [UIButton buttonWithType:UIButtonTypeCustom];
        self.fab.frame = CGRectMake(12, 140, 46, 46);
        self.fab.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65];
        self.fab.layer.cornerRadius = 23;
        [self.fab setTitle:@"🎙" forState:UIControlStateNormal];
        [self.fab addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [self.fab addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    }
    [self ensure];
    if (!self.timer) {
        __weak ACMenu *ws = self;
        self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { [ws ensure]; }];
    }
}

// يتأكد كل ثانية إن النافذة موجودة وفوق اللعبة
- (void)ensure {
    UIWindowScene *sc = activeScene();
    if (!self.win) {
        ACWindow *w = sc ? [[ACWindow alloc] initWithWindowScene:sc]
                         : [[ACWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        w.backgroundColor = UIColor.clearColor;
        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = UIColor.clearColor;
        w.rootViewController = vc;
        self.win = w;
        [vc.view addSubview:self.fab];
    }
    if (sc && self.win.windowScene != sc) self.win.windowScene = sc;
    self.win.windowLevel = UIWindowLevelAlert + 1000;
    self.win.hidden = NO;
    UIView *host = self.win.rootViewController.view;
    if (self.fab.superview != host) [host addSubview:self.fab];
    [host bringSubviewToFront:self.fab];
}

- (void)drag:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
    if (self.panel.superview) [self layoutPanel];
}

- (void)toggle {
    if (self.panel.superview) { [self.panel removeFromSuperview]; return; }
    [self buildPanel];
}

- (void)layoutPanel {
    CGRect f = self.panel.frame;
    CGRect sb = self.fab.superview.bounds;
    f.origin.x = MIN(MAX(8, self.fab.frame.origin.x), sb.size.width - f.size.width - 8);
    f.origin.y = MIN(CGRectGetMaxY(self.fab.frame) + 8, sb.size.height - f.size.height - 8);
    self.panel.frame = f;
}

- (void)buildPanel {
    NSArray *rows = @[ @[kOn, @"تفعيل الأداة"],
                       @[kVP, @"منع معالجة الصوت (VoiceProcessing)"],
                       @[kAU, @"تعطيل VoiceProcessingIO (AudioUnit)"],
                       @[kHFP, @"منع بلوتوث HFP (جودة واطية)"],
                       @[kSR, @"فرض 48kHz"] ];
    CGFloat W = 300, rowH = 44;
    UIView *p = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 40 + rows.count * rowH + 56)];
    p.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
    p.layer.cornerRadius = 14;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 8, W, 24)];
    title.text = @"AudioClear — نقاء الصوت";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:15];
    title.textAlignment = NSTextAlignmentCenter;
    [p addSubview:title];

    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = 40 + i * rowH;
        UISwitch *sw = [[UISwitch alloc] init];
        sw.frame = CGRectMake(12, y + 6, 51, 31);
        sw.on = B(rows[i][0]);
        sw.tag = i;
        [sw addTarget:self action:@selector(flip:) forControlEvents:UIControlEventValueChanged];
        [p addSubview:sw];

        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(70, y, W - 82, rowH)];
        l.text = rows[i][1];
        l.textColor = UIColor.whiteColor;
        l.font = [UIFont systemFontOfSize:13];
        l.textAlignment = NSTextAlignmentRight;
        l.numberOfLines = 2;
        [p addSubview:l];
    }

    UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"وضع التطبيق", @"Default", @"Measurement"]];
    seg.frame = CGRectMake(12, 40 + rows.count * rowH + 8, W - 24, 32);
    seg.selectedSegmentIndex = I(kMode);
    [seg addTarget:self action:@selector(seg:) forControlEvents:UIControlEventValueChanged];
    [p addSubview:seg];

    self.panel = p;
    [self.fab.superview addSubview:p];
    [self.fab.superview bringSubviewToFront:self.fab];
    [self layoutPanel];
}

- (void)flip:(UISwitch *)sw {
    NSArray *keys = @[kOn, kVP, kAU, kHFP, kSR];
    [[NSUserDefaults standardUserDefaults] setBool:sw.on forKey:keys[sw.tag]];
    applyNow();
}

- (void)seg:(UISegmentedControl *)s {
    [[NSUserDefaults standardUserDefaults] setInteger:s.selectedSegmentIndex forKey:kMode];
    applyNow();
}

@end

#pragma mark - نقطة الدخول

__attribute__((constructor))
static void ACInit(void) {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kOn: @YES, kVP: @YES, kAU: @YES, kHFP: @NO, kSR: @YES, kMode: @1
    }];
    installHooks();
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
        usingBlock:^(NSNotification *n) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [[ACMenu shared] setup];
                applyNow();
            });
        }];
}
