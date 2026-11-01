#include "MacDetectHardware.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOBSD.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>

uint32_t md_nvme_read_health(const char *name, uint8_t *data, size_t length) {
    if (!name || !data || length != 512 || strncmp(name, "disk", 4) || !name[4]) return kIOReturnBadArgument;
    for (size_t i = 4; name[i]; i++) if (i > 16 || name[i] < '0' || name[i] > '9') return kIOReturnBadArgument;
    io_registry_entry_t entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, name));
    if (!entry) return kIOReturnNotFound;
    bool found = false;
    for (int depth = 0; depth < 24; depth++) {
        CFTypeRef capable = IORegistryEntryCreateCFProperty(entry, CFSTR(kIOPropertyNVMeSMARTCapableKey), kCFAllocatorDefault, 0);
        found = capable && CFGetTypeID(capable) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)capable);
        if (capable) CFRelease(capable);
        if (found) break;
        io_registry_entry_t parent = 0;
        IOReturn status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent);
        IOObjectRelease(entry); entry = parent;
        if (status != kIOReturnSuccess || !entry) break;
    }
    if (!found) { if (entry) IOObjectRelease(entry); return kIOReturnUnsupported; }
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn result = IOCreatePlugInInterfaceForService(entry, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(entry);
    if (result != kIOReturnSuccess || !plugin) return result ? result : kIOReturnUnsupported;
    IONVMeSMARTInterface **smart = NULL;
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (query != S_OK || !smart) { IODestroyPlugInInterface(plugin); return kIOReturnUnsupported; }
    NVMeSMARTData health;
    _Static_assert(sizeof(health) == 512, "NVMe SMART ABI must be 512 bytes");
    memset(&health, 0, sizeof(health));
    result = (*smart)->SMARTReadData(smart, &health);
    if (result == kIOReturnSuccess) memcpy(data, &health, sizeof(health));
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    return result;
}

// AppleSMC's 80-byte user-client ABI, documented by the MIT-licensed SMCKit.
// See THIRD_PARTY_NOTICES.md. Deliberately supports only read / enumeration operations.
typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, memory; } SMCPowerLimit;
typedef struct { uint32_t size, type; uint8_t attributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPowerLimit power_limit;
    SMCKeyInfo key_info;
    uint8_t result, status, command;
    uint32_t index;
    uint8_t bytes[32];
} SMCRequest;
_Static_assert(sizeof(SMCRequest) == 80, "AppleSMC user-client ABI must be 80 bytes");

static IOReturn smc_call(uint32_t connection, const SMCRequest *input, SMCRequest *output) {
    if (input->command != 5 && input->command != 8 && input->command != 9) return kIOReturnNotPermitted;
    size_t size = sizeof(*output);
    memset(output, 0, size);
    IOReturn result = IOConnectCallStructMethod(connection, 2, input, sizeof(*input), output, &size);
    if (result != kIOReturnSuccess) return result;
    if (size != sizeof(*output)) return kIOReturnBadArgument;
    if (output->result == 132) return kIOReturnNotFound;
    return output->result == 0 ? kIOReturnSuccess : kIOReturnError;
}
uint32_t md_smc_open(uint32_t *connection) {
    if (!connection) return kIOReturnBadArgument;
    *connection = 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    IOReturn result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}
void md_smc_close(uint32_t connection) { if (connection) IOServiceClose(connection); }
uint32_t md_smc_read(uint32_t connection, uint32_t key, MD_SMCValue *value) {
    if (!connection || !value) return kIOReturnBadArgument;
    memset(value, 0, sizeof(*value));
    SMCRequest input = {0}, output = {0};
    input.key = key; input.command = 9;
    IOReturn result = smc_call(connection, &input, &output);
    if (result != kIOReturnSuccess) return result;
    if (output.key_info.size < 1 || output.key_info.size > 32) return kIOReturnUnsupported;
    value->data_type = output.key_info.type; value->size = output.key_info.size;
    input.key_info = output.key_info; input.command = 5;
    result = smc_call(connection, &input, &output);
    if (result == kIOReturnSuccess) memcpy(value->bytes, output.bytes, value->size);
    return result;
}
uint32_t md_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key) {
    if (!connection || !key || index > 16383) return kIOReturnBadArgument;
    SMCRequest input = {0}, output = {0};
    input.command = 8; input.index = index;
    IOReturn result = smc_call(connection, &input, &output);
    if (result == kIOReturnSuccess) *key = output.key;
    return result;
}
