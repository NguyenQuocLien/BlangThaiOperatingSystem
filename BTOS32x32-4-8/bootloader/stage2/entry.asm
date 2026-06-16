; =====================================================
; stage2/entry.asm
; Điểm vào chính của Stage 2 (Protected Mode 32-bit)
; Phiên bản: 2.1 — Fix F1 interrupt, fix .do_menu
; =====================================================
;
; CALLING CONVENTION (từ Stage 1 boot.asm):
;   Stage 1 thực hiện:  push eax (boot_drive)
;                       call 0x10000
;   => Tại entry, stack layout:
;       [esp+0] = return address (từ call)
;       [esp+4] = boot_drive (uint32_t)
;
; MEMORY MAP:
;   0x00007C00 - Bootloader Stage 1
;   0x00007E00 - VBE Mode Info Block
;   0x00008500 - E820 Memory Map entries
;   0x00007FF0 - E820 entry count (word)
;   0x00007FFC - Boot state flag (byte)
;   0x00010000 - Stage 2 (file này, load tại đây)
;   0x00090000 - Stack top (grow xuống)
;   0x00020000 - Language file buffer
;   0x00030000 - Parsed language table
; =====================================================

BITS 32

; =====================================================
; CONSTANTS — khai báo TẤT CẢ ở đây, trước section .text
; =====================================================
STACK_TOP               equ 0x90000
LANG_FILE_LOAD_ADDR     equ 0x20000
LANG_TABLE_ADDR         equ 0x30000
LANG_FILE_MAX_SIZE      equ 0x8000
LANG_NAME_MAX_LEN       equ 32
LANG_CODE_LEN           equ 8
LANG_MAX_ENTRIES        equ 64
LANG_ENTRY_SIZE         equ (LANG_NAME_MAX_LEN + LANG_CODE_LEN + 4)
MENU_TIMEOUT_SECONDS    equ 10
DEFAULT_LANGUAGE_IDX    equ 0
VGA_TEXT_BASE           equ 0xB8000
VGA_COLS                equ 80
VGA_ROWS                equ 25
COLOR_NORMAL            equ 0x07
COLOR_HIGHLIGHT         equ 0x70
COLOR_TITLE             equ 0x0F
COLOR_TIMEOUT           equ 0x0E
COLOR_ERROR             equ 0x0C
COLOR_WARNING           equ 0x0E    ; Vàng — dùng cho cảnh báo

; F1 interrupt constants
F1_SCANCODE             equ 0x3B
BOOT_STATE_ADDR         equ 0x7FFC
BOOT_STATE_NORMAL       equ 0
BOOT_STATE_INTERRUPTED  equ 1

; =====================================================
; MACRO CHECK_F1_INTERRUPT — định nghĩa DUY NHẤT 1 LẦN
; Đặt tại các checkpoint trong stage2_entry
; =====================================================
%macro CHECK_F1_INTERRUPT 0
    in al, 0x64             ; Keyboard status port
    test al, 1              ; Output buffer full?
    jz %%no_key
    in al, 0x60             ; Đọc scan code
    cmp al, F1_SCANCODE     ; F1?
    jne %%no_key
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INTERRUPTED
    jmp boot_interrupted    ; Nhảy tới handler tập trung
%%no_key:
%endmacro

; =====================================================
; EXPORTS
; =====================================================
global stage2_entry
global show_boot_menu
global handle_language_selection
global load_language_list
global parse_language_file
global get_language_count
global get_language_name
global get_language_code

; =====================================================
; IMPORTS
; =====================================================
extern fat32_init
extern fat32_load_file
extern pit_get_ticks
extern pit_init
extern show_main_menu           ; Từ menu.asm

; =====================================================
; SECTION TEXT
; =====================================================
section .text

