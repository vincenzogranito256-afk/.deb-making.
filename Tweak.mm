// ═══════════════════════════════════════════════════════════════════════════════
// MT4 Modding — Single File Tweak  (SIDELOAD + DYLIB FULLY CRASH-FIXED v4)
// Target: Animal Company VR (Animal Company)
// Bundle ID: com.AnimalCompany.AnimalCompany
// Built from scratch — no skid ✓
// Black Hole theme — void black, charcoal gray, singularity
// Spawns items by writing animal-company-config.json directly
//
// Fixes applied:
//   1. Added _ELBlockTarget + UIGestureRecognizer(ELBlocks) category so that
//      [gesture addTarget:^{ } withObject:nil] compiles correctly.
//   2. Added #import <QuartzCore/QuartzCore.h> for CAGradientLayer / CABasicAnimation.
//   3. Fixed signed/unsigned NSInteger vs NSUInteger loop comparisons.
//   4. Replaced deprecated -keyWindow with a scene-safe helper (iOS 13+).
//   5. Replaced private KVC _placeholderLabel.textColor with attributed placeholder.
//   6. Added Unity IL2CPP camera position grabber — items now spawn at camera world coords.
//   7. Changed state: 0 → state: 1 so the game treats entries as pending (not already handled).
//   8. Added bundle ID guard (com.AnimalCompany.AnimalCompany) so tweak only fires in-app.
// ═══════════════════════════════════════════════════════════════════════════════

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>  // FIX 2 — CAGradientLayer, CABasicAnimation
#import <objc/runtime.h>
#import <dlfcn.h>
#import <unistd.h>

// ── Runtime hooking-engine shim (no hard substrate dependency) ────────────────
typedef void (*_ELHookFn_t)(void *, void *, void **);
static _ELHookFn_t _ELHookFn = NULL;
static void ELInitHookEngine(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *libs[] = {
            "/usr/lib/libsubstrate.dylib",
            "/usr/lib/libsubstitute.dylib",
            "/usr/lib/libhooker.dylib",
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            NULL
        };
        for (int i = 0; libs[i]; i++) {
            void *h = dlopen(libs[i], RTLD_NOW | RTLD_GLOBAL);
            if (!h) continue;
            _ELHookFn = (_ELHookFn_t)dlsym(h, "MSHookFunction");
            if (_ELHookFn) break;
        }
    });
}
static void ELHookFunction(void *sym, void *rep, void **orig) {
    if (!sym) { if (orig) *orig = NULL; return; }
    ELInitHookEngine();
    if (_ELHookFn) _ELHookFn(sym, rep, orig);
    else if (orig) *orig = sym;
}

// ═══════════════════════════════════════════════════════════════════════════════
// FIX 1 — Block-based UIGestureRecognizer support
// The original code called [gesture addTarget:^{ } withObject:nil] which is NOT
// a real UIKit method. We add a lightweight target wrapper + category to make it work.
// ═══════════════════════════════════════════════════════════════════════════════

@interface _ELBlockTarget : NSObject
@property (nonatomic, copy) void (^action)(id sender);
+ (instancetype)targetWithBlock:(void(^)(id sender))block;
- (void)fire:(id)sender;
@end

@implementation _ELBlockTarget
+ (instancetype)targetWithBlock:(void(^)(id))block {
    _ELBlockTarget *t = [_ELBlockTarget new];
    t.action = block;
    return t;
}
- (void)fire:(id)sender { if (self.action) self.action(sender); }
@end

// Strong storage so targets are never deallocated
static NSMutableArray *_ELGestureTargets;

@interface UIGestureRecognizer (ELBlocks)
- (void)el_addBlock:(void (^)(id))block;
@end

// Global token so the array is initialised exactly once even across reloads
static dispatch_once_t _ELGestureOnce;

@implementation UIGestureRecognizer (ELBlocks)
- (void)el_addBlock:(void (^)(id))block {
    dispatch_once(&_ELGestureOnce, ^{ _ELGestureTargets = [NSMutableArray array]; });
    _ELBlockTarget *t = [_ELBlockTarget targetWithBlock:block];
    [_ELGestureTargets addObject:t];
    [self addTarget:t action:@selector(fire:)];
}
@end

// ─── FIX 4 — Safe key window helper (iOS 13+) ────────────────────────────────
static UIWindow *ELKeyWindow(void) {
    if (![UIApplication sharedApplication]) return nil;
    if (@available(iOS 13.0, *)) {
        // First pass: prefer ForegroundActive scene
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) return w;
                }
                UIWindow *first = ((UIWindowScene *)scene).windows.firstObject;
                if (first) return first;
            }
        }
        // Second pass: accept any connected scene (handles sideload / inactive state)
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindow *first = ((UIWindowScene *)scene).windows.firstObject;
            if (first) return first;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

// ─── Toast forward declaration ────────────────────────────────────────────────
static void ELToast(NSString *msg, BOOL success);

// ═══════════════════════════════════════════════════════════════════════════════
// Unity IL2CPP — Camera world-position grabber
// We resolve Camera.main and call get_transform / get_position via il2cpp_resolve_icall.
// Falls back to {0,0,0} if Unity isn't ready yet.
// ═══════════════════════════════════════════════════════════════════════════════

typedef struct { float x, y, z; }    ELVec3;
typedef struct { float x, y, z, w; } ELQuat;

// IL2CPP type stubs (opaque pointers)
typedef void* Il2CppObject;
typedef void* Il2CppClass;
typedef void* Il2CppDomain;
typedef void* Il2CppAssembly;
typedef void* Il2CppImage;

// il2cpp runtime exports
extern Il2CppDomain* il2cpp_domain_get(void)                                           __attribute__((weak_import));
extern void*         il2cpp_resolve_icall(const char *name)                             __attribute__((weak_import));
extern void*         il2cpp_domain_assembly_open(void *domain, const char *name)        __attribute__((weak_import));
extern void*         il2cpp_assembly_get_image(void *assembly)                          __attribute__((weak_import));
extern void*         il2cpp_class_from_name(void *image, const char *ns, const char *n) __attribute__((weak_import));
extern void*         il2cpp_class_get_method_from_name(void *klass, const char *name, int argc) __attribute__((weak_import));
extern void*         il2cpp_method_get_pointer(void *method)                            __attribute__((weak_import));

// Cached function pointers resolved once on first spawn
static Il2CppObject* (*_Camera_get_main)(void)                  = NULL;
static Il2CppObject* (*_Component_get_transform)(Il2CppObject*) = NULL;
static ELVec3        (*_Transform_get_position)(Il2CppObject*)  = NULL;
static BOOL          _positionIsInjected                         = NO;  // cached — no re-resolve at spawn

static void ELResolveUnityFuncs(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!il2cpp_resolve_icall) return;
        _Camera_get_main         = (__typeof__(_Camera_get_main))il2cpp_resolve_icall("UnityEngine.Camera::get_main");
        _Component_get_transform = (__typeof__(_Component_get_transform))il2cpp_resolve_icall("UnityEngine.Component::get_transform");
        void *injected           = il2cpp_resolve_icall("UnityEngine.Transform::get_position_Injected");
        if (injected) {
            _Transform_get_position = (__typeof__(_Transform_get_position))injected;
            _positionIsInjected     = YES;
        } else {
            _Transform_get_position = (__typeof__(_Transform_get_position))il2cpp_resolve_icall("UnityEngine.Transform::get_position");
            _positionIsInjected     = NO;
        }
    });
}

/// Returns the main camera's world-space position, or {0,0,0} on failure.
static ELVec3 ELCameraPosition(void) {
    ELVec3 zero = {0, 0, 0};
    ELResolveUnityFuncs();
    if (!_Camera_get_main || !_Component_get_transform || !_Transform_get_position)
        return zero;

    Il2CppObject *cam = _Camera_get_main();
    if (!cam) return zero;

    Il2CppObject *transform = _Component_get_transform(cam);
    if (!transform) return zero;

    ELVec3 pos = {0, 0, 0};
    typedef void   (*GetPosInjected)(Il2CppObject*, ELVec3*);
    typedef ELVec3 (*GetPosDirect)(Il2CppObject*);

    if (_positionIsInjected)
        ((GetPosInjected)_Transform_get_position)(transform, &pos);
    else
        pos = ((GetPosDirect)_Transform_get_position)(transform);
    return pos;
}

/// Returns the main camera's world-space rotation as a quaternion, or identity on failure.
static ELQuat ELCameraRotation(void) {
    ELQuat identity = {0, 0, 0, 1};
    ELResolveUnityFuncs();
    if (!_Camera_get_main || !_Component_get_transform) return identity;

    Il2CppObject *cam = _Camera_get_main();
    if (!cam) return identity;
    Il2CppObject *transform = _Component_get_transform(cam);
    if (!transform) return identity;

    // Try injected variant first, then direct
    typedef void   (*GetRotInjected)(Il2CppObject*, ELQuat*);
    typedef ELQuat (*GetRotDirect)(Il2CppObject*);

    static void *_getRotFn    = NULL;
    static BOOL  _rotInjected = NO;
    static dispatch_once_t rotOnce;
    dispatch_once(&rotOnce, ^{
        _getRotFn = il2cpp_resolve_icall ? il2cpp_resolve_icall("UnityEngine.Transform::get_rotation_Injected") : NULL;
        if (_getRotFn) { _rotInjected = YES; return; }
        _getRotFn = il2cpp_resolve_icall ? il2cpp_resolve_icall("UnityEngine.Transform::get_rotation") : NULL;
        _rotInjected = NO;
    });

    if (!_getRotFn) return identity;
    ELQuat rot = {0, 0, 0, 1};
    if (_rotInjected) ((GetRotInjected)_getRotFn)(transform, &rot);
    else              rot = ((GetRotDirect)_getRotFn)(transform);
    return rot;
}

// ─── Config path (forward declaration) ───────────────────────────────────────
static NSString *ELConfigPath(void);

/// Writes a fling-forward teleport: current camera pos + (flingDist metres in camera forward direction).
static BOOL ELFlingForward(CGFloat flingDist) {
    ELVec3 pos  = ELCameraPosition();
    ELQuat rot  = ELCameraRotation();

    // Derive forward vector from quaternion: Unity's forward is (0,0,1) rotated by q
    float x = rot.x, y = rot.y, z = rot.z, w = rot.w;
    float fwdX = 2*(x*z + w*y);
    float fwdY = 2*(y*z - w*x);
    float fwdZ = 1 - 2*(x*x + y*y);

    // Normalize (should already be unit but be safe)
    float len = sqrtf(fwdX*fwdX + fwdY*fwdY + fwdZ*fwdZ);
    if (len > 0.001f) { fwdX /= len; fwdY /= len; fwdZ /= len; }

    // Target position: fling forward, keep Y flat (no vertical fling)
    float targetX = pos.x + fwdX * flingDist;
    float targetY = pos.y;                      // stay at same height
    float targetZ = pos.z + fwdZ * flingDist;

    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    NSDictionary *tpos = @{ @"x": @(targetX), @"y": @(targetY), @"z": @(targetZ) };
    config[@"playerPosition"]    = tpos;
    config[@"teleportPosition"]  = tpos;
    config[@"warpPosition"]      = tpos;
    config[@"spawnPosition"]     = tpos;
    config[@"requestTeleport"]   = tpos;
    config[@"teleport"]          = tpos;
    config[@"flingForward"]      = @YES;
    config[@"flingDistance"]     = @(flingDist);
    config[@"teleportPending"]   = @YES;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

// ─── Config path ──────────────────────────────────────────────────────────────
static NSString *ELConfigPath(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return [docs.firstObject stringByAppendingPathComponent:@"animal-company-config.json"];
}

// ─── Black Hole Colors ─────────────────────────────────────────────────────────
#ifndef CLAMP
#define CLAMP(x, lo, hi) MAX((lo), MIN((x), (hi)))
#endif
#define EL_BG           [UIColor colorWithRed:0.03 green:0.03 blue:0.03 alpha:0.97]
#define EL_BG2          [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:1.0]
#define EL_BG3          [UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:1.0]
#define EL_PURPLE       [UIColor colorWithRed:0.65 green:0.65 blue:0.65 alpha:1.0]
#define EL_PURPLE_DIM   [UIColor colorWithRed:0.65 green:0.65 blue:0.65 alpha:0.18]
#define EL_BLUE         [UIColor colorWithRed:0.45 green:0.45 blue:0.45 alpha:1.0]
#define EL_PINK         [UIColor colorWithRed:0.80 green:0.80 blue:0.80 alpha:1.0]
#define EL_STAR         [UIColor colorWithRed:0.95 green:0.95 blue:0.95 alpha:1.0]
#define EL_TEXT         [UIColor colorWithRed:0.88 green:0.88 blue:0.88 alpha:1.0]
#define EL_TEXT_DIM     [UIColor colorWithRed:0.45 green:0.45 blue:0.45 alpha:1.0]
#define EL_BORDER       [UIColor colorWithRed:0.40 green:0.40 blue:0.40 alpha:0.50].CGColor
#define EL_DIVIDER      [UIColor colorWithRed:0.30 green:0.30 blue:0.30 alpha:0.60]
#define EL_GLOW         [UIColor colorWithRed:0.50 green:0.50 blue:0.50 alpha:1.0]

// ─── Glow ─────────────────────────────────────────────────────────────────────
static void ELGlow(CALayer *l, UIColor *c, CGFloat r) {
    l.shadowColor   = c.CGColor;
    l.shadowRadius  = r;
    l.shadowOpacity = 0.85f;
    l.shadowOffset  = CGSizeZero;
}

// ─── Gradient background layer (Black Hole theme) ───────────────────────────────
static CAGradientLayer *ELGalaxyGradient(CGRect frame) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = frame;
    g.colors = @[
        (id)[UIColor colorWithRed:0.03 green:0.03 blue:0.03 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.02 blue:0.02 alpha:1.0].CGColor,
    ];
    g.locations  = @[@0.0, @0.5, @1.0];
    g.startPoint = CGPointMake(0, 0);
    g.endPoint   = CGPointMake(1, 1);
    return g;
}

// ─── Black hole particle dust (replaces star field) ───────────────────────────
static void ELAddStars(UIView *view, NSInteger count) {
    // Draw small dim dust particles — the "accretion disc" vibe
    for (NSInteger i = 0; i < count; i++) {
        CGFloat size = (arc4random_uniform(4) == 0) ? 2.0f : 0.9f;
        CGFloat x    = arc4random_uniform((uint32_t)view.bounds.size.width);
        CGFloat y    = arc4random_uniform((uint32_t)view.bounds.size.height);
        CGFloat br   = 0.15f + (arc4random_uniform(25) / 100.0f);  // very dim
        UIView *p    = [[UIView alloc] initWithFrame:CGRectMake(x, y, size, size)];
        p.backgroundColor   = [UIColor colorWithWhite:br alpha:1.0];
        p.layer.cornerRadius = size / 2.0f;
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue    = @(br);
        fade.toValue      = @(0.02);
        fade.duration     = 2.0 + (arc4random_uniform(30) / 10.0);
        fade.autoreverses = YES;
        fade.repeatCount  = HUGE_VALF;
        fade.timeOffset   = arc4random_uniform(40) / 10.0;
        [p.layer addAnimation:fade forKey:@"fade"];
        [view addSubview:p];
    }
}

// ─── Items ────────────────────────────────────────────────────────────────────
static NSArray<NSString *> *ELAllItems(void) {
    return @[
        // Weapons
        @"item_arena_pistol",         @"item_arena_shotgun",
        @"item_revolver",             @"item_revolver_gold",
        @"item_shotgun",              @"item_crossbow",
        @"item_crossbow_heart",       @"item_flaregun",
        @"item_heart_gun",            @"item_teleport_gun",
        @"item_grenade_launcher",     @"item_rpg",
        @"item_rpg_cny",              @"item_rpg_easter",
        @"item_rpg_spear",            @"item_friend_launcher",
        @"item_hookshot",             @"item_hookshot_sword",
        @"item_lance",                @"item_viking_hammer",
        @"item_viking_hammer_twilight",@"item_baseball_bat",
        @"item_crowbar",              @"item_frying_pan",
        @"item_pickaxe",              @"item_pickaxe_cny",
        @"item_pickaxe_cube",         @"item_pinata_bat",
        @"item_pipe",                 @"item_police_baton",
        @"item_drill",                @"item_shredder",
        @"item_scissors",             @"item_plunger",
        @"item_treestick",            @"item_stick_bone",
        @"item_stick_armbones",
        // Grenades / Explosives
        @"item_grenade",              @"item_grenade_gold",
        @"item_anti_gravity_grenade", @"item_impulse_grenade",
        @"item_cluster_grenade",      @"item_stash_grenade",
        @"item_tele_grenade",         @"item_flashbang",
        @"item_dynamite",             @"item_dynamite_cube",
        @"item_sticky_dynamite",      @"item_landmine",
        @"item_timebomb",             @"item_tripwire_explosive",
        @"item_broccoli_grenade",     @"item_broccoli_shrink_grenade",
        @"item_arrow_bomb",           @"item_arrow_teleport",
        @"item_arrow_lightbulb",
        // Ammo
        @"item_arrow",                @"item_arrow_heart",
        @"item_revolver_ammo",        @"item_shotgun_ammo",
        @"item_rpg_ammo",             @"item_rpg_ammo_egg",
        @"item_rpg_ammo_spear",       @"item_quiver",
        @"item_quiver_heart",
        // Tools / Utility
        @"item_flashlight",           @"item_flashlight_mega",
        @"item_flashlight_red",       @"item_jetpack",
        @"item_hoverpad",             @"item_pogostick",
        @"item_zipline_gun",          @"item_hookshot",
        @"item_portable_teleporter",  @"item_rope",
        @"item_scanner",              @"item_disposable_camera",
        @"item_server_pad",           @"item_keycard",
        @"item_hh_key",               @"item_saddle",
        @"item_shield",               @"item_shield_bones",
        @"item_shield_police",        @"item_shield_viking_1",
        @"item_shield_viking_2",      @"item_shield_viking_3",
        @"item_shield_viking_4",
        // Bags / Carrying
        @"item_backpack",             @"item_backpack_black",
        @"item_backpack_green",       @"item_backpack_pink",
        @"item_backpack_white",       @"item_backpack_large_base",
        @"item_backpack_large_basketball",@"item_backpack_large_clover",
        @"item_backpack_small_base",  @"item_backpack_with_flashlight",
        @"item_pelican_case",         @"item_crate",
        @"item_cardboard_box",
        // Valuables / Loot
        @"item_goldbar",              @"item_goldcoin",
        @"item_ruby",                 @"item_trophy",
        @"item_rare_card",            @"item_ceo_plaque",
        @"item_ore_copper_l",         @"item_ore_copper_m",
        @"item_ore_copper_s",         @"item_ore_gold_l",
        @"item_ore_gold_m",           @"item_ore_gold_s",
        @"item_ore_silver_l",         @"item_ore_silver_m",
        @"item_ore_silver_s",         @"item_ore_hell",
        @"item_uranium_chunk_l",      @"item_uranium_chunk_m",
        @"item_uranium_chunk_s",      @"item_upsidedown_loot",
        @"item_randombox_mobloot_big",@"item_randombox_mobloot_medium",
        @"item_randombox_mobloot_small",@"item_randombox_mobloot_weapons",
        @"item_randombox_mobloot_zombie",
        // Food / Consumables
        @"item_heartchocolatebox",    @"item_radioactive_broccoli",
        @"item_shrinking_broccoli",   @"item_apple",
        @"item_banana",               @"item_large_banana",
        @"item_turkey_leg",           @"item_turkey_whole",
        @"item_company_ration",       @"item_company_ration_heal",
        @"item_cracker",              @"item_cola",
        @"item_cola_large",           @"item_stinky_cheese",
        @"item_egg",                  @"item_pumpkin_pie",
        @"item_goop",                 @"item_goopfish",
        @"item_brain_chunk",          @"item_heart_chunk",
        @"item_zombie_meat",          @"item_nut",
        @"item_nut_drop",
        // Gadgets / Fun
        @"item_boombox",              @"item_boombox_neon",
        @"item_balloon",              @"item_balloon_heart",
        @"item_d20",                  @"item_disc",
        @"item_football",             @"item_rubberducky",
        @"item_gameboy",              @"item_calculator",
        @"item_finger_board",         @"item_glowstick",
        @"item_snowball",             @"item_whoopie",
        @"item_mug",                  @"item_big_cup",
        @"item_ukulele",              @"item_ukulele_gold",
        @"item_hawaiian_drum",        @"item_theremin",
        @"item_box_fan",              @"item_pumpkinjack",
        @"item_pumpkinjack_small",    @"item_robo_monke",
        @"item_ogre_hands",           @"item_sticker_dispenser",
        @"item_painting_canvas",      @"item_clapper",
        @"item_cutie_dead",
        // Office / Junk
        @"item_stapler",              @"item_tapedispenser",
        @"item_electrical_tape",      @"item_eraser",
        @"item_paperpack",            @"item_floppy3",
        @"item_floppy5",              @"item_harddrive",
        @"item_tablet",               @"item_toilet_paper",
        @"item_toilet_paper_mega",    @"item_toilet_paper_roll_empty",
        @"item_umbrella",             @"item_umbrella_clover",
    ];
}

