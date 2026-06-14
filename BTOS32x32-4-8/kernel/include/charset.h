#ifndef CHARSET_H
#define CHARSET_H

#include <stdint.h>

// 3 bảng mã hỗ trợ
typedef enum {
    CHARSET_ASCII = 0,
    CHARSET_VSCII = 1,
    CHARSET_VISCII = 2
} charset_t;

// Biến toàn cục lưu bảng mã hiện tại (mặc định ASCII)
extern charset_t current_charset;

// Hàm thiết lập bảng mã (gọi từ Boot Settings hoặc kernel init)
void set_charset(charset_t cs);

// Hàm in ký tự đơn (sẽ dùng sau khi có font)
void draw_char(struct btos_hardware_profile *hw, uint32_t x, uint32_t y, 
               uint8_t ch, uint32_t fg_color, uint32_t bg_color);

// Hàm in chuỗi theo bảng mã hiện tại
void draw_string(struct btos_hardware_profile *hw, uint32_t x, uint32_t y, 
                 const char *str, uint32_t fg_color, uint32_t bg_color);

#endif
