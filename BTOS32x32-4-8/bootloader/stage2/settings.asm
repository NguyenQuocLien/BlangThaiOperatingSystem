; =====================================================
; stage2/settings.asm
; Module: Boot Settings
; Compile thành SETTINGS.BIN, load động bởi menu.asm
;
; CALLING CONVENTION (từ menu.asm):
;   push boot_drive
;   call SETTINGS_BUF_ADDR   (0x00040000)
;
; SETTINGS FILE FORMAT (SETTINGS.CFG, plain text):
;   KEY=VALUE\n
;   Ví dụ:
;     boot_timeout=10
;     default_lang=vi
;     vbe_mode=4118
;     boot_drive=80
;     debug_mode=0
;
; Layout trong file:
;   Mỗi entry: KEY\0VALUE\0 (null-separated pairs)
;   Hoặc dùng parser text đơn giản
; =====================================================

BITS 32

; =====================================================
; CONSTANTS
; =====================================================
SETTINGS_CFG_ADDR       equ 0x00055000  ; Buffer đọc SETTINGS.CFG
SETTINGS_CFG_MAX        equ 0x1000      ; 4 KB tối đa
SETTINGS_SAVE_ADDR      equ 0x00056000  ; Buffer ghi trước khi save
SETTINGS_ITEM_COUNT     equ 6
SETTINGS_MENU_START_ROW equ 4
SETTINGS_MENU_COL       equ 10

; Settings item indices
SETT_TIMEOUT        equ 0
SETT_DEF_LANG       equ 1
SETT_VBE_MODE       equ 2
SETT_BOOT_DRIVE     equ 3
SETT_DEBUG          equ 4
SETT_BOOT_DELAY     equ 5

; Giá trị default
DEFAULT_TIMEOUT     equ 10
DEFAULT_VBE_MODE    equ 0x4118
DEFAULT_DEBUG       equ 0
DEFAULT_DELAY       equ 0

; VGA colors (khai báo lại vì module độc lập)
VGA_TEXT_BASE       equ 0xB8000
VGA_COLS            equ 80
VGA_ROWS            equ 25
COLOR_NORMAL        equ 0x07
COLOR_HIGHLIGHT     equ 0x70
COLOR_TITLE         equ 0x0F
COLOR_KEY           equ 0x0E
COLOR_ERROR         equ 0x0C
COLOR_SUCCESS       equ 0x0A
COLOR_DESC          equ 0x08
COLOR_EDIT          equ 0x3F        ; Trắng sáng trên cyan (edit mode)

; =====================================================
; EXPORTS
; =====================================================
global settings_entry
global settings_load
global settings_save
global settings_get_value
global settings_set_value

; =====================================================
; IMPORTS (link với fat32.asm)
; =====================================================
extern fat32_load_file
extern fat32_write_file

; =====================================================
; SECTION TEXT
; =====================================================
section .text

; =====================================================
; settings_entry
; Entry point khi load từ menu.asm
;
; Stack: [esp+4] = boot_drive
; =====================================================
settings_entry:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx
    push esi
    push edi
    sub esp, 8              ; [ebp-4] = selected_item (0-based)
                            ; [ebp-8] = edit_mode flag

    mov eax, [ebp + 8]
    mov [boot_drive_s], eax

    ; Inicializar valores default
    call init_default_settings

    ; Cargar configuración
    call settings_load

    ; Estado inicial
    mov dword [ebp - 4], 0  ; selected = item 0
    mov dword [ebp - 8], 0  ; no edit mode

    ; Vẽ màn hình settings
    call draw_settings_screen

.settings_loop:
    ; Vẽ lại danh sách items
    push dword [ebp - 8]    ; edit_mode
    push dword [ebp - 4]    ; selected
    call draw_settings_items
    add esp, 8

    ; Đọc phím
    call read_key_blocking_s

    ; Kiểm tra edit mode
    cmp dword [ebp - 8], 1
    je .handle_edit_key

    ; --- Navigation mode ---
    cmp eax, 0x48           ; UP
    je .nav_up
    cmp eax, 0x50           ; DOWN
    je .nav_down
    cmp eax, 0x1C           ; ENTER = vào edit mode
    je .enter_edit
    cmp eax, 0x1F           ; S = Save
    je .do_save
    cmp eax, 0x01           ; ESC = thoát
    je .do_exit
    cmp eax, 0x13           ; R = Reset defaults
    je .do_reset
    jmp .settings_loop

