// MobNode.h — Data model node for the Mob UI tree (iOS SwiftUI layer).
// Created and mutated by mob_nif.m NIFs; read by MobRootView.swift for rendering.
// No BEAM headers here — kept clean for Swift import via bridging header.

#pragma once

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

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

// text_field
@property (nonatomic, copy, nullable) NSString* placeholder;
@property (nonatomic, copy, nonnull)  NSString* keyboardTypeStr;  // "default","number","decimal","email","phone","url"
@property (nonatomic, copy, nonnull)  NSString* returnKeyStr;     // "done","next","go","search","send"
@property (nonatomic, copy, nullable) void (^onFocus)(void);
@property (nonatomic, copy, nullable) void (^onBlur)(void);
@property (nonatomic, copy, nullable) void (^onSubmit)(void);
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

// image
@property (nonatomic, copy,   nullable) NSString*  src;
@property (nonatomic, copy,   nonnull)  NSString*  contentModeStr;   // "fit" | "fill" | "stretch"
@property (nonatomic)                  CGFloat    fixedWidth;        // 0 = fill available
@property (nonatomic)                  CGFloat    fixedHeight;       // 0 = auto
@property (nonatomic)                  CGFloat    cornerRadius;
@property (nonatomic, strong, nullable) UIColor*  placeholderColor;

// Children
@property (nonatomic, strong, nonnull) NSMutableArray<MobNode*>* children;

@end

NS_ASSUME_NONNULL_END
