// mob_nif.m — Mob UI NIF for iOS (SwiftUI, JSON backend).
//
// NIF functions (matches mob_nif.erl):
//   platform/0         — returns :ios
//   log/1, log/2       — NSLog
//   set_transition/1   — stores transition atom for next set_root call
//   set_root/1         — accepts JSON binary, parses to MobNode tree, pushes to MobViewModel
//   register_tap/1     — register pid (or {pid,tag}), returns integer handle
//   clear_taps/0       — clear tap registry before each render

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach/mach_time.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <dlfcn.h>
// dlopen/dlsym are marked unavailable in iOS SDK headers but exist at runtime
// in the iOS Simulator (macOS). Declare prototypes directly to bypass the header
// restriction. On a real device these will be NULL (weak symbols).
#ifndef RTLD_DEFAULT
#define RTLD_DEFAULT ((void *)-2L)
#define RTLD_LAZY    1
#endif
extern void *dlopen(const char *path, int mode)  __attribute__((weak));
extern void *dlsym(void *handle, const char *symbol) __attribute__((weak));
extern char *dlerror(void) __attribute__((weak));
#import <LocalAuthentication/LocalAuthentication.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>
#import <Photos/Photos.h>
#import <PhotosUI/PhotosUI.h>
#import <UserNotifications/UserNotifications.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <string.h>
#include "erl_nif.h"
#import "MobNode.h"
#import "MobApp-Swift.h"

#define LOGI(...) NSLog(@"[MobNIF] " __VA_ARGS__)
#define LOGE(...) NSLog(@"[MobNIF][ERROR] " __VA_ARGS__)

// ── Startup status (declared in mob_beam.h, called from mob_beam.m) ───────────
// Implemented here rather than in mob_beam.m because this file is compiled with
// -I $BUILD_DIR so it can import the Swift-generated MobApp-Swift.h header.

void mob_set_startup_phase(const char* phase) {
    NSLog(@"[MobBeam] startup: %s", phase);
    [MobViewModel.shared setStartupPhase:[NSString stringWithUTF8String:phase]];
}

void mob_set_startup_error(const char* error) {
    NSLog(@"[MobBeam] ERROR: %s", error);
    [MobViewModel.shared setStartupError:[NSString stringWithUTF8String:error]];
}

// ── Tap handle registry ───────────────────────────────────────────────────────
// Cleared before every render. Max 256 tappable elements per frame.

#define MAX_TAP_HANDLES 256

typedef struct {
    ErlNifPid    pid;
    ErlNifEnv*   tag_env;   // persistent env owning tag; NULL when slot is free
    ERL_NIF_TERM tag;
} TapHandle;

static TapHandle    tap_handles[MAX_TAP_HANDLES];
static int          tap_handle_next = 0;
static ErlNifMutex* tap_mutex       = NULL;
static char         g_transition[16] = "none";

// Called from node onTap blocks — routes tap to BEAM via enif_send.
static void mob_send_tap(int handle) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid    pid     = tap_handles[handle].pid;
    ERL_NIF_TERM tag     = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env,
        enif_make_atom(msg_env, "tap"),
        enif_make_copy(msg_env, tag));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

// ── Focus / blur / submit senders ────────────────────────────────────────────
// Called from MobTextField SwiftUI view when focus state changes or return key tapped.

static void mob_send_event(int handle, const char* atom) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid    pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(msg_env,
        enif_make_atom(msg_env, atom),
        enif_make_copy(msg_env, tag));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_focus(int handle)  { mob_send_event(handle, "focus"); }
static void mob_send_blur(int handle)   { mob_send_event(handle, "blur"); }
static void mob_send_submit(int handle) { mob_send_event(handle, "submit"); }

// ── Back gesture sender ───────────────────────────────────────────────────────
// Called from MobHostingController when the left-edge-pan gesture fires.
// Looks up the :mob_screen registered process and sends {:mob, :back}.
// Non-static so Swift can call it via the bridging header.

void mob_handle_back(void) {
    ErlNifEnv* env = enif_alloc_env();
    ErlNifPid pid;
    if (enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        ERL_NIF_TERM msg = enif_make_tuple2(env,
            enif_make_atom(env, "mob"),
            enif_make_atom(env, "back"));
        enif_send(NULL, &pid, env, msg);
    }
    enif_free_env(env);
}

// ── Change senders ────────────────────────────────────────────────────────────
// Called from MobNode onChange blocks when an input widget fires.

static void mob_send_change(int handle, ERL_NIF_TERM value_term) {
    enif_mutex_lock(tap_mutex);
    if (handle < 0 || handle >= tap_handle_next || !tap_handles[handle].tag_env) {
        enif_mutex_unlock(tap_mutex);
        return;
    }
    ErlNifPid    pid = tap_handles[handle].pid;
    ERL_NIF_TERM tag = tap_handles[handle].tag;
    enif_mutex_unlock(tap_mutex);

    ErlNifEnv* msg_env = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(msg_env,
        enif_make_atom(msg_env, "change"),
        enif_make_copy(msg_env, tag),
        enif_make_copy(msg_env, value_term));
    enif_send(NULL, &pid, msg_env, msg);
    enif_free_env(msg_env);
}

static void mob_send_change_str(int handle, const char* utf8) {
    ErlNifEnv* tmp = enif_alloc_env();
    ErlNifBinary bin;
    size_t len = strlen(utf8);
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    ERL_NIF_TERM term = enif_make_binary(tmp, &bin);
    mob_send_change(handle, term);
    enif_free_env(tmp);
}

static void mob_send_change_bool(int handle, int bool_val) {
    ErlNifEnv* tmp = enif_alloc_env();
    ERL_NIF_TERM term = enif_make_atom(tmp, bool_val ? "true" : "false");
    mob_send_change(handle, term);
    enif_free_env(tmp);
}

static void mob_send_change_float(int handle, double value) {
    ErlNifEnv* tmp = enif_alloc_env();
    ERL_NIF_TERM term = enif_make_double(tmp, value);
    mob_send_change(handle, term);
    enif_free_env(tmp);
}

// ── JSON → MobNode parser ─────────────────────────────────────────────────────

static UIColor* color_from_argb(long argb) {
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >>  8) & 0xFF) / 255.0;
    CGFloat b = ((argb >>  0) & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

static MobNode* mob_node_from_dict(NSDictionary* dict) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;

    MobNode* node = [[MobNode alloc] init];

    NSString* type = dict[@"type"];
    if      ([type isEqualToString:@"column"])   node.nodeType = MobNodeTypeColumn;
    else if ([type isEqualToString:@"row"])      node.nodeType = MobNodeTypeRow;
    else if ([type isEqualToString:@"text"] ||
             [type isEqualToString:@"label"])    node.nodeType = MobNodeTypeLabel;
    else if ([type isEqualToString:@"button"])   node.nodeType = MobNodeTypeButton;
    else if ([type isEqualToString:@"scroll"])   node.nodeType = MobNodeTypeScroll;
    else if ([type isEqualToString:@"box"])        node.nodeType = MobNodeTypeBox;
    else if ([type isEqualToString:@"divider"])    node.nodeType = MobNodeTypeDivider;
    else if ([type isEqualToString:@"spacer"])     node.nodeType = MobNodeTypeSpacer;
    else if ([type isEqualToString:@"progress"])   node.nodeType = MobNodeTypeProgress;
    else if ([type isEqualToString:@"text_field"]) node.nodeType = MobNodeTypeTextField;
    else if ([type isEqualToString:@"toggle"])     node.nodeType = MobNodeTypeToggle;
    else if ([type isEqualToString:@"slider"])     node.nodeType = MobNodeTypeSlider;
    else if ([type isEqualToString:@"image"])      node.nodeType = MobNodeTypeImage;
    else if ([type isEqualToString:@"lazy_list"])  node.nodeType = MobNodeTypeLazyList;
    else if ([type isEqualToString:@"tab_bar"])    node.nodeType = MobNodeTypeTabBar;
    else if ([type isEqualToString:@"video"])          node.nodeType = MobNodeTypeVideo;
    else if ([type isEqualToString:@"camera_preview"]) node.nodeType = MobNodeTypeCameraPreview;
    else if ([type isEqualToString:@"webview"])        node.nodeType = MobNodeTypeWebView;

    NSDictionary* props = dict[@"props"];
    if ([props isKindOfClass:[NSDictionary class]]) {
        id text = props[@"text"];
        if (text) node.text = [text isKindOfClass:[NSString class]] ? text : [text description];

        id padding = props[@"padding"];
        if (padding) node.padding = [padding doubleValue];

        id paddingTop = props[@"padding_top"];
        if (paddingTop) node.paddingTop = [paddingTop doubleValue];
        id paddingRight = props[@"padding_right"];
        if (paddingRight) node.paddingRight = [paddingRight doubleValue];
        id paddingBottom = props[@"padding_bottom"];
        if (paddingBottom) node.paddingBottom = [paddingBottom doubleValue];
        id paddingLeft = props[@"padding_left"];
        if (paddingLeft) node.paddingLeft = [paddingLeft doubleValue];

        id textSize = props[@"text_size"];
        if (textSize) node.textSize = [textSize doubleValue];

        id fontFamily = props[@"font"];
        if ([fontFamily isKindOfClass:[NSString class]]) node.fontFamily = fontFamily;
        id fontWeight = props[@"font_weight"];
        if (fontWeight) node.fontWeight = [fontWeight description];
        id textAlign = props[@"text_align"];
        if (textAlign) node.textAlign = [textAlign description];
        id italic = props[@"italic"];
        if (italic) node.italic = [italic boolValue];
        id lineHeight = props[@"line_height"];
        if (lineHeight) node.lineHeight = [lineHeight doubleValue];
        id letterSpacing = props[@"letter_spacing"];
        if (letterSpacing) node.letterSpacing = [letterSpacing doubleValue];

        id tabDefs = props[@"tabs"];
        if ([tabDefs isKindOfClass:[NSArray class]]) node.tabDefs = tabDefs;
        id activeTab = props[@"active"];
        if (activeTab) node.activeTab = [activeTab description];
        id onTabSelect = props[@"on_tab_select"];
        if (onTabSelect && [onTabSelect isKindOfClass:[NSNumber class]]) {
            int handle = [onTabSelect intValue];
            node.onTabSelect = ^(NSString* tabId) {
                mob_send_change_str(handle, [tabId UTF8String]);
            };
        }

        id bg = props[@"background"];
        if (bg) node.backgroundColor = color_from_argb((long)[bg longLongValue]);

        id textColor = props[@"text_color"];
        if (textColor) node.textColor = color_from_argb((long)[textColor longLongValue]);

        id color = props[@"color"];
        if (color) node.color = color_from_argb((long)[color longLongValue]);

        id thickness = props[@"thickness"];
        if (thickness) node.thickness = [thickness doubleValue];

        id fixedSize = props[@"size"];
        if (fixedSize) node.fixedSize = [fixedSize doubleValue];

        id axis = props[@"axis"];
        if ([axis isKindOfClass:[NSString class]]) node.axis = axis;

        id showIndicator = props[@"show_indicator"];
        if (showIndicator) node.showIndicator = [showIndicator boolValue];

        id value = props[@"value"];
        if (value) node.value = [value doubleValue];

        id onTap = props[@"on_tap"];
        if (onTap && [onTap isKindOfClass:[NSNumber class]]) {
            int handle = [onTap intValue];
            node.onTap = ^{ mob_send_tap(handle); };
        }

        id placeholder = props[@"placeholder"];
        if (placeholder) node.placeholder = [placeholder isKindOfClass:[NSString class]] ? placeholder : [placeholder description];

        id keyboardType = props[@"keyboard"];
        if ([keyboardType isKindOfClass:[NSString class]]) node.keyboardTypeStr = keyboardType;

        id returnKey = props[@"return_key"];
        if ([returnKey isKindOfClass:[NSString class]]) node.returnKeyStr = returnKey;

        id onFocus = props[@"on_focus"];
        if (onFocus && [onFocus isKindOfClass:[NSNumber class]]) {
            int handle = [onFocus intValue];
            node.onFocus = ^{ mob_send_focus(handle); };
        }

        id onBlur = props[@"on_blur"];
        if (onBlur && [onBlur isKindOfClass:[NSNumber class]]) {
            int handle = [onBlur intValue];
            node.onBlur = ^{ mob_send_blur(handle); };
        }

        id onSubmit = props[@"on_submit"];
        if (onSubmit && [onSubmit isKindOfClass:[NSNumber class]]) {
            int handle = [onSubmit intValue];
            node.onSubmit = ^{ mob_send_submit(handle); };
        }

        id checked = props[@"value"];
        if (checked && node.nodeType == MobNodeTypeToggle) {
            // value is a boolean atom serialised as "true"/"false"
            node.checked = [[checked description] isEqualToString:@"true"] ||
                           ([checked isKindOfClass:[NSNumber class]] && [checked boolValue]);
        }

        id minVal = props[@"min"];
        if (minVal) node.minValue = [minVal doubleValue];

        id maxVal = props[@"max"];
        if (maxVal) node.maxValue = [maxVal doubleValue];

        id src = props[@"src"];
        if ([src isKindOfClass:[NSString class]]) node.src = src;

        id contentMode = props[@"content_mode"];
        if ([contentMode isKindOfClass:[NSString class]]) node.contentModeStr = contentMode;

        id fixedWidth = props[@"width"];
        if (fixedWidth) node.fixedWidth = [fixedWidth doubleValue];

        id fixedHeight = props[@"height"];
        if (fixedHeight) node.fixedHeight = [fixedHeight doubleValue];

        id cornerRadius = props[@"corner_radius"];
        if (cornerRadius) node.cornerRadius = [cornerRadius doubleValue];

        id fillWidth = props[@"fill_width"];
        if (fillWidth) node.fillWidth = [fillWidth boolValue];

        id placeholderColor = props[@"placeholder_color"];
        if (placeholderColor) node.placeholderColor = color_from_argb((long)[placeholderColor longLongValue]);

        id videoAutoplay = props[@"autoplay"];
        if (videoAutoplay) node.videoAutoplay = [videoAutoplay boolValue];
        id videoLoop = props[@"loop"];
        if (videoLoop) node.videoLoop = [videoLoop boolValue];
        id videoControls = props[@"controls"];
        if (videoControls) node.videoControls = [videoControls boolValue];

        id cameraFacing = props[@"facing"];
        if ([cameraFacing isKindOfClass:[NSString class]]) node.cameraFacing = cameraFacing;

        // webview props
        id webViewUrl = props[@"url"];
        if ([webViewUrl isKindOfClass:[NSString class]]) node.webViewUrl = webViewUrl;
        id webViewAllow = props[@"allow"];
        if ([webViewAllow isKindOfClass:[NSString class]]) node.webViewAllow = webViewAllow;
        id webViewShowUrl = props[@"show_url"];
        if (webViewShowUrl) node.webViewShowUrl = [webViewShowUrl boolValue];
        id webViewTitle = props[@"title"];
        if ([webViewTitle isKindOfClass:[NSString class]]) node.webViewTitle = webViewTitle;

        id onEndReached = props[@"on_end_reached"];
        if (onEndReached && [onEndReached isKindOfClass:[NSNumber class]]) {
            int handle = [onEndReached intValue];
            node.onTap = ^{ mob_send_tap(handle); };
        }

        // For slider, value is the initial position (re-uses node.value property)
        // text_field initial text re-uses node.text property

        id onChange = props[@"on_change"];
        if (onChange && [onChange isKindOfClass:[NSNumber class]]) {
            int handle = [onChange intValue];
            switch (node.nodeType) {
                case MobNodeTypeTextField:
                    node.onChangeStr = ^(NSString* v) { mob_send_change_str(handle, [v UTF8String]); };
                    break;
                case MobNodeTypeToggle:
                    node.onChangeBool = ^(BOOL v) { mob_send_change_bool(handle, (int)v); };
                    break;
                case MobNodeTypeSlider:
                    node.onChangeFloat = ^(double v) { mob_send_change_float(handle, v); };
                    break;
                default:
                    break;
            }
        }

        id accessibilityId = props[@"accessibility_id"];
        if ([accessibilityId isKindOfClass:[NSString class]]) {
            node.accessibilityId = accessibilityId;
        }
    }

    NSArray* children = dict[@"children"];
    if ([children isKindOfClass:[NSArray class]]) {
        for (id child in children) {
            MobNode* childNode = mob_node_from_dict(child);
            if (childNode) [node.children addObject:childNode];
        }
    }

    return node;
}

