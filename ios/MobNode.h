// MobNode.h — Data model node for the Mob UI tree (iOS SwiftUI layer).
// Created and mutated by mob_nif.m NIFs; read by MobRootView.swift for rendering.
// No BEAM headers here — kept clean for Swift import via bridging header.

#pragma once

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

// Shared camera preview session. Now OWNED by the mob_camera plugin (its NIF
// defines g_preview_session and drives start/stop_preview); core's MobRootView
// camera-preview view only reads it. Weak so core still links when mob_camera
// isn't activated — the symbol resolves to NULL and the preview shows black.
extern AVCaptureSession *_Nullable g_preview_session __attribute__((weak));

// Shared WebView — set by MobWebView when created, read by webview NIFs.
extern WKWebView *_Nullable g_webview;

typedef NS_ENUM(NSInteger, MobNodeType) {
    MobNodeTypeColumn,
    MobNodeTypeRow,
    MobNodeTypeLabel,
    MobNodeTypeButton,
    MobNodeTypeScroll,
    MobNodeTypeBox,
    MobNodeTypeDivider,
    MobNodeTypeSpacer,
    MobNodeTypeProgress,
    MobNodeTypeTextField,
    MobNodeTypeToggle,
    MobNodeTypeSlider,
    MobNodeTypeImage,
    MobNodeTypeLazyList,
    MobNodeTypeTabBar,
    MobNodeTypeVideo,
    MobNodeTypeCameraPreview,
    MobNodeTypeWebView,
    MobNodeTypeNativeView,
    MobNodeTypeIcon,
    MobNodeTypeCanvas,
    MobNodeTypeGpuView,
};

NS_ASSUME_NONNULL_BEGIN

@interface MobNode : NSObject

// Layout
@property(nonatomic) MobNodeType nodeType;
@property(nonatomic, strong, nullable) UIColor *backgroundColor;
@property(nonatomic) CGFloat padding;       // uniform; -1 if unset
@property(nonatomic) CGFloat paddingTop;    // -1 = use uniform padding
@property(nonatomic) CGFloat paddingRight;  // -1 = use uniform padding
@property(nonatomic) CGFloat paddingBottom; // -1 = use uniform padding
@property(nonatomic) CGFloat paddingLeft;   // -1 = use uniform padding

// Text / Button
@property(nonatomic, copy, nullable) NSString *text;
@property(nonatomic) CGFloat textSize;
@property(nonatomic, strong, nullable) UIColor *textColor;

// Tap
@property(nonatomic, copy, nullable) void (^onTap)(void);

// Value-bearing change callbacks (set by mob_nif.m; called by SwiftUI)
@property(nonatomic, copy, nullable) void (^onChangeStr)(NSString *);
@property(nonatomic, copy, nullable) void (^onChangeBool)(BOOL);
@property(nonatomic, copy, nullable) void (^onChangeFloat)(double);

// Selection (pickers, menus, segmented controls)
@property(nonatomic, copy, nullable) void (^onSelect)(void);

// Gestures (Batch 4) — set by mob_nif.m via tap-handle registration.
// SwiftUI side wires these through .onLongPressGesture, .gesture(TapGesture(count:2)),
// .gesture(DragGesture(...)). Each is opt-in (nil = no gesture recognizer).
@property(nonatomic, copy, nullable) void (^onLongPress)(void);
@property(nonatomic, copy, nullable) void (^onDoubleTap)(void);
@property(nonatomic, copy, nullable) void (^onSwipe)(NSString *direction);
@property(nonatomic, copy, nullable) void (^onSwipeLeft)(void);
@property(nonatomic, copy, nullable) void (^onSwipeRight)(void);
@property(nonatomic, copy, nullable) void (^onSwipeUp)(void);
@property(nonatomic, copy, nullable) void (^onSwipeDown)(void);

// ── Batch 5 Tier 1: high-frequency scroll/drag/pinch/rotate/pointer ──
// These callbacks are wired by mob_nif.m. Throttling and delta-thresholding
// happen native-side BEFORE invocation — by the time these fire, the BEAM
// crossing is already justified. Apps SHOULD NOT throttle in the closure.
//
// Scroll: SwiftUI .onScrollGeometryChange (iOS 17+) or UIScrollView delegate.
// (CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, CGFloat vx, CGFloat vy, NSString phase)
@property(nonatomic, copy, nullable) void (^onScroll)
    (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, NSString *);

// Drag: pan gesture deltas.
// (CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, NSString phase)
@property(nonatomic, copy, nullable) void (^onDrag)(CGFloat, CGFloat, CGFloat, CGFloat, NSString *);

