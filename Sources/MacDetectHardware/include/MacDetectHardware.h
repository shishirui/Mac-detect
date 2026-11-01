#ifndef MAC_DETECT_HARDWARE_H
#define MAC_DETECT_HARDWARE_H
#include <stdint.h>
#include <stddef.h>

// Read-only hardware access. No SMC write selector or NVMe admin write operations.
uint32_t md_nvme_read_health(const char *whole_disk_bsd_name, uint8_t *data, size_t length);
uint32_t md_smc_open(uint32_t *connection);
void md_smc_close(uint32_t connection);
typedef struct {
    uint32_t data_type;
    uint32_t size;
    uint8_t bytes[32];
} MD_SMCValue;
uint32_t md_smc_read(uint32_t connection, uint32_t key, MD_SMCValue *value);
uint32_t md_smc_key_at_index(uint32_t connection, uint32_t index, uint32_t *key);
#endif
