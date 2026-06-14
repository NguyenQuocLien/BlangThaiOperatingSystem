#ifndef HARDWARE_H
#define HARDWARE_H

#include <stdint.h>

typedef enum { ARCH_X86_32 } cpu_arch_t;
typedef enum { RAM_NON_ECC = 0 } ram_ecc_t;

struct btos_hardware_profile {
    cpu_arch_t architecture;
    uint32_t   process_nm;
    uint32_t   layers;
    uint32_t   ram_generation;
    ram_ecc_t  ram_ecc;
    uint32_t   total_ram_gb;
    
    // THAM SỐ ĐỒ HỌA MỚI CHO GUI
    uint32_t*  video_framebuffer; // Địa chỉ RAM vật lý của màn hình
    uint32_t   screen_width;      // Chiều rộng (Pixel)
    uint32_t   screen_height;     // Chiều cao (Pixel)
    uint32_t   screen_pitch;      // Số byte trên một hàng màn hình
};

#endif
