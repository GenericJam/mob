// MobNode.m — Mob UI tree node implementation.

#import "MobNode.h"
#import <math.h>

@implementation MobNode

- (instancetype)init {
    if ((self = [super init])) {
        _textSize      = 14.0;
        _padding       = 0.0;
        _paddingTop    = -1.0;
        _paddingRight  = -1.0;
        _paddingBottom = -1.0;
        _paddingLeft   = -1.0;
        _fontWeight    = @"regular";
        _textAlign     = @"left";
        _italic        = NO;
        _lineHeight    = 0.0;
        _letterSpacing = 0.0;
        _thickness     = 1.0;
        _fixedSize     = 0.0;
        _value         = NAN;   // NaN = indeterminate (progress) or not-yet-set (slider)
        _minValue      = 0.0;
        _maxValue      = 1.0;
        _checked       = NO;
        _axis            = @"vertical";
        _showIndicator   = YES;
        _rowAlign        = @"center";
        _keyboardTypeStr = @"default";
        _returnKeyStr    = @"done";
        _contentModeStr  = @"fit";
        _fixedWidth      = 0.0;
        _fixedHeight     = 0.0;
        _fillWidth       = NO;
        _cornerRadius    = 0.0;
        _videoAutoplay = NO;
        _videoLoop     = NO;
        _videoControls = YES;
        _children      = [NSMutableArray array];
    }
    return self;
}

@end