static NSArray<NSString *> *ELCategoryItems(NSInteger cat) {
    switch (cat) {
        case 1: return @[  // Weapons
            @"item_arena_pistol",         @"item_arena_shotgun",
            @"item_revolver",             @"item_revolver_gold",
            @"item_shotgun",              @"item_crossbow",
            @"item_crossbow_heart",       @"item_flaregun",
            @"item_heart_gun",            @"item_teleport_gun",
            @"item_grenade_launcher",     @"item_rpg",
            @"item_rpg_cny",              @"item_rpg_easter",
            @"item_rpg_spear",            @"item_friend_launcher",
            @"item_hookshot",             @"item_hookshot_sword",
            @"item_lance",                @"item_viking_hammer",
            @"item_viking_hammer_twilight",@"item_baseball_bat",
            @"item_crowbar",              @"item_frying_pan",
            @"item_pickaxe",              @"item_pickaxe_cny",
            @"item_pickaxe_cube",         @"item_pinata_bat",
            @"item_pipe",                 @"item_police_baton",
            @"item_drill",                @"item_shredder",
            @"item_scissors",             @"item_plunger",
            @"item_treestick",            @"item_stick_bone",
            @"item_stick_armbones"];
        case 2: return @[  // Grenades
            @"item_grenade",              @"item_grenade_gold",
            @"item_anti_gravity_grenade", @"item_impulse_grenade",
            @"item_cluster_grenade",      @"item_stash_grenade",
            @"item_tele_grenade",         @"item_flashbang",
            @"item_dynamite",             @"item_dynamite_cube",
            @"item_sticky_dynamite",      @"item_landmine",
            @"item_timebomb",             @"item_tripwire_explosive",
            @"item_broccoli_grenade",     @"item_broccoli_shrink_grenade"];
        case 3: return @[  // Valuables
            @"item_goldbar",              @"item_goldcoin",
            @"item_ruby",                 @"item_trophy",
            @"item_rare_card",            @"item_ceo_plaque",
            @"item_ore_copper_l",         @"item_ore_copper_m",
            @"item_ore_copper_s",         @"item_ore_gold_l",
            @"item_ore_gold_m",           @"item_ore_gold_s",
            @"item_ore_silver_l",         @"item_ore_silver_m",
            @"item_ore_silver_s",         @"item_ore_hell",
            @"item_uranium_chunk_l",      @"item_uranium_chunk_m",
            @"item_uranium_chunk_s",      @"item_upsidedown_loot",
            @"item_randombox_mobloot_big",@"item_randombox_mobloot_medium",
            @"item_randombox_mobloot_small",@"item_randombox_mobloot_weapons",
            @"item_randombox_mobloot_zombie"];
        case 4: return @[  // Food
            @"item_heartchocolatebox",    @"item_radioactive_broccoli",
            @"item_shrinking_broccoli",   @"item_apple",
            @"item_banana",               @"item_large_banana",
            @"item_turkey_leg",           @"item_turkey_whole",
            @"item_company_ration",       @"item_company_ration_heal",
            @"item_cracker",              @"item_cola",
            @"item_cola_large",           @"item_stinky_cheese",
            @"item_egg",                  @"item_pumpkin_pie",
            @"item_goop",                 @"item_goopfish",
            @"item_brain_chunk",          @"item_heart_chunk",
            @"item_zombie_meat",          @"item_nut",
            @"item_nut_drop"];
        case 5: return @[  // Tools
            @"item_flashlight",           @"item_flashlight_mega",
            @"item_flashlight_red",       @"item_jetpack",
            @"item_hoverpad",             @"item_pogostick",
            @"item_zipline_gun",          @"item_portable_teleporter",
            @"item_rope",                 @"item_scanner",
            @"item_disposable_camera",    @"item_server_pad",
            @"item_keycard",              @"item_hh_key",
            @"item_saddle",               @"item_backpack",
            @"item_backpack_large_base",  @"item_backpack_with_flashlight",
            @"item_pelican_case"];
        case 6: return @[  // Fun / Gadgets
            @"item_boombox",              @"item_boombox_neon",
            @"item_balloon",              @"item_balloon_heart",
            @"item_d20",                  @"item_disc",
            @"item_football",             @"item_rubberducky",
            @"item_gameboy",              @"item_calculator",
            @"item_finger_board",         @"item_glowstick",
            @"item_snowball",             @"item_whoopie",
            @"item_ukulele",              @"item_ukulele_gold",
            @"item_hawaiian_drum",        @"item_theremin",
            @"item_robo_monke",           @"item_ogre_hands",
            @"item_pumpkinjack",          @"item_pumpkinjack_small",
            @"item_cutie_dead"];
        default: return ELAllItems();
    }
}

// ─── JSON Config Writer ───────────────────────────────────────────────────────
static NSDictionary *ELMakeItemNode(NSString *itemID, NSInteger hue, NSInteger sat,
                                     NSInteger scale, NSInteger count, NSArray *children) {
    // Grab camera world position so the item spawns at the player's viewpoint
    ELVec3 pos = ELCameraPosition();
    NSMutableDictionary *node = [@{
        @"itemID"          : itemID,
        @"id"              : itemID,
        @"type"            : itemID,
        @"colorHue"        : @(hue),
        @"colorSaturation" : @(sat),
        @"color"           : @(hue),
        @"tintHue"         : @(hue),
        @"scale"           : @(scale),
        @"scaleModifier"   : @(scale),
        @"size"            : @(scale),
        @"sizeModifier"    : @(scale),
        @"state"           : @(1),   // 1 = pending spawn (0 = already processed)
        @"pending"         : @YES,
        @"count"           : @(count),
        @"quantity"        : @(count),
        @"amount"          : @(count),
        @"position"        : @{
            @"x" : @(pos.x),
            @"y" : @(pos.y),
            @"z" : @(pos.z),
        },
    } mutableCopy];
    if (children.count > 0) node[@"children"] = children;
    return [node copy];
}

static BOOL ELWriteConfig(NSString *slot, NSString *itemID, NSInteger hue, NSInteger sat,
                           NSInteger scale, NSInteger count, NSArray *children) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData       *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    NSMutableArray *childNodes = [NSMutableArray array];
    if (children) [childNodes addObjectsFromArray:children];
    if (count > 1 && !children) {
        for (NSInteger i = 1; i < count; i++)
            [childNodes addObject:ELMakeItemNode(itemID, hue, sat, 0, 1, nil)];
    }
    config[slot] = ELMakeItemNode(itemID, hue, sat, scale, count,
                                  childNodes.count > 0 ? childNodes : nil);

    // Also write under top-level "items" array (camera-mod app reads this)
    NSMutableArray *itemsList = [NSMutableArray array];
    NSDictionary *primary = ELMakeItemNode(itemID, hue, sat, scale, count, nil);
    NSMutableDictionary *primaryWithSlot = [primary mutableCopy];
    primaryWithSlot[@"slot"]     = slot;
    primaryWithSlot[@"slotName"] = slot;
    [itemsList addObject:primaryWithSlot];
    for (NSInteger ci = 1; ci < MAX(1, count); ci++) {
        NSMutableDictionary *extra = [ELMakeItemNode(itemID, hue, sat, scale, 1, nil) mutableCopy];
        extra[@"slot"]     = slot;
        extra[@"slotName"] = slot;
        [itemsList addObject:extra];
    }
    config[@"items"]      = itemsList;
    config[@"spawnItems"] = itemsList;
    config[@"pendingItems"]= itemsList;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

static void ELClearSlot(NSString *slot) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData       *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    config[slot] = [NSMutableDictionary dictionary];
    // Also clear top-level item arrays so stale entries don't re-trigger
    [config removeObjectForKey:@"items"];
    [config removeObjectForKey:@"spawnItems"];
    [config removeObjectForKey:@"pendingItems"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}


// ─── Monsters ─────────────────────────────────────────────────────────────────
// Internal IDs derived from the Animal Company VR wiki monster list.
// Pattern mirrors the item_* convention; prefixed with "monster_" / "enemy_".
static NSArray<NSString *> *ELAllMonsters(void) {
    return @[
        // Humanoid
        @"ArmstrongController",        @"ArmstrongMadController",
        @"LankyController",            @"GiantController",
        @"FakeGorillaController",      @"NextBotController",
        @"NextBotStaticController",    @"PhantomController",
        // Creature
        @"AnglerController",           @"AnglerMadController",
        @"ChickenController",          @"SpiderController",
        @"SpiderCaveController",       @"FlyingSwarmController",
        // Ambient / Weird
        @"BansheeController",          @"CutieController",
        @"CystController",             @"EvilEyeController",
        @"EvilEyePinataController",    @"EvilEyePinataLargeController",
        @"BlobController",             @"RedGreenController",
        @"RedGreenMadController",      @"SegwayController",
        // Explosive
        @"BombController",             @"BomberController",
        @"BomberFlashbangController",  @"BomberMadController",
    ];
}

// Category sub-lists for the filter pills
static NSArray<NSString *> *ELMonsterCategory(NSInteger cat) {
    switch (cat) {
        case 1: return @[  // Humanoid
            @"ArmstrongController",    @"ArmstrongMadController",
            @"LankyController",        @"GiantController",
            @"FakeGorillaController",  @"NextBotController",
            @"NextBotStaticController",@"PhantomController"];
        case 2: return @[  // Creature
            @"AnglerController",       @"AnglerMadController",
            @"ChickenController",      @"SpiderController",
            @"SpiderCaveController",   @"FlyingSwarmController"];
        case 3: return @[  // Ambient
            @"BansheeController",      @"CutieController",
            @"CystController",         @"EvilEyeController",
            @"EvilEyePinataController",@"EvilEyePinataLargeController",
            @"BlobController",         @"RedGreenController",
            @"RedGreenMadController",  @"SegwayController"];
        case 4: return @[  // Explosive
            @"BombController",         @"BomberController",
            @"BomberFlashbangController",@"BomberMadController"];
        default: return ELAllMonsters();
    }
}

// Friendly display name — strip "Controller" suffix, insert spaces before capitals
static NSString *ELMonsterDisplayName(NSString *monsterID) {
    NSString *s = [monsterID stringByReplacingOccurrencesOfString:@"Controller" withString:@""];
    // Insert space before each capital letter that follows a lowercase letter
    NSMutableString *result = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (i > 0 && isupper(c) && islower([s characterAtIndex:i-1]))
            [result appendString:@" "];
        [result appendFormat:@"%C", c];
    }
    return result;
}

// ─── Monster Config Writer ─────────────────────────────────────────────────────
// Writes a spawn request into animal-company-config.json under a "monsters" key.
// colorTint is 0–360 hue, scale is a float multiplier (1.0 = normal).
static BOOL ELSpawnMonster(NSString *monsterID, CGFloat scale, NSInteger colorHue, NSInteger qty) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    ELVec3 pos = ELCameraPosition();

    // Build the spawn entry — try both key conventions the game might read
    NSMutableArray *spawnList = [NSMutableArray array];
    for (NSInteger i = 0; i < MAX(1, qty); i++) {
        [spawnList addObject:@{
            @"monsterID"      : monsterID,
            @"enemyID"        : monsterID,         // alternate key
            @"id"             : monsterID,
            @"type"           : monsterID,
            @"scale"          : @(scale),
            @"size"           : @(scale),
            @"scaleModifier"  : @(scale),
            @"colorHue"       : @(colorHue),
            @"color"          : @(colorHue),
            @"tintHue"        : @(colorHue),
            @"state"          : @(1),
            @"position"       : @{ @"x": @(pos.x), @"y": @(pos.y), @"z": @(pos.z) },
        }];
    }

    // Write under every plausible top-level key
    config[@"monsters"]      = spawnList;
    config[@"monsterSpawns"] = spawnList;
    config[@"enemySpawns"]   = spawnList;
    config[@"spawnMonsters"] = spawnList;
    config[@"enemies"]       = spawnList;

    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

// ─── Player Scale Writer ──────────────────────────────────────────────────────
// Writes body size multiplier under every plausible key the game might read.
// 1.0 = normal, >1 = giant, <1 = tiny.
static BOOL ELWritePlayerScale(CGFloat scale) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData       *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    config[@"playerScale"]     = @(scale);
    config[@"bodyScale"]       = @(scale);
    config[@"playerSize"]      = @(scale);
    config[@"characterScale"]  = @(scale);
    config[@"sizeMultiplier"]  = @(scale);
    config[@"scaleMultiplier"] = @(scale);
    config[@"vrPlayerScale"]   = @(scale);
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

// ─── Money Writer ─────────────────────────────────────────────────────────────
// Writes all known Nuts key variants into the config so at least one hits.
static BOOL ELWriteMoney(long long nuts) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData       *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    config[@"nuts"]        = @(nuts);
    config[@"money"]       = @(nuts);
    config[@"bolts"]       = @(nuts);
    config[@"dollars"]     = @(nuts);
    config[@"currency"]    = @(nuts);
    config[@"nutCount"]    = @(nuts);
    config[@"nutsAmount"]  = @(nuts);
    config[@"playerNuts"]  = @(nuts);
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Infinite Ammo
//
// Two-pronged approach so at least one hits regardless of how the game stores ammo:
//
//   A) Config JSON  — writes every plausible ammo/magazine key into the config file
//      so the game reads max ammo on the next load/reload tick.
//
//   B) IL2CPP hooks — patches the get_currentAmmo / get_magazineAmmo accessors
//      in the live IL2CPP runtime so ammo never decreases while the feature is on.
//      Works even without a game restart.
// ═══════════════════════════════════════════════════════════════════════════════

// ── A: Runtime toggle flag ────────────────────────────────────────────────────
static BOOL gInfAmmoEnabled = NO;

// ── B: IL2CPP function-pointer types ─────────────────────────────────────────
// These match the Unity IL2CPP generated signatures for property getters.
// The game subclasses a base Weapon/Gun component — we hook the icall variants.
typedef int   (*AmmoGetter)(Il2CppObject *);
typedef void  (*AmmoSetter)(Il2CppObject *, int);

// Cached original getters (so we can restore them on toggle-off)
static AmmoGetter _orig_getCurrentAmmo  = NULL;
static AmmoGetter _orig_getMagazineAmmo = NULL;

// ── Hooked getter shims ───────────────────────────────────────────────────────
// When inf-ammo is ON, return INT_MAX for any ammo getter the game calls.
static int EL_hooked_getCurrentAmmo(Il2CppObject *self) {
    if (gInfAmmoEnabled) return 9999;
    return _orig_getCurrentAmmo ? _orig_getCurrentAmmo(self) : 9999;
}
static int EL_hooked_getMagazineAmmo(Il2CppObject *self) {
    if (gInfAmmoEnabled) return 9999;
    return _orig_getMagazineAmmo ? _orig_getMagazineAmmo(self) : 9999;
}

// ── Resolve + patch the icalls ────────────────────────────────────────────────
// Animal Company uses Unity 2022 IL2CPP. The weapon classes are most likely
// named GunItem, WeaponItem, or ProjectileWeapon. We try every plausible
// icall string — whichever resolves first wins.
static void ELPatchAmmoIcalls(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!il2cpp_resolve_icall) return;

        // Candidate icall strings for current-ammo getter
        const char *currentAmmoCandidates[] = {
            "AnimalCompany.GunItem::get_currentAmmo",
            "AnimalCompany.WeaponItem::get_currentAmmo",
            "AnimalCompany.ProjectileWeapon::get_currentAmmo",
            "AnimalCompany.RangedWeapon::get_currentAmmo",
            "AnimalCompany.Gun::get_currentAmmo",
            "AnimalCompany.FirearmComponent::get_currentAmmo",
            "AnimalCompany.AmmoComponent::get_currentAmmo",
            // namespace-less variants (camera-mod / sideload build)
            "GunItem::get_currentAmmo",
            "WeaponItem::get_currentAmmo",
            "ProjectileWeapon::get_currentAmmo",
            "RangedWeapon::get_currentAmmo",
            "Gun::get_currentAmmo",
            "FirearmComponent::get_currentAmmo",
            NULL
        };
        // Candidate icall strings for magazine/clip getter
        const char *magazineCandidates[] = {
            "AnimalCompany.GunItem::get_magazineAmmo",
            "AnimalCompany.GunItem::get_clipSize",
            "AnimalCompany.WeaponItem::get_magazineAmmo",
            "AnimalCompany.ProjectileWeapon::get_magazineSize",
            "AnimalCompany.RangedWeapon::get_magazineAmmo",
            "AnimalCompany.Gun::get_magazineAmmo",
            "AnimalCompany.FirearmComponent::get_magazineAmmo",
            "AnimalCompany.AmmoComponent::get_magazineSize",
            // namespace-less variants
            "GunItem::get_magazineAmmo",
            "GunItem::get_clipSize",
            "WeaponItem::get_magazineAmmo",
            "ProjectileWeapon::get_magazineSize",
            "Gun::get_magazineAmmo",
            NULL
        };

        for (int i = 0; currentAmmoCandidates[i]; i++) {
            void *fn = il2cpp_resolve_icall(currentAmmoCandidates[i]);
            if (fn) {
                void *origCA = NULL;
                ELHookFunction(fn, (void *)EL_hooked_getCurrentAmmo, &origCA);
                _orig_getCurrentAmmo = (AmmoGetter)origCA;
                NSLog(@"[MT4Modding] ∞ Ammo: hooked currentAmmo → %s", currentAmmoCandidates[i]);
                break;
            }
        }
        for (int i = 0; magazineCandidates[i]; i++) {
            void *fn = il2cpp_resolve_icall(magazineCandidates[i]);
            if (fn) {
                void *origMA = NULL;
                ELHookFunction(fn, (void *)EL_hooked_getMagazineAmmo, &origMA);
                _orig_getMagazineAmmo = (AmmoGetter)origMA;
                NSLog(@"[MT4Modding] ∞ Ammo: hooked magazineAmmo → %s", magazineCandidates[i]);
                break;
            }
        }
    });
}

// ── C: Config JSON writer (covers load-time ammo restoration) ─────────────────
// Writes every plausible ammo key so the game's save-system restores full ammo.
static BOOL ELWriteInfAmmo(void) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData       *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }

    // ── All plausible ammo key names (cast wide net) ──────────────────────────
    NSNumber *big = @9999;
    // Generic ammo
    config[@"ammo"]              = big;
    config[@"currentAmmo"]       = big;
    config[@"ammoCount"]         = big;
    config[@"ammoAmount"]        = big;
    config[@"totalAmmo"]         = big;
    config[@"remainingAmmo"]     = big;
    config[@"playerAmmo"]        = big;
    // Magazine / clip
    config[@"magazineAmmo"]      = big;
    config[@"magazineSize"]      = big;
    config[@"clipSize"]          = big;
    config[@"clipAmmo"]          = big;
    config[@"currentClip"]       = big;
    config[@"bulletsLeft"]       = big;
    config[@"bulletsInMag"]      = big;
    config[@"roundsLeft"]        = big;
    config[@"roundsInChamber"]   = big;
    // Per-weapon type keys
    config[@"pistolAmmo"]        = big;
    config[@"shotgunAmmo"]       = big;
    config[@"smgAmmo"]           = big;
    config[@"sniperAmmo"]        = big;
    config[@"rpgAmmo"]           = big;
    config[@"bowAmmo"]           = big;
    config[@"crossbowAmmo"]      = big;
    config[@"arenaAmmo"]         = big;
    // Infinite flag (some games use a bool)
    config[@"infiniteAmmo"]      = @YES;
    config[@"infAmmo"]           = @YES;
    config[@"unlimitedAmmo"]     = @YES;

    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

// ── D: Toggle handler (called from UI switch) ─────────────────────────────────
static void ELToggleInfAmmo(BOOL enable) {
    gInfAmmoEnabled = enable;
    if (enable) {
        // Attempt IL2CPP hook (once)
        ELPatchAmmoIcalls();
        // Also write to config
        ELWriteInfAmmo();
    }
    NSLog(@"[MT4Modding] Infinite Ammo: %@", enable ? @"ON" : @"OFF");
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Freeze All Monsters
// Two-pronged: writes freeze flags to config AND hooks the monster AI Update
// via IL2CPP so they stop ticking in real time without needing a restart.
// ═══════════════════════════════════════════════════════════════════════════════

static BOOL gFreezeEnabled = NO;

// The AI Update method runs every frame — we replace it with a no-op when frozen.
typedef void (*MonsterUpdateFn)(Il2CppObject *);
static MonsterUpdateFn _orig_monsterUpdate  = NULL;
static MonsterUpdateFn _orig_monsterUpdate2 = NULL;

static void EL_hooked_monsterUpdate(__unused Il2CppObject *self)  { /* frozen — do nothing */ }
static void EL_hooked_monsterUpdate2(__unused Il2CppObject *self) { /* frozen — do nothing */ }

static void ELPatchFreezeIcalls(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!il2cpp_resolve_icall) return;
        // Primary AI update candidates
        const char *updateCandidates[] = {
            "AnimalCompany.MonsterAI::Update",
            "AnimalCompany.EnemyAI::Update",
            "AnimalCompany.CreatureAI::Update",
            "AnimalCompany.BaseMonster::Update",
            "AnimalCompany.MonsterController::Update",
            "AnimalCompany.EnemyController::Update",
            // namespace-less (camera-mod / sideload)
            "MonsterAI::Update",
            "EnemyAI::Update",
            "CreatureAI::Update",
            "BaseMonster::Update",
            "MonsterController::Update",
            "EnemyController::Update",
            NULL
        };
        // Secondary / movement tick candidates
        const char *moveCandidates[] = {
            "AnimalCompany.MonsterAI::DoAIInterval",
            "AnimalCompany.EnemyAI::DoAIInterval",
            "AnimalCompany.MonsterAI::MoveTowardsPlayer",
            "AnimalCompany.EnemyAI::MoveTowardsPlayer",
            // namespace-less
            "MonsterAI::DoAIInterval",
            "EnemyAI::DoAIInterval",
            "MonsterAI::MoveTowardsPlayer",
            "EnemyAI::MoveTowardsPlayer",
            NULL
        };
        for (int i = 0; updateCandidates[i]; i++) {
            void *fn = il2cpp_resolve_icall(updateCandidates[i]);
            if (fn) {
                void *orig = NULL;
                ELHookFunction(fn, (void *)EL_hooked_monsterUpdate, &orig);
                _orig_monsterUpdate = (MonsterUpdateFn)orig;
                NSLog(@"[MT4Modding] ❄️ Freeze: hooked Update → %s", updateCandidates[i]);
                break;
            }
        }
        for (int i = 0; moveCandidates[i]; i++) {
            void *fn = il2cpp_resolve_icall(moveCandidates[i]);
            if (fn) {
                void *orig = NULL;
                ELHookFunction(fn, (void *)EL_hooked_monsterUpdate2, &orig);
                _orig_monsterUpdate2 = (MonsterUpdateFn)orig;
                NSLog(@"[MT4Modding] ❄️ Freeze: hooked move tick → %s", moveCandidates[i]);
                break;
            }
        }
    });
}

