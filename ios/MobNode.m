// MobNode.m — Mob UI tree node implementation.

#import "MobNode.h"

@implementation MobNode

- (instancetype)init {
    if ((self = [super init])) {
        _textSize = 14.0;
        _padding  = 0.0;
        _children = [NSMutableArray array];
    }
    return self;
}

@end
