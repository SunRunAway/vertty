#include "vertty_shim.h"

// CGWindowListCreateImage is deprecated in favor of ScreenCaptureKit, which
// needs the screen recording permission even for our own windows.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
CGImageRef vertty_window_image(CGWindowID window) {
    return CGWindowListCreateImage(CGRectNull, kCGWindowListOptionIncludingWindow, window,
                                   kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
}
#pragma clang diagnostic pop
