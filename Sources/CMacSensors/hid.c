// Sensor readout through the private IOHIDEventSystemClient API.
//
// The approach (matching Apple vendor usage pages and copying temperature /
// power events) is the one used by exelban/stats (MIT License,
// https://github.com/exelban/stats, Modules/Sensors/bridge.h and reader).
// Declarations are written here independently; they are not part of the
// public SDK and may change between macOS releases.

#include "CMacSensors.h"
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

// Public in the SDK: IOHIDEventSystemClientRef, IOHIDServiceClientRef,
// IOHIDEventSystemClientCopyServices, IOHIDServiceClientCopyProperty.
// The declarations below are private (exported by IOKit, not in the headers).
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                                 int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

static CFNumberRef FSCreateInt32(int32_t value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
}

CFTypeRef FSHIDClientCreate(int32_t usagePage, int32_t usage) {
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) return NULL;

    CFNumberRef page = FSCreateInt32(usagePage);
    CFNumberRef use = FSCreateInt32(usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page, use };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(page);
    CFRelease(use);
    return client;
}

CFArrayRef FSHIDClientCopyReadings(CFTypeRef client, int64_t eventType) {
    CFArrayRef services = IOHIDEventSystemClientCopyServices((IOHIDEventSystemClientRef)client);
    if (services == NULL) return NULL;

    CFMutableArrayRef result = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    int32_t field = (int32_t)(eventType << 16);
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (service == NULL) continue;

        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        CFTypeRef location = IOHIDServiceClientCopyProperty(service, CFSTR("LocationID"));
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, eventType, 0, 0);
        if (name != NULL && CFGetTypeID(name) == CFStringGetTypeID() && event != NULL) {
            double value = IOHIDEventGetFloatValue(event, field);
            CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &value);
            const void *keys[] = { CFSTR("name"), CFSTR("value"), CFSTR("locationID") };
            const void *values[] = { name, number, location };
            CFIndex pairs = (location != NULL && CFGetTypeID(location) == CFNumberGetTypeID()) ? 3 : 2;
            CFDictionaryRef entry = CFDictionaryCreate(kCFAllocatorDefault, keys, values, pairs,
                                                       &kCFTypeDictionaryKeyCallBacks,
                                                       &kCFTypeDictionaryValueCallBacks);
            CFArrayAppendValue(result, entry);
            CFRelease(entry);
            CFRelease(number);
        }
        if (event != NULL) CFRelease(event);
        if (name != NULL) CFRelease(name);
        if (location != NULL) CFRelease(location);
    }
    CFRelease(services);
    return result;
}
