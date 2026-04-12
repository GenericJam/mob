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
};

NS_ASSUME_NONNULL_BEGIN

@interface MobNode : NSObject

@property (nonatomic) MobNodeType               nodeType;
@property (nonatomic, copy,   nullable) NSString* text;
@property (nonatomic)                   CGFloat   textSize;
@property (nonatomic, strong, nullable) UIColor*  textColor;
@property (nonatomic, strong, nullable) UIColor*  backgroundColor;
@property (nonatomic)                   CGFloat   padding;
@property (nonatomic, strong, nonnull)  NSMutableArray<MobNode*>* children;
@property (nonatomic, copy,   nullable) void (^onTap)(void);

@end

NS_ASSUME_NONNULL_END
