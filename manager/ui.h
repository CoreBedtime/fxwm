//
//  ui.h
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <stdint.h>

@interface PVView : NSObject {
    NSMutableArray *_internalSubviews;
    uint32_t _backgroundColor;
    PVView *_superview;
    void (^_onRender)(PVView *view);
}

@property (nonatomic, assign) CGRect frame;
@property (nonatomic, assign) uint32_t backgroundColor;
@property (nonatomic, readonly) NSArray *subviews;
@property (nonatomic, assign) PVView *superview;
@property (nonatomic, copy) void (^onRender)(PVView *view);

- (void)addSubview:(PVView *)view;
- (void)removeFromSuperview;
@end

@interface PVLabel : PVView {
    NSString *_text;
    uint32_t _textColor;
}

@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) uint32_t textColor;
@end

@interface PVButton : PVView {
    NSString *_title;
    uint32_t _textColor;
    void (^_onClick)(void);
}

@property (nonatomic, copy) NSString *title;
@property (nonatomic, assign) uint32_t textColor;
@property (nonatomic, assign) BOOL isHovering;
@property (nonatomic, assign) BOOL isDown;
@property (nonatomic, copy) void (^onClick)(void);
@end