; =====================================================
; stage2_entry
; =====================================================
stage2_entry:
    ; Lưu boot_drive TRƯỚC KHI di chuyển stack
    mov eax, [esp + 4]
    mov [boot_drive], eax

    ; Reset stack
    mov esp, STACK_TOP
    mov ebp, esp

    ; Checkpoint 0: Ngay khi vào Stage 2
    CHECK_F1_INTERRUPT

    ; Bước 3: Clear màn hình
    call clear_screen

    ; Bước 4: Khởi tạo PIT
    call pit_init

    ; Checkpoint 1: Trước fat32_init
    CHECK_F1_INTERRUPT

    ; Bước 5: Khởi tạo FAT32
    push dword [boot_drive]
    call fat32_init
    add esp, 4
    test eax, eax
    jnz .fat32_init_failed

    ; Checkpoint 2: Trước load language
    CHECK_F1_INTERRUPT

    ; Bước 6: Load danh sách ngôn ngữ
    call load_language_list
    test eax, eax
    jnz .lang_load_failed

    ; Checkpoint 3: Trước show menu / load kernel
    CHECK_F1_INTERRUPT

    ; Bước 7: Hiển thị menu ngôn ngữ
    call show_boot_menu
    mov [selected_language], eax

    ; Bước 8: Load kernel
    push dword [selected_language]
    call load_kernel_with_language
    add esp, 4
    test eax, eax
    jz .main_loop           ; Kernel tự jump, không return ở đây

    ; Kernel load thất bại -> vào menu chính
.kernel_load_failed:
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INTERRUPTED
    push dword COLOR_ERROR
    push dword err_kernel_load
    push dword 24
    push dword 0
    call print_string_at_color
    add esp, 16
    call show_main_menu     ; Từ menu.asm, không return
    jmp .main_loop          ; Safety

; --- Vòng lặp an toàn (không bao giờ đến đây) ---
.main_loop:
    cli
    hlt
    jmp .main_loop

; --- Error handlers ---
.fat32_init_failed:
    push dword COLOR_ERROR
    push dword err_fat32_init
    push dword 12
    push dword 0
    call print_string_at_color
    add esp, 16
    jmp .halt

.lang_load_failed:
    ; Thông báo, dùng English mặc định
    push dword COLOR_WARNING
    push dword warn_lang_default
    push dword 2
    push dword 0
    call print_string_at_color
    add esp, 16

    mov dword [language_count], 1
    mov dword [lang_table_ptr], LANG_TABLE_ADDR
    mov esi, default_lang_name
    mov edi, LANG_TABLE_ADDR
    mov ecx, LANG_NAME_MAX_LEN
    call strncpy_safe
    mov esi, default_lang_code
    mov edi, LANG_TABLE_ADDR + LANG_NAME_MAX_LEN
    mov ecx, LANG_CODE_LEN
    call strncpy_safe

    ; Fall through vào .do_menu

.do_menu:
    ; Boot state = NORMAL (lần đầu boot với default language)
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_NORMAL
    call show_main_menu     ; Từ menu.asm, không bao giờ return
    ; Safety:
    jmp .main_loop

.halt:
    cli
    hlt
    jmp .halt

; =====================================================
; boot_interrupted
; Handler tập trung khi F1 bị ấn bất kỳ lúc nào
; Đây là GLOBAL label (không có dấu chấm đầu)
; => có thể nhảy tới từ bất kỳ đâu trong file
; =====================================================
boot_interrupted:
    ; Hiện thông báo
    push dword COLOR_WARNING
    push dword str_boot_interrupted
    push dword 12
    push dword 15
    call print_string_at_color
    add esp, 16

    ; Delay ~2 giây (36 ticks PIT @ 18.2 Hz)
    call pit_get_ticks
    add eax, 36
    mov [temp_tick], eax
.bi_wait:
    call pit_get_ticks
    cmp eax, [temp_tick]
    jl .bi_wait

    ; Đặt boot state
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INTERRUPTED

    ; Vào menu chính
    call show_main_menu     ; Không return
    ; Safety:
    cli
    hlt
    jmp $

