; =====================================================
; BTOS Bootloader Core
; boot.asm - Core (512 bytes max)
; Chỉ khởi động phần cứng + Nạp Stage 2
; Không in text, không có FAT32 reader phức tạp
; =====================================================

[org 0x7c00]
BITS 16

start:
    ; Khởi tạo segment
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    ; Bật A20
    in al, 0x92
    or al, 2
    out 0x92, al

    ; =====================================================
    ; NẠP STAGE 2 (Đọc sector 1 trở đi)
    ; Giả định stage2.bin nằm ngay sau sector 0
    ; =====================================================
    mov bx, 0x1000          ; Địa chỉ nạp Stage 2
    mov ah, 0x02            ; Đọc sector
    mov al, 32              ; Đọc 32 sector (16KB) - điều chỉnh sau
    mov ch, 0
    mov cl, 2               ; Bắt đầu từ sector 2
    mov dh, 0
    mov dl, 0x80            ; Ổ cứng
    int 0x13

    ; =====================================================
    ; CHUYỂN SANG PROTECTED MODE
    ; =====================================================
    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm

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
    jmp 0x1000

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

; =====================================================
; Boot Signature
; =====================================================
times 510 - ($ - $$) db 0
dw 0xaa55
