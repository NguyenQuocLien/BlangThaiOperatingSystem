; =====================================================
; stage2/menu.asm
; Menu chính BTOS Bootloader
; Phiên bản: 1.1
;
; VẤN ĐỀ ĐÃ SỬA:
;   1. Thêm VGA_COLS, VGA_ROWS, COLOR_TITLE vào constants
;   2. boot_drive_global được sync từ entry.asm
;      (entry.asm extern boot_drive_global và gán trước
;       khi gọi show_main_menu)
;   3. extern stage2_entry bị thừa -> xóa
;   4. draw_all_menu_items: xóa "ternary" NASM giả
;      (push dword (eax == ebx ? ...) là INVALID syntax)
;   5. menu_resume_boot: thay cli+hlt bằng reload kernel
;   6. cursor_pos_low/high trong draw_partition_confirm_screen
;      được tính đúng thay vì đọc từ biến chưa init
;
; FLOW:
;   stage2_entry  -->  show_main_menu
;                           |
;              +------------+------------+-----------+
;              |            |            |           |
;          [1] Resume   [2] Language  [3] Settings  [4] Partition Editor
;              |            |            |           |
;       reload kernel  show_boot_menu  settings.asm  editing.asm
;
; MEMORY MAP:
;   0x7FFC        — Boot state flag
;   0x40000       — Settings buffer    (4 KB)
;   0x41000       — Partition editor   (60 KB)
;   0x51000       — FAT32 sector cache (16 KB)
; =====================================================

BITS 32

; =====================================================
; CONSTANTS
; =====================================================
; VGA
VGA_TEXT_BASE           equ 0xB8000
VGA_COLS                equ 80
VGA_ROWS                equ 25

; Màu sắc — khai báo đầy đủ, không extern
COLOR_NORMAL            equ 0x07
COLOR_HIGHLIGHT         equ 0x70
COLOR_TITLE             equ 0x0F        ; ← Đã thêm
COLOR_MENU_BORDER       equ 0x0B
COLOR_MENU_ITEM         equ 0x07
COLOR_MENU_SELECTED     equ 0x70
COLOR_MENU_KEY          equ 0x0E
COLOR_MENU_DESC         equ 0x08
COLOR_WARNING           equ 0x0C
COLOR_SUCCESS           equ 0x0A
COLOR_PARTITION_WARN    equ 0x4F

; Boot state
BOOT_STATE_ADDR         equ 0x7FFC
BOOT_STATE_NORMAL       equ 0
BOOT_STATE_INTERRUPTED  equ 1
BOOT_STATE_SETTINGS     equ 2

; Menu layout
MENU_ITEM_RESUME        equ 1
MENU_ITEM_LANGUAGE      equ 2
MENU_ITEM_SETTINGS      equ 3
MENU_ITEM_PARTITION     equ 4
MENU_ITEM_COUNT         equ 4
MENU_START_ROW          equ 5
MENU_START_COL          equ 20
MENU_ITEM_HEIGHT        equ 3

; Memory vùng làm việc
SETTINGS_BUF_ADDR       equ 0x00040000
EDITOR_BUF_ADDR         equ 0x00041000
FAT32_CACHE_ADDR        equ 0x00051000

; =====================================================
; EXPORTS
; =====================================================
global show_main_menu
global menu_resume_boot
global menu_enter_language
global menu_enter_settings
global menu_enter_partition_editor
global get_boot_state
global set_boot_state
global boot_drive_global        ; ← Export để entry.asm có thể gán

; =====================================================
; IMPORTS
; =====================================================
; ĐÃ XÓA: extern stage2_entry   (không dùng ở đâu)
extern show_boot_menu           ; Từ entry.asm
extern load_kernel_with_language ; Từ entry.asm (cho Resume)
extern fat32_init
extern fat32_load_file
extern fat32_write_file
extern fat32_list_dir
extern pit_get_ticks
extern pit_init
extern print_string_at_color    ; Từ entry.asm
extern clear_screen             ; Từ entry.asm

