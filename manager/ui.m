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

- (void)safeSetText:(NSString *)text {
    @synchronized(self) {
        [self setText:text];
    }
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

@implementation PVTextField

@synthesize text = _text;
@synthesize placeholder = _placeholder;
@synthesize textColor = _textColor;
@synthesize isFocused = _isFocused;
@synthesize onEnter = _onEnter;
@synthesize secureTextEntry = _secureTextEntry;

- (instancetype)init {
    self = [super init];
    if (self) {
        _text = [@"" copy];
        _placeholder = [@"" copy];
        _textColor = 0xFFFFFFFF;
        self.backgroundColor = 0x333333FF; // Dark gray background
        _isFocused = NO;
        _secureTextEntry = NO;
    }
    return self;
}

- (void)dealloc {
    [_text release];
    [_placeholder release];
    if (_onEnter) [ (id)_onEnter release];
    [super dealloc];
}

- (void)handleKeyDown:(uint16_t)keyCode character:(char)character {
    if (keyCode == 36) { // Return key
        if (_onEnter) {
            _onEnter(_text);
        }
        return;
    }
    
    if (keyCode == 51) { // Delete key
        if (_text.length > 0) {
            self.text = [_text substringToIndex:_text.length - 1];
        }
        return;
    }
    
    // Simple printable character check (very basic)
    if (character >= 32 && character <= 126) {
        self.text = [_text stringByAppendingFormat:@"%c", character];
    }
}

@end

@implementation PVScrollView

@synthesize contentOffset = _contentOffset;
@synthesize contentSize = _contentSize;

- (instancetype)init {
    self = [super init];
    if (self) {
        _contentOffset = CGPointZero;
        _contentSize = CGSizeZero;
        self.backgroundColor = 0x00000000; // Transparent by default
    }
    return self;
}

@end

@implementation PVImage

@synthesize imagePath = _imagePath;
@synthesize contentMode = _contentMode;

- (instancetype)init {
    self = [super init];
    if (self) {
        _imagePath = nil;
        _contentMode = PVContentModeScaleToFill; // Default to stretch
        self.backgroundColor = 0x00000000; // Transparent
    }
    return self;
}

- (void)dealloc {
    [_imagePath release];
    [super dealloc];
}

- (void)setImagePath:(NSString *)imagePath {
    if (_imagePath != imagePath) {
        [_imagePath release];
        _imagePath = [imagePath copy];
    }
}

- (NSString *)imagePath {
    return _imagePath;
}

@end