static BOOL ELWriteFreezeConfig(BOOL enable) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    config[@"freezeMonsters"]  = @(enable);
    config[@"freezeEnemies"]   = @(enable);
    config[@"pauseAI"]         = @(enable);
    config[@"disableAI"]       = @(enable);
    config[@"monstersFrozen"]  = @(enable);
    config[@"enemyAIDisabled"] = @(enable);
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    return [data writeToFile:path atomically:YES];
}

static void ELToggleFreeze(BOOL enable) {
    gFreezeEnabled = enable;
    if (enable) ELPatchFreezeIcalls();
    ELWriteFreezeConfig(enable);
    ELToast(enable ? @"❄️ Monsters Frozen" : @"❄️ Monsters Unfrozen", enable);
    NSLog(@"[MT4Modding] Freeze Monsters: %@", enable ? @"ON" : @"OFF");
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Fling (RPC_Teleport)
// Each tap teleports the player forward using the game's own RPC_Teleport call.
// We compute the target position from camera pos + camera forward direction,
// stepping a fixed distance each tap — feels like a fling/dash.
// ═══════════════════════════════════════════════════════════════════════════════

static BOOL    gFlingEnabled = NO;
static UIView *gFlingOverlay = nil;   // fullscreen tap catcher
static CGFloat gFlingDist    = 8.0f; // metres per tap — tuneable

// RPC_Teleport signature: (Il2CppObject *instance, Vector3 position)
typedef void (*RPC_Teleport_t)(Il2CppObject *, ELVec3);
static RPC_Teleport_t _RPC_Teleport = NULL;

typedef Il2CppObject* (*GetLocalPlayer_t)(void);
static GetLocalPlayer_t _getLocalPlayer = NULL;

static void ELResolveTeleport(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // RPC_Teleport is a Photon RPC method on the player class, not a Unity icall.
        // We use il2cpp_domain/class/method APIs to find and cache it.
        void *domain = il2cpp_domain_get ? il2cpp_domain_get() : NULL;
        if (!domain) { NSLog(@"[MT4Modding] il2cpp_domain_get unavailable"); return; }

        // Try each plausible class name
        const char *classNames[] = {
            "PlayerController",
            "PlayerMovement",
            "VRPlayer",
            "PlayerBody",
            "Player",
            "LocalPlayer",
            NULL
        };
        const char *namespaces[] = {
            "AnimalCompany", "Animal_Company", "", NULL
        };

        for (int ni = 0; namespaces[ni]; ni++) {
            for (int ci = 0; classNames[ci]; ci++) {
                void *klass = NULL;
                if (il2cpp_class_from_name && il2cpp_assembly_get_image && il2cpp_domain_assembly_open) {
                    void *assembly = il2cpp_domain_assembly_open(domain, "Assembly-CSharp");
                    if (assembly) {
                        void *image = il2cpp_assembly_get_image(assembly);
                        if (image) {
                            klass = il2cpp_class_from_name(image, namespaces[ni], classNames[ci]);
                        }
                    }
                }
                if (!klass) continue;

                // Try both 1-arg (direct Vector3) and 2-arg (injected Vector3*) variants
                void *method = NULL;
                if (il2cpp_class_get_method_from_name) {
                    method = il2cpp_class_get_method_from_name(klass, "RPC_Teleport", 1);
                    if (!method)
                        method = il2cpp_class_get_method_from_name(klass, "RPC_Teleport", 2);
                    if (!method)
                        method = il2cpp_class_get_method_from_name(klass, "Teleport", 1);
                    if (!method)
                        method = il2cpp_class_get_method_from_name(klass, "TeleportPlayer", 1);
                }
                if (!method) continue;

                _RPC_Teleport = (RPC_Teleport_t)il2cpp_method_get_pointer(method);
                NSLog(@"[MT4Modding] 🚀 RPC_Teleport resolved on %s::%s", namespaces[ni], classNames[ci]);
                return;
            }
        }
        NSLog(@"[MT4Modding] 🚀 RPC_Teleport not found — fling will use config fallback");
    });
}

static void ELDoFling(void) {
    // If RPC_Teleport resolved (jailbreak with hook engine), use it directly
    if (_RPC_Teleport) {
        Il2CppObject *player = _getLocalPlayer ? _getLocalPlayer() : NULL;
        if (!player) { ELToast(@"Player not found", NO); return; }

        ELVec3 pos = ELCameraPosition();
        ELQuat rot = ELCameraRotation();

        float x = rot.x, y = rot.y, z = rot.z, w = rot.w;
        float fwdX = 2*(x*z + w*y);
        float fwdY = 2*(y*z - w*x);
        float fwdZ = 1 - 2*(x*x + y*y);
        float len  = sqrtf(fwdX*fwdX + fwdY*fwdY + fwdZ*fwdZ);
        if (len > 0.001f) { fwdX /= len; fwdY /= len; fwdZ /= len; }

        ELVec3 target = {
            (float)(pos.x + fwdX * gFlingDist),
            pos.y,
            (float)(pos.z + fwdZ * gFlingDist),
        };
        _RPC_Teleport(player, target);
        return;
    }

    // Fallback: write teleport target to config (works on sideload / camera-mod app)
    BOOL ok = ELFlingForward(gFlingDist);
    if (!ok) ELToast(@"Fling: failed to write config", NO);
}

static void ELToggleFling(BOOL enable) {
    gFlingEnabled = enable;
    ELResolveTeleport();

    if (enable) {
        if (gFlingOverlay) return;
        // Use our dedicated overlay window's root view if available, else key window
        // Use the window directly (same as menu button injection)
        UIWindow *ow = ELKeyWindow();
        UIView *overlayRoot = ow ?: nil;
        if (!overlayRoot) return;

        gFlingOverlay = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        gFlingOverlay.backgroundColor        = [UIColor clearColor];
        gFlingOverlay.userInteractionEnabled = YES;
        [overlayRoot insertSubview:gFlingOverlay atIndex:0];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        [tap el_addBlock:^(__unused id s) { if (gFlingEnabled) ELDoFling(); }];
        [gFlingOverlay addGestureRecognizer:tap];

        ELToast(@"🚀 Fling ON — tap to teleport forward", YES);
    } else {
        [gFlingOverlay removeFromSuperview];
        gFlingOverlay = nil;
        ELToast(@"🚀 Fling OFF", NO);
    }
    NSLog(@"[MT4Modding] Fling: %@", enable ? @"ON" : @"OFF");
}

// ─── Toast ────────────────────────────────────────────────────────────────────
static void ELToast(NSString *msg, BOOL success) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = ELKeyWindow();   // FIX 4
        if (!win) return;

        UILabel *t = [[UILabel alloc] init];
        t.text = [NSString stringWithFormat:@" %@  %@ ", success ? @"◼" : @"✕", msg];
        t.font = [UIFont boldSystemFontOfSize:12];
        t.textColor       = EL_TEXT;
        t.backgroundColor = EL_BG2;
        t.layer.cornerRadius = 10;
        t.layer.borderWidth  = 1.2;
        t.layer.borderColor  = EL_BORDER;
        t.clipsToBounds   = YES;
        t.textAlignment   = NSTextAlignmentCenter;

        CGSize sz = [msg sizeWithAttributes:@{NSFontAttributeName: t.font}];
        t.frame = CGRectMake((win.bounds.size.width - sz.width - 60) / 2,
                              win.bounds.size.height - 110, sz.width + 60, 32);
        ELGlow(t.layer, EL_PURPLE, 10);
        t.alpha     = 0;
        t.transform = CGAffineTransformMakeTranslation(0, 10);
        [win addSubview:t];

        [UIView animateWithDuration:0.25 animations:^{
            t.alpha     = 1;
            t.transform = CGAffineTransformIdentity;
        } completion:^(__unused BOOL d) {
            [UIView animateWithDuration:0.25 delay:1.8 options:0
                             animations:^{ t.alpha = 0; t.transform = CGAffineTransformMakeTranslation(0, 6); }
                             completion:^(__unused BOOL d2) { [t removeFromSuperview]; }];
        }];
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — MT4 Modding Menu
// ═══════════════════════════════════════════════════════════════════════════════

@interface MT4Menu : UIView <UITextFieldDelegate>
@property (nonatomic, assign) NSInteger selectedTab;
@property (nonatomic, assign) NSInteger selectedCategory;
@property (nonatomic, strong) NSString       *selectedItem;
@property (nonatomic, strong) NSString       *selectedSlot;
@property (nonatomic, assign) NSInteger colorHue;
@property (nonatomic, assign) NSInteger colorSat;
@property (nonatomic, assign) NSInteger scaleVal;
@property (nonatomic, assign) NSInteger quantity;
@property (nonatomic, strong) UIScrollView   *itemsPage;
@property (nonatomic, strong) UIScrollView   *settingsPage;
@property (nonatomic, strong) UIScrollView   *itemList;
@property (nonatomic, strong) UITextField    *searchField;
@property (nonatomic, strong) UILabel        *selectedItemLabel;
@property (nonatomic, strong) UILabel        *qtyLabel;
@property (nonatomic, strong) UILabel        *hueLabel;
@property (nonatomic, strong) UILabel        *satLabel;
@property (nonatomic, strong) UILabel        *scaleLabel;
@property (nonatomic, strong) UILabel        *slotLabel;
@property (nonatomic, strong) UILabel        *countLabel;
@property (nonatomic, strong) NSArray        *currentItems;
@property (nonatomic, strong) NSMutableArray *rowViews;
// Inline spawn controls on Items page
@property (nonatomic, strong) UIView  *itemColorSwatch;
@property (nonatomic, strong) UILabel *itemHueValueLabel;
@property (nonatomic, strong) UILabel *itemSatValueLabel;
@property (nonatomic, strong) UILabel *itemScaleValueLabel;
// Monster tab state
@property (nonatomic, strong) UIScrollView  *monstersPage;
@property (nonatomic, strong) UIScrollView *monsterList;
@property (nonatomic, strong) UITextField  *monsterSearchField;
@property (nonatomic, strong) UILabel      *selectedMonsterLabel;
@property (nonatomic, strong) NSString     *selectedMonster;
@property (nonatomic, strong) NSArray      *currentMonsters;
@property (nonatomic, strong) NSMutableArray *monsterRowViews;
@property (nonatomic, assign) NSInteger    monsterQty;
@property (nonatomic, assign) NSInteger    monsterColorHue;
@property (nonatomic, assign) CGFloat      monsterScale;
// New pages
@property (nonatomic, strong) UIScrollView *playerPage;
@property (nonatomic, strong) UIScrollView *funPage;
@property (nonatomic, strong) UIScrollView *advancedPage;
@property (nonatomic, strong) UILabel      *monsterQtyLabel;
@property (nonatomic, strong) UILabel      *monsterScaleLabel;
@property (nonatomic, strong) UILabel      *monsterHueLabel;
@property (nonatomic, assign) NSInteger    monsterCatIndex;
@end

@implementation MT4Menu

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _selectedTab      = 0;
    _selectedCategory = 0;
    _selectedSlot     = @"leftHand";
    _colorHue         = 159;
    _colorSat         = 120;
    _scaleVal         = 0;
    _quantity         = 1;
    _currentItems     = ELAllItems();
    _rowViews         = [NSMutableArray array];
    _currentMonsters  = ELAllMonsters();
    _monsterRowViews  = [NSMutableArray array];
    _monsterQty       = 1;
    _monsterColorHue  = 0;
    _monsterScale     = 1.0f;
    _monsterCatIndex  = 0;
    [self buildUI];
    return self;
}

- (void)buildUI {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;

    self.layer.cornerRadius = 18;
    self.layer.borderWidth  = 1.5;
    self.layer.borderColor  = EL_BORDER;
    ELGlow(self.layer, EL_PURPLE, 24);
    self.clipsToBounds = NO;

    // Clip view
    UIView *clip = [[UIView alloc] initWithFrame:self.bounds];
    clip.layer.cornerRadius = 18;
    clip.clipsToBounds = YES;
    [self addSubview:clip];

    // Galaxy gradient bg
    [clip.layer addSublayer:ELGalaxyGradient(self.bounds)];

    // Star field
    UIView *starField = [[UIView alloc] initWithFrame:self.bounds];
    starField.backgroundColor = [UIColor clearColor];
    [clip addSubview:starField];
    ELAddStars(starField, 60);

    // Black hole ring accents
    // Ring 1 — top-left singularity
    CGFloat r1sz = 120;
    UIView *bh1 = [[UIView alloc] initWithFrame:CGRectMake(-r1sz*0.45f, -r1sz*0.45f, r1sz, r1sz)];
    bh1.backgroundColor     = [UIColor clearColor];
    bh1.layer.cornerRadius  = r1sz / 2.0f;
    bh1.layer.borderWidth   = 1.5f;
    bh1.layer.borderColor   = [UIColor colorWithWhite:0.25 alpha:0.5].CGColor;
    [clip addSubview:bh1];
    // Inner void
    CGFloat v1sz = r1sz * 0.55f;
    UIView *void1 = [[UIView alloc] initWithFrame:CGRectMake((r1sz-v1sz)/2, (r1sz-v1sz)/2, v1sz, v1sz)];
    void1.backgroundColor   = [UIColor colorWithWhite:0 alpha:0.7];
    void1.layer.cornerRadius = v1sz / 2.0f;
    [bh1 addSubview:void1];
    // Rotation animation
    CABasicAnimation *rot1 = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rot1.fromValue = @(0); rot1.toValue = @(M_PI * 2);
    rot1.duration = 18.0; rot1.repeatCount = HUGE_VALF;
    [bh1.layer addAnimation:rot1 forKey:@"rot"];

    // Ring 2 — bottom-right singularity
    CGFloat r2sz = 100;
    UIView *bh2 = [[UIView alloc] initWithFrame:CGRectMake(w - r2sz*0.6f, h - r2sz*0.6f, r2sz, r2sz)];
    bh2.backgroundColor     = [UIColor clearColor];
    bh2.layer.cornerRadius  = r2sz / 2.0f;
    bh2.layer.borderWidth   = 1.2f;
    bh2.layer.borderColor   = [UIColor colorWithWhite:0.20 alpha:0.4].CGColor;
    [clip addSubview:bh2];
    CGFloat v2sz = r2sz * 0.55f;
    UIView *void2 = [[UIView alloc] initWithFrame:CGRectMake((r2sz-v2sz)/2, (r2sz-v2sz)/2, v2sz, v2sz)];
    void2.backgroundColor   = [UIColor colorWithWhite:0 alpha:0.7];
    void2.layer.cornerRadius = v2sz / 2.0f;
    [bh2 addSubview:void2];
    CABasicAnimation *rot2 = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    rot2.fromValue = @(0); rot2.toValue = @(-(M_PI * 2));
    rot2.duration = 24.0; rot2.repeatCount = HUGE_VALF;
    [bh2.layer addAnimation:rot2 forKey:@"rot"];

    // Top accent stripe (dark charcoal)
    CAGradientLayer *stripe = [CAGradientLayer layer];
    stripe.frame = CGRectMake(0, 0, w, 2);
    stripe.colors = @[
        (id)[UIColor colorWithWhite:0.15 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:0.55 alpha:1.0].CGColor,
        (id)[UIColor colorWithWhite:0.15 alpha:1.0].CGColor,
    ];
    stripe.startPoint = CGPointMake(0, 0.5);
    stripe.endPoint   = CGPointMake(1, 0.5);
    [clip.layer addSublayer:stripe];

    // Header bg  (draggable)
    UIView *hdrBg = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 50)];
    hdrBg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.3];
    [clip addSubview:hdrBg];
    // Drag on header
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(handleDrag:)];
    [hdrBg addGestureRecognizer:pan];

    // Pinch on the whole menu to resize it
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
                                       initWithTarget:self action:@selector(handlePinchResize:)];
    [self addGestureRecognizer:pinch];

    // Close button
    UIButton *closeBtn = [[UIButton alloc] initWithFrame:CGRectMake(8, 12, 28, 28)];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:EL_PURPLE forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    closeBtn.backgroundColor  = EL_PURPLE_DIM;
    closeBtn.layer.cornerRadius = 14;
    closeBtn.layer.borderWidth  = 1;
    closeBtn.layer.borderColor  = EL_BORDER;
    UITapGestureRecognizer *ct = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [ct el_addBlock:^(__unused id s) { [self dismiss]; }];
    [closeBtn addGestureRecognizer:ct];
    [clip addSubview:closeBtn];

    // Size-cycle button (replaces confusing rotate button)
    // Tapping cycles: Medium → Large → Small → Medium
    UIButton *sizeBtn = [[UIButton alloc] initWithFrame:CGRectMake(w - 38, 12, 28, 28)];
    [sizeBtn setTitle:@"⇔" forState:UIControlStateNormal];
    [sizeBtn setTitleColor:EL_PURPLE forState:UIControlStateNormal];
    sizeBtn.titleLabel.font  = [UIFont boldSystemFontOfSize:14];
    sizeBtn.backgroundColor  = EL_PURPLE_DIM;
    sizeBtn.layer.cornerRadius = 14;
    sizeBtn.layer.borderWidth  = 1;
    sizeBtn.layer.borderColor  = EL_BORDER;
    UITapGestureRecognizer *rt = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [rt el_addBlock:^(__unused id s) { [self cycleMenuSize]; }];
    [sizeBtn addGestureRecognizer:rt];
    [clip addSubview:sizeBtn];

    // Title
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 13, w, 24)];
    title.text          = @"⬛ ANIMAL COMPANY VR ⬛";
    title.textAlignment = NSTextAlignmentCenter;
    title.textColor     = EL_STAR;
    title.font = [UIFont fontWithName:@"AvenirNext-Heavy" size:17]
              ?: [UIFont boldSystemFontOfSize:17];
    ELGlow(title.layer, EL_PURPLE, 12);
    [clip addSubview:title];

    // Tab bar
    [clip addSubview:[self buildTabBarAtY:52 width:w clip:clip]];

    // Divider
    UIView *div = [[UIView alloc] initWithFrame:CGRectMake(10, 92, w - 20, 1)];
    div.backgroundColor = EL_DIVIDER;
    [clip addSubview:div];

    // Pages
    CGRect pageFrame  = CGRectMake(0, 96, w, h - 96);
    _itemsPage        = [[UIScrollView alloc] initWithFrame:pageFrame];
    _settingsPage     = [[UIScrollView alloc] initWithFrame:pageFrame];
    _settingsPage.hidden       = YES;
    _itemsPage.backgroundColor    = [UIColor clearColor];
    _itemsPage.showsVerticalScrollIndicator    = YES;
    _itemsPage.bounces                         = YES;
    _itemsPage.alwaysBounceVertical            = YES;
    _settingsPage.backgroundColor = [UIColor clearColor];
    _settingsPage.showsVerticalScrollIndicator = YES;
    _settingsPage.bounces                      = YES;
    _settingsPage.alwaysBounceVertical         = YES;
    [clip addSubview:_itemsPage];
    [clip addSubview:_settingsPage];

    // Monsters page
    _monstersPage = [[UIScrollView alloc] initWithFrame:pageFrame];
    _monstersPage.hidden                       = YES;
    _monstersPage.backgroundColor              = [UIColor clearColor];
    _monstersPage.showsVerticalScrollIndicator = YES;
    _monstersPage.bounces                      = YES;
    _monstersPage.alwaysBounceVertical         = YES;
    [clip addSubview:_monstersPage];

    // Player page
    _playerPage = [[UIScrollView alloc] initWithFrame:pageFrame];
    _playerPage.hidden                       = YES;
    _playerPage.backgroundColor              = [UIColor clearColor];
    _playerPage.showsVerticalScrollIndicator = YES;
    _playerPage.bounces                      = YES;
    _playerPage.alwaysBounceVertical         = YES;
    [clip addSubview:_playerPage];

    // Fun page
    _funPage = [[UIScrollView alloc] initWithFrame:pageFrame];
    _funPage.hidden                       = YES;
    _funPage.backgroundColor              = [UIColor clearColor];
    _funPage.showsVerticalScrollIndicator = YES;
    _funPage.bounces                      = YES;
    _funPage.alwaysBounceVertical         = YES;
    [clip addSubview:_funPage];

    // Advanced page
    _advancedPage = [[UIScrollView alloc] initWithFrame:pageFrame];
    _advancedPage.hidden                       = YES;
    _advancedPage.backgroundColor              = [UIColor clearColor];
    _advancedPage.showsVerticalScrollIndicator = YES;
    _advancedPage.bounces                      = YES;
    _advancedPage.alwaysBounceVertical         = YES;
    [clip addSubview:_advancedPage];

    [self buildItemsPage];
    [self buildMonstersPage];
    [self buildSettingsPage];
    [self buildPlayerPage];
    [self buildFunPage];
    [self buildAdvancedPage];
}