// Pinch: scale + velocity. (CGFloat scale, CGFloat velocity, NSString phase)
@property(nonatomic, copy, nullable) void (^onPinch)(CGFloat, CGFloat, NSString *);

// Rotate: angle in degrees + velocity. (CGFloat degrees, CGFloat velocity, NSString phase)
@property(nonatomic, copy, nullable) void (^onRotate)(CGFloat, CGFloat, NSString *);

// Pointer move (iPad trackpad / Apple Pencil hover).
// (CGFloat x, CGFloat y)
@property(nonatomic, copy, nullable) void (^onPointerMove)(CGFloat, CGFloat);

// ── Batch 5 Tier 2: semantic scroll events (single-fire) ──
@property(nonatomic, copy, nullable) void (^onScrollBegan)(void);
@property(nonatomic, copy, nullable) void (^onScrollEnded)(void);
@property(nonatomic, copy, nullable) void (^onScrollSettled)(void);
@property(nonatomic, copy, nullable) void (^onTopReached)(void);
@property(nonatomic, copy, nullable) void (^onScrolledPast)(void);
@property(nonatomic) CGFloat scrolledPastThreshold; // y boundary

// ── Batch 5 Tier 3: native-side scroll-driven UI ──
// Each is a config dict (decoded from JSON). The SwiftUI view layer reads
// these and wires them up using .scrollPosition / .onScrollGeometryChange
// observers without going through the BEAM. nil = not configured.
@property(nonatomic, strong, nullable) NSDictionary *parallaxConfig;
@property(nonatomic, strong, nullable) NSDictionary *fadeOnScrollConfig;
@property(nonatomic, strong, nullable) NSDictionary *stickyWhenScrolledPastConfig;

// text_field
@property(nonatomic, copy, nullable) NSString *placeholder;
@property(nonatomic, copy, nonnull)
    NSString *keyboardTypeStr; // "default","number","decimal","email","phone","url"
@property(nonatomic, copy, nonnull) NSString *returnKeyStr; // "done","next","go","search","send"
@property(nonatomic, assign) BOOL isSecure;                 // mask input (SecureField on iOS)
@property(nonatomic, copy, nullable) void (^onFocus)(void);
@property(nonatomic, copy, nullable) void (^onBlur)(void);
@property(nonatomic, copy, nullable) void (^onSubmit)(void);
// IME composition (CJK, Korean, Vietnamese, accent input). Called by
// the iOS text-input layer when marked-text state changes.
//   text:  the in-progress (or committed) text
//   phase: "began" | "updating" | "committed" | "cancelled"
@property(nonatomic, copy, nullable) void (^onCompose)(NSString *text, NSString *phase);
// toggle
@property(nonatomic) BOOL checked;
// slider
@property(nonatomic) CGFloat minValue; // default 0.0
@property(nonatomic) CGFloat maxValue; // default 1.0

// Divider
@property(nonatomic) CGFloat thickness; // default 1.0

// Scroll
@property(nonatomic, copy, nonnull) NSString *axis; // "vertical" | "horizontal"
@property(nonatomic) BOOL showIndicator;            // default YES

// Row vertical alignment — "top" | "center" (default) | "bottom"
@property(nonatomic, copy, nonnull) NSString *rowAlign;

// Box content alignment — "top_leading" (default) | "center" | "top_center" |
// "bottom_leading" | "bottom_center" | "bottom_trailing" | "top_trailing".
// Affects how a box's children are placed within its frame; relevant when
// the box has explicit width/height larger than the children.
@property(nonatomic, copy, nonnull) NSString *boxAlign;

// Per-node offset applied as .offset(x:y:) on iOS / Modifier.offset on
// Compose. Useful for absolute positioning within an aligned box. Default 0.
@property(nonatomic) CGFloat offsetX;
@property(nonatomic) CGFloat offsetY;

// Spacer — fixedSize == 0 means fill available space
@property(nonatomic) CGFloat fixedSize;

// Progress — NaN means indeterminate
@property(nonatomic) CGFloat value;
@property(nonatomic, strong, nullable) UIColor *color; // track / indicator color

// Layout behaviour
@property(nonatomic) BOOL fillWidth; // fill parent width (default NO; button default YES)
@property(nonatomic)
    BOOL fillHeight; // fill parent height (default NO) — used for full-screen overlays/dialogs
@property(nonatomic) CGFloat cornerRadius; // rounded corners in pt (default 0)

// Border (currently honored on box). Both must be set for a border to draw.
@property(nonatomic, strong, nullable) UIColor *borderColor;
@property(nonatomic) CGFloat borderWidth; // pt; default 0 = no border

// Liquid Glass opt-in (set by Mob.Renderer when the active theme has
// `glass: true` AND the node has a `background:`). MobBox replaces the
// solid fill with `.glassEffect()` on iOS 26+, falling back to
// `.ultraThinMaterial` on iOS 17–25. The original `backgroundColor` is
// preserved so the swap can be undone at runtime by toggling the theme.
@property(nonatomic) BOOL useGlass;

// image
@property(nonatomic, copy, nullable) NSString *src;
@property(nonatomic, copy, nonnull) NSString *contentModeStr; // "fit" | "fill" | "stretch"
@property(nonatomic) CGFloat fixedWidth;                      // 0 = fill available
@property(nonatomic) CGFloat fixedHeight;                     // 0 = auto
@property(nonatomic, strong, nullable) UIColor *placeholderColor;

// Typography
@property(nonatomic, copy, nullable) NSString *fontFamily; // nil = system font
@property(nonatomic, copy, nonnull)
    NSString *fontWeight; // "regular","medium","semibold","bold","light","thin"
@property(nonatomic, copy, nonnull) NSString *textAlign; // "left","center","right"
@property(nonatomic) BOOL italic;
@property(nonatomic) CGFloat lineHeight; // multiplier; 0 = default
@property(nonatomic) CGFloat letterSpacing;

// Tab bar
@property(nonatomic, strong, nullable)
    NSArray *tabDefs; // array of NSDictionary, each with id/label/icon
@property(nonatomic, copy, nullable) NSString *activeTab; // selected tab id
@property(nonatomic, copy, nullable) void (^onTabSelect)(NSString *)
    ; // sends selected tab id as string

// Video player
@property(nonatomic) BOOL videoAutoplay;
@property(nonatomic) BOOL videoLoop;
@property(nonatomic) BOOL videoControls;

// Camera preview
@property(nonatomic, copy, nonnull) NSString *cameraFacing; // "back" | "front"

// WebView
@property(nonatomic, copy, nullable) NSString *webViewUrl;   // URL to load
@property(nonatomic, copy, nullable) NSString *webViewAllow; // comma-separated allowed URL prefixes
@property(nonatomic) BOOL webViewShowUrl;
@property(nonatomic, copy, nullable)
    NSString *webViewTitle; // static title label; overrides show_url

// NativeView — rendered by MobNativeViewRegistry
@property(nonatomic, copy, nullable)
    NSString *nativeViewModule; // registry key (e.g. "MyApp_ChartComponent")
@property(nonatomic, copy, nullable) NSString *nativeViewId; // user-assigned id
@property(nonatomic) int nativeViewHandle; // NIF component handle for event callbacks
@property(nonatomic, strong, nullable)
    NSDictionary *nativeViewProps; // full props dict forwarded to the factory

// Accessibility — set from the tap tag atom name; read by XCTest / ui_describe_all
@property(nonatomic, copy, nullable) NSString *accessibilityId;

// Icon — logical name resolved to an SF Symbol on iOS / Material Symbol
// on Android. textSize and textColor control glyph sizing + tint.
@property(nonatomic, copy, nullable) NSString *iconName;

// Canvas — declarative draw-op list from Mob.Canvas. Each entry is an
// NSDictionary with an "op" key (e.g. "line", "circle") and op-specific
// fields. Color values arrive pre-resolved (ARGB integers) from the
// renderer's encode_canvas_op/2.
@property(nonatomic, strong, nullable) NSArray *canvasOps;
@property(nonatomic) CGFloat canvasWidth;  // pt; required (>0)
@property(nonatomic) CGFloat canvasHeight; // pt; required (>0)

// GpuView — Metal shader source + per-frame uniforms. The native side
// compiles `gpuShaderMSL` into an MTLRenderPipelineState (cached by
// the source hash) and binds `gpuUniforms` to fragment buffer slot 0
// every frame. Shader compile errors surface as a translucent overlay
// on top of the view. See `Mob.UI.gpu_view/1` for the BEAM-side
// contract and the iOS-only / MSL-only scope.
@property(nonatomic, copy, nullable) NSString *gpuShaderMSL;
// May be an NSArray (preferred — ordered uniform list) or NSDictionary
// (legacy — iteration order undefined). See MobGpuView.swift for the
// expected packing semantics per element.
@property(nonatomic, strong, nullable) id gpuUniforms;

// Children
@property(nonatomic, strong, nonnull) NSMutableArray<MobNode *> *children;

@end

NS_ASSUME_NONNULL_END
