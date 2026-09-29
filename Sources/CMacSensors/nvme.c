// NVMe SMART / health log via the NVMeSMARTLib CFPlugIn that macOS attaches to
// NVMe block devices ("NVMe SMART Capable" = Yes). No root privileges needed.
//
// The plug-in type / interface UUIDs and the function table layout follow
// Apple's NVMeSMARTLibExternal.h (IOStorageFamily, APSL), as also used by
// smartmontools (os_darwin). Only SMARTReadData is called: it returns the
// standard 512-byte NVMe "SMART / Health Information" log page.

#include "CMacSensors.h"
#include <IOKit/IOCFPlugIn.h>
#include <string.h>

#define FS_NVME_SMART_USERCLIENT_TYPE CFUUIDGetConstantUUIDWithBytes(NULL, \
    0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
#define FS_NVME_SMART_INTERFACE CFUUIDGetConstantUUIDWithBytes(NULL, \
    0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

typedef struct {
    IUNKNOWN_C_GUTS;
    UInt16 version;
    UInt16 revision;
    IOReturn (*SMARTReadData)(void *interface, void *smartLog512);
    IOReturn (*GetIdentifyData)(void *interface, void *identify4096, unsigned int namespaceID);
} FSNVMeSMARTInterface;

static io_service_t FSFindSMARTCapableDevice(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDevice"), &iterator) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }
    io_service_t found = IO_OBJECT_NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(service, CFSTR("NVMe SMART Capable"), kCFAllocatorDefault, 0);
        Boolean yes = capable != NULL && CFGetTypeID(capable) == CFBooleanGetTypeID() && CFBooleanGetValue(capable);
        if (capable != NULL) CFRelease(capable);
        if (yes && found == IO_OBJECT_NULL) {
            found = service;
        } else {
            IOObjectRelease(service);
        }
    }
    IOObjectRelease(iterator);
    return found;
}

kern_return_t FSNVMeReadSMARTLog(uint8_t *outLog512) {
    io_service_t device = FSFindSMARTCapableDevice();
    if (device == IO_OBJECT_NULL) return kIOReturnNotFound;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(device, FS_NVME_SMART_USERCLIENT_TYPE,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(device);
    if (kr != KERN_SUCCESS || plugin == NULL) return kr != KERN_SUCCESS ? kr : kIOReturnError;

    FSNVMeSMARTInterface **smart = NULL;
    HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(FS_NVME_SMART_INTERFACE), (LPVOID *)&smart);
    if (result != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }

    // Larger scratch buffer in case an implementation writes past 512 bytes.
    uint8_t buffer[4096];
    memset(buffer, 0, sizeof(buffer));
    kr = (*smart)->SMARTReadData(smart, buffer);
    if (kr == KERN_SUCCESS) memcpy(outLog512, buffer, 512);

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return kr;
}
