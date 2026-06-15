; =====================================================
; stage2/entry.asm
; Điểm vào chính của Stage 2 (Protected Mode)
; =====================================================

BITS 32

global stage2_entry
extern fat32_init          ; Sẽ viết sau trong fat32.asm
extern load_boot_messages  ; Sẽ viết sau

section .text

stage2_entry:
    ; Lấy boot drive từ stack (do boot.asm push)
    pop eax
    mov [boot_drive], eax

    ; Thiết lập stack mới cho Stage 2 (an toàn)
    mov esp, 0x90000
    mov ebp, esp

    ; === Gọi các hàm khởi tạo ===
    ; (Hiện tại comment lại, sẽ mở dần)

    ; call fat32_init
    ; call load_boot_messages

    ; Tạm thời: dừng tại đây để test
    hlt
    jmp $

; =====================================================
; Dữ liệu
; =====================================================
section .data
boot_drive: dd 0

section .bss
; Chỗ để khai báo biến sau này nếu cần