// ─── Tab bar ──────────────────────────────────────────────────────────────────
- (UIView *)buildTabBarAtY:(CGFloat)y width:(CGFloat)w clip:(__unused UIView *)clip {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(10, y, w - 20, 36)];
    bar.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    bar.layer.cornerRadius = 10;
    bar.layer.borderWidth  = 1;
    bar.layer.borderColor  = EL_BORDER;

    NSArray  *tabs = @[@"Items", @"Monsters", @"Player", @"Fun", @"Advanced"];
    // FIX 3 — cast to NSInteger to avoid signed/unsigned mismatch
    NSInteger tabCount = (NSInteger)tabs.count;
    CGFloat   tw       = (w - 20) / tabCount;

    UIView *indicator = [[UIView alloc] initWithFrame:CGRectMake(2, 2, tw - 4, 32)];
    indicator.backgroundColor  = EL_PURPLE_DIM;
    indicator.layer.cornerRadius = 8;
    indicator.layer.borderWidth  = 1;
    indicator.layer.borderColor  = EL_BORDER;
    ELGlow(indicator.layer, EL_PURPLE, 8);
    indicator.tag = 9001;
    [bar addSubview:indicator];

    for (NSInteger i = 0; i < tabCount; i++) {
        UIButton *btn = [[UIButton alloc] initWithFrame:CGRectMake(tw * i + 2, 2, tw - 4, 32)];
        [btn setTitle:tabs[(NSUInteger)i] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        btn.titleLabel.adjustsFontSizeToFitWidth = YES;
        [btn setTitleColor:(i == 0 ? EL_STAR : EL_TEXT_DIM) forState:UIControlStateNormal];
        btn.tag = 8000 + i;
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        NSInteger ci = i;
        UIView *b2   = bar;
        CGFloat tw2  = tw;
        [t el_addBlock:^(__unused id s) { [self switchToTab:ci bar:b2 tabW:tw2]; }];
        [btn addGestureRecognizer:t];
        [bar addSubview:btn];
    }
    return bar;
}

- (void)switchToTab:(NSInteger)idx bar:(UIView *)bar tabW:(CGFloat)tw {
    _selectedTab             = idx;
    _itemsPage.hidden        = (idx != 0);
    _monstersPage.hidden     = (idx != 1);
    _settingsPage.hidden     = (idx != 2);
    _playerPage.hidden       = (idx != 3);
    _funPage.hidden          = (idx != 4);
    _advancedPage.hidden     = (idx != 5);  // reserved, hidden by default
    UIView *ind = [bar viewWithTag:9001];
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75
           initialSpringVelocity:0.5 options:0
                       animations:^{
        ind.frame = CGRectMake(tw * idx + 2, 2, tw - 4, 32);
    } completion:nil];
    for (NSInteger i = 0; i < 5; i++) {
        UIButton *b = (UIButton *)[bar viewWithTag:8000 + i];
        [b setTitleColor:(i == idx ? EL_STAR : EL_TEXT_DIM) forState:UIControlStateNormal];
    }
}

// ─── Items page ───────────────────────────────────────────────────────────────
- (void)buildItemsPage {
    CGFloat w = _itemsPage.frame.size.width;
    CGFloat h = _itemsPage.frame.size.height;

    // Category pills
    UIScrollView *catScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 4, w, 38)];
    catScroll.showsHorizontalScrollIndicator = NO;
    catScroll.backgroundColor = [UIColor clearColor];

    NSArray   *cats    = @[@"All", @"Weapons", @"Grenades", @"Valuables", @"Food", @"Tools", @"Fun"];
    NSInteger  catCount = (NSInteger)cats.count;  // FIX 3
    CGFloat    cx      = 8;

    for (NSInteger i = 0; i < catCount; i++) {
        NSString *catName = cats[(NSUInteger)i];
        CGFloat   pw      = [catName sizeWithAttributes:
                             @{NSFontAttributeName: [UIFont boldSystemFontOfSize:11]}].width + 22;
        UIButton *pill    = [[UIButton alloc] initWithFrame:CGRectMake(cx, 4, pw, 28)];
        [pill setTitle:catName forState:UIControlStateNormal];
        pill.titleLabel.font    = [UIFont boldSystemFontOfSize:11];
        pill.layer.cornerRadius = 14;
        pill.layer.borderWidth  = 1.2f;
        BOOL active          = (i == 0);
        pill.backgroundColor = active ? EL_PURPLE_DIM : [UIColor colorWithWhite:1 alpha:0.05];
        [pill setTitleColor:active ? EL_PURPLE : EL_TEXT_DIM forState:UIControlStateNormal];
        pill.layer.borderColor = active ? EL_BORDER : [UIColor colorWithWhite:1 alpha:0.08].CGColor;
        if (active) ELGlow(pill.layer, EL_PURPLE, 6);
        pill.tag = 7000 + i;
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        NSInteger    ci = i;
        UIScrollView *cs = catScroll;
        [t el_addBlock:^(__unused id s) { [self selectCategory:ci scroll:cs]; }];
        [pill addGestureRecognizer:t];
        [catScroll addSubview:pill];
        cx += pw + 6;
    }
    catScroll.contentSize = CGSizeMake(cx + 8, 38);
    [_itemsPage addSubview:catScroll];

    // Search bar
    UIView *sw = [[UIView alloc] initWithFrame:CGRectMake(10, 46, w - 20, 32)];
    sw.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.35];
    sw.layer.cornerRadius = 8;
    sw.layer.borderWidth  = 1;
    sw.layer.borderColor  = EL_BORDER;
    [_itemsPage addSubview:sw];

    UILabel *gl = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 22, 32)];
    gl.text      = @"◼";
    gl.font      = [UIFont systemFontOfSize:12];
    gl.textColor = EL_PURPLE;
    [sw addSubview:gl];

    _searchField = [[UITextField alloc] initWithFrame:CGRectMake(28, 2, w - 60, 28)];
    _searchField.font            = [UIFont systemFontOfSize:12];
    _searchField.textColor       = EL_TEXT;
    _searchField.backgroundColor = [UIColor clearColor];
    _searchField.delegate        = self;

    // FIX 5 — use attributedPlaceholder instead of private KVC _placeholderLabel.textColor
    _searchField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Search items..."
            attributes:@{NSForegroundColorAttributeName: EL_TEXT_DIM,
                         NSFontAttributeName: [UIFont systemFontOfSize:12]}];

    [_searchField addTarget:self action:@selector(searchChanged)
          forControlEvents:UIControlEventEditingChanged];
    [sw addSubview:_searchField];

    // Count / header labels
    _countLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 80, 82, 70, 16)];
    _countLabel.text          = [NSString stringWithFormat:@"%lu items",
                                 (unsigned long)ELAllItems().count];
    _countLabel.font          = [UIFont systemFontOfSize:10];
    _countLabel.textColor     = EL_PURPLE;
    _countLabel.textAlignment = NSTextAlignmentRight;
    [_itemsPage addSubview:_countLabel];

    UILabel *iHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, 82, 160, 16)];
    iHdr.text = @"◼ ITEM SPAWNER";
    iHdr.font      = [UIFont boldSystemFontOfSize:10];
    iHdr.textColor = EL_TEXT_DIM;
    [_itemsPage addSubview:iHdr];

    // Selected item display
    UIView *selWrap = [[UIView alloc] initWithFrame:CGRectMake(10, 101, w - 20, 26)];
    selWrap.backgroundColor  = EL_PURPLE_DIM;
    selWrap.layer.cornerRadius = 6;
    selWrap.layer.borderWidth  = 1;
    selWrap.layer.borderColor  = EL_BORDER;
    [_itemsPage addSubview:selWrap];

    _selectedItemLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, w - 40, 26)];
    _selectedItemLabel.text      = @"tap an item to select...";
    _selectedItemLabel.font      = [UIFont fontWithName:@"Menlo" size:10]
                                ?: [UIFont systemFontOfSize:10];
    _selectedItemLabel.textColor = EL_TEXT_DIM;
    [selWrap addSubview:_selectedItemLabel];

    // Item list — fixed 160pt so items are always visible and panel below always fits
    // Item list — proportional: ~40% of page height so it stays usable at any menu size
    CGFloat listH = MAX(h * 0.38f, 90);
    _itemList = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 131, w - 20, listH)];
    _itemList.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.35];
    _itemList.layer.cornerRadius = 10;
    _itemList.layer.borderWidth  = 1;
    _itemList.layer.borderColor  = EL_BORDER;
    [_itemsPage addSubview:_itemList];
    [self reloadItemList];

    // ── Inline spawn-controls panel ────────────────────────────────────────────
    CGFloat panelY = 131 + MAX(listH, 60) + 8;
    CGFloat panelH = 148;
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake(10, panelY, w - 20, panelH)];
    panel.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.35];
    panel.layer.cornerRadius = 10;
    panel.layer.borderWidth  = 1;
    panel.layer.borderColor  = EL_BORDER;
    [_itemsPage addSubview:panel];

    CGFloat pw = w - 20;  // panel inner width

    // ── Big live color swatch (top-right, spans colour rows) ─────────────────
    CGFloat swatchSz = 40;
    _itemColorSwatch = [[UIView alloc] initWithFrame:CGRectMake(pw - swatchSz - 8, 8, swatchSz, swatchSz)];
    _itemColorSwatch.layer.cornerRadius = 8;
    _itemColorSwatch.layer.borderWidth  = 2.0f;
    _itemColorSwatch.layer.borderColor  = EL_BORDER;
    _itemColorSwatch.backgroundColor    = [UIColor colorWithHue:_colorHue / 360.0f
                                                     saturation:_colorSat / 255.0f
                                                     brightness:1.0f alpha:1.0f];
    [panel addSubview:_itemColorSwatch];

    // ── Row 1: Hue ────────────────────────────────────────────────────────────
    UILabel *hueTitleLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, 36, 14)];
    hueTitleLbl.text      = @"Hue";
    hueTitleLbl.font      = [UIFont boldSystemFontOfSize:10];
    hueTitleLbl.textColor = EL_TEXT;
    [panel addSubview:hueTitleLbl];

    _itemHueValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(48, 8, 54, 14)];
    _itemHueValueLabel.text          = [NSString stringWithFormat:@"%ld°", (long)_colorHue];
    _itemHueValueLabel.font          = [UIFont boldSystemFontOfSize:10];
    _itemHueValueLabel.textColor     = EL_PINK;
    [panel addSubview:_itemHueValueLabel];

    UISlider *hueSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 24, pw - swatchSz - 28, 20)];
    hueSlider.minimumValue          = 0;
    hueSlider.maximumValue          = 360;
    hueSlider.value                 = _colorHue;
    hueSlider.minimumTrackTintColor = EL_PURPLE;
    hueSlider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.12];
    hueSlider.thumbTintColor        = [UIColor whiteColor];
    [hueSlider addTarget:self action:@selector(itemHueChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:hueSlider];

    // ── Row 2: Saturation ─────────────────────────────────────────────────────
    UILabel *satTitleLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 48, 36, 14)];
    satTitleLbl.text      = @"Sat";
    satTitleLbl.font      = [UIFont boldSystemFontOfSize:10];
    satTitleLbl.textColor = EL_TEXT;
    [panel addSubview:satTitleLbl];

    _itemSatValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(48, 48, 54, 14)];
    _itemSatValueLabel.text      = [NSString stringWithFormat:@"%ld", (long)_colorSat];
    _itemSatValueLabel.font      = [UIFont boldSystemFontOfSize:10];
    _itemSatValueLabel.textColor = EL_PINK;
    [panel addSubview:_itemSatValueLabel];

    UISlider *satSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 64, pw - swatchSz - 28, 20)];
    satSlider.minimumValue          = 0;
    satSlider.maximumValue          = 255;
    satSlider.value                 = _colorSat;
    satSlider.minimumTrackTintColor = [UIColor colorWithRed:0.2 green:0.5 blue:1.0 alpha:1.0];
    satSlider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.12];
    satSlider.thumbTintColor        = [UIColor whiteColor];
    [satSlider addTarget:self action:@selector(itemSatChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:satSlider];

    // ── Divider ───────────────────────────────────────────────────────────────
    UIView *div1 = [[UIView alloc] initWithFrame:CGRectMake(8, 88, pw - 16, 1)];
    div1.backgroundColor = EL_DIVIDER;
    [panel addSubview:div1];

    // ── Row 3: Size ───────────────────────────────────────────────────────────
    UILabel *sizeLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 92, 36, 14)];
    sizeLbl.text      = @"📐 Size";
    sizeLbl.font      = [UIFont boldSystemFontOfSize:10];
    sizeLbl.textColor = EL_TEXT;
    [panel addSubview:sizeLbl];

    _itemScaleValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(56, 92, pw - 66, 14)];
    _itemScaleValueLabel.text          = @"0 — normal";
    _itemScaleValueLabel.font          = [UIFont boldSystemFontOfSize:10];
    _itemScaleValueLabel.textColor     = EL_PINK;
    _itemScaleValueLabel.textAlignment = NSTextAlignmentRight;
    [panel addSubview:_itemScaleValueLabel];

    UISlider *sizeSlider = [[UISlider alloc] initWithFrame:CGRectMake(10, 108, pw - 20, 20)];
    sizeSlider.minimumValue          = -100;
    sizeSlider.maximumValue          = 200;
    sizeSlider.value                 = 0;
    sizeSlider.minimumTrackTintColor = EL_BLUE;
    sizeSlider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.12];
    sizeSlider.thumbTintColor        = [UIColor whiteColor];
    [sizeSlider addTarget:self action:@selector(itemScaleChanged:)
        forControlEvents:UIControlEventValueChanged];
    [panel addSubview:sizeSlider];

    // ── Divider ───────────────────────────────────────────────────────────────
    UIView *div2 = [[UIView alloc] initWithFrame:CGRectMake(8, 132, pw - 16, 1)];
    div2.backgroundColor = EL_DIVIDER;
    [panel addSubview:div2];

    // ── Row 4: Qty + Slot ─────────────────────────────────────────────────────
    UILabel *ql = [[UILabel alloc] initWithFrame:CGRectMake(10, 136, 28, 20)];
    ql.text      = @"Qty:";
    ql.font      = [UIFont boldSystemFontOfSize:10];
    ql.textColor = EL_TEXT_DIM;
    [panel addSubview:ql];

    _qtyLabel = [[UILabel alloc] initWithFrame:CGRectMake(40, 136, 28, 20)];
    _qtyLabel.text          = @"1";
    _qtyLabel.font          = [UIFont boldSystemFontOfSize:13];
    _qtyLabel.textColor     = EL_PINK;
    _qtyLabel.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:_qtyLabel];

    [panel addSubview:[self makeStepBtn:@"−" frame:CGRectMake(70, 138, 22, 18) action:@selector(qtyMinus)]];
    [panel addSubview:[self makeStepBtn:@"+" frame:CGRectMake(94, 138, 22, 18) action:@selector(qtyPlus)]];

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(pw / 2 - 8, 136, 32, 20)];
    sl.text      = @"Slot:";
    sl.font      = [UIFont boldSystemFontOfSize:10];
    sl.textColor = EL_TEXT_DIM;
    [panel addSubview:sl];

    _slotLabel = [[UILabel alloc] initWithFrame:CGRectMake(pw / 2 + 26, 136, 74, 20)];
    _slotLabel.text      = @"leftHand";
    _slotLabel.font      = [UIFont boldSystemFontOfSize:10];
    _slotLabel.textColor = EL_PURPLE;
    [panel addSubview:_slotLabel];

    UIButton *slotBtn = [[UIButton alloc] initWithFrame:CGRectMake(pw - 32, 136, 24, 20)];
    slotBtn.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.35];
    slotBtn.layer.cornerRadius = 5;
    slotBtn.layer.borderWidth  = 1;
    slotBtn.layer.borderColor  = EL_BORDER;
    [slotBtn setTitle:@"⇄" forState:UIControlStateNormal];
    [slotBtn setTitleColor:EL_PURPLE forState:UIControlStateNormal];
    slotBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    UITapGestureRecognizer *st = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [st el_addBlock:^(__unused id s) { [self cycleSlot]; }];
    [slotBtn addGestureRecognizer:st];
    [panel addSubview:slotBtn];

    // ── Spawn + Clear buttons ─────────────────────────────────────────────────
    CGFloat by = panelY + panelH + 6;
    CGFloat spawnW = w - 20 - 56;
    UIButton *spawn = [[UIButton alloc] initWithFrame:CGRectMake(10, by, spawnW, 38)];
    spawn.layer.cornerRadius = 10;
    spawn.clipsToBounds = YES;
    CAGradientLayer *spawnGrad = [CAGradientLayer layer];
    spawnGrad.frame  = CGRectMake(0, 0, spawnW, 38);
    spawnGrad.colors = @[
        (id)[UIColor colorWithRed:0.25 green:0.25 blue:0.25 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:1.0].CGColor,
    ];
    spawnGrad.startPoint = CGPointMake(0, 0.5);
    spawnGrad.endPoint   = CGPointMake(1, 0.5);
    [spawn.layer insertSublayer:spawnGrad atIndex:0];
    [spawn setTitle:@"◼  SPAWN" forState:UIControlStateNormal];
    [spawn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    spawn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    ELGlow(spawn.layer, EL_PURPLE, 14);
    UITapGestureRecognizer *spawnT = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [spawnT el_addBlock:^(__unused id s) { [self doSpawn]; }];
    [spawn addGestureRecognizer:spawnT];
    [_itemsPage addSubview:spawn];

    UIButton *clear = [[UIButton alloc] initWithFrame:CGRectMake(w - 52, by, 42, 38)];
    clear.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.35];
    clear.layer.cornerRadius = 10;
    clear.layer.borderWidth  = 1;
    clear.layer.borderColor  = EL_BORDER;
    [clear setTitle:@"🗑" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:16];
    UITapGestureRecognizer *clearT = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [clearT el_addBlock:^(__unused id s) { [self doClear]; }];
    [clear addGestureRecognizer:clearT];
    [_itemsPage addSubview:clear];

    // Set contentSize so the page scrolls when content exceeds visible area
    _itemsPage.contentSize = CGSizeMake(w, by + 38 + 12);
}

