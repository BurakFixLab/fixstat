// Raw trackpad contacts through the private MultitouchSupport framework (loaded with
// dlopen, so nothing links against it). Contacts arrive for the built-in trackpad no
// matter where the pointer is. Read-only; no permission is needed.
//
// The contact layout follows the one used by open-source tools built on this framework
// (e.g. OpenMultitouchSupport, MiddleClick): 96 bytes per contact on 64-bit macOS.

#include "CMacSensors.h"
#include <dlfcn.h>
#include <stddef.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTTouch;

typedef void *MTDeviceRef;
typedef void (*MTFrameCallback)(MTDeviceRef device, const MTTouch *touches, size_t count, double timestamp, size_t frame);

static MTDeviceRef (*pCreateDefault)(void);
static void (*pRegister)(MTDeviceRef, MTFrameCallback);
static void (*pUnregister)(MTDeviceRef, MTFrameCallback);
static int32_t (*pStart)(MTDeviceRef, int32_t);
static int32_t (*pStop)(MTDeviceRef);
static void (*pRelease)(MTDeviceRef);

static MTDeviceRef device;
static FSTouchCallback userCallback;
static void *userContext;

static int load(void) {
    static int loaded = -1;
    if (loaded >= 0) return loaded;
    void *lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (lib) {
        pCreateDefault = dlsym(lib, "MTDeviceCreateDefault");
        pRegister = dlsym(lib, "MTRegisterContactFrameCallback");
        pUnregister = dlsym(lib, "MTUnregisterContactFrameCallback");
        pStart = dlsym(lib, "MTDeviceStart");
        pStop = dlsym(lib, "MTDeviceStop");
        pRelease = dlsym(lib, "MTDeviceRelease"); // optional
    }
    loaded = lib && pCreateDefault && pRegister && pUnregister && pStart && pStop;
    return loaded;
}

static void frameCallback(MTDeviceRef dev, const MTTouch *touches, size_t count, double timestamp, size_t frame) {
    (void)dev; (void)frame;
    if (!userCallback) return;
    FSTouch out[FSTouchMax];
    int n = 0;
    for (size_t i = 0; i < count && n < FSTouchMax; i++) {
        // 3 = make touch, 4 = touching; hovering / lifting contacts are skipped.
        if (touches[i].state != 3 && touches[i].state != 4) continue;
        out[n].x = touches[i].normalized.position.x;
        out[n].y = touches[i].normalized.position.y;
        out[n].size = touches[i].zTotal;
        out[n].identifier = touches[i].pathIndex;
        n++;
    }
    userCallback(out, n, timestamp, userContext);
}

static void closeDevice(void) {
    if (!device) return;
    pUnregister(device, frameCallback);
    pStop(device);
    if (pRelease) pRelease(device);
    device = NULL;
}

/// Opens the default multitouch device afresh on every start: a device kept from an earlier
/// start can go stale (after sleep, or when the trackpad driver restarted) and then never
/// starts again. A second start while running hands the frames to the new caller.
bool FSMultitouchStart(FSTouchCallback callback, void *context) {
    if (!load()) return false;
    closeDevice();
    userCallback = callback;
    userContext = context;
    for (int attempt = 0; attempt < 2; attempt++) {
        device = pCreateDefault();
        if (!device) continue;
        pRegister(device, frameCallback);
        if (pStart(device, 0) == 0) return true;
        closeDevice();
    }
    userCallback = NULL;
    userContext = NULL;
    return false;
}

/// Stops only if `context` is the current caller: a test pane that closes after a new one
/// opened must not stop the new one's frames.
void FSMultitouchStop(void *context) {
    if (!load() || context != userContext) return;
    closeDevice();
    userCallback = NULL;
    userContext = NULL;
}
