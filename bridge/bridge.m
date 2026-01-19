// tweak here
#import <Foundation/Foundation.h>
#include <objc/NSObject.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "dobby.h"

// Hook for NSWindow initialization to force headless mode
static id (*original_NSWindow_initWithContentRect_styleMask_backing_defer_)(id self, SEL _cmd, NSRect contentRect, NSWindowStyleMask styleMask, NSBackingStoreType backing, BOOL defer);
static id hooked_NSWindow_initWithContentRect_styleMask_backing_defer_(id self, SEL _cmd, NSRect contentRect, NSWindowStyleMask styleMask, NSBackingStoreType backing, BOOL defer);

// Hook for NSWindow _commonInitFrame to force defer mode
static void (*original_NSWindow__commonInitFrame_styleMask_backing_defer_)(id self, SEL _cmd, NSRect frame, NSWindowStyleMask styleMask, NSBackingStoreType backing, BOOL defer);
static void hooked_NSWindow__commonInitFrame_styleMask_backing_defer_(id self, SEL _cmd, NSRect frame, NSWindowStyleMask styleMask, NSBackingStoreType backing, BOOL defer);

// Hook for setCanHostLayersInWindowServer to disable WindowServer layer hosting
static void (*original_NSWindow_setCanHostLayersInWindowServer_)(id self, SEL _cmd, BOOL canHost);
static void hooked_NSWindow_setCanHostLayersInWindowServer_(id self, SEL _cmd, BOOL canHost);

// Hook for _setWindowNumber to prevent real WindowServer windows
static void (*original_NSWindow__setWindowNumber_)(id self, SEL _cmd, NSInteger windowNumber);
static void hooked_NSWindow__setWindowNumber_(id self, SEL _cmd, NSInteger windowNumber);

void (*OldPanic)(int64_t a1, int64_t a2);
void NSCGSPanicThub(int64_t a1, int64_t a2) {
    return;
}

extern
void * symrez_resolve_once(const char *image_name, const char *symbol);
@implementation NSWindow (HeadlessHooks)

+ (void)load {

    DobbyHook(symrez_resolve_once("AppKit", "_NSCGSPanicv"), (void *)NSCGSPanicThub, (void **)&OldPanic);

    // Hook NSWindow initialization methods
    Method initMethod = class_getInstanceMethod(self, @selector(initWithContentRect:styleMask:backing:defer:));
    original_NSWindow_initWithContentRect_styleMask_backing_defer_ = (typeof(original_NSWindow_initWithContentRect_styleMask_backing_defer_))method_getImplementation(initMethod);
    method_setImplementation(initMethod, (IMP)hooked_NSWindow_initWithContentRect_styleMask_backing_defer_);

    // Hook _commonInitFrame method
    Method commonInitMethod = class_getInstanceMethod(self, @selector(_commonInitFrame:styleMask:backing:defer:));
    original_NSWindow__commonInitFrame_styleMask_backing_defer_ = (typeof(original_NSWindow__commonInitFrame_styleMask_backing_defer_))method_getImplementation(commonInitMethod);
    method_setImplementation(commonInitMethod, (IMP)hooked_NSWindow__commonInitFrame_styleMask_backing_defer_);

    // Hook setCanHostLayersInWindowServer
    Method layerHostMethod = class_getInstanceMethod(self, @selector(setCanHostLayersInWindowServer:));
    if (layerHostMethod) {
        original_NSWindow_setCanHostLayersInWindowServer_ = (typeof(original_NSWindow_setCanHostLayersInWindowServer_))method_getImplementation(layerHostMethod);
        method_setImplementation(layerHostMethod, (IMP)hooked_NSWindow_setCanHostLayersInWindowServer_);
    }

    // Hook _setWindowNumber
    Method setWindowNumMethod = class_getInstanceMethod(self, @selector(_setWindowNumber:));
    if (setWindowNumMethod) {
        original_NSWindow__setWindowNumber_ = (typeof(original_NSWindow__setWindowNumber_))method_getImplementation(setWindowNumMethod);
        method_setImplementation(setWindowNumMethod, (IMP)hooked_NSWindow__setWindowNumber_);
    }
}

@end

// Hooked implementations
static id hooked_NSWindow_initWithContentRect_styleMask_backing_defer_(id self, SEL _cmd, NSRect contentRect, NSWindowStyleMask styleMask, NSBackingStoreType backing, BOOL defer) {
    // Force defer=YES to prevent immediate WindowServer connection
    id result = original_NSWindow_initWithContentRect_styleMask_backing_defer_(self, _cmd, contentRect, styleMask, backing, YES);

    if (result) {
        // Disable WindowServer layer hosting immediately after creation
        if ([result respondsToSelector:@selector(setCanHostLayersInWindowServer:)]) {
            [(NSWindow *)result setCanHostLayersInWindowServer:NO];
        }

        // Set window number to -1 to indicate no WindowServer connection
        if ([result respondsToSelector:@selector(_setWindowNumber:)]) {
            [(NSWindow *)result _setWindowNumber:-1];
        }
    }

    return result;
}

static void hooked_NSWindow__commonInitFrame_styleMask_backing_defer_(id self, SEL _cmd, NSRect frame, NSWindowStyleMask styleMask, NSBackingStoreType backing, BOOL defer) {
    // Force defer=YES regardless of what was passed
    original_NSWindow__commonInitFrame_styleMask_backing_defer_(self, _cmd, frame, styleMask, backing, YES);

    // Disable WindowServer layer hosting
    if ([self respondsToSelector:@selector(setCanHostLayersInWindowServer:)]) {
        [(NSWindow *)self setCanHostLayersInWindowServer:NO];
    }
}

static void hooked_NSWindow_setCanHostLayersInWindowServer_(id self, SEL _cmd, BOOL canHost) {
    // Always force NO to prevent WindowServer layer hosting
    original_NSWindow_setCanHostLayersInWindowServer_(self, _cmd, NO);
}

static void hooked_NSWindow__setWindowNumber_(id self, SEL _cmd, NSInteger windowNumber) {
    // Prevent setting real window numbers (keep at -1 for headless)
    if (windowNumber > 0) {
        // Replace positive window numbers with -1 to maintain headless state
        original_NSWindow__setWindowNumber_(self, _cmd, -1);
    } else {
        // Allow -1 or 0 to pass through
        original_NSWindow__setWindowNumber_(self, _cmd, windowNumber);
    }
}

@interface CAContext : NSObject
@end

// Additional hook for CAContext to prevent WindowServer connections
@interface CAContext (HeadlessHooks)
+ (void)load;
@end

@implementation CAContext (HeadlessHooks)

static id (*original_CAContext_contextWithCGSConnection_options_)(Class cls, SEL _cmd, int connection, NSDictionary *options);
static id hooked_CAContext_contextWithCGSConnection_options_(Class cls, SEL _cmd, int connection, NSDictionary *options);

+ (void)load {
    Method contextMethod = class_getClassMethod(objc_getClass("CAContext"), @selector(contextWithCGSConnection:options:));
    if (contextMethod) {
        original_CAContext_contextWithCGSConnection_options_ = (typeof(original_CAContext_contextWithCGSConnection_options_))method_getImplementation(contextMethod);
        method_setImplementation(contextMethod, (IMP)hooked_CAContext_contextWithCGSConnection_options_);
    }
}

@end

static id hooked_CAContext_contextWithCGSConnection_options_(Class cls, SEL _cmd, int connection, NSDictionary *options) {
    // Return nil to prevent CAContext creation with WindowServer connection
    // This forces client-side layer rendering
    return nil;
}
