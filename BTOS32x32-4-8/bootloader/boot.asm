; =====================================================
; bootloader/boot.asm
; Stage 1 Bootloader — BTOS
; =====================================================
; MEMORY MAP sau khi chạy xong:
;   0x7C00        — Stage 1 (file này)
;   0x7E00        — VBE Mode Info Block
;   0x7FF0        — E820 entry count (word)
;   0x7FFC        — Boot state flag (byte):
;                     0 = NORMAL
;                     1 = INTERRUPTED (F1 bị ấn)
;   0x8500        — E820 Memory Map entries
;   0x10000       — Stage 2 (entry.asm, load tại đây)
;
; VẤN ĐỀ ĐÃ SỬA:
;   1. Label 'continue_to_stage2' không tồn tại -> đã định nghĩa
;   2. F1 kiểm tra trước E820/VBE -> đúng thứ tự
;   3. Thêm kiểm tra F1 lần 2 SAU khi load Stage 2 (trước jmp PM)
; =====================================================

[org 0x7c00]
BITS 16

; =====================================================
; Constants
; =====================================================
BOOT_STATE_ADDR     equ 0x7FFC
BOOT_STATE_NORMAL   equ 0x00
BOOT_STATE_INT      equ 0x01
F1_SCANCODE         equ 0x3B

; =====================================================
; Entry Point
; =====================================================
start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    ; Lưu boot drive (BIOS để sẵn trong DL)
    mov [boot_drive], dl

    ; Khởi tạo boot state = NORMAL
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_NORMAL

    ; === Bật A20 (an toàn, tránh bit 0 = reset) ===
    in al, 0x92
    test al, 2
    jnz a20_done
    or al, 2
    and al, 0xFE        ; Bit 0 = system reset, KHÔNG set
    out 0x92, al
a20_done:

    ; =====================================================
    ; CHECKPOINT F1 — #1: Ngay sau A20, trước mọi thứ
    ; Đây là điểm sớm nhất người dùng có thể ấn F1
    ; =====================================================
    mov ah, 0x01        ; INT 16h AH=01: peek keystroke (non-blocking)
    int 0x16
    jz .no_f1_early     ; ZF=1: buffer trống, không có phím
    mov ah, 0x00
    int 0x16            ; Đọc và xóa phím khỏi buffer
    cmp ah, F1_SCANCODE
    jne .no_f1_early
    ; F1 ấn -> đánh dấu state, nhảy thẳng vào PM (bỏ qua E820/VBE)
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INT
    jmp continue_to_stage2
.no_f1_early:

    ; === Đọc E820 Memory Map ===
    xor ax, ax
    mov es, ax
    mov di, 0x8500
    xor ebx, ebx
    mov word [0x7FF0], 0

e820_loop:
    mov eax, 0xE820
    mov edx, 0x534D4150     ; 'SMAP'
    mov ecx, 24
    int 0x15
    jc e820_done            ; CF=1 sau entry cuối = bình thường
    cmp eax, 0x534D4150
    jne error_handler
    add di, 24
    inc word [0x7FF0]
    test ebx, ebx
    jnz e820_loop
e820_done:

    ; === VBE: Lấy Mode Info Block vào 0x7E00 ===
    xor ax, ax
    mov es, ax
    mov ax, 0x4F01
    mov cx, 0x4118
    mov di, 0x7E00
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; Set VBE mode với Linear Framebuffer (bit 14)
    mov ax, 0x4F02
    mov bx, 0x4118 | 0x4000
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; === Reset disk controller trước khi đọc ===
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    jc error_handler

    ; === Lần 1: Đọc 63 sectors đầu vào linear 0x10000 ===
    ;   ES:BX = 0x1000:0x0000 = 0x10000
    mov ax, 0x1000
    mov es, ax
    xor bx, bx
    mov ah, 0x02
    mov al, 63
    mov ch, 0           ; Cylinder 0
    mov cl, 2           ; Sector bắt đầu từ sector 2 (1=MBR)
    mov dh, 0           ; Head 0
    mov dl, [boot_drive]
    int 0x13
    jc error_handler

    ; === Lần 2: Đọc 65 sectors tiếp vào linear 0x17E00 ===
    ;   63 sectors * 512 bytes = 0x7E00
    ;   ES mới = 0x1000 + 0x7E00/0x10 = 0x17E0
    ;   Sector bắt đầu: sector 65 (CHS: cl=65)
    mov ax, 0x17E0
    mov es, ax
    xor bx, bx
    mov ah, 0x02
    mov al, 65
    mov ch, 0
    mov cl, 65
    mov dh, 0
    mov dl, [boot_drive]
    int 0x13
    jc error_handler

    ; =====================================================
    ; CHECKPOINT F1 — #2: Sau khi load Stage 2, trước PM
    ; Stage 2 đã nằm trong RAM tại 0x10000
    ; Đây là điểm cuối cùng trong Real Mode
    ; =====================================================
    mov ah, 0x01
    int 0x16
    jz continue_to_stage2   ; Không có phím -> boot bình thường
    mov ah, 0x00
    int 0x16
    cmp ah, F1_SCANCODE
    jne continue_to_stage2
    ; F1 -> set state INTERRUPTED
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INT

    ; =====================================================
    ; continue_to_stage2
    ; Chuyển sang Protected Mode và nhảy vào Stage 2
    ; Được gọi trong CẢ HAI trường hợp: boot bình thường
    ; và boot bị ngắt (F1). Stage 2 tự đọc BOOT_STATE_ADDR
    ; để biết phải làm gì.
    ; =====================================================
continue_to_stage2:
    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp CODE_SEG:init_pm

; =====================================================
; error_handler
; In 'E' ra màn hình rồi halt
; =====================================================
error_handler:
    mov ah, 0x0E
    mov al, 'E'
    int 0x10
    cli
    hlt
    jmp error_handler

; =====================================================
; PROTECTED MODE entry
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

    ; Truyền boot drive cho Stage 2 qua stack
    ; (Stage 2 đọc tại [esp+4] sau call)
    movzx eax, byte [0x7C00 + (boot_drive - $$)]
    push eax

    call 0x10000        ; Gọi stage2_entry

    ; Không bao giờ đến đây — Stage 2 tự quản lý
    cli
    hlt
    jmp $

; =====================================================
; GDT — Global Descriptor Table
; =====================================================
gdt_start:
    ; Null descriptor (bắt buộc)
    dd 0x00000000
    dd 0x00000000

gdt_code:
    ; Code segment: base=0, limit=4GB, 32-bit, ring 0, execute/read
    dw 0xFFFF           ; Limit [15:0]
    dw 0x0000           ; Base  [15:0]
    db 0x00             ; Base  [23:16]
    db 0x9A             ; Access: Present, Ring0, Code, Execute/Read
    db 0xCF             ; Flags: 4KB granularity, 32-bit + Limit [19:16]=0xF
    db 0x00             ; Base  [31:24]

gdt_data:
    ; Data segment: base=0, limit=4GB, 32-bit, ring 0, read/write
    dw 0xFFFF
    dw 0x0000
    db 0x00
    db 0x92             ; Access: Present, Ring0, Data, Read/Write
    db 0xCF
    db 0x00

gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1     ; GDT size - 1
    dd gdt_start                    ; GDT linear address

CODE_SEG    equ gdt_code - gdt_start   ; = 0x08
DATA_SEG    equ gdt_data - gdt_start   ; = 0x10

; =====================================================
; Data
; =====================================================
boot_drive: db 0

; Padding + Boot signature
times 510 - ($ - $$) db 0
dw 0xAA55
