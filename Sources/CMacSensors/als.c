// Ambient light sensor (read-only).
//
// Apple Silicon: the SPU ALS service in the HID event system (vendor usage page 0xFF00,
// usage 4, no Product name), event type 12 (kIOHIDEventTypeAmbientLightSensor); its first
// field is the level in lux.
// T2 Macs: the USB ambient light sensor behind the T2, also in the HID event system (sensor
// page 0x20, usage 0x41), same event and field.
// Intel without T2: the AppleLMUController user client, selector 0 returns two raw channel
// values (older MacBooks); 2016 / 2017 MacBook Pros have no LMU controller and report through
// the SMC instead (read in Swift).

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

// Apple Silicon's SPU service (vendor page 0xFF00, usage 4) and the T2's USB sensor
// (AppleUSBALSService: HID sensor page 0x20, usage 0x41 "ambient light"; MacBookPro15,1 dump).
static IOHIDEventSystemClientRef alsClients[2] = { NULL, NULL };
static const int32_t alsMatches[2][2] = { { 0xFF00, 4 }, { 0x20, 0x41 } };

static IOHIDEventSystemClientRef alsClient(int index) {
    if (alsClients[index] != NULL) return alsClients[index];
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client == NULL) return NULL;
    int32_t pageValue = alsMatches[index][0], usageValue = alsMatches[index][1];
    CFNumberRef page = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &pageValue);
    CFNumberRef usage = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &usageValue);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page, usage };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(page);
    CFRelease(usage);
    alsClients[index] = client;
    return client;
}

bool FSAmbientLightLux(double *outLux) {
    for (int index = 0; index < 2; index++) {
        IOHIDEventSystemClientRef client = alsClient(index);
        if (client == NULL) continue;
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (services == NULL) continue;
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
        if (found) return true;
    }
    return false;
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
