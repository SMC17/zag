#ifndef CBASE_CRC32_H
#define CBASE_CRC32_H
#include <stddef.h>
#include <stdint.h>
/* CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320). Start with crc = 0. */
uint32_t crc32_update(uint32_t crc, const unsigned char *data, size_t n);
#endif