; =====================================================
; load_language_list
; =====================================================
load_language_list:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp

    push dword LANG_FILE_MAX_SIZE
    push dword LANG_FILE_LOAD_ADDR
    push dword language_file_name
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .load_error
    test eax, eax
    jz .load_error

    mov [lang_file_size], eax

    push eax
    call parse_language_file
    add esp, 4

    cmp eax, 0
    je .parse_error
    mov [language_count], eax

    xor eax, eax
    jmp .done

.load_error:
    mov eax, -1
    jmp .done

.parse_error:
    mov eax, -1

.done:
    mov esp, ebp
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; parse_language_file
; Input:  [esp+4] = số bytes trong buffer
; Output: EAX = số entry parse được
; =====================================================
parse_language_file:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp

    mov esi, LANG_FILE_LOAD_ADDR
    mov edi, LANG_TABLE_ADDR
    mov ecx, [lang_file_size]

    xor edx, edx
    mov [lang_table_ptr], edi

.parse_loop:
    test ecx, ecx
    jz .parse_done

    mov al, [esi]
    cmp al, '#'
    je .skip_line
    cmp al, 0x0A
    je .next_char
    cmp al, 0x0D
    je .next_char
    cmp al, 0
    je .parse_done

    cmp edx, LANG_MAX_ENTRIES
    jge .parse_done

    push esi
    push edi
    mov ebx, edi

    mov edi, ebx
    add edi, LANG_NAME_MAX_LEN
    push edi
    xor ah, ah
.read_code:
    cmp byte [esi], '|'
    je .code_done
    cmp byte [esi], 0x0A
    je .line_malformed
    cmp byte [esi], 0
    je .parse_done
    cmp ah, LANG_CODE_LEN - 1
    jge .skip_char_code
    mov al, [esi]
    mov [edi], al
    inc edi
    inc ah
.skip_char_code:
    inc esi
    dec ecx
    jmp .read_code
.code_done:
    mov byte [edi], 0
    inc esi
    dec ecx
    pop edi

    mov edi, ebx
    xor ah, ah
.read_name:
    cmp byte [esi], 0x0A
    je .name_done
    cmp byte [esi], 0x0D
    je .name_done
    cmp byte [esi], 0
    je .name_done_eof
    cmp ah, LANG_NAME_MAX_LEN - 1
    jge .skip_char_name
    mov al, [esi]
    mov [edi], al
    inc edi
    inc ah
.skip_char_name:
    inc esi
    dec ecx
    jmp .read_name
.name_done:
    mov byte [edi], 0
.skip_crlf:
    cmp byte [esi], 0x0D
    jne .check_lf
    inc esi
    dec ecx
.check_lf:
    cmp byte [esi], 0x0A
    jne .entry_done
    inc esi
    dec ecx
    jmp .entry_done
.name_done_eof:
    mov byte [edi], 0

.entry_done:
    mov edi, ebx
    add edi, LANG_NAME_MAX_LEN + LANG_CODE_LEN
    mov dword [edi], 0

    pop edi
    pop esi
    mov edi, ebx
    add edi, LANG_ENTRY_SIZE
    inc edx
    jmp .parse_loop

.line_malformed:
    pop edi
    pop esi
.skip_line:
.skip_loop:
    cmp byte [esi], 0x0A
    je .next_char
    cmp byte [esi], 0
    je .parse_done
    inc esi
    dec ecx
    jmp .skip_loop

.next_char:
    inc esi
    dec ecx
    jmp .parse_loop

