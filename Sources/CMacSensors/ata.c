// ATA / SATA (AHCI) SMART via the ATASMARTLib CFPlugIn that macOS attaches to SMART
// capable ATA block devices ("SMART Capable" = Yes): the PCIe AHCI SSDs of Intel Macs up to
// about 2015, SATA SSDs and hard disks of iMacs and Mac minis. No root privileges needed.
//
// Read-only: only SMART RETURN STATUS, READ DATA and READ THRESHOLDS are issued. SMART is
// never enabled, disabled or self-tested from here.

#include "CMacSensors.h"
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>
#include <string.h>

kern_return_t FSATAReadSMART(io_service_t device, uint8_t *outData512, uint8_t *outThresholds512,
                             int *outExceeded) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(device, kIOATASMARTUserClientTypeID,
                                                         kIOCFPlugInInterfaceID, &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL) return kr != KERN_SUCCESS ? kr : kIOReturnError;

    IOATASMARTInterface **smart = NULL;
    HRESULT result = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart);
    if (result != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }

    ATASMARTData data;
    memset(&data, 0, sizeof(data));
    kr = (*smart)->SMARTReadData(smart, &data);
    if (kr == KERN_SUCCESS) {
        memcpy(outData512, &data, 512);
        ATASMARTDataThresholds thresholds;
        memset(&thresholds, 0, sizeof(thresholds));
        // Thresholds are optional (obsolete in newer ATA standards): zeros when unsupported.
        if ((*smart)->SMARTReadDataThresholds(smart, &thresholds) == KERN_SUCCESS) {
            memcpy(outThresholds512, &thresholds, 512);
        } else {
            memset(outThresholds512, 0, 512);
        }
        Boolean exceeded = false;
        *outExceeded = (*smart)->SMARTReturnStatus(smart, &exceeded) == KERN_SUCCESS ? (exceeded ? 1 : 0) : -1;
    }

    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return kr;
}
