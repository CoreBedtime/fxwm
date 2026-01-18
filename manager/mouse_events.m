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
#include <unistd.h>

#import "metal_renderer.h"
#import "protein_events.h"
#import "mouse_events.h"

// External globals from libprotein_render.m
extern void *gWindowRoot;
extern CGRect gWindowRootBounds;

// ============================================================================
// MARK: - SLSEventRecord Structure (248 bytes, from IDA analysis)
// ============================================================================

#pragma pack(push, 1)
typedef struct __attribute__((packed)) SLSEventRecord {
    uint16_t flags;              // +0
    uint16_t reserved1;          // +2
    uint32_t recordSize;         // +4 (always 248)
    uint32_t eventType;          // +8 (CGSEventType)
    uint32_t reserved2;          // +12
    double locationX;            // +16 (screen X coordinate)
    double locationY;            // +24 (screen Y coordinate)
    double windowLocationX;      // +32 (window-relative X)
    double windowLocationY;      // +40 (window-relative Y)
    uint64_t timestamp;          // +48
    uint32_t eventFlags;         // +56
    uint32_t reserved3;          // +60
    uint32_t reserved4;          // +64

    // Source data (+68)
    uint8_t sourceData[32];      // CGEventSourceData

    // Process data (+100)
    uint8_t processData[20];     // CGEventProcess

    // Event-specific union (+120)
    union {
        struct {
            uint8_t padding[18];     // +120 to +138
            uint16_t clickID;        // +138
            int32_t clickCount;      // +140
            uint8_t clickState;      // +144 (-1=down, 0=up)
            uint8_t buttonNumber;    // +145 (0=left, 1=right, 2+=other)
        } mouse;
        uint8_t rawData[80];
    } eventData;

    // Remaining fields
    uint8_t tail[48];            // +200 to +248
} SLSEventRecord;
#pragma pack(pop)

// Global mouse event callback
static MouseEventCallback gMouseEventCallback = NULL;
static void *gMouseEventUserInfo = NULL;

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

// Mouse event processor dispatch (the main event dispatch method)
static __int64 (*_MouseEventDispatch_Orig)(id self, SEL sel, SLSEventRecord *event, id annotationParams, id dispatcher);

// ============================================================================
// MARK: - Mouse Event Public API
// ============================================================================

void ProteinSetMouseEventCallback(MouseEventCallback callback, void *userInfo) {
    gMouseEventCallback = callback;
    gMouseEventUserInfo = userInfo;
}

// Check if a point is inside our protein window
static bool ProteinPointInWindow(CGPoint screenPoint) {
    if (gWindowRoot == NULL) return false;

    return CGRectContainsPoint(gWindowRootBounds, screenPoint);
}

// Convert screen coordinates to window-local coordinates
static CGPoint ProteinScreenToWindow(CGPoint screenPoint) {
    return CGPointMake(
        screenPoint.x - gWindowRootBounds.origin.x,
        screenPoint.y - gWindowRootBounds.origin.y
    );
}

// Get event type name for logging
static const char* EventTypeName(CGSEventType type) {
    switch (type) {
        case kCGSEventLeftMouseDown: return "LeftMouseDown";
        case kCGSEventLeftMouseUp: return "LeftMouseUp";
        case kCGSEventRightMouseDown: return "RightMouseDown";
        case kCGSEventRightMouseUp: return "RightMouseUp";
        case kCGSEventMouseMoved: return "MouseMoved";
        case kCGSEventLeftMouseDragged: return "LeftMouseDragged";
        case kCGSEventRightMouseDragged: return "RightMouseDragged";
        case kCGSEventOtherMouseDown: return "OtherMouseDown";
        case kCGSEventOtherMouseUp: return "OtherMouseUp";
        case kCGSEventOtherMouseDragged: return "OtherMouseDragged";
        case kCGSEventScrollWheel: return "ScrollWheel";
        default: return "Unknown";
    }
}

// Process an incoming mouse event
static void ProcessMouseEvent(SLSEventRecord *event) {
    if (!event) return;

    CGSEventType eventType = (CGSEventType)event->eventType;

    // Only process mouse events
    switch (eventType) {
        case kCGSEventLeftMouseDown:
        case kCGSEventLeftMouseUp:
        case kCGSEventRightMouseDown:
        case kCGSEventRightMouseUp:
        case kCGSEventMouseMoved:
        case kCGSEventLeftMouseDragged:
        case kCGSEventRightMouseDragged:
        case kCGSEventOtherMouseDown:
        case kCGSEventOtherMouseUp:
        case kCGSEventOtherMouseDragged:
            break;
        default:
            return; // Not a mouse event
    }

    CGPoint screenLocation = CGPointMake(event->locationX, event->locationY);

    // Check if the event is in our window
    if (!ProteinPointInWindow(screenLocation)) {
        return;
    }

    CGPoint windowLocation = ProteinScreenToWindow(screenLocation);
    int buttonNumber = event->eventData.mouse.buttonNumber;
    int clickCount = event->eventData.mouse.clickCount;

    NSLog(@"[Protein] Mouse event: %s at screen(%.1f, %.1f) window(%.1f, %.1f) button=%d clicks=%d",
          EventTypeName(eventType),
          screenLocation.x, screenLocation.y,
          windowLocation.x, windowLocation.y,
          buttonNumber, clickCount);

    // Call the registered callback if any
    if (gMouseEventCallback) {
        gMouseEventCallback(eventType, screenLocation, windowLocation,
                           buttonNumber, clickCount, gMouseEventUserInfo);
    }
}

// ============================================================================
// MARK: - Default Mouse Handler (connects to Metal renderer)
// ============================================================================

static void DefaultMouseEventHandler(
    CGSEventType eventType,
    CGPoint screenLocation,
    CGPoint windowLocation,
    int buttonNumber,
    int clickCount,
    void *userInfo) 
{
    // Update metal renderer with mouse position
    MetalRendererSetMousePosition(windowLocation);

    // Handle mouse down/up for dragging
    switch (eventType) {
        case kCGSEventLeftMouseDown:
            MetalRendererSetMouseDown(true);
            break;
        case kCGSEventLeftMouseUp:
            MetalRendererSetMouseDown(false);
            break;
        case kCGSEventLeftMouseDragged:
            // Position already updated above
            break;
        default:
            break;
    }
}

// ============================================================================
// MARK: - Mouse Event Hook
// ============================================================================

// Hook for WSMouseEventProcessor event_dispatch:annotationParams:dispatcher:
static __int64 MouseEventDispatch_Hook(id self, SEL sel, SLSEventRecord *event, id annotationParams, id dispatcher) {
    // Process the event for our window
    ProcessMouseEvent(event);

    // Call original implementation
    return _MouseEventDispatch_Orig(self, sel, event, annotationParams, dispatcher);
}

void SetupMouseEvents(void) {
    // Hook mouse event processor
    HOOK_INSTANCE_METHOD(
        NSClassFromString(@"WSMouseEventProcessor"),
        NSSelectorFromString(@"event_dispatch:annotationParams:dispatcher:"),
        MouseEventDispatch_Hook,
        (IMP *)&_MouseEventDispatch_Orig
    );

    NSLog(@"[Protein] Mouse event hook installed");
    
    // Register default mouse handler for Metal renderer interaction
    ProteinSetMouseEventCallback(DefaultMouseEventHandler, NULL);
    NSLog(@"[Protein] Default mouse handler registered");
}
