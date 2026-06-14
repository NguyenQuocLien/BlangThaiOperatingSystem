; =============================================
; BTOS Bootloader - Phiên bản cải tiến
; =============================================
[org 0x7c00]
BITS 16

start:
    ; Thiết lập segment an toàn
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    ; In thông báo khởi động
    mov si, msg_booting
    call print_string

    ; Kích hoạt A20
    in al, 0x92
    or al, 2
    out 0x92, al

    ; --- BẬT VESA VBE ---
    mov ax, 0x4F02
    mov bx, 0x4118          ; 1024x768, 32-bit, Linear FB
    int 0x10
    cmp ax, 0x004F
    jne error_vbe

    ; Lưu thông tin Mode Info Block vào 0x7E00 (để kernel dùng sau)
    mov ax, 0x4F01
    mov cx, 0x118
    mov di, 0x7E00
    int 0x10
    cmp ax, 0x004F
    jne error_vbe

    mov si, msg_vbe_ok
    call print_string

    ; ==================== PHÁT HIỆN BỘ NHỚ E820 ====================
    mov si, msg_mem_detect
    call print_string

    mov di, 0x8000          ; Vùng lưu Memory Map
    xor ebx, ebx
    mov word [0x7FF0], 0    ; Số entry = 0

.mem_loop:
    mov eax, 0xE820
    mov edx, 0x534D4150     ; 'SMAP'
    mov ecx, 24
    int 0x15
    jc .mem_error

    ; Kiểm tra chữ ký SMAP
    cmp eax, 0x534D4150
    jne .mem_error

    inc word [0x7FF0]       ; Tăng số entry
    add di, 24              ; Chuẩn bị entry tiếp theo

    test ebx, ebx
    jnz .mem_loop           ; Còn entry thì tiếp tục

    mov si, msg_mem_ok
    call print_string
    jmp .continue_pm

.mem_error:
    mov si, msg_mem_fail
    call print_string
    ; Tiếp tục với giá trị mặc định

.continue_pm:

    ; --- CHUYỂN SANG PROTECTED MODE ---
    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm

; ==================== HÀM IN CHUỖI (Real Mode) ====================
print_string:
    pusha
    mov ah, 0x0E            ; BIOS teletype
.loop:
    lodsb
    cmp al, 0
    je .done
    int 0x10
    jmp .loop
.done:
    popa
    ret

; ==================== XỬ LÝ LỖI ====================
error_vbe:
    mov si, msg_vbe_fail
    call print_string
    cli
    hlt

; ==================== PROTECTED MODE ====================
BITS 32
init_pm:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov ebp, 0x90000
    mov esp, ebp

    mov si, msg_pm_ok       ; (sẽ in sau khi có hàm in 32-bit)
    ; Gọi stage2 để nạp kernel
    extern load_kernel_from_fat32
    call load_kernel_from_fat32

    ; Nhảy vào kernel
    jmp CODE_SEG:0x100000

; ==================== GDT ====================
gdt_start:
    dd 0x0, 0x0
gdt_code:
    dw 0xffff, 0x0
    db 0x0, 0x9a, 0xcf, 0x0
gdt_data:
    dw 0xffff, 0x0
    db 0x0, 0x92, 0xcf, 0x0
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

; ==================== THÔNG BÁO ====================
msg_booting    db "BTOS Booting...", 0x0D, 0x0A, 0
msg_vbe_ok     db "VBE Mode OK (1024x768x32)", 0x0D, 0x0A, 0
msg_vbe_fail   db "ERROR: VBE not supported!", 0x0D, 0x0A, 0
msg_pm_ok      db "Protected Mode OK", 0

msg_mem_detect db "Detecting Memory (E820)...", 0x0D, 0x0A, 0
msg_mem_ok     db "Memory Map OK", 0x0D, 0x0A, 0
msg_mem_fail   db "Memory detection failed (using default)", 0x0D, 0x0A, 0

times 510-($-$$) db 0
dw 0xaa55