// ── NIF: exit_app/0 ──────────────────────────────────────────────────────────
// iOS apps don't have a programmatic "exit" convention — the home gesture is
// handled by the OS. This is intentionally a no-op; backgrounding on iOS
// happens naturally when the user swipes up.

static ERL_NIF_TERM nif_exit_app(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "ok");
}

// ── NIF: platform/0 ──────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_platform(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "ios");
}

// ── NIF: safe_area/0 ─────────────────────────────────────────────────────────
// Returns {Top, Right, Bottom, Left} in logical points (not pixels).
// Must read UIWindow.safeAreaInsets on the main thread.

static ERL_NIF_TERM nif_safe_area(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    __block UIEdgeInsets insets = UIEdgeInsetsZero;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIWindow* window = nil;
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene* ws = (UIWindowScene*)scene;
                window = ws.windows.firstObject;
                break;
            }
        }
        if (window) insets = window.safeAreaInsets;
    });
    return enif_make_tuple4(env,
        enif_make_double(env, insets.top),
        enif_make_double(env, insets.right),
        enif_make_double(env, insets.bottom),
        enif_make_double(env, insets.left)
    );
}

// ── NIF: log/1 ────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_log(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char buf[4096] = {0};
    ErlNifBinary bin;
    if (enif_inspect_binary(env, argv[0], &bin)) {
        size_t len = bin.size < sizeof(buf) - 1 ? bin.size : sizeof(buf) - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
    } else if (!enif_get_string(env, argv[0], buf, sizeof(buf), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }
    NSLog(@"[mob] %s", buf);
    return enif_make_atom(env, "ok");
}

// ── NIF: log/2 ────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_log2(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char level[16] = {0};
    char buf[4096] = {0};
    enif_get_atom(env, argv[0], level, sizeof(level), ERL_NIF_LATIN1);
    ErlNifBinary bin;
    if (enif_inspect_binary(env, argv[1], &bin)) {
        size_t len = bin.size < sizeof(buf) - 1 ? bin.size : sizeof(buf) - 1;
        memcpy(buf, bin.data, len);
        buf[len] = 0;
    } else if (!enif_get_string(env, argv[1], buf, sizeof(buf), ERL_NIF_LATIN1)) {
        return enif_make_badarg(env);
    }
    NSLog(@"[%s] %s", level, buf);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_transition/1 ─────────────────────────────────────────────────────

static ERL_NIF_TERM nif_set_transition(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    if (!enif_get_atom(env, argv[0], g_transition, sizeof(g_transition), ERL_NIF_LATIN1)) {
        enif_mutex_unlock(tap_mutex);
        return enif_make_badarg(env);
    }
    enif_mutex_unlock(tap_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: set_root/1 ──────────────────────────────────────────────────────────
// Accepts a JSON binary, parses it to a MobNode tree, and pushes it to the
// SwiftUI view model. Runs on the BEAM thread — MobViewModel dispatches to main.

static ERL_NIF_TERM nif_set_root(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSData* data = [NSData dataWithBytes:bin.data length:bin.size];
    NSError* err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (err || ![json isKindOfClass:[NSDictionary class]]) {
        LOGE(@"set_root: JSON parse error: %@", err);
        return enif_make_atom(env, "error");
    }

    MobNode* node = mob_node_from_dict((NSDictionary*)json);
    if (!node) return enif_make_atom(env, "error");

    // Snapshot and reset the transition
    enif_mutex_lock(tap_mutex);
    char transition[16];
    strncpy(transition, g_transition, sizeof(transition) - 1);
    transition[sizeof(transition) - 1] = 0;
    strncpy(g_transition, "none", sizeof(g_transition));
    enif_mutex_unlock(tap_mutex);

    NSString* transitionStr = [NSString stringWithUTF8String:transition];
    [[MobViewModel shared] setRoot:node transition:transitionStr];

    return enif_make_atom(env, "ok");
}

// ── NIF: register_tap/1 ──────────────────────────────────────────────────────

static ERL_NIF_TERM nif_register_tap(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid    pid;
    ERL_NIF_TERM tag_term;

    if (enif_get_local_pid(env, argv[0], &pid)) {
        tag_term = enif_make_atom(env, "ok");
    } else {
        int arity;
        const ERL_NIF_TERM* elems;
        if (!enif_get_tuple(env, argv[0], &arity, &elems) || arity != 2)
            return enif_make_badarg(env);
        if (!enif_get_local_pid(env, elems[0], &pid))
            return enif_make_badarg(env);
        tag_term = elems[1];
    }

    enif_mutex_lock(tap_mutex);
    if (tap_handle_next >= MAX_TAP_HANDLES) {
        enif_mutex_unlock(tap_mutex);
        return enif_make_badarg(env);
    }
    int handle = tap_handle_next++;
    tap_handles[handle].pid     = pid;
    tap_handles[handle].tag_env = enif_alloc_env();
    tap_handles[handle].tag     = enif_make_copy(tap_handles[handle].tag_env, tag_term);
    enif_mutex_unlock(tap_mutex);

    return enif_make_int(env, handle);
}

// ── NIF: clear_taps/0 ─────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_clear_taps(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    enif_mutex_lock(tap_mutex);
    for (int i = 0; i < tap_handle_next; i++) {
        if (tap_handles[i].tag_env) {
            enif_free_env(tap_handles[i].tag_env);
            tap_handles[i].tag_env = NULL;
        }
    }
    tap_handle_next = 0;
    enif_mutex_unlock(tap_mutex);
    return enif_make_atom(env, "ok");
}

// ── NIF: haptic/1 ─────────────────────────────────────────────────────────────
// Triggers haptic feedback. Fire-and-forget; dispatched async to main thread.

static ERL_NIF_TERM nif_haptic(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char type[32] = {0};
    enif_get_atom(env, argv[0], type, sizeof(type), ERL_NIF_LATIN1);
    NSString* typeStr = [NSString stringWithUTF8String:type];

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([typeStr isEqualToString:@"success"] ||
            [typeStr isEqualToString:@"error"]   ||
            [typeStr isEqualToString:@"warning"]) {
            UINotificationFeedbackGenerator* g = [[UINotificationFeedbackGenerator alloc] init];
            [g prepare];
            if ([typeStr isEqualToString:@"success"])
                [g notificationOccurred:UINotificationFeedbackTypeSuccess];
            else if ([typeStr isEqualToString:@"error"])
                [g notificationOccurred:UINotificationFeedbackTypeError];
            else
                [g notificationOccurred:UINotificationFeedbackTypeWarning];
        } else {
            UIImpactFeedbackStyle style = UIImpactFeedbackStyleMedium;
            if ([typeStr isEqualToString:@"light"])  style = UIImpactFeedbackStyleLight;
            if ([typeStr isEqualToString:@"heavy"])  style = UIImpactFeedbackStyleHeavy;
            UIImpactFeedbackGenerator* g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
            [g prepare];
            [g impactOccurred];
        }
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: clipboard_put/1 ──────────────────────────────────────────────────────
// Writes a UTF-8 binary to the system clipboard. Fire-and-forget.

static ERL_NIF_TERM nif_clipboard_put(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString* text = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIPasteboard generalPasteboard].string = text;
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: clipboard_get/0 ──────────────────────────────────────────────────────
// Returns {:ok, Binary} or :empty. Synchronous (dispatch_sync to main thread).

static ERL_NIF_TERM nif_clipboard_get(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    __block NSString* text = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        text = [UIPasteboard generalPasteboard].string;
    });

    if (text) {
        const char* utf8 = [text UTF8String];
        ErlNifBinary bin;
        size_t len = strlen(utf8);
        enif_alloc_binary(len, &bin);
        memcpy(bin.data, utf8, len);
        ERL_NIF_TERM text_term = enif_make_binary(env, &bin);
        return enif_make_tuple2(env, enif_make_atom(env, "ok"), text_term);
    }
    return enif_make_atom(env, "empty");
}

// ── NIF: share_text/1 ─────────────────────────────────────────────────────────
// Opens the iOS share sheet with plain text. Fire-and-forget.

static ERL_NIF_TERM nif_share_text(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString* text = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                            encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityViewController* vc =
            [[UIActivityViewController alloc] initWithActivityItems:@[text]
                                              applicationActivities:nil];
        UIViewController* root = nil;
        for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                root = ((UIWindowScene*)scene).windows.firstObject.rootViewController;
                break;
            }
        }
        if (root) {
            if (vc.popoverPresentationController) {
                vc.popoverPresentationController.sourceView = root.view;
                CGRect r = root.view.bounds;
                vc.popoverPresentationController.sourceRect =
                    CGRectMake(CGRectGetMidX(r), CGRectGetMidY(r), 0, 0);
            }
            [root presentViewController:vc animated:YES completion:nil];
        }
    });
    return enif_make_atom(env, "ok");
}

// ════════════════════════════════════════════════════════════════════════════
// Device capability NIFs
// ════════════════════════════════════════════════════════════════════════════

// ── Shared helpers ─────────────────────────────────────────────────────────

// Build and send {atom1, atom2} to a pid from any thread.
static void mob_send2(const ErlNifPid* pid, const char* a1, const char* a2) {
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,a1), enif_make_atom(e,a2));
    enif_send(NULL, (ErlNifPid*)pid, e, msg);
    enif_free_env(e);
}

// Return the root view controller of the key window in the first active scene.
static UIViewController* mob_root_vc(void) {
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            UIWindowScene* ws = (UIWindowScene*)scene;
            UIWindow* w = ws.keyWindow ?: ws.windows.firstObject;
            if (w.rootViewController) return w.rootViewController;
        }
    }
    return nil;
}

// ── Launch notification global ─────────────────────────────────────────────
// Written by mob_set_launch_notification_json() (called from app delegate);
// read and cleared by nif_take_launch_notification.
static char* g_launch_notification_json = NULL;
static ErlNifMutex* g_launch_notif_mutex = NULL;

@interface MobNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@property (nonatomic) ErlNifPid screenPid;
@end
static MobNotificationDelegate* g_notif_delegate;

// Called from AppDelegate didRegisterForRemoteNotificationsWithDeviceToken.
// Sends {:push_token, :ios, token_hex_string} to the registered screen process.
void mob_send_push_token(const char* hex_token) {
    if (!g_notif_delegate) return;
    ErlNifPid p = g_notif_delegate.screenPid;
    ErlNifEnv* e = enif_alloc_env();
    size_t len = strlen(hex_token);
    ErlNifBinary tb; enif_alloc_binary(len, &tb); memcpy(tb.data, hex_token, len);
    ERL_NIF_TERM msg = enif_make_tuple3(e,
        enif_make_atom(e,"push_token"),
        enif_make_atom(e,"ios"),
        enif_make_binary(e,&tb));
    enif_send(NULL, &p, e, msg);
    enif_free_env(e);
}

void mob_set_launch_notification_json(const char* json) {
    if (!g_launch_notif_mutex) return;
    enif_mutex_lock(g_launch_notif_mutex);
    free(g_launch_notification_json);
    g_launch_notification_json = json ? strdup(json) : NULL;
    enif_mutex_unlock(g_launch_notif_mutex);
}

static ERL_NIF_TERM nif_take_launch_notification(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (!g_launch_notif_mutex) return enif_make_atom(env, "none");
    enif_mutex_lock(g_launch_notif_mutex);
    char* json = g_launch_notification_json;
    g_launch_notification_json = NULL;
    enif_mutex_unlock(g_launch_notif_mutex);
    if (!json) return enif_make_atom(env, "none");
    ErlNifBinary bin;
    size_t len = strlen(json);
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, json, len);
    free(json);
    return enif_make_binary(env, &bin);
}

// ── Permission request ────────────────────────────────────────────────────

static ERL_NIF_TERM nif_request_permission(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char cap[32];
    if (!enif_get_atom(env, argv[0], cap, sizeof(cap), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    ErlNifPid pid;
    enif_self(env, &pid);

    if (strcmp(cap, "camera") == 0 || strcmp(cap, "microphone") == 0) {
        AVMediaType mtype = strcmp(cap, "camera") == 0
            ? AVMediaTypeVideo : AVMediaTypeAudio;
        NSString* capStr = [NSString stringWithUTF8String:cap];
        [AVCaptureDevice requestAccessForMediaType:mtype completionHandler:^(BOOL granted) {
            mob_send2(&pid, "permission", granted ? "granted" : "denied");
        }];
    } else if (strcmp(cap, "photo_library") == 0) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite
            handler:^(PHAuthorizationStatus status) {
            BOOL ok = (status == PHAuthorizationStatusAuthorized ||
                       status == PHAuthorizationStatusLimited);
            mob_send2(&pid, "permission", ok ? "granted" : "denied");
        }];
    } else if (strcmp(cap, "location") == 0) {
        // Location permission is requested via CLLocationManager when get_once/start are called.
        // Here we just signal granted for iOS (the actual dialog shows at location call time).
        mob_send2(&pid, "permission", "granted");
    } else if (strcmp(cap, "notifications") == 0) {
        UNUserNotificationCenter* center = [UNUserNotificationCenter currentNotificationCenter];
        [center requestAuthorizationWithOptions:
            UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge
            completionHandler:^(BOOL granted, NSError* err) {
            mob_send2(&pid, "permission", granted ? "granted" : "denied");
        }];
    } else {
        return enif_make_badarg(env);
    }
    return enif_make_atom(env, "ok");
}

// ── Biometric authentication ──────────────────────────────────────────────

static ERL_NIF_TERM nif_biometric_authenticate(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString* reason = [[NSString alloc] initWithBytes:bin.data length:bin.size
                                              encoding:NSUTF8StringEncoding];
    ErlNifPid pid; enif_self(env, &pid);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        LAContext* ctx = [[LAContext alloc] init];
        NSError* err = nil;
        if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err]) {
            [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                localizedReason:reason reply:^(BOOL ok, NSError* e) {
                mob_send2(&pid, "biometric", ok ? "success" : "failure");
            }];
        } else {
            mob_send2(&pid, "biometric", "not_available");
        }
    });
    return enif_make_atom(env, "ok");
}

// ── Location ──────────────────────────────────────────────────────────────

@interface MobLocationDelegate : NSObject <CLLocationManagerDelegate>
@property (nonatomic) ErlNifPid pid;
@property (nonatomic) BOOL oneShot;
@end

static MobLocationDelegate* g_location_delegate = nil;
static CLLocationManager*   g_location_manager  = nil;

@implementation MobLocationDelegate
- (void)locationManager:(CLLocationManager*)mgr didUpdateLocations:(NSArray<CLLocation*>*)locs {
    CLLocation* loc = locs.lastObject;
    if (!loc) return;
    ErlNifPid p = self.pid;
    double lat = loc.coordinate.latitude;
    double lon = loc.coordinate.longitude;
    double acc = loc.horizontalAccuracy;
    double alt = loc.altitude;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv* e = enif_alloc_env();
        ERL_NIF_TERM keys[4] = {
            enif_make_atom(e,"lat"), enif_make_atom(e,"lon"),
            enif_make_atom(e,"accuracy"), enif_make_atom(e,"altitude")
        };
        ERL_NIF_TERM vals[4] = {
            enif_make_double(e,lat), enif_make_double(e,lon),
            enif_make_double(e,acc), enif_make_double(e,alt)
        };
        ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 4, &map);
        ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,"location"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    });
    if (self.oneShot) [mgr stopUpdatingLocation];
}
- (void)locationManager:(CLLocationManager*)mgr didFailWithError:(NSError*)err {
    ErlNifPid p = self.pid;
    ErlNifEnv* e = enif_alloc_env();
    ERL_NIF_TERM msg = enif_make_tuple3(e,
        enif_make_atom(e,"location"), enif_make_atom(e,"error"),
        enif_make_atom(e,"unavailable"));
    enif_send(NULL, &p, e, msg);
    enif_free_env(e);
}
@end

static void setup_location_manager(ErlNifPid pid, BOOL oneShot, NSString* accuracy) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_location_manager) {
            g_location_manager = [[CLLocationManager alloc] init];
        }
        g_location_delegate = [[MobLocationDelegate alloc] init];
        g_location_delegate.pid = pid;
        g_location_delegate.oneShot = oneShot;
        g_location_manager.delegate = g_location_delegate;
        if ([accuracy isEqualToString:@"high"]) {
            g_location_manager.desiredAccuracy = kCLLocationAccuracyBest;
        } else if ([accuracy isEqualToString:@"low"]) {
            g_location_manager.desiredAccuracy = kCLLocationAccuracyKilometer;
        } else {
            g_location_manager.desiredAccuracy = kCLLocationAccuracyHundredMeters;
        }
        [g_location_manager requestWhenInUseAuthorization];
        [g_location_manager startUpdatingLocation];
    });
}

