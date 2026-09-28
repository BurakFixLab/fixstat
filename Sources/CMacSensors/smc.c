// Read-only access to the AppleSMC user client.
//
// The parameter struct layout and command numbers follow the long-standing
// public reverse engineering of the SMC interface (Apple's historical smc.c,
// smcFanControl) as also used by exelban/stats (MIT License,
// https://github.com/exelban/stats, Modules/Sensors/... and SMC/smc.swift).
// This file is an independent C implementation; no write command is defined.

#include "CMacSensors.h"
#include <string.h>

typedef struct {
    char major;
    char minor;
    char build;
    char reserved;
    UInt16 release;
} FSSMCVersion;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} FSSMCPLimitData;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    UInt8 dataAttributes;
} FSSMCKeyInfo;

typedef struct {
    UInt32 key;
    FSSMCVersion vers;
    FSSMCPLimitData pLimitData;
    FSSMCKeyInfo keyInfo;
    UInt8 result;
    UInt8 status;
    UInt8 data8;
    UInt32 data32;
    UInt8 bytes[32];
} FSSMCParam;

_Static_assert(sizeof(FSSMCParam) == 80, "SMC parameter struct must be 80 bytes");

// IOConnectCallStructMethod selector of the SMC user client.
static const uint32_t kFSSMCUserClientSelector = 2;

// Read-only commands (data8). The write command is intentionally not listed.
enum {
    kFSSMCCmdReadBytes = 5,
    kFSSMCCmdReadIndex = 8,
    kFSSMCCmdReadKeyInfo = 9,
};

static kern_return_t FSSMCCall(io_connect_t connection, FSSMCParam *input, FSSMCParam *output) {
    // Defensive guard: only read commands may ever reach the kernel.
    if (input->data8 != kFSSMCCmdReadBytes &&
        input->data8 != kFSSMCCmdReadIndex &&
        input->data8 != kFSSMCCmdReadKeyInfo) {
        return kIOReturnNotPermitted;
    }
    size_t outputSize = sizeof(FSSMCParam);
    kern_return_t kr = IOConnectCallStructMethod(connection, kFSSMCUserClientSelector,
                                                 input, sizeof(FSSMCParam),
                                                 output, &outputSize);
    if (kr != KERN_SUCCESS) return kr;
    if (output->result != 0) return kIOReturnError;
    return KERN_SUCCESS;
}

kern_return_t FSSMCOpen(io_connect_t *outConnection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == IO_OBJECT_NULL) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, outConnection);
    IOObjectRelease(service);
    return kr;
}

void FSSMCClose(io_connect_t connection) {
    IOServiceClose(connection);
}

kern_return_t FSSMCGetKeyInfo(io_connect_t connection, uint32_t key,
                              uint32_t *outSize, uint32_t *outType, uint8_t *outAttributes) {
    FSSMCParam input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.data8 = kFSSMCCmdReadKeyInfo;
    kern_return_t kr = FSSMCCall(connection, &input, &output);
    if (kr != KERN_SUCCESS) return kr;
    if (outSize) *outSize = output.keyInfo.dataSize;
    if (outType) *outType = output.keyInfo.dataType;
    if (outAttributes) *outAttributes = output.keyInfo.dataAttributes;
    return KERN_SUCCESS;
}

kern_return_t FSSMCReadKey(io_connect_t connection, uint32_t key,
                           uint8_t *outBytes, uint32_t *outSize, uint32_t *outType) {
    uint32_t size = 0, type = 0;
    kern_return_t kr = FSSMCGetKeyInfo(connection, key, &size, &type, NULL);
    if (kr != KERN_SUCCESS) return kr;
    if (size > 32) size = 32;

    FSSMCParam input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key;
    input.keyInfo.dataSize = size;
    input.data8 = kFSSMCCmdReadBytes;
    kr = FSSMCCall(connection, &input, &output);
    if (kr != KERN_SUCCESS) return kr;

    memcpy(outBytes, output.bytes, 32);
    if (outSize) *outSize = size;
    if (outType) *outType = type;
    return KERN_SUCCESS;
}

kern_return_t FSSMCKeyAtIndex(io_connect_t connection, uint32_t index, uint32_t *outKey) {
    FSSMCParam input, output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.data8 = kFSSMCCmdReadIndex;
    input.data32 = index;
    kern_return_t kr = FSSMCCall(connection, &input, &output);
    if (kr != KERN_SUCCESS) return kr;
    *outKey = output.key;
    return KERN_SUCCESS;
}
