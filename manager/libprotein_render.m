#include <Foundation/Foundation.h>
#include <Foundation/NSObjCRuntime.h>
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
#include <unistd.h>

#import "metal_renderer.h"
#import "protein_events.h"
#import "mouse_events.h"

// ============================================================================
// MARK: - SLSEventRecord Structure (Removed - Moved to mouse_events.m)
// ============================================================================

// Global mouse event callback (Removed - Moved to mouse_events.m)

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

// ============================================================================
// MARK: - Mouse Event Function Pointers (Removed)
// ============================================================================

// Get window ID from window pointer
int (*_WSWindowGetID)(void *window);

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

#import "ui.h"
#import "keyboard_events.h"

// Global (non-static) for access by mouse_events.m
void *gWindowRoot = NULL;
CAContext *gRootContextPtr = NULL;
CGRect gWindowRootBounds = {0, 0, 1800, 1169};

// Root of our view hierarchy
PVView *gRootView = nil; // Removed static

// ============================================================================
// MARK: - Mouse Event Public API (Removed - Moved to mouse_events.m)
// ============================================================================

// ============================================================================
// MARK: - Default Mouse Handler (Removed - Moved to mouse_events.m)
// ============================================================================

// ============================================================================
// MARK: - Mouse Event Hook (Removed - Moved to mouse_events.m)
// ============================================================================

void HideAllWindowsTest(void) {
    pthread_mutex_lock(&gWindowListLock);
    WindowNode *curr = gWindowList;
    while (curr) {
        curr = curr->next;
    }
    pthread_mutex_unlock(&gWindowListLock);
}

// Mouse handler for Protein UI
static void ProteinMouseHandler(
    CGSEventType eventType,
    CGPoint screenLocation,
    CGPoint windowLocation,
    int buttonNumber,
    int clickCount,
    double deltaX,
    double deltaY,
    void *userInfo)
{
    if (!gRootView) return;

    if (eventType == kCGSEventScrollWheel) {
        MetalRendererHandleScroll(gRootView, windowLocation, deltaX, deltaY);
        return;
    }

    bool isDown = false;
    switch (eventType) {
        case kCGSEventLeftMouseDown:
        case kCGSEventRightMouseDown:
        case kCGSEventOtherMouseDown:
            isDown = true;
            break;
        case kCGSEventLeftMouseUp:
        case kCGSEventRightMouseUp:
        case kCGSEventOtherMouseUp:
            isDown = false;
            break;
        case kCGSEventLeftMouseDragged:
        case kCGSEventRightMouseDragged:
        case kCGSEventOtherMouseDragged:
            // Dragged implies down usually, but we might want to check button state
            // For simplicity, let's assume if we are dragging, it's down.
            // But we only get "isDown" passed as a bool to renderer.
            // Renderer logic: hover && down -> pressed.
            // If we are dragging, we are down.
            isDown = true;
            break;
        default:
            // MouseMoved
            isDown = false;
            break;
    }

    MetalRendererHandleMouse(gRootView, windowLocation, isDown);
}

void UpdateProteinRoot(void) {
    CGRect _updateRect = gWindowRootBounds;
    gWindowRootBounds = _updateRect; // Update bounds for hit testing
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
        NSLog(@"[Protein] Window created with bounds: %.0f,%.0f %.0fx%.0f",
              gWindowRootBounds.origin.x, gWindowRootBounds.origin.y,
              gWindowRootBounds.size.width, gWindowRootBounds.size.height);

    } else {
        __int64 intptr = 0;
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [CATransaction setDisableSignPosts:YES];
        [CATransaction setCommittingContexts:@[gRootContextPtr]];
        __SERVER_COMMIT_START(&intptr, gRootContextPtr);

        gRootContextPtr.layer.backgroundColor = CGColorCreateSRGB(0.5, 0, 0, 1.0);

        // Render the view hierarchy
        if (gRootView) {
            MetalRendererRender(gRootView, gRootContextPtr.layer);
        }

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

extern
void CreateLogonView(PVView *gRootView);

char * LibName;
void _RenderSetup(void) {
    // madman hooks
    void *Target;
    Target = symrez_resolve_once(LibName, "_CGXUpdateDisplay");
    DobbyHook(Target, (void *)UpdateHook, (void **)&_UpdateOld);

    HOOK_INSTANCE_METHOD(NSClassFromString(@"CAWindowServerDisplay"), NSSelectorFromString(@"needsUpdate"), NeedsUpdateTrue, (IMP *)&_NeedsUpdateOrig);

    gWindowRootBounds = [[NSClassFromString(@"CADisplay") mainDisplay] bounds];

    // Initialize mouse event handling
    SetupMouseEvents();
    ProteinSetMouseEventCallback(ProteinMouseHandler, NULL);
    SetupKeyboardEvents();

    // Setup View Hierarchy
    gRootView = [[PVView alloc] init];
    gRootView.frame = gWindowRootBounds;
    gRootView.backgroundColor = 0x1A1A1AFF; // Dark grey


    // call create logon shits
    CreateLogonView(gRootView);

    // // Add a button
    // PVButton *btn = [[PVButton alloc] init];
    // btn.frame = CGRectMake(800, 500, 200, 60); // Centered-ish
    // btn.title = @"Click Me";
    // btn.backgroundColor = 0x3399FFFF; // Light blue
    // [gRootView addSubview:btn];

    // // Add another view
    // PVView *box = [[PVView alloc] init];
    // box.frame = CGRectMake(100, 100, 100, 100);
    // box.backgroundColor = 0xCC3333FF; // Red-ish
    // [gRootView addSubview:box];

    // // Add a label
    // PVLabel *lbl = [[PVLabel alloc] init];
    // lbl.frame = CGRectMake(100, 220, 200, 30);
    // lbl.text = @"Hello Label";
    // lbl.textColor = 0xFF00FFFF; // Magenta
    // [gRootView addSubview:lbl];

    // // Add a text field
    // PVTextField *tf = [[PVTextField alloc] init];
    // tf.frame = CGRectMake(800, 600, 200, 40);
    // tf.placeholder = @"Type here...";
    // tf.textColor = 0xFFFFFFFF;
    // tf.backgroundColor = 0x555555FF;
    // tf.onEnter = ^(NSString *text) {
    //     NSLog(@"[Protein] Text Entered: %@", text);
    //     lbl.text = [NSString stringWithFormat:@"Entered: %@", text];
    // };
    // [gRootView addSubview:tf];
}

Boolean setupAlready = false;
void __BootStrapFuncHook(__int64 a1) {
    if (!setupAlready) { // nine is called when logon.
        freopen("/tmp/protein.log", "a+", stderr);
        setbuf(stderr, NULL);

        _RenderSetup();
        setupAlready = true;
    }
    // _StartSubsidiaryServices(a1);
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
