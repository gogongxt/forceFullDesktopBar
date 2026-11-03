#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <objc/objc-runtime.h>
#import <dlfcn.h>
#include "frida-gum.h"

#define VERBOSE

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"

#define dockSwipeGesturePhase 123
#define dockSwipeGestureMotion 134
#define dockSwipeEvent 30
#define kIOHIDGestureMotionVerticalY 2
#define kIOHIDGestureMotionDoubleTap 6

// Undocumented CoreGraphics function:
CGPoint CGSCurrentInputPointerPosition(void);

static IMP originalMissionControlSetupSpacesStripControllerForDisplay;
static IMP originalChangeMode;
static IMP originalHandleEvent;
static int mouseOverrideCount = 0;

// NSLog output from code injected into the Dock doesn't show up in the unified
// log on recent macOS versions, so when VERBOSE is defined we also mirror log
// messages to a file to make diagnosis possible.
static void fdbLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"%@", message);

#ifdef VERBOSE
    FILE *logFile = fopen("/tmp/forceFullDesktopBar.log", "a");
    if (logFile) {
        fprintf(logFile, "%s %s\n", [[NSDate date] description].UTF8String, message.UTF8String);
        fclose(logFile);
    }
#endif
}

static void swizzle_missionControlSetupSpacesStripControllerForDisplay(id self, SEL _cmd, void *arg2, bool arg3)
{
    void (*originalFunction)(id, SEL, void *, bool) = (void (*)(id, SEL, void *, bool))originalMissionControlSetupSpacesStripControllerForDisplay;
    originalFunction(self, _cmd, arg2, true);
}

static CGPoint moveToTopOfScreen(CGPoint p)
{
    CGDirectDisplayID displayContainingCursor;
    uint32_t matchingDisplayCount = 0;

    CGGetDisplaysWithPoint(p, 1, &displayContainingCursor, &matchingDisplayCount);

    if (matchingDisplayCount >= 1) {
        CGRect rect = CGDisplayBounds(displayContainingCursor);
        p.y = rect.origin.y+1;
        return p;

    } else {
        fdbLog(@"forceFullDesktopBar error: could not determine which screen contains mouse coordinates (%f %f)", p.x, p.y);
        return p;
    }
}

static void swizzle_changeMode(id self, SEL _cmd, long long mode)
{
#ifdef VERBOSE
    fdbLog(@"forceFullDesktopBar: caught dock changing mode to: %lld", mode);
#endif
    if (mode == 1) {
#ifdef VERBOSE
        fdbLog(@"forceFullDesktopBar: Caught dock changing mode, will override pointer position");
#endif
        mouseOverrideCount = 1;
    }

    void (*originalFunction)(id, SEL, long long) = (void (*)(id, SEL, long long))originalChangeMode;
    originalFunction(self, _cmd, mode);
}

static bool isStartOfTrackpadSwipeUpEvent(CGEventType type, CGGesturePhase phase, uint64_t direction)
{
    return type == dockSwipeEvent && phase == kCGGesturePhaseBegan && direction == kIOHIDGestureMotionVerticalY;
}

static bool isDoubleTapEvent(CGEventType type, CGGesturePhase phase, uint64_t direction)
{
    return type == dockSwipeEvent && phase == kCGGesturePhaseNone && direction == kIOHIDGestureMotionDoubleTap;
}

static void checkDockEvent(CGEventRef event)
{
    if (!event) {
        return;
    }

    CGEventType type = CGEventGetType(event);
    CGGesturePhase phase = (CGGesturePhase)CGEventGetIntegerValueField(event, dockSwipeGestureMotion);
    uint64_t direction = (CGGesturePhase)CGEventGetIntegerValueField(event, dockSwipeGesturePhase);

    if (isStartOfTrackpadSwipeUpEvent(type, phase, direction)) {
#ifdef VERBOSE
        fdbLog(@"forceFullDesktopBar: Caught beginning of vertical swipe, will override pointer position");
#endif
        mouseOverrideCount = 2;

    } else if (isDoubleTapEvent(type, phase, direction)) {
#ifdef VERBOSE
        fdbLog(@"forceFullDesktopBar: Caught magic mouse double tap, will override pointer position");
#endif
        mouseOverrideCount = 2;
    }
}

