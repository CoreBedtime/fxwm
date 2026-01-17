#include <Foundation/Foundation.h>
#include <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stdint.h>
#include <IOSurface/IOSurface.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#include <objc/runtime.h>
#include <Metal/Metal.h>
#include <unistd.h>


#define HOOK_INSTANCE_METHOD(CLASS, SELECTOR, REPLACEMENT, ORIGINAL) \
({ \
    Class _class = (CLASS); \
    SEL _selector = (SELECTOR); \
    Method _method = class_getInstanceMethod(_class, _selector); \
    if (_method) { \
        IMP _replacement = (IMP)(REPLACEMENT); \
        *(ORIGINAL) = method_setImplementation(_method, _replacement); \
    } else { \
        NSLog(@"Warning: Failed to hook method %@ in class %@", \
              NSStringFromSelector(_selector), NSStringFromClass(_class)); \
    } \
})

#define __int64 int64_t

#include "dobby.h"
#import "sym.h"

@interface CATransaction (Priv)

+(void)setCommittingContexts:(id)arg1 ;
+(BOOL)setDisableSignPosts:(Boolean)arg1 ;
@end

@interface CAContext : NSObject

@property (class) BOOL allowsCGSConnections;

+ (instancetype)remoteContextWithOptions:(NSDictionary *)options;
+ (instancetype)remoteContext;
+ (instancetype)localContextWithOptions:(NSDictionary *)options;
+ (instancetype)localContext;
+ (instancetype)currentContext;

+ (NSArray<__kindof CAContext *> *)allContexts;
+ (void)setClientPort:(mach_port_t)port;

@property BOOL colorMatchUntaggedContent;
@property CGColorSpaceRef colorSpace;
@property uint32_t commitPriority;
@property (copy) NSString *contentsFormat;
@property (readonly) uint32_t contextId;
@property uint32_t displayMask;
@property uint32_t displayNumber;
@property uint32_t eventMask;
@property (strong) CALayer *layer;
@property (readonly) NSDictionary *options;
@property int restrictedHostProcessId;
@property (readonly) BOOL valid;

- (void)invalidate;

- (uint32_t)createSlot;
- (void)setObject:(id)object forSlot:(uint32_t)slot;
- (void)deleteSlot:(uint32_t)slot;

- (mach_port_t)createFencePort;
- (void)setFence:(uint32_t)fence count:(uint32_t)count;
- (void)setFencePort:(mach_port_t)port commitHandler:(void(^)(void))handler;
- (void)setFencePort:(mach_port_t)port;
- (void)invalidateFences;

@end

/* Can be used as the value of `CALayer.contents`. */
@interface CASlotProxy: NSObject

- (instancetype)initWithName:(uint32_t)slotName;

@end

@interface CARemoteLayerClient ()

- (CAContext *)context;

@end

@interface CALayer (CAContext)

@property (readonly) CAContext *context;

@end

CG_EXTERN CFTypeRef CGRegionCreateWithRect(CGRect rect);

void *(*_StartSubsidiaryServices)(__int64 a1);

void *(*_WindowCreate)(__int64 a1, unsigned int a2, const void *a3, int a4);
Boolean (*_WindowIsValid)(void *a1);
pid_t (*_WindowGetOwningProcessId)(void *a1);
void (*_ShapeWindowWithRect)(void *a1, CGRect a2);
void (*_OrderWindowListSpaceSwitchOptions)(__int64 a1,
                                           __int64 a2,
                                           __int64 a3,
                                           __int64 a4,
                                           unsigned int a5,
                                           unsigned int a6); // im lazyyyy

void (*_BindLocalClientContext)(void *a1, CAContext *a2, __int64 a3); // a3 usually one
void (*_WindowLayerBackingTakeOwnershipOfContext)(void *a1, CAContext *a2); // a3 usually one


void (*_InvalidateDisplayShape)(__int64 a1, __int64 a2, __int64 a3); // a3 usually one
void (*_ScheduleUpdateAllDisplays)(__int64 a1, __int64 a2); // a3 usually one


void (*__SERVER_COMMIT_START)(__int64 * int_ptr, CAContext *ptr);
void (*__SERVER_COMMIT_END)(__int64 * int_ptr);

