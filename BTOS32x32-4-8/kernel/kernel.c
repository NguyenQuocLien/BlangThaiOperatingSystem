#include <stdint.h>
#include "include/hardware.h"
#include "include/usb.h"

// Khai báo từ linker.ld (sẽ thêm symbol ở bước sau)
extern uint32_t _bss_start;
extern uint32_t _bss_end;

// Khai báo hàm từ shell
extern void start_btos_shell(struct btos_hardware_profile *hw);

// Hàm xóa vùng BSS
static void clear_bss(void) {
    uint8_t *bss = (uint8_t *)&_bss_start;
    uint8_t *bss_end = (uint8_t *)&_bss_end;
    
    while (bss < bss_end) {
        *bss++ = 0;
    }
}

// Điểm vào chính của Kernel (bootloader nhảy vào đây)
void kernel_main(void) {
    // 1. Xóa vùng BSS trước khi dùng biến toàn cục
    clear_bss();
    
    // 2. Khởi tạo cấu trúc thông tin phần cứng
    struct btos_hardware_profile hw = {0};
    
    // Thông tin màn hình từ VBE (bootloader đã bật 1024x768x32)
    hw.video_framebuffer = (uint32_t*)0xFD000000;
    hw.screen_width      = 1024;
    hw.screen_height     = 768;
    hw.screen_pitch      = 1024 * 4;
    
    // 3. Khởi tạo USB EHCI (địa chỉ mẫu)
    btos_usb_init(0xFEB00000);
    
    // 4. Chuyển quyền điều khiển sang Shell GUI
    start_btos_shell(&hw);
    
    // 5. Vòng lặp an toàn
    while (1) {
        __asm__ __volatile__("hlt");
    }
}