static ERL_NIF_TERM nif_location_get_once(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    setup_location_manager(pid, YES, @"balanced");
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_location_start(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char acc[16] = "balanced";
    enif_get_atom(env, argv[0], acc, sizeof(acc), ERL_NIF_LATIN1);
    ErlNifPid pid; enif_self(env, &pid);
    setup_location_manager(pid, NO, [NSString stringWithUTF8String:acc]);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_location_stop(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_location_manager stopUpdatingLocation];
    });
    return enif_make_atom(env, "ok");
}

// ── Camera capture ────────────────────────────────────────────────────────

@interface MobCameraDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic) ErlNifPid pid;
@property (nonatomic) BOOL isVideo;
@end

static MobCameraDelegate* g_camera_delegate = nil;

@implementation MobCameraDelegate
- (void)imagePickerController:(UIImagePickerController*)picker
    didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id>*)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    ErlNifPid p = self.pid;
    BOOL isVid = self.isVideo;
    g_camera_delegate = nil;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv* e = enif_alloc_env();
        ERL_NIF_TERM msg;
        if (!isVid) {
            UIImage* img = info[UIImagePickerControllerOriginalImage];
            NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"mob_photo_%@.jpg", [NSUUID UUID].UUIDString]];
            [UIImageJPEGRepresentation(img, 0.9) writeToFile:tmp atomically:YES];
            const char* path = tmp.UTF8String;
            ErlNifBinary pbin; enif_alloc_binary(strlen(path), &pbin);
            memcpy(pbin.data, path, strlen(path));
            ERL_NIF_TERM keys[3] = {enif_make_atom(e,"path"),enif_make_atom(e,"width"),enif_make_atom(e,"height")};
            ERL_NIF_TERM vals[3] = {enif_make_binary(e,&pbin),
                enif_make_int(e,(int)img.size.width), enif_make_int(e,(int)img.size.height)};
            ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 3, &map);
            msg = enif_make_tuple3(e, enif_make_atom(e,"camera"), enif_make_atom(e,"photo"), map);
        } else {
            NSURL* url = info[UIImagePickerControllerMediaURL];
            NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"mob_video_%@.mp4", [NSUUID UUID].UUIDString]];
            if (url) [[NSFileManager defaultManager] copyItemAtPath:url.path toPath:tmp error:nil];
            const char* path = tmp.UTF8String;
            ErlNifBinary pbin; enif_alloc_binary(strlen(path), &pbin);
            memcpy(pbin.data, path, strlen(path));
            ERL_NIF_TERM keys[2] = {enif_make_atom(e,"path"), enif_make_atom(e,"duration")};
            ERL_NIF_TERM vals[2] = {enif_make_binary(e,&pbin), enif_make_double(e,0.0)};
            ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 2, &map);
            msg = enif_make_tuple3(e, enif_make_atom(e,"camera"), enif_make_atom(e,"video"), map);
        }
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    });
}
- (void)imagePickerControllerDidCancel:(UIImagePickerController*)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    mob_send2(&_pid, "camera", "cancelled");
    g_camera_delegate = nil;
}
@end

static void present_image_picker(ErlNifPid pid, UIImagePickerControllerSourceType src,
                                  UIImagePickerControllerCameraCaptureMode mode) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (![UIImagePickerController isSourceTypeAvailable:src]) {
            mob_send2(&pid, "camera", "not_available");
            return;
        }
        UIImagePickerController* picker = [[UIImagePickerController alloc] init];
        picker.sourceType  = src;
        picker.cameraCaptureMode = mode;
        if (mode == UIImagePickerControllerCameraCaptureModeVideo) {
            picker.mediaTypes = @[UTTypeMovie.identifier];
        }
        g_camera_delegate = [[MobCameraDelegate alloc] init];
        g_camera_delegate.pid    = pid;
        g_camera_delegate.isVideo = (mode == UIImagePickerControllerCameraCaptureModeVideo);
        picker.delegate    = g_camera_delegate;

        [mob_root_vc() presentViewController:picker animated:YES completion:nil];
    });
}

static ERL_NIF_TERM nif_camera_capture_photo(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    present_image_picker(pid, UIImagePickerControllerSourceTypeCamera,
                         UIImagePickerControllerCameraCaptureModePhoto);
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_camera_capture_video(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    int max_sec = 60;
    enif_get_int(env, argv[0], &max_sec);
    present_image_picker(pid, UIImagePickerControllerSourceTypeCamera,
                         UIImagePickerControllerCameraCaptureModeVideo);
    return enif_make_atom(env, "ok");
}

// ── Camera preview ────────────────────────────────────────────────────────

AVCaptureSession* g_preview_session = nil;

static ERL_NIF_TERM nif_camera_start_preview(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    NSString* facing = @"back";
    if (enif_inspect_binary(env, argv[0], &bin) || enif_inspect_iolist_as_binary(env, argv[0], &bin)) {
        NSString* json = [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
        NSDictionary* opts = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:nil];
        if ([opts[@"facing"] isEqualToString:@"front"]) facing = @"front";
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_preview_session) {
            [g_preview_session stopRunning];
            g_preview_session = nil;
        }
        AVCaptureDevicePosition position = [facing isEqualToString:@"front"]
            ? AVCaptureDevicePositionFront
            : AVCaptureDevicePositionBack;
        AVCaptureDevice* device = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                                                     mediaType:AVMediaTypeVideo
                                                                      position:position];
        if (!device) return;
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:nil];
        if (!input) return;
        AVCaptureSession* session = [[AVCaptureSession alloc] init];
        session.sessionPreset = AVCaptureSessionPresetHigh;
        if ([session canAddInput:input]) [session addInput:input];
        [session startRunning];
        g_preview_session = session;
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_camera_stop_preview(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_preview_session stopRunning];
        g_preview_session = nil;
    });
    return enif_make_atom(env, "ok");
}

// ── Photo library picker ──────────────────────────────────────────────────

@interface MobPhotosDelegate : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic) ErlNifPid pid;
@property (nonatomic) int maxItems;
@end

static MobPhotosDelegate* g_photos_delegate = nil;

@implementation MobPhotosDelegate
- (void)picker:(PHPickerViewController*)picker didFinishPicking:(NSArray<PHPickerResult*>*)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        mob_send2(&_pid, "photos", "cancelled");
        g_photos_delegate = nil;
        return;
    }
    ErlNifPid p = self.pid;
    g_photos_delegate = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        dispatch_group_t grp = dispatch_group_create();
        NSMutableArray* items = [NSMutableArray array];
        for (PHPickerResult* result in results) {
            dispatch_group_enter(grp);
            BOOL isVideo = [result.itemProvider hasItemConformingToTypeIdentifier:@"public.movie"];
            NSString* typeId = isVideo ? @"public.movie" : @"public.image";
            [result.itemProvider loadFileRepresentationForTypeIdentifier:typeId
                completionHandler:^(NSURL* url, NSError* err) {
                if (url) {
                    NSString* ext = isVideo ? @"mp4" : @"jpg";
                    NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"mob_pick_%@.%@", [NSUUID UUID].UUIDString, ext]];
                    [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:nil];
                    @synchronized(items) {
                        [items addObject:@{@"path": tmp, @"type": isVideo ? @"video" : @"image"}];
                    }
                }
                dispatch_group_leave(grp);
            }];
        }
        dispatch_group_notify(grp, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            ErlNifEnv* e = enif_alloc_env();
            ERL_NIF_TERM list = enif_make_list(e, 0);
            for (NSDictionary* item in items.reverseObjectEnumerator) {
                const char* path = [item[@"path"] UTF8String];
                const char* type = [item[@"type"] UTF8String];
                ErlNifBinary pbin; enif_alloc_binary(strlen(path), &pbin);
                memcpy(pbin.data, path, strlen(path));
                ERL_NIF_TERM keys[2] = {enif_make_atom(e,"path"), enif_make_atom(e,"type")};
                ERL_NIF_TERM vals[2] = {enif_make_binary(e,&pbin), enif_make_atom(e,type)};
                ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 2, &map);
                list = enif_make_list_cell(e, map, list);
            }
            ERL_NIF_TERM msg = enif_make_tuple3(e,
                enif_make_atom(e,"photos"), enif_make_atom(e,"picked"), list);
            enif_send(NULL, &p, e, msg);
            enif_free_env(e);
        });
    });
}
@end

static ERL_NIF_TERM nif_photos_pick(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int max = 1; enif_get_int(env, argv[0], &max);
    ErlNifPid pid; enif_self(env, &pid);
    dispatch_async(dispatch_get_main_queue(), ^{
        PHPickerConfiguration* cfg = [[PHPickerConfiguration alloc] init];
        cfg.selectionLimit = max;
        PHPickerViewController* vc = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        g_photos_delegate = [[MobPhotosDelegate alloc] init];
        g_photos_delegate.pid      = pid;
        g_photos_delegate.maxItems = max;
        vc.delegate = g_photos_delegate;
        [mob_root_vc() presentViewController:vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── File picker ───────────────────────────────────────────────────────────

@interface MobFilesDelegate : NSObject <UIDocumentPickerDelegate>
@property (nonatomic) ErlNifPid pid;
@end

static MobFilesDelegate* g_files_delegate = nil;

@implementation MobFilesDelegate
- (void)documentPicker:(UIDocumentPickerViewController*)ctrl
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    if (urls.count == 0) { mob_send2(&_pid, "files", "cancelled"); g_files_delegate = nil; return; }
    ErlNifPid p = self.pid;
    g_files_delegate = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv* e = enif_alloc_env();
        ERL_NIF_TERM list = enif_make_list(e, 0);
        for (NSURL* url in urls.reverseObjectEnumerator) {
            [url startAccessingSecurityScopedResource];
            NSString* name = url.lastPathComponent;
            NSString* tmp  = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
            [[NSFileManager defaultManager] copyItemAtURL:url toURL:[NSURL fileURLWithPath:tmp] error:nil];
            [url stopAccessingSecurityScopedResource];
            NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tmp error:nil];
            long long sz = [attrs[NSFileSize] longLongValue];
            const char* path = tmp.UTF8String;
            const char* nm   = name.UTF8String;
            ErlNifBinary pb; enif_alloc_binary(strlen(path), &pb); memcpy(pb.data, path, strlen(path));
            ErlNifBinary nb; enif_alloc_binary(strlen(nm),   &nb); memcpy(nb.data, nm,   strlen(nm));
            ERL_NIF_TERM keys[3] = {enif_make_atom(e,"path"),enif_make_atom(e,"name"),enif_make_atom(e,"size")};
            ERL_NIF_TERM vals[3] = {enif_make_binary(e,&pb),enif_make_binary(e,&nb),enif_make_int64(e,sz)};
            ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 3, &map);
            list = enif_make_list_cell(e, map, list);
        }
        ERL_NIF_TERM msg = enif_make_tuple3(e,
            enif_make_atom(e,"files"), enif_make_atom(e,"picked"), list);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)ctrl {
    mob_send2(&_pid, "files", "cancelled");
    g_files_delegate = nil;
}
@end

static ERL_NIF_TERM nif_files_pick(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIDocumentPickerViewController* vc =
            [[UIDocumentPickerViewController alloc]
                initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
        vc.allowsMultipleSelection = YES;
        g_files_delegate = [[MobFilesDelegate alloc] init];
        g_files_delegate.pid = pid;
        vc.delegate = g_files_delegate;
        [mob_root_vc() presentViewController:vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── Audio recording ───────────────────────────────────────────────────────

static AVAudioRecorder* g_audio_recorder = nil;
static ErlNifPid        g_audio_pid;
static NSString*        g_audio_path     = nil;
static NSDate*          g_audio_start    = nil;

static ERL_NIF_TERM nif_audio_start_recording(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    g_audio_pid = pid;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryRecord error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
        NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"mob_audio_%@.m4a", [NSUUID UUID].UUIDString]];
        g_audio_path  = tmp;
        g_audio_start = [NSDate date];
        NSURL* url = [NSURL fileURLWithPath:tmp];
        NSDictionary* settings = @{
            AVFormatIDKey:          @(kAudioFormatMPEG4AAC),
            AVSampleRateKey:        @44100,
            AVNumberOfChannelsKey:  @1,
            AVEncoderAudioQualityKey: @(AVAudioQualityMedium)
        };
        g_audio_recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:nil];
        [g_audio_recorder record];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_stop_recording(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_audio_recorder) return;
        NSTimeInterval dur = -[g_audio_start timeIntervalSinceNow];
        [g_audio_recorder stop];
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
        NSString* path = g_audio_path;
        g_audio_recorder = nil;
        ErlNifPid p = g_audio_pid;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            ErlNifEnv* e = enif_alloc_env();
            const char* cpath = path.UTF8String;
            ErlNifBinary pb; enif_alloc_binary(strlen(cpath), &pb); memcpy(pb.data, cpath, strlen(cpath));
            ERL_NIF_TERM keys[2] = {enif_make_atom(e,"path"), enif_make_atom(e,"duration")};
            ERL_NIF_TERM vals[2] = {enif_make_binary(e,&pb),  enif_make_double(e,dur)};
            ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 2, &map);
            ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e,"audio"), enif_make_atom(e,"recorded"), map);
            enif_send(NULL, &p, e, msg);
            enif_free_env(e);
        });
    });
    return enif_make_atom(env, "ok");
}

// ── Audio playback ────────────────────────────────────────────────────────

@interface MobAudioPlayerDelegate : NSObject <AVAudioPlayerDelegate>
@end

static AVAudioPlayer* g_audio_player = nil;
static ErlNifPid      g_playback_pid;
static NSString*      g_playback_path = nil;
static MobAudioPlayerDelegate* g_player_delegate = nil;

@implementation MobAudioPlayerDelegate
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer*)player successfully:(BOOL)flag {
    NSString* path = g_playback_path;
    ErlNifPid p = g_playback_pid;
    g_audio_player = nil;
    g_playback_path = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv* e = enif_alloc_env();
        const char* cpath = path.UTF8String;
        ErlNifBinary pb; enif_alloc_binary(strlen(cpath), &pb); memcpy(pb.data, cpath, strlen(cpath));
        ERL_NIF_TERM keys[1] = {enif_make_atom(e, "path")};
        ERL_NIF_TERM vals[1] = {enif_make_binary(e, &pb)};
        ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 1, &map);
        ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "audio"),
                                               enif_make_atom(e, "playback_finished"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    });
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer*)player error:(NSError*)error {
    ErlNifPid p = g_playback_pid;
    NSString* reason = error ? error.localizedDescription : @"decode_error";
    g_audio_player = nil;
    g_playback_path = nil;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ErlNifEnv* e = enif_alloc_env();
        const char* cr = reason.UTF8String;
        ErlNifBinary rb; enif_alloc_binary(strlen(cr), &rb); memcpy(rb.data, cr, strlen(cr));
        ERL_NIF_TERM keys[1] = {enif_make_atom(e, "reason")};
        ERL_NIF_TERM vals[1] = {enif_make_binary(e, &rb)};
        ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 1, &map);
        ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "audio"),
                                               enif_make_atom(e, "playback_error"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    });
}
@end

