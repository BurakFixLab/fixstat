// ATA / SATA (AHCI) SMART via the ATASMARTLib CFPlugIn that macOS attaches to SMART
// capable ATA block devices ("SMART Capable" = Yes): the PCIe AHCI SSDs of Intel Macs up to
// about 2015, SATA SSDs and hard disks of iMacs and Mac minis. No root privileges needed.
//
// Read-only: only IDENTIFY DEVICE, SMART RETURN STATUS, READ DATA and READ THRESHOLDS are
// issued. SMART is never enabled, disabled or self-tested from here.

#include "CMacSensors.h"
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <string.h>
#include <unistd.h>

enum { StepPlugin, StepInterface, StepIdentify, StepRead, StepRetry, StepParentPlugin, StepParentRead };

/// Opens the SMART interface of `service`; records the plugin and interface results.
static IOATASMARTInterface **open_smart(io_service_t service, IOCFPlugInInterface ***outPlugin,
                                        kern_return_t *pluginStep, kern_return_t *interfaceStep) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(service, kIOATASMARTUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    *pluginStep = (kr == KERN_SUCCESS && plugin == NULL) ? kIOReturnError : kr;
    if (kr != KERN_SUCCESS || plugin == NULL) return NULL;
    IOATASMARTInterface **smart = NULL;
    HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart);
    if (interfaceStep) *interfaceStep = (result == S_OK && smart != NULL) ? KERN_SUCCESS : kIOReturnUnsupported;
    if (result != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return NULL;
    }
    *outPlugin = plugin;
    return smart;
}

static void close_smart(IOATASMARTInterface **smart, IOCFPlugInInterface **plugin) {
    if (smart) (*smart)->Release(smart);
    if (plugin) IODestroyPlugInInterface(plugin);
}

/// Thresholds (optional, obsolete in newer ATA standards: zeros when unsupported) and status.
static void read_rest(IOATASMARTInterface **smart, uint8_t *outThresholds512, int *outExceeded) {
    ATASMARTDataThresholds thresholds;
    memset(&thresholds, 0, sizeof(thresholds));
    if ((*smart)->SMARTReadDataThresholds(smart, &thresholds) == KERN_SUCCESS) {
        memcpy(outThresholds512, &thresholds, 512);
    } else {
        memset(outThresholds512, 0, 512);
    }
    Boolean exceeded = false;
    *outExceeded = (*smart)->SMARTReturnStatus(smart, &exceeded) == KERN_SUCCESS ? (exceeded ? 1 : 0) : -1;
}

kern_return_t FSATAReadSMART(io_service_t device, uint8_t *outData512, uint8_t *outThresholds512,
                             int *outExceeded, kern_return_t *outSteps) {
    for (int i = 0; i < FSATAStepCount; i++) outSteps[i] = FSATAStepNotRun;
    ATASMARTData data;

    IOCFPlugInInterface **plugin = NULL;
    IOATASMARTInterface **smart = open_smart(device, &plugin, &outSteps[StepPlugin], &outSteps[StepInterface]);
    if (smart) {
        // smartmontools identifies the drive before any SMART command; some drives or
        // drivers only answer READ DATA after it.
        uint8_t identify[512];
        UInt32 count = 0;
        outSteps[StepIdentify] = (*smart)->GetATAIdentifyData(smart, identify, sizeof(identify), &count);

        memset(&data, 0, sizeof(data));
        kern_return_t kr = (*smart)->SMARTReadData(smart, &data);
        outSteps[StepRead] = kr;
        if (kr != KERN_SUCCESS) {
            usleep(200000);
            memset(&data, 0, sizeof(data));
            kr = (*smart)->SMARTReadData(smart, &data);
            outSteps[StepRetry] = kr;
        }
        if (kr == KERN_SUCCESS) {
            memcpy(outData512, &data, 512);
            read_rest(smart, outThresholds512, outExceeded);
            close_smart(smart, plugin);
            return KERN_SUCCESS;
        }
        close_smart(smart, plugin);
    }

    // The SMART user client may belong to the driver above the block storage device.
    io_registry_entry_t parent = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(device, kIOServicePlane, &parent) == KERN_SUCCESS) {
        plugin = NULL;
        smart = open_smart(parent, &plugin, &outSteps[StepParentPlugin], NULL);
        if (smart) {
            memset(&data, 0, sizeof(data));
            kern_return_t kr = (*smart)->SMARTReadData(smart, &data);
            outSteps[StepParentRead] = kr;
            if (kr == KERN_SUCCESS) {
                memcpy(outData512, &data, 512);
                read_rest(smart, outThresholds512, outExceeded);
            }
            close_smart(smart, plugin);
            IOObjectRelease(parent);
            if (kr == KERN_SUCCESS) return KERN_SUCCESS;
        } else {
            IOObjectRelease(parent);
        }
    }
    // The most informative failure: the read on the device itself, else how far it got.
    for (int i = StepRetry; i >= StepPlugin; i--) {
        if (outSteps[i] != FSATAStepNotRun && outSteps[i] != KERN_SUCCESS) return outSteps[i];
    }
    return kIOReturnError;
}