; =====================================================
; SECTION TEXT
; =====================================================
section .text

; =====================================================
; show_main_menu
; Vòng lặp menu chính, không bao giờ return
; =====================================================
show_main_menu:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp
    sub esp, 8          ; [ebp-4]=selected(1-based), [ebp-8]=boot_state

    movzx eax, byte [BOOT_STATE_ADDR]
    mov [ebp - 8], eax

    call draw_main_menu_frame
    mov dword [ebp - 4], 1

.menu_loop:
    push dword [ebp - 4]
    push dword [ebp - 8]
    call draw_all_menu_items
    add esp, 8

    call read_key_blocking

    cmp eax, 0x48       ; UP
    je .key_up
    cmp eax, 0x50       ; DOWN
    je .key_down
    cmp eax, 0x1C       ; ENTER
    je .key_enter
    cmp eax, 0x02       ; '1'
    je .select_1
    cmp eax, 0x03       ; '2'
    je .select_2
    cmp eax, 0x04       ; '3'
    je .select_3
    cmp eax, 0x05       ; '4'
    je .select_4
    jmp .menu_loop

.key_up:
    mov eax, [ebp - 4]
    dec eax
    jnz .set_sel
    mov eax, MENU_ITEM_COUNT
    jmp .set_sel

.key_down:
    mov eax, [ebp - 4]
    inc eax
    cmp eax, MENU_ITEM_COUNT + 1
    jl .set_sel
    mov eax, 1

.set_sel:
    mov [ebp - 4], eax
    jmp .menu_loop

.select_1:
    mov dword [ebp - 4], 1
    jmp .key_enter
.select_2:
    mov dword [ebp - 4], 2
    jmp .key_enter
.select_3:
    mov dword [ebp - 4], 3
    jmp .key_enter
.select_4:
    mov dword [ebp - 4], 4
    jmp .key_enter

.key_enter:
    mov eax, [ebp - 4]
    cmp eax, MENU_ITEM_RESUME
    je .do_resume
    cmp eax, MENU_ITEM_LANGUAGE
    je .do_language
    cmp eax, MENU_ITEM_SETTINGS
    je .do_settings
    cmp eax, MENU_ITEM_PARTITION
    je .do_partition
    jmp .menu_loop

.do_resume:
    call menu_resume_boot
    jmp show_main_menu

.do_language:
    call menu_enter_language
    jmp show_main_menu

.do_settings:
    call menu_enter_settings
    jmp show_main_menu

.do_partition:
    call menu_enter_partition_editor
    jmp show_main_menu

; =====================================================
; draw_main_menu_frame
; =====================================================
draw_main_menu_frame:
    push ebp
    mov ebp, esp
    push esi
    push edi

    call clear_screen

    push dword COLOR_TITLE
    push dword str_header_title
    push dword 0
    push dword 12
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_DESC
    push dword str_header_version
    push dword 1
    push dword 15
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_BORDER
    push dword str_line_single
    push dword 2
    push dword 0
    call print_string_at_color
    add esp, 16

    call draw_boot_status_line

    push dword COLOR_MENU_BORDER
    push dword str_line_single
    push dword 4
    push dword 0
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_BORDER
    push dword str_line_single
    push dword 21
    push dword 0
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_DESC
    push dword str_footer_nav
    push dword 22
    push dword 8
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_DESC
    push dword str_footer_select
    push dword 23
    push dword 8
    call print_string_at_color
    add esp, 16

    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; draw_boot_status_line
; =====================================================
draw_boot_status_line:
    push ebp
    mov ebp, esp

    movzx eax, byte [BOOT_STATE_ADDR]
    cmp eax, BOOT_STATE_INTERRUPTED
    je .interrupted
    cmp eax, BOOT_STATE_SETTINGS
    je .settings_mode

    push dword COLOR_SUCCESS
    push dword str_state_normal
    push dword 3
    push dword 2
    call print_string_at_color
    add esp, 16
    jmp .done