static ERL_NIF_TERM nif_audio_play(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary path_bin, opts_bin;
    if (!enif_inspect_binary(env, argv[0], &path_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &path_bin)) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &opts_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &opts_bin)) return enif_make_badarg(env);

    NSString* path = [[NSString alloc] initWithBytes:path_bin.data length:path_bin.size encoding:NSUTF8StringEncoding];
    NSString* opts = [[NSString alloc] initWithBytes:opts_bin.data length:opts_bin.size encoding:NSUTF8StringEncoding];

    ErlNifPid pid; enif_self(env, &pid);
    g_playback_pid  = pid;
    g_playback_path = path;

    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary* o = [NSJSONSerialization
            JSONObjectWithData:[opts dataUsingEncoding:NSUTF8StringEncoding]
            options:0 error:nil];
        BOOL loop      = [o[@"loop"]   boolValue];
        double volume  = o[@"volume"] ? [o[@"volume"] doubleValue] : 1.0;

        [g_audio_player stop];
        g_audio_player = nil;

        NSURL* url = [NSURL fileURLWithPath:path];
        NSError* err = nil;
        AVAudioPlayer* player = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
        if (!player || err) {
            NSString* reason = err ? err.localizedDescription : @"open_failed";
            ErlNifPid p = g_playback_pid;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                ErlNifEnv* e = enif_alloc_env();
                const char* cr = reason.UTF8String;
                ErlNifBinary rb; enif_alloc_binary(strlen(cr), &rb); memcpy(rb.data, cr, strlen(cr));
                ERL_NIF_TERM keys[1] = {enif_make_atom(e, "reason")};
                ERL_NIF_TERM vals[1] = {enif_make_binary(e, &rb)};
                ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 1, &map);
                ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e, "audio"),
                                                       enif_make_atom(e, "playback_error"), map);
                enif_send(NULL, &p, e, msg);
                enif_free_env(e);
            });
            return;
        }

        if (!g_player_delegate) g_player_delegate = [[MobAudioPlayerDelegate alloc] init];
        player.delegate      = g_player_delegate;
        player.volume        = (float)volume;
        player.numberOfLoops = loop ? -1 : 0;

        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];

        g_audio_player = player;
        [player play];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_stop_playback(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_audio_player stop];
        g_audio_player  = nil;
        g_playback_path = nil;
        [[AVAudioSession sharedInstance] setActive:NO error:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_audio_set_volume(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    double vol = 1.0;
    enif_get_double(env, argv[0], &vol);
    dispatch_async(dispatch_get_main_queue(), ^{
        g_audio_player.volume = (float)vol;
    });
    return enif_make_atom(env, "ok");
}

// ── Motion sensors ────────────────────────────────────────────────────────

static CMMotionManager* g_motion_manager = nil;
static ErlNifPid        g_motion_pid;

static ERL_NIF_TERM nif_motion_start(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    g_motion_pid = pid;
    int interval_ms = 100;
    // argv[0] is a list of sensor name binaries; argv[1] is interval_ms int
    enif_get_int(env, argv[1], &interval_ms);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_motion_manager) g_motion_manager = [[CMMotionManager alloc] init];
        NSTimeInterval interval = interval_ms / 1000.0;
        g_motion_manager.deviceMotionUpdateInterval = interval;
        [g_motion_manager startDeviceMotionUpdatesToQueue:[NSOperationQueue new]
            withHandler:^(CMDeviceMotion* motion, NSError* err) {
            if (!motion) return;
            ErlNifPid p = g_motion_pid;
            double ax = motion.userAcceleration.x + motion.gravity.x;
            double ay = motion.userAcceleration.y + motion.gravity.y;
            double az = motion.userAcceleration.z + motion.gravity.z;
            double gx = motion.rotationRate.x;
            double gy = motion.rotationRate.y;
            double gz = motion.rotationRate.z;
            ErlNifEnv* e = enif_alloc_env();
            ERL_NIF_TERM accel = enif_make_tuple3(e,
                enif_make_double(e,ax), enif_make_double(e,ay), enif_make_double(e,az));
            ERL_NIF_TERM gyro  = enif_make_tuple3(e,
                enif_make_double(e,gx), enif_make_double(e,gy), enif_make_double(e,gz));
            long long ts = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
            ERL_NIF_TERM keys[3] = {enif_make_atom(e,"accel"),enif_make_atom(e,"gyro"),enif_make_atom(e,"timestamp")};
            ERL_NIF_TERM vals[3] = {accel, gyro, enif_make_int64(e,ts)};
            ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 3, &map);
            ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,"motion"), map);
            enif_send(NULL, &p, e, msg);
            enif_free_env(e);
        }];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_motion_stop(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_motion_manager stopDeviceMotionUpdates];
    });
    return enif_make_atom(env, "ok");
}

// ── QR / barcode scanner ──────────────────────────────────────────────────

@interface MobScannerVC : UIViewController <AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic) ErlNifPid pid;
@property (nonatomic, strong) AVCaptureSession* session;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer* preview;
@end

static MobScannerVC* g_scanner_vc = nil;

@implementation MobScannerVC
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    NSError* err = nil;
    AVCaptureDevice* dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    AVCaptureDeviceInput* inp = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
    if (!inp) { mob_send2(&_pid, "scan", "not_available"); [self dismissViewControllerAnimated:YES completion:nil]; return; }
    self.session = [[AVCaptureSession alloc] init];
    [self.session addInput:inp];
    AVCaptureMetadataOutput* out = [[AVCaptureMetadataOutput alloc] init];
    [self.session addOutput:out];
    [out setMetadataObjectsDelegate:self queue:dispatch_get_main_queue()];
    out.metadataObjectTypes = @[
        AVMetadataObjectTypeQRCode, AVMetadataObjectTypeEAN13Code,
        AVMetadataObjectTypeEAN8Code, AVMetadataObjectTypeCode128Code,
        AVMetadataObjectTypeCode39Code, AVMetadataObjectTypeAztecCode,
        AVMetadataObjectTypePDF417Code, AVMetadataObjectTypeDataMatrixCode
    ];
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.preview.frame = self.view.bounds;
    [self.view.layer addSublayer:self.preview];
    // Cancel button
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"Cancel" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.frame = CGRectMake(16, 60, 80, 44);
    [btn addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:btn];
    [self.session startRunning];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.preview.frame = self.view.bounds;
}
- (void)cancel {
    [self.session stopRunning];
    mob_send2(&_pid, "scan", "cancelled");
    [self dismissViewControllerAnimated:YES completion:nil];
    g_scanner_vc = nil;
}
- (void)captureOutput:(AVCaptureOutput*)out
    didOutputMetadataObjects:(NSArray<__kindof AVMetadataObject*>*)metas
    fromConnection:(AVCaptureConnection*)conn {
    AVMetadataMachineReadableCodeObject* code = metas.firstObject;
    if (!code || !code.stringValue) return;
    [self.session stopRunning];
    NSString* val = code.stringValue;
    NSString* typ = @"qr";
    if ([code.type isEqualToString:AVMetadataObjectTypeEAN13Code]) typ = @"ean13";
    else if ([code.type isEqualToString:AVMetadataObjectTypeEAN8Code]) typ = @"ean8";
    else if ([code.type isEqualToString:AVMetadataObjectTypeCode128Code]) typ = @"code128";
    else if ([code.type isEqualToString:AVMetadataObjectTypeCode39Code]) typ = @"code39";
    ErlNifPid p = self.pid;
    g_scanner_vc = nil;
    [self dismissViewControllerAnimated:YES completion:^{
        ErlNifEnv* e = enif_alloc_env();
        const char* cval = val.UTF8String;
        const char* ctyp = typ.UTF8String;
        ErlNifBinary vb; enif_alloc_binary(strlen(cval), &vb); memcpy(vb.data, cval, strlen(cval));
        ERL_NIF_TERM keys[2] = {enif_make_atom(e,"type"), enif_make_atom(e,"value")};
        ERL_NIF_TERM vals[2] = {enif_make_atom(e,ctyp),  enif_make_binary(e,&vb)};
        ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 2, &map);
        ERL_NIF_TERM msg = enif_make_tuple3(e, enif_make_atom(e,"scan"), enif_make_atom(e,"result"), map);
        enif_send(NULL, &p, e, msg);
        enif_free_env(e);
    }];
}
@end

static ERL_NIF_TERM nif_scanner_scan(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    dispatch_async(dispatch_get_main_queue(), ^{
        g_scanner_vc = [[MobScannerVC alloc] init];
        g_scanner_vc.pid = pid;
        g_scanner_vc.modalPresentationStyle = UIModalPresentationFullScreen;
        [mob_root_vc() presentViewController:g_scanner_vc animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── Notifications ─────────────────────────────────────────────────────────

@implementation MobNotificationDelegate
// Foreground delivery
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    willPresentNotification:(UNNotification*)notification
    withCompletionHandler:(void(^)(UNNotificationPresentationOptions))handler {
    handler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
    [self deliverNotification:notification.request.content
                       source:@"local" id:notification.request.identifier];
}
// Tap on notification (foreground or background)
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
    didReceiveNotificationResponse:(UNNotificationResponse*)response
    withCompletionHandler:(void(^)(void))handler {
    [self deliverNotification:response.notification.request.content
                       source:@"local" id:response.notification.request.identifier];
    handler();
}
- (void)deliverNotification:(UNNotificationContent*)content source:(NSString*)src id:(NSString*)nid {
    ErlNifPid p = self.screenPid;
    ErlNifEnv* e = enif_alloc_env();
    // Build data map from userInfo
    ERL_NIF_TERM data_map = enif_make_new_map(e);
    NSDictionary* ui = content.userInfo;
    for (NSString* key in ui) {
        id val = ui[key];
        const char* ck = key.UTF8String;
        ERL_NIF_TERM kterm = enif_make_atom(e, ck);
        ERL_NIF_TERM vterm;
        if ([val isKindOfClass:[NSString class]]) {
            const char* cv = [val UTF8String];
            ErlNifBinary b; enif_alloc_binary(strlen(cv), &b); memcpy(b.data, cv, strlen(cv));
            vterm = enif_make_binary(e, &b);
        } else if ([val isKindOfClass:[NSNumber class]]) {
            vterm = enif_make_int64(e, [val longLongValue]);
        } else {
            vterm = enif_make_atom(e, "nil");
        }
        enif_make_map_put(e, data_map, kterm, vterm, &data_map);
    }
    const char* cid  = nid.UTF8String;
    const char* csrc = src.UTF8String;
    ErlNifBinary ib; enif_alloc_binary(strlen(cid),  &ib); memcpy(ib.data, cid,  strlen(cid));
    ERL_NIF_TERM keys[3] = {enif_make_atom(e,"id"),enif_make_atom(e,"source"),enif_make_atom(e,"data")};
    ERL_NIF_TERM vals[3] = {enif_make_binary(e,&ib),enif_make_atom(e,csrc),data_map};
    ERL_NIF_TERM map; enif_make_map_from_arrays(e, keys, vals, 3, &map);
    ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e,"notification"), map);
    enif_send(NULL, &p, e, msg);
    enif_free_env(e);
}
@end

static ERL_NIF_TERM nif_notify_schedule(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    ErlNifPid pid; enif_self(env, &pid);

    // Copy JSON to heap-allocated buffer for use in async block
    char* json = (char*)malloc(bin.size + 1);
    memcpy(json, bin.data, bin.size);
    json[bin.size] = 0;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Set delegate once
        if (!g_notif_delegate) {
            g_notif_delegate = [[MobNotificationDelegate alloc] init];
            g_notif_delegate.screenPid = pid;
            [UNUserNotificationCenter currentNotificationCenter].delegate = g_notif_delegate;
        }
        g_notif_delegate.screenPid = pid;

        NSData* data = [NSData dataWithBytes:json length:strlen(json)];
        free(json);
        NSDictionary* opts = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (!opts) return;

        UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
        content.title = opts[@"title"] ?: @"";
        content.body  = opts[@"body"]  ?: @"";
        NSDictionary* dataMap = opts[@"data"];
        if ([dataMap isKindOfClass:[NSDictionary class]]) content.userInfo = dataMap;
        content.sound = [UNNotificationSound defaultSound];

        NSTimeInterval delay = [opts[@"trigger_at"] doubleValue] - [[NSDate date] timeIntervalSince1970];
        if (delay < 1) delay = 1;
        UNTimeIntervalNotificationTrigger* trigger =
            [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay repeats:NO];
        NSString* nid = opts[@"id"] ?: [[NSUUID UUID] UUIDString];
        UNNotificationRequest* req = [UNNotificationRequest requestWithIdentifier:nid
                                                                          content:content
                                                                          trigger:trigger];
        [[UNUserNotificationCenter currentNotificationCenter]
            addNotificationRequest:req withCompletionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_notify_cancel(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString* nid = [[NSString alloc] initWithBytes:bin.data length:bin.size
                                           encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UNUserNotificationCenter currentNotificationCenter]
            removePendingNotificationRequestsWithIdentifiers:@[nid]];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_notify_register_push(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid; enif_self(env, &pid);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_notif_delegate) {
            g_notif_delegate = [[MobNotificationDelegate alloc] init];
            [UNUserNotificationCenter currentNotificationCenter].delegate = g_notif_delegate;
        }
        g_notif_delegate.screenPid = pid;
        [[UIApplication sharedApplication] registerForRemoteNotifications];
        // Token is delivered via AppDelegate didRegisterForRemoteNotificationsWithDeviceToken.
        // Add a call to mob_send_push_token(token) there — see README for setup.
    });
    return enif_make_atom(env, "ok");
}


// ── Test harness helpers (a11y walk, nsstring_to_term, AX framework) ───────────
static ERL_NIF_TERM nsstring_to_term(ErlNifEnv *env, NSString *s) {
    if (!s) return enif_make_atom(env, "nil");
    const char *utf8 = [s UTF8String];
    if (!utf8) return enif_make_atom(env, "nil");
    size_t len = strlen(utf8);
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    return enif_make_binary(env, &bin);
}

static void walk_a11y(ErlNifEnv *env, id obj, ERL_NIF_TERM *list, int depth) {
    if (!obj || depth > 30) return;

    // Collect leaf accessibility elements (visible, interactive, or labelled nodes)
    BOOL isElem = [obj respondsToSelector:@selector(isAccessibilityElement)] &&
                  [(id)obj isAccessibilityElement];
    if (isElem) {
        NSString *label  = [obj respondsToSelector:@selector(accessibilityLabel)]
                         ? [(id)obj accessibilityLabel] : nil;
        NSString *value  = [obj respondsToSelector:@selector(accessibilityValue)]
                         ? [(id)obj accessibilityValue] : nil;
        UIAccessibilityTraits traits = [obj respondsToSelector:@selector(accessibilityTraits)]
                         ? [(id)obj accessibilityTraits] : 0;
        CGRect frame     = [obj respondsToSelector:@selector(accessibilityFrame)]
                         ? [(id)obj accessibilityFrame] : CGRectZero;

        const char *type_str = "element";
        if      (traits & UIAccessibilityTraitButton)     type_str = "button";
        else if (traits & UIAccessibilityTraitStaticText) type_str = "text";
        else if (traits & UIAccessibilityTraitImage)      type_str = "image";
        else if (traits & UIAccessibilityTraitHeader)     type_str = "header";
        else if (traits & UIAccessibilityTraitSearchField) type_str = "text_field";

        ERL_NIF_TERM frame_tup = enif_make_tuple4(env,
            enif_make_double(env, frame.origin.x),
            enif_make_double(env, frame.origin.y),
            enif_make_double(env, frame.size.width),
            enif_make_double(env, frame.size.height));

        ERL_NIF_TERM elem = enif_make_tuple4(env,
            enif_make_atom(env, type_str),
            nsstring_to_term(env, label),
            nsstring_to_term(env, value),
            frame_tup);

        *list = enif_make_list_cell(env, elem, *list);
    }

    // Walk children via exactly one path to avoid duplicates.
    // Prefer accessibilityElements array, fall back to count/index, then UIView subviews.
    BOOL walked = NO;

    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj) walk_a11y(env, child, list, depth + 1);
            }
            walked = YES;
        }
    }

    if (!walked && [obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj) walk_a11y(env, child, list, depth + 1);
            }
            walked = YES;
        }
    }

    if (!walked && [obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            walk_a11y(env, sub, list, depth + 1);
        }
    }
}

// ── NIF: ui_debug/0 — diagnostic: dumps window/view/a11y structure to NSLog ──
static void debug_walk(id obj, int depth) {
    if (!obj || depth > 8) return;
    NSString *indent = [@"" stringByPaddingToLength:depth*2 withString:@"  " startingAtIndex:0];
    NSString *cls = NSStringFromClass([obj class]);
    NSString *label = [obj respondsToSelector:@selector(accessibilityLabel)] ? [obj accessibilityLabel] : @"-";
    NSString *value = [obj respondsToSelector:@selector(accessibilityValue)] ? [obj accessibilityValue] : @"-";
    BOOL isElem    = [obj respondsToSelector:@selector(isAccessibilityElement)] && [obj isAccessibilityElement];
    NSInteger a11yCount = [obj respondsToSelector:@selector(accessibilityElementCount)] ? [obj accessibilityElementCount] : -99;
    NSArray *a11yArr    = [obj respondsToSelector:@selector(accessibilityElements)] ? [obj accessibilityElements] : nil;
    NSInteger subCount  = [obj isKindOfClass:[UIView class]] ? [(UIView*)obj subviews].count : -1;
    NSLog(@"[ui_debug]%@%@ isElem=%d a11yCount=%ld a11yArr=%ld subs=%ld label=%@ value=%@",
          indent, cls, isElem, (long)a11yCount, (long)a11yArr.count, (long)subCount, label, value);
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger cnt = [obj accessibilityElementCount];
        if (cnt != NSNotFound && cnt > 0) {
            for (NSInteger i = 0; i < cnt; i++) debug_walk([obj accessibilityElementAtIndex:i], depth+1);
        }
    }
    for (id child in [obj respondsToSelector:@selector(accessibilityElements)] ? [obj accessibilityElements] : @[])
        debug_walk(child, depth+1);
    if ([obj isKindOfClass:[UIView class]])
        for (UIView *sub in [(UIView*)obj subviews]) debug_walk(sub, depth+1);
}