// Linked list node structure
typedef struct WindowNode {
    void * window;
    pid_t owner;
    struct WindowNode *next;
} WindowNode;

// Head of linked list
WindowNode *gWindowList = NULL;
pthread_mutex_t gWindowListLock = PTHREAD_MUTEX_INITIALIZER;

// Helper to add a window ID
void AddWindow(void * w) {
    pid_t owner = _WindowGetOwningProcessId(w);

    NSLog(@"added window %p owned by owner %i", w, owner);

    pthread_mutex_lock(&gWindowListLock);
    WindowNode *node = malloc(sizeof(WindowNode));
    if (node) {
        node->window = w;
        node->owner = owner;
        node->next = gWindowList;
        gWindowList = node;
    }
    pthread_mutex_unlock(&gWindowListLock);
}

void GarbageCollectWindows(void) {
    pthread_mutex_lock(&gWindowListLock);

    WindowNode *prev = NULL;
    WindowNode *curr = gWindowList;

    while (curr) {
        Boolean invalid = _WindowIsValid(curr->window);

        if (invalid) {
            // Log for debugging
            NSLog(@"[gc] removing invalid window: %p", curr->window);

            // Remove node from list
            WindowNode *toFree = curr;
            if (prev) {
                prev->next = curr->next;
            } else {
                gWindowList = curr->next;
            }
            curr = curr->next;
            free(toFree);
        } else {
            prev = curr;
            curr = curr->next;
        }
    }

    pthread_mutex_unlock(&gWindowListLock);
}

void OrderWindow(void *window_ptr, int orderOp) {
    int windowID = *(int *)(window_ptr);
    int relativeWindowID = 0;

    _OrderWindowListSpaceSwitchOptions(
        0LL,                         // connection
        (__int64)&windowID,          // window list
        (__int64)&orderOp,           // order operations
        (__int64)&relativeWindowID,  // relative window ID
        1LL,                         // count
        0LL                          // options
    );
}


void *MarkWindows(__int64 a1, unsigned int a2, const void *a3, int a4) {
    void * w = _WindowCreate(a1, a2, a3, a4);
    GarbageCollectWindows();

    AddWindow(w);

    return w;
}

void *gWindowRoot = NULL;
CAContext *gRootContextPtr = NULL;

// Metal rendering objects
id<MTLDevice> gMetalDevice = nil;
id<MTLCommandQueue> gMetalCommandQueue = nil;
id<MTLRenderPipelineState> gMetalPipeline = nil;
id<MTLBuffer> gMetalVertexBuffer = nil;
id<MTLBuffer> gMetalIndexBuffer = nil;
static CAMetalLayer *gMetalSublayer = nil;

void HideAllWindowsTest(void) {
    pthread_mutex_lock(&gWindowListLock);
    WindowNode *curr = gWindowList;
    while (curr) {
        curr = curr->next;
    }
    pthread_mutex_unlock(&gWindowListLock);
}

