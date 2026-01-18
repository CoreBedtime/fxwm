//
//  metal_renderer.m
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

#import "metal_renderer.h"
#import "iso_font.h"

// Uniforms for rendering
typedef struct {
    float scale[2];     // Scale factor for NDC mapping
    float offset[2];    // Position offset in NDC
    float color[4];     // RGBA color
} Uniforms;

typedef struct {
    float position[2];
    float texCoord[2];
} TextVertex;

// Metal rendering objects
static id<MTLDevice> gMetalDevice = nil;
static id<MTLCommandQueue> gMetalCommandQueue = nil;
static id<MTLRenderPipelineState> gMetalPipeline = nil;     // For solid color quads
static id<MTLRenderPipelineState> gMetalTextPipeline = nil; // For text
static id<MTLBuffer> gMetalVertexBuffer = nil;              // For solid color quads (shared)
static id<MTLTexture> gMetalFontTexture = nil;
static CAMetalLayer *gMetalSublayer = nil;

void MetalRendererInit(void) {
    if (gMetalDevice) return;

    gMetalDevice = MTLCopyAllDevices()[0];
    if (!gMetalDevice) {
        NSLog(@"Failed to create Metal device");
        return;
    }

    gMetalCommandQueue = [gMetalDevice newCommandQueue];
    if (!gMetalCommandQueue) {
        NSLog(@"Failed to create Metal command queue");
        return;
    }

    // ------------------------------------------------------------------------
    // Shaders
    // ------------------------------------------------------------------------
    NSString *shaderSource = @"using namespace metal;\n"
        "struct VertexIn {\n"
        "    float2 position [[attribute(0)]];\n"
        "};\n"
        "struct VertexOut {\n"
        "    float4 position [[position]];\n"
        "    float4 color;\n"
        "};\n"
        "struct Uniforms {\n"
        "    float2 scale;\n"
        "    float2 offset;\n"
        "    float4 color;\n"
        "};\n"
        // Solid Color Vertex Shader
        "vertex VertexOut vertex_main(VertexIn in [[stage_in]],\n"
        "                             constant Uniforms &uniforms [[buffer(1)]]) {\n"
        "    VertexOut out;\n"
        "    out.position = float4(in.position * uniforms.scale + uniforms.offset, 0.0, 1.0);\n"
        "    out.color = uniforms.color;\n"
        "    return out;\n"
        "}\n"
        // Solid Color Fragment Shader
        "fragment float4 fragment_main(VertexOut in [[stage_in]]) {\n"
        "    return in.color;\n"
        "}\n"
        "\n"
        // Text Structures
        "struct TextVertexIn {\n"
        "    float2 position [[attribute(0)]];\n"
        "    float2 texCoord [[attribute(1)]];\n"
        "};\n"
        "struct TextVertexOut {\n"
        "    float4 position [[position]];\n"
        "    float2 texCoord [[user(texcoord)]];\n"
        "};\n"
        // Text Vertex Shader
        "vertex TextVertexOut vertex_text(TextVertexIn in [[stage_in]],\n"
        "                                 constant Uniforms &uniforms [[buffer(1)]]) {\n"
        "    TextVertexOut out;\n"
        "    // Position is already in NDC or pixels? We use the same uniform system.\n"
        "    out.position = float4(in.position * uniforms.scale + uniforms.offset, 0.0, 1.0);\n"
        "    out.texCoord = in.texCoord;\n"
        "    return out;\n"
        "}\n"
        // Text Fragment Shader
        "fragment float4 fragment_text(TextVertexOut in [[stage_in]],\n"
        "                              texture2d<float> fontTexture [[texture(0)]],\n"
        "                              constant Uniforms &uniforms [[buffer(1)]]) {\n"
        "    constexpr sampler textureSampler (mag_filter::nearest, min_filter::nearest);\n"
        "    float alpha = fontTexture.sample(textureSampler, in.texCoord).r;\n"
        "    if (alpha < 0.5) discard_fragment();\n"
        "    return float4(uniforms.color.rgb, uniforms.color.a * alpha);\n"
        "}\n";

    NSError *error = nil;
    id<MTLLibrary> library = [gMetalDevice newLibraryWithSource:shaderSource options:nil error:&error];
    if (error) {
        NSLog(@"Failed to create Metal library: %@", error);
        return;
    }

    // ------------------------------------------------------------------------
    // Solid Color Pipeline
    // ------------------------------------------------------------------------
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragment_main"];

    float vertices[] = {
        -1.0f, -1.0f,  1.0f, -1.0f, -1.0f,  1.0f,
         1.0f, -1.0f,  1.0f,  1.0f, -1.0f,  1.0f,
    };
    gMetalVertexBuffer = [gMetalDevice newBufferWithBytes:vertices
                                                   length:sizeof(vertices)
                                                  options:MTLResourceStorageModeShared];

    MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.layouts[0].stride = 2 * sizeof(float);
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.vertexDescriptor = vertexDescriptor;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
    pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    gMetalPipeline = [gMetalDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (error) {
        NSLog(@"Failed to create Metal pipeline: %@", error);
        return;
    }

    // ------------------------------------------------------------------------
    // Text Pipeline
    // ------------------------------------------------------------------------
    id<MTLFunction> textVertexFn = [library newFunctionWithName:@"vertex_text"];
    id<MTLFunction> textFragmentFn = [library newFunctionWithName:@"fragment_text"];

    MTLVertexDescriptor *textVertexDesc = [[MTLVertexDescriptor alloc] init];
    textVertexDesc.attributes[0].format = MTLVertexFormatFloat2; // Position
    textVertexDesc.attributes[0].offset = offsetof(TextVertex, position);
    textVertexDesc.attributes[0].bufferIndex = 0;
    textVertexDesc.attributes[1].format = MTLVertexFormatFloat2; // TexCoord
    textVertexDesc.attributes[1].offset = offsetof(TextVertex, texCoord);
    textVertexDesc.attributes[1].bufferIndex = 0;
    textVertexDesc.layouts[0].stride = sizeof(TextVertex);
    textVertexDesc.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    MTLRenderPipelineDescriptor *textPipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    textPipelineDesc.vertexFunction = textVertexFn;
    textPipelineDesc.fragmentFunction = textFragmentFn;
    textPipelineDesc.vertexDescriptor = textVertexDesc;
    textPipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    textPipelineDesc.colorAttachments[0].blendingEnabled = YES;
    textPipelineDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    textPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    textPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

    gMetalTextPipeline = [gMetalDevice newRenderPipelineStateWithDescriptor:textPipelineDesc error:&error];
    if (error) {
        NSLog(@"Failed to create Metal text pipeline: %@", error);
        return;
    }
    
    // ------------------------------------------------------------------------
    // Font Texture
    // ------------------------------------------------------------------------
    if (!gMetalFontTexture) {
        MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
        textureDescriptor.pixelFormat = MTLPixelFormatR8Unorm;
        textureDescriptor.width = 2048;
        textureDescriptor.height = 16;
        gMetalFontTexture = [gMetalDevice newTextureWithDescriptor:textureDescriptor];
        
        uint8_t *pixelData = (uint8_t *)malloc(2048 * 16);
        for (int c = 0; c < 256; c++) {
            for (int y = 0; y < 16; y++) {
                uint8_t row = iso_font[c * 16 + y];
                for (int x = 0; x < 8; x++) {
                    // Font data: bit 0 is left-most
                    bool on = (row >> x) & 1;
                    pixelData[y * 2048 + (c * 8) + x] = on ? 255 : 0;
                }
            }
        }
        
        [gMetalFontTexture replaceRegion:MTLRegionMake2D(0, 0, 2048, 16)
                             mipmapLevel:0
                               withBytes:pixelData
                             bytesPerRow:2048];
        free(pixelData);
        [textureDescriptor release];
    }

    NSLog(@"Metal Renderer initialized");
}

// Draw text string at specific location
void DrawText(id<MTLRenderCommandEncoder> renderEncoder, NSString *text, CGPoint origin, CGSize screenSize, float r, float g, float b, float a) {
    if (!text || text.length == 0) return;
    
    NSUInteger len = text.length;
    TextVertex *vertices = malloc(sizeof(TextVertex) * len * 6);
    const char *cStr = [text UTF8String];
    
    float x = 0;
    float y = 0; // Relative to origin
    
    int vIndex = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)cStr[i];
        
        // Quad geometry
        float w = 8.0f;
        float h = 16.0f;
        
        // Texture coords
        // Atlas width 2048. Char width 8.
        float u0 = (c * 8.0f) / 2048.0f;
        float u1 = ((c + 1) * 8.0f) / 2048.0f;
        float v0 = 0.0f;
        float v1 = 1.0f;
        
        // Pos relative to origin (top-left)
        // Vertices: BL, BR, TL, BR, TR, TL
        // Metal Y: up is positive?
        // Wait, in my vertex shader, I use uniforms.offset to position.
        // My uniform setup logic in DrawViewRecursively maps input frame to NDC.
        // If I reuse that logic here, I can pass text position as relative to window.
        
        // Let's create vertices in "pixels relative to start of string"
        // And then apply uniforms for the whole string block.
        // Or better: generate vertices in "pixels relative to view/window".
        
        float px = x + origin.x;
        float py = y + origin.y;
        
        // In my current setup (DrawViewRecursively):
        // Frame origin Y is top-left.
        // NDC Y is calculated as: 1.0 - (centerY / screenH) * 2.0.
        // This implies screen coordinate 0 is top.
        
        // Vertices (x, y)
        // BL: px, py + h
        // BR: px + w, py + h
        // TL: px, py
        // TR: px + w, py
        
        // Note on NDC:
        // If I pass these pixel coords to shader, I need to know how shader interprets them.
        // Shader: pos * scale + offset.
        // If I set scale to (2/w, -2/h) and offset to (-1, 1), then pixels (0,0) -> (-1, 1) (TL).
        // Pixels (w, h) -> (1, -1) (BR).
        
        // Let's configure uniforms for "Pixel Coordinates" once for the text draw call.
        // Scale = (2.0 / ScreenW, -2.0 / ScreenH)
        // Offset = (-1.0, 1.0)
        // Input Vertex Position = Absolute Pixel Position (x, y).
        
        // Triangle 1
        vertices[vIndex++] = (TextVertex){{px, py + h},      {u0, v1}}; // BL
        vertices[vIndex++] = (TextVertex){{px + w, py + h},  {u1, v1}}; // BR
        vertices[vIndex++] = (TextVertex){{px, py},          {u0, v0}}; // TL
        
        // Triangle 2
        vertices[vIndex++] = (TextVertex){{px + w, py + h},  {u1, v1}}; // BR
        vertices[vIndex++] = (TextVertex){{px + w, py},      {u1, v0}}; // TR
        vertices[vIndex++] = (TextVertex){{px, py},          {u0, v0}}; // TL
        
        x += 8.0f;
    }
    
    // Set Text Pipeline
    [renderEncoder setRenderPipelineState:gMetalTextPipeline];
    [renderEncoder setFragmentTexture:gMetalFontTexture atIndex:0];
    
    // Set Uniforms for Pixel Space
    Uniforms uniforms;
    uniforms.scale[0] = 2.0f / screenSize.width;
    uniforms.scale[1] = -2.0f / screenSize.height; // Flip Y
    uniforms.offset[0] = -1.0f;
    uniforms.offset[1] = 1.0f;
    uniforms.color[0] = r;
    uniforms.color[1] = g;
    uniforms.color[2] = b;
    uniforms.color[3] = a;
    
    [renderEncoder setVertexBytes:&uniforms length:sizeof(Uniforms) atIndex:1];
    [renderEncoder setFragmentBytes:&uniforms length:sizeof(Uniforms) atIndex:1];
    
    // Draw
    [renderEncoder setVertexBytes:vertices length:sizeof(TextVertex) * len * 6 atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:len * 6];
    
    free(vertices);
    
    // Restore Solid Pipeline (for subsequent views)
    [renderEncoder setRenderPipelineState:gMetalPipeline];
    [renderEncoder setVertexBuffer:gMetalVertexBuffer offset:0 atIndex:0];
}

