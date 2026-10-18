#include "../Sources/RunApp.c"
#include <assert.h>
#include <stdio.h>
int main(void) {
    prepareApp();
    setKeyTrigger(49, 0);
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 49, true);
    CGEventRef unrelatedUp = CGEventCreateKeyboardEvent(NULL, 12, false);
    CGEventRef triggerUp = CGEventCreateKeyboardEvent(NULL, 49, false);
    assert(down && unrelatedUp && triggerUp);
    CGEventSetFlags(down, 0);
    CGEventCallback(NULL, kCGEventKeyDown, down, NULL);
    assert(gAssignedTriggerDown);
    CGEventCallback(NULL, kCGEventKeyUp, unrelatedUp, NULL);
    assert(gAssignedTriggerDown);
    CGEventSourceRef privateSource = CGEventSourceCreate(kCGEventSourceStatePrivate);
    CGEventRef syntheticUp = CGEventCreateKeyboardEvent(privateSource, 49, false);
    CGEventSetIntegerValueField(syntheticUp, kCGEventSourceUserData, gSyntheticEventTag);
    CGEventCallback(NULL, kCGEventKeyUp, syntheticUp, NULL);
    assert(gAssignedTriggerDown);
    CGEventCallback(NULL, kCGEventKeyUp, triggerUp, NULL);
    assert(!gAssignedTriggerDown);
    CFRelease(syntheticUp); CFRelease(privateSource);
    setMouseTrigger(2, 1);
    CGEventRef mouse = CGEventCreateMouseEvent(NULL, kCGEventOtherMouseDown, CGPointZero, kCGMouseButtonCenter);
    CGEventSetFlags(mouse, kCGEventFlagMaskControl);
    CGEventCallback(NULL, kCGEventOtherMouseDown, mouse, NULL);
    assert(gAssignedTriggerDown);
    CGEventSetFlags(mouse, 0);
    CGEventCallback(NULL, kCGEventFlagsChanged, mouse, NULL);
    assert(!gAssignedTriggerDown);
    assert(compactModifierMask(kCGEventFlagMaskSecondaryFn) == 16);
    stopApp();
    runApp(); // must return without starting any event tap after queued stop
    assert(gEventTap == NULL);
    CFRelease(down); CFRelease(unrelatedUp); CFRelease(triggerUp); CFRelease(mouse);
    puts("PASS: exact key release, synthetic exclusion, modifier release, Fn, stop-before-start (no events posted)");
    return 0;
}