.nav_up:
    mov eax, [ebp - 4]
    test eax, eax
    jz .wrap_bottom
    dec eax
    jmp .set_item

.wrap_bottom:
    mov eax, SETTINGS_ITEM_COUNT - 1
    jmp .set_item

.nav_down:
    mov eax, [ebp - 4]
    inc eax
    cmp eax, SETTINGS_ITEM_COUNT
    jl .set_item
    xor eax, eax

.set_item:
    mov [ebp - 4], eax
    jmp .settings_loop

.enter_edit:
    mov dword [ebp - 8], 1  ; Bật edit mode
    ; Lưu giá trị hiện tại vào edit_buffer để edit
    push dword [ebp - 4]
    call begin_edit_item
    add esp, 4
    jmp .settings_loop

.handle_edit_key:
    ; Trong edit mode: nhận input
    cmp eax, 0x01           ; ESC = hủy edit
    je .cancel_edit
    cmp eax, 0x1C           ; ENTER = xác nhận edit
    je .confirm_edit
    cmp eax, 0x0E           ; BACKSPACE
    je .edit_backspace

    ; Ký tự thường: append vào edit buffer
    push eax
    call scancode_to_ascii
    test eax, eax
    jz .settings_loop

    ; Append vào edit_input_buf
    mov edi, edit_input_buf
    mov ecx, [edit_input_len]
    cmp ecx, 15
    jge .settings_loop
    mov [edi + ecx], al
    inc dword [edit_input_len]
    jmp .settings_loop

.edit_backspace:
    mov ecx, [edit_input_len]
    test ecx, ecx
    jz .settings_loop
    dec dword [edit_input_len]
    jmp .settings_loop

.cancel_edit:
    mov dword [ebp - 8], 0
    jmp .settings_loop

.confirm_edit:
    ; Lưu giá trị từ edit_input_buf vào settings_values
    push dword [ebp - 4]
    call commit_edit_item
    add esp, 4
    mov dword [ebp - 8], 0
    jmp .settings_loop

.do_save:
    call settings_save
    test eax, eax
    jz .save_ok

    ; Lỗi save
    push dword COLOR_ERROR
    push dword str_save_error
    push dword 23
    push dword 5
    call print_string_at_color_s
    add esp, 16
    jmp .settings_loop

.save_ok:
    push dword COLOR_SUCCESS
    push dword str_save_ok
    push dword 23
    push dword 5
    call print_string_at_color_s
    add esp, 16
    jmp .settings_loop

.do_reset:
    call init_default_settings
    call draw_settings_screen
    jmp .settings_loop

.do_exit:
    ; Thoát về menu.asm
    add esp, 8
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret

; =====================================================
; init_default_settings
; Điền giá trị mặc định vào settings_values table
; =====================================================
init_default_settings:
    push edi
    push ecx

    ; settings_values[SETT_TIMEOUT] = "10"
    mov edi, settings_values + SETT_TIMEOUT * SVAL_SIZE
    mov esi, default_timeout_str
    call copy_sval

    mov edi, settings_values + SETT_DEF_LANG * SVAL_SIZE
    mov esi, default_lang_str
    call copy_sval

    mov edi, settings_values + SETT_VBE_MODE * SVAL_SIZE
    mov esi, default_vbe_str
    call copy_sval

    mov edi, settings_values + SETT_BOOT_DRIVE * SVAL_SIZE
    mov esi, default_drive_str
    call copy_sval

    mov edi, settings_values + SETT_DEBUG * SVAL_SIZE
    mov esi, default_debug_str
    call copy_sval

    mov edi, settings_values + SETT_BOOT_DELAY * SVAL_SIZE
    mov esi, default_delay_str
    call copy_sval

    pop ecx
    pop edi
    ret

copy_sval:
    push ecx
    mov ecx, SVAL_SIZE - 1
.loop:
    lodsb
    test al, al
    jz .done
    stosb
    dec ecx
    jnz .loop
.done:
    mov byte [edi], 0
    pop ecx
    ret

; =====================================================
; settings_load
; Đọc SETTINGS.CFG từ FAT32 và parse KEY=VALUE
; =====================================================
settings_load:
    push ebp
    mov ebp, esp
    push esi
    push edi

    ; Load file
    push dword SETTINGS_CFG_MAX
    push dword SETTINGS_CFG_ADDR
    push dword file_settings_cfg
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .load_fail
    test eax, eax
    jz .load_fail

    mov [cfg_file_size], eax

    ; Parse KEY=VALUE từng dòng
    mov esi, SETTINGS_CFG_ADDR
    mov ecx, [cfg_file_size]