// Walk macOS AXUIElement tree (works because the iOS Simulator IS a macOS process).
// We load ApplicationServices from the Mac host path (not the simulator runtime root).
typedef void *AXUIElementRef_t;
typedef int   AXError_t;
typedef void *(*AXUIElementCreateApplicationFn)(pid_t pid);
typedef AXError_t (*AXUIElementCopyAttributeValueFn)(AXUIElementRef_t elem, void *attr, void **value);
typedef AXError_t (*AXUIElementCopyAttributeNamesFn)(AXUIElementRef_t elem, void **names);
typedef Boolean (*AXIsProcessTrustedFn)(void);
static void *g_AppSvc = NULL;
static AXUIElementCreateApplicationFn    g_AXCreateApp  = NULL;
static AXUIElementCopyAttributeValueFn   g_AXCopyAttr   = NULL;
static AXIsProcessTrustedFn              g_AXIsTrusted  = NULL;

static NSString *g_ax_load_error = nil;
static void load_ax(void) {
    if (g_AppSvc) return;
    // The iOS Simulator is a macOS process. Check if AX symbols are already available
    // in the process image (RTLD_DEFAULT searches all loaded libraries).
    if (dlsym) {
        void *fn = dlsym(RTLD_DEFAULT, "AXUIElementCreateApplication");
        if (fn) {
            g_AppSvc = RTLD_DEFAULT;  // sentinel: symbols are available
        } else {
            const char *err = dlerror ? dlerror() : "no dlerror";
            g_ax_load_error = [NSString stringWithFormat:@"RTLD_DEFAULT AXUIElementCreateApplication: %s", err];
        }
    }
    if (!g_AppSvc) return;
    g_AXCreateApp = (AXUIElementCreateApplicationFn) dlsym(g_AppSvc, "AXUIElementCreateApplication");
    g_AXCopyAttr  = (AXUIElementCopyAttributeValueFn)dlsym(g_AppSvc, "AXUIElementCopyAttributeValue");
    g_AXIsTrusted = (AXIsProcessTrustedFn)           dlsym(g_AppSvc, "AXIsProcessTrusted");
}

static void ax_walk(void *elem, ErlNifEnv *env, ERL_NIF_TERM *list, int depth) {
    if (!elem || depth > 20) return;
    // role
    void *role = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXRole"), &role);
    // label
    void *label = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXLabel"), &label);
    // value
    void *value = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXValue"), &value);
    // frame via AXFrame (CFDictionaryRef with x/y/w/h)
    void *frameVal = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXFrame"), &frameVal);

    // Only emit if we have a role (leaf or intermediate)
    if (role) {
        // CF types loaded via dlopen — bridge via CFStringRef intermediate (no ARC transfer)
        NSString *roleStr  = (__bridge NSString *)((CFStringRef)role);
        NSString *labelStr = label ? (__bridge NSString *)((CFStringRef)label) : @"";
        NSString *valueStr = value ? (__bridge NSString *)((CFStringRef)value) : @"";
        CGRect frame = CGRectZero;
        if (frameVal) {
            // AXFrame value is an AXValue (AXValueType kAXValueCGRectType == 3)
            typedef Boolean (*AXValueGetValueFn)(CFTypeRef axval, int type, void *out);
            AXValueGetValueFn axGetVal = (AXValueGetValueFn)dlsym(g_AppSvc, "AXValueGetValue");
            if (axGetVal) axGetVal((CFTypeRef)frameVal, 3, &frame);
            CFRelease((CFTypeRef)frameVal);
        }
        ERL_NIF_TERM frame_tup = enif_make_tuple4(env,
            enif_make_double(env, frame.origin.x),
            enif_make_double(env, frame.origin.y),
            enif_make_double(env, frame.size.width),
            enif_make_double(env, frame.size.height));
        ERL_NIF_TERM elem_tup = enif_make_tuple4(env,
            nsstring_to_term(env, roleStr),
            nsstring_to_term(env, labelStr),
            nsstring_to_term(env, valueStr),
            frame_tup);
        *list = enif_make_list_cell(env, elem_tup, *list);
        if (role)  CFRelease((CFTypeRef)role);
        if (label) CFRelease((CFTypeRef)label);
        if (value) CFRelease((CFTypeRef)value);
    }
    // recurse into children
    void *children = NULL;
    g_AXCopyAttr(elem, (void *)CFSTR("AXChildren"), &children);
    if (children) {
        CFIndex count = CFArrayGetCount((CFArrayRef)children);
        for (CFIndex i = 0; i < count; i++) {
            void *child = (void *)CFArrayGetValueAtIndex((CFArrayRef)children, i);
            ax_walk(child, env, list, depth + 1);
        }
        CFRelease((CFTypeRef)children);
    }
}



// ── Test harness (ui_tree, tap, tap_xy, type_text, swipe_xy, etc.) ─────────────
static ERL_NIF_TERM nif_ui_debug(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    load_ax();

    __block ERL_NIF_TERM result = enif_make_list(env, 0);
    // Probe via macOS AXUIElement — runs on NIF thread, no main-queue needed.
    Boolean trusted = g_AXIsTrusted ? g_AXIsTrusted() : NO;
    ERL_NIF_TERM trusted_t = enif_make_atom(env, trusted ? "trusted" : "not_trusted");
    ERL_NIF_TERM appsvc_t  = enif_make_atom(env, g_AppSvc ? "loaded" : "not_loaded");
    result = enif_make_list_cell(env, enif_make_tuple2(env,
        enif_make_atom(env, "ax_status"),
        enif_make_tuple2(env, appsvc_t, trusted_t)), result);
    if (g_ax_load_error) {
        result = enif_make_list_cell(env, nsstring_to_term(env, g_ax_load_error), result);
    }

    if (g_AXCreateApp && g_AXCopyAttr && trusted) {
        void *appElem = g_AXCreateApp(getpid());
        if (appElem) {
            ax_walk(appElem, env, &result, 0);
            CFRelease((CFTypeRef)appElem);
        }
    }

    ERL_NIF_TERM reversed;
    enif_make_reverse_list(env, result, &reversed);
    return reversed;
}


// ensure_a11y_enabled: no-op in the NIF itself.
// Accessibility must be activated from the Mac side before calling ui_tree():
//   xcrun simctl spawn <udid> defaults write com.apple.Accessibility VoiceOverTouchEnabled -bool YES
//   xcrun simctl spawn <udid> notifyutil -p com.apple.accessibility.voiceover.status.changed
// pegleg_dev's `mix mob.connect` will do this automatically.
static void ensure_a11y_enabled(void) { }

static ERL_NIF_TERM nif_ui_tree(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block ERL_NIF_TERM list = enif_make_list(env, 0);
    dispatch_sync(dispatch_get_main_queue(), ^{
        ensure_a11y_enabled();
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                if (window.isHidden) continue;
                walk_a11y(env, window, &list, 0);
            }
        }
    });
    ERL_NIF_TERM reversed;
    enif_make_reverse_list(env, list, &reversed);
    return reversed;
}

// ─── tap/1 — activate element by accessibility label (PUBLIC API) ─────────────
//
// Walks the same a11y tree as ui_tree() and calls -accessibilityActivate on the
// first element whose accessibilityLabel matches the given binary string.
//
// -accessibilityActivate is fully public (UIAccessibilityAction protocol, iOS 4+).
// For SwiftUI buttons it fires the button's action. The app cannot tell this from
// a real tap, though it bypasses the touch event system entirely (no gesture
// recognizer involvement, no UITouch objects).
//
// Use this for Phase 2 (driving apps from tests). For interactions that require
// real UITouch events (custom gesture recognizers, scroll view momentum, etc.)
// use tap_xy/2 instead.

// Returns the deepest accessibility element whose frame contains 'pt'.
// Walks children depth-first (deepest/most-specific match wins).
static id find_a11y_at_point(id obj, CGPoint pt, int depth) {
    if (!obj || depth > 30) return nil;

    // Recurse into children first (deepest match wins)
    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj) {
                    id found = find_a11y_at_point(child, pt, depth + 1);
                    if (found) return found;
                }
            }
            goto check_self;
        }
    }
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj) {
                    id found = find_a11y_at_point(child, pt, depth + 1);
                    if (found) return found;
                }
            }
            goto check_self;
        }
    }
    if ([obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            id found = find_a11y_at_point(sub, pt, depth + 1);
            if (found) return found;
        }
    }

check_self:
    if ([obj respondsToSelector:@selector(isAccessibilityElement)] &&
        [(id)obj isAccessibilityElement] &&
        [obj respondsToSelector:@selector(accessibilityFrame)]) {
        CGRect frame = [(id)obj accessibilityFrame];
        if (CGRectContainsPoint(frame, pt)) return obj;
    }
    return nil;
}

static id find_a11y_by_label(id obj, NSString *target, int depth) {
    if (!obj || depth > 30) return nil;

    if ([obj respondsToSelector:@selector(isAccessibilityElement)] &&
        [(id)obj isAccessibilityElement]) {
        NSString *lbl = [obj respondsToSelector:@selector(accessibilityLabel)]
                      ? [(id)obj accessibilityLabel] : nil;
        if ([lbl isEqualToString:target]) return obj;
    }

    // Walk children via the same single-path logic as walk_a11y() to avoid duplicates.
    if ([obj respondsToSelector:@selector(accessibilityElements)]) {
        NSArray *elems = [(id)obj accessibilityElements];
        if (elems.count > 0) {
            for (id child in elems) {
                if (child && child != obj) {
                    id found = find_a11y_by_label(child, target, depth + 1);
                    if (found) return found;
                }
            }
            return nil;
        }
    }
    if ([obj respondsToSelector:@selector(accessibilityElementCount)]) {
        NSInteger count = [(id)obj accessibilityElementCount];
        if (count != NSNotFound && count > 0) {
            for (NSInteger i = 0; i < count; i++) {
                id child = [(id)obj accessibilityElementAtIndex:i];
                if (child && child != obj) {
                    id found = find_a11y_by_label(child, target, depth + 1);
                    if (found) return found;
                }
            }
            return nil;
        }
    }
    if ([obj isKindOfClass:[UIView class]]) {
        for (UIView *sub in [(UIView *)obj subviews]) {
            id found = find_a11y_by_label(sub, target, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static ERL_NIF_TERM nif_tap(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Accept Elixir binary strings (the normal case)
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin)) return enif_make_badarg(env);
    NSString *label = [[NSString alloc] initWithBytes:bin.data
                                               length:bin.size
                                             encoding:NSUTF8StringEncoding];
    if (!label) return enif_make_badarg(env);

    __block BOOL activated = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in [(UIWindowScene *)scene windows]) {
                if (window.isHidden) continue;
                id elem = find_a11y_by_label(window, label, 0);
                if (elem) {
                    [elem accessibilityActivate];
                    activated = YES;
                    return;
                }
            }
        }
    });

    if (activated) return enif_make_atom(env, "ok");
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "not_found"));
}


// ─── tap_xy/2 — Phase 3: real UITouch injection at screen coordinates ─────────
//
// Synthesises genuine UITouch/UIEvent objects and delivers them through UIKit's
// full event dispatch pipeline:
//
//   UIWindow.sendEvent: → UIGestureRecognizer → UIResponder.touchesBegan/Ended
//
// The app sees these as indistinguishable from a real finger. Scroll view
// momentum, custom gesture recognizers, drag & drop — all work.
//
// ⚠️  PRIVATE API throughout — read before modifying ⚠️
//
// Private interfaces declared via categories below. Using categories (not
// performSelector:) gives the compiler type information and avoids ARC leaks.
//
// BREAKAGE SIGNALS AND FALLBACKS (most → least likely):
//
//   _setLocationInWindow:resetPrevious: renamed:
//     Try _setLocationInWindow: (no resetPrevious), or KVC:
//     [touch setValue:[NSValue valueWithCGPoint:pt] forKey:@"locationInWindow"]
//
//   _setPhase: renamed:
//     Try KVC: [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"]
//     The backing ivar has been "_phase" since iOS 8.
//
//   _setView: / _setWindow: renamed:
//     Try KVC with keys @"view" and @"window" — UITouch KVC has been stable.
//
//   _touchesEvent not found on UIApplication:
//     Try [UIEvent eventWithType:UIEventTypeTouches subtype:0 timestamp:ts]
//     or [[UIApplication sharedApplication] _makeTouchEvent]
//
//   _clearTouches / _addTouch:forDelayedDelivery: renamed:
//     Try [event _removeAllTouches] or building a fresh UIEvent each time.
//
//   Everything above breaks at once:
//     Fall back to the IOHIDEvent path (works on real device, not simulator):
//     dlopen IOKit → IOHIDEventCreateDigitizerFingerEvent →
//     [UIApplication.sharedApplication _handleHIDEvent:event] via objc_msgSend.
//     Coordinates may need scaling by [UIScreen mainScreen].scale on device.
//
// COORDINATES: UIKit screen points, same space as ui_tree() frames.
//   Centre of a frame: tap_xy(x + w/2, y + h/2).

// ── Private category declarations ─────────────────────────────────────────────
// iOS 26 promoted many UITouch setters to public API. The remaining private
// pieces are declared here so the compiler has type information.
//
// iOS 26 availability notes (from runtime enumeration 2026-04-21):
//   PUBLIC (no underscore):  setWindow:  setView:  setPhase:  setTimestamp:  setTapCount:
//   STILL PRIVATE:           _setLocationInWindow:resetPrevious:
//   NEW (UIEvent):           _initWithEvent:touches:  (replaces _clearTouches + _addTouch:)
//   GONE (UITouch):          _setWindow: _setView: _setPhase: _setTimestamp: _setTapCount:
//   GONE (UIEvent):          _clearTouches  _addTouch:forDelayedDelivery:
//
// On older iOS (< 26), the _-prefixed versions are used and the public ones
// may not exist — both paths are guarded with respondsToSelector:.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

@interface UIApplication (MobPhase3)
// iOS <26 only (still present on iOS 26 but unused in the new path)
- (UIEvent *)_touchesEvent;
@end

@interface UIEvent (MobPhase3)
// iOS <26 path — touch management on a shared UIEvent
- (void)_clearTouches;
- (void)_addTouch:(UITouch *)touch forDelayedDelivery:(BOOL)delayed;
// iOS 26+ — create bare event backed by IOHIDEvent
- (instancetype)_init;
- (void)_setHIDEvent:(CFTypeRef)hidEvent;  // back UIEvent with IOHIDEventRef
@end

@interface UITouch (MobPhase3)
// Private on all iOS versions
- (void)_setLocationInWindow:(CGPoint)pt resetPrevious:(BOOL)reset;
- (void)_setHidEvent:(CFTypeRef)hidEvent;   // per-touch HID backing (lowercase 'id')
// Private on iOS < 26, GONE on iOS 26 (replaced by public setters below)
- (void)_setWindow:(UIWindow *)window;
- (void)_setView:(UIView *)view;
- (void)_setPhase:(UITouchPhase)phase;
- (void)_setTimestamp:(NSTimeInterval)ts;
- (void)_setTapCount:(NSUInteger)n;
// iOS 26+ public setters (exist at runtime, not yet in UITouch.h SDK headers)
- (void)setPhase:(UITouchPhase)phase;
- (void)setTimestamp:(NSTimeInterval)ts;
- (void)setTapCount:(NSUInteger)n;
@end

#pragma clang diagnostic pop

// Preserved UITouch from Began phase — reused for Ended/Cancelled so that
// the touch object's pointer identity remains stable across phases.
static UITouch * __strong   sSavedTouch = nil;

// IOHIDEventCreateDigitizerFingerEvent — resolved once via dlsym.
typedef CFTypeRef IOHIDEventRef_t;
typedef IOHIDEventRef_t (*IOHIDCreateFingerFn)(
    CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t,
    double, double, double, double, double, bool, bool, uint32_t
);
static IOHIDCreateFingerFn sIOHIDCreateFinger;
static dispatch_once_t     sIOHIDOnce;