static void InitializeMetal(void) {
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

    // Simple vertex shader
    NSString *vertexShaderSource = @"using namespace metal;\n"
                                   "struct VertexOut {\n"
                                   "    float4 position [[position]];\n"
                                   "    float4 color;\n"
                                   "};\n"
                                   "vertex VertexOut vertex_main(uint vid [[vertex_id]]) {\n"
                                   "    float4 positions[3] = {\n"
                                   "        float4( 0.0,  0.3, 0.0, 1.0),\n"
                                   "        float4(-0.3, -0.3, 0.0, 1.0),\n"
                                   "        float4( 0.3, -0.3, 0.0, 1.0)\n"
                                   "    };\n"
                                   "    float4 colors[3] = {\n"
                                   "        float4(1.0, 1.0, 1.0, 1.0),\n"
                                   "        float4(1.0, 1.0, 1.0, 1.0),\n"
                                   "        float4(1.0, 1.0, 1.0, 1.0)\n"
                                   "    };\n"
                                   "    VertexOut out;\n"
                                   "    out.position = positions[vid];\n"
                                   "    out.color = colors[vid];\n"
                                   "    return out;\n"
                                   "}";

    // Simple fragment shader
    NSString *fragmentShaderSource = @"using namespace metal;\n"
                                     "struct VertexOut {\n"
                                     "    float4 position [[position]];\n"
                                     "    float4 color;\n"
                                     "};\n"
                                     "fragment float4 fragment_main(VertexOut in [[stage_in]]) {\n"
                                     "    return in.color;\n"
                                     "}";

    // Create vertex shader library
    NSError *error = nil;
    id<MTLLibrary> vertexLibrary = [gMetalDevice newLibraryWithSource:vertexShaderSource options:nil error:&error];
    if (error) {
        NSLog(@"Failed to create vertex Metal library: %@", error);
        return;
    }

    // Create fragment shader library
    id<MTLLibrary> fragmentLibrary = [gMetalDevice newLibraryWithSource:fragmentShaderSource options:nil error:&error];
    if (error) {
        NSLog(@"Failed to create fragment Metal library: %@", error);
        return;
    }

    id<MTLFunction> vertexFunction = [vertexLibrary newFunctionWithName:@"vertex_main"];
    id<MTLFunction> fragmentFunction = [fragmentLibrary newFunctionWithName:@"fragment_main"];

    NSLog(@"Vertex function: %@", vertexFunction ? @"OK" : @"NULL");
    NSLog(@"Fragment function: %@", fragmentFunction ? @"OK" : @"NULL");

    // Create render pipeline
    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;

    gMetalPipeline = [gMetalDevice newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (error) {
        NSLog(@"Failed to create Metal pipeline: %@", error);
        return;
    }

    NSLog(@"Metal initialized successfully with device: %@", gMetalDevice);
}

static void RenderProteinLogToLayer(CALayer *layer) {
    InitializeMetal();

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
    }

    @autoreleasepool {
        // Create drawable
        id<CAMetalDrawable> drawable = [gMetalSublayer nextDrawable];
        if (!drawable) {
            NSLog(@"Failed to create Metal drawable");
            return;
        }

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [gMetalCommandQueue commandBuffer];

        // Create render pass descriptor
        MTLRenderPassDescriptor *renderPassDescriptor = [[MTLRenderPassDescriptor alloc] init];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        // Begin encoding
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        [renderEncoder setViewport:(MTLViewport){0.0, 0.0, size.width, size.height, 0.0, 1.0}];
        [renderEncoder setRenderPipelineState:gMetalPipeline];
        [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [renderEncoder endEncoding];

        // Present and commit
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }
}

void UpdateProteinRoot(void) {
    CGRect _updateRect = CGRectMake(0, 0, 1800, 1169);
    CFTypeRef Region = CGRegionCreateWithRect(_updateRect);
    if (gWindowRoot == NULL) {
        gWindowRoot = _WindowCreate(0LL, 5LL, Region, 6145LL);

        gRootContextPtr = [CAContext localContextWithOptions:@{}];
        _BindLocalClientContext(gWindowRoot, gRootContextPtr, 0);
        _WindowLayerBackingTakeOwnershipOfContext(gWindowRoot, gRootContextPtr);

        __int64 intptr = 0;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        __SERVER_COMMIT_START(&intptr, gRootContextPtr);

        CALayer * rootlayer = [CALayer new];
        _updateRect.origin = CGPointZero;
        rootlayer.frame = _updateRect;
        rootlayer.backgroundColor = CGColorCreateSRGB(1, 0, 0, 1);

        gRootContextPtr.layer = rootlayer;
        __SERVER_COMMIT_END(&intptr);
        [CATransaction commit];

        OrderWindow(gWindowRoot, 1);
    } else {
        __int64 intptr = 0;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setDisableSignPosts:YES];
        [CATransaction setCommittingContexts:@[gRootContextPtr]];
        __SERVER_COMMIT_START(&intptr, gRootContextPtr);

        gRootContextPtr.layer.backgroundColor = CGColorCreateSRGB(0.5, 0, 0, 1.0);
        RenderProteinLogToLayer(gRootContextPtr.layer);

        __SERVER_COMMIT_END(&intptr);
        [CATransaction commit];

        _InvalidateDisplayShape(0LL, (__int64)gWindowRoot, (__int64)Region);
        _ScheduleUpdateAllDisplays(0LL, 0LL);
        OrderWindow(gWindowRoot, 1);
    }
}

__int64 (*_UpdateOld)(__int64 a1, __int64 a2, __int64 a3, __int64 a4);

