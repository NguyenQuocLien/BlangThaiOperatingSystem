[org 0x7c00]                ; BIOS luôn nạp Bootloader tại địa chỉ này trong RAM
BITS 16                     ; Khởi đầu ở chế độ 16-bit Real Mode mặc định

start:
    cli                     ; Tắt toàn bộ ngắt phần cứng để đảm bảo an toàn
    xor ax, ax              ; Xóa sạch các thanh ghi đoạn về 0
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00          ; Thiết lập đỉnh ngăn xếp (Stack) an toàn

    ; Kích hoạt đường A20 để CPU có thể truy cập trên 1MB RAM (Cứu 8GB RAM của bạn)
    in al, 0x92
    or al, 2
    out 0x92, al

    ; Nạp bảng GDT (Global Descriptor Table) để định nghĩa các đoạn bộ nhớ 32-bit
    lgdt [gdt_descriptor]

    ; Chuyển sang 32-bit Protected Mode bằng cách bật bit CR0
    mov eax, cr0
    or eax, 1
    mov cr0, eax

    ; Nhảy xa (Far Jump) để xóa sạch các lệnh 16-bit còn sót trong hàng đợi CPU
    jmp CODE_SEG:init_pm

BITS 32                     ; Từ đây CPU chạy chế độ 32-bit Protected Mode
init_pm:
    mov ax, DATA_SEG        ; Nạp các thanh ghi đoạn dữ liệu 32-bit
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov ebp, 0x90000        ; Thiết lập lại Stack mới cho chế độ 32-bit
    mov esp, ebp

    ; Gọi đoạn mã tiếp theo của phân vùng FAT32 để tìm và nạp Kernel tại địa chỉ 0x100000
    extern load_kernel_from_fat32
    call load_kernel_from_fat32

    jmp CODE_SEG:0x100000   ; NHẢY THẲNG VÀO KERNEL (Địa chỉ đã cấu hình trong linker.ld)
    hlt

; --- CẤU TRÚC GDT CƠ BẢN ĐỂ CHẠY CHẾ ĐỘ 32-BIT ---
gdt_start:
    dd 0x0, 0x0             ; Đoạn trống bắt buộc (Null Descriptor)
gdt_code:
    dw 0xffff, 0x0          ; Đoạn mã lệnh (Code Segment Descriptor)
    db 0x0, 0x9a, 0xcf, 0x0
gdt_data:
    dw 0xffff, 0x0          ; Đoạn dữ liệu (Data Segment Descriptor)
    db 0x0, 0x92, 0xcf, 0x0
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

times 510-($-$$) db 0       ; Điền các byte 0 cho đủ 510 byte
dw 0xaa55                   ; Ký tự chữ ký Bootloader bắt buộc của BIOS
