#include "include/charset.h"
#include "include/hardware.h"

// Biến toàn cục
charset_t current_charset = CHARSET_ASCII;

// Thiết lập bảng mã
void set_charset(charset_t cs) {
    if (cs <= CHARSET_VISCII) {
        current_charset = cs;
    }
}

// Vẽ 1 ký tự (8x8 font đơn giản - bạn có thể thay font sau)
void draw_char(struct btos_hardware_profile *hw, uint32_t x, uint32_t y, 
               uint8_t ch, uint32_t fg_color, uint32_t bg_color) {
    // TODO: Thêm bitmap font 8x8 hỗ trợ VSCII + VISCII
    // Hiện tại chỉ vẽ ASCII cơ bản (sau sẽ mở rộng)
    // Ví dụ: nếu ch là ký tự có dấu VSCII/VISCII thì map sang glyph tương ứng
    
    // Tạm thời vẽ hình chữ nhật nhỏ thay cho ký tự (để test)
    for (uint32_t yy = 0; yy < 8; yy++) {
        for (uint32_t xx = 0; xx < 8; xx++) {
            uint32_t color = (xx == 0 || yy == 0 || xx == 7 || yy == 7) ? fg_color : bg_color;
            btos_gui_draw_pixel(hw, x + xx, y + yy, color);
        }
    }
}

// In chuỗi theo bảng mã hiện tại
void draw_string(struct btos_hardware_profile *hw, uint32_t x, uint32_t y, 
                 const char *str, uint32_t fg_color, uint32_t bg_color) {
    uint32_t cx = x;
    while (*str) {
        uint8_t ch = (uint8_t)*str;
        
        // Xử lý theo bảng mã (có thể mở rộng mapping sau)
        if (current_charset == CHARSET_VSCII || current_charset == CHARSET_VISCII) {
            // TODO: Mapping ký tự có dấu VSCII/VISCII sang glyph
            // Ví dụ: ch = 0xE0 (à trong VSCII) → vẽ glyph 'à'
        }
        
        draw_char(hw, cx, y, ch, fg_color, bg_color);
        cx += 8;           // khoảng cách giữa các ký tự
        str++;
    }
}
