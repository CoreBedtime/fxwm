//
//  protein_events.h
//  Protein Window Manager - Mouse Event API
//

#ifndef protein_events_h
#define protein_events_h

#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// MARK: - CGS Event Types
// ============================================================================

typedef enum CGSEventType {
    kCGSEventNull = 0,
    kCGSEventLeftMouseDown = 1,
    kCGSEventLeftMouseUp = 2,
    kCGSEventRightMouseDown = 3,
    kCGSEventRightMouseUp = 4,
    kCGSEventMouseMoved = 5,
    kCGSEventLeftMouseDragged = 6,
    kCGSEventRightMouseDragged = 7,
    kCGSEventMouseEntered = 8,
    kCGSEventMouseExited = 9,
    kCGSEventKeyDown = 10,
    kCGSEventKeyUp = 11,
    kCGSEventFlagsChanged = 12,
    kCGSEventScrollWheel = 22,
    kCGSEventOtherMouseDown = 25,
    kCGSEventOtherMouseUp = 26,
    kCGSEventOtherMouseDragged = 27,
} CGSEventType;

// ============================================================================
// MARK: - Mouse Event Callback
// ============================================================================

/**
 * Mouse event callback function type.
 *
 * @param eventType     The type of mouse event (e.g., kCGSEventLeftMouseDown)
 * @param screenLocation The mouse position in screen coordinates
 * @param windowLocation The mouse position relative to the protein window origin
 * @param buttonNumber   The mouse button number (0=left, 1=right, 2+=other)
 * @param clickCount     The click count for multi-click detection
 * @param userInfo       User-provided context pointer
 */
typedef void (*MouseEventCallback)(
    CGSEventType eventType,
    CGPoint screenLocation,
    CGPoint windowLocation,
    int buttonNumber,
    int clickCount,
    double deltaX,
    double deltaY,
    void *userInfo
);

// ============================================================================
// MARK: - Public API
// ============================================================================

/**
 * Register a callback to receive mouse events in the protein window.
 *
 * @param callback  Function to call when a mouse event occurs in the window.
 *                  Pass NULL to disable mouse event handling.
 * @param userInfo  User-provided pointer passed to the callback.
 *
 * Example usage:
 * @code
 * void MyMouseHandler(CGSEventType type, CGPoint screen, CGPoint window,
 *                     int button, int clicks, void *info) {
 *     if (type == kCGSEventLeftMouseDown) {
 *         NSLog(@"Left click at window position: %.0f, %.0f", window.x, window.y);
 *     }
 * }
 *
 * ProteinSetMouseEventCallback(MyMouseHandler, NULL);
 * @endcode
 */
void ProteinSetMouseEventCallback(MouseEventCallback callback, void *userInfo);

// ============================================================================
// MARK: - Helper Macros
// ============================================================================

/// Check if event is a mouse down event
#define IS_MOUSE_DOWN(type) \
    ((type) == kCGSEventLeftMouseDown || \
     (type) == kCGSEventRightMouseDown || \
     (type) == kCGSEventOtherMouseDown)

/// Check if event is a mouse up event
#define IS_MOUSE_UP(type) \
    ((type) == kCGSEventLeftMouseUp || \
     (type) == kCGSEventRightMouseUp || \
     (type) == kCGSEventOtherMouseUp)

/// Check if event is a mouse drag event
#define IS_MOUSE_DRAG(type) \
    ((type) == kCGSEventLeftMouseDragged || \
     (type) == kCGSEventRightMouseDragged || \
     (type) == kCGSEventOtherMouseDragged)

/// Check if event is any click-related event (down, up, or drag)
#define IS_MOUSE_CLICK_EVENT(type) \
    (IS_MOUSE_DOWN(type) || IS_MOUSE_UP(type) || IS_MOUSE_DRAG(type))

#ifdef __cplusplus
}
#endif

#endif /* protein_events_h */