// ── Core touch-phase helper ────────────────────────────────────────────────────
// Delivers one touch phase to UIKit.
//
// iOS 26+ path: IOHIDDigitizerFingerEvent → UIApplication._handleHIDEvent:
//   UIKit creates UITouch/UIEvent internally from the HID event. This path is
//   indistinguishable from a real touch because it enters UIKit at the same
//   level as hardware-generated events.
//
// iOS <26 path: manual UITouch + UIEvent construction via private setters,
//   then [UIWindow sendEvent:].
//
// Returns NO if the required APIs are missing on this iOS version.
static BOOL mob_send_touch_phase(UIWindow *window, UIView *hitView,
                                    CGPoint pt, UITouchPhase phase) {
    // ── iOS 26+ path: pure IOHIDEvent → _handleHIDEvent: ─────────────────────────
    // Let UIKit create UITouch and dispatch through its full pipeline.
    // Both Began and Ended go through _handleHIDEvent: — no manual UITouch injection,
    // no [window sendEvent:].  UIKit routes based on the window's contextId.
    {
        dispatch_once(&sIOHIDOnce, ^{
            sIOHIDCreateFinger =
                dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent");
        });

        SEL handleSel = NSSelectorFromString(@"_handleHIDEvent:");
        UIApplication *app = [UIApplication sharedApplication];

        if (!sIOHIDCreateFinger || ![app respondsToSelector:handleSel]) {
            LOGE(@"tap_xy: IOHIDCreateFinger=%p handleHIDEvent=%d",
                 (void *)sIOHIDCreateFinger, (int)[app respondsToSelector:handleSel]);
            return NO;
        }

        CGSize screen = [UIScreen mainScreen].bounds.size;
        double normX  = pt.x / screen.width;
        double normY  = pt.y / screen.height;
        uint64_t ts   = mach_absolute_time();

        // fingerDown=YES for Began/Moved, NO for Ended/Cancelled
        BOOL fingerDown = (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved);

        IOHIDEventRef_t hidEvent = sIOHIDCreateFinger(
            kCFAllocatorDefault, ts,
            0u,             // fingerIndex
            1u,             // identity
            1u | 2u | 4u,  // eventMask: Range | Touch | Position
            normX, normY, 0.0,
            fingerDown ? 1.0 : 0.0,  // tipPressure: 1.0 down, 0.0 up
            0.0,
            (bool)fingerDown,   // range: finger in digitizer range?
            (bool)fingerDown,   // touch: finger touching?
            0u
        );
        if (!hidEvent) {
            LOGE(@"tap_xy: IOHIDEventCreateDigitizerFingerEvent returned nil");
            return NO;
        }

        LOGI(@"tap_xy: _handleHIDEvent: phase=%d normX=%.3f normY=%.3f fingerDown=%d",
             (int)phase, normX, normY, (int)fingerDown);

        typedef void (*HandleFn)(id, SEL, CFTypeRef);
        ((HandleFn)objc_msgSend)(app, handleSel, hidEvent);

        // Check what UIKit created — did it produce a UITouch?
        if ([app respondsToSelector:@selector(_touchesEvent)]) {
            UIEvent *ev = [app _touchesEvent];
            LOGI(@"tap_xy: post-handleHID: _touchesEvent=%p allTouches=%lu",
                 (__bridge void *)ev, (unsigned long)ev.allTouches.count);
            if (ev && ev.allTouches.count > 0) {
                // UIKit created a UITouch — dispatch via the correct window
                LOGI(@"tap_xy: dispatching via [window sendEvent:] with UIKit-created touch");
                [window sendEvent:ev];
            }
        }

        CFRelease(hidEvent);
        return YES;
    }   // end iOS 26+ pure-HID block

    // ── iOS <26 path: manual UITouch + UIEvent ────────────────────────────────
    // UITouch private setters + _touchesEvent + _addTouch:forDelayedDelivery:.
    // These APIs were removed in iOS 26 (confirmed by probe), so this path only
    // runs on older devices/OS versions.
    UIApplication *app = [UIApplication sharedApplication];
    NSTimeInterval ts = [NSProcessInfo processInfo].systemUptime;
    UITouch *touch = [[UITouch alloc] init];

    // window setter
    if ([touch respondsToSelector:@selector(_setWindow:)])
        [touch _setWindow:window];
    else { LOGE(@"tap_xy (<26): no _setWindow: on UITouch"); return NO; }

    // view setter (best-effort; nil is tolerated by some iOS versions)
    if ([touch respondsToSelector:@selector(_setView:)])
        [touch _setView:hitView];

    // phase setter
    if ([touch respondsToSelector:@selector(_setPhase:)])
        [touch _setPhase:phase];
    else { LOGE(@"tap_xy (<26): no _setPhase: on UITouch"); return NO; }

    // timestamp
    if ([touch respondsToSelector:@selector(_setTimestamp:)])
        [touch _setTimestamp:ts];

    // tap count
    if ([touch respondsToSelector:@selector(_setTapCount:)])
        [touch _setTapCount:1];

    // location
    if ([touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)])
        [touch _setLocationInWindow:pt resetPrevious:(phase == UITouchPhaseBegan)];
    else { LOGE(@"tap_xy (<26): no _setLocationInWindow:resetPrevious: on UITouch"); return NO; }

    // build UIEvent
    if (![app respondsToSelector:@selector(_touchesEvent)]) {
        LOGE(@"tap_xy (<26): no _touchesEvent on UIApplication"); return NO;
    }
    UIEvent *event = [app _touchesEvent];
    if ([event respondsToSelector:@selector(_clearTouches)])
        [event _clearTouches];
    if ([event respondsToSelector:@selector(_addTouch:forDelayedDelivery:)])
        [event _addTouch:touch forDelayedDelivery:NO];
    else { LOGE(@"tap_xy (<26): no _addTouch:forDelayedDelivery:"); return NO; }

    [window sendEvent:event];
    return YES;
}

// Temporary diagnostic: returns which Phase 3 private selectors are available.
// Call as: :rpc.call(node, :pegleg_nif, :tap_xy, [:probe])  — not real NIF arg,
// just probe by passing atom; actual impl checks argc.
static ERL_NIF_TERM nif_tap_xy_enumerate(ErlNifEnv *env, Class cls, const char *filter) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    ERL_NIF_TERM list = enif_make_list(env, 0);
    for (unsigned int i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (!filter || strstr(name, filter)) {
            list = enif_make_list_cell(env, enif_make_atom(env, name), list);
        }
    }
    free(methods);
    return list;
}

static ERL_NIF_TERM nif_tap_xy_probe(ErlNifEnv *env) {
    UIApplication *app = [UIApplication sharedApplication];
    UITouch *touch = [[UITouch alloc] init];
    UIEvent *fakeEvent = [UIEvent new];

    struct { const char *name; BOOL found; } checks[] = {
        {"UIApp._touchesEvent",                      [app    respondsToSelector:@selector(_touchesEvent)]},
        // UITouch — old private names (iOS <26)
        {"UITouch._setWindow:",                      [touch  respondsToSelector:@selector(_setWindow:)]},
        {"UITouch._setView:",                        [touch  respondsToSelector:@selector(_setView:)]},
        {"UITouch._setPhase:",                       [touch  respondsToSelector:@selector(_setPhase:)]},
        {"UITouch._setTimestamp:",                   [touch  respondsToSelector:@selector(_setTimestamp:)]},
        {"UITouch._setTapCount:",                    [touch  respondsToSelector:@selector(_setTapCount:)]},
        {"UITouch._setLocationInWindow:resetPrevious:", [touch respondsToSelector:@selector(_setLocationInWindow:resetPrevious:)]},
        // UITouch — iOS 26+ names (no underscore)
        {"UITouch.setWindow:",                       [touch  respondsToSelector:@selector(setWindow:)]},
        {"UITouch.setView:",                         [touch  respondsToSelector:@selector(setView:)]},
        {"UITouch.setPhase:",                        [touch  respondsToSelector:@selector(setPhase:)]},
        {"UITouch.setTimestamp:",                    [touch  respondsToSelector:@selector(setTimestamp:)]},
        {"UITouch.setTapCount:",                     [touch  respondsToSelector:@selector(setTapCount:)]},
        // UIEvent — old private names (iOS <26)
        {"UIEvent._clearTouches",                    [fakeEvent respondsToSelector:@selector(_clearTouches)]},
        {"UIEvent._addTouch:forDelayedDelivery:",    [fakeEvent respondsToSelector:@selector(_addTouch:forDelayedDelivery:)]},
        // UIEvent — iOS 26+
        {"UIEvent._initWithEvent:touches:",          [UIEvent instancesRespondToSelector:@selector(_initWithEvent:touches:)]},
        // UITouch HID backing
        {"UITouch._setHidEvent:",                    [touch  respondsToSelector:@selector(_setHidEvent:)]},
        {"UITouch._hidEvent",                        [touch  respondsToSelector:@selector(_hidEvent)]},
    };

    ERL_NIF_TERM list = enif_make_list(env, 0);
    int n = sizeof(checks) / sizeof(checks[0]);
    for (int i = n - 1; i >= 0; i--) {
        ERL_NIF_TERM key = enif_make_atom(env, checks[i].name);
        ERL_NIF_TERM val = enif_make_atom(env, checks[i].found ? "true" : "false");
        list = enif_make_list_cell(env, enif_make_tuple2(env, key, val), list);
    }

    // Inspect the type encoding of _initWithEvent:touches: to learn what first arg type it wants.
    // "@" = id (object), "^" = pointer, etc.
    {
        Method m = class_getInstanceMethod([UIEvent class], @selector(_initWithEvent:touches:));
        if (m) {
            const char *enc = method_getTypeEncoding(m);
            // enc looks like "@24@0:8@16@16" — arg0 is return (id), arg2 is self,
            // arg3 is SEL, arg4 is first real arg. We want arg4's type.
            ERL_NIF_TERM enc_term = enif_make_string(env, enc ? enc : "(null)", ERL_NIF_LATIN1);
            list = enif_make_list_cell(env,
                enif_make_tuple2(env,
                    enif_make_atom(env, "UIEvent._initWithEvent:touches:.encoding"),
                    enc_term),
                list);
        }
    }

    // Test _initWithEvent: with empty NSSet to isolate whether UITouch or base causes nil return.
    {
        UIEvent *baseInit = [UIEvent instancesRespondToSelector:@selector(_init)]
                          ? [[UIEvent alloc] _init] : nil;
        SEL initWithEvSel = NSSelectorFromString(@"_initWithEvent:touches:");
        typedef UIEvent* (*InitWithEvFn)(id, SEL, void*, NSSet*);
        UIEvent *testEmpty = [UIEvent instancesRespondToSelector:initWithEvSel]
            ? ((InitWithEvFn)objc_msgSend)([[UIEvent alloc] init], initWithEvSel, (__bridge void *)baseInit, [NSSet set])
            : nil;
        ERL_NIF_TERM val = enif_make_atom(env, testEmpty ? "non_nil" : "nil");
        list = enif_make_list_cell(env,
            enif_make_tuple2(env,
                enif_make_atom(env, "_initWithEvent:emptySet"),
                val),
            list);
    }

    // Type encoding of UIEvent._setHIDEvent: to learn what it takes.
    {
        Method m = class_getInstanceMethod([UIEvent class], @selector(_setHIDEvent:));
        if (m) {
            const char *enc = method_getTypeEncoding(m);
            list = enif_make_list_cell(env,
                enif_make_tuple2(env,
                    enif_make_atom(env, "UIEvent._setHIDEvent:.encoding"),
                    enif_make_string(env, enc ? enc : "(null)", ERL_NIF_LATIN1)),
                list);
        }
    }

    // Check if IOHIDEventCreate* functions are available (for direct HID injection).
    {
        BOOL hasCreateFinger = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEvent") != NULL;
        BOOL hasCreateFingerQ = dlsym(RTLD_DEFAULT, "IOHIDEventCreateDigitizerFingerEventWithQuality") != NULL;
        list = enif_make_list_cell(env,
            enif_make_tuple2(env,
                enif_make_atom(env, "dlsym.IOHIDEventCreateDigitizerFingerEvent"),
                enif_make_atom(env, hasCreateFinger ? "true" : "false")),
            list);
        list = enif_make_list_cell(env,
            enif_make_tuple2(env,
                enif_make_atom(env, "dlsym.IOHIDEventCreateDigitizerFingerEventWithQuality"),
                enif_make_atom(env, hasCreateFingerQ ? "true" : "false")),
            list);
    }

    // Check for UIApplication._handleHIDEvent:
    {
        UIApplication *a = [UIApplication sharedApplication];
        BOOL hasHandle = [a respondsToSelector:NSSelectorFromString(@"_handleHIDEvent:")];
        list = enif_make_list_cell(env,
            enif_make_tuple2(env,
                enif_make_atom(env, "UIApp._handleHIDEvent:"),
                enif_make_atom(env, hasHandle ? "true" : "false")),
            list);
    }

    // Check for GSSendSystemEvent / GSSynthesizeSystemEvent via dlsym.
    {
        const char *gsFuncs[] = {
            "GSSendSystemEvent", "GSSynthesizeSystemEvent",
            "GSSendEvent", "GSEventDispatch",
            "GSSendSystemEventFast",
        };
        for (int i = 0; i < 5; i++) {
            BOOL found = dlsym(RTLD_DEFAULT, gsFuncs[i]) != NULL;
            list = enif_make_list_cell(env,
                enif_make_tuple2(env,
                    enif_make_atom(env, gsFuncs[i]),
                    enif_make_atom(env, found ? "true" : "false")),
                list);
        }
    }

    return list;
}

static ERL_NIF_TERM nif_tap_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    // Diagnostics mode — pass :probe or :enumerate_touch or :enumerate_event
    if (enif_is_atom(env, argv[0])) {
        char atom[64]; enif_get_atom(env, argv[0], atom, sizeof(atom), ERL_NIF_LATIN1);
        if (strcmp(atom, "enumerate_touch") == 0)
            return nif_tap_xy_enumerate(env, [UITouch class], NULL);
        if (strcmp(atom, "enumerate_event") == 0)
            return nif_tap_xy_enumerate(env, [UIEvent class], NULL);
        if (strcmp(atom, "enumerate_app_event") == 0)
            return nif_tap_xy_enumerate(env, [UIApplication class], "Event");
        if (strcmp(atom, "enumerate_app_hid") == 0)
            return nif_tap_xy_enumerate(env, [UIApplication class], "HID");
        if (strcmp(atom, "enumerate_app_touch") == 0)
            return nif_tap_xy_enumerate(env, [UIApplication class], "ouch");
        if (strcmp(atom, "enumerate_touch_set") == 0)
            return nif_tap_xy_enumerate(env, [UITouch class], "set");
        if (strcmp(atom, "enumerate_touch_init") == 0)
            return nif_tap_xy_enumerate(env, [UITouch class], "init");
        if (strcmp(atom, "enumerate_event_ivars") == 0) {
            // Dump UIEvent instance variable names and offsets
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList([UIEvent class], &count);
            ERL_NIF_TERM list = enif_make_list(env, 0);
            for (unsigned int i = 0; i < count; i++) {
                const char *name = ivar_getName(ivars[i]);
                ptrdiff_t   off  = ivar_getOffset(ivars[i]);
                const char *type = ivar_getTypeEncoding(ivars[i]);
                char buf[256];
                snprintf(buf, sizeof(buf), "%s@%td(%s)", name ? name : "?", off, type ? type : "?");
                list = enif_make_list_cell(env, enif_make_atom(env, buf), list);
            }
            free(ivars);
            return list;
        }
        // Enumerate UIWindow methods (useful for finding contextId getter)
        if (strcmp(atom, "enumerate_window") == 0) {
            return nif_tap_xy_enumerate(env, [UIWindow class], NULL);
        }
        if (strcmp(atom, "enumerate_window_context") == 0) {
            return nif_tap_xy_enumerate(env, [UIWindow class], "context");
        }
        // Return contextId and class of the key window — for HID event routing
        if (strcmp(atom, "window_info") == 0) {
            __block ERL_NIF_TERM result = enif_make_atom(env, "no_window");
            dispatch_sync(dispatch_get_main_queue(), ^{
                UIWindow *win = nil;
                for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                    if ([sc isKindOfClass:[UIWindowScene class]]) {
                        for (UIWindow *w in [(UIWindowScene *)sc windows]) {
                            if (!w.isHidden) { win = w; break; }
                        }
                        if (win) break;
                    }
                }
                if (!win) return;

                // Try various contextId getters
                uint32_t ctxId = 0;
                SEL ctxSels[] = {
                    @selector(_contextId),
                    @selector(_windowContextID),
                    @selector(contextId),
                    @selector(_displayID),
                };
                NSString *ctxSelName = @"none";
                for (int i = 0; i < 4; i++) {
                    if ([win respondsToSelector:ctxSels[i]]) {
                        typedef uint32_t (*GetU32Fn)(id, SEL);
                        ctxId = ((GetU32Fn)objc_msgSend)(win, ctxSels[i]);
                        ctxSelName = NSStringFromSelector(ctxSels[i]);
                        break;
                    }
                }

                char buf[256];
                snprintf(buf, sizeof(buf), "win=%p class=%s ctxSel=%s ctxId=0x%08x",
                         (__bridge void *)win,
                         class_getName(object_getClass(win)),
                         [ctxSelName UTF8String],
                         ctxId);
                result = enif_make_string(env, buf, ERL_NIF_LATIN1);
            });
            return result;
        }
        return nif_tap_xy_probe(env);
    }
    double x, y;
    if (!enif_get_double(env, argv[0], &x)) {
        int ix; if (!enif_get_int(env, argv[0], &ix)) return enif_make_badarg(env); x = ix;
    }
    if (!enif_get_double(env, argv[1], &y)) {
        int iy; if (!enif_get_int(env, argv[1], &iy)) return enif_make_badarg(env); y = iy;
    }

    CGPoint pt = CGPointMake(x, y);

