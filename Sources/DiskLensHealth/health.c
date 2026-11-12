#include "DiskLensHealth.h"
#include <TargetConditionals.h>
#if TARGET_OS_OSX
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <string.h>

// Apple's NVMe SMART user client (IONVMeFamily). The same interface disk utilities use; read-only.
#define kIONVMeSMARTUserClientTypeID CFUUIDGetConstantUUIDWithBytes(NULL, 0xAA,0x0F,0xA6,0xF9,0xC2,0xD6,0x45,0x7F,0xB1,0x0B,0x59,0xA1,0x32,0x53,0x29,0x2F)
#define kIONVMeSMARTInterfaceID CFUUIDGetConstantUUIDWithBytes(NULL, 0xCC,0xD1,0xDB,0x19,0xFD,0x9A,0x4D,0xAF,0xBF,0x95,0x12,0x45,0x4B,0x23,0x0A,0xB6)

// NVMe SMART / Health Information log page (512 bytes).
struct nvme_smart_log {
    uint8_t critical_warning, temperature[2], avail_spare, spare_thresh, percent_used, rsvd6[26];
    uint8_t data_units_read[16], data_units_written[16], host_reads[16], host_writes[16], ctrl_busy_time[16],
        power_cycles[16], power_on_hours[16], unsafe_shutdowns[16], media_errors[16], num_err_log_entries[16];
    uint32_t warning_temp_time, critical_comp_time;
    uint16_t temp_sensor[8];
    uint8_t rsvd216[296];
};

typedef struct {
    IUNKNOWN_C_GUTS;
    UInt16 version, revision;
    IOReturn (*SMARTReadData)(void *self, struct nvme_smart_log *data);
} IONVMeSMARTInterface;

static uint64_t le64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = v << 8 | p[i];
    return v;
}

int dl_read_nvme_health(DLNVMeHealth *out, int max) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &it) != KERN_SUCCESS) return 0;
    int n = 0;
    io_object_t service;
    while (n < max && (service = IOIteratorNext(it))) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score = 0;
        if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS && plugin) {
            IONVMeSMARTInterface **smart = NULL;
            (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
            if (smart) {
                struct nvme_smart_log log;
                memset(&log, 0, sizeof log);
                if ((*smart)->SMARTReadData(smart, &log) == kIOReturnSuccess) {
                    DLNVMeHealth h;
                    memset(&h, 0, sizeof h);
                    h.ok = 1;
                    h.criticalWarning = log.critical_warning;
                    h.percentUsed = log.percent_used;
                    h.availableSpare = log.avail_spare;
                    h.spareThreshold = log.spare_thresh;
                    h.temperatureC = (int)(log.temperature[0] | log.temperature[1] << 8) - 273;
                    h.powerOnHours = le64(log.power_on_hours);
                    h.dataUnitsWritten = le64(log.data_units_written);
                    h.dataUnitsRead = le64(log.data_units_read);
                    h.unsafeShutdowns = le64(log.unsafe_shutdowns);
                    h.mediaErrors = le64(log.media_errors);
                    h.powerCycles = le64(log.power_cycles);
                    out[n++] = h;
                }
                (*smart)->Release(smart);
            }
            IODestroyPlugInInterface(plugin);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(it);
    return n;
}
#else
int dl_read_nvme_health(DLNVMeHealth *out, int max) { (void)out; (void)max; return 0; }
#endif
