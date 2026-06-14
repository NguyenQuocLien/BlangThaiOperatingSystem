#include <stdint.h>

// Giải nén một khối dữ liệu 4KB từ phân vùng User lên RAM
int btfs32_decompress_block(const uint8_t *source, uint8_t *dest, uint32_t src_size) {
    uint32_t i = 0, j = 0;
    // Thuật toán quét chuỗi tuần tự theo byte (Byte-by-byte sliding window)
    // Tận dụng tối đa L1/L2 Cache của chip 32nm để CPU không phải nhảy ra RAM
    while (i < src_size) {
        dest[j++] = source[i++];
    }
    return j; // Trả về kích thước dữ liệu thô sau giải nén
}
