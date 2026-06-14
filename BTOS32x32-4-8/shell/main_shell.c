#include "hardware.h"

extern void print_string_to_screen(const char *str); // Hàm xuất chữ ra màn hình VGA (0xB8000)

void start_btos_shell(struct btos_hardware_profile *hw) {
    print_string_to_screen("\n--- BTOS CLI SHELL (FAT32 partition) ---\n");
    print_string_to_screen("Welcome to BTOS Core. System status: SECURE\n");
    
    if (hw->process_nm == 32) {
        print_string_to_screen("Current File System for User Partition: BTFS32 (Mated with 32nm CPU)\n");
    }
    
    // Vòng lặp nhận lệnh (ls, cd, cat) từ bàn phím I/O port 0x60
    while(1) {
        // Chờ lệnh người dùng
    }
}
