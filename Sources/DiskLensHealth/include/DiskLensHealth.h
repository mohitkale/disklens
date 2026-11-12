#ifndef DISKLENS_HEALTH_H
#define DISKLENS_HEALTH_H
#include <stdint.h>

/// The NVMe health log of one internal SSD, read through Apple's IONVMeSMART interface (no admin rights needed).
typedef struct {
    int ok;                    // 1 if read
    uint8_t criticalWarning;   // bit flags; 0 means none
    uint8_t percentUsed;       // wear estimate; 100 = rated endurance reached (can go above)
    uint8_t availableSpare;    // % of spare blocks left
    uint8_t spareThreshold;    // below this the drive warns
    int temperatureC;
    uint64_t powerOnHours;
    uint64_t dataUnitsWritten; // in units of 512,000 bytes
    uint64_t dataUnitsRead;
    uint64_t unsafeShutdowns;
    uint64_t mediaErrors;
    uint64_t powerCycles;
} DLNVMeHealth;

/// Fills up to `max` entries (one per NVMe drive) and returns how many were read.
int dl_read_nvme_health(DLNVMeHealth *out, int max);

#endif