void DrawViewRecursively(PVView *view, id<MTLRenderCommandEncoder> renderEncoder, CGSize screenSize, CGPoint parentOrigin) {
    if (screenSize.width <= 0 || screenSize.height <= 0) return;

    if (view.onRender) {
        view.onRender(view);
    }

    // Calculate Absolute Frame
    CGRect frame = view.frame;
    frame.origin.x += parentOrigin.x;
    frame.origin.y += parentOrigin.y;
    
    // Scale for NDC
    float scaleX = frame.size.width / screenSize.width;
    float scaleY = frame.size.height / screenSize.height;
    
    // Offset for NDC (Top-Left origin assumption for UI)
    float centerX = frame.origin.x + frame.size.width / 2.0;
    float centerY = frame.origin.y + frame.size.height / 2.0;
    
    float ndcX = (centerX / screenSize.width) * 2.0 - 1.0;
    float ndcY = 1.0 - (centerY / screenSize.height) * 2.0;
    
    Uniforms uniforms;
    uniforms.scale[0] = scaleX;
    uniforms.scale[1] = scaleY;
    uniforms.offset[0] = ndcX;
    uniforms.offset[1] = ndcY;
    
    // Color
    uint32_t bg = view.backgroundColor;
    float r = ((bg >> 24) & 0xFF) / 255.0f;
    float g = ((bg >> 16) & 0xFF) / 255.0f;
    float b = ((bg >> 8) & 0xFF) / 255.0f;
    float a = (bg & 0xFF) / 255.0f;
    
    if ([view isKindOfClass:[PVButton class]]) {
        PVButton *btn = (PVButton *)view;
        if (btn.isDown) {
            r *= 0.6; g *= 0.6; b *= 0.6;
        } else if (btn.isHovering) {
            r *= 1.2; g *= 1.2; b *= 1.2;
        }
        r = fminf(r, 1.0); g = fminf(g, 1.0); b = fminf(b, 1.0);
    }
    
    uniforms.color[0] = r;
    uniforms.color[1] = g;
    uniforms.color[2] = b;
    uniforms.color[3] = a;
    
    [renderEncoder setVertexBytes:&uniforms length:sizeof(Uniforms) atIndex:1];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    
    // Draw Text
    NSString *text = nil;
    uint32_t color = 0xFFFFFFFF;
    
    if ([view isKindOfClass:[PVButton class]]) {
        text = ((PVButton *)view).title;
        color = ((PVButton *)view).textColor;
    } else if ([view isKindOfClass:[PVLabel class]]) {
        text = ((PVLabel *)view).text;
        color = ((PVLabel *)view).textColor;
    } else if ([view isKindOfClass:[PVTextField class]]) {
        PVTextField *tf = (PVTextField *)view;
        text = tf.text;
        if (text.length == 0) {
            text = tf.placeholder;
            color = 0xAAAAAAFF; // Grey placeholder
        } else {
            color = tf.textColor;
        }
        
        // Draw Cursor if focused
        if (tf.isFocused) {
            float cursorX = frame.origin.x + 4 + (tf.text.length * 8.0f);
            float cursorY = frame.origin.y + (frame.size.height - 16.0f) / 2.0f;
            float cursorW = 2.0f;
            float cursorH = 16.0f;
            
            // We need to draw a solid rect for cursor.
            // But we are in "Solid Pipeline" mode or "Text Pipeline" mode?
            // Currently DrawText switches pipelines.
            // Let's just draw the cursor text "|" or use a solid quad.
            // Using a solid quad requires setting up vertices and switching pipeline back if we were in text mode.
            // But we are currently in solid mode (before DrawText call).
            
            // Let's draw cursor as a pipe character for simplicity for now, or just a quad.
            // Actually, let's defer cursor drawing to be part of the text drawing or just draw it after.
            
            // To keep it simple: Draw a "|" character at the end.
            // But that depends on font.
            // Let's try drawing a solid quad.
            
            // Need to generate vertices for cursor.
            // ... (Skipping complex cursor logic for this step, just appending | to text if focused?)
            // No, changing text is bad.
            
            // Let's just draw it.
            // We need to switch to solid pipeline if we were in text pipeline? 
            // DrawViewRecursively is called. It sets solid pipeline.
            // Then it draws background.
            // Then it calls DrawText which sets text pipeline.
            // So if we want to draw cursor, we should do it BEFORE DrawText or switch back.
            // DrawText switches back to solid pipeline at the end!
            
            // So we can draw cursor after DrawText.
            // But wait, DrawViewRecursively logic:
            // 1. Set uniforms for background quad.
            // 2. Draw background quad.
            // 3. Draw Text (switches to text, then back to solid).
            
            // So we can draw cursor here (before text) or after.
            // Let's draw it after text to be safe/lazy? 
            // Actually, let's just append a pipe if focused and we are typing?
            // No, let's do it properly later. For now, let's just render the text.
        }
    }
    
    if (text && text.length > 0) {
        float r = ((color >> 24) & 0xFF) / 255.0f;
        float g = ((color >> 16) & 0xFF) / 255.0f;
        float b = ((color >> 8) & 0xFF) / 255.0f;
        float a = (color & 0xFF) / 255.0f;
        
        // Center text for Buttons, Left align for others?
        float tx, ty;
        
        if ([view isKindOfClass:[PVButton class]]) {
            float textW = text.length * 8.0f;
            float textH = 16.0f;
            tx = frame.origin.x + (frame.size.width - textW) / 2.0f;
            ty = frame.origin.y + (frame.size.height - textH) / 2.0f;
        } else if ([view isKindOfClass:[PVTextField class]]) {
             // Left align with padding
            tx = frame.origin.x + 4.0f;
            ty = frame.origin.y + (frame.size.height - 16.0f) / 2.0f;
        } else {
             // Left align
            tx = frame.origin.x;
            ty = frame.origin.y + (frame.size.height - 16.0f) / 2.0f;
        }
        
        DrawText(renderEncoder, text, CGPointMake(tx, ty), screenSize, r, g, b, a);
    }
    
    // Draw Cursor for TextField (Simple Quad)
    if ([view isKindOfClass:[PVTextField class]] && ((PVTextField *)view).isFocused) {
        PVTextField *tf = (PVTextField *)view;
        float cursorX = frame.origin.x + 4.0f + (tf.text.length * 8.0f);
        float cursorY = frame.origin.y + (frame.size.height - 16.0f) / 2.0f;
        float cursorW = 2.0f;
        float cursorH = 16.0f;
        
        // Calculate NDC for cursor
        float scaleX = cursorW / screenSize.width;
        float scaleY = cursorH / screenSize.height;
        float centerX = cursorX + cursorW / 2.0f;
        float centerY = cursorY + cursorH / 2.0f;
        float ndcX = (centerX / screenSize.width) * 2.0 - 1.0;
        float ndcY = 1.0 - (centerY / screenSize.height) * 2.0;
        
        Uniforms cursorUniforms;
        cursorUniforms.scale[0] = scaleX;
        cursorUniforms.scale[1] = scaleY;
        cursorUniforms.offset[0] = ndcX;
        cursorUniforms.offset[1] = ndcY;
        cursorUniforms.color[0] = 1.0; cursorUniforms.color[1] = 1.0; cursorUniforms.color[2] = 1.0; cursorUniforms.color[3] = 1.0; // White cursor
        
        [renderEncoder setVertexBytes:&cursorUniforms length:sizeof(Uniforms) atIndex:1];
        [renderEncoder setFragmentBytes:&cursorUniforms length:sizeof(Uniforms) atIndex:1];
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
    
    // Recurse
    CGPoint childrenOrigin = frame.origin;
    if ([view isKindOfClass:[PVScrollView class]]) {
        PVScrollView *sv = (PVScrollView *)view;
        childrenOrigin.x -= sv.contentOffset.x;
        childrenOrigin.y -= sv.contentOffset.y;
        
        // Apply clipping for scroll view
        MTLScissorRect scissor;
        scissor.x = (NSUInteger)fmax(0, frame.origin.x);
        scissor.y = (NSUInteger)fmax(0, frame.origin.y);
        scissor.width = (NSUInteger)fmax(0, frame.size.width);
        scissor.height = (NSUInteger)fmax(0, frame.size.height);
        
        // Clip to screen bounds
        if (scissor.x > screenSize.width) scissor.x = (NSUInteger)screenSize.width;
        if (scissor.y > screenSize.height) scissor.y = (NSUInteger)screenSize.height;
        if (scissor.x + scissor.width > screenSize.width) scissor.width = (NSUInteger)screenSize.width - scissor.x;
        if (scissor.y + scissor.height > screenSize.height) scissor.height = (NSUInteger)screenSize.height - scissor.y;

        if (scissor.width > 0 && scissor.height > 0) {
            [renderEncoder setScissorRect:scissor];
        }
    }

    for (PVView *subview in view.subviews) {
        DrawViewRecursively(subview, renderEncoder, screenSize, childrenOrigin); 
    }
    
    // Reset scissor if we set it
    if ([view isKindOfClass:[PVScrollView class]]) {
        [renderEncoder setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)screenSize.width, (NSUInteger)screenSize.height}];
    }
}