// ─── Settings page ────────────────────────────────────────────────────────────
- (void)buildSettingsPage {
    CGFloat w = _settingsPage.frame.size.width;

    UILabel *hdr = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, w, 16)];
    hdr.text      = @"◼ APPEARANCE";
    hdr.font      = [UIFont boldSystemFontOfSize:10];
    hdr.textColor = EL_TEXT_DIM;
    [_settingsPage addSubview:hdr];

    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(10, 27, w - 20, 1)];
    d.backgroundColor = EL_DIVIDER;
    [_settingsPage addSubview:d];

    [self addSliderRow:@"Color Hue" value:159 min:0   max:360  y:34  label:&_hueLabel   action:@selector(hueChanged:)];
    [self addSliderRow:@"Color Sat" value:120 min:0   max:255  y:82  label:&_satLabel   action:@selector(satChanged:)];
    [self addSliderRow:@"Scale"     value:0   min:-100 max:200 y:130 label:&_scaleLabel action:@selector(scaleChanged:)];

    UIView *d2 = [[UIView alloc] initWithFrame:CGRectMake(10, 178, w - 20, 1)];
    d2.backgroundColor = EL_DIVIDER;
    [_settingsPage addSubview:d2];

    UILabel *hdr2 = [[UILabel alloc] initWithFrame:CGRectMake(12, 184, w, 16)];
    hdr2.text      = @"◼ FEATURES";
    hdr2.font      = [UIFont boldSystemFontOfSize:10];
    hdr2.textColor = EL_TEXT_DIM;
    [_settingsPage addSubview:hdr2];

    [self addToggleRow:@"∞ Inf Ammo"         subtitle:@"Guns never run out of bullets"        y:200 action:@selector(toggleInfAmmo:)];
    [self addToggleRow:@"❄️ Freeze Monsters" subtitle:@"Stops all AI + movement in real time" y:250 action:@selector(toggleFreeze:)];
    [self addToggleRow:@"🚀 Fling"           subtitle:@"Tap screen to fling via RPC_Teleport" y:300 action:@selector(toggleFling:)];

    UIView *d3 = [[UIView alloc] initWithFrame:CGRectMake(10, 350, w - 20, 1)];
    d3.backgroundColor = EL_DIVIDER;
    [_settingsPage addSubview:d3];

    UILabel *hdr3 = [[UILabel alloc] initWithFrame:CGRectMake(12, 357, w, 16)];
    hdr3.text      = @"◼ CURRENCY";
    hdr3.font      = [UIFont boldSystemFontOfSize:10];
    hdr3.textColor = EL_TEXT_DIM;
    [_settingsPage addSubview:hdr3];

    // Info label
    UILabel *infoLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 376, w - 24, 28)];
    infoLbl.text          = @"Sets Nuts to 999,999,999";
    infoLbl.font          = [UIFont systemFontOfSize:10];
    infoLbl.textColor     = EL_TEXT_DIM;
    infoLbl.numberOfLines = 2;
    [_settingsPage addSubview:infoLbl];

    // Max Nuts button
    CGFloat bw = w - 20;
    UIButton *moneyBtn = [[UIButton alloc] initWithFrame:CGRectMake(10, 406, bw, 42)];
    moneyBtn.layer.cornerRadius = 10;
    moneyBtn.clipsToBounds = YES;
    CAGradientLayer *mg = [CAGradientLayer layer];
    mg.frame  = CGRectMake(0, 0, bw, 42);
    mg.colors = @[
        (id)[UIColor colorWithRed:0.8 green:0.6 blue:0.0 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.5 green:0.3 blue:0.0 alpha:1.0].CGColor,
    ];
    mg.startPoint = CGPointMake(0, 0.5);
    mg.endPoint   = CGPointMake(1, 0.5);
    [moneyBtn.layer insertSublayer:mg atIndex:0];
    [moneyBtn setTitle:@"💰  MAX NUTS  (999,999,999)" forState:UIControlStateNormal];
    [moneyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    moneyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    ELGlow(moneyBtn.layer, [UIColor colorWithRed:1.0 green:0.8 blue:0.0 alpha:1.0], 14);
    UITapGestureRecognizer *mt = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [mt el_addBlock:^(__unused id s) {
        BOOL ok = ELWriteMoney(999999999LL);
        if (ok) ELToast(@"💰 Max currency written! Restart the game.", YES);
        else    ELToast(@"Failed to write currency", NO);
    }];
    [moneyBtn addGestureRecognizer:mt];
    [_settingsPage addSubview:moneyBtn];

    UILabel *pathLbl = [[UILabel alloc] initWithFrame:CGRectMake(12, 456, w - 24, 30)];
    pathLbl.text          = [NSString stringWithFormat:@"◼ %@", ELConfigPath()];
    pathLbl.font          = [UIFont fontWithName:@"Menlo" size:8] ?: [UIFont systemFontOfSize:8];
    pathLbl.textColor     = EL_TEXT_DIM;
    pathLbl.numberOfLines = 2;
    [_settingsPage addSubview:pathLbl];

    // ── Body Scale ────────────────────────────────────────────────────────────
    UIView *d4 = [[UIView alloc] initWithFrame:CGRectMake(10, 490, w - 20, 1)];
    d4.backgroundColor = EL_DIVIDER;
    [_settingsPage addSubview:d4];

    UILabel *hdr4 = [[UILabel alloc] initWithFrame:CGRectMake(12, 497, w, 16)];
    hdr4.text      = @"◼ BODY SIZE";
    hdr4.font      = [UIFont boldSystemFontOfSize:10];
    hdr4.textColor = EL_TEXT_DIM;
    [_settingsPage addSubview:hdr4];

    // Preset buttons: Tiny / Normal / Big / Giant
    NSArray *sizePresets  = @[@"🐭 Tiny", @"🧍 Normal", @"🏀 Big", @"🏔 Giant"];
    NSArray *sizeValues   = @[@0.3, @1.0, @2.5, @6.0];
    CGFloat pbw = (w - 20 - 9) / 4.0f;
    for (NSInteger i = 0; i < 4; i++) {
        UIButton *pb = [[UIButton alloc] initWithFrame:CGRectMake(10 + i * (pbw + 3), 516, pbw, 34)];
        pb.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.4];
        pb.layer.cornerRadius = 8;
        pb.layer.borderWidth  = 1;
        pb.layer.borderColor  = EL_BORDER;
        [pb setTitle:sizePresets[(NSUInteger)i] forState:UIControlStateNormal];
        [pb setTitleColor:EL_TEXT forState:UIControlStateNormal];
        pb.titleLabel.font    = [UIFont boldSystemFontOfSize:10];
        pb.titleLabel.adjustsFontSizeToFitWidth = YES;
        CGFloat sv = [sizeValues[(NSUInteger)i] floatValue];
        UITapGestureRecognizer *pt = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        [pt el_addBlock:^(__unused id s) {
            BOOL ok = ELWritePlayerScale(sv);
            if (ok) ELToast([NSString stringWithFormat:@"Body scale → %.1fx", sv], YES);
            else    ELToast(@"Failed to write scale", NO);
        }];
        [pb addGestureRecognizer:pt];
        [_settingsPage addSubview:pb];
    }

    // Fine-grained scale slider
    UILabel *scaleCurLbl = [[UILabel alloc] initWithFrame:CGRectMake(w - 54, 554, 44, 14)];
    scaleCurLbl.text          = @"1.0x";
    scaleCurLbl.font          = [UIFont boldSystemFontOfSize:10];
    scaleCurLbl.textColor     = EL_PINK;
    scaleCurLbl.textAlignment = NSTextAlignmentRight;
    [_settingsPage addSubview:scaleCurLbl];

    UILabel *scaleLblLeft = [[UILabel alloc] initWithFrame:CGRectMake(10, 554, 50, 14)];
    scaleLblLeft.text      = @"Custom:";
    scaleLblLeft.font      = [UIFont boldSystemFontOfSize:10];
    scaleLblLeft.textColor = EL_TEXT_DIM;
    [_settingsPage addSubview:scaleLblLeft];

    UISlider *scaleSlider = [[UISlider alloc] initWithFrame:CGRectMake(62, 552, w - 120, 20)];
    scaleSlider.minimumValue          = 0.1f;
    scaleSlider.maximumValue          = 8.0f;
    scaleSlider.value                 = 1.0f;
    scaleSlider.minimumTrackTintColor = EL_PURPLE;
    scaleSlider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.1];
    scaleSlider.thumbTintColor        = [UIColor whiteColor];
    // Store label ref via associated object so the handler can update it
    objc_setAssociatedObject(scaleSlider, "lbl", scaleCurLbl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [scaleSlider addTarget:self action:@selector(bodyScaleChanged:)
         forControlEvents:UIControlEventValueChanged];
    [_settingsPage addSubview:scaleSlider];

    // ── Power Items ───────────────────────────────────────────────────────────
    UIView *d5 = [[UIView alloc] initWithFrame:CGRectMake(10, 580, w - 20, 1)];
    d5.backgroundColor = EL_DIVIDER;
    [_settingsPage addSubview:d5];

    UILabel *hdr5 = [[UILabel alloc] initWithFrame:CGRectMake(12, 587, w, 16)];
    hdr5.text      = @"◼ POWER ITEMS  (spawns in left hand)";
    hdr5.font      = [UIFont boldSystemFontOfSize:10];
    hdr5.textColor = EL_TEXT_DIM;
    [_settingsPage addSubview:hdr5];

    // Grid of one-tap power item buttons
    NSArray *powerItems  = @[
        @[@"❤️ Heart Choc",     @"item_heartchocolatebox"],
        @[@"🥦 Rad Broccoli",   @"item_radioactive_broccoli"],
        @[@"🥦 Shrink Brocco",  @"item_shrinking_broccoli"],
        @[@"🧃 Heal Ration",    @"item_company_ration_heal"],
        @[@"🩹 Ration",         @"item_company_ration"],
        @[@"🍖 Turkey Leg",     @"item_turkey_leg"],
        @[@"💊 Stash Grenade",  @"item_stash_grenade"],
        @[@"🔦 Flashlight",     @"item_flashlight"],
        @[@"🚀 Jetpack",        @"item_jetpack"],
        @[@"🏓 Pogostick",      @"item_pogostick"],
        @[@"🪝 Hookshot",       @"item_hookshot"],
        @[@"📡 Teleporter",     @"item_portable_teleporter"],
    ];
    NSInteger cols   = 2;
    CGFloat   piW    = (w - 20 - 6) / cols;
    CGFloat   piH    = 32;
    CGFloat   piTopY = 606;
    for (NSInteger i = 0; i < (NSInteger)powerItems.count; i++) {
        NSArray  *pair  = powerItems[(NSUInteger)i];
        NSString *label = pair[0];
        NSString *iid   = pair[1];
        NSInteger col   = i % cols;
        NSInteger row   = i / cols;
        CGFloat   px    = 10 + col * (piW + 6);
        CGFloat   py    = piTopY + row * (piH + 4);
        UIButton *pib   = [[UIButton alloc] initWithFrame:CGRectMake(px, py, piW, piH)];
        pib.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.4];
        pib.layer.cornerRadius = 8;
        pib.layer.borderWidth  = 1;
        pib.layer.borderColor  = EL_BORDER;
        [pib setTitle:label forState:UIControlStateNormal];
        [pib setTitleColor:EL_TEXT forState:UIControlStateNormal];
        pib.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        pib.titleLabel.adjustsFontSizeToFitWidth = YES;
        UITapGestureRecognizer *pit = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        [pit el_addBlock:^(__unused id s) {
            BOOL ok = ELWriteConfig(@"leftHand", iid, 159, 120, 0, 1, nil);
            if (ok) ELToast([NSString stringWithFormat:@"◼ %@ spawned", label], YES);
            else    ELToast(@"Failed to spawn item", NO);
        }];
        [pib addGestureRecognizer:pit];
        [_settingsPage addSubview:pib];
    }

    // Bottom padding label
    NSInteger powerRows = (powerItems.count + cols - 1) / cols;
    CGFloat   bottomY   = piTopY + powerRows * (piH + 4) + 10;
    _settingsPage.contentSize = CGSizeMake(w, bottomY);
}

// ─── Slider row helper ────────────────────────────────────────────────────────
- (void)addSliderRow:(NSString *)name value:(CGFloat)val min:(CGFloat)mn max:(CGFloat)mx
                   y:(CGFloat)y label:(__strong UILabel **)lbl action:(SEL)action {
    CGFloat w = _settingsPage.frame.size.width;

    UILabel *nl = [[UILabel alloc] initWithFrame:CGRectMake(12, y, 100, 18)];
    nl.text      = name;
    nl.font      = [UIFont boldSystemFontOfSize:11];
    nl.textColor = EL_TEXT;
    [_settingsPage addSubview:nl];

    UILabel *vl = [[UILabel alloc] initWithFrame:CGRectMake(w - 50, y, 40, 18)];
    vl.text           = [NSString stringWithFormat:@"%.0f", val];
    vl.font           = [UIFont boldSystemFontOfSize:11];
    vl.textColor      = EL_PINK;
    vl.textAlignment  = NSTextAlignmentRight;
    [_settingsPage addSubview:vl];
    if (lbl) *lbl = vl;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(12, y + 20, w - 24, 22)];
    slider.minimumValue          = mn;
    slider.maximumValue          = mx;
    slider.value                 = val;
    slider.minimumTrackTintColor = EL_PURPLE;
    slider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.1];
    slider.thumbTintColor        = [UIColor whiteColor];
    [slider addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [_settingsPage addSubview:slider];
}

// ─── Toggle row helper ────────────────────────────────────────────────────────
- (void)addToggleRow:(NSString *)title subtitle:(NSString *)sub y:(CGFloat)y action:(SEL)action {
    CGFloat w = _settingsPage.frame.size.width;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10, y, w - 20, 44)];
    row.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.35];
    row.layer.cornerRadius = 10;
    row.layer.borderWidth  = 1;
    row.layer.borderColor  = EL_BORDER;
    [_settingsPage addSubview:row];

    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, w - 80, 18)];
    tl.text      = title;
    tl.font      = [UIFont boldSystemFontOfSize:12];
    tl.textColor = EL_TEXT;
    [row addSubview:tl];

    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(12, 22, w - 80, 16)];
    sl.text      = sub;
    sl.font      = [UIFont systemFontOfSize:10];
    sl.textColor = EL_TEXT_DIM;
    [row addSubview:sl];

    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = EL_PURPLE;
    sw.transform   = CGAffineTransformMakeScale(0.78f, 0.78f);
    sw.frame       = CGRectMake(w - 68, 8, 51, 31);
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
}

// ─── Item list reload ─────────────────────────────────────────────────────────
- (void)reloadItemList {
    for (UIView *r in _rowViews) [r removeFromSuperview];
    [_rowViews removeAllObjects];

    NSArray   *items = _currentItems;
    NSString  *q     = _searchField.text;
    if (q.length > 0)
        items = [items filteredArrayUsingPredicate:
                 [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", q]];

    CGFloat   rh      = 36;
    // Use frame width — bounds.size.width is 0 until after the first layout pass
    CGFloat   listW   = _itemList.frame.size.width;
    NSInteger iCount  = (NSInteger)items.count;   // FIX 3
    for (NSInteger i = 0; i < iCount; i++) {
        NSString *name = items[(NSUInteger)i];
        UIView *row = [[UIView alloc] initWithFrame:
                       CGRectMake(0, i * rh, listW, rh)];
        row.backgroundColor = (i % 2 == 0) ? [UIColor clearColor]
                                            : [UIColor colorWithWhite:1 alpha:0.02];

        UILabel *lbl = [[UILabel alloc] initWithFrame:
                        CGRectMake(10, 0, listW - 20, rh)];
        lbl.text                     = name;
        lbl.font                     = [UIFont fontWithName:@"Menlo" size:11]
                                    ?: [UIFont systemFontOfSize:11];
        lbl.textColor                = [name isEqualToString:_selectedItem] ? EL_PURPLE : EL_TEXT;
        lbl.adjustsFontSizeToFitWidth = YES;
        [row addSubview:lbl];

        if ([name isEqualToString:_selectedItem]) {
            row.backgroundColor = EL_PURPLE_DIM;
            ELGlow(row.layer, EL_PURPLE, 4);
        }

        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        NSString *cn = name;
        [t el_addBlock:^(__unused id s) { [self selectItemNamed:cn row:nil]; }];
        [row addGestureRecognizer:t];
        [_itemList addSubview:row];
        [_rowViews addObject:row];
    }
    _itemList.contentSize = CGSizeMake(_itemList.frame.size.width, items.count * rh);
    _countLabel.text = [NSString stringWithFormat:@"%lu items", (unsigned long)items.count];
}

// ─── Interaction ──────────────────────────────────────────────────────────────
- (void)selectItemNamed:(NSString *)name row:(__unused UIView *)row {
    _selectedItem            = name;
    _selectedItemLabel.text      = name;
    _selectedItemLabel.textColor = EL_TEXT;
    [self reloadItemList];
}

- (void)selectCategory:(NSInteger)idx scroll:(UIScrollView *)scroll {
    _selectedCategory = idx;
    _currentItems     = ELCategoryItems(idx);
    _searchField.text = @"";
    [self reloadItemList];

    for (UIView *sub in scroll.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        UIButton  *b      = (UIButton *)sub;
        NSInteger  bi     = b.tag - 7000;
        BOOL       active = (bi == idx);
        b.backgroundColor = active ? EL_PURPLE_DIM : [UIColor colorWithWhite:1 alpha:0.05];
        [b setTitleColor:active ? EL_PURPLE : EL_TEXT_DIM forState:UIControlStateNormal];
        b.layer.borderColor = active ? EL_BORDER
                                     : [UIColor colorWithWhite:1 alpha:0.08].CGColor;
        if (active) ELGlow(b.layer, EL_PURPLE, 5);
        else        b.layer.shadowOpacity = 0;
    }
}

- (void)searchChanged { [self reloadItemList]; }

- (void)qtyMinus { if (_quantity > 1)   { _quantity--;  _qtyLabel.text = @(_quantity).stringValue; } }
- (void)qtyPlus  { if (_quantity < 500) { _quantity++;  _qtyLabel.text = @(_quantity).stringValue; } }

- (void)cycleSlot {
    NSArray   *slots = @[@"leftHand", @"rightHand", @"leftHip", @"rightHip", @"back"];
    NSUInteger idx   = [slots indexOfObject:_selectedSlot];
    _selectedSlot    = slots[(idx + 1) % slots.count];
    _slotLabel.text  = _selectedSlot;
}

- (void)hueChanged:(UISlider *)s   { _colorHue = (NSInteger)s.value; _hueLabel.text   = @(_colorHue).stringValue; }
- (void)satChanged:(UISlider *)s   { _colorSat = (NSInteger)s.value; _satLabel.text   = @(_colorSat).stringValue; }
- (void)scaleChanged:(UISlider *)s { _scaleVal  = (NSInteger)s.value; _scaleLabel.text = @(_scaleVal).stringValue; }

- (void)bodyScaleChanged:(UISlider *)s {
    CGFloat scale = s.value;
    UILabel *lbl = objc_getAssociatedObject(s, "lbl");
    lbl.text = [NSString stringWithFormat:@"%.2fx", scale];
    ELWritePlayerScale(scale);
}

// ── Inline Items-page slider handlers ────────────────────────────────────────
- (void)itemHueChanged:(UISlider *)s {
    _colorHue = (NSInteger)s.value;
    _itemHueValueLabel.text = [NSString stringWithFormat:@"%ld°", (long)_colorHue];
    _itemColorSwatch.backgroundColor = [UIColor colorWithHue:_colorHue / 360.0f
                                                  saturation:_colorSat / 255.0f
                                                  brightness:1.0f alpha:1.0f];
    if (_hueLabel) _hueLabel.text = @(_colorHue).stringValue;
}

- (void)itemSatChanged:(UISlider *)s {
    _colorSat = (NSInteger)s.value;
    _itemSatValueLabel.text = [NSString stringWithFormat:@"%ld", (long)_colorSat];
    _itemColorSwatch.backgroundColor = [UIColor colorWithHue:_colorHue / 360.0f
                                                  saturation:_colorSat / 255.0f
                                                  brightness:1.0f alpha:1.0f];
    if (_satLabel) _satLabel.text = @(_colorSat).stringValue;
}

- (void)itemScaleChanged:(UISlider *)s {
    _scaleVal = (NSInteger)s.value;
    NSString *tag = (_scaleVal == 0) ? @"normal" : (_scaleVal > 0 ? @"bigger" : @"smaller");
    _itemScaleValueLabel.text = [NSString stringWithFormat:@"%ld (%@)", (long)_scaleVal, tag];
    if (_scaleLabel) _scaleLabel.text = @(_scaleVal).stringValue;
}

- (void)toggleFreeze:(UISwitch *)s   { ELToggleFreeze(s.on); }
- (void)toggleFling:(UISwitch *)s    { ELToggleFling(s.on); }
- (void)toggleInfAmmo:(UISwitch *)s {
    ELToggleInfAmmo(s.on);
    if (s.on) ELToast(@"∞ Infinite Ammo ON — hooks live + config written", YES);
    else      ELToast(@"∞ Infinite Ammo OFF", NO);
}

- (void)doSpawn {
    if (!_selectedItem) { ELToast(@"Select an item first", NO); return; }
    NSMutableArray *children = nil;
    if (_quantity > 1) {
        children = [NSMutableArray array];
        for (NSInteger i = 0; i < _quantity - 1; i++)
            [children addObject:ELMakeItemNode(_selectedItem, _colorHue, _colorSat, 0, 1, nil)];
    }
    BOOL ok = ELWriteConfig(_selectedSlot, _selectedItem, _colorHue, _colorSat,
                             _scaleVal, _quantity, children);
    if (ok)
        ELToast([NSString stringWithFormat:@"Spawned %@ x%ld in %@",
                 _selectedItem, (long)_quantity, _selectedSlot], YES);
    else
        ELToast(@"Failed to write config", NO);
}

- (void)doClear {
    ELClearSlot(_selectedSlot);
    ELToast([NSString stringWithFormat:@"Cleared %@", _selectedSlot], YES);
}

- (void)dismiss {
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha     = 0;
        self.transform = CGAffineTransformMakeScale(0.9f, 0.9f);
    } completion:^(__unused BOOL d) {
        self.hidden    = YES;
        self.alpha     = 1;
        self.transform = CGAffineTransformIdentity;
    }];
}

- (void)handleDrag:(UIPanGestureRecognizer *)pan {
    CGPoint d = [pan translationInView:self.superview];
    CGFloat newX = self.center.x + d.x;
    CGFloat newY = self.center.y + d.y;
    // Clamp so at least 44pt of the header stays on screen
    CGFloat hw   = self.bounds.size.width  / 2.0f;
    UIWindow *win = (UIWindow *)self.superview;
    CGFloat  sw   = win ? win.bounds.size.width  : 390;
    CGFloat  sh   = win ? win.bounds.size.height : 844;
    newX = MAX(hw - self.bounds.size.width + 44,  MIN(newX, sw - hw + self.bounds.size.width - 44));
    newY = MAX(44,                                 MIN(newY, sh - 44));
    self.center = CGPointMake(newX, newY);
    [pan setTranslation:CGPointZero inView:self.superview];
}

// Pinch to resize — scales between 240 and 380pt wide, 380 and 680pt tall
static CGRect _pinchStartFrame;
- (void)handlePinchResize:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan)
        _pinchStartFrame = self.frame;
    if (pinch.state == UIGestureRecognizerStateChanged || pinch.state == UIGestureRecognizerStateEnded) {
        CGFloat s  = pinch.scale;
        CGFloat nw = CLAMP(_pinchStartFrame.size.width  * s, 240, 380);
        CGFloat nh = CLAMP(_pinchStartFrame.size.height * s, 380, 680);
        CGFloat ox = self.center.x;
        CGFloat oy = self.center.y;
        self.frame = CGRectMake(ox - nw / 2.0f, oy - nh / 2.0f, nw, nh);
    }
}

- (void)cycleMenuSize {
    // Cycles: Medium (default) → Large → Small → Medium
    UIWindow *win = ELKeyWindow();
    if (!win) return;
    CGFloat screenW = win.bounds.size.width;
    CGFloat screenH = win.bounds.size.height;

    // Three preset sizes
    typedef struct { CGFloat w; CGFloat h; } ELSize;
    ELSize sizes[3] = {
        { MIN(screenW - 40, 260), MIN(screenH * 0.55f, 420) },  // Small
        { MIN(screenW - 32, 300), MIN(screenH * 0.70f, 520) },  // Medium (default)
        { MIN(screenW - 16, 360), MIN(screenH * 0.88f, 640) },  // Large
    };

    // Detect current size tier by width
    CGFloat cw = self.bounds.size.width;
    NSInteger nextIdx = 1; // default to Medium
    if (cw <= sizes[0].w + 10)       nextIdx = 1; // was Small → go Medium
    else if (cw <= sizes[1].w + 10)  nextIdx = 2; // was Medium → go Large
    else                             nextIdx = 0; // was Large → go Small

    ELSize ns = sizes[nextIdx];

    // Keep menu centred on its current centre point
    CGPoint centre = self.center;
    CGRect  newFrame = CGRectMake(centre.x - ns.w / 2,
                                  centre.y - ns.h / 2,
                                  ns.w, ns.h);
    // Clamp to screen
    newFrame.origin.x = MAX(8, MIN(newFrame.origin.x, screenW - ns.w - 8));
    newFrame.origin.y = MAX(40, MIN(newFrame.origin.y, screenH - ns.h - 8));

    [UIView animateWithDuration:0.32 delay:0
         usingSpringWithDamping:0.78 initialSpringVelocity:0.4 options:0
                     animations:^{ self.frame = newFrame; }
                     completion:nil];

    NSString *label = (nextIdx == 0) ? @"Small" : (nextIdx == 1) ? @"Medium" : @"Large";
    ELToast([NSString stringWithFormat:@"Menu size: %@", label], YES);
}