.parse_done:
    mov eax, edx

    mov esp, ebp
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; show_boot_menu
; Output: EAX = index ngôn ngữ được chọn
; =====================================================
show_boot_menu:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp
    sub esp, 16

    mov eax, [language_count]
    mov [ebp - 8], eax

    cmp eax, 1
    je .single_language

    call draw_menu_frame

    mov dword [ebp - 4], 0
    call pit_get_ticks
    add eax, MENU_TIMEOUT_SECONDS * 18
    mov [ebp - 12], eax

    push dword [ebp - 4]
    call draw_language_list
    add esp, 4

    push dword [ebp - 12]
    call draw_timeout_bar
    add esp, 4

.input_loop:
    call pit_get_ticks
    mov [ebp - 16], eax
    cmp eax, [ebp - 12]
    jge .timeout

    mov eax, [ebp - 12]
    sub eax, [ebp - 16]
    xor edx, edx
    mov ecx, 18
    div ecx
    push eax
    call draw_timeout_bar
    add esp, 4

    call read_key_nonblocking
    test eax, eax
    jz .input_loop

    ; Kiểm tra F1 ngay trong vòng lặp menu
    cmp eax, F1_SCANCODE
    je .f1_in_menu

    cmp eax, 0x48
    je .key_up
    cmp eax, 0x50
    je .key_down
    cmp eax, 0x1C
    je .key_enter
    cmp eax, 0x01
    je .key_esc

    cmp eax, 0x02
    jl .input_loop
    cmp eax, 0x0A
    jge .input_loop
    sub eax, 0x02
    cmp eax, [ebp - 8]
    jge .input_loop
    mov [ebp - 4], eax
    jmp .key_enter

.f1_in_menu:
    ; F1 ấn ngay trong menu ngôn ngữ -> vào menu chính
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INTERRUPTED
    mov esp, ebp
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    jmp boot_interrupted

.key_up:
    mov eax, [ebp - 4]
    test eax, eax
    jz .wrap_to_bottom
    dec eax
    mov [ebp - 4], eax
    jmp .redraw

.wrap_to_bottom:
    mov eax, [ebp - 8]
    dec eax
    mov [ebp - 4], eax
    jmp .redraw

.key_down:
    mov eax, [ebp - 4]
    inc eax
    cmp eax, [ebp - 8]
    jl .set_selected
    xor eax, eax
.set_selected:
    mov [ebp - 4], eax

.redraw:
    push dword [ebp - 4]
    call draw_language_list
    add esp, 4
    jmp .input_loop

.key_enter:
    mov eax, [ebp - 4]
    jmp .done

.key_esc:
.timeout:
    mov eax, DEFAULT_LANGUAGE_IDX
    jmp .done

.single_language:
    xor eax, eax

.done:
    mov esp, ebp
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; draw_menu_frame
; =====================================================
draw_menu_frame:
    push ebx
    push ecx
    push edx

    call clear_screen

    push dword COLOR_TITLE
    push dword str_menu_title
    push dword 1
    push dword 10
    call print_string_at_color
    add esp, 16

    push dword COLOR_TITLE
    push dword str_separator
    push dword 2
    push dword 0
    call print_string_at_color
    add esp, 16

    push dword COLOR_NORMAL
    push dword str_key_help
    push dword 22
    push dword 0
    call print_string_at_color
    add esp, 16

    push dword COLOR_NORMAL
    push dword str_key_help2
    push dword 23
    push dword 0
    call print_string_at_color
    add esp, 16

    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; draw_language_list
; Input: [esp+4] = selected index
; =====================================================
draw_language_list:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp

    mov ebx, [ebp + 28]
    mov ecx, [language_count]
    xor edx, edx
    mov esi, LANG_TABLE_ADDR

.draw_loop:
    cmp edx, ecx
    jge .draw_done

    mov eax, COLOR_NORMAL
    cmp edx, ebx
    jne .set_color
    mov eax, COLOR_HIGHLIGHT
.set_color:
    push eax

    mov eax, edx
    add eax, 4

    push dword [esp]
    push esi
    push eax
    push dword 4
    call print_string_at_color
    add esp, 16

    pop eax

    add esi, LANG_ENTRY_SIZE
    inc edx
    jmp .draw_loop