.parse_line:
    test ecx, ecx
    jz .parse_done

    ; Bỏ qua comment và dòng trống
    mov al, [esi]
    cmp al, '#'
    je .skip_line
    cmp al, 0x0A
    je .next_line
    cmp al, 0x0D
    je .next_line
    cmp al, 0
    je .parse_done

    ; Tìm KEY (đến '=')
    mov edi, parse_key_buf
    xor ah, ah
.read_key:
    mov al, [esi]
    cmp al, '='
    je .key_done
    cmp al, 0x0A
    je .next_line
    cmp al, 0
    je .parse_done
    cmp ah, 31
    jge .skip_key_char
    stosb
    inc ah
.skip_key_char:
    inc esi
    dec ecx
    jmp .read_key
.key_done:
    mov byte [edi], 0
    inc esi
    dec ecx

    ; Tìm VALUE (đến '\n')
    mov edi, parse_val_buf
    xor ah, ah
.read_val:
    mov al, [esi]
    cmp al, 0x0A
    je .val_done
    cmp al, 0x0D
    je .val_done
    cmp al, 0
    je .val_done_eof
    cmp ah, SVAL_SIZE - 1
    jge .skip_val_char
    stosb
    inc ah
.skip_val_char:
    inc esi
    dec ecx
    jmp .read_val
.val_done:
    mov byte [edi], 0
    ; Map key -> settings_values entry
    push dword parse_val_buf
    push dword parse_key_buf
    call apply_setting
    add esp, 8
    jmp .next_line

.val_done_eof:
    mov byte [edi], 0
    push dword parse_val_buf
    push dword parse_key_buf
    call apply_setting
    add esp, 8
    jmp .parse_done

.next_line:
    ; Bỏ qua CRLF
.skip_crlf:
    cmp byte [esi], 0x0D
    jne .check_lf
    inc esi
    dec ecx
.check_lf:
    cmp byte [esi], 0x0A
    jne .parse_line
    inc esi
    dec ecx
    jmp .parse_line

.skip_line:
.sl_loop:
    cmp byte [esi], 0x0A
    je .next_line
    cmp byte [esi], 0
    je .parse_done
    inc esi
    dec ecx
    jmp .sl_loop

.parse_done:
    xor eax, eax
    jmp .done

.load_fail:
    ; Không tìm thấy file -> dùng default (đã set)
    xor eax, eax

.done:
    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; apply_setting
; Map key string -> settings_values slot
; Input: [esp+4]=key_ptr, [esp+8]=val_ptr
; =====================================================
apply_setting:
    push ebp
    mov ebp, esp
    push esi
    push edi

    mov esi, [ebp + 8]      ; key
    mov edi, key_timeout
    call strcmp_s
    test eax, eax
    jnz .try_lang
    ; Apply timeout
    mov edi, settings_values + SETT_TIMEOUT * SVAL_SIZE
    mov esi, [ebp + 12]
    call copy_sval
    jmp .done

.try_lang:
    mov esi, [ebp + 8]
    mov edi, key_lang
    call strcmp_s
    test eax, eax
    jnz .try_vbe
    mov edi, settings_values + SETT_DEF_LANG * SVAL_SIZE
    mov esi, [ebp + 12]
    call copy_sval
    jmp .done

.try_vbe:
    mov esi, [ebp + 8]
    mov edi, key_vbe
    call strcmp_s
    test eax, eax
    jnz .try_drive
    mov edi, settings_values + SETT_VBE_MODE * SVAL_SIZE
    mov esi, [ebp + 12]
    call copy_sval
    jmp .done

.try_drive:
    mov esi, [ebp + 8]
    mov edi, key_drive
    call strcmp_s
    test eax, eax
    jnz .try_debug
    mov edi, settings_values + SETT_BOOT_DRIVE * SVAL_SIZE
    mov esi, [ebp + 12]
    call copy_sval
    jmp .done

.try_debug:
    mov esi, [ebp + 8]
    mov edi, key_debug
    call strcmp_s
    test eax, eax
    jnz .try_delay
    mov edi, settings_values + SETT_DEBUG * SVAL_SIZE
    mov esi, [ebp + 12]
    call copy_sval
    jmp .done

