#include "hardware.h"
#include "usb.h"

// 1. KHAI BÁO BIẾN TOÀN CỤC (Nằm ngoài cùng, trên đầu file)
int current_mouse_x = 512;
int current_mouse_y = 384;

// 2. CÁC HÀM VẼ ĐỒ HỌA NỀN TẢNG
void btos_gui_draw_pixel(struct btos_hardware_profile *hw, uint32_t x, uint32_t y, uint32_t color) {
    if (x >= hw->screen_width || y >= hw->screen_height) return;
    
    // Tính toán tọa độ chính xác trong bộ nhớ RAM Đồ họa
    uint32_t pixel_offset = y * (hw->screen_pitch / 4) + x;
    hw->video_framebuffer[pixel_offset] = color; // Ghi màu ARGB
}

void btos_gui_draw_rect(struct btos_hardware_profile *hw, uint32_t start_x, uint32_t start_y, uint32_t width, uint32_t height, uint32_t color) {
    for (uint32_t y = start_y; y < start_y + height; y++) {
        for (uint32_t x = start_x; x < start_x + width; x++) {
            btos_gui_draw_pixel(hw, x, y, color);
        }
    }
}

// 3. HÀM THỰC THI CHÍNH CỦA SHELL GUI
void start_btos_shell(struct btos_hardware_profile *hw) {
    #include "include/charset.h"

// ... code cũ ...

void start_btos_shell(struct btos_hardware_profile *hw) {
    // ... code cũ của bạn ...

    // === THIẾT LẬP BẢNG MÃ MẶC ĐỊNH ===
   
    hw->video_framebuffer = (uint32_t*)0xFD000000; // Địa chỉ LFB mẫu
    hw->screen_width = 1024;
    hw->screen_height = 768;
    hw->screen_pitch = 1024 * 4;

    set_charset(CHARSET_VSCII); 
    // KHU VỰC GIAO DIỆN DESKTOP (ĐANG NGHIÊN CỨU)

    // Khởi tạo hệ thống USB (Địa chỉ MMIO mẫu)
    btos_usb_init(0xFEB00000);

    // VÒNG LẶP VÔ HẠN QUÉT TÍN HIỆU PHẦN CỨNG LIÊN TỤC
    while(1) {
        int delta_x = 0;
        int delta_y = 0;
        uint8_t mouse_buttons = 0;

        // Đọc dữ liệu dịch chuyển từ chuột USB thông qua bộ điều khiển EHCI
        btos_usb_poll_mouse(&delta_x, &delta_y, &mouse_buttons);

        if (delta_x != 0 || delta_y != 0) {
            // Xóa vết con trỏ chuột cũ (Vẽ đè màu nền Desktop lên vị trí cũ để xóa vết)
            btos_gui_draw_rect(hw, current_mouse_x, current_mouse_y, 8, 8, 0xff1a4d80);

            // Cập nhật tọa độ chuột mới theo tín hiệu phần cứng
            current_mouse_x += delta_x;
            current_mouse_y += delta_y;

            // Giới hạn biên màn hình 1024x768 không cho chuột chạy ra ngoài
            if (current_mouse_x < 0) current_mouse_x = 0;
            if (current_mouse_x > 1016) current_mouse_x = 1016;
            if (current_mouse_y < 0) current_mouse_y = 0;
            if (current_mouse_y > 760) current_mouse_y = 760;

            // Vẽ con trỏ chuột mới (Khối vuông màu Đỏ 8x8 pixel)
            btos_gui_draw_rect(hw, current_mouse_x, current_mouse_y, 8, 8, 0xffff0000);
        }

        // Ép CPU thực hiện lệnh hlt để tản nhiệt, bảo vệ chip 32nm phẳng
        __asm__ __volatile__("hlt");
    }
}