#if TARGET_OS_SIMULATOR
    // ── Simulator: accessibility-based activation by coordinates ─────────────────
    // The iOS simulator rejects in-process synthetic IOHIDEvents (no valid display
    // context) and SwiftUI on iOS 26 ignores direct touchesBegan: calls without
    // proper event system backing. Accessibility activation is the reliable path
    // for the simulator; for scroll views and custom GRs that lack accessibility,
    // a simulator-specific event injection mechanism would be needed.
    __block BOOL activated = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                id elem = find_a11y_at_point(win, pt, 0);
                if (elem) {
                    LOGI(@"tap_xy(sim): accessibilityActivate on %@ frame=%@",
                         NSStringFromClass(object_getClass(elem)),
                         NSStringFromCGRect([elem accessibilityFrame]));
                    [elem accessibilityActivate];
                    // For text fields: accessibilityActivate on UITextFieldLabel
                    // (the hint label inside UITextField) doesn't focus the
                    // field. Walk the responder chain up from the hit view to
                    // find the first UITextField/UITextView and focus it.
                    UIView *hv = [win hitTest:pt withEvent:nil];
                    UIResponder *r = hv;
                    while (r) {
                        if ([r isKindOfClass:[UITextField class]] ||
                            [r isKindOfClass:[UITextView class]]) {
                            [(UIView *)r becomeFirstResponder];
                            break;
                        }
                        r = r.nextResponder;
                    }
                    activated = YES;
                    return;
                }
            }
        }
    });
    if (activated) return enif_make_atom(env, "ok");
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_element_at_point"));

#else
    // ── Real device: UITouch injection via IOHIDEvent ─────────────────────────────
    __block UIWindow *targetWindow = nil;
    __block UIView   *hitView      = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                UIView *hit = [win hitTest:pt withEvent:nil];
                if (hit) { targetWindow = win; hitView = hit; return; }
            }
        }
    });

    if (!hitView) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "no_view_at_point"));
    }

    __block BOOL ok = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        ok = mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseBegan);
    });
    if (!ok) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            nif_tap_xy_probe(env));
    }

    [NSThread sleepForTimeInterval:0.10];

    dispatch_sync(dispatch_get_main_queue(), ^{
        mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseEnded);
    });

    return enif_make_atom(env, "ok");
#endif
}


static id find_first_responder_in(UIView *view) {
    if (view.isFirstResponder) return view;
    for (UIView *sub in view.subviews) {
        id fr = find_first_responder_in(sub);
        if (fr) return fr;
    }
    return nil;
}

// ─── delete_backward/0 — delete one character behind the cursor ──────────────
//
// Calls deleteBackward: on the current first responder. Equivalent to pressing
// the backspace key. Repeating gives "hold backspace" behaviour.
//
// Returns: ok | {error, no_first_responder} | {error, not_text_input}

static ERL_NIF_TERM nif_delete_backward(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block BOOL done = NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                id fr = find_first_responder_in(win);
                if (!fr) continue;
                found = YES;
                if ([fr respondsToSelector:@selector(deleteBackward)]) {
                    [fr deleteBackward];
                    done = YES;
                }
                return;
            }
        }
    });
    if (done)  return enif_make_atom(env, "ok");
    if (found) return enif_make_tuple2(env,
                   enif_make_atom(env, "error"),
                   enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_first_responder"));
}


// ─── key_press/1 — send a special key to the focused text input ───────────────
//
// Accepts an atom:
//   return   — submit / next field (inserts "\n", triggers textFieldShouldReturn:)
//   tab      — move to next field (inserts "\t")
//   escape   — dismiss keyboard (resignFirstResponder)
//   space    — insert a space character
//
// Returns: ok | {error, no_first_responder} | {error, unknown_key} |
//          {error, not_text_input}

static ERL_NIF_TERM nif_key_press(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    char keybuf[32];
    if (!enif_get_atom(env, argv[0], keybuf, sizeof(keybuf), ERL_NIF_LATIN1))
        return enif_make_badarg(env);
    NSString *key = [NSString stringWithUTF8String:keybuf];

    __block BOOL done = NO;
    __block BOOL found = NO;
    __block BOOL unknown = NO;

    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                id fr = find_first_responder_in(win);
                if (!fr) continue;
                found = YES;

                if ([key isEqualToString:@"return"]) {
                    if ([fr respondsToSelector:@selector(insertText:)]) {
                        [fr insertText:@"\n"];
                        done = YES;
                    }
                } else if ([key isEqualToString:@"tab"]) {
                    if ([fr respondsToSelector:@selector(insertText:)]) {
                        [fr insertText:@"\t"];
                        done = YES;
                    }
                } else if ([key isEqualToString:@"space"]) {
                    if ([fr respondsToSelector:@selector(insertText:)]) {
                        [fr insertText:@" "];
                        done = YES;
                    }
                } else if ([key isEqualToString:@"escape"]) {
                    [fr resignFirstResponder];
                    done = YES;
                } else {
                    unknown = YES;
                }
                return;
            }
        }
    });

    if (unknown) return enif_make_tuple2(env,
                     enif_make_atom(env, "error"),
                     enif_make_atom(env, "unknown_key"));
    if (done)  return enif_make_atom(env, "ok");
    if (found) return enif_make_tuple2(env,
                   enif_make_atom(env, "error"),
                   enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_first_responder"));
}


// ─── clear_text/0 — erase all text in the focused input ──────────────────────
//
// Calls selectAll: then deleteBackward: on the first responder. Works on
// UITextField, UITextView, and UIKeyInput adopters.
//
// Returns: ok | {error, no_first_responder} | {error, not_text_input}

static ERL_NIF_TERM nif_clear_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    __block BOOL done = NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                id fr = find_first_responder_in(win);
                if (!fr) continue;
                found = YES;
                BOOL canClear = [fr respondsToSelector:@selector(selectAll:)] &&
                                [fr respondsToSelector:@selector(deleteBackward)];
                if (canClear) {
                    [fr selectAll:nil];
                    // selectAll: is async in UITextView — yield once to let selection settle
                    // before deleting.
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [fr deleteBackward];
                    });
                    done = YES;
                }
                return;
            }
        }
    });
    if (done)  return enif_make_atom(env, "ok");
    if (found) return enif_make_tuple2(env,
                   enif_make_atom(env, "error"),
                   enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_first_responder"));
}


// ─── long_press_xy/3 — hold touch at (x, y) for duration_ms milliseconds ─────
//
// Simulator: finds UILongPressGestureRecognizer on the hit view or its ancestors
// and forces state transitions via the private _setState: selector, which fires
// the target/action pairs without needing HID events.
//
// Real device: emits Began → sleep(duration_ms) → Ended via IOHIDEvent, same
// path as tap_xy.
//
// Returns: ok | {error, no_view_at_point} | {error, no_long_press_recognizer}

static ERL_NIF_TERM nif_long_press_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    double x, y;
    int duration_ms;
    if (!enif_get_double(env, argv[0], &x) ||
        !enif_get_double(env, argv[1], &y) ||
        !enif_get_int(env, argv[2], &duration_ms))
        return enif_make_badarg(env);

    CGPoint pt = CGPointMake((CGFloat)x, (CGFloat)y);

#if TARGET_OS_SIMULATOR
    __block BOOL fired = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIView *hitView = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                UIView *h = [win hitTest:pt withEvent:nil];
                if (h) { hitView = h; break; }
            }
            if (hitView) break;
        }
        if (!hitView) return;

        // Walk up the responder chain looking for any UILongPressGestureRecognizer
        SEL setStateSel = NSSelectorFromString(@"_setState:");
        UIView *v = hitView;
        while (v && !fired) {
            for (UIGestureRecognizer *gr in v.gestureRecognizers) {
                if (![gr isKindOfClass:[UILongPressGestureRecognizer class]]) continue;
                if (![gr respondsToSelector:setStateSel]) continue;
                typedef void (*SetStateFn)(id, SEL, NSInteger);
                SetStateFn setState = (SetStateFn)objc_msgSend;
                LOGI(@"long_press_xy(sim): firing LPGR on %@", NSStringFromClass([v class]));
                setState(gr, setStateSel, UIGestureRecognizerStateBegan);
                setState(gr, setStateSel, UIGestureRecognizerStateEnded);
                fired = YES;
                break;
            }
            v = v.superview;
        }

        // SwiftUI onLongPressGesture may also surface as an accessibility custom action.
        // Try accessibilityActivate as a fallback — limited but better than nothing.
        if (!fired) {
            id elem = find_a11y_at_point(hitView, pt, 0);
            if (elem && [elem respondsToSelector:@selector(accessibilityActivate)]) {
                LOGI(@"long_press_xy(sim): fallback to accessibilityActivate on %@",
                     NSStringFromClass(object_getClass(elem)));
                [elem accessibilityActivate];
                fired = YES;
            }
        }
    });

    if (fired) return enif_make_atom(env, "ok");
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_long_press_recognizer"));

#else
    // Real device: Began → hold → Ended
    __block UIWindow *targetWindow = nil;
    __block UIView   *hitView      = nil;

    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                UIView *h = [win hitTest:pt withEvent:nil];
                if (h) { targetWindow = win; hitView = h; return; }
            }
        }
    });

    if (!hitView)
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "no_view_at_point"));

    dispatch_sync(dispatch_get_main_queue(), ^{
        mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseBegan);
    });

    [NSThread sleepForTimeInterval:(double)duration_ms / 1000.0];

    dispatch_sync(dispatch_get_main_queue(), ^{
        mob_send_touch_phase(targetWindow, hitView, pt, UITouchPhaseEnded);
    });

    return enif_make_atom(env, "ok");
#endif
}


// ─── type_text/1 — type into whatever UITextField/UITextView has focus ────────
//
// Finds the current first responder in the view hierarchy and calls insertText:
// on it. Works for UITextField, UITextView, and any custom view that adopts
// UIKeyInput. The caller should tap the field first to give it focus.
//
// Returns: ok | {error, no_first_responder} | {error, not_text_input}

static ERL_NIF_TERM nif_type_text(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin))
        return enif_make_badarg(env);

    NSString *text = [[NSString alloc] initWithBytes:bin.data
                                              length:bin.size
                                           encoding:NSUTF8StringEncoding];
    if (!text)
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "invalid_utf8"));

    __block BOOL typed = NO;
    __block BOOL found = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                id fr = find_first_responder_in(win);
                if (!fr) continue;
                found = YES;
                if ([fr respondsToSelector:@selector(insertText:)]) {
                    LOGI(@"type_text: inserting %lu chars into %@",
                         (unsigned long)text.length, NSStringFromClass([fr class]));
                    [fr insertText:text];
                    typed = YES;
                }
                return;
            }
        }
    });

    if (typed)  return enif_make_atom(env, "ok");
    if (found)  return enif_make_tuple2(env,
                    enif_make_atom(env, "error"),
                    enif_make_atom(env, "not_text_input"));
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_first_responder"));
}


// ─── swipe_xy/4 — scroll gesture from (x1,y1) to (x2,y2) ────────────────────
//
// Simulator: walks the hit-test chain up from the touch point to find a
// UIScrollView and adjusts its contentOffset by the swipe delta.
//
// Real device: synthesises Began + multiple Moved + Ended IOHIDEvents through
// the same mob_send_touch_phase path used by tap_xy.
//
// Returns: ok | {error, no_scroll_view} | {error, no_view_at_point}

static UIScrollView *find_scroll_view_at(CGPoint pt) {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *win in [(UIWindowScene *)scene windows]) {
            if (win.isHidden) continue;
            UIView *hit = [win hitTest:pt withEvent:nil];
            UIView *v = hit;
            while (v) {
                if ([v isKindOfClass:[UIScrollView class]])
                    return (UIScrollView *)v;
                v = v.superview;
            }
        }
    }
    return nil;
}

static ERL_NIF_TERM nif_swipe_xy(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    double x1, y1, x2, y2;
    if (!enif_get_double(env, argv[0], &x1) ||
        !enif_get_double(env, argv[1], &y1) ||
        !enif_get_double(env, argv[2], &x2) ||
        !enif_get_double(env, argv[3], &y2))
        return enif_make_badarg(env);

    CGFloat dx = (CGFloat)(x2 - x1);
    CGFloat dy = (CGFloat)(y2 - y1);
    // Center of swipe for hit-testing
    CGPoint mid = CGPointMake((CGFloat)((x1 + x2) / 2.0), (CGFloat)((y1 + y2) / 2.0));

#if TARGET_OS_SIMULATOR
    __block BOOL scrolled = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        UIScrollView *sv = find_scroll_view_at(mid);
        if (!sv) {
            // Also try start point
            sv = find_scroll_view_at(CGPointMake((CGFloat)x1, (CGFloat)y1));
        }
        if (!sv) return;

        CGPoint cur = sv.contentOffset;
        // Swiping up (dy < 0) means content moves down (contentOffset.y increases)
        CGFloat newX = cur.x - dx;
        CGFloat newY = cur.y - dy;
        // Clamp to valid range
        CGFloat maxX = MAX(0.0f, sv.contentSize.width  - sv.bounds.size.width);
        CGFloat maxY = MAX(0.0f, sv.contentSize.height - sv.bounds.size.height);
        newX = MAX(0.0f, MIN(newX, maxX));
        newY = MAX(0.0f, MIN(newY, maxY));
        LOGI(@"swipe_xy(sim): sv=%@ offset (%.1f,%.1f) → (%.1f,%.1f)",
             NSStringFromClass([sv class]), cur.x, cur.y, newX, newY);
        [sv setContentOffset:CGPointMake(newX, newY) animated:YES];
        scrolled = YES;
    });
    if (scrolled) return enif_make_atom(env, "ok");
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "no_scroll_view"));

#else
    // Real device: emit Began → 10 Moved steps → Ended via HID events
    __block UIWindow *targetWindow = nil;
    __block UIView   *hitView      = nil;
    CGPoint startPt = CGPointMake((CGFloat)x1, (CGFloat)y1);
    CGPoint endPt   = CGPointMake((CGFloat)x2, (CGFloat)y2);

    dispatch_sync(dispatch_get_main_queue(), ^{
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *win in [(UIWindowScene *)scene windows]) {
                if (win.isHidden) continue;
                UIView *hit = [win hitTest:startPt withEvent:nil];
                if (hit) { targetWindow = win; hitView = hit; return; }
            }
        }
    });

    if (!hitView)
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "no_view_at_point"));

    // Began
    dispatch_sync(dispatch_get_main_queue(), ^{
        mob_send_touch_phase(targetWindow, hitView, startPt, UITouchPhaseBegan);
    });

    // 10 evenly-spaced Moved steps
    int steps = 10;
    for (int i = 1; i <= steps; i++) {
        [NSThread sleepForTimeInterval:0.016]; // ~60fps
        CGPoint movePt = CGPointMake(
            (CGFloat)(x1 + dx * i / steps),
            (CGFloat)(y1 + dy * i / steps)
        );
        dispatch_sync(dispatch_get_main_queue(), ^{
            mob_send_touch_phase(targetWindow, hitView, movePt, UITouchPhaseMoved);
        });
    }

    [NSThread sleepForTimeInterval:0.016];

    // Ended
    dispatch_sync(dispatch_get_main_queue(), ^{
        mob_send_touch_phase(targetWindow, hitView, endPt, UITouchPhaseEnded);
    });

    return enif_make_atom(env, "ok");
