#include "usb.h"
#include "hardware.h"

volatile struct ehci_capability_regs*  ehci_cap;
volatile struct ehci_operational_regs* ehci_op;

// Hàm khởi tạo bộ điều khiển USB EHCI
void btos_usb_init(uint32_t pci_mmio_base) {
    // 1. Ánh xạ địa chỉ phần cứng của USB Controller vào bộ nhớ RAM
    ehci_cap = (struct ehci_capability_regs*)pci_mmio_base;
    
    // Thanh ghi vận hành nằm ngay sau thanh ghi cấu hình
    uint32_t op_base = pci_mmio_base + ehci_cap->cap_length;
    ehci_op = (struct ehci_operational_regs*)op_base;

    // 2. Tiến hành Reset bộ điều khiển USB để đưa về trạng thái sạch
    ehci_op->usb_cmd |= (1 << 1); // Bật bit HCRESET (Host Controller Reset)
    while (ehci_op->usb_cmd & (1 << 1)) {
        // Chờ chip phần cứng phản hồi xóa bit sau khi reset xong
    }

    // 3. Định tuyến toàn bộ các cổng vật lý về bộ điều khiển EHCI
    ehci_op->config_flag = 1;

    // 4. Kích hoạt bộ điều khiển chạy (Run)
    ehci_op->usb_cmd |= (1 << 0); // Bật bit RS (Run/Stop)
}

// Hàm đọc dữ liệu tọa độ từ chuột USB (USB HID Mouse Mouse Protocol)
void btos_usb_poll_mouse(int *mouse_x, int *mouse_y, uint8_t *buttons) {
    // Trong thực tế, chuột USB gửi dữ liệu qua một cấu trúc gọi là Queue Head (QH) 
    // và Transfer Descriptor (TD) nằm trong bộ nhớ async_list_base.
    // Để giữ chip 32nm luôn mát, driver đọc tuần tự trạng thái gói tin thay vì dùng vòng lặp vô hạn ngốn điện.

    uint8_t *hid_report = (uint8_t*)(ehci_op->async_list_base); // Giả định vị trí đệm dữ liệu chuột
    
    if (hid_report != 0) {
        *buttons = hid_report[0]; // Trạng thái click chuột trái/phải/giữa
        *mouse_x = (int8_t)hid_report[1]; // Độ dịch chuyển trục X (Số nguyên có dấu)
        *mouse_y = (int8_t)hid_report[2]; // Độ dịch chuyển trục Y (Số nguyên có dấu)
    }
}
