BITS 32
global load_kernel_from_fat32

load_kernel_from_fat32:
    push ebp
    mov ebp, esp

    ; Giả lập đọc ổ đĩa cứng cổng I/O ATA để nạp Kernel
    ; Trong thực tế, đoạn này sẽ gửi lệnh đến cổng 0x1F0 - 0x1F7 để đọc các Sector FAT32
    mov ebx, 0x100000       ; Địa chỉ đích nạp Kernel (1MB)
    mov ecx, 64             ; Giả định đọc 64 Sectors thô chứa file kernel.bin (32KB)
    mov edx, 0x1F0          ; Cổng dữ liệu ATA Data Port

.read_loop:
    ; (Đoạn mã gửi lệnh đọc sector và kiểm tra trạng thái ổ đĩa rảnh)
    ; Đọc dữ liệu từ cổng đĩa cứng vào bộ nhớ RAM tại địa chỉ ebx
    insw                    ; Đọc một từ (Word) từ cổng EDX vào ES:EDI/EBX
    add ebx, 2
    loop .read_loop

    mov esp, ebp
    pop ebp
    ret