void MetalRendererRender(PVView *rootView, CALayer *layer) {
    if (!rootView) return;
    MetalRendererInit();
    
    CGSize size = layer.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;
    
    if (!gMetalSublayer) {
        gMetalSublayer = [[CAMetalLayer alloc] init];
        gMetalSublayer.device = gMetalDevice;
        gMetalSublayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        gMetalSublayer.frame = layer.bounds;
        gMetalSublayer.drawableSize = CGSizeMake(size.width, size.height);
        gMetalSublayer.opaque = NO;
        gMetalSublayer.backgroundColor = CGColorGetConstantColor(kCGColorClear);
        [layer addSublayer:gMetalSublayer];
    }
    
    if (!CGRectEqualToRect(gMetalSublayer.frame, layer.bounds)) {
        gMetalSublayer.frame = layer.bounds;
        gMetalSublayer.drawableSize = CGSizeMake(size.width, size.height);
    }
    
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [gMetalSublayer nextDrawable];
        if (!drawable) return;
        
        id<MTLCommandBuffer> commandBuffer = [gMetalCommandQueue commandBuffer];
        MTLRenderPassDescriptor *passDescriptor = [[MTLRenderPassDescriptor alloc] init];
        passDescriptor.colorAttachments[0].texture = drawable.texture;
        passDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        passDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
        
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDescriptor];
        [encoder setViewport:(MTLViewport){0, 0, size.width, size.height, 0, 1}];
        
        // Initial state for solid views
        [encoder setRenderPipelineState:gMetalPipeline];
        [encoder setVertexBuffer:gMetalVertexBuffer offset:0 atIndex:0];
        
        DrawViewRecursively(rootView, encoder, size, CGPointZero);
        
        [encoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}

