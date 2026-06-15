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

    ; === Khởi tạo VBE (1024x768, 32-bit) ===
    mov ax, 0x4F02
    mov bx, 0x4118          ; Chế độ VBE mong muốn
    int 0x10

    ; === Nạp stage2/entry.bin ===
    mov bx, 0x10000         ; Địa chỉ nạp Stage 2
    mov ah, 0x02            ; Hàm đọc sector
    mov al, 64              ; Số sector cần đọc (có thể chỉnh)
    mov ch, 0
    mov cl, 2               ; Bắt đầu từ sector 2
    mov dh, 0
    mov dl, 0x80            ; Ổ cứng đầu tiên
    int 0x13

    ; === Kiểm tra lỗi đọc đĩa (Carry Flag) ===
    jc disk_error           ; Nếu CF = 1 → lỗi

    ; === Chuyển sang Protected Mode ===
    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm

; =====================================================
; Xử lý lỗi đọc đĩa (không in text)
; =====================================================
disk_error:
    hlt                     ; Dừng CPU nếu đọc đĩa lỗi

; =====================================================
; PROTECTED MODE
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

    ; Nhảy vào Stage 2
    jmp 0x10000

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