.interrupted:
    push dword COLOR_WARNING
    push dword str_state_interrupted
    push dword 3
    push dword 2
    call print_string_at_color
    add esp, 16
    jmp .done

.settings_mode:
    push dword COLOR_MENU_KEY
    push dword str_state_settings
    push dword 3
    push dword 2
    call print_string_at_color
    add esp, 16

.done:
    pop ebp
    ret

; =====================================================
; draw_all_menu_items
; Input (cdecl): [esp+4]=selected(1-based), [esp+8]=boot_state
;
; SỬA: Xóa hoàn toàn "ternary expression" NASM giả
;      Dùng cmp/je thuần túy cho từng item
; =====================================================
draw_all_menu_items:
    push ebp
    mov ebp, esp
    push ebx
    push ecx

    mov ebx, [ebp + 8]      ; selected
    mov ecx, [ebp + 12]     ; boot_state

    ; --- Item 1: Resume ---
    ; Màu: SELECTED nếu ebx==1, DIM nếu boot_state==NORMAL, ITEM nếu khác
    cmp ebx, 1
    je .item1_sel
    cmp ecx, BOOT_STATE_NORMAL
    je .item1_dim
    mov eax, COLOR_MENU_ITEM
    jmp .item1_draw
.item1_sel:
    mov eax, COLOR_MENU_SELECTED
    jmp .item1_draw
.item1_dim:
    mov eax, COLOR_MENU_DESC
.item1_draw:
    push eax
    push dword str_item1_desc
    push dword str_item1_name
    push dword str_item1_key
    push dword MENU_START_ROW
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    ; --- Item 2: Language ---
    mov eax, COLOR_MENU_ITEM
    cmp ebx, 2
    jne .item2_draw
    mov eax, COLOR_MENU_SELECTED
.item2_draw:
    push eax
    push dword str_item2_desc
    push dword str_item2_name
    push dword str_item2_key
    push dword (MENU_START_ROW + MENU_ITEM_HEIGHT)
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    ; --- Item 3: Settings ---
    mov eax, COLOR_MENU_ITEM
    cmp ebx, 3
    jne .item3_draw
    mov eax, COLOR_MENU_SELECTED
.item3_draw:
    push eax
    push dword str_item3_desc
    push dword str_item3_name
    push dword str_item3_key
    push dword (MENU_START_ROW + MENU_ITEM_HEIGHT * 2)
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    ; --- Item 4: Partition Editor ---
    mov eax, COLOR_MENU_ITEM
    cmp ebx, 4
    jne .item4_draw
    mov eax, COLOR_MENU_SELECTED
.item4_draw:
    push eax
    push dword str_item4_desc
    push dword str_item4_name
    push dword str_item4_key
    push dword (MENU_START_ROW + MENU_ITEM_HEIGHT * 3)
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    pop ecx
    pop ebx
    pop ebp
    ret

; =====================================================
; draw_single_menu_item
; Vẽ 1 item: dòng 1 = "[N] NAME", dòng 2 = "    desc"
;
; Input (cdecl — push từ trái sang phải, tức là push ngược):
;   [esp+4]  = col
;   [esp+8]  = row
;   [esp+12] = key_ptr   "[1]"
;   [esp+16] = name_ptr
;   [esp+20] = desc_ptr
;   [esp+24] = color
; =====================================================
draw_single_menu_item:
    push ebp
    mov ebp, esp
    push ebx

    mov ebx, [ebp + 28]     ; color

    ; In key "[N]"
    push ebx
    push dword [ebp + 12]   ; key_ptr
    push dword [ebp + 8]    ; row
    push dword [ebp + 4]    ; col
    call print_string_at_color
    add esp, 16

    ; In name (col + 4, sau "[N] ")
    mov eax, [ebp + 4]
    add eax, 4
    push ebx
    push dword [ebp + 16]   ; name_ptr
    push dword [ebp + 8]    ; row
    push eax
    call print_string_at_color
    add esp, 16

    ; In desc (row+1, màu xám)
    mov eax, [ebp + 8]
    inc eax
    push dword COLOR_MENU_DESC
    push dword [ebp + 20]   ; desc_ptr
    push eax
    push dword [ebp + 4]    ; col gốc
    call print_string_at_color
    add esp, 16

    pop ebx
    pop ebp
    ret

