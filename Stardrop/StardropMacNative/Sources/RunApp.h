#ifndef RUNAPP_H
#define RUNAPP_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Reset a completed run before dispatching runApp. Call synchronously so a stop
// made while runApp is queued is preserved. Do not call while a run is active.
void prepareApp(void);

// Starts the CGEventTap event loop after prepareApp, until stopApp() is called.
// This function BLOCKS – call it from a background thread.
void runApp(void);

// Signals the run loop to stop and tears down the event tap.
void stopApp(void);

// Returns true if the process has Accessibility permissions.
bool isAccessibilityEnabled(void);

// Sets the repeat interval (left-click → delay → cancel combo) in milliseconds.
// Clamped to [1, 500].
void setRepeatIntervalMilliseconds(int milliseconds);

// Configures a mouse button as the trigger.
// buttonNumber: 0=left (avoid), 1=right, 2=middle, etc.
// modifiersMask: bitmask of required modifiers (ctrl=1, cmd=2, opt=4, shift=8, fn=16)
void setMouseTrigger(int buttonNumber, uint64_t modifiersMask);

// Configures a keyboard key as the trigger.
// keyCode: Carbon virtual key code.
// modifiersMask: same bitmask as above.
void setKeyTrigger(uint16_t keyCode, uint64_t modifiersMask);

#ifdef __cplusplus
}
#endif

#endif /* RUNAPP_H */
