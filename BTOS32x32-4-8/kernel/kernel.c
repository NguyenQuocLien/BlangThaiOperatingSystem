#include <stdint.h>
#include "include/hardware.h"
#include "include/usb.h"

// Khai báo hàm từ shell
extern void start_btos_shell(struct btos_hardware_profile *hw);

// Hàm khởi tạo kernel chính (điểm vào từ bootloader)
void kernel_main(void) {
    // Khởi tạo cấu trúc thông tin phần cứng
    struct btos_hardware_profile hw = {0};
    
    // Thiết lập thông tin màn hình (lấy từ VBE bootloader đã bật)
    hw.video_framebuffer = (uint32_t*)0xFD000000;   // Linear Framebuffer (có thể điều chỉnh sau)
    hw.screen_width      = 1024;
    hw.screen_height     = 768;
    hw.screen_pitch      = 1024 * 4;                // 4 bytes/pixel (32-bit ARGB)
    
    // Khởi tạo USB EHCI (địa chỉ MMIO mẫu, bạn có thể thay sau khi có PCI scan)
    btos_usb_init(0xFEB00000);
    
    // Chuyển sang Shell GUI (chuột + vẽ màn hình)
    start_btos_shell(&hw);
    
    // Vòng lặp an toàn nếu shell thoát
    while (1) {
        __asm__ __volatile__("hlt");
    }
}