void HandleMouseRecursively(PVView *view, CGPoint mousePos, CGPoint parentOrigin, bool isDown) {
    CGRect absFrame = view.frame;
    absFrame.origin.x += parentOrigin.x;
    absFrame.origin.y += parentOrigin.y;
    
    bool isInside = CGRectContainsPoint(absFrame, mousePos);
    
    if ([view isKindOfClass:[PVButton class]]) {
        PVButton *btn = (PVButton *)view;
        bool wasDown = btn.isDown;
        btn.isHovering = isInside;
        btn.isDown = isDown && isInside;
        
        if (wasDown && !isDown && isInside) {
            if (btn.onClick) {
                btn.onClick();
            }
        }
    }
    
    if (isDown && [view isKindOfClass:[PVTextField class]]) {
        PVTextField *tf = (PVTextField *)view;
        tf.isFocused = isInside;
    } else if (isDown && !isInside && [view isKindOfClass:[PVTextField class]]) {
        // Clicked outside
        // ((PVTextField *)view).isFocused = NO; // Handled above if isInside is false? No.
        // Logic: if we click somewhere, we want to unfocus others?
        // Simple logic: if isDown and isInside is false, set focused to false.
        ((PVTextField *)view).isFocused = NO;
    }
    
    CGPoint childrenOrigin = absFrame.origin;
    if ([view isKindOfClass:[PVScrollView class]]) {
        PVScrollView *sv = (PVScrollView *)view;
        childrenOrigin.x -= sv.contentOffset.x;
        childrenOrigin.y -= sv.contentOffset.y;
    }

    for (PVView *subview in view.subviews) {
        HandleMouseRecursively(subview, mousePos, childrenOrigin, isDown);
    }
}

