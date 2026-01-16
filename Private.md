# Private WindowServer Documentation

## CGXStartSubsidiaryServices

`CGXStartSubsidiaryServices` is an internal WindowServer function that manages display-related services triggered at various points during session lifecycle. The function takes a single service ID parameter (0-10) and dispatches to appropriate CoreDisplay functions.

### Function Signature
```c
__int64 CGXStartSubsidiaryServices(__int64 serviceId)
```

### Service ID Bitmask Groups

The function uses bitmasks to categorize services:
- `0x6A` (binary: `01101010`) = Services 1, 3, 5, 6
- `0x600` (binary: `11000000000`) = Services 9, 10

### Subsidiary Services

| Service ID | Bitmask Group | Function Called | Trigger Context |
|------------|---------------|-----------------|-----------------|
| 0 | None (explicit check) | `CoreDisplay_UpdateDisplayProfiles(0, 80)` | Unknown/Init |
| 1 | 0x6A | `CoreDisplay_UpdateDisplayProfiles(sessionDisplayID)` | First window after login |
| 2 | Unhandled | N/A | N/A |
| 3 | 0x6A | `CoreDisplay_UpdateDisplayProfiles(sessionDisplayID)` | Unknown |
| 4 | Unhandled | N/A | N/A |
| 5 | 0x6A | `CoreDisplay_UpdateDisplayProfiles(sessionDisplayID)` | Unknown |
| 6 | 0x6A | `CoreDisplay_UpdateDisplayProfiles(sessionDisplayID)` | Unknown |
| 7 | Unhandled | N/A | N/A |
| 8 | Unhandled | N/A | N/A |
| **9** | 0x600 | **CoreDisplay vtable slot N** | **First window after login** |
| 10 | 0x600 | CoreDisplay vtable slot N+2 | Session creation, Console yield |

### Service 9 Analysis

Service 9 is called from `firstWindowAfterLoginNotifyProc` immediately after service 1:

```c
// From firstWindowAfterLoginNotifyProc
CGXStartSubsidiaryServices(1LL);
WSRemoveNotificationCallback(firstWindowAfterLoginNotifyProc, 1000LL, sessionID);
CGXStartSubsidiaryServices(9LL);
```

**Purpose**: Service 9 appears to handle post-login color profile initialization that occurs after the first window is displayed. It's called after the notification callback is removed, suggesting it's a one-time initialization task related to display profile configuration when a user's first window appears.

**Key characteristics**:
- Only triggered once per login (notification callback is removed before calling)
- Called with session display parameters (high/low DWORD split)
- Requires non-safe-mode (skipped if `gServerRunningInSafeMode` is set)
- Calls an internal CoreDisplay function via dynamic vtable lookup

### Service 10 Analysis

Service 10 is called during session management operations:

**Called from `createSessionWithOwner`**: During new session creation after workspace initialization
**Called from `yieldConsoleCallback`**: During console session switching

**Purpose**: Handles color profile restoration/reconfiguration when:
1. A new session is created
2. The console is yielded to a different session

### Safe Mode Behavior

All subsidiary services (0, 1, 3, 5, 6, 9, 10) are disabled when `gServerRunningInSafeMode` flag is set. This prevents display profile operations during safe mode boot.

### CoreDisplay VTable

The function references a CoreDisplay vtable loaded dynamically from `/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay`. The vtable contains 64 function pointers including:

- Display timing and VBL functions
- Content protection and Metal protection
- HDR mode control
- Preset management
- User adjustment handling
- Virtual display management

Services 9, 10, and `CoreDisplay_UpdateDisplayProfiles` all call functions from this vtable with display session parameters.

### Related Functions

- `CoreDisplay_UpdateDisplayProfiles` - Main display profile update function
- `firstWindowAfterLoginNotifyProc` - Notification callback for first window after login
- `yieldConsoleCallback` - Console session yield handler
- `createSessionWithOwner` - Session creation function
- `WSCoreDisplayVTable` - Dynamic vtable for CoreDisplay functions

### Notes

The specific CoreDisplay functions called by services 9 and 10 are resolved at runtime via dlsym() from CoreDisplay.framework. The vtable addresses (0x1EE404D80 and 0x1EE404D90 in the analyzed binary) contain placeholder values (-1) in the dyld shared cache and are populated when the vtable is initialized.

---

## CGXUpdateDisplay

`CGXUpdateDisplay` is the main display update function that triggers rendering updates across displays. It wraps `WS::Updater::UpdateDisplays` and handles the display vector construction.

### Function Signature
```c
__int64 CGXUpdateDisplay(
    void *connection,
    __int64 independentScheduleEnabled,
    __int64 displaysBegin,
    __int64 displaysEnd
)
```

### Arguments

| Argument | Type | Description |
|----------|------|-------------|
| `connection` | `CGXConnection*` | The connection requesting the update. Can be `NULL` for background/system-initiated updates. |
| `independentScheduleEnabled` | `bool` | Result of `WSIndependentDisplayScheduleEnabled()`. Controls whether displays are updated on independent schedules. |
| `displaysBegin` | `shared_ptr<Display>*` | Start pointer of the display array to update. |
| `displaysEnd` | `shared_ptr<Display>*` | End pointer of the display array (past-the-end iterator). |

### Internal Behavior

The function:
1. Constructs a `std::vector<std::shared_ptr<WS::Displays::Display>>` from the begin/end pointers
2. Calls `WS::Updater::UpdateDisplays(connection, independentScheduleEnabled, displayVector)`
3. Destroys the temporary vector
4. Returns the update result

### Callers

| Caller | connection | independentScheduleEnabled | Context |
|--------|------------|---------------------------|---------|
| `update_display_callback` | `NULL` | `WSIndependentDisplayScheduleEnabled()` | Scheduled display updates |
| `WSSchedulerRunDeferredUpdate` | Passed in | `0` (false) | Deferred update execution |
| `transitionTimerCallback` | `NULL` | `0` (false) | Animation/transition updates |

### Return Values

Returns the result from `WS::Updater::UpdateDisplays`:
- `10`: Indicates the display was not ready, triggering a reschedule in `WSSchedulerRunDeferredUpdate`
- Other values: Success or other status codes

### Related Functions

- `WS::Updater::UpdateDisplays` - The underlying C++ implementation
- `WSIndependentDisplayScheduleEnabled` - Returns whether independent display scheduling is active
- `update_display_callback` - Main scheduled update callback
- `WSSchedulerRunDeferredUpdate` - Handles deferred display updates
- `transitionTimerCallback` - Handles transition animation updates