.draw_done:
    mov esp, ebp
    pop ebp
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; draw_timeout_bar
; Input: [esp+4] = giây còn lại
; =====================================================
draw_timeout_bar:
    push ebx
    push ecx
    push edx
    push ebp
    mov ebp, esp

    push dword [ebp + 20]
    push dword str_timeout_prefix
    push dword 20
    push dword 0
    call print_timeout_line
    add esp, 16

    mov esp, ebp
    pop ebp
    pop edx
    pop ecx
    pop ebx
    ret

; =====================================================
; handle_language_selection (wrapper)
; =====================================================
handle_language_selection:
    call show_boot_menu
    ret

; =====================================================
; get_language_count
; =====================================================
get_language_count:
    mov eax, [language_count]
    ret

; =====================================================
; get_language_name
; Input: [esp+4] = index
; Output: EAX = ptr hoặc 0
; =====================================================
get_language_name:
    mov eax, [esp + 4]
    cmp eax, [language_count]
    jge .invalid
    mov ecx, LANG_ENTRY_SIZE
    mul ecx
    add eax, LANG_TABLE_ADDR
    ret
.invalid:
    xor eax, eax
    ret

; =====================================================
; get_language_code
; Input: [esp+4] = index
; Output: EAX = ptr hoặc 0
; =====================================================
get_language_code:
    mov eax, [esp + 4]
    cmp eax, [language_count]
    jge .invalid
    mov ecx, LANG_ENTRY_SIZE
    mul ecx
    add eax, LANG_TABLE_ADDR + LANG_NAME_MAX_LEN
    ret
.invalid:
    xor eax, eax
    ret

; =====================================================
; load_kernel_with_language
; Input: [esp+4] = language index
; Output: EAX = 0 (không return nếu thành công)
; =====================================================
load_kernel_with_language:
    push ebp
    mov ebp, esp

    push dword [ebp + 8]
    call get_language_code
    add esp, 4
    mov [kernel_lang_code_ptr], eax

    ; TODO: fat32_load_file kernel rồi jmp vào entry point

    xor eax, eax    ; Placeholder — hiện tại luôn "thành công" (return 0)
    pop ebp
    ret

; =====================================================
; HELPERS
; =====================================================

clear_screen:
    push edi
    push ecx
    push eax
    mov edi, VGA_TEXT_BASE
    mov ecx, VGA_COLS * VGA_ROWS
    mov ax, 0x0720
    rep stosw
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, 0
    out dx, al
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, 0
    out dx, al
    pop eax
    pop ecx
    pop edi
    ret

print_string_at_color:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ebx
    mov eax, [ebp + 8]
    mov ecx, VGA_COLS
    mul ecx
    add eax, [ebp + 4]
    shl eax, 1
    add eax, VGA_TEXT_BASE
    mov edi, eax
    mov esi, [ebp + 12]
    mov ah, [ebp + 16]
.loop:
    mov al, [esi]
    test al, al
    jz .done
    mov [edi], ax
    add edi, 2
    inc esi
    jmp .loop
.done:
    pop ebx
    pop edi
    pop esi
    pop ebp
    ret

print_string_at:
    push ebp
    mov ebp, esp
    push dword COLOR_NORMAL
    push dword [ebp + 16]
    push dword [ebp + 12]
    push dword [ebp + 8]
    call print_string_at_color
    add esp, 16
    pop ebp
    ret

print_error:
    push ebp
    mov ebp, esp
    push dword COLOR_ERROR
    push dword [ebp + 12]
    push dword [ebp + 8]
    push dword [ebp + 4]
    call print_string_at_color
    add esp, 16
    pop ebp
    ret

print_timeout_line:
    push ebp
    mov ebp, esp
    push esi
    push edi

    push dword COLOR_TIMEOUT
    push dword [ebp + 12]
    push dword [ebp + 8]
    push dword [ebp + 4]
    call print_string_at_color
    add esp, 16

    mov esi, [ebp + 12]
    xor ecx, ecx