#endif
}


// ── Storage ───────────────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_storage_dir(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char loc[32];
    enif_get_atom(env, argv[0], loc, sizeof(loc), ERL_NIF_LATIN1);

    NSString* path = nil;
    NSFileManager* fm = [NSFileManager defaultManager];
    if (strcmp(loc, "temp") == 0) {
        path = NSTemporaryDirectory();
    } else if (strcmp(loc, "documents") == 0) {
        path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    } else if (strcmp(loc, "cache") == 0) {
        path = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    } else if (strcmp(loc, "app_support") == 0) {
        path = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
        [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    } else if (strcmp(loc, "icloud") == 0) {
        NSURL* url = [fm URLForUbiquityContainerIdentifier:nil];
        if (url) {
            path = [url URLByAppendingPathComponent:@"Documents"].path;
            [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
        }
    }

    if (!path) return enif_make_atom(env, "nil");
    const char* cpath = path.UTF8String;
    ErlNifBinary bin; enif_alloc_binary(strlen(cpath), &bin);
    memcpy(bin.data, cpath, strlen(cpath));
    return enif_make_binary(env, &bin);
}

static ERL_NIF_TERM nif_storage_save_to_photo_library(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString* path = [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
    ErlNifPid pid; enif_self(env, &pid);

    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                               handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
            ErlNifEnv* e = enif_alloc_env();
            ERL_NIF_TERM msg = enif_make_tuple4(e,
                enif_make_atom(e, "storage"), enif_make_atom(e, "error"),
                enif_make_atom(e, "save_to_library"), enif_make_atom(e, "permission_denied"));
            enif_send(NULL, &pid, e, msg);
            enif_free_env(e);
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            NSURL* url = [NSURL fileURLWithPath:path];
            NSString* ext = path.pathExtension.lowercaseString;
            BOOL isVideo = [@[@"mp4", @"mov", @"m4v"] containsObject:ext];
            if (isVideo) [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
            else         [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:url];
        } completionHandler:^(BOOL success, NSError* err) {
            ErlNifEnv* e = enif_alloc_env();
            ERL_NIF_TERM msg;
            if (success) {
                const char* cpath = path.UTF8String;
                ErlNifBinary pb; enif_alloc_binary(strlen(cpath), &pb);
                memcpy(pb.data, cpath, strlen(cpath));
                msg = enif_make_tuple3(e,
                    enif_make_atom(e, "storage"),
                    enif_make_atom(e, "saved_to_library"),
                    enif_make_binary(e, &pb));
            } else {
                msg = enif_make_tuple4(e,
                    enif_make_atom(e, "storage"), enif_make_atom(e, "error"),
                    enif_make_atom(e, "save_to_library"), enif_make_atom(e, "save_failed"));
            }
            enif_send(NULL, &pid, e, msg);
            enif_free_env(e);
        }];
    }];
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_storage_save_to_media_store(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_tuple2(env, enif_make_atom(env, "error"), enif_make_atom(env, "not_supported"));
}

static ERL_NIF_TERM nif_storage_external_files_dir(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    return enif_make_atom(env, "nil");
}

// ── WebView ───────────────────────────────────────────────────────────────────
// g_webview is set by MobWebView (MobRootView.swift) when the component is created.
// mob_deliver_webview_message / _blocked are called from Swift (via bridging header).

static void deliver_webview_binary(const char* tag, const char* utf8) {
    ErlNifEnv* env = enif_alloc_env();
    ErlNifPid pid;
    if (!enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        enif_free_env(env); return;
    }
    size_t len = strlen(utf8);
    ErlNifBinary bin;
    enif_alloc_binary(len, &bin);
    memcpy(bin.data, utf8, len);
    ERL_NIF_TERM msg = enif_make_tuple3(env,
        enif_make_atom(env, "webview"),
        enif_make_atom(env, tag),
        enif_make_binary(env, &bin));
    enif_send(NULL, &pid, env, msg);
    enif_free_env(env);
}

void mob_deliver_webview_message(const char* json_utf8) {
    deliver_webview_binary("message", json_utf8);
}

void mob_deliver_webview_blocked(const char* url_utf8) {
    deliver_webview_binary("blocked", url_utf8);
}

WKWebView* g_webview = nil;


// ── Alert delivery (called from UIAlertAction blocks) ────────────────────────

static void mob_deliver_alert_action(const char* action) {
    ErlNifEnv* env = enif_alloc_env();
    ErlNifPid pid;
    if (enif_whereis_pid(env, enif_make_atom(env, "mob_screen"), &pid)) {
        ERL_NIF_TERM msg = enif_make_tuple2(env,
            enif_make_atom(env, "alert"),
            enif_make_atom(env, action));
        enif_send(NULL, &pid, env, msg);
    }
    enif_free_env(env);
}

// Returns the root UIViewController for presenting dialogs.
static UIViewController* root_vc(void) {
    for (UIWindowScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            UIWindow* win = scene.windows.firstObject;
            UIViewController* vc = win.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            return vc;
        }
    }
    return nil;
}

// ── NIF: alert_show/3 ────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_alert_show(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary title_bin, msg_bin, btns_bin;
    if (!enif_inspect_binary(env, argv[0], &title_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &title_bin)) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &msg_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &msg_bin))   return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[2], &btns_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[2], &btns_bin))  return enif_make_badarg(env);

    NSString* title   = [[NSString alloc] initWithBytes:title_bin.data length:title_bin.size encoding:NSUTF8StringEncoding];
    NSString* message = msg_bin.size > 0 ? [[NSString alloc] initWithBytes:msg_bin.data length:msg_bin.size encoding:NSUTF8StringEncoding] : nil;
    NSData*   btns_d  = [NSData dataWithBytes:btns_bin.data length:btns_bin.size];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray* buttons = [NSJSONSerialization JSONObjectWithData:btns_d options:0 error:nil];
        if (![buttons isKindOfClass:[NSArray class]]) return;

        UIAlertController* ac = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
        for (NSDictionary* btn in buttons) {
            NSString* label  = btn[@"label"]  ?: @"";
            NSString* action = btn[@"action"] ?: @"dismiss";
            NSString* style  = btn[@"style"]  ?: @"default";
            UIAlertActionStyle as = UIAlertActionStyleDefault;
            if ([style isEqualToString:@"cancel"])      as = UIAlertActionStyleCancel;
            if ([style isEqualToString:@"destructive"]) as = UIAlertActionStyleDestructive;
            const char* act_c = [action UTF8String];
            [ac addAction:[UIAlertAction actionWithTitle:label style:as handler:^(UIAlertAction* _) {
                mob_deliver_alert_action(act_c);
            }]];
        }
        UIViewController* vc = root_vc();
        if (vc) [vc presentViewController:ac animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: action_sheet_show/2 ─────────────────────────────────────────────────

static ERL_NIF_TERM nif_action_sheet_show(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary title_bin, btns_bin;
    if (!enif_inspect_binary(env, argv[0], &title_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &title_bin)) return enif_make_badarg(env);
    if (!enif_inspect_binary(env, argv[1], &btns_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[1], &btns_bin))  return enif_make_badarg(env);

    NSString* title  = title_bin.size > 0 ? [[NSString alloc] initWithBytes:title_bin.data length:title_bin.size encoding:NSUTF8StringEncoding] : nil;
    NSData*   btns_d = [NSData dataWithBytes:btns_bin.data length:btns_bin.size];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray* buttons = [NSJSONSerialization JSONObjectWithData:btns_d options:0 error:nil];
        if (![buttons isKindOfClass:[NSArray class]]) return;

        UIAlertController* ac = [UIAlertController alertControllerWithTitle:title
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSDictionary* btn in buttons) {
            NSString* label  = btn[@"label"]  ?: @"";
            NSString* action = btn[@"action"] ?: @"dismiss";
            NSString* style  = btn[@"style"]  ?: @"default";
            UIAlertActionStyle as = UIAlertActionStyleDefault;
            if ([style isEqualToString:@"cancel"])      as = UIAlertActionStyleCancel;
            if ([style isEqualToString:@"destructive"]) as = UIAlertActionStyleDestructive;
            const char* act_c = [action UTF8String];
            [ac addAction:[UIAlertAction actionWithTitle:label style:as handler:^(UIAlertAction* _) {
                mob_deliver_alert_action(act_c);
            }]];
        }
        UIViewController* vc = root_vc();
        if (!vc) return;
        // iPad requires a source view for action sheets
        if (ac.popoverPresentationController) {
            ac.popoverPresentationController.sourceView = vc.view;
            ac.popoverPresentationController.sourceRect =
                CGRectMake(vc.view.bounds.size.width / 2, vc.view.bounds.size.height, 0, 0);
        }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF: toast_show/2 ────────────────────────────────────────────────────────

static ERL_NIF_TERM nif_toast_show(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary msg_bin;
    char dur[8] = "short";
    if (!enif_inspect_binary(env, argv[0], &msg_bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &msg_bin)) return enif_make_badarg(env);
    enif_get_atom(env, argv[1], dur, sizeof(dur), ERL_NIF_LATIN1);

    NSString* message = [[NSString alloc] initWithBytes:msg_bin.data length:msg_bin.size encoding:NSUTF8StringEncoding];
    double seconds = strcmp(dur, "long") == 0 ? 3.5 : 2.0;

    dispatch_async(dispatch_get_main_queue(), ^{
        // Find the key window
        UIWindow* window = nil;
        for (UIWindowScene* scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive) {
                window = scene.windows.firstObject; break;
            }
        }
        if (!window) return;

        UILabel* label = [[UILabel alloc] init];
        label.text = message;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
        label.textAlignment = NSTextAlignmentCenter;
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
        label.layer.cornerRadius = 12;
        label.layer.masksToBounds = YES;
        label.numberOfLines = 0;

        CGFloat maxW = window.bounds.size.width - 48;
        CGSize  fit  = [label sizeThatFits:CGSizeMake(maxW - 32, 200)];
        CGFloat w    = MIN(fit.width + 32, maxW);
        CGFloat h    = fit.height + 16;
        CGFloat x    = (window.bounds.size.width - w) / 2;
        CGFloat y    = window.bounds.size.height - h - 80; // above home indicator
        label.frame  = CGRectMake(x, y, w, h);
        label.alpha  = 0;

        [window addSubview:label];
        [UIView animateWithDuration:0.25 animations:^{ label.alpha = 1.0; } completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ label.alpha = 0; }
                               completion:^(BOOL _) { [label removeFromSuperview]; }];
            });
        }];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_webview_eval_js(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString* code = [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_webview evaluateJavaScript:code completionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_webview_post_message(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString* json = [[NSString alloc] initWithBytes:bin.data length:bin.size encoding:NSUTF8StringEncoding];
    // Escape for single-quoted JS string: backslash then apostrophe
    NSString* escaped = [json stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString* js = [NSString stringWithFormat:@"window.mob&&window.mob._dispatch('%@')", escaped];
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_webview evaluateJavaScript:js completionHandler:nil];
    });
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM nif_webview_can_go_back(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    // dispatch_sync blocks this BEAM scheduler thread until the main queue drains.
    // Intentional — the caller (Mob.Screen back handler) needs the boolean before deciding
    // whether to pop the nav stack. Same pattern as clipboard_get and safe_area.
    // The main thread is expected to be idle during a back gesture.
    __block BOOL result = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        result = g_webview ? [g_webview canGoBack] : NO;
    });
    return enif_make_atom(env, result ? "true" : "false");
}

static ERL_NIF_TERM nif_webview_go_back(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [g_webview goBack];
    });
    return enif_make_atom(env, "ok");
}

// ── NIF table & load ──────────────────────────────────────────────────────────

static ErlNifFunc nif_funcs[] = {
    // ── Test harness (listed first to survive linker dead-code stripping) ──────
    {"ui_tree",          0, nif_ui_tree,          0},
    {"ui_debug",         0, nif_ui_debug,         0},
    {"tap",              1, nif_tap,              0},
    {"tap_xy",           2, nif_tap_xy,           0},
    {"type_text",        1, nif_type_text,        0},
    {"delete_backward",  0, nif_delete_backward,  0},
    {"key_press",        1, nif_key_press,        0},
    {"clear_text",       0, nif_clear_text,       0},
    {"long_press_xy",    3, nif_long_press_xy,    0},
    {"swipe_xy",         4, nif_swipe_xy,         0},
    // ── Core mob functions ───────────────────────────────────────────────────
    {"platform",       0, nif_platform,       0},
    {"log",            1, nif_log,            0},
    {"log",            2, nif_log2,           0},
    {"set_transition", 1, nif_set_transition, 0},
    {"set_root",       1, nif_set_root,       0},
    {"register_tap",   1, nif_register_tap,   0},
    {"clear_taps",     0, nif_clear_taps,     0},
    {"exit_app",       0, nif_exit_app,       0},
    {"safe_area",      0, nif_safe_area,      0},
    {"haptic",                    1, nif_haptic,                    0},
    {"clipboard_put",             1, nif_clipboard_put,             0},
    {"clipboard_get",             0, nif_clipboard_get,             0},
    {"share_text",                1, nif_share_text,                0},
    {"request_permission",        1, nif_request_permission,        0},
    {"biometric_authenticate",    1, nif_biometric_authenticate,    0},
    {"location_get_once",         0, nif_location_get_once,         0},
    {"location_start",            1, nif_location_start,            0},
    {"location_stop",             0, nif_location_stop,             0},
    {"camera_capture_photo",      1, nif_camera_capture_photo,      0},
    {"camera_capture_video",      1, nif_camera_capture_video,      0},
    {"camera_start_preview",      1, nif_camera_start_preview,      0},
    {"camera_stop_preview",       0, nif_camera_stop_preview,       0},
    {"photos_pick",               2, nif_photos_pick,               0},
    {"files_pick",                1, nif_files_pick,                0},
    {"audio_start_recording",     1, nif_audio_start_recording,     0},
    {"audio_stop_recording",      0, nif_audio_stop_recording,      0},
    {"audio_play",                2, nif_audio_play,                0},
    {"audio_stop_playback",       0, nif_audio_stop_playback,       0},
    {"audio_set_volume",          1, nif_audio_set_volume,          0},
    {"motion_start",              2, nif_motion_start,              0},
    {"motion_stop",               0, nif_motion_stop,               0},
    {"scanner_scan",              1, nif_scanner_scan,              0},
    {"notify_schedule",           1, nif_notify_schedule,           0},
    {"notify_cancel",             1, nif_notify_cancel,             0},
    {"notify_register_push",      0, nif_notify_register_push,      0},
    {"take_launch_notification",  0, nif_take_launch_notification,  0},
    {"storage_dir",                    1, nif_storage_dir,                    0},
    {"storage_save_to_photo_library",  1, nif_storage_save_to_photo_library,  0},
    {"storage_save_to_media_store",    2, nif_storage_save_to_media_store,    0},
    {"storage_external_files_dir",     1, nif_storage_external_files_dir,     0},
    {"alert_show",          3, nif_alert_show,          0},
    {"action_sheet_show",   2, nif_action_sheet_show,   0},
    {"toast_show",          2, nif_toast_show,          0},
    {"webview_eval_js",     1, nif_webview_eval_js,     0},
    {"webview_post_message",1, nif_webview_post_message,0},
    {"webview_can_go_back", 0, nif_webview_can_go_back, 0},
    {"webview_go_back",     0, nif_webview_go_back,     0},
};

static int nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
    LOGI(@"nif_load: initialising mob_nif (iOS/SwiftUI JSON backend)");
    tap_mutex = enif_mutex_create("mob_tap_mutex");
    if (!tap_mutex) { LOGE(@"nif_load: failed to create tap mutex"); return -1; }
    g_launch_notif_mutex = enif_mutex_create("mob_launch_notif_mutex");
    if (!g_launch_notif_mutex) { LOGE(@"nif_load: failed to create launch notif mutex"); return -1; }
    LOGI(@"nif_load: mob_nif ready");
    return 0;
}

ERL_NIF_INIT(mob_nif, nif_funcs, nif_load, NULL, NULL, NULL)
