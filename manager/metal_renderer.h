//
//  metal_renderer.h
//

#ifndef metal_renderer_h
#define metal_renderer_h

#import <QuartzCore/QuartzCore.h>

void MetalRendererInit(void);
void MetalRendererDrawToLayer(CALayer *layer);

#endif /* metal_renderer_h */