; =====================================================
; menu_resume_boot
; Option 1: Tiếp tục boot bị ngắt
;
; SỬA: Thay cli+hlt bằng reload kernel
;      Nếu boot state không phải INTERRUPTED -> thông báo
; =====================================================
menu_resume_boot:
    push ebp
    mov ebp, esp

    movzx eax, byte [BOOT_STATE_ADDR]
    cmp eax, BOOT_STATE_INTERRUPTED
    jne .not_interrupted

    ; Hiện thông báo
    call clear_screen
    push dword COLOR_SUCCESS
    push dword str_resuming
    push dword 12
    push dword 15
    call print_string_at_color
    add esp, 16

    ; Đặt lại boot state
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_NORMAL

    ; Reload kernel với ngôn ngữ đã chọn trước đó
    ; (selected_language_global được lưu khi chọn ngôn ngữ)
    push dword [selected_language_global]
    call load_kernel_with_language  ; extern từ entry.asm
    add esp, 4
    ; Nếu kernel load fail, load_kernel_with_language trả về != 0
    test eax, eax
    jz .resume_ok   ; eax=0 nghĩa là kernel tự jump, không đến đây

    ; Load kernel thất bại -> thông báo và về menu
    push dword COLOR_WARNING
    push dword str_resume_fail
    push dword 14
    push dword 10
    call print_string_at_color
    add esp, 16
    call read_key_blocking
    jmp .done

.resume_ok:
    ; Không bao giờ đến đây nếu kernel đã jump
    jmp .done

.not_interrupted:
    push dword COLOR_WARNING
    push dword str_no_resume
    push dword 12
    push dword 10
    call print_string_at_color
    add esp, 16
    call read_key_blocking

.done:
    pop ebp
    ret

; =====================================================
; menu_enter_language
; Option 2: Chọn ngôn ngữ
; =====================================================
menu_enter_language:
    push ebp
    mov ebp, esp

    call show_boot_menu     ; eax = index ngôn ngữ
    mov [selected_language_global], eax

    call clear_screen
    push dword COLOR_SUCCESS
    push dword str_lang_saved
    push dword 12
    push dword 15
    call print_string_at_color
    add esp, 16

    ; Delay ~1 giây
    call pit_get_ticks
    add eax, 18
    mov [menu_temp_tick], eax
.wait:
    call pit_get_ticks
    cmp eax, [menu_temp_tick]
    jl .wait

    pop ebp
    ret

; =====================================================
; menu_enter_settings
; Option 3: Load SETTINGS.BIN và gọi settings_entry
; =====================================================
menu_enter_settings:
    push ebp
    mov ebp, esp

    call clear_screen
    push dword COLOR_MENU_KEY
    push dword str_loading_settings
    push dword 12
    push dword 20
    call print_string_at_color
    add esp, 16

    push dword 0x1000               ; max 4 KB
    push dword SETTINGS_BUF_ADDR
    push dword file_settings
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .load_error
    test eax, eax
    jz .load_error

    ; Gọi settings_entry(boot_drive)
    push dword [boot_drive_global]
    call SETTINGS_BUF_ADDR
    add esp, 4
    jmp .done

.load_error:
    push dword COLOR_WARNING
    push dword str_err_load_settings
    push dword 14
    push dword 10
    call print_string_at_color
    add esp, 16
    call read_key_blocking

.done:
    pop ebp
    ret