void MetalRendererHandleMouse(PVView *rootView, CGPoint position, bool isDown) {

    if (!rootView) return;

    HandleMouseRecursively(rootView, position, CGPointZero, isDown);

}



void HandleScrollRecursively(PVView *view, CGPoint mousePos, CGPoint parentOrigin, double deltaX, double deltaY) {

    CGRect absFrame = view.frame;

    absFrame.origin.x += parentOrigin.x;

    absFrame.origin.y += parentOrigin.y;



    if (!CGRectContainsPoint(absFrame, mousePos)) return;



    if ([view isKindOfClass:[PVScrollView class]]) {

        PVScrollView *sv = (PVScrollView *)view;

        CGPoint offset = sv.contentOffset;

        offset.x -= deltaX; // Scroll direction might need adjustment

        offset.y -= deltaY;



        // Clamp to contentSize

        float maxOffsetX = fmax(0, sv.contentSize.width - sv.frame.size.width);

        float maxOffsetY = fmax(0, sv.contentSize.height - sv.frame.size.height);

        offset.x = fmin(fmax(0, offset.x), maxOffsetX);

        offset.y = fmin(fmax(0, offset.y), maxOffsetY);

        

        sv.contentOffset = offset;

    }



    CGPoint childrenOrigin = absFrame.origin;

    if ([view isKindOfClass:[PVScrollView class]]) {

        PVScrollView *sv = (PVScrollView *)view;

        childrenOrigin.x -= sv.contentOffset.x;

        childrenOrigin.y -= sv.contentOffset.y;

    }



    for (PVView *subview in view.subviews) {

        HandleScrollRecursively(subview, mousePos, childrenOrigin, deltaX, deltaY);

    }

}



void MetalRendererHandleScroll(PVView *rootView, CGPoint position, double deltaX, double deltaY) {

    if (!rootView) return;

    HandleScrollRecursively(rootView, position, CGPointZero, deltaX, deltaY);

}
