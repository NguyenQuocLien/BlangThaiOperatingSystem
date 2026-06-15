[org 0x7c00]
BITS 16

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    ; Lưu boot drive
    mov [boot_drive], dl

    ; === Bật A20 (an toàn) ===
    in al, 0x92
    test al, 2
    jnz a20_done
    or al, 2
    and al, 0xFE
    out 0x92, al
a20_done:

    ; === Đọc E820 Memory Map ===
    xor ax, ax
    mov es, ax
    mov di, 0x8500
    xor ebx, ebx
    mov word [0x7FF0], 0

e820_loop:
    mov eax, 0xE820
    mov edx, 0x534D4150
    mov ecx, 24
    int 0x15
    jc e820_done
    cmp eax, 0x534D4150
    jne error_handler
    add di, 24
    inc word [0x7FF0]
    test ebx, ebx
    jnz e820_loop

e820_done:
    ; === VBE: Lấy Mode Info Block ===
    xor ax, ax
    mov es, ax
    mov ax, 0x4F01
    mov cx, 0x4118
    mov di, 0x7E00
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; Set VBE mode (Linear Framebuffer)
    mov ax, 0x4F02
    mov bx, 0x4118 | 0x4000
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; === Reset disk controller ===
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    jc error_handler

    ; === Lần 1: Đọc 63 sectors đầu vào 0x10000 ===
    mov ax, 0x1000
    mov es, ax
    xor bx, bx
    mov ah, 0x02
    mov al, 63
    mov ch, 0
    mov cl, 2
    mov dh, 0
    mov dl, [boot_drive]
    int 0x13
    jc error_handler

    ; === Lần 2: Đọc 65 sectors còn lại vào 0x17E00 ===
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

    ; === Chuyển sang Protected Mode ===
    cli
    lgdt [gdt_descriptor]

    mov eax, cr0
    or eax, 1
    mov cr0, eax

    jmp CODE_SEG:init_pm

; =====================================================
; Xử lý lỗi (in 'E')
; =====================================================
error_handler:
    mov ah, 0x0E
    mov al, 'E'
    int 0x10
    cli
    hlt
    jmp error_handler

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

    ; Truyền boot drive sang Stage 2
    movzx eax, byte [0x7C00 + (boot_drive - $$)]
    push eax

    call 0x10000

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

boot_drive: db 0

times 510 - ($ - $$) db 0
dw 0xaa55
