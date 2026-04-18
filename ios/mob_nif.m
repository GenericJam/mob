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
    else if ([type isEqualToString:@"video"])      node.nodeType = MobNodeTypeVideo;

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

// ── NIF table & load ──────────────────────────────────────────────────────────

static ErlNifFunc nif_funcs[] = {
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
    {"photos_pick",               2, nif_photos_pick,               0},
    {"files_pick",                1, nif_files_pick,                0},
    {"audio_start_recording",     1, nif_audio_start_recording,     0},
    {"audio_stop_recording",      0, nif_audio_stop_recording,      0},
    {"motion_start",              2, nif_motion_start,              0},
    {"motion_stop",               0, nif_motion_stop,               0},
    {"scanner_scan",              1, nif_scanner_scan,              0},
    {"notify_schedule",           1, nif_notify_schedule,           0},
    {"notify_cancel",             1, nif_notify_cancel,             0},
    {"notify_register_push",      0, nif_notify_register_push,      0},
    {"take_launch_notification",  0, nif_take_launch_notification,  0},
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