.try_delay:
    mov esi, [ebp + 8]
    mov edi, key_delay
    call strcmp_s
    test eax, eax
    jnz .done
    mov edi, settings_values + SETT_BOOT_DELAY * SVAL_SIZE
    mov esi, [ebp + 12]
    call copy_sval

.done:
    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; settings_save
; Serialize settings_values -> KEY=VALUE text -> FAT32
; Output: EAX = 0 OK, -1 lỗi
; =====================================================
settings_save:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ecx

    mov edi, SETTINGS_SAVE_ADDR     ; Ghi vào buffer

    ; Viết header comment
    mov esi, save_header
.write_header:
    lodsb
    test al, al
    jz .write_items
    stosb
    jmp .write_header

.write_items:
    ; Lần lượt ghi từng KEY=VALUE\n
    push edi
    push dword settings_values + SETT_TIMEOUT * SVAL_SIZE
    push dword key_timeout
    call write_cfg_line
    add esp, 8
    mov edi, eax

    push edi
    push dword settings_values + SETT_DEF_LANG * SVAL_SIZE
    push dword key_lang
    call write_cfg_line
    add esp, 8
    mov edi, eax

    push edi
    push dword settings_values + SETT_VBE_MODE * SVAL_SIZE
    push dword key_vbe
    call write_cfg_line
    add esp, 8
    mov edi, eax

    push edi
    push dword settings_values + SETT_BOOT_DRIVE * SVAL_SIZE
    push dword key_drive
    call write_cfg_line
    add esp, 8
    mov edi, eax

    push edi
    push dword settings_values + SETT_DEBUG * SVAL_SIZE
    push dword key_debug
    call write_cfg_line
    add esp, 8
    mov edi, eax

    push edi
    push dword settings_values + SETT_BOOT_DELAY * SVAL_SIZE
    push dword key_delay
    call write_cfg_line
    add esp, 8
    mov edi, eax

    ; Tính số bytes đã ghi
    mov eax, edi
    sub eax, SETTINGS_SAVE_ADDR

    ; Ghi ra FAT32
    push eax                        ; size
    push dword SETTINGS_SAVE_ADDR
    push dword file_settings_cfg
    call fat32_write_file
    add esp, 12

    pop ecx
    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; write_cfg_line
; Ghi "KEY=VALUE\n" vào buffer
; Input:  [esp+4]=key_ptr, [esp+8]=val_ptr, [esp+12]=buf_ptr
; Output: EAX = con trỏ sau ký tự cuối
; =====================================================
write_cfg_line:
    push ebp
    mov ebp, esp
    push esi
    push edi

    mov edi, [ebp + 16]     ; buf_ptr
    mov esi, [ebp + 8]      ; key
.write_key:
    lodsb
    test al, al
    jz .key_done
    stosb
    jmp .write_key
.key_done:
    mov al, '='
    stosb
    mov esi, [ebp + 12]     ; val
.write_val:
    lodsb
    test al, al
    jz .val_done
    stosb
    jmp .write_val
.val_done:
    mov al, 0x0A            ; LF
    stosb
    mov eax, edi            ; Return pointer

    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; begin_edit_item / commit_edit_item
; =====================================================
begin_edit_item:
    push ebp
    mov ebp, esp

    mov eax, [ebp + 8]      ; item index
    ; Copy giá trị hiện tại vào edit_input_buf
    mov esi, settings_values
    mov ecx, SVAL_SIZE
    mul ecx
    add esi, eax
    mov edi, edit_input_buf
    mov ecx, SVAL_SIZE
    rep movsb
    ; Tính len
    mov edi, edit_input_buf
    xor ecx, ecx
.count:
    cmp byte [edi + ecx], 0
    je .counted
    inc ecx
    jmp .count
.counted:
    mov [edit_input_len], ecx

    pop ebp
    ret

commit_edit_item:
    push ebp
    mov ebp, esp

    mov eax, [ebp + 8]
    mov ecx, SVAL_SIZE
    mul ecx
    mov edi, settings_values
    add edi, eax
    mov esi, edit_input_buf
    mov ecx, SVAL_SIZE
    rep movsb
    ; Đảm bảo null-terminated
    mov byte [edi - 1], 0

    pop ebp
    ret