; =====================================================
; menu_enter_partition_editor
; Option 4: Load EDITING.BIN với xác nhận 2 bước
; =====================================================
menu_enter_partition_editor:
    push ebp
    mov ebp, esp

    ; Bước 1: Màn hình cảnh báo
    call draw_partition_warning_screen
    call read_key_blocking
    cmp eax, 0x01       ; ESC = hủy
    je .cancel
    cmp eax, 0x1C       ; ENTER = tiếp tục
    jne .cancel

    ; Bước 2: Gõ "YES"
    call draw_partition_confirm_screen
    push dword confirm_buf
    call read_string
    add esp, 4

    mov esi, confirm_buf
    mov edi, str_confirm_yes
    call strcmp
    test eax, eax
    jnz .cancel

    ; Load EDITING.BIN
    call clear_screen
    push dword COLOR_PARTITION_WARN
    push dword str_loading_editor
    push dword 12
    push dword 18
    call print_string_at_color
    add esp, 16

    push dword 0xF000               ; max 60 KB
    push dword EDITOR_BUF_ADDR
    push dword file_editing
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .load_error
    test eax, eax
    jz .load_error

    ; Gọi editor_entry(boot_drive, fat32_cache_addr)
    push dword FAT32_CACHE_ADDR
    push dword [boot_drive_global]
    call EDITOR_BUF_ADDR
    add esp, 8
    jmp .done

.cancel:
    push dword COLOR_SUCCESS
    push dword str_editor_cancelled
    push dword 20
    push dword 20
    call print_string_at_color
    add esp, 16
    call read_key_blocking
    jmp .done

.load_error:
    push dword COLOR_WARNING
    push dword str_err_load_editor
    push dword 18
    push dword 10
    call print_string_at_color
    add esp, 16
    call read_key_blocking

.done:
    pop ebp
    ret

; =====================================================
; draw_partition_warning_screen
; =====================================================
draw_partition_warning_screen:
    push ebp
    mov ebp, esp

    call clear_screen

    push dword COLOR_PARTITION_WARN
    push dword str_warn_header
    push dword 1
    push dword 0
    call print_string_at_color
    add esp, 16

    push dword COLOR_PARTITION_WARN
    push dword str_warn_header
    push dword 2
    push dword 0
    call print_string_at_color
    add esp, 16

    push dword COLOR_WARNING
    push dword str_warn_title
    push dword 4
    push dword 20
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_ITEM
    push dword str_warn_line1
    push dword 6
    push dword 4
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_ITEM
    push dword str_warn_line2
    push dword 7
    push dword 4
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_ITEM
    push dword str_warn_line3
    push dword 8
    push dword 4
    call print_string_at_color
    add esp, 16

    push dword COLOR_WARNING
    push dword str_warn_line4
    push dword 10
    push dword 4
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_KEY
    push dword str_warn_press_enter
    push dword 13
    push dword 10
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_DESC
    push dword str_warn_press_esc
    push dword 14
    push dword 10
    call print_string_at_color
    add esp, 16

    pop ebp
    ret

; =====================================================
; draw_partition_confirm_screen
;
; SỬA: Tính cursor position đúng thay vì
;      đọc từ cursor_pos_low/high chưa init
; =====================================================
draw_partition_confirm_screen:
    push ebp
    mov ebp, esp
    push edx

    call clear_screen

    push dword COLOR_WARNING
    push dword str_confirm_title
    push dword 10
    push dword 15
    call print_string_at_color
    add esp, 16

    push dword COLOR_MENU_ITEM
    push dword str_confirm_prompt
    push dword 12
    push dword 10
    call print_string_at_color
    add esp, 16

    ; Tính cursor position: row=12, col=59
    ; (10 + len("Type YES (uppercase) and press ENTER to proceed: ") = 10+49 = 59)
    ; Linear position = row * VGA_COLS + col = 12*80 + 59 = 1019
    mov eax, 12 * VGA_COLS + 59
    mov dx, 0x3D4
    out dx, al              ; Ghi low byte cursor pos
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, ah              ; Low byte của position
    ; Cần chia: high byte = pos >> 8, low byte = pos & 0xFF
    ; Làm lại đúng:
    dec dx
    mov al, 0x0E            ; Cursor position high register
    out dx, al
    inc dx
    mov eax, 12 * VGA_COLS + 59
    shr eax, 8
    out dx, al              ; High byte
    dec dx
    mov al, 0x0F            ; Cursor position low register
    out dx, al
    inc dx
    mov eax, 12 * VGA_COLS + 59
    and eax, 0xFF
    out dx, al              ; Low byte

    pop edx
    pop ebp
    ret

