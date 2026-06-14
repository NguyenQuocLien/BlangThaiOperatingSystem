#ifndef CHARSET_H
#define CHARSET_H

#include <stdint.h>

// 3 bảng mã hỗ trợ
typedef enum {
    CHARSET_ASCII       = 0,
    CHARSET_VSCII_VN1   = 1,   // VSCII VN1 (có chồng lấn C0/C1)
    CHARSET_VSCII_VN2   = 2,   // VSCII VN2 (khuyến nghị - sạch)
    CHARSET_VSCII_VN3   = 3,   // VSCII VN3 (tối giản)
    CHARSET_VISCII      = 4    // VISCII (rất phổ biến)
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
                 const char *str, uint32_t fg_color, uint32_t bg_color) {
    uint32_t cx = x;

    while (*str) {
        uint8_t ch = (uint8_t)*str++;

        if (ch == 0x7F || ch == 0x08) {
            if (cx >= 8) {
                cx -= 8;
                // Xóa vùng 8x16
                for (uint32_t row = 0; row < 16; row++) {
                    for (uint32_t col = 0; col < 8; col++) {
                        btos_gui_draw_pixel(hw, cx + col, y + row, bg_color);
                    }
                }
            }
            continue;
        }

        draw_glyph(hw, cx, y, ch, fg_color, bg_color);
        cx += 8;           // ngang
        // Không tăng y ở đây (chỉ tăng khi xuống dòng)
    }
}

#endif