static void swizzle_handleEvent(id self, SEL _cmd, CGEventRef event)
{
    checkDockEvent(event);
    void (*originalFunction)(id, SEL, CGEventRef) = (void (*)(id, SEL, CGEventRef))originalHandleEvent;
    originalFunction(self, _cmd, event);
}

static void swizzle_handleEventWithType(id self, SEL _cmd, CGEventRef event, CGEventType type)
{
    checkDockEvent(event);
    void (*originalFunction)(id, SEL, CGEventRef, CGEventType) = (void (*)(id, SEL, CGEventRef, CGEventType))originalHandleEvent;
    originalFunction(self, _cmd, event, type);
}

static CGPoint overrideCGSCurrentInputPointerPosition(void)
{
    CGPoint result = CGSCurrentInputPointerPosition();

    if (mouseOverrideCount > 0) {
        mouseOverrideCount -= 1;
        result = moveToTopOfScreen(result);
#ifdef VERBOSE
        fdbLog(@"forceFullDesktopBar: overriding pointer position to: %f %f", result.x, result.y);
#endif
    }

    return result;
}

bool swizzleMethod(NSString *className, SEL orig, IMP newMethod, IMP *originalFunction)
{
    id targetClass = NSClassFromString(className);

    if (!targetClass) {
        fdbLog(@"forceFullDesktopBar error: Unable to find %@ class", className);
        return false;
    }

    Method origMethod = class_getInstanceMethod(targetClass, orig);

    if (!origMethod) {
        fdbLog(@"forceFullDesktopBar error: Unable to find target method in %@ class", className);
        return false;
    }

    (*originalFunction) = method_getImplementation(origMethod);
    method_setImplementation(origMethod, newMethod);

    fdbLog(@"forceFullDesktopBar: Successfully swizzled target method in %@ class", className);
    return true;
}

#ifdef VERBOSE
// Logs every registered class that implements the given selector itself, which
// helps tracking down where a method moved to when a macOS update renames or
// relocates the classes we swizzle.
static void logClassesImplementingSelector(SEL selector, NSString *selectorName)
{
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);

    if (!allClasses) {
        return;
    }

    NSMutableArray *implementers = [NSMutableArray array];
    for (unsigned int i = 0; i < classCount; i++) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(allClasses[i], &methodCount);

        for (unsigned int j = 0; j < methodCount; j++) {
            if (method_getName(methods[j]) == selector) {
                [implementers addObject:NSStringFromClass(allClasses[i])];
                break;
            }
        }

        if (methods) {
            free(methods);
        }
    }
    free(allClasses);

    fdbLog(@"forceFullDesktopBar: classes implementing %@: %@", selectorName, implementers);
}
#endif

void macOS10_11Method(void)
{
    swizzleMethod(@"WVExpose",
                  @selector(_missionControlSetupSpacesStripControllerForDisplay:showFullBar:),
                  (IMP)swizzle_missionControlSetupSpacesStripControllerForDisplay,
                  &originalMissionControlSetupSpacesStripControllerForDisplay);
}

bool swizzleWVExposeMethod(void)
{
    // In macOS 26 (Tahoe), the Dock's Swift code moved from the "Dock" module
    // into "DockCore", changing the runtime class name from _TtC4Dock8WVExpose
    // to _TtC8DockCore8WVExpose, so try each known name in turn.
    NSArray *candidateClassNames = @[@"_TtC8DockCore8WVExpose",
                                      @"_TtC4Dock8WVExpose",
                                      @"WVExpose"];

    for (NSString *className in candidateClassNames) {
        if (swizzleMethod(className, @selector(changeMode:), (IMP)swizzle_changeMode,
                          &originalChangeMode)) {
            return true;
        }
    }

#ifdef VERBOSE
    logClassesImplementingSelector(@selector(changeMode:), @"changeMode:");
#endif

    fdbLog(@"forceFullDesktopBar: unable to swizzle WVExpose method, cannot proceed.");

    return false;
}

