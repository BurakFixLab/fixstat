// Ambient light sensor (read-only).
//
// Apple Silicon: the SPU ALS service in the HID event system (vendor usage page 0xFF00,
// usage 4, no Product name), event type 12 (kIOHIDEventTypeAmbientLightSensor); its first
// field is the level in lux.
// Intel: the AppleLMUController user client, selector 0 returns two raw channel values
// (older MacBooks; T2 Macs report through the HID event system as well).

#include "CMacSensors.h"
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                                 int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

enum { kALSEventType = 12 };

static IOHIDEventSystemClientRef alsClient = NULL;

bool FSAmbientLightLux(double *outLux) {
    if (alsClient == NULL) {
        alsClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (alsClient == NULL) return false;
        int32_t pageValue = 0xFF00, usageValue = 4;
        CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pageValue);
        CFNumberRef usage = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usageValue);
        const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
        const void *values[] = { page, usage };
        CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        IOHIDEventSystemClientSetMatching(alsClient, match);
        CFRelease(match);
        CFRelease(page);
        CFRelease(usage);
    }
    CFArrayRef services = IOHIDEventSystemClientCopyServices(alsClient);
    if (services == NULL) return false;
    bool found = false;
    for (CFIndex i = 0; i < CFArrayGetCount(services) && !found; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kALSEventType, 0, 0);
        if (event != NULL) {
            *outLux = IOHIDEventGetFloatValue(event, kALSEventType << 16);
            found = true;
            CFRelease(event);
        }
    }
    CFRelease(services);
    return found;
}

bool FSLMUReadChannels(uint64_t *outLeft, uint64_t *outRight) {
    io_service_t service = IOServiceGetMatchingService(MACH_PORT_NULL, IOServiceMatching("AppleLMUController"));
    if (service == IO_OBJECT_NULL) return false;
    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) return false;
    uint64_t values[2] = { 0, 0 };
    uint32_t count = 2;
    // Selector 0: read the sensor (no input, two scalar outputs). Nothing is written.
    result = IOConnectCallMethod(connection, 0, NULL, 0, NULL, 0, values, &count, NULL, NULL);
    IOServiceClose(connection);
    if (result != KERN_SUCCESS || count < 2) return false;
    *outLeft = values[0];
    *outRight = values[1];
    return true;
}
