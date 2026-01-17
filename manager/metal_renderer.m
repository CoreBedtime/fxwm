//
//  metal_renderer.m
//

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>

#import "metal_renderer.h"

// Cube vertex structure
typedef struct {
    float position[3];
    float color[3];
} CubeVertex;

// Uniforms for animation
typedef struct {
    float modelViewProjection[16];
} Uniforms;

// Metal rendering objects
static id<MTLDevice> gMetalDevice = nil;
static id<MTLCommandQueue> gMetalCommandQueue = nil;
static id<MTLRenderPipelineState> gMetalPipeline = nil;
static id<MTLBuffer> gMetalVertexBuffer = nil;
static id<MTLBuffer> gMetalIndexBuffer = nil;
static id<MTLBuffer> gMetalUniformBuffer = nil;
static id<MTLDepthStencilState> gMetalDepthState = nil;
static id<MTLTexture> gDepthTexture = nil;
static CAMetalLayer *gMetalSublayer = nil;
static CFTimeInterval gAnimationStartTime = 0;

// Matrix math helpers (column-major for Metal)
// Column-major: element at row r, col c is at index c*4+r
static void matrix_multiply(float *result, const float *a, const float *b) {
    float temp[16];
    for (int c = 0; c < 4; c++) {
        for (int r = 0; r < 4; r++) {
            temp[c * 4 + r] = 0;
            for (int k = 0; k < 4; k++) {
                temp[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
            }
        }
    }
    memcpy(result, temp, sizeof(temp));
}

static void matrix_identity(float *m) {
    memset(m, 0, 16 * sizeof(float));
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static void matrix_rotation_y(float *m, float angle) {
    matrix_identity(m);
    float c = cosf(angle);
    float s = sinf(angle);
    // Column-major Y rotation
    m[0] = c;   m[2] = -s;
    m[8] = s;   m[10] = c;
}

static void matrix_rotation_x(float *m, float angle) {
    matrix_identity(m);
    float c = cosf(angle);
    float s = sinf(angle);
    // Column-major X rotation
    m[5] = c;   m[6] = s;
    m[9] = -s;  m[10] = c;
}

static void matrix_translation(float *m, float x, float y, float z) {
    matrix_identity(m);
    // Column-major: translation in column 3
    m[12] = x; m[13] = y; m[14] = z;
}

static void matrix_perspective(float *m, float fov, float aspect, float near, float far) {
    memset(m, 0, 16 * sizeof(float));
    float f = 1.0f / tanf(fov / 2.0f);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = far / (near - far);
    m[11] = -1.0f;
    m[14] = (far * near) / (near - far);
}

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

    // Cube shader with 3D transforms
    NSString *shaderSource = @"using namespace metal;\n"
        "struct VertexIn {\n"
        "    float3 position [[attribute(0)]];\n"
        "    float3 color [[attribute(1)]];\n"
        "};\n"
        "struct VertexOut {\n"
        "    float4 position [[position]];\n"
        "    float3 color;\n"
        "};\n"
        "struct Uniforms {\n"
        "    float4x4 modelViewProjection;\n"
        "};\n"
        "vertex VertexOut vertex_main(VertexIn in [[stage_in]],\n"
        "                             constant Uniforms &uniforms [[buffer(1)]]) {\n"
        "    VertexOut out;\n"
        "    out.position = uniforms.modelViewProjection * float4(in.position, 1.0);\n"
        "    out.color = in.color;\n"
        "    return out;\n"
        "}\n"
        "fragment float4 fragment_main(VertexOut in [[stage_in]]) {\n"
        "    return float4(in.color, 1.0);\n"
        "}";

    NSError *error = nil;
    id<MTLLibrary> library = [gMetalDevice newLibraryWithSource:shaderSource options:nil error:&error];
    if (error) {
        NSLog(@"Failed to create Metal library: %@", error);
        return;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragment_main"];

    // Define cube vertices with colors per face
    // 8 corners, but we need 24 vertices (4 per face) for proper face colors
    CubeVertex vertices[] = {
        // Front face (red)
        {{-0.5, -0.5,  0.5}, {1.0, 0.2, 0.2}},
        {{ 0.5, -0.5,  0.5}, {1.0, 0.2, 0.2}},
        {{ 0.5,  0.5,  0.5}, {1.0, 0.2, 0.2}},
        {{-0.5,  0.5,  0.5}, {1.0, 0.2, 0.2}},
        // Back face (green)
        {{ 0.5, -0.5, -0.5}, {0.2, 1.0, 0.2}},
        {{-0.5, -0.5, -0.5}, {0.2, 1.0, 0.2}},
        {{-0.5,  0.5, -0.5}, {0.2, 1.0, 0.2}},
        {{ 0.5,  0.5, -0.5}, {0.2, 1.0, 0.2}},
        // Top face (blue)
        {{-0.5,  0.5,  0.5}, {0.2, 0.2, 1.0}},
        {{ 0.5,  0.5,  0.5}, {0.2, 0.2, 1.0}},
        {{ 0.5,  0.5, -0.5}, {0.2, 0.2, 1.0}},
        {{-0.5,  0.5, -0.5}, {0.2, 0.2, 1.0}},
        // Bottom face (yellow)
        {{-0.5, -0.5, -0.5}, {1.0, 1.0, 0.2}},
        {{ 0.5, -0.5, -0.5}, {1.0, 1.0, 0.2}},
        {{ 0.5, -0.5,  0.5}, {1.0, 1.0, 0.2}},
        {{-0.5, -0.5,  0.5}, {1.0, 1.0, 0.2}},
        // Right face (magenta)
        {{ 0.5, -0.5,  0.5}, {1.0, 0.2, 1.0}},
        {{ 0.5, -0.5, -0.5}, {1.0, 0.2, 1.0}},
        {{ 0.5,  0.5, -0.5}, {1.0, 0.2, 1.0}},
        {{ 0.5,  0.5,  0.5}, {1.0, 0.2, 1.0}},
        // Left face (cyan)
        {{-0.5, -0.5, -0.5}, {0.2, 1.0, 1.0}},
        {{-0.5, -0.5,  0.5}, {0.2, 1.0, 1.0}},
        {{-0.5,  0.5,  0.5}, {0.2, 1.0, 1.0}},
        {{-0.5,  0.5, -0.5}, {0.2, 1.0, 1.0}},
    };

    // Index buffer for cube faces (2 triangles per face, 6 faces)
    uint16_t indices[] = {
        0,  1,  2,  0,  2,  3,   // front
        4,  5,  6,  4,  6,  7,   // back
        8,  9,  10, 8,  10, 11,  // top
        12, 13, 14, 12, 14, 15,  // bottom
        16, 17, 18, 16, 18, 19,  // right
        20, 21, 22, 20, 22, 23,  // left
    };

    gMetalVertexBuffer = [gMetalDevice newBufferWithBytes:vertices
                                                   length:sizeof(vertices)
                                                  options:MTLResourceStorageModeShared];
    gMetalIndexBuffer = [gMetalDevice newBufferWithBytes:indices
                                                  length:sizeof(indices)
                                                 options:MTLResourceStorageModeShared];
    gMetalUniformBuffer = [gMetalDevice newBufferWithLength:sizeof(Uniforms)
                                                    options:MTLResourceStorageModeShared];

    // Vertex descriptor
    MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[0].offset = offsetof(CubeVertex, position);
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat3;
    vertexDescriptor.attributes[1].offset = offsetof(CubeVertex, color);
    vertexDescriptor.attributes[1].bufferIndex = 0;
    vertexDescriptor.layouts[0].stride = sizeof(CubeVertex);
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // Create render pipeline
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.vertexDescriptor = vertexDescriptor;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    gMetalPipeline = [gMetalDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (error) {
        NSLog(@"Failed to create Metal pipeline: %@", error);
        return;
    }

    // Create depth stencil state
    MTLDepthStencilDescriptor *depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;
    gMetalDepthState = [gMetalDevice newDepthStencilStateWithDescriptor:depthDescriptor];

    gAnimationStartTime = CACurrentMediaTime();
    NSLog(@"Metal initialized successfully with device: %@", gMetalDevice);
}

void MetalRendererDrawToLayer(CALayer *layer) {
    MetalRendererInit();

    CGSize size = layer.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;

    // Create Metal sublayer if it doesn't exist
    if (!gMetalSublayer) {
        gMetalSublayer = [[CAMetalLayer alloc] init];
        gMetalSublayer.device = gMetalDevice;
        gMetalSublayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        gMetalSublayer.frame = layer.bounds;
        gMetalSublayer.drawableSize = CGSizeMake(size.width, size.height);
        gMetalSublayer.opaque = YES;

        [layer addSublayer:gMetalSublayer];
    }

    // Update frame if needed
    if (!CGRectEqualToRect(gMetalSublayer.frame, layer.bounds)) {
        gMetalSublayer.frame = layer.bounds;
        gMetalSublayer.drawableSize = CGSizeMake(size.width, size.height);
        gDepthTexture = nil; // Force recreation
    }

    // Create or recreate depth texture if needed
    if (!gDepthTexture || gDepthTexture.width != (NSUInteger)size.width || gDepthTexture.height != (NSUInteger)size.height) {
        MTLTextureDescriptor *depthDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                            width:(NSUInteger)size.width
                                                                                           height:(NSUInteger)size.height
                                                                                        mipmapped:NO];
        depthDesc.usage = MTLTextureUsageRenderTarget;
        depthDesc.storageMode = MTLStorageModePrivate;
        gDepthTexture = [gMetalDevice newTextureWithDescriptor:depthDesc];
    }

    @autoreleasepool {
        // Create drawable
        id<CAMetalDrawable> drawable = [gMetalSublayer nextDrawable];
        if (!drawable) {
            NSLog(@"Failed to create Metal drawable");
            return;
        }

        // Calculate animation time
        CFTimeInterval time = CACurrentMediaTime() - gAnimationStartTime;
        float rotationY = time * 1.0f; // Rotate around Y axis
        float rotationX = time * 0.7f; // Rotate around X axis

        // Build model-view-projection matrix
        float rotY[16], rotX[16], rot[16], trans[16], model[16], proj[16], mvp[16];

        matrix_rotation_y(rotY, rotationY);
        matrix_rotation_x(rotX, rotationX);
        matrix_multiply(rot, rotX, rotY);

        matrix_translation(trans, 0.0f, 0.0f, -3.0f);
        matrix_multiply(model, trans, rot);

        float aspect = size.width / size.height;
        matrix_perspective(proj, M_PI / 4.0f, aspect, 0.1f, 100.0f);

        matrix_multiply(mvp, proj, model);

        // Update uniform buffer
        Uniforms *uniforms = (Uniforms *)[gMetalUniformBuffer contents];
        memcpy(uniforms->modelViewProjection, mvp, sizeof(mvp));

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [gMetalCommandQueue commandBuffer];

        // Create render pass descriptor
        MTLRenderPassDescriptor *renderPassDescriptor = [[MTLRenderPassDescriptor alloc] init];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.05, 0.05, 0.1, 1.0);

        renderPassDescriptor.depthAttachment.texture = gDepthTexture;
        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
        renderPassDescriptor.depthAttachment.clearDepth = 1.0;

        // Begin encoding
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setViewport:(MTLViewport){0.0, 0.0, size.width, size.height, 0.0, 1.0}];
        [renderEncoder setRenderPipelineState:gMetalPipeline];
        [renderEncoder setDepthStencilState:gMetalDepthState];
        [renderEncoder setCullMode:MTLCullModeBack];
        [renderEncoder setFrontFacingWinding:MTLWindingClockwise];

        [renderEncoder setVertexBuffer:gMetalVertexBuffer offset:0 atIndex:0];
        [renderEncoder setVertexBuffer:gMetalUniformBuffer offset:0 atIndex:1];

        [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                  indexCount:36
                                   indexType:MTLIndexTypeUInt16
                                 indexBuffer:gMetalIndexBuffer
                           indexBufferOffset:0];
        [renderEncoder endEncoding];

        // Present and commit
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}