bool swizzleDOCKGesturesMethod(void)
{
    bool success = swizzleMethod(@"DOCKGestures", @selector(handleEvent:), (IMP)swizzle_handleEvent,
                                 &originalHandleEvent);

    if (success) {
        return true;
    }

    fdbLog(@"forceFullDesktopBar: unable to swizzle [DOCKGestures handleEvent:], trying another");

    success = swizzleMethod(@"DOCKGestures", @selector(handleEvent:type:), (IMP)swizzle_handleEventWithType,
                            &originalHandleEvent);

    if (success) {
        return true;
    }

#ifdef VERBOSE
    logClassesImplementingSelector(@selector(handleEvent:type:), @"handleEvent:type:");
#endif

    fdbLog(@"forceFullDesktopBar: unable to swizzle DOCKGestures method");

    return false;
}

void macOS10_13AndLaterMethod(void)
{
    if (!swizzleWVExposeMethod()) {
        return;
    }

    // If the gestures class can't be swizzled we still install the rest, since
    // Mission Control can also be entered through paths that end up in
    // changeMode: (keyboard shortcuts, hot corners).
    if (!swizzleDOCKGesturesMethod()) {
        fdbLog(@"forceFullDesktopBar: continuing without gesture event interception");
    }

    fdbLog(@"forceFullDesktopBar: starting interception");
    GumInterceptor * interceptor;

    gum_init_embedded();
    interceptor = gum_interceptor_obtain();

    if (!interceptor) {
        fdbLog(@"forceFullDesktopBar error: gum_interceptor_obtain failed ... cannot proceed");
        return;
    }

    gum_interceptor_begin_transaction(interceptor);

    GumAddress funcAddr = 0;
    GError *error = nil;
    GumModule *module = gum_module_load("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", &error);

    if (module) {
        funcAddr = gum_module_find_export_by_name(module, "CGSCurrentInputPointerPosition");
    } else {
        fdbLog(@"forceFullDesktopBar error: gum_module_load failed");

        if (error && error->message) {
            fdbLog(@"forceFullDesktopBar error message: %s", error->message);
        }
    }

    // In macOS 26 (Tahoe) the Dock no longer exports this symbol; it's only
    // exported by SkyLight, so fall back to a lookup among the images already
    // loaded in the process.
    if (!funcAddr) {
        void *symbol = dlsym(RTLD_DEFAULT, "CGSCurrentInputPointerPosition");

        if (symbol) {
            funcAddr = (GumAddress)symbol;
            fdbLog(@"forceFullDesktopBar: resolved CGSCurrentInputPointerPosition through dlsym");
        }
    }

    if (!funcAddr) {
        fdbLog(@"forceFullDesktopBar error: unable to find CGSCurrentInputPointerPosition ... cannot proceed");
        gum_interceptor_end_transaction(interceptor);
        return;
    }

    GumReplaceReturn result = gum_interceptor_replace(interceptor, (gpointer) funcAddr, overrideCGSCurrentInputPointerPosition, NULL, NULL);

    if (result != GUM_REPLACE_OK) {
        fdbLog(@"forceFullDesktopBar error: gum_interceptor_replace failed with result: %d ... cannot proceed", result);
        gum_interceptor_end_transaction(interceptor);
        return;
    }

    gum_interceptor_end_transaction (interceptor);

    fdbLog(@"forceFullDesktopBar: successfully rebound CGSCurrentInputPointerPosition symbol");
}

__attribute__((constructor)) static void install(void)
{
    fdbLog(@"forceFullDesktopBar: dockInjection installed and running");

    NSInteger osxMajorVersion = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    NSInteger osxMinorVersion = [[NSProcessInfo processInfo] operatingSystemVersion].minorVersion;

    @autoreleasepool {
        if (osxMajorVersion == 10 && osxMinorVersion == 11) {
            fdbLog(@"forceFullDesktopBar: Using 10.11 method...");
            macOS10_11Method();
        } else if (osxMajorVersion >= 11 || osxMinorVersion >= 13) {
            fdbLog(@"forceFullDesktopBar: Using 10.13 and later method...");
            macOS10_13AndLaterMethod();
        } else {
            fdbLog(@"forceFullDesktopBar error: macOS %ld.%ld is not supported", osxMajorVersion, osxMinorVersion);
        }
    }
}

#pragma clang diagnostic pop
