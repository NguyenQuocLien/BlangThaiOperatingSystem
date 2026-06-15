[org 0x7c00]
BITS 16

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    ; === Bật A20 ===
    in al, 0x92
    or al, 2
    out 0x92, al

    ; === Khởi tạo VBE + Lưu Mode Info Block ===
    mov ax, 0x4F02
    mov bx, 0x4118
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; Lưu VBE Mode Info Block vào 0x7E00 (Chiếm vùng từ 0x7E00 -> 0x7F00)
    mov ax, 0x4F01
    mov cx, 0x4118
    mov di, 0x7E00
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; === Đọc E820 Memory Map ===
    ; Sắp xếp lại: Đưa số lượng entry và dữ liệu lên vùng 0x8000 để tránh xung đột
    mov di, 0x8004                ; Danh sách các entry bắt đầu lưu từ 0x8004
    xor ebx, ebx
    mov word [0x8000], 0          ; Địa chỉ 0x8000 sẽ lưu số lượng entry E820

e820_loop:
    mov eax, 0xE820
    mov edx, 0x534D4150           ; 'SMAP'
    mov ecx, 24
    int 0x15
    jc error_handler

    cmp eax, 0x534D4150           ; Kiểm tra chữ ký hợp lệ
    jne error_handler

    add di, 24
    inc word [0x8000]             ; Tăng số lượng entry lưu tại địa chỉ 0x8000
    test ebx, ebx
    jnz e820_loop

    ; === Nạp stage2/entry.bin (128 sectors) ===
    mov ax, 0x1000
    mov es, ax
    xor bx, bx                    ; ES:BX = 0x1000:0x0000 -> Địa chỉ vật lý 0x10000
    mov ah, 0x02
    mov al, 128
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, 0x80                  ; Đọc từ ổ đĩa cứng đầu tiên
    int 0x13
    jc error_handler

    ; === Chuyển sang Protected Mode ===
    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm

; =====================================================
; Xử lý lỗi tập trung
; =====================================================
error_handler:
    hlt
    jmp error_handler

; =====================================================
; PROTECTED MODE (32-bit)
; =====================================================
BITS 32
init_pm:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; Truyền boot drive sang Stage 2
    movzx eax, dl
    push eax

    ; Nhảy vào Stage 2 (Sửa lỗi ép kiểu dword cho con trỏ 32-bit nhảy xa)
    jmp CODE_SEG:dword 0x10000

; =====================================================
; GDT
; =====================================================
gdt_start:
    dd 0x0, 0x0
gdt_code:
    dw 0xffff, 0x0000
    db 0x00, 0x9a, 0xcf, 0x00
gdt_data:
    dw 0xffff, 0x0000
    db 0x00, 0x92, 0xcf, 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

times 510 - ($ - $$) db 0
dw 0xaa55