; =====================================================
; get_boot_state / set_boot_state
; =====================================================
get_boot_state:
    movzx eax, byte [BOOT_STATE_ADDR]
    ret

set_boot_state:
    mov eax, [esp + 4]
    mov byte [BOOT_STATE_ADDR], al
    ret

; =====================================================
; read_key_blocking
; Block đến khi có phím, return scan code
; Bỏ qua key-release events (bit 7 set)
; =====================================================
read_key_blocking:
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    movzx eax, al
    test eax, 0x80
    jnz .wait
    ret

; =====================================================
; read_string
; Đọc chuỗi có echo, tối đa 15 ký tự
; Input: [esp+4] = buffer ptr
; Dùng cho xác nhận "YES"
; =====================================================
read_string:
    push ebp
    mov ebp, esp
    push edi
    push ecx

    mov edi, [ebp + 8]
    xor ecx, ecx
    mov dword [rs_col], 59      ; Col bắt đầu nhập (sau prompt)
    mov dword [rs_row], 12

.read_loop:
    call read_key_blocking
    cmp eax, 0x1C               ; ENTER
    je .done
    cmp eax, 0x0E               ; BACKSPACE
    je .backspace
    cmp ecx, 15
    jge .read_loop

    push eax
    call scancode_to_ascii_upper
    test eax, eax
    jz .skip_char

    mov [edi + ecx], al
    inc ecx

    mov [rs_echo_char], al
    mov byte [rs_echo_char + 1], 0
    push dword COLOR_MENU_KEY
    push dword rs_echo_char
    push dword [rs_row]
    push dword [rs_col]
    call print_string_at_color
    add esp, 16
    inc dword [rs_col]
    jmp .read_loop

.skip_char:
    pop eax
    jmp .read_loop

.backspace:
    test ecx, ecx
    jz .read_loop
    dec ecx
    dec dword [rs_col]
    push dword COLOR_MENU_ITEM
    push dword str_space
    push dword [rs_row]
    push dword [rs_col]
    call print_string_at_color
    add esp, 16
    jmp .read_loop

.done:
    mov byte [edi + ecx], 0
    pop ecx
    pop edi
    pop ebp
    ret

; =====================================================
; strcmp
; Input: ESI = str1, EDI = str2
; Output: EAX = 0 nếu bằng nhau
; =====================================================
strcmp:
    push esi
    push edi
.loop:
    mov al, [esi]
    mov bl, [edi]
    cmp al, bl
    jne .not_equal
    test al, al
    jz .equal
    inc esi
    inc edi
    jmp .loop
.equal:
    xor eax, eax
    jmp .done
.not_equal:
    movzx eax, al
    movzx ebx, bl
    sub eax, ebx
.done:
    pop edi
    pop esi
    ret

; =====================================================
; scancode_to_ascii_upper
; Chuyển scan code -> ASCII uppercase (chỉ cần Y,E,S)
; Input: [esp+4] = scancode
; Output: EAX = ASCII, 0 nếu không map được
; =====================================================
scancode_to_ascii_upper:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]
    cmp eax, 0x15   ; Y
    je .y
    cmp eax, 0x12   ; E
    je .e
    cmp eax, 0x1F   ; S
    je .s
    xor eax, eax
    pop ebp
    ret