; =====================================================
; draw_settings_screen
; =====================================================
draw_settings_screen:
    push ebp
    mov ebp, esp

    call clear_screen_s

    ; Header
    push dword COLOR_TITLE
    push dword str_settings_title
    push dword 0
    push dword 18
    call print_string_at_color_s
    add esp, 16

    push dword COLOR_DESC
    push dword str_settings_sub
    push dword 1
    push dword 10
    call print_string_at_color_s
    add esp, 16

    push dword COLOR_TITLE
    push dword str_line_s
    push dword 2
    push dword 0
    call print_string_at_color_s
    add esp, 16

    ; Header cột
    push dword COLOR_KEY
    push dword str_col_header
    push dword 3
    push dword SETTINGS_MENU_COL
    call print_string_at_color_s
    add esp, 16

    ; Footer
    push dword COLOR_TITLE
    push dword str_line_s
    push dword 21
    push dword 0
    call print_string_at_color_s
    add esp, 16

    push dword COLOR_DESC
    push dword str_sett_help1
    push dword 22
    push dword 2
    call print_string_at_color_s
    add esp, 16

    push dword COLOR_DESC
    push dword str_sett_help2
    push dword 23
    push dword 2
    call print_string_at_color_s
    add esp, 16

    pop ebp
    ret

; =====================================================
; draw_settings_items
; Input: [esp+4]=selected, [esp+8]=edit_mode
; =====================================================
draw_settings_items:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push esi
    push edi

    mov ebx, [ebp + 8]      ; selected
    mov ecx, [ebp + 12]     ; edit_mode

    ; Vẽ 6 items
    xor edi, edi            ; current item index

.draw_loop:
    cmp edi, SETTINGS_ITEM_COUNT
    jge .done

    ; Tính row
    mov eax, edi
    add eax, SETTINGS_MENU_START_ROW

    ; Chọn màu
    mov esi, COLOR_NORMAL
    cmp edi, ebx
    jne .not_selected
    ; Selected item
    test ecx, ecx
    jnz .edit_color
    mov esi, COLOR_HIGHLIGHT
    jmp .not_selected
.edit_color:
    mov esi, COLOR_EDIT

.not_selected:
    ; Lấy label
    mov edx, edi
    shl edx, 2
    mov edx, [settings_labels + edx]   ; ptr to label string

    ; Lấy value
    push edi
    call get_display_value
    add esp, 4              ; eax = ptr to value string

    ; In label (col 10)
    push esi                ; color
    push edx                ; label ptr
    push eax                ; <- không, label first
    ; Re-order: print label then value
    push esi
    push edx
    push eax                ; row
    push dword SETTINGS_MENU_COL
    ; Sai logic, simplify:
    add esp, 12

    ; Ghi label
    push esi
    push edx
    push eax                ; row (từ edi + 4)
    mov eax, edi
    add eax, SETTINGS_MENU_START_ROW
    push eax
    push dword SETTINGS_MENU_COL
    call print_string_at_color_s
    add esp, 16

    ; Ghi value (col 45)
    push esi
    ; Nếu đang edit item này, hiện edit_input_buf
    cmp edi, ebx
    jne .show_stored_val
    test ecx, ecx
    jz .show_stored_val
    push dword edit_input_buf
    jmp .print_val
.show_stored_val:
    push edi
    call get_display_value
    add esp, 4
    push eax
.print_val:
    mov eax, edi
    add eax, SETTINGS_MENU_START_ROW
    push eax
    push dword 45
    call print_string_at_color_s
    add esp, 16

    inc edi
    jmp .draw_loop

.done:
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop ebp
    ret

; =====================================================
; get_display_value
; Input: [esp+4] = item index
; Output: EAX = ptr to value string
; =====================================================
get_display_value:
    mov eax, [esp + 4]
    mov ecx, SVAL_SIZE
    mul ecx
    add eax, settings_values
    ret

; settings_get_value / settings_set_value (public API)
settings_get_value:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]      ; index
    cmp eax, SETTINGS_ITEM_COUNT
    jge .invalid
    mov ecx, SVAL_SIZE
    mul ecx
    add eax, settings_values
    pop ebp
    ret
.invalid:
    xor eax, eax
    pop ebp
    ret

settings_set_value:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]      ; index
    cmp eax, SETTINGS_ITEM_COUNT
    jge .invalid
    mov ecx, SVAL_SIZE
    mul ecx
    mov edi, settings_values
    add edi, eax
    mov esi, [ebp + 12]     ; value ptr
    mov ecx, SVAL_SIZE - 1
    call copy_sval
.invalid:
    pop ebp
    ret

; =====================================================
; HELPERS (standalone copies cho module độc lập)
; =====================================================
clear_screen_s:
    push edi
    push ecx
    push eax
    mov edi, VGA_TEXT_BASE
    mov ecx, VGA_COLS * VGA_ROWS
    mov ax, 0x0720
    rep stosw
    pop eax
    pop ecx
    pop edi
    ret