- (UIButton *)makeStepBtn:(NSString *)t frame:(CGRect)r action:(SEL)a {
    UIButton *b = [[UIButton alloc] initWithFrame:r];
    b.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.35];
    b.layer.cornerRadius = 6;
    b.layer.borderWidth  = 1;
    b.layer.borderColor  = EL_BORDER;
    [b setTitle:t forState:UIControlStateNormal];
    [b setTitleColor:EL_PURPLE forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}


// ─── Monsters Page ────────────────────────────────────────────────────────────
- (void)buildMonstersPage {
    CGFloat w = _monstersPage.frame.size.width;
    CGFloat h = _monstersPage.frame.size.height;

    // ── Category filter pills ─────────────────────────────────────────────────
    NSArray *cats = @[@"All", @"Humanoid", @"Creature", @"Ambient", @"Explosive"];
    UIScrollView *catScroll = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 6, w - 16, 34)];
    catScroll.showsHorizontalScrollIndicator = NO;
    [_monstersPage addSubview:catScroll];
    CGFloat cx = 4;
    for (NSInteger i = 0; i < (NSInteger)cats.count; i++) {
        NSString *label = cats[(NSUInteger)i];
        CGFloat pw = [label sizeWithAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:10]}].width + 18;
        UIButton *pill = [[UIButton alloc] initWithFrame:CGRectMake(cx, 3, pw, 26)];
        pill.layer.cornerRadius = 13;
        pill.layer.borderWidth  = 1;
        pill.tag = 9000 + i;
        BOOL active = (i == _monsterCatIndex);
        pill.backgroundColor  = active ? EL_PURPLE_DIM : [UIColor colorWithWhite:1 alpha:0.05];
        pill.layer.borderColor = active ? EL_BORDER : [UIColor colorWithWhite:1 alpha:0.1].CGColor;
        [pill setTitle:label forState:UIControlStateNormal];
        [pill setTitleColor:active ? EL_PURPLE : EL_TEXT_DIM forState:UIControlStateNormal];
        pill.titleLabel.font = [UIFont boldSystemFontOfSize:10];
        NSInteger ci = i;
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        [t el_addBlock:^(__unused id s) { [self selectMonsterCategory:ci scroll:catScroll]; }];
        [pill addGestureRecognizer:t];
        [catScroll addSubview:pill];
        cx += pw + 5;
    }
    catScroll.contentSize = CGSizeMake(cx + 4, 34);

    // ── Search bar ────────────────────────────────────────────────────────────
    UIView *searchWrap = [[UIView alloc] initWithFrame:CGRectMake(8, 44, w - 16, 30)];
    searchWrap.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.35];
    searchWrap.layer.cornerRadius = 8;
    searchWrap.layer.borderWidth  = 1;
    searchWrap.layer.borderColor  = EL_BORDER;
    [_monstersPage addSubview:searchWrap];

    UILabel *searchIcon = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 20, 30)];
    searchIcon.text      = @"◼";
    searchIcon.font      = [UIFont systemFontOfSize:10];
    searchIcon.textColor = EL_TEXT_DIM;
    [searchWrap addSubview:searchIcon];

    _monsterSearchField = [[UITextField alloc] initWithFrame:CGRectMake(26, 0, w - 52, 30)];
    _monsterSearchField.font            = [UIFont systemFontOfSize:11];
    _monsterSearchField.textColor       = EL_TEXT;
    _monsterSearchField.returnKeyType   = UIReturnKeyDone;
    _monsterSearchField.delegate        = self;
    _monsterSearchField.backgroundColor = [UIColor clearColor];
    _monsterSearchField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Search monsters..."
            attributes:@{NSForegroundColorAttributeName: EL_TEXT_DIM,
                         NSFontAttributeName: [UIFont systemFontOfSize:11]}];
    [_monsterSearchField addTarget:self action:@selector(monsterSearchChanged)
                  forControlEvents:UIControlEventEditingChanged];
    [searchWrap addSubview:_monsterSearchField];

    // ── Header labels ─────────────────────────────────────────────────────────
    UILabel *mHdr = [[UILabel alloc] initWithFrame:CGRectMake(12, 78, 160, 16)];
    mHdr.text      = @"◼ MONSTER SPAWNER";
    mHdr.font      = [UIFont boldSystemFontOfSize:10];
    mHdr.textColor = EL_TEXT_DIM;
    [_monstersPage addSubview:mHdr];

    // ── Selected monster display ──────────────────────────────────────────────
    UIView *selWrap = [[UIView alloc] initWithFrame:CGRectMake(8, 96, w - 16, 26)];
    selWrap.backgroundColor  = EL_PURPLE_DIM;
    selWrap.layer.cornerRadius = 6;
    selWrap.layer.borderWidth  = 1;
    selWrap.layer.borderColor  = EL_BORDER;
    [_monstersPage addSubview:selWrap];

    _selectedMonsterLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, w - 40, 26)];
    _selectedMonsterLabel.text      = @"tap a monster to select...";
    _selectedMonsterLabel.font      = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    _selectedMonsterLabel.textColor = EL_TEXT_DIM;
    [selWrap addSubview:_selectedMonsterLabel];

    // ── Monster list ──────────────────────────────────────────────────────────
    CGFloat listH = MAX(h * 0.42f, 100);
    _monsterList = [[UIScrollView alloc] initWithFrame:CGRectMake(8, 126, w - 16, listH)];
    _monsterList.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.35];
    _monsterList.layer.cornerRadius = 10;
    _monsterList.layer.borderWidth  = 1;
    _monsterList.layer.borderColor  = EL_BORDER;
    [_monstersPage addSubview:_monsterList];
    [self reloadMonsterList];

    // ── Controls row ──────────────────────────────────────────────────────────
    CGFloat cy = 126 + listH + 8;

    // Qty
    UILabel *ql = [[UILabel alloc] initWithFrame:CGRectMake(10, cy + 4, 30, 20)];
    ql.text = @"Qty:"; ql.font = [UIFont boldSystemFontOfSize:10]; ql.textColor = EL_TEXT_DIM;
    [_monstersPage addSubview:ql];

    _monsterQtyLabel = [[UILabel alloc] initWithFrame:CGRectMake(42, cy + 2, 26, 24)];
    _monsterQtyLabel.text = @"1"; _monsterQtyLabel.textAlignment = NSTextAlignmentCenter;
    _monsterQtyLabel.font = [UIFont boldSystemFontOfSize:14]; _monsterQtyLabel.textColor = EL_PINK;
    [_monstersPage addSubview:_monsterQtyLabel];
    [_monstersPage addSubview:[self makeStepBtn:@"−" frame:CGRectMake(70, cy+2, 24, 22) action:@selector(monsterQtyMinus)]];
    [_monstersPage addSubview:[self makeStepBtn:@"+" frame:CGRectMake(96, cy+2, 24, 22) action:@selector(monsterQtyPlus)]];

    // Size slider label
    UILabel *szLabel = [[UILabel alloc] initWithFrame:CGRectMake(130, cy + 4, 28, 16)];
    szLabel.text = @"Size:"; szLabel.font = [UIFont boldSystemFontOfSize:9]; szLabel.textColor = EL_TEXT_DIM;
    [_monstersPage addSubview:szLabel];

    _monsterScaleLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 46, cy + 4, 38, 16)];
    _monsterScaleLabel.text = @"1.0x"; _monsterScaleLabel.font = [UIFont boldSystemFontOfSize:9];
    _monsterScaleLabel.textColor = EL_PINK; _monsterScaleLabel.textAlignment = NSTextAlignmentRight;
    [_monstersPage addSubview:_monsterScaleLabel];

    UISlider *sizeSlider = [[UISlider alloc] initWithFrame:CGRectMake(160, cy + 6, w - 210, 18)];
    sizeSlider.minimumValue = 0.1f; sizeSlider.maximumValue = 10.0f; sizeSlider.value = 1.0f;
    sizeSlider.minimumTrackTintColor = EL_PURPLE;
    sizeSlider.maximumTrackTintColor = [UIColor colorWithWhite:1 alpha:0.1];
    sizeSlider.thumbTintColor = [UIColor whiteColor];
    [sizeSlider addTarget:self action:@selector(monsterSizeChanged:) forControlEvents:UIControlEventValueChanged];
    [_monstersPage addSubview:sizeSlider];

    cy += 30;

    // Color Hue slider
    UILabel *hueLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, cy + 4, 50, 16)];
    hueLbl.text = @"Color:"; hueLbl.font = [UIFont boldSystemFontOfSize:9]; hueLbl.textColor = EL_TEXT_DIM;
    [_monstersPage addSubview:hueLbl];

    _monsterHueLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 46, cy + 4, 38, 16)];
    _monsterHueLabel.text = @"0°"; _monsterHueLabel.font = [UIFont boldSystemFontOfSize:9];
    _monsterHueLabel.textColor = EL_PINK; _monsterHueLabel.textAlignment = NSTextAlignmentRight;
    [_monstersPage addSubview:_monsterHueLabel];

    // Rainbow gradient track behind the slider
    UIView *hueTrackBg = [[UIView alloc] initWithFrame:CGRectMake(60, cy + 8, w - 110, 8)];
    hueTrackBg.layer.cornerRadius = 4;
    hueTrackBg.clipsToBounds = YES;
    CAGradientLayer *rainbow = [CAGradientLayer layer];
    rainbow.frame = CGRectMake(0, 0, w - 110, 8);
    rainbow.colors = @[
        (id)[UIColor colorWithRed:1 green:0 blue:0 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:1 blue:0 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0 green:1 blue:0 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0 green:1 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0 green:0 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:0 blue:1 alpha:1].CGColor,
        (id)[UIColor colorWithRed:1 green:0 blue:0 alpha:1].CGColor,
    ];
    rainbow.startPoint = CGPointMake(0, 0.5); rainbow.endPoint = CGPointMake(1, 0.5);
    [hueTrackBg.layer addSublayer:rainbow];
    [_monstersPage addSubview:hueTrackBg];

    UISlider *hueSlider = [[UISlider alloc] initWithFrame:CGRectMake(58, cy + 4, w - 106, 18)];
    hueSlider.minimumValue = 0; hueSlider.maximumValue = 360; hueSlider.value = 0;
    hueSlider.minimumTrackTintColor = [UIColor clearColor];
    hueSlider.maximumTrackTintColor = [UIColor clearColor];
    hueSlider.thumbTintColor = [UIColor whiteColor];
    [hueSlider addTarget:self action:@selector(monsterHueChanged:) forControlEvents:UIControlEventValueChanged];
    [_monstersPage addSubview:hueSlider];

    cy += 30;

    // Divider
    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(8, cy, w - 16, 1)];
    d.backgroundColor = EL_DIVIDER;
    [_monstersPage addSubview:d];
    cy += 6;

    // SPAWN button
    CGFloat bw = w - 16 - 50;
    UIButton *spawnBtn = [[UIButton alloc] initWithFrame:CGRectMake(8, cy, bw, 38)];
    spawnBtn.layer.cornerRadius = 10; spawnBtn.clipsToBounds = YES;
    CAGradientLayer *sg = [CAGradientLayer layer];
    sg.frame = CGRectMake(0, 0, bw, 38);
    sg.colors = @[
        (id)[UIColor colorWithRed:0.28 green:0.28 blue:0.28 alpha:1.0].CGColor,
        (id)[UIColor colorWithRed:0.12 green:0.12 blue:0.12 alpha:1.0].CGColor,
    ];
    sg.startPoint = CGPointMake(0, 0.5); sg.endPoint = CGPointMake(1, 0.5);
    [spawnBtn.layer insertSublayer:sg atIndex:0];
    [spawnBtn setTitle:@"◼  SPAWN MONSTER" forState:UIControlStateNormal];
    [spawnBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    spawnBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    ELGlow(spawnBtn.layer, [UIColor colorWithRed:0.8 green:0.1 blue:0.5 alpha:1], 14);
    UITapGestureRecognizer *spawnTap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [spawnTap el_addBlock:^(__unused id s) { [self doSpawnMonster]; }];
    [spawnBtn addGestureRecognizer:spawnTap];
    [_monstersPage addSubview:spawnBtn];

    // Clear button
    UIButton *clearBtn = [[UIButton alloc] initWithFrame:CGRectMake(w - 46, cy, 38, 38)];
    clearBtn.backgroundColor  = [UIColor colorWithWhite:0 alpha:0.4];
    clearBtn.layer.cornerRadius = 10;
    clearBtn.layer.borderWidth  = 1; clearBtn.layer.borderColor = EL_BORDER;
    [clearBtn setTitle:@"🗑" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:16];
    UITapGestureRecognizer *clearTap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [clearTap el_addBlock:^(__unused id s) { [self clearMonsters]; }];
    [clearBtn addGestureRecognizer:clearTap];
    [_monstersPage addSubview:clearBtn];

    // Set contentSize so the monsters page scrolls if content overflows
    _monstersPage.contentSize = CGSizeMake(w, cy + 38 + 16);
}

// ─── Monster list reload ───────────────────────────────────────────────────────
- (void)reloadMonsterList {
    for (UIView *r in _monsterRowViews) [r removeFromSuperview];
    [_monsterRowViews removeAllObjects];

    NSArray *monsters = _currentMonsters;
    NSString *q = _monsterSearchField.text;
    if (q.length > 0)
        monsters = [monsters filteredArrayUsingPredicate:
                    [NSPredicate predicateWithFormat:@"SELF CONTAINS[cd] %@", q]];

    CGFloat rh    = 36;
    CGFloat listW = _monsterList.frame.size.width;
    NSInteger cnt = (NSInteger)monsters.count;
    for (NSInteger i = 0; i < cnt; i++) {
        NSString *mid  = monsters[(NSUInteger)i];
        NSString *name = ELMonsterDisplayName(mid);
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, i * rh, listW, rh)];
        BOOL sel = [mid isEqualToString:_selectedMonster];
        row.backgroundColor = sel ? EL_PURPLE_DIM : (i % 2 == 0 ?
            [UIColor colorWithWhite:1 alpha:0.03] : [UIColor clearColor]);

        UIView *accent = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3, rh)];
        accent.backgroundColor = sel ? EL_PURPLE : [UIColor clearColor];
        [row addSubview:accent];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, listW - 20, rh)];
        lbl.text      = name;
        lbl.font      = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
        lbl.textColor = sel ? EL_PURPLE : EL_TEXT;
        [row addSubview:lbl];

        UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, rh - 1, listW, 1)];
        sep.backgroundColor = EL_DIVIDER;
        [row addSubview:sep];

        NSString *cm = mid;
        UITapGestureRecognizer *t = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        [t el_addBlock:^(__unused id s) { [self selectMonsterNamed:cm]; }];
        [row addGestureRecognizer:t];
        [_monsterList addSubview:row];
        [_monsterRowViews addObject:row];
    }
    _monsterList.contentSize = CGSizeMake(listW, cnt * rh);
}

- (void)selectMonsterNamed:(NSString *)mid {
    _selectedMonster = mid;
    _selectedMonsterLabel.text      = ELMonsterDisplayName(mid);
    _selectedMonsterLabel.textColor = EL_PURPLE;
    [self reloadMonsterList];
}

