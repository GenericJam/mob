// MobNode.m — Mob UI tree node implementation.

#import "MobNode.h"
#import <math.h>

@implementation MobNode

- (instancetype)init {
    if ((self = [super init])) {
        _textSize      = 14.0;
        _padding       = 0.0;
        _thickness     = 1.0;
        _fixedSize     = 0.0;
        _value         = NAN;   // NaN = indeterminate (progress) or not-yet-set (slider)
        _minValue      = 0.0;
        _maxValue      = 1.0;
        _checked       = NO;
        _axis            = @"vertical";
        _showIndicator   = YES;
        _keyboardTypeStr = @"default";
        _returnKeyStr    = @"done";
        _contentModeStr  = @"fit";
        _fixedWidth      = 0.0;
        _fixedHeight     = 0.0;
        _cornerRadius    = 0.0;
        _children      = [NSMutableArray array];
    }
    return self;
}

@end
