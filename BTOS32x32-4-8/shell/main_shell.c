#include "hardware.h"

// Hàm vẽ một điểm ảnh (Pixel) trực tiếp lên màn hình
void btos_gui_draw_pixel(struct btos_hardware_profile *hw, uint32_t x, uint32_t y, uint32_t color) {
    if (x >= hw->screen_width || y >= hw->screen_height) return;
    
    // Tính toán tọa độ chính xác trong bộ nhớ RAM Đồ họa
    uint32_t pixel_offset = y * (hw->screen_pitch / 4) + x;
    hw->video_framebuffer[pixel_offset] = color; // Ghi màu ARGB (Ví dụ: 0xFFFF0000 là màu Đỏ)
}

// Hàm vẽ một khối hình chữ nhật (Ứng dụng cho việc vẽ Cửa sổ / Nền Desktop)
void btos_gui_draw_rect(struct btos_hardware_profile *hw, uint32_t start_x, uint32_t start_y, uint32_t width, uint32_t height, uint32_t color) {
    for (uint32_t y = start_y; y < start_y + height; y++) {
        for (uint32_t x = start_x; x < start_x + width; x++) {
            btos_gui_draw_pixel(hw, x, y, color);
        }
    }
}

// Khởi chạy giao diện Hệ điều hành Đồ họa BTOS GUI
void start_btos_shell(struct btos_hardware_profile *hw) {
    // Lấy thông tin màn hình do VBE cấp từ Bootloader (Thường map tại địa chỉ cứng sau khi quét)
    hw->video_framebuffer = (uint32_t*)0xFD000000; // Địa chỉ LFB mẫu (Sẽ được điền chính xác bởi asm_detect)
    hw->screen_width = 1024;
    hw->screen_height = 768;
    hw->screen_pitch = 1024 * 4;

    // 1. Vẽ hình nền Desktop (Màu xanh lam đậm thanh lịch)
    btos_gui_draw_rect(hw, 0, 0, hw->screen_width, hw->screen_height, 0xff1a4d80);

    // 2. Vẽ Thanh Taskbar ở dưới cùng màn hình (Màu xám đen)
    btos_gui_draw_rect(hw, 0, hw->screen_height - 40, hw->screen_width, 40, 0xff222222);

    // 3. Vẽ một Cửa sổ Ứng dụng mẫu ở giữa màn hình (Màu trắng, thanh tiêu đề màu xám)
    btos_gui_draw_rect(hw, 200, 150, 600, 400, 0xffffffff); // Thân cửa sổ
    btos_gui_draw_rect(hw, 200, 150, 600, 30, 0xff555555);  // Thanh tiêu đề (Title Bar)

    // 4. Vẽ nút "Start" giả lập trên Taskbar (Màu xanh lá)
    btos_gui_draw_rect(hw, 5, hw->screen_height - 35, 80, 30, 0xff2ecc71);

    // Vòng lặp GUI để liên tục cập nhật tọa độ chuột và các sự kiện ứng dụng
    while(1) {
        // Driver chuột sẽ đọc cổng PS/2 (0x60) và liên tục vẽ lại con trỏ chuột tại đây
    }
}