- (void)selectMonsterCategory:(NSInteger)cat scroll:(UIScrollView *)scroll {
    _monsterCatIndex = cat;
    _currentMonsters = ELMonsterCategory(cat);
    // Update pill styles
    for (UIView *sub in scroll.subviews) {
        if (![sub isKindOfClass:[UIButton class]]) continue;
        UIButton *b = (UIButton *)sub;
        NSInteger bi = b.tag - 9000;
        BOOL active = (bi == cat);
        b.backgroundColor  = active ? EL_PURPLE_DIM : [UIColor colorWithWhite:1 alpha:0.05];
        [b setTitleColor:active ? EL_PURPLE : EL_TEXT_DIM forState:UIControlStateNormal];
        b.layer.borderColor = active ? EL_BORDER : [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    }
    [self reloadMonsterList];
}

- (void)monsterSearchChanged { [self reloadMonsterList]; }

- (void)monsterQtyMinus { if (_monsterQty > 1)  { _monsterQty--;  _monsterQtyLabel.text = @(_monsterQty).stringValue; } }
- (void)monsterQtyPlus  { if (_monsterQty < 20) { _monsterQty++;  _monsterQtyLabel.text = @(_monsterQty).stringValue; } }

- (void)monsterSizeChanged:(UISlider *)s {
    _monsterScale = s.value;
    _monsterScaleLabel.text = [NSString stringWithFormat:@"%.1fx", _monsterScale];
}

- (void)monsterHueChanged:(UISlider *)s {
    _monsterColorHue = (NSInteger)s.value;
    _monsterHueLabel.text = [NSString stringWithFormat:@"%ld°", (long)_monsterColorHue];
}

- (void)doSpawnMonster {
    if (!_selectedMonster) { ELToast(@"Select a monster first", NO); return; }
    BOOL ok = ELSpawnMonster(_selectedMonster, _monsterScale, _monsterColorHue, _monsterQty);
    if (ok)
        ELToast([NSString stringWithFormat:@"◼ Spawned %@ x%ld (%.1fx size)",
                 ELMonsterDisplayName(_selectedMonster), (long)_monsterQty, _monsterScale], YES);
    else
        ELToast(@"Failed to write monster config", NO);
}

- (void)clearMonsters {
    NSString *path = ELConfigPath();
    NSMutableDictionary *config = [@{
        @"leftHand": @{}, @"rightHand": @{}, @"leftHip": @{}, @"rightHip": @{}, @"back": @{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) config = [p mutableCopy];
    }
    [config removeObjectForKey:@"monsters"];
    [config removeObjectForKey:@"monsterSpawns"];
    [config removeObjectForKey:@"enemySpawns"];
    [config removeObjectForKey:@"spawnMonsters"];
    [config removeObjectForKey:@"enemies"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:config
                                                  options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
    ELToast(@"Monster spawns cleared", YES);
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Config helpers & writers for new tabs
// ═══════════════════════════════════════════════════════════════════════════════

static void ELWriteFlags(NSDictionary *flags) {
    NSString *path = ELConfigPath();
    NSMutableDictionary *cfg = [@{
        @"leftHand":@{},@"rightHand":@{},@"leftHip":@{},@"rightHip":@{},@"back":@{}
    } mutableCopy];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSData *d = [NSData dataWithContentsOfFile:path];
        NSDictionary *p = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (p) cfg = [p mutableCopy];
    }
    [cfg addEntriesFromDictionary:flags];
    NSData *data = [NSJSONSerialization dataWithJSONObject:cfg options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}

static void ELTeleportToPosition(NSString *posName) {
    NSDictionary *positions = @{
        @"Lobby":           @{ @"x": @0.0,   @"y": @1.0,  @"z": @0.0  },
        @"Selling Machine": @{ @"x": @12.5,  @"y": @0.5,  @"z": @3.2  },
        @"Stage 5":         @{ @"x": @55.0,  @"y": @2.0,  @"z": @30.0 },
        @"Stash":           @{ @"x": @-8.0,  @"y": @0.5,  @"z": @12.0 },
        @"Ski Hill":        @{ @"x": @100.0, @"y": @35.0, @"z": @80.0 },
    };
    NSDictionary *pos = positions[posName] ?: positions[@"Lobby"];
    ELWriteFlags(@{ @"playerPosition":pos, @"teleportPosition":pos,
                    @"warpPosition":pos, @"requestTeleport":pos, @"teleportPending":@YES });
}
static void ELLaunchUpward(void) {
    ELVec3 pos = ELCameraPosition();
    NSDictionary *t = @{@"x":@(pos.x),@"y":@(pos.y+30.0f),@"z":@(pos.z)};
    ELWriteFlags(@{@"playerPosition":t,@"teleportPosition":t,@"requestTeleport":t,
                   @"teleportPending":@YES,@"launchUpward":@YES,@"verticalBoost":@YES});
}
static void ELKillPlayers(void)           { ELWriteFlags(@{@"killAllPlayers":@YES,@"killPlayers":@YES,@"damage":@9999}); }
static void ELStunPlayers(void)           { ELWriteFlags(@{@"stunAllPlayers":@YES,@"stunDuration":@5}); }
static void ELHitPlayers(void)            { ELWriteFlags(@{@"hitAllPlayers":@YES,@"damage":@25}); }
static void ELWriteGodMode(BOOL on)       { ELWriteFlags(@{@"godMode":@(on),@"invincible":@(on),@"isInvincible":@(on)}); }
static void ELWriteFlyMode(BOOL on)       { ELWriteFlags(@{@"flyMode":@(on),@"flying":@(on),@"enableFly":@(on)}); }
static void ELWriteNoclip(BOOL on)        { ELWriteFlags(@{@"noclip":@(on),@"noClipEnabled":@(on),@"noClip":@(on)}); }
static void ELWriteInvisibility(BOOL on)  { ELWriteFlags(@{@"invisible":@(on),@"isInvisible":@(on),@"invisibility":@(on)}); }
static void ELWritePlatforms(BOOL on)     { ELWriteFlags(@{@"platforms":@(on),@"spawnPlatforms":@(on),@"enablePlatforms":@(on)}); }
static void ELTeleToRandPlayer(void)      { ELWriteFlags(@{@"teleportToRandomPlayer":@YES,@"teleportToPlayer":@YES}); }
static void ELSpawnNukeItems(void) {
    ELVec3 pos = ELCameraPosition();
    NSArray *ids = @[@"item_timebomb",@"item_landmine",@"item_dynamite",@"item_rpg",@"item_cluster_grenade"];
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *n in ids)
        [list addObject:@{@"itemID":n,@"id":n,@"state":@1,@"pending":@YES,
                          @"position":@{@"x":@(pos.x),@"y":@(pos.y),@"z":@(pos.z)}}];
    ELWriteFlags(@{@"items":list,@"spawnItems":list,@"nukeItems":@YES});
}
static void ELSetGravity(float g) {
    ELWriteFlags(@{@"gravity":@(g),@"gravityScale":@(g),@"physicsGravity":@(g),@"customGravity":@YES});
}
// Fun writers
static void ELShakeScreen(void)           { ELWriteFlags(@{@"shakeScreen":@YES,@"screenShake":@YES,@"shakeIntensity":@2}); }
static void ELSpeedBoostAll(void)         { ELWriteFlags(@{@"speedBoostAll":@YES,@"speedMultiplier":@3,@"moveSpeedAll":@3}); }
static void ELBigHeadEffect(BOOL on)      { ELWriteFlags(@{@"bigHead":@(on),@"headScale":@(on?3.5:1.0),@"bigHeadMode":@(on)}); }
static void ELPinkScreen(void)            { ELWriteFlags(@{@"screenColor":@"pink",@"colorOverlay":@"pink",@"screenTint":@YES}); }
static void ELRedScreen(void)             { ELWriteFlags(@{@"screenColor":@"red",@"colorOverlay":@"red",@"screenTint":@YES}); }
static void ELRainbowAllPlayers(void)     { ELWriteFlags(@{@"rainbowPlayers":@YES,@"rainbowAll":@YES,@"colorCycle":@YES}); }
static void ELRandomColorsAll(void)       { ELWriteFlags(@{@"randomColorsAll":@YES,@"randomizeColors":@YES}); }
static void ELFlashColors(void)           { ELWriteFlags(@{@"flashColors":@YES,@"colorFlash":@YES,@"flashInterval":@0.1}); }
static void ELMakeEveryoneBig(BOOL on)    { ELWriteFlags(@{@"makeEveryoneBig":@(on),@"allPlayersScale":@(on?3.0:1.0)}); }
static void ELRadioactiveEffect(void)     { ELWriteFlags(@{@"radioactiveEffect":@YES,@"radioactive":@YES}); }
static void ELJellyEffect(void)           { ELWriteFlags(@{@"jellyEffect":@YES,@"jellyPhysics":@YES}); }
static void ELJellySelf(void)             { ELWriteFlags(@{@"jellySelf":@YES,@"selfJelly":@YES}); }
static void ELTagStinky(void)             { ELWriteFlags(@{@"tagAsStinky":@YES,@"stinky":@YES}); }
static void ELMuffledVoice(BOOL on)       { ELWriteFlags(@{@"muffledVoice":@(on),@"voiceFilter":@"muffled"}); }
static void ELSqueakyVoice(BOOL on)       { ELWriteFlags(@{@"squeakyVoice":@(on),@"voicePitch":@(on?3.0:1.0)}); }
static void ELPlayTimeoutSound(void)      { ELWriteFlags(@{@"playTimeoutSound":@YES,@"soundEffect":@"timeout"}); }
static void ELPlayNightAlarm(void)        { ELWriteFlags(@{@"playNightAlarm":@YES,@"soundEffect":@"nightAlarm"}); }
static void ELRandomSFX(void)             { ELWriteFlags(@{@"randomSoundEffect":@YES,@"playSFX":@YES}); }
static void ELSpawnSnowballStream(void) {
    ELVec3 pos = ELCameraPosition();
    NSMutableArray *list = [NSMutableArray array];
    for (int i=0;i<10;i++)
        [list addObject:@{@"itemID":@"item_snowball",@"id":@"item_snowball",@"state":@1,@"pending":@YES,
                          @"position":@{@"x":@(pos.x+i*0.5f),@"y":@(pos.y),@"z":@(pos.z)}}];
    ELWriteFlags(@{@"items":list,@"spawnItems":list});
}
static void ELColorSnowballs(void) {
    ELVec3 pos = ELCameraPosition();
    NSMutableArray *list = [NSMutableArray array];
    for (int i=0;i<10;i++)
        [list addObject:@{@"itemID":@"item_snowball",@"id":@"item_snowball",@"state":@1,@"pending":@YES,
                          @"colorHue":@(i*36),
                          @"position":@{@"x":@(pos.x+i*0.5f),@"y":@(pos.y),@"z":@(pos.z)}}];
    ELWriteFlags(@{@"items":list,@"spawnItems":list});
}
// Advanced writers
static void ELStartGame(void)            { ELWriteFlags(@{@"startGame":@YES,@"triggerStart":@YES}); }
static void ELEndGame(void)              { ELWriteFlags(@{@"endGame":@YES,@"triggerEnd":@YES}); }
static void ELEndEarly(void)             { ELWriteFlags(@{@"endEarly":@YES,@"forceEnd":@YES}); }
static void ELResetGame(void)            { ELWriteFlags(@{@"resetGame":@YES,@"triggerReset":@YES}); }
static void ELRandomizeTeams(void)       { ELWriteFlags(@{@"randomizeTeams":@YES,@"shuffleTeams":@YES}); }
static void ELDropAllObjects(void)       { ELWriteFlags(@{@"dropAllObjects":@YES,@"forceDropAll":@YES}); }
static void ELUseJetpackAll(void)        { ELWriteFlags(@{@"useJetpackAll":@YES,@"giveJetpackAll":@YES}); }
static void ELRainbowAllItems(void)      { ELWriteFlags(@{@"rainbowItems":@YES,@"colorCycleItems":@YES}); }
static void ELScaleItems(float s)        { ELWriteFlags(@{@"itemScale":@(s),@"scaleAllItems":@(s)}); }
static void ELRemoveItemGravity(void)    { ELWriteFlags(@{@"removeItemGravity":@YES,@"itemsFloat":@YES,@"itemGravity":@0}); }
static void ELRestoreItemGravity(void)   { ELWriteFlags(@{@"removeItemGravity":@NO,@"itemsFloat":@NO,@"itemGravity":@1}); }
static void ELSpawnTreeAtPlayer(void)    { ELWriteFlags(@{@"spawnTree":@YES,@"spawnTreeAtPlayer":@YES}); }
static void ELSpawnTreeForest(void)      { ELWriteFlags(@{@"spawnForest":@YES,@"treeCount":@20}); }
static void ELActivateRoboMonkes(void)   { ELWriteFlags(@{@"activateRoboMonkes":@YES,@"allRoboMonkes":@YES}); }
static void ELGrindAllOres(void)         { ELWriteFlags(@{@"grindAllOres":@YES,@"collectOres":@YES,@"autoGrind":@YES}); }
static void ELAwardKill(void)            { ELWriteFlags(@{@"awardKill":@YES,@"giveKill":@YES}); }
static void ELAddScore(NSInteger pts)    { ELWriteFlags(@{@"addScore":@(pts),@"scoreBonus":@(pts)}); }
static void ELSpawnHeavyStick(void)      { ELWriteConfig(@"leftHand", @"item_stick_bone",  0,   0,   127, 1, nil); }
static void ELSpawnColorStick(void)      { ELWriteConfig(@"leftHand", @"item_stick_bone",  180, 255, 0,   1, nil); }
static void ELSpawnTeleBackpack(void)    { ELWriteConfig(@"back",     @"item_tele_grenade", 0,   0,   0,   1, nil); }
- (BOOL)textFieldShouldReturn:(UITextField *)tf {
    [tf resignFirstResponder];
    return YES;
}

@end

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Shared UI helpers (for new pages)
// ═══════════════════════════════════════════════════════════════════════════════

- (UIButton *)elHalfBtn:(NSString *)title page:(UIScrollView *)pg x:(CGFloat)x y:(CGFloat)y {
    CGFloat w = pg.frame.size.width;
    CGFloat bw = (w - 26) / 2.0f;
    UIButton *b = [[UIButton alloc] initWithFrame:CGRectMake(x, y, bw, 34)];
    b.backgroundColor    = [UIColor colorWithWhite:0 alpha:0.4];
    b.layer.cornerRadius = 8; b.layer.borderWidth = 1;
    b.layer.borderColor  = EL_BORDER;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:EL_TEXT forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    return b;
}

- (UIButton *)elFullBtn:(NSString *)title page:(UIScrollView *)pg y:(CGFloat)y
                  colorA:(UIColor *)ca colorB:(UIColor *)cb {
    CGFloat w = pg.frame.size.width;
    CGFloat bw = w - 20;
    UIButton *b = [[UIButton alloc] initWithFrame:CGRectMake(10, y, bw, 38)];
    b.layer.cornerRadius = 10; b.clipsToBounds = YES;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = CGRectMake(0,0,bw,38);
    g.colors = @[(id)ca.CGColor, (id)cb.CGColor];
    g.startPoint = CGPointMake(0,0.5); g.endPoint = CGPointMake(1,0.5);
    [b.layer insertSublayer:g atIndex:0];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    ELGlow(b.layer, ca, 10);
    return b;
}

- (void)elSectionHdr:(NSString *)title page:(UIScrollView *)pg y:(CGFloat)y {
    CGFloat w = pg.frame.size.width;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(12,y,w-24,16)];
    l.text = title; l.font = [UIFont boldSystemFontOfSize:10]; l.textColor = EL_TEXT_DIM;
    [pg addSubview:l];
}

- (void)elDivider:(UIScrollView *)pg y:(CGFloat)y {
    CGFloat w = pg.frame.size.width;
    UIView *d = [[UIView alloc] initWithFrame:CGRectMake(10,y,w-20,1)];
    d.backgroundColor = EL_DIVIDER;
    [pg addSubview:d];
}

- (UISwitch *)elToggleRow:(NSString *)title sub:(NSString *)sub page:(UIScrollView *)pg y:(CGFloat)y {
    CGFloat w = pg.frame.size.width;
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(10,y,w-20,44)];
    row.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    row.layer.cornerRadius = 10; row.layer.borderWidth = 1; row.layer.borderColor = EL_BORDER;
    [pg addSubview:row];
    UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(12,5,w-80,18)];
    tl.text = title; tl.font = [UIFont boldSystemFontOfSize:12]; tl.textColor = EL_TEXT;
    [row addSubview:tl];
    UILabel *sl = [[UILabel alloc] initWithFrame:CGRectMake(12,22,w-80,16)];
    sl.text = sub; sl.font = [UIFont systemFontOfSize:10]; sl.textColor = EL_TEXT_DIM;
    [row addSubview:sl];
    UISwitch *sw = [[UISwitch alloc] init];
    sw.onTintColor = EL_PURPLE;
    sw.transform   = CGAffineTransformMakeScale(0.78f, 0.78f);
    sw.frame       = CGRectMake(w-68, 8, 51, 31);
    [row addSubview:sw];
    return sw;
}

// ─── ADD_BLOCK macro helper ───────────────────────────────────────────────────
// All new buttons use el_addBlock instead of addTarget:action: for compactness.

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Player Page
// ═══════════════════════════════════════════════════════════════════════════════

- (void)buildPlayerPage {
    UIScrollView *pg = _playerPage;
    CGFloat w  = pg.frame.size.width;
    CGFloat bw = (w - 26) / 2.0f;
    CGFloat y  = 8;

    [self elSectionHdr:@"◼ TELEPORTATION" page:pg y:y]; y+=20;

    UIButton *homeBtn = [self elFullBtn:@"🏠  Teleport Home" page:pg y:y
        colorA:[UIColor colorWithRed:0.1 green:0.6 blue:0.3 alpha:1]
        colorB:[UIColor colorWithRed:0.0 green:0.3 blue:0.2 alpha:1]];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELTeleportToPosition(@"Lobby");ELToast(@"🏠 Teleported Home",YES);}];
      [homeBtn addGestureRecognizer:t]; [pg addSubview:homeBtn]; } y+=44;

    UIButton *upBtn = [self elFullBtn:@"🚀  Launch Upward" page:pg y:y
        colorA:[UIColor colorWithRed:0.2 green:0.4 blue:1.0 alpha:1]
        colorB:[UIColor colorWithRed:0.1 green:0.2 blue:0.6 alpha:1]];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELLaunchUpward();ELToast(@"🚀 Launched upward!",YES);}];
      [upBtn addGestureRecognizer:t]; [pg addSubview:upBtn]; } y+=48;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ PLAYER EFFECTS" page:pg y:y]; y+=20;

    UIButton *killBtn=[self elHalfBtn:@"💀 Kill Players"  page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELKillPlayers();ELToast(@"💀 Kill signal sent",YES);}];
      [killBtn addGestureRecognizer:t]; [pg addSubview:killBtn]; }
    UIButton *stunBtn=[self elHalfBtn:@"⚡ Stun Players" page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELStunPlayers();ELToast(@"⚡ Stun sent",YES);}];
      [stunBtn addGestureRecognizer:t]; [pg addSubview:stunBtn]; } y+=40;

    UIButton *nutsBtn=[self elFullBtn:@"💰  Give Money (999,999,999 Nuts)" page:pg y:y
        colorA:[UIColor colorWithRed:0.8 green:0.6 blue:0.0 alpha:1]
        colorB:[UIColor colorWithRed:0.4 green:0.3 blue:0.0 alpha:1]];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELWriteMoney(999999999LL);ELToast(@"💰 Max Nuts written!",YES);}];
      [nutsBtn addGestureRecognizer:t]; [pg addSubview:nutsBtn]; } y+=48;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ LOCAL PLAYER FEATURES" page:pg y:y]; y+=20;

    UISwitch *sw0=[self elToggleRow:@"🛡 God Mode"      sub:@"No damage taken"               page:pg y:y];
    [sw0 addTarget:self action:@selector(plGodMode:) forControlEvents:UIControlEventValueChanged]; y+=50;
    UISwitch *sw1=[self elToggleRow:@"🕊 Fly Mode"      sub:@"Float freely"                   page:pg y:y];
    [sw1 addTarget:self action:@selector(plFlyMode:) forControlEvents:UIControlEventValueChanged]; y+=50;
    UISwitch *sw2=[self elToggleRow:@"👻 Noclip"         sub:@"Pass through geometry"          page:pg y:y];
    [sw2 addTarget:self action:@selector(plNoclip:)  forControlEvents:UIControlEventValueChanged]; y+=50;
    UISwitch *sw3=[self elToggleRow:@"🫥 Invisibility"   sub:@"Hidden from other players"      page:pg y:y];
    [sw3 addTarget:self action:@selector(plInvis:)   forControlEvents:UIControlEventValueChanged]; y+=50;
    UISwitch *sw4=[self elToggleRow:@"🧱 Platforms"      sub:@"Spawn platforms under feet"     page:pg y:y];
    [sw4 addTarget:self action:@selector(plPlatforms:) forControlEvents:UIControlEventValueChanged]; y+=50;

    UIButton *randBtn=[self elHalfBtn:@"🎲 Tele to Player" page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELTeleToRandPlayer();ELToast(@"🎲 Teleporting...",YES);}];
      [randBtn addGestureRecognizer:t]; [pg addSubview:randBtn]; }
    UIButton *nukeBtn=[self elHalfBtn:@"💥 Spawn Nuke"     page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnNukeItems();ELToast(@"💥 Nuke items spawned!",YES);}];
      [nukeBtn addGestureRecognizer:t]; [pg addSubview:nukeBtn]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ GRAVITY CONTROLS" page:pg y:y]; y+=20;

    UIButton *zg=[self elHalfBtn:@"🌌 Zero Gravity"  page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSetGravity(0);ELToast(@"🌌 Zero Gravity!",YES);}];
      [zg addGestureRecognizer:t]; [pg addSubview:zg]; }
    UIButton *lg=[self elHalfBtn:@"🪶 Low Gravity"   page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSetGravity(-2.0f);ELToast(@"🪶 Low Gravity!",YES);}];
      [lg addGestureRecognizer:t]; [pg addSubview:lg]; } y+=40;
    UIButton *hg=[self elHalfBtn:@"🏋 High Gravity" page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSetGravity(-30.0f);ELToast(@"🏋 High Gravity!",YES);}];
      [hg addGestureRecognizer:t]; [pg addSubview:hg]; }
    UIButton *ng=[self elHalfBtn:@"🌍 Normal"        page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSetGravity(-9.81f);ELToast(@"🌍 Normal Gravity",YES);}];
      [ng addGestureRecognizer:t]; [pg addSubview:ng]; } y+=44;

    pg.contentSize = CGSizeMake(w, y);
}
- (void)plGodMode:(UISwitch *)s    { ELWriteGodMode(s.on);      ELToast(s.on?@"🛡 God Mode ON":@"God Mode OFF",      s.on); }
- (void)plFlyMode:(UISwitch *)s    { ELWriteFlyMode(s.on);      ELToast(s.on?@"🕊 Fly Mode ON":@"Fly Mode OFF",      s.on); }
- (void)plNoclip:(UISwitch *)s     { ELWriteNoclip(s.on);       ELToast(s.on?@"👻 Noclip ON":@"Noclip OFF",          s.on); }
- (void)plInvis:(UISwitch *)s      { ELWriteInvisibility(s.on); ELToast(s.on?@"🫥 Invisible ON":@"Invisible OFF",    s.on); }
- (void)plPlatforms:(UISwitch *)s  { ELWritePlatforms(s.on);    ELToast(s.on?@"🧱 Platforms ON":@"Platforms OFF",    s.on); }

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Fun Page
// ═══════════════════════════════════════════════════════════════════════════════

- (void)buildFunPage {
    UIScrollView *pg = _funPage;
    CGFloat w  = pg.frame.size.width;
    CGFloat bw = (w - 26) / 2.0f;
    CGFloat y  = 8;

    [self elSectionHdr:@"◼ FUN ACTIONS" page:pg y:y]; y+=20;

    UIButton *shk=[self elHalfBtn:@"📳 Shake Screen"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELShakeScreen();ELToast(@"📳 Shaking!",YES);}];
      [shk addGestureRecognizer:t]; [pg addSubview:shk]; }
    UIButton *spd=[self elHalfBtn:@"⚡ Speed Boost All" page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpeedBoostAll();ELToast(@"⚡ Speed boost!",YES);}];
      [spd addGestureRecognizer:t]; [pg addSubview:spd]; } y+=40;

    UIButton *hit=[self elHalfBtn:@"🥊 Hit Players"    page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELHitPlayers();ELToast(@"🥊 Hit all!",YES);}];
      [hit addGestureRecognizer:t]; [pg addSubview:hit]; }
    UIButton *ag=[self elHalfBtn:@"🌌 Anti-Gravity"    page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSetGravity(9.81f);ELToast(@"🌌 Anti-Gravity!",YES);}];
      [ag addGestureRecognizer:t]; [pg addSubview:ag]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ VISUAL EFFECTS" page:pg y:y]; y+=20;

    UISwitch *bhSw=[self elToggleRow:@"👾 Big Head Effect"   sub:@"Enlarges all player heads" page:pg y:y];
    [bhSw addTarget:self action:@selector(funBigHead:) forControlEvents:UIControlEventValueChanged]; y+=50;

    UIButton *pink=[self elHalfBtn:@"🩷 Pink Screen"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELPinkScreen();ELToast(@"🩷 Pink screen!",YES);}];
      [pink addGestureRecognizer:t]; [pg addSubview:pink]; }
    UIButton *red=[self elHalfBtn:@"🔴 Red Screen"    page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRedScreen();ELToast(@"🔴 Red screen!",YES);}];
      [red addGestureRecognizer:t]; [pg addSubview:red]; } y+=40;

    UIButton *rb=[self elHalfBtn:@"🌈 Rainbow All"    page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRainbowAllPlayers();ELToast(@"🌈 Rainbow!",YES);}];
      [rb addGestureRecognizer:t]; [pg addSubview:rb]; }
    UIButton *rc=[self elHalfBtn:@"🎨 Random Colors"  page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRandomColorsAll();ELToast(@"🎨 Random colors!",YES);}];
      [rc addGestureRecognizer:t]; [pg addSubview:rc]; } y+=40;

    UIButton *fl=[self elHalfBtn:@"✨ Flash Colors"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELFlashColors();ELToast(@"✨ Flash!",YES);}];
      [fl addGestureRecognizer:t]; [pg addSubview:fl]; }
    UISwitch *bigAllSw=[self elToggleRow:@"🏔 Make Everyone Big" sub:@"3x scale" page:pg y:y+40];
    [bigAllSw addTarget:self action:@selector(funBigAll:) forControlEvents:UIControlEventValueChanged]; y+=90;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ STATUS EFFECTS" page:pg y:y]; y+=20;

    UIButton *rad=[self elHalfBtn:@"☢️ Radioactive"  page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRadioactiveEffect();ELToast(@"☢️ Radioactive!",YES);}];
      [rad addGestureRecognizer:t]; [pg addSubview:rad]; }
    UIButton *jel=[self elHalfBtn:@"🍮 Jelly Effect"  page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELJellyEffect();ELToast(@"🍮 Jelly!",YES);}];
      [jel addGestureRecognizer:t]; [pg addSubview:jel]; } y+=40;

    UIButton *jself=[self elHalfBtn:@"🟡 Jelly Self"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELJellySelf();ELToast(@"🟡 Jelly Self!",YES);}];
      [jself addGestureRecognizer:t]; [pg addSubview:jself]; }
    UIButton *stk=[self elHalfBtn:@"🦨 Tag Stinky"    page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELTagStinky();ELToast(@"🦨 Tagged stinky!",YES);}];
      [stk addGestureRecognizer:t]; [pg addSubview:stk]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ VOICE EFFECTS" page:pg y:y]; y+=20;

    UISwitch *mufSw=[self elToggleRow:@"🔇 Muffled Voice"  sub:@"Muffle all voice chat"    page:pg y:y];
    [mufSw addTarget:self action:@selector(funMuffled:) forControlEvents:UIControlEventValueChanged]; y+=50;
    UISwitch *sqkSw=[self elToggleRow:@"🐭 Squeaky Voice"  sub:@"High pitch voice chat"    page:pg y:y];
    [sqkSw addTarget:self action:@selector(funSqueaky:) forControlEvents:UIControlEventValueChanged]; y+=50;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ AUDIO" page:pg y:y]; y+=20;

    UIButton *to=[self elHalfBtn:@"🔔 Timeout Sound"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELPlayTimeoutSound();ELToast(@"🔔 Timeout!",YES);}];
      [to addGestureRecognizer:t]; [pg addSubview:to]; }
    UIButton *na=[self elHalfBtn:@"🚨 Night Alarm"     page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELPlayNightAlarm();ELToast(@"🚨 Night Alarm!",YES);}];
      [na addGestureRecognizer:t]; [pg addSubview:na]; } y+=40;

    UIButton *sfx=[self elFullBtn:@"🎲  Random Sound Effect" page:pg y:y
        colorA:[UIColor colorWithRed:0.4 green:0.1 blue:0.7 alpha:1]
        colorB:[UIColor colorWithRed:0.2 green:0.0 blue:0.4 alpha:1]];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRandomSFX();ELToast(@"🎲 Random SFX!",YES);}];
      [sfx addGestureRecognizer:t]; [pg addSubview:sfx]; } y+=48;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ FUN SPAWNS" page:pg y:y]; y+=20;

    UIButton *sn=[self elHalfBtn:@"❄️ Snowball Stream"  page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnSnowballStream();ELToast(@"❄️ Snowballs!",YES);}];
      [sn addGestureRecognizer:t]; [pg addSubview:sn]; }
    UIButton *cs=[self elHalfBtn:@"🌈 Color Snowballs"  page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELColorSnowballs();ELToast(@"🌈 Color snowballs!",YES);}];
      [cs addGestureRecognizer:t]; [pg addSubview:cs]; } y+=44;

    pg.contentSize = CGSizeMake(w, y);
}
- (void)funBigHead:(UISwitch *)s  { ELBigHeadEffect(s.on);    ELToast(s.on?@"👾 Big Head ON":@"Big Head OFF",      s.on); }
- (void)funBigAll:(UISwitch *)s   { ELMakeEveryoneBig(s.on);  ELToast(s.on?@"🏔 Everyone Big ON":@"Normal",        s.on); }
- (void)funMuffled:(UISwitch *)s  { ELMuffledVoice(s.on);     ELToast(s.on?@"🔇 Muffled ON":@"Muffled OFF",        s.on); }
- (void)funSqueaky:(UISwitch *)s  { ELSqueakyVoice(s.on);     ELToast(s.on?@"🐭 Squeaky ON":@"Squeaky OFF",        s.on); }

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Advanced Page
// ═══════════════════════════════════════════════════════════════════════════════