.count:
    cmp byte [esi + ecx], 0
    je .count_done
    inc ecx
    jmp .count
.count_done:
    mov eax, [ebp + 4]
    add eax, ecx

    mov edx, [ebp + 16]
    push edx
    push dword timeout_num_buf
    call itoa_decimal
    add esp, 8

    push dword COLOR_TIMEOUT
    push dword timeout_num_buf
    push dword [ebp + 8]
    push eax
    call print_string_at_color
    add esp, 16

    pop edi
    pop esi
    pop ebp
    ret

read_key_nonblocking:
    in al, 0x64
    test al, 1
    jz .no_key
    in al, 0x60
    movzx eax, al
    test eax, 0x80
    jnz .no_key
    ret
.no_key:
    xor eax, eax
    ret

strncpy_safe:
    push ecx
    push esi
    push edi
    test ecx, ecx
    jz .done
    dec ecx
.copy:
    test ecx, ecx
    jz .terminate
    lodsb
    test al, al
    jz .terminate
    stosb
    dec ecx
    jmp .copy
.terminate:
    mov byte [edi], 0
.done:
    pop edi
    pop esi
    pop ecx
    ret

itoa_decimal:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ebx
    push ecx
    mov edi, [ebp + 4]
    mov eax, [ebp + 8]
    mov ebx, 10
    test eax, eax
    jnz .convert
    mov byte [edi], '0'
    mov byte [edi + 1], 0
    jmp .done
.convert:
    xor ecx, ecx
.div_loop:
    test eax, eax
    jz .write
    xor edx, edx
    div ebx
    add dl, '0'
    push edx
    inc ecx
    jmp .div_loop
.write:
    pop edx
    mov [edi], dl
    inc edi
    dec ecx
    jnz .write
    mov byte [edi], 0
.done:
    pop ecx
    pop ebx
    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; SECTION DATA
; =====================================================
section .data align=4

boot_drive:             dd 0
selected_language:      dd 0
language_count:         dd 0
lang_file_size:         dd 0
lang_table_ptr:         dd LANG_TABLE_ADDR
kernel_lang_code_ptr:   dd 0

language_file_name:     db "LANGUAGES.BIN", 0
kernel_file_name:       db "KERNEL.BIN", 0

default_lang_name:      db "English", 0
default_lang_code:      db "en", 0

str_menu_title:
    db "  BTOS Bootloader v2.1 - Language / Ngon ngu / Langue  ", 0
str_separator:
    db "========================================================", 0
str_key_help:
    db "  [UP]/[DOWN]: Navigate    [ENTER]: Select    [ESC]: Default", 0
str_key_help2:
    db "  [1]-[9]: Quick select    [F1]: Boot Menu", 0
str_timeout_prefix:
    db "  Auto-selecting default in ", 0
str_timeout_suffix:
    db " seconds...", 0

; Chuỗi cho boot_interrupted handler
str_boot_interrupted:
    db "  [F1] Boot interrupted. Entering Boot Menu...", 0

err_fat32_init:
    db "[ERROR] FAT32 initialization failed. System halted.", 0
err_kernel_load:
    db "[ERROR] Failed to load kernel. Check disk integrity.", 0
warn_lang_default:
    db "[WARN] Language file not found. Using default (English).", 0

; =====================================================
; SECTION BSS
; =====================================================
section .bss align=4

timeout_num_buf:    resb 12
temp_tick:          resd 1      ; Dùng bởi boot_interrupted delay

; =====================================================
; FORMAT LANGUAGES.BIN
; =====================================================
; Plain text UTF-8, mỗi dòng: CODE|NAME
; Ví dụ:
;   # Comment
;   vi|Tieng Viet
;   en|English
;   ja|Japanese
; =====================================================
