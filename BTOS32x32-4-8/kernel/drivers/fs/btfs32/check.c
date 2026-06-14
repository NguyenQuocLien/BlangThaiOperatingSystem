#include <stdint.h>

// Hàm tính mã băm CRC32/XXH64 để kiểm tra tính toàn vẹn dữ liệu
// Vì RAM DDR4 8GB của máy mục tiêu là Non-ECC, hàm này bắt buộc phải chạy
uint32_t btfs32_calculate_checksum(const uint8_t *data, uint32_t length) {
    uint32_t crc = 0xFFFFFFFF;
    for (uint32_t i = 0; i < length; i++) {
        crc ^= data[i];
        for (int j = 0; j < 8; j++) {
            if (crc & 1) crc = (crc >> 1) ^ 0xEDB88320;
            else crc >>= 1;
        }
    }
    return ~crc;
}
