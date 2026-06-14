; =============================================
; FAT32 Stage2 - Đọc kernel từ ổ đĩa (ATA PIO)
; =============================================
BITS 32
global load_kernel_from_fat32

load_kernel_from_fat32:
    push ebp
    mov ebp, esp

    ; Đọc 128 sector (64KB) kernel từ LBA 10 trở đi
    ; (Bạn có thể thay đổi LBA khi tạo image sau)
    mov ebx, 0x100000       ; Địa chỉ đích
    mov ecx, 128            ; Số sector cần đọc
    mov edx, 0x1F0          ; ATA Data Port

    mov eax, 10             ; LBA bắt đầu (sector 10)
    call ata_read_sectors

    mov esp, ebp
    pop ebp
    ret

; ==================== Hàm đọc sector ATA PIO ====================
ata_read_sectors:
    ; eax = LBA, ecx = số sector, ebx = buffer đích
    pushad

.read_loop:
    ; Gửi lệnh đọc
    mov dx, 0x1F2
    mov al, 1               ; đọc 1 sector/lần
    out dx, al

    mov dx, 0x1F3
    mov al, al              ; LBA low
    out dx, al

    mov dx, 0x1F4
    shr eax, 8
    out dx, al

    mov dx, 0x1F5
    shr eax, 8
    out dx, al

    mov dx, 0x1F6
    shr eax, 8
    or al, 0xE0             ; LBA mode + master
    out dx, al

    mov dx, 0x1F7
    mov al, 0x20            ; READ SECTORS
    out dx, al

.wait_ready:
    in al, dx
    test al, 0x80           ; BSY
    jnz .wait_ready
    test al, 0x08           ; DRQ
    jz .wait_ready

    ; Đọc 256 word (512 byte)
    mov dx, 0x1F0
    mov edi, ebx
    mov cx, 256
    rep insw

    add ebx, 512
    dec dword [esp+28]      ; giảm ecx (số sector còn lại)
    jnz .read_loop

    popad
    ret
