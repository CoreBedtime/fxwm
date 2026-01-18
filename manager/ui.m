//
//  ui.m
//

#import "ui.h"

@implementation PVView

@synthesize frame = _frame;
@synthesize superview = _superview;

- (instancetype)init {
    self = [super init];
    if (self) {
        _internalSubviews = [[NSMutableArray alloc] init];
        _backgroundColor = 0xFFFFFFFF; // White
        _onRender = nil;
    }
    return self;
}

- (void)dealloc {
    [_internalSubviews release];
    if (_onRender) [ (id)_onRender release];
    [super dealloc];
}

- (void)setOnRender:(void (^)(PVView *))onRender {
    if (_onRender != onRender) {
        if (_onRender) [ (id)_onRender release];
        _onRender = [onRender copy];
    }
}

- (void (^)(PVView *))onRender {
    return _onRender;
}

- (NSArray *)subviews {
    return _internalSubviews;
}

- (void)setBackgroundColor:(uint32_t)backgroundColor {
    _backgroundColor = backgroundColor;
}

- (uint32_t)backgroundColor {
    return _backgroundColor;
}

- (void)addSubview:(PVView *)view {
    if (!view) return;
    if (view.superview) {
        [view removeFromSuperview];
    }
    [_internalSubviews addObject:view];
    view.superview = self;
}

- (void)removeFromSuperview {
    if (_superview) {
        [[_superview internalSubviews] removeObject:self];
        _superview = nil;
    }
}

- (NSMutableArray *)internalSubviews {
    return _internalSubviews;
}

@end

@implementation PVLabel

@synthesize textColor = _textColor;

- (instancetype)init {
    self = [super init];
    if (self) {
        _textColor = 0xFFFFFFFF; // White default
        self.backgroundColor = 0x00000000; // Clear
    }
    return self;
}

- (void)dealloc {
    [_text release];
    [super dealloc];
}

- (void)setText:(NSString *)text {
    if (_text != text) {
        [_text release];
        _text = [text copy];
    }
}

- (NSString *)text {
    return _text;
}

@end

@implementation PVButton

@synthesize textColor = _textColor;
@synthesize isHovering = _isHovering;
@synthesize isDown = _isDown;

- (instancetype)init {
    self = [super init];
    if (self) {
        _textColor = 0xFFFFFFFF; // White default
        self.backgroundColor = 0x0078D7FF; // Blue
    }
    return self;
}

- (void)dealloc {
    [_title release];
    if (_onClick) [ (id)_onClick release];
    [super dealloc];
}

- (void)setTitle:(NSString *)title {
    if (_title != title) {
        [_title release];
        _title = [title copy];
    }
}

- (NSString *)title {
    return _title;
}

- (void)setOnClick:(void (^)(void))onClick {
    if (_onClick != onClick) {
        if (_onClick) [ (id)_onClick release];
        _onClick = [onClick copy];
    }
}

- (void (^)(void))onClick {
    return _onClick;
}

@end