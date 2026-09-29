#ifndef CMACSENSORS_H
#define CMACSENSORS_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>

CF_ASSUME_NONNULL_BEGIN

// MARK: - AppleSMC (read-only)
//
// Only the read commands of the SMC user client are implemented. There is
// deliberately no function that can write a key.

/// Opens a connection to the AppleSMC user client.
kern_return_t FSSMCOpen(io_connect_t *outConnection);

/// Closes a connection returned by FSSMCOpen.
void FSSMCClose(io_connect_t connection);

/// Reads size, type (FourCC) and attribute byte of a key.
kern_return_t FSSMCGetKeyInfo(io_connect_t connection, uint32_t key,
                              uint32_t * _Nullable outSize, uint32_t * _Nullable outType,
                              uint8_t * _Nullable outAttributes);

/// Reads the raw value of a key. `outBytes` must hold 32 bytes.
kern_return_t FSSMCReadKey(io_connect_t connection, uint32_t key,
                           uint8_t *outBytes, uint32_t * _Nullable outSize, uint32_t * _Nullable outType);

/// Returns the key at the given index (0 ..< #KEY).
kern_return_t FSSMCKeyAtIndex(io_connect_t connection, uint32_t index, uint32_t *outKey);

// MARK: - IOHIDEventSystemClient (private API)

/// HID event types used with FSHIDClientCopyReadings.
enum {
    FSHIDEventTypeTemperature = 15,
    FSHIDEventTypePower = 25,
};

/// Creates an event system client matching services with the given primary
/// usage page / usage. Returns NULL on failure.
CFTypeRef _Nullable FSHIDClientCreate(int32_t usagePage, int32_t usage) CF_RETURNS_RETAINED;

/// Reads every matching service. Returns an array of dictionaries with the keys
/// "name" (CFString, the service's Product), "value" (CFNumber, double) and,
/// when present, "locationID" (CFNumber). Services that do not deliver an
/// event are skipped.
CFArrayRef _Nullable FSHIDClientCopyReadings(CFTypeRef client, int64_t eventType) CF_RETURNS_RETAINED;

// MARK: - NVMe SMART (read-only)

/// Reads the 512-byte NVMe SMART / Health Information log of the first NVMe
/// device that supports it. `outLog512` must hold 512 bytes.
kern_return_t FSNVMeReadSMARTLog(uint8_t *outLog512);

CF_ASSUME_NONNULL_END

#endif
