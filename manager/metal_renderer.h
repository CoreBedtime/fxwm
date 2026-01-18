//
//  metal_renderer.h
//

#ifndef metal_renderer_h
#define metal_renderer_h

#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import "ui.h"

// Renders the view hierarchy starting from rootView into the layer
void MetalRendererRender(PVView *rootView, CALayer *layer);

// Updates view state based on mouse interaction (hover, click)
void MetalRendererHandleMouse(PVView *rootView, CGPoint position, bool isDown);

// Updates scroll views based on scroll wheel interaction
void MetalRendererHandleScroll(PVView *rootView, CGPoint position, double deltaX, double deltaY);

#endif /* metal_renderer_h */