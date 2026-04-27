// MobNode.h — Data model node for the Mob UI tree (iOS SwiftUI layer).
// Created and mutated by mob_nif.m NIFs; read by MobRootView.swift for rendering.
// No BEAM headers here — kept clean for Swift import via bridging header.

#pragma once

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>

// Shared camera preview session — set by nif_camera_start/stop_preview, read by MobRootView.
extern AVCaptureSession* _Nullable g_preview_session;

// Shared WebView — set by MobWebView when created, read by webview NIFs.
extern WKWebView* _Nullable g_webview;

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
};

NS_ASSUME_NONNULL_BEGIN

@interface MobNode : NSObject

// Layout
@property (nonatomic) MobNodeType               nodeType;
@property (nonatomic, strong, nullable) UIColor* backgroundColor;
@property (nonatomic)                  CGFloat   padding;           // uniform; -1 if unset
@property (nonatomic)                  CGFloat   paddingTop;        // -1 = use uniform padding
@property (nonatomic)                  CGFloat   paddingRight;      // -1 = use uniform padding
@property (nonatomic)                  CGFloat   paddingBottom;     // -1 = use uniform padding
@property (nonatomic)                  CGFloat   paddingLeft;       // -1 = use uniform padding

// Text / Button
@property (nonatomic, copy,   nullable) NSString* text;
@property (nonatomic)                  CGFloat    textSize;
@property (nonatomic, strong, nullable) UIColor*  textColor;

// Tap
@property (nonatomic, copy, nullable) void (^onTap)(void);

// Value-bearing change callbacks (set by mob_nif.m; called by SwiftUI)
@property (nonatomic, copy, nullable) void (^onChangeStr)(NSString*);
@property (nonatomic, copy, nullable) void (^onChangeBool)(BOOL);
@property (nonatomic, copy, nullable) void (^onChangeFloat)(double);

// Selection (pickers, menus, segmented controls)
@property (nonatomic, copy, nullable) void (^onSelect)(void);

// Gestures (Batch 4) — set by mob_nif.m via tap-handle registration.
// SwiftUI side wires these through .onLongPressGesture, .gesture(TapGesture(count:2)),
// .gesture(DragGesture(...)). Each is opt-in (nil = no gesture recognizer).
@property (nonatomic, copy, nullable) void (^onLongPress)(void);
@property (nonatomic, copy, nullable) void (^onDoubleTap)(void);
@property (nonatomic, copy, nullable) void (^onSwipe)(NSString* direction);
@property (nonatomic, copy, nullable) void (^onSwipeLeft)(void);
@property (nonatomic, copy, nullable) void (^onSwipeRight)(void);
@property (nonatomic, copy, nullable) void (^onSwipeUp)(void);
@property (nonatomic, copy, nullable) void (^onSwipeDown)(void);

// ── Batch 5 Tier 1: high-frequency scroll/drag/pinch/rotate/pointer ──
// These callbacks are wired by mob_nif.m. Throttling and delta-thresholding
// happen native-side BEFORE invocation — by the time these fire, the BEAM
// crossing is already justified. Apps SHOULD NOT throttle in the closure.
//
// Scroll: SwiftUI .onScrollGeometryChange (iOS 17+) or UIScrollView delegate.
// (CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, CGFloat vx, CGFloat vy, NSString phase)
@property (nonatomic, copy, nullable) void (^onScroll)(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, NSString*);

// Drag: pan gesture deltas.
// (CGFloat dx, CGFloat dy, CGFloat x, CGFloat y, NSString phase)
@property (nonatomic, copy, nullable) void (^onDrag)(CGFloat, CGFloat, CGFloat, CGFloat, NSString*);

// Pinch: scale + velocity. (CGFloat scale, CGFloat velocity, NSString phase)
@property (nonatomic, copy, nullable) void (^onPinch)(CGFloat, CGFloat, NSString*);

// Rotate: angle in degrees + velocity. (CGFloat degrees, CGFloat velocity, NSString phase)
@property (nonatomic, copy, nullable) void (^onRotate)(CGFloat, CGFloat, NSString*);

// Pointer move (iPad trackpad / Apple Pencil hover).
// (CGFloat x, CGFloat y)
@property (nonatomic, copy, nullable) void (^onPointerMove)(CGFloat, CGFloat);

// ── Batch 5 Tier 2: semantic scroll events (single-fire) ──
@property (nonatomic, copy, nullable) void (^onScrollBegan)(void);
@property (nonatomic, copy, nullable) void (^onScrollEnded)(void);
@property (nonatomic, copy, nullable) void (^onScrollSettled)(void);
@property (nonatomic, copy, nullable) void (^onTopReached)(void);
@property (nonatomic, copy, nullable) void (^onScrolledPast)(void);
@property (nonatomic) CGFloat scrolledPastThreshold;     // y boundary

// ── Batch 5 Tier 3: native-side scroll-driven UI ──
// Each is a config dict (decoded from JSON). The SwiftUI view layer reads
// these and wires them up using .scrollPosition / .onScrollGeometryChange
// observers without going through the BEAM. nil = not configured.
@property (nonatomic, strong, nullable) NSDictionary* parallaxConfig;
@property (nonatomic, strong, nullable) NSDictionary* fadeOnScrollConfig;
@property (nonatomic, strong, nullable) NSDictionary* stickyWhenScrolledPastConfig;

// text_field
@property (nonatomic, copy, nullable) NSString* placeholder;
@property (nonatomic, copy, nonnull)  NSString* keyboardTypeStr;  // "default","number","decimal","email","phone","url"
@property (nonatomic, copy, nonnull)  NSString* returnKeyStr;     // "done","next","go","search","send"
@property (nonatomic, copy, nullable) void (^onFocus)(void);
@property (nonatomic, copy, nullable) void (^onBlur)(void);
@property (nonatomic, copy, nullable) void (^onSubmit)(void);
// IME composition (CJK, Korean, Vietnamese, accent input). Called by
// the iOS text-input layer when marked-text state changes.
//   text:  the in-progress (or committed) text
//   phase: "began" | "updating" | "committed" | "cancelled"
@property (nonatomic, copy, nullable) void (^onCompose)(NSString* text, NSString* phase);
// toggle
@property (nonatomic) BOOL checked;
// slider
@property (nonatomic) CGFloat minValue;   // default 0.0
@property (nonatomic) CGFloat maxValue;   // default 1.0

// Divider
@property (nonatomic)                  CGFloat    thickness;   // default 1.0

// Scroll
@property (nonatomic, copy, nonnull)   NSString*  axis;          // "vertical" | "horizontal"
@property (nonatomic)                  BOOL       showIndicator; // default YES

// Spacer — fixedSize == 0 means fill available space
@property (nonatomic)                  CGFloat    fixedSize;

// Progress — NaN means indeterminate
@property (nonatomic)                  CGFloat    value;
@property (nonatomic, strong, nullable) UIColor*  color;       // track / indicator color

// Layout behaviour
@property (nonatomic) BOOL    fillWidth;    // fill parent width (default NO; button default YES)
@property (nonatomic) CGFloat cornerRadius; // rounded corners in pt (default 0)

// image
@property (nonatomic, copy,   nullable) NSString*  src;
@property (nonatomic, copy,   nonnull)  NSString*  contentModeStr;   // "fit" | "fill" | "stretch"
@property (nonatomic)                  CGFloat    fixedWidth;        // 0 = fill available
@property (nonatomic)                  CGFloat    fixedHeight;       // 0 = auto
@property (nonatomic, strong, nullable) UIColor*  placeholderColor;

// Typography
@property (nonatomic, copy, nullable) NSString* fontFamily;    // nil = system font
@property (nonatomic, copy, nonnull)  NSString* fontWeight;   // "regular","medium","semibold","bold","light","thin"
@property (nonatomic, copy, nonnull)  NSString* textAlign;    // "left","center","right"
@property (nonatomic)                 BOOL      italic;
@property (nonatomic)                 CGFloat   lineHeight;   // multiplier; 0 = default
@property (nonatomic)                 CGFloat   letterSpacing;

// Tab bar
@property (nonatomic, strong, nullable) NSArray*         tabDefs;       // array of NSDictionary, each with id/label/icon
@property (nonatomic, copy,   nullable) NSString*        activeTab;     // selected tab id
@property (nonatomic, copy,   nullable) void (^onTabSelect)(NSString*); // sends selected tab id as string

// Video player
@property (nonatomic) BOOL videoAutoplay;
@property (nonatomic) BOOL videoLoop;
@property (nonatomic) BOOL videoControls;

// Camera preview
@property (nonatomic, copy, nonnull) NSString* cameraFacing;  // "back" | "front"

// WebView
@property (nonatomic, copy, nullable) NSString* webViewUrl;    // URL to load
@property (nonatomic, copy, nullable) NSString* webViewAllow;  // comma-separated allowed URL prefixes
@property (nonatomic)                 BOOL       webViewShowUrl;
@property (nonatomic, copy, nullable) NSString*  webViewTitle; // static title label; overrides show_url

// NativeView — rendered by MobNativeViewRegistry
@property (nonatomic, copy, nullable) NSString*     nativeViewModule;  // registry key (e.g. "MyApp_ChartComponent")
@property (nonatomic, copy, nullable) NSString*     nativeViewId;      // user-assigned id
@property (nonatomic)                 int            nativeViewHandle;  // NIF component handle for event callbacks
@property (nonatomic, strong, nullable) NSDictionary* nativeViewProps;  // full props dict forwarded to the factory

// Accessibility — set from the tap tag atom name; read by XCTest / ui_describe_all
@property (nonatomic, copy, nullable) NSString* accessibilityId;

// Children
@property (nonatomic, strong, nonnull) NSMutableArray<MobNode*>* children;

@end

NS_ASSUME_NONNULL_END
