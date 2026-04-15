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
#include <string.h>
#include "erl_nif.h"
#import "MobNode.h"
#import "MobDemo-Swift.h"

#define LOGI(...) NSLog(@"[MobNIF] " __VA_ARGS__)
#define LOGE(...) NSLog(@"[MobNIF][ERROR] " __VA_ARGS__)

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

    NSDictionary* props = dict[@"props"];
    if ([props isKindOfClass:[NSDictionary class]]) {
        id text = props[@"text"];
        if (text) node.text = [text isKindOfClass:[NSString class]] ? text : [text description];

        id padding = props[@"padding"];
        if (padding) node.padding = [padding doubleValue];

        id textSize = props[@"text_size"];
        if (textSize) node.textSize = [textSize doubleValue];

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

        id placeholderColor = props[@"placeholder_color"];
        if (placeholderColor) node.placeholderColor = color_from_argb((long)[placeholderColor longLongValue]);

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
};

static int nif_load(ErlNifEnv* env, void** priv, ERL_NIF_TERM info) {
    LOGI(@"nif_load: initialising mob_nif (iOS/SwiftUI JSON backend)");
    tap_mutex = enif_mutex_create("mob_tap_mutex");
    if (!tap_mutex) { LOGE(@"nif_load: failed to create tap mutex"); return -1; }
    LOGI(@"nif_load: mob_nif ready");
    return 0;
}

ERL_NIF_INIT(mob_nif, nif_funcs, nif_load, NULL, NULL, NULL)