bool needsSetup = true;
__int64 UpdateHook(__int64 a1, __int64 a2, __int64 a3, __int64 a4) {
    static dispatch_once_t once;
    static dispatch_source_t timer = NULL;

    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,
                                       0, 0,
                                       dispatch_get_main_queue());

        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  16 * NSEC_PER_MSEC,
                                  1 * NSEC_PER_MSEC);

        dispatch_source_set_event_handler(timer, ^{
            @autoreleasepool {
                HideAllWindowsTest();
                UpdateProteinRoot();
            }
        });

        dispatch_resume(timer);
    });

    return _UpdateOld(a1, a2, a3, a4);
}

Boolean (*_NeedsUpdateOrig)(void);
Boolean NeedsUpdateTrue(id self, SEL _cmd) {
    return true;
}

char * LibName;
void _RenderSetup(void) {
    // madman hooks
    void *Target;
    Target = symrez_resolve_once(LibName, "_CGXUpdateDisplay");
    DobbyHook(Target, (void *)UpdateHook, (void **)&_UpdateOld);

    HOOK_INSTANCE_METHOD(NSClassFromString(@"CAWindowServerDisplay"), NSSelectorFromString(@"needsUpdate"), NeedsUpdateTrue, (IMP *)&_NeedsUpdateOrig);
}

Boolean setupAlready = false;
void __BootStrapFuncHook(__int64 a1) {
    if (!setupAlready) { // nine is called when logon.
        freopen("/tmp/protein.log", "a+", stderr);
        setbuf(stderr, NULL);

        _RenderSetup();
        setupAlready = true;
    }
    _StartSubsidiaryServices(a1);
}

__attribute__((constructor))
void _TweakConstructor(void) {
    LibName = "SkyLight";

    // madman symbol res
    _ShapeWindowWithRect = symrez_resolve_once(LibName, "_WSShapeWindowWithRect");

    _WindowIsValid = symrez_resolve_once(LibName, "_WSWindowIsInvalid");

    _WindowGetOwningProcessId = symrez_resolve_once(LibName, "_WSWindowGetOwningPID");

    _OrderWindowListSpaceSwitchOptions = symrez_resolve_once(LibName, "__ZL36CGXOrderWindowListSpaceSwitchOptionsP13CGXConnectionPKjPK10CGSOrderOpS2_jb");

    _BindLocalClientContext = symrez_resolve_once(LibName, "__ZN9CGXWindow28bind_local_ca_client_contextEP9CAContextb");

    _WindowLayerBackingTakeOwnershipOfContext = symrez_resolve_once(LibName, "_WSCALayerBackingTakeOwnershipOfContext");

    _ScheduleUpdateAllDisplays = symrez_resolve_once(LibName, "_CGXScheduleUpdateAllDisplays");

    _InvalidateDisplayShape = symrez_resolve_once(LibName, "_CGXInvalidateDisplayShape");

    _StartSubsidiaryServices = symrez_resolve_once(LibName, "_CGXStartSubsidiaryServices");

    __SERVER_COMMIT_START = symrez_resolve_once(LibName, "__ZN27WSCAContextScopeTransaction18addContextToCommitEP9CAContext");

    __SERVER_COMMIT_END = symrez_resolve_once(LibName, "__ZN27WSCAContextScopeTransactionD1Ev");


    // init hooks
    void *Target = symrez_resolve_once(LibName, "_CGXStartSubsidiaryServices");
    DobbyHook(Target, (void *)__BootStrapFuncHook, (void **)&_StartSubsidiaryServices);

    Target = symrez_resolve_once(LibName, "_WSWindowCreate");
    DobbyHook(Target, (void *)MarkWindows, (void **)&_WindowCreate);
}


#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };
// don't discard our privilleges
int _libsecinit_initializer();
int _libsecinit_initializer_new() {
    return 0;
}
int setegid_new(gid_t gid) {
    return 0;
}
int seteuid_new(uid_t uid) {
    return 0;
}
DYLD_INTERPOSE(_libsecinit_initializer_new, _libsecinit_initializer);
DYLD_INTERPOSE(setegid_new, setegid);
DYLD_INTERPOSE(seteuid_new, seteuid);