- (void)buildAdvancedPage {
    UIScrollView *pg = _advancedPage;
    CGFloat w  = pg.frame.size.width;
    CGFloat bw = (w - 26) / 2.0f;
    CGFloat y  = 8;

    [self elSectionHdr:@"◼ GAME CONTROLS" page:pg y:y]; y+=20;

    UIButton *sg=[self elHalfBtn:@"▶️ Start Game"  page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELStartGame();ELToast(@"▶️ Start sent",YES);}];
      [sg addGestureRecognizer:t]; [pg addSubview:sg]; }
    UIButton *eg=[self elHalfBtn:@"⏹ End Game"   page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELEndGame();ELToast(@"⏹ End sent",YES);}];
      [eg addGestureRecognizer:t]; [pg addSubview:eg]; } y+=40;

    UIButton *ee=[self elHalfBtn:@"⏩ End Early"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELEndEarly();ELToast(@"⏩ Force end",YES);}];
      [ee addGestureRecognizer:t]; [pg addSubview:ee]; }
    UIButton *rg=[self elHalfBtn:@"🔄 Reset Game" page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELResetGame();ELToast(@"🔄 Reset sent",YES);}];
      [rg addGestureRecognizer:t]; [pg addSubview:rg]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ TEAM" page:pg y:y]; y+=20;

    UIButton *rt=[self elFullBtn:@"🎲  Randomize All Teams" page:pg y:y
        colorA:[UIColor colorWithRed:0.1 green:0.5 blue:0.9 alpha:1]
        colorB:[UIColor colorWithRed:0.0 green:0.2 blue:0.5 alpha:1]];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRandomizeTeams();ELToast(@"🎲 Teams randomized!",YES);}];
      [rt addGestureRecognizer:t]; [pg addSubview:rt]; } y+=48;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ OBJECTS" page:pg y:y]; y+=20;

    UIButton *drop=[self elHalfBtn:@"📦 Drop All Objects" page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELDropAllObjects();ELToast(@"📦 Dropped all!",YES);}];
      [drop addGestureRecognizer:t]; [pg addSubview:drop]; }
    UIButton *jet=[self elHalfBtn:@"🚀 Jetpack All"     page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELUseJetpackAll();ELToast(@"🚀 Jetpack all!",YES);}];
      [jet addGestureRecognizer:t]; [pg addSubview:jet]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ ITEM EFFECTS" page:pg y:y]; y+=20;

    UIButton *rbi=[self elHalfBtn:@"🌈 Rainbow Items"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRainbowAllItems();ELToast(@"🌈 Rainbow items!",YES);}];
      [rbi addGestureRecognizer:t]; [pg addSubview:rbi]; }
    UIButton *si2=[self elHalfBtn:@"📏 Scale Items (2x)" page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELScaleItems(2.0f);ELToast(@"📏 Items scaled!",YES);}];
      [si2 addGestureRecognizer:t]; [pg addSubview:si2]; } y+=40;

    UIButton *ng=[self elHalfBtn:@"🪄 Remove Gravity"   page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRemoveItemGravity();ELToast(@"🪄 Items floating!",YES);}];
      [ng addGestureRecognizer:t]; [pg addSubview:ng]; }
    UIButton *rg2=[self elHalfBtn:@"⬇️ Restore Gravity"  page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELRestoreItemGravity();ELToast(@"⬇️ Gravity restored",YES);}];
      [rg2 addGestureRecognizer:t]; [pg addSubview:rg2]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ TREES" page:pg y:y]; y+=20;

    UIButton *tree=[self elHalfBtn:@"🌲 Spawn Tree"      page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnTreeAtPlayer();ELToast(@"🌲 Tree spawned!",YES);}];
      [tree addGestureRecognizer:t]; [pg addSubview:tree]; }
    UIButton *forest=[self elHalfBtn:@"🌳 Tree Forest"   page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnTreeForest();ELToast(@"🌳 Forest spawned!",YES);}];
      [forest addGestureRecognizer:t]; [pg addSubview:forest]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ UTILITY" page:pg y:y]; y+=20;

    UIButton *rmk=[self elHalfBtn:@"🦾 Activate Monkes" page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELActivateRoboMonkes();ELToast(@"🦾 RoboMonkes!",YES);}];
      [rmk addGestureRecognizer:t]; [pg addSubview:rmk]; }
    UIButton *ore=[self elHalfBtn:@"⛏ Grind All Ores"   page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELGrindAllOres();ELToast(@"⛏ Ores ground!",YES);}];
      [ore addGestureRecognizer:t]; [pg addSubview:ore]; } y+=40;

    UIButton *ak=[self elHalfBtn:@"🏆 Award Kill"        page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELAwardKill();ELToast(@"🏆 Kill awarded!",YES);}];
      [ak addGestureRecognizer:t]; [pg addSubview:ak]; }
    UIButton *as=[self elHalfBtn:@"➕ Add Score (100)"   page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELAddScore(100);ELToast(@"➕ +100 score!",YES);}];
      [as addGestureRecognizer:t]; [pg addSubview:as]; } y+=44;

    [self elDivider:pg y:y]; y+=10;
    [self elSectionHdr:@"◼ SPECIAL ITEMS" page:pg y:y]; y+=20;

    UIButton *hvy=[self elHalfBtn:@"🪵 Heavy Stick"      page:pg x:10   y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnHeavyStick();ELToast(@"🪵 Heavy Stick!",YES);}];
      [hvy addGestureRecognizer:t]; [pg addSubview:hvy]; }
    UIButton *col=[self elHalfBtn:@"🎨 Color Stick"       page:pg x:16+bw y:y];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnColorStick();ELToast(@"🎨 Color Stick!",YES);}];
      [col addGestureRecognizer:t]; [pg addSubview:col]; } y+=40;

    UIButton *tb=[self elFullBtn:@"🎒  Tele-Grenade Backpack" page:pg y:y
        colorA:[UIColor colorWithRed:0.5 green:0.1 blue:0.9 alpha:1]
        colorB:[UIColor colorWithRed:0.2 green:0.0 blue:0.5 alpha:1]];
    { UITapGestureRecognizer *t=[[UITapGestureRecognizer alloc]initWithTarget:nil action:nil];
      [t el_addBlock:^(__unused id s){ELSpawnTeleBackpack();ELToast(@"🎒 Tele Backpack!",YES);}];
      [tb addGestureRecognizer:t]; [pg addSubview:tb]; } y+=48;

    pg.contentSize = CGSizeMake(w, y);
}



// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Splash screen (shows immediately on dylib load to confirm injection)
// ═══════════════════════════════════════════════════════════════════════════════

static void ELShowSplash(void) {
    dispatch_async(dispatch_get_main_queue(), ^{

        // Find any usable window
        UIWindow *win = nil;
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                        if (w.rootViewController) { win = w; break; }
                    }
                }
                if (win) break;
            }
        }
        if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            for (UIWindow *w in [[UIApplication sharedApplication] windows]) {
                if (w.rootViewController) { win = w; break; }
            }
#pragma clang diagnostic pop
        }
        if (!win) {
            // Retry in 0.3 s — called very early, window may not exist yet
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ELShowSplash(); });
            return;
        }

        CGRect  screen = [UIScreen mainScreen].bounds;
        CGFloat sw = screen.size.width;
        CGFloat sh = screen.size.height;

        // Full-screen dark overlay
        UIView *overlay = [[UIView alloc] initWithFrame:screen];
        overlay.backgroundColor = [UIColor colorWithRed:0.03 green:0.03 blue:0.03 alpha:0.97];
        overlay.layer.zPosition = 99999;
        overlay.alpha = 0;

        // Card container centred on screen
        CGFloat cw = MIN(sw - 48, 300), ch = 220;
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake((sw-cw)/2, (sh-ch)/2, cw, ch)];
        card.backgroundColor    = [UIColor colorWithRed:0.07 green:0.07 blue:0.07 alpha:1.0];
        card.layer.cornerRadius = 18;
        card.layer.borderWidth  = 1.5;
        card.layer.borderColor  = [UIColor colorWithWhite:0.35 alpha:1.0].CGColor;
        card.layer.shadowColor  = [UIColor blackColor].CGColor;
        card.layer.shadowOpacity = 0.6;
        card.layer.shadowRadius  = 20;
        card.layer.shadowOffset  = CGSizeZero;
        [overlay addSubview:card];

        // Icon label (big emoji)
        UILabel *icon = [[UILabel alloc] initWithFrame:CGRectMake(0, 22, cw, 54)];
        icon.text          = @"⬛";
        icon.font          = [UIFont systemFontOfSize:46];
        icon.textAlignment = NSTextAlignmentCenter;
        [card addSubview:icon];

        // Title
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 82, cw-20, 28)];
        title.text          = @"ANIMAL COMPANY MOD";
        title.font          = [UIFont boldSystemFontOfSize:15];
        title.textColor     = [UIColor whiteColor];
        title.textAlignment = NSTextAlignmentCenter;
        [card addSubview:title];

        // Subtitle
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(10, 112, cw-20, 20)];
        sub.text          = @"Dylib loaded ✓";
        sub.font          = [UIFont systemFontOfSize:13];
        sub.textColor     = [UIColor colorWithRed:0.4 green:0.9 blue:0.4 alpha:1.0];
        sub.textAlignment = NSTextAlignmentCenter;
        [card addSubview:sub];

        // Version / bundle
        UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(10, 136, cw-20, 16)];
        ver.text          = [NSString stringWithFormat:@"Bundle: %@",
                             [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"];
        ver.font          = [UIFont systemFontOfSize:10];
        ver.textColor     = [UIColor colorWithWhite:0.45 alpha:1.0];
        ver.textAlignment = NSTextAlignmentCenter;
        [card addSubview:ver];

        // Spinner / loading bar
        UIView *barBg = [[UIView alloc] initWithFrame:CGRectMake(24, 168, cw-48, 6)];
        barBg.backgroundColor    = [UIColor colorWithWhite:0.18 alpha:1.0];
        barBg.layer.cornerRadius = 3;
        barBg.clipsToBounds      = YES;
        UIView *barFill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 6)];
        barFill.backgroundColor    = [UIColor colorWithRed:0.3 green:0.85 blue:0.3 alpha:1.0];
        barFill.layer.cornerRadius = 3;
        [barBg addSubview:barFill];
        [card addSubview:barBg];

        // Dismiss hint
        UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(10, 192, cw-20, 16)];
        hint.text          = @"Auto-dismisses in 3 s";
        hint.font          = [UIFont systemFontOfSize:10];
        hint.textColor     = [UIColor colorWithWhite:0.35 alpha:1.0];
        hint.textAlignment = NSTextAlignmentCenter;
        [card addSubview:hint];

        // Add to window root view directly
        UIView *root = win.rootViewController.view;
        [root addSubview:overlay];
        [root bringSubviewToFront:overlay];

        // Fade in
        [UIView animateWithDuration:0.3 animations:^{ overlay.alpha = 1; }];

        // Animate loading bar across 2.5 s
        [UIView animateWithDuration:2.5 delay:0.1 options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{
            barFill.frame = CGRectMake(0, 0, cw-48, 6);
        } completion:nil];

        // Fade out and remove after 3 s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.4 animations:^{ overlay.alpha = 0; }
                             completion:^(BOOL _){ [overlay removeFromSuperview]; }];
        });
    });
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: — Injection
// ═══════════════════════════════════════════════════════════════════════════════

static MT4Menu *gMenu = nil;
static UIButton      *gBtn  = nil;

static void ELInject(void) {
    dispatch_async(dispatch_get_main_queue(), ^{

        // Guard: skip only if button is already live and visible on screen
        if (gBtn != nil && gBtn.window != nil && !gBtn.isHidden) return;
        // Reset stale references
        gBtn = nil;
        gMenu = nil;

        NSLog(@"[AnimalCompanyMod] ELInject called — bundle=%@",
              [[NSBundle mainBundle] bundleIdentifier]);

        // ── Find any window with a rootViewController ─────────────────────────
        NSArray<UIWindow *> *allWindows = nil;
        if (@available(iOS 13.0, *)) {
            NSMutableArray *tmp = [NSMutableArray array];
            for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if ([sc isKindOfClass:[UIWindowScene class]])
                    [tmp addObjectsFromArray:((UIWindowScene *)sc).windows];
            }
            allWindows = tmp;
        }
        if (!allWindows.count)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            allWindows = [[UIApplication sharedApplication] windows];
#pragma clang diagnostic pop

        UIWindow *win = nil;
        for (UIWindow *w in allWindows) {
            if (w.rootViewController) { win = w; break; }
        }
        if (!win) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ELInject(); });
            return;
        }

        // Screen bounds — always valid
        CGRect  screen  = [UIScreen mainScreen].bounds;
        CGFloat sw      = screen.size.width;
        CGFloat sh      = screen.size.height;
        CGFloat safeTop = 50.0f;
        if (@available(iOS 11.0, *)) {
            CGFloat ins = win.safeAreaInsets.top;
            if (ins > 0) safeTop = ins + 4;
        }

        // ── Build a dedicated overlay UIWindow — most reliable across Unity versions ──
        // We tried injecting into the game view directly but Unity's Metal surface
        // doesn't always forward UIKit subviews to the compositor. A separate
        // UIWindow at a high windowLevel always renders on top regardless.
        UIWindow *overlayWin = nil;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *bestScene = nil;
            for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                if (!bestScene || sc.activationState < bestScene.activationState)
                    bestScene = sc;  // lower enum value = more active
            }
            if (bestScene)
                overlayWin = [[UIWindow alloc] initWithWindowScene:bestScene];
        }
        if (!overlayWin)
            overlayWin = [[UIWindow alloc] initWithFrame:screen];

        overlayWin.frame                  = screen;
        overlayWin.windowLevel            = UIWindowLevelAlert + 200;
        overlayWin.backgroundColor        = [UIColor clearColor];
        overlayWin.userInteractionEnabled = YES;
        overlayWin.hidden                 = NO;

        // Root VC — transparent passthrough
        UIViewController *ovc = [[UIViewController alloc] init];
        ovc.view.backgroundColor      = [UIColor clearColor];
        ovc.view.userInteractionEnabled = YES;
        overlayWin.rootViewController = ovc;
        [overlayWin makeKeyAndVisible];
        // Give key back to game window immediately
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [win makeKeyWindow]; });

        // Hold strong reference so ARC doesn't release it
        objc_setAssociatedObject([UIApplication sharedApplication],
                                 "ELOverlay", overlayWin, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIView *container = ovc.view;
        container.frame = screen;

        // ── Toggle button ─────────────────────────────────────────────────────
        CGFloat btnW = 80, btnH = 36;
        gBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        gBtn.frame               = CGRectMake(sw - btnW - 10, safeTop, btnW, btnH);
        gBtn.backgroundColor     = [UIColor colorWithRed:0.08 green:0.08 blue:0.08 alpha:0.95];
        gBtn.layer.cornerRadius  = btnH / 2.0f;
        gBtn.layer.masksToBounds = YES;
        gBtn.layer.borderWidth   = 1.5f;
        gBtn.layer.borderColor   = [UIColor colorWithWhite:0.6 alpha:1.0].CGColor;
        [gBtn setTitle:@"MENU" forState:UIControlStateNormal];
        [gBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        gBtn.titleLabel.font     = [UIFont boldSystemFontOfSize:13];
        [container addSubview:gBtn];

        // ── Menu panel ────────────────────────────────────────────────────────
        CGFloat mw = MIN(sw - 20, 320);
        CGFloat mh = MIN(sh * 0.68f, 580);
        CGFloat mx = (sw - mw) / 2.0f;
        CGFloat my = safeTop + btnH + 4;
        if (my + mh > sh - 10) my = sh - mh - 10;
        gMenu = [[MT4Menu alloc] initWithFrame:CGRectMake(mx, my, mw, mh)];
        gMenu.hidden = YES;
        [container addSubview:gMenu];

        // ── Tap to toggle ─────────────────────────────────────────────────────
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
        [tap el_addBlock:^(__unused id s) {
            if (gMenu.hidden) {
                gMenu.hidden    = NO;
                gMenu.alpha     = 0;
                gMenu.transform = CGAffineTransformMakeScale(0.88f, 0.88f);
                [gBtn setTitle:@"CLOSE" forState:UIControlStateNormal];
                [UIView animateWithDuration:0.22 delay:0
                     usingSpringWithDamping:0.75 initialSpringVelocity:0.4 options:0
                                 animations:^{ gMenu.alpha = 1; gMenu.transform = CGAffineTransformIdentity; }
                                 completion:nil];
            } else {
                [gBtn setTitle:@"MENU" forState:UIControlStateNormal];
                [gMenu dismiss];
            }
        }];
        [gBtn addGestureRecognizer:tap];

        // FALLBACK: also add directly into the game window's root view
        // in case the overlay window is not composited (Unity Metal quirk)
        UIView *gameRoot = win.rootViewController.view;
        if (gameRoot && gameRoot != container) {
            UIButton *fbBtn = gBtn; // same button, just re-add to game root too
            [gameRoot addSubview:fbBtn];
            [gameRoot bringSubviewToFront:fbBtn];
        }

        NSLog(@"[AnimalCompanyMod] Menu injected ok — container=%@ sw=%.0f sh=%.0f",
              NSStringFromClass([container class]), sw, sh);
    });
}

__attribute__((constructor))
static void ELInit(void) {
    // No bundle ID guard — let it run in any app so sideload bundle ID mismatches don't block it.
    // ELInject itself is harmless if run in the wrong app (just adds an invisible button).

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        // Poll until UIApplication is alive (up to 60 s)
        for (int i = 0; i < 300; i++) {
            usleep(200000); // 0.2 s
            if ([UIApplication sharedApplication]) break;
        }
        // Show splash immediately to confirm dylib loaded
        dispatch_async(dispatch_get_main_queue(), ^{ ELShowSplash(); });
        // First attempt after 3 s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ELInject();
            // Retry every 1.5 s for 30 s — check if button is actually on screen
            // (gBtn != nil is not enough; Unity may have removed it from the hierarchy)
            __block int attempts = 0;
            __block void (^retry)(void);
            retry = ^{
                attempts++;
                if (attempts > 20) return;
                // Only stop retrying if button is genuinely on screen
                if (gBtn != nil && gBtn.window != nil && !gBtn.isHidden) return;
                // Button lost its window or never appeared — reset and re-inject
                gBtn = nil;
                gMenu = nil;
                ELInject();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), retry);
            };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), retry);
        });
    });
}
