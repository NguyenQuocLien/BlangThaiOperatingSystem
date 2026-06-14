#ifndef USB_H
#define USB_H

#include <stdint.h>

// Định nghĩa cấu trúc thanh ghi của USB EHCI Controller (MMIO)
struct ehci_capability_regs {
    uint8_t  cap_length;       // Chiều dài của thanh ghi cấu hình
    uint8_t  reserved;
    uint16_t hci_version;      // Phiên bản EHCI (0x0200 cho USB 2.0)
    uint32_t hcs_params;       // Tham số cấu trúc hệ thống
    uint32_t hcc_params;       // Tham số đặc tính phần cứng
} __attribute__((packed));

struct ehci_operational_regs {
    uint32_t usb_cmd;          // Lệnh điều khiển USB (Run/Stop, Reset)
    uint32_t usb_sts;          // Trạng thái bộ điều khiển (Ngắt, Lỗi)
    uint32_t usb_intr;         // Kích hoạt ngắt USB
    uint32_t fr_index;         // Chỉ số khung hình thời gian thực
    uint32_t ctrl_ds_segment;  // Đoạn bộ nhớ 64-bit (nếu có)
    uint32_t periodic_list_base;// Địa chỉ danh sách truyền tải tuần tuần tự
    uint32_t async_list_base;   // Địa chỉ danh sách truyền tải bất đồng bộ (Chuột/Bàn phím)
    uint32_t config_flag;      // Cờ cấu hình định tuyến định tuyến cổng
} __attribute__((packed));

// Hàm khởi tạo hệ thống USB
void btos_usb_init(uint32_t pci_base_addr);
void btos_usb_poll_mouse(int *mouse_x, int *mouse_y, uint8_t *buttons);

#endif