print_string_at_color_s:
    push ebp
    mov ebp, esp
    push esi
    push edi
    mov eax, [ebp + 12]
    mov ecx, VGA_COLS
    mul ecx
    add eax, [ebp + 8]
    shl eax, 1
    add eax, VGA_TEXT_BASE
    mov edi, eax
    mov esi, [ebp + 16]
    mov ah, [ebp + 20]
.loop:
    lodsb
    test al, al
    jz .done
    mov [edi], ax
    add edi, 2
    jmp .loop
.done:
    pop edi
    pop esi
    pop ebp
    ret

read_key_blocking_s:
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    movzx eax, al
    test eax, 0x80
    jnz .wait
    ret

strcmp_s:
.loop:
    mov al, [esi]
    mov bl, [edi]
    cmp al, bl
    jne .neq
    test al, al
    jz .eq
    inc esi
    inc edi
    jmp .loop
.eq:
    xor eax, eax
    ret
.neq:
    movzx eax, al
    movzx ebx, bl
    sub eax, ebx
    ret

scancode_to_ascii:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]
    ; Bảng đơn giản (US QWERTY, không shift)
    cmp eax, 0x02
    jl .nomap
    cmp eax, 0x0B
    jle .digits
    ; Thêm letters nếu cần
    xor eax, eax
    pop ebp
    ret
.digits:
    ; scancode 0x02='1' ... 0x0A='9', 0x0B='0'
    sub eax, 0x02
    cmp eax, 9
    jle .is_digit
    ; 0x0B -> '0'
    mov eax, '0'
    pop ebp
    ret
.is_digit:
    add eax, '1'
    pop ebp
    ret
.nomap:
    xor eax, eax
    pop ebp
    ret

; =====================================================
; SECTION DATA
; =====================================================
section .data align=4

SVAL_SIZE               equ 16          ; Max length của value string

boot_drive_s:           dd 0
cfg_file_size:          dd 0
edit_input_len:         dd 0

file_settings_cfg:      db "SETTINGS.CFG", 0

; Default values
default_timeout_str:    db "10", 0
default_lang_str:       db "vi", 0
default_vbe_str:        db "4118", 0
default_drive_str:      db "80", 0
default_debug_str:      db "0", 0
default_delay_str:      db "0", 0

; Config keys
key_timeout:    db "boot_timeout", 0
key_lang:       db "default_lang", 0
key_vbe:        db "vbe_mode", 0
key_drive:      db "boot_drive", 0
key_debug:      db "debug_mode", 0
key_delay:      db "boot_delay", 0

; Labels hiển thị
str_label_timeout:  db "Boot Timeout (seconds)", 0
str_label_lang:     db "Default Language", 0
str_label_vbe:      db "VBE Video Mode (hex)", 0
str_label_drive:    db "Boot Drive (hex)", 0
str_label_debug:    db "Debug Mode (0/1)", 0
str_label_delay:    db "Boot Delay (seconds)", 0

; Pointer table
settings_labels:
    dd str_label_timeout
    dd str_label_lang
    dd str_label_vbe
    dd str_label_drive
    dd str_label_debug
    dd str_label_delay

; UI strings
str_settings_title: db "BTOS Boot Settings", 0
str_settings_sub:   db "Changes take effect on next boot", 0
str_line_s:         db "--------------------------------------------------------------------------------", 0
str_col_header:     db "Setting Name                           Value", 0
str_sett_help1:     db "[UP][DOWN] Navigate  [ENTER] Edit  [S] Save  [R] Reset defaults  [ESC] Back", 0
str_sett_help2:     db "While editing: type value, [ENTER] confirm, [ESC] cancel, [BACKSPACE] delete", 0
str_save_ok:        db "Settings saved to SETTINGS.CFG successfully.", 0
str_save_error:     db "[ERROR] Failed to write SETTINGS.CFG to disk.", 0

save_header:
    db "# BTOS Boot Settings", 0x0A
    db "# Generated by BTOS Settings Module", 0x0A
    db "# Edit with caution", 0x0A
    db 0

; =====================================================
; SECTION BSS
; =====================================================
section .bss align=4

settings_values:    resb SVAL_SIZE * SETTINGS_ITEM_COUNT
edit_input_buf:     resb 16
parse_key_buf:      resb 32
parse_val_buf:      resb 16
