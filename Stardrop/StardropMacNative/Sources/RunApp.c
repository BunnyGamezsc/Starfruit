#include "RunApp.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>

// The event tap, Swift settings callbacks, and repeat worker use distinct threads.
// All shared configuration/lifecycle state belongs to this mutex.
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gCondition = PTHREAD_COND_INITIALIZER;
static bool gShouldQuit = true;
static bool gAssignedTriggerDown = false;
static bool gUseMouseTrigger = true;
static int gTriggerMouseButton = 2;
static uint16_t gTriggerKeyCode = 0;
static uint64_t gTriggerModifierMask = 0;
static int gRepeatMilliseconds = 200;
static CFMachPortRef gEventTap = NULL; // accessed only by the tap run loop
static const int64_t gSyntheticEventTag = 0x5354415246525549LL;

static uint64_t compactModifierMask(CGEventFlags flags) {
    uint64_t mask = 0;
    if (flags & kCGEventFlagMaskControl) mask |= 1ULL << 0;
    if (flags & kCGEventFlagMaskCommand) mask |= 1ULL << 1;
    if (flags & kCGEventFlagMaskAlternate) mask |= 1ULL << 2;
    if (flags & kCGEventFlagMaskShift) mask |= 1ULL << 3;
    if (flags & kCGEventFlagMaskSecondaryFn) mask |= 1ULL << 4;
    return mask;
}

static void postTagged(CGEventRef event, CGEventTapLocation location) {
    if (event) {
        CGEventSetIntegerValueField(event, kCGEventSourceUserData, gSyntheticEventTag);
        CGEventPost(location, event);
    }
}

static void cancelAnimation(void) {
    const CGKeyCode keys[] = {kVK_RightShift, kVK_ANSI_R, kVK_ForwardDelete};
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStatePrivate);
    if (!source) return;
    CGEventRef down[3] = {NULL, NULL, NULL};
    CGEventRef up[3] = {NULL, NULL, NULL};
    for (int i = 0; i < 3; i++) {
        down[i] = CGEventCreateKeyboardEvent(source, keys[i], true);
        up[i] = CGEventCreateKeyboardEvent(source, keys[i], false);
    }
    if (down[0] && down[1] && down[2] && up[0] && up[1] && up[2]) {
        for (int i = 0; i < 3; i++) postTagged(down[i], kCGSessionEventTap);
        usleep(20000);
        for (int i = 0; i < 3; i++) postTagged(up[i], kCGSessionEventTap);
    }
    for (int i = 0; i < 3; i++) {
        if (down[i]) CFRelease(down[i]);
        if (up[i]) CFRelease(up[i]);
    }
    CFRelease(source);
}

static void synthesizeLeftClick(void) {
    CGEventRef current = CGEventCreate(NULL);
    if (!current) return;
    CGPoint location = CGEventGetLocation(current);
    CFRelease(current);
    CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, location, kCGMouseButtonLeft);
    CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, location, kCGMouseButtonLeft);
    if (down && up) {
        postTagged(down, kCGHIDEventTap);
        usleep(20000);
        postTagged(up, kCGHIDEventTap);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

static void *repeatWorker(void *unused) {
    (void)unused;
    pthread_mutex_lock(&gLock);
    while (!gShouldQuit) {
        while (!gAssignedTriggerDown && !gShouldQuit) pthread_cond_wait(&gCondition, &gLock);
        if (gShouldQuit) break;
        int delay = gRepeatMilliseconds;
        pthread_mutex_unlock(&gLock);
        synthesizeLeftClick();
        pthread_mutex_lock(&gLock);
        struct timespec deadline;
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_nsec += (long)delay * 1000000L;
        deadline.tv_sec += deadline.tv_nsec / 1000000000L;
        deadline.tv_nsec %= 1000000000L;
        int result = 0;
        while (gAssignedTriggerDown && !gShouldQuit && result == 0) {
            result = pthread_cond_timedwait(&gCondition, &gLock, &deadline);
        }
        if (!gAssignedTriggerDown || gShouldQuit) continue;
        pthread_mutex_unlock(&gLock);
        cancelAnimation();
        pthread_mutex_lock(&gLock);
    }
    pthread_mutex_unlock(&gLock);
    return NULL;
}

static CGEventRef CGEventCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    (void)proxy; (void)refcon;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gEventTap) CGEventTapEnable(gEventTap, true);
        return event;
    }
    if (!event || CGEventGetIntegerValueField(event, kCGEventSourceUserData) == gSyntheticEventTag) return event;
    pthread_mutex_lock(&gLock);
    if (gShouldQuit) {
        pthread_mutex_unlock(&gLock);
        return event;
    }
    uint64_t modifiers = compactModifierMask(CGEventGetFlags(event));
    if (type == kCGEventFlagsChanged) {
        if (modifiers != gTriggerModifierMask) gAssignedTriggerDown = false;
    } else if (gUseMouseTrigger) {
        bool down = type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
        bool up = type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
        if (down || up) {
            int button = (type == kCGEventRightMouseDown || type == kCGEventRightMouseUp)
                ? 1 : (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
            if (button == gTriggerMouseButton && button > 0) {
                if (up) gAssignedTriggerDown = false;
                else if (modifiers == gTriggerModifierMask) gAssignedTriggerDown = true;
            }
        }
    } else if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
        uint16_t code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (code == gTriggerKeyCode) {
            if (type == kCGEventKeyUp) gAssignedTriggerDown = false;
            else if (modifiers == gTriggerModifierMask) gAssignedTriggerDown = true;
        }
    }
    pthread_cond_broadcast(&gCondition);
    pthread_mutex_unlock(&gLock);
    return event;
}