.y: mov eax, 'Y'
    jmp .done
.e: mov eax, 'E'
    jmp .done
.s: mov eax, 'S'
.done:
    pop ebp
    ret

; =====================================================
; SECTION DATA
; =====================================================
section .data align=4

boot_drive_global:          dd 0    ; global — entry.asm gán trước show_main_menu
selected_language_global:   dd 0
menu_temp_tick:             dd 0

file_settings:  db "SETTINGS.BIN", 0
file_editing:   db "EDITING.BIN", 0

; Header
str_header_title:   db "BTOS Bootloader v2.1 / Fannlaangtay Tsautzuoh shihtoong Yiindao jeatzay cherngshiuh ", 0
str_header_version: db "Build 2025 | Protected Mode 32-bit", 0
str_line_single:
    db "--------------------------------------------------------------------------------", 0

; Boot state
str_state_normal:
    db "Status: System initialized normally", 0
str_state_interrupted:
    db "Status: [!] Boot was interrupted - press 1 to resume", 0
str_state_settings:
    db "Status: Boot configuration mode", 0

; Menu items
str_item1_key:  db "[1]", 0
str_item1_name: db " Resume Boot", 0
str_item1_desc: db "    Continue the interrupted boot process", 0

str_item2_key:  db "[2]", 0
str_item2_name: db " Change Language", 0
str_item2_desc: db "    Select display language for OS Bootloader", 0

str_item3_key:  db "[3]", 0
str_item3_name: db " Boot Settings", 0
str_item3_desc: db "    Configure boot parameters and hardware options", 0

str_item4_key:  db "[4]", 0
str_item4_name: db " Partition Editor  [ADVANCED]", 0
str_item4_desc: db "    Direct intervention into bootloader partition", 0

str_footer_nav:
    db "[UP][DOWN] Navigate   [1-4] Direct select", 0
str_footer_select:
    db "[ENTER] Confirm   [F1] Interrupt boot (from boot screen)", 0

; Thông báo
str_resuming:       db "Resuming boot process...", 0
str_resume_fail:    db "[ERROR] Cannot reload kernel. Check disk.", 0
str_no_resume:
    db "[!] No interrupted boot session found. Nothing to resume.", 0
str_lang_saved:         db "Language selection saved.", 0
str_loading_settings:   db "Loading Boot Settings...", 0
str_loading_editor:     db "Loading Partition Editor...", 0
str_editor_cancelled:   db "Operation cancelled.", 0
str_err_load_settings:
    db "[ERROR] Cannot load SETTINGS.BIN from FAT32 partition.", 0
str_err_load_editor:
    db "[ERROR] Cannot load EDITING.BIN from FAT32 partition.", 0
str_space:  db " ", 0

; Partition editor warning
str_warn_header:
    db "================================================================================", 0
str_warn_title:
    db "!! DANGER: BOOTLOADER PARTITION EDITOR !!", 0
str_warn_line1:
    db "This tool allows DIRECT READ/WRITE access to the boot partition.", 0
str_warn_line2:
    db "Incorrect changes WILL corrupt your bootloader and prevent system boot.", 0
str_warn_line3:
    db "There is NO UNDO. Always backup your MBR before making changes.", 0
str_warn_line4:
    db "YOU HAVE BEEN WARNED. Proceed only if you know what you are doing.", 0
str_warn_press_enter:
    db "[ENTER] I understand the risks - Continue", 0
str_warn_press_esc:
    db "[ESC]   Cancel and return to menu", 0

str_confirm_title:  db "FINAL CONFIRMATION", 0
str_confirm_prompt:
    db "Type YES (uppercase) and press ENTER to proceed: ", 0
str_confirm_yes:    db "YES", 0

; =====================================================
; SECTION BSS
; =====================================================
section .bss align=4

confirm_buf:    resb 16
rs_col:         resd 1
rs_row:         resd 1
rs_echo_char:   resb 4
