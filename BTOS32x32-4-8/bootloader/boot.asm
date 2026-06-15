[org 0x7c00]
BITS 16

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00

    ; Lưu boot drive (BIOS để trong DL)
    mov [boot_drive], dl

    ; === Bật A20 (an toàn) ===
    in al, 0x92
    test al, 2
    jnz a20_done
    or al, 2
    and al, 0xFE        ; Bit 0 = reset trigger, KHÔNG được set
    out 0x92, al
a20_done:

    ; === Đọc E820 Memory Map (trước VBE) ===
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
    jc e820_done        ; CF=1 sau entry cuối trên một số BIOS = bình thường
    cmp eax, 0x534D4150
    jne error_handler
    add di, 24
    inc word [0x7FF0]
    test ebx, ebx
    jnz e820_loop
e820_done:

    ; === VBE: Lấy danh sách mode (0x4F00) ===
    ; (Lý tưởng: parse mode list, ở đây hardcode có điều kiện)
    ; Lấy Mode Info Block trước khi set
    xor ax, ax
    mov es, ax
    mov ax, 0x4F01
    mov cx, 0x4118
    mov di, 0x7E00
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; Set VBE mode (bit 14 = linear framebuffer)
    mov ax, 0x4F02
    mov bx, 0x4118 | 0x4000   ; Linear framebuffer flag
    int 0x10
    cmp ax, 0x004F
    jne error_handler

    ; === Nạp Stage 2 (chia làm 2 lần, ≤63 sectors mỗi lần) ===
    ; Reset disk controller
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    jc error_handler

    ; Lần 1: 63 sectors đầu vào 0x10000
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

    ; Lần 2: 65 sectors còn lại vào 0x17E00 (0x1000 + 63*512/16 = 0x2F80... )
    ; 63 sectors = 63*512 = 32256 bytes = 0x7E00
    ; ES mới = 0x1000 + 0x7E00/0x10 = 0x1000 + 0x7E0 = 0x17E0
    mov ax, 0x17E0
    mov es, ax
    xor bx, bx
    mov ah, 0x02
    mov al, 65
    mov ch, 0
    mov cl, 65          ; Sector vật lý 65 (1-indexed)
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

error_handler:
    ; In 'E' để biết có lỗi
    mov ah, 0x0E
    mov al, 'E'
    int 0x10
    cli
    hlt
    jmp error_handler

boot_drive: db 0

BITS 32
init_pm:
    mov ax, DATA_SEG
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x90000

    ; Truyền boot drive cho Stage 2
    movzx eax, byte [0x7C00 + (boot_drive - $$)]
    push eax
    call 0x10000        ; Dùng call thay jmp để có return address

gdt_start:
    dd 0x0, 0x0
gdt_code:
    dw 0xffff
    dw 0x0000
    db 0x00
    db 0x9a
    db 0xcf
    db 0x00
gdt_data:
    dw 0xffff
    dw 0x0000
    db 0x00
    db 0x92
    db 0xcf
    db 0x00
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt_start - 1
    dd gdt_start

CODE_SEG equ gdt_code - gdt_start
DATA_SEG equ gdt_data - gdt_start

times 510 - ($ - $$) db 0
dw 0xaa55