// Called synchronously before dispatching runApp, so a stop request made while
// the worker is queued cannot be erased by that worker starting later.
void prepareApp(void) {
    pthread_mutex_lock(&gLock);
    gShouldQuit = false;
    gAssignedTriggerDown = false;
    pthread_mutex_unlock(&gLock);
}

void runApp(void) {
    pthread_mutex_lock(&gLock);
    bool shouldRun = !gShouldQuit;
    pthread_mutex_unlock(&gLock);
    if (!shouldRun) return;
    CGEventMask mask = CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp)
        | CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp)
        | CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
    gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, 0, mask, CGEventCallback, NULL);
    if (!gEventTap) return;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    if (!source) {
        CFRelease(gEventTap);
        gEventTap = NULL;
        return;
    }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    pthread_t worker;
    if (pthread_create(&worker, NULL, repeatWorker, NULL) != 0) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CFRelease(source);
        CFRelease(gEventTap);
        gEventTap = NULL;
        return;
    }
    CGEventTapEnable(gEventTap, true);
    while (true) {
        pthread_mutex_lock(&gLock);
        bool quit = gShouldQuit;
        pthread_mutex_unlock(&gLock);
        if (quit) break;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
    }
    pthread_join(worker, NULL);
    CGEventTapEnable(gEventTap, false);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFRelease(gEventTap);
    gEventTap = NULL;
}

void stopApp(void) {
    pthread_mutex_lock(&gLock);
    gShouldQuit = true;
    gAssignedTriggerDown = false;
    pthread_cond_broadcast(&gCondition);
    pthread_mutex_unlock(&gLock);
}

bool isAccessibilityEnabled(void) { return AXIsProcessTrusted(); }

void setRepeatIntervalMilliseconds(int milliseconds) {
    pthread_mutex_lock(&gLock);
    gRepeatMilliseconds = milliseconds < 1 ? 1 : milliseconds > 500 ? 500 : milliseconds;
    pthread_mutex_unlock(&gLock);
}

void setMouseTrigger(int buttonNumber, uint64_t modifiersMask) {
    pthread_mutex_lock(&gLock);
    gAssignedTriggerDown = false;
    gUseMouseTrigger = true;
    gTriggerMouseButton = buttonNumber > 0 ? buttonNumber : 2;
    gTriggerModifierMask = modifiersMask & 31;
    pthread_cond_broadcast(&gCondition);
    pthread_mutex_unlock(&gLock);
}

void setKeyTrigger(uint16_t keyCode, uint64_t modifiersMask) {
    pthread_mutex_lock(&gLock);
    gAssignedTriggerDown = false;
    gUseMouseTrigger = false;
    gTriggerKeyCode = keyCode;
    gTriggerModifierMask = modifiersMask & 31;
    pthread_cond_broadcast(&gCondition);
    pthread_mutex_unlock(&gLock);
}
