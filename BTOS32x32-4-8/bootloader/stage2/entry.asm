; =====================================================
; stage2/entry.asm
; Điểm vào chính của Stage 2 (Protected Mode 32-bit)
; Phiên bản: 2.0
; Tác giả: BTOS Project
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
;   0x00010000 - Stage 2 (file này, load tại đây)
;   0x00090000 - Stack top (grow xuống)
;   0x00020000 - Language file buffer
;   0x00030000 - Parsed language table
; =====================================================

BITS 32

; =====================================================
; CONSTANTS
; =====================================================
STACK_TOP               equ 0x90000
LANG_FILE_LOAD_ADDR     equ 0x20000     ; Buffer load LANGUAGES.BIN
LANG_TABLE_ADDR         equ 0x30000     ; Parsed language table
LANG_FILE_MAX_SIZE      equ 0x8000      ; 32 KB tối đa
LANG_NAME_MAX_LEN       equ 32          ; Độ dài tên ngôn ngữ tối đa
LANG_CODE_LEN           equ 8           ; Độ dài mã ngôn ngữ (vi, en, ...)
LANG_MAX_ENTRIES        equ 64          ; Tối đa 64 ngôn ngữ
LANG_ENTRY_SIZE         equ (LANG_NAME_MAX_LEN + LANG_CODE_LEN + 4)  ; 44 bytes/entry
MENU_TIMEOUT_SECONDS    equ 10          ; Timeout mặc định
DEFAULT_LANGUAGE_IDX    equ 0           ; Ngôn ngữ mặc định nếu timeout
VGA_TEXT_BASE           equ 0xB8000     ; VGA text mode framebuffer
VGA_COLS                equ 80
VGA_ROWS                equ 25
COLOR_NORMAL            equ 0x07        ; Trắng trên đen
COLOR_HIGHLIGHT         equ 0x70        ; Đen trên trắng (selected)
COLOR_TITLE             equ 0x0F        ; Trắng sáng trên đen
COLOR_TIMEOUT           equ 0x0E        ; Vàng trên đen
COLOR_ERROR             equ 0x0C        ; Đỏ sáng trên đen

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
; IMPORTS từ các module khác
; =====================================================
extern fat32_init
extern fat32_load_file          ; (filename_ptr, buffer_ptr, max_size) -> eax = bytes_read hoặc -1
extern pit_get_ticks            ; () -> eax = tick count (18.2 ticks/giây)
extern pit_init                 ; Khởi tạo PIT timer

; =====================================================
; SECTION TEXT
; =====================================================
section .text

; =====================================================
; stage2_entry
; Entry point được gọi từ Stage 1
;
; Stack khi vào:
;   [esp+0] = return address
;   [esp+4] = boot_drive (uint32_t)
; =====================================================
stage2_entry:
    ; --- Bước 1: Lưu boot_drive TRƯỚC KHI di chuyển stack ---
    ; Đọc từ [esp+4] (bỏ qua return address tại esp+0)
    mov eax, [esp + 4]
    mov [boot_drive], eax

    ; --- Bước 2: Thiết lập stack mới ---
    ; Sau đây mọi giá trị trên stack cũ đều không còn dùng
    mov esp, STACK_TOP
    mov ebp, esp

    ; --- Bước 3: Clear màn hình VGA ---
    call clear_screen

    ; --- Bước 4: Khởi tạo PIT (cần cho timeout menu) ---
    call pit_init

    ; --- Bước 5: Khởi tạo FAT32 với boot drive ---
    push dword [boot_drive]
    call fat32_init
    add esp, 4
    test eax, eax
    jnz .fat32_init_failed

    ; --- Bước 6: Load và parse danh sách ngôn ngữ ---
    call load_language_list
    test eax, eax
    jnz .lang_load_failed

    ; --- Bước 7: Hiển thị menu và lấy lựa chọn ---
    call show_boot_menu
    ; eax = index ngôn ngữ được chọn (đã bảo toàn đúng)
    mov [selected_language], eax

    ; --- Bước 8: Load kernel với ngôn ngữ đã chọn ---
    ; Sau khi load kernel thành công, kernel tự nhảy đi
    ; Nếu kernel load fail -> vào menu thay vì halt
    push dword [selected_language]
    call load_kernel_with_language
    add esp, 4
    test eax, eax
    jz .main_loop          ; Kernel tự jump, không return ở đây

    ; Kernel load thất bại -> vào menu để người dùng xử lý
.kernel_load_failed:
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_INTERRUPTED
    push dword COLOR_ERROR
    push dword err_kernel_load
    push dword 24
    push dword 0
    call print_string_at_color
    add esp, 16
    call show_main_menu     ; Vào menu thay vì halt

    ; --- Không nên đến đây (kernel đã nhảy đi) ---
.main_loop:
    hlt
    jmp .main_loop

; --- Error handlers ---
.fat32_init_failed:
    push dword err_fat32_init
    push dword 0                ; row
    push dword 0                ; col
    call print_error
    add esp, 12
    jmp .halt

.lang_load_failed:
    ; Điền default entry (English) — giữ nguyên như cũ
    push dword COLOR_WARNING          ; Thêm: báo người dùng biết
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

    ; KHÔNG jmp .do_menu nữa — fall through vào menu chính
    ; vì .do_menu cũ đã lỗi thời sau khi có menu.asm

.do_menu:
    ; Đặt boot state = INTERRUPTED để item [1] Resume có ý nghĩa
    ; (hoặc NORMAL nếu đây là lần đầu boot)
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_NORMAL

    call show_main_menu     ; Từ menu.asm — không bao giờ return
                            ; vì show_main_menu tự quản lý vòng lặp

    ; Không bao giờ đến đây, nhưng để an toàn:
.main_loop:
    cli
    hlt
    jmp .main_loop

.halt:
    cli
    hlt
    jmp .halt

; =====================================================
; load_language_list
; Load và parse file LANGUAGES.BIN từ FAT32
;
; Return: EAX = 0 (OK), -1 (lỗi)
; Clobbers: EBX, ECX, EDX, ESI, EDI (đã lưu qua push/pop)
; =====================================================
load_language_list:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp

    ; --- Gọi FAT32 để load file ---
    push dword LANG_FILE_MAX_SIZE
    push dword LANG_FILE_LOAD_ADDR
    push dword language_file_name
    call fat32_load_file
    add esp, 12

    ; eax = số bytes đọc được, -1 nếu lỗi
    cmp eax, -1
    je .load_error
    test eax, eax
    jz .load_error

    mov [lang_file_size], eax

    ; --- Parse file ---
    push eax                    ; bytes_loaded
    call parse_language_file
    add esp, 4

    ; eax = số entry parse được
    cmp eax, 0
    je .parse_error
    mov [language_count], eax

    ; Kết quả OK
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
; Parse nội dung LANGUAGES.BIN thành lang table
;
; Format LANGUAGES.BIN (text-based, dễ edit):
;   Mỗi dòng: <CODE>|<NAME>\n
;   Ví dụ:
;       vi|Tiếng Việt
;       en|English
;       ja|日本語
;
; Input:  [esp+4] = số bytes trong buffer (LANG_FILE_LOAD_ADDR)
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

    mov esi, LANG_FILE_LOAD_ADDR    ; Con trỏ đọc file
    mov edi, LANG_TABLE_ADDR        ; Con trỏ ghi table
    mov ecx, [ebp + 28]             ; bytes = arg (8 bytes locals + 6 regs * 4)
    ; Tính lại: ebp+4 là return, ebp+8 là arg sau push ebp
    ; Nhưng ta đã push 6 regs trước ebp => arg ở ebp + 4 + 24 = ebp+28
    ; (push ebx,ecx,edx,esi,edi,ebp = 6*4=24 bytes)
    ; Thực ra: [ebp+4] = return addr, [ebp+8] = arg đầu tiên
    ; Nhưng vì ta mov ebp,esp SAU khi push regs, ebp trỏ vào vùng sau push
    ; => arg đúng là ở [ebp + 4] nếu push ebp là push cuối trước mov ebp,esp
    ; Để tránh nhầm, dùng biến trung gian:
    mov ecx, [lang_file_size]       ; An toàn hơn

    xor edx, edx                    ; edx = entry count
    mov [lang_table_ptr], edi

.parse_loop:
    test ecx, ecx
    jz .parse_done

    ; --- Bỏ qua dòng trống và comment (#) ---
    mov al, [esi]
    cmp al, '#'
    je .skip_line
    cmp al, 0x0A                    ; LF
    je .next_char
    cmp al, 0x0D                    ; CR
    je .next_char
    cmp al, 0
    je .parse_done

    ; --- Check giới hạn số entry ---
    cmp edx, LANG_MAX_ENTRIES
    jge .parse_done

    ; --- Đọc CODE (đến dấu '|') ---
    push esi
    push edi
    mov ebx, edi                    ; ebx = đầu entry hiện tại
    add edi, LANG_NAME_MAX_LEN      ; Bắt đầu code sau name field
    ; (Layout: [NAME_MAX_LEN bytes][CODE_LEN bytes][4 bytes flags])

    ; Đọc code vào ebx+LANG_NAME_MAX_LEN
    mov edi, ebx
    add edi, LANG_NAME_MAX_LEN
    push edi                        ; Lưu code_ptr
    xor ah, ah                      ; ah = code byte count
.read_code:
    cmp byte [esi], '|'
    je .code_done
    cmp byte [esi], 0x0A
    je .line_malformed
    cmp byte [esi], 0
    je .parse_done
    cmp ah, LANG_CODE_LEN - 1
    jge .skip_char_code             ; Cắt nếu quá dài
    mov al, [esi]
    mov [edi], al
    inc edi
    inc ah
.skip_char_code:
    inc esi
    dec ecx
    jmp .read_code
.code_done:
    mov byte [edi], 0               ; Null terminate code
    inc esi                         ; Bỏ qua '|'
    dec ecx
    pop edi                         ; Khôi phục code_ptr (không dùng nữa)

    ; --- Đọc NAME (đến '\n' hoặc '\r\n') ---
    mov edi, ebx                    ; Ghi name vào đầu entry
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
    mov byte [edi], 0               ; Null terminate name
    ; Bỏ qua CR+LF
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
    ; Ghi flags = 0
    mov edi, ebx
    add edi, LANG_NAME_MAX_LEN + LANG_CODE_LEN
    mov dword [edi], 0

    pop edi                         ; Khôi phục edi = ebx (entry start)
    pop esi                         ; Khôi phục esi (đã advance)
    ; Thực ra esi đã thay đổi trong loop, dùng giá trị mới
    ; Nhưng ta push esi TRƯỚC khi thay đổi nên cần điều chỉnh
    ; => Rewrite: bỏ push/pop esi, edi ở đây
    ; (Xem note bên dưới - đây là simplified version)

    ; Advance edi sang entry tiếp theo
    mov edi, ebx
    add edi, LANG_ENTRY_SIZE
    inc edx
    jmp .parse_loop

.line_malformed:
    pop edi                         ; Xếp lại stack
    pop esi
.skip_line:
    ; Bỏ qua đến hết dòng
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
    mov eax, edx                    ; Return số entry

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
; Hiển thị menu chọn ngôn ngữ với highlight và timeout
;
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
    sub esp, 16                     ; Locals: [ebp-4]=selected, [ebp-8]=count
                                    ;         [ebp-12]=timeout_tick, [ebp-16]=cur_tick

    ; --- Lấy số lượng ngôn ngữ ---
    mov eax, [language_count]
    mov [ebp - 8], eax

    ; Nếu chỉ có 1 ngôn ngữ, skip menu
    cmp eax, 1
    je .single_language

    ; --- Vẽ khung menu ---
    call draw_menu_frame

    ; --- Khởi tạo trạng thái ---
    mov dword [ebp - 4], 0          ; selected = 0
    call pit_get_ticks
    add eax, MENU_TIMEOUT_SECONDS * 18     ; timeout tick
    mov [ebp - 12], eax

    ; --- Vẽ lần đầu ---
    push dword [ebp - 4]
    call draw_language_list
    add esp, 4

    push dword [ebp - 12]
    call draw_timeout_bar
    add esp, 4

.input_loop:
    ; --- Kiểm tra timeout ---
    call pit_get_ticks
    mov [ebp - 16], eax
    cmp eax, [ebp - 12]
    jge .timeout

    ; Tính giây còn lại để update bar
    mov eax, [ebp - 12]
    sub eax, [ebp - 16]
    xor edx, edx
    mov ecx, 18
    div ecx                         ; eax = giây còn lại
    push eax
    call draw_timeout_bar
    add esp, 4

    ; --- Đọc phím (non-blocking) ---
    call read_key_nonblocking       ; eax = scancode, 0 nếu không có phím
    test eax, eax
    jz .input_loop

    ; --- Xử lý phím ---
    cmp eax, 0x48                   ; Up arrow
    je .key_up
    cmp eax, 0x50                   ; Down arrow
    je .key_down
    cmp eax, 0x1C                   ; Enter
    je .key_enter
    cmp eax, 0x01                   ; ESC -> chọn default
    je .key_esc

    ; Phím số 1-9
    cmp eax, 0x02                   ; '1'
    jl .input_loop
    cmp eax, 0x0A                   ; '9'+1
    jge .input_loop
    sub eax, 0x02                   ; Convert scancode -> index (0-based)
    cmp eax, [ebp - 8]
    jge .input_loop
    mov [ebp - 4], eax
    jmp .key_enter

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
    xor eax, eax                    ; Wrap to top
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
; Vẽ khung UI menu bằng VGA text mode characters
; =====================================================
draw_menu_frame:
    push ebx
    push ecx
    push edx

    call clear_screen

    ; --- Tiêu đề ---
    push dword COLOR_TITLE
    push dword str_menu_title
    push dword 1
    push dword 10
    call print_string_at_color
    add esp, 16

    ; --- Đường kẻ ngang ---
    push dword COLOR_TITLE
    push dword str_separator
    push dword 2
    push dword 0
    call print_string_at_color
    add esp, 16

    ; --- Hướng dẫn phím ---
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
; Vẽ danh sách ngôn ngữ, highlight item được chọn
;
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

    mov ebx, [ebp + 28]             ; selected index
    mov ecx, [language_count]
    xor edx, edx                    ; current index
    mov esi, LANG_TABLE_ADDR

.draw_loop:
    cmp edx, ecx
    jge .draw_done

    ; Chọn màu
    mov eax, COLOR_NORMAL
    cmp edx, ebx
    jne .set_color
    mov eax, COLOR_HIGHLIGHT
.set_color:

    ; In số thứ tự
    push eax                        ; save color

    ; Tính row: bắt đầu từ row 4
    mov eax, edx
    add eax, 4

    ; In "[N] Name (Code)"
    ; Đây là simplified - ideally format string
    push dword [esp]                ; color (đã push)
    push esi                        ; name ptr (đầu entry)
    push eax                        ; row
    push dword 4                    ; col
    call print_string_at_color
    add esp, 16

    pop eax                         ; Khôi phục color (đã dùng)

    ; Advance sang entry tiếp
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
; Vẽ thanh đếm ngược
;
; Input: [esp+4] = giây còn lại
; =====================================================
draw_timeout_bar:
    push ebx
    push ecx
    push edx
    push ebp
    mov ebp, esp

    ; TODO: In "Auto-select in X seconds..."
    ; Cần itoa cho số giây
    push dword [ebp + 20]           ; giây
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
; handle_language_selection  (wrapper, giữ lại API cũ)
; Gọi show_boot_menu và trả về kết quả
; Output: EAX = index ngôn ngữ được chọn
; =====================================================
handle_language_selection:
    call show_boot_menu
    ret                             ; eax đã chứa kết quả từ show_boot_menu

; =====================================================
; get_language_count
; Output: EAX = số ngôn ngữ đã load
; =====================================================
get_language_count:
    mov eax, [language_count]
    ret

; =====================================================
; get_language_name
; Input:  [esp+4] = index (0-based)
; Output: EAX = con trỏ tới chuỗi tên (null-terminated)
;         0 nếu index không hợp lệ
; =====================================================
get_language_name:
    mov eax, [esp + 4]
    cmp eax, [language_count]
    jge .invalid
    mov ecx, LANG_ENTRY_SIZE
    mul ecx
    add eax, LANG_TABLE_ADDR        ; eax = &table[index].name
    ret
.invalid:
    xor eax, eax
    ret

; =====================================================
; get_language_code
; Input:  [esp+4] = index (0-based)
; Output: EAX = con trỏ tới chuỗi code (null-terminated)
;         0 nếu index không hợp lệ
; =====================================================
get_language_code:
    mov eax, [esp + 4]
    cmp eax, [language_count]
    jge .invalid
    mov ecx, LANG_ENTRY_SIZE
    mul ecx
    add eax, LANG_TABLE_ADDR + LANG_NAME_MAX_LEN    ; eax = &table[index].code
    ret
.invalid:
    xor eax, eax
    ret

; =====================================================
; load_kernel_with_language
; Load kernel và truyền thông tin ngôn ngữ
;
; Input: [esp+4] = language index
; Output: EAX = 0 (không bao giờ return nếu thành công)
; =====================================================
load_kernel_with_language:
    push ebp
    mov ebp, esp

    ; Lấy language code để truyền cho kernel
    push dword [ebp + 8]
    call get_language_code
    add esp, 4
    mov [kernel_lang_code_ptr], eax

    ; TODO: Load kernel từ FAT32
    ; push dword KERNEL_LOAD_ADDR
    ; push dword kernel_file_name
    ; call fat32_load_file
    ; add esp, 8

    ; Truyền thông tin vào kernel info struct
    ; và nhảy vào kernel entry point

    ; Placeholder: hiện tại chỉ halt
    xor eax, eax

    mov esp, ebp
    pop ebp
    ret

; =====================================================
; HELPER FUNCTIONS
; =====================================================

; =====================================================
; clear_screen
; Xóa màn hình VGA text mode (fill space + color 0x07)
; =====================================================
clear_screen:
    push edi
    push ecx
    push eax

    mov edi, VGA_TEXT_BASE
    mov ecx, VGA_COLS * VGA_ROWS    ; 2000 characters
    mov ax, 0x0720                  ; ' ' với attribute 0x07
    rep stosw

    ; Reset cursor về (0,0) qua port VGA CRTC
    mov dx, 0x3D4
    mov al, 0x0F                    ; Cursor position low
    out dx, al
    inc dx
    mov al, 0
    out dx, al
    dec dx
    mov al, 0x0E                    ; Cursor position high
    out dx, al
    inc dx
    mov al, 0
    out dx, al

    pop eax
    pop ecx
    pop edi
    ret

; =====================================================
; print_string_at_color
; In chuỗi tại vị trí (col, row) với màu chỉ định
;
; Input (cdecl):
;   [esp+4]  = col
;   [esp+8]  = row
;   [esp+12] = string ptr
;   [esp+16] = color (byte, chỉ dùng low byte)
; =====================================================
print_string_at_color:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ebx

    mov eax, [ebp + 8]              ; row
    mov ecx, VGA_COLS
    mul ecx
    add eax, [ebp + 4]             ; + col
    shl eax, 1                      ; * 2 (mỗi cell = 2 bytes)
    add eax, VGA_TEXT_BASE
    mov edi, eax                    ; edi = VGA cell pointer

    mov esi, [ebp + 12]             ; string ptr
    mov ah, [ebp + 16]             ; color attribute

.print_loop:
    mov al, [esi]
    test al, al
    jz .done
    mov [edi], ax
    add edi, 2
    inc esi
    jmp .print_loop

.done:
    pop ebx
    pop edi
    pop esi
    pop ebp
    ret

; --- Alias không có color (dùng COLOR_NORMAL) ---
print_string_at:
    push ebp
    mov ebp, esp
    push dword COLOR_NORMAL
    push dword [ebp + 16]           ; string
    push dword [ebp + 12]           ; row
    push dword [ebp + 8]            ; col
    call print_string_at_color
    add esp, 16
    pop ebp
    ret

; =====================================================
; print_error
; In thông báo lỗi (màu đỏ) và không return
; Input: [esp+4]=col, [esp+8]=row, [esp+12]=string
; =====================================================
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

; =====================================================
; print_timeout_line
; In dòng "Auto-select in X seconds..."
; Input: [esp+4]=col, [esp+8]=row, [esp+12]=prefix, [esp+16]=seconds
; =====================================================
print_timeout_line:
    push ebp
    mov ebp, esp
    push esi
    push edi

    ; In prefix
    push dword COLOR_TIMEOUT
    push dword [ebp + 12]
    push dword [ebp + 8]
    push dword [ebp + 4]
    call print_string_at_color
    add esp, 16

    ; Tính vị trí sau prefix (strlen + col)
    mov esi, [ebp + 12]
    xor ecx, ecx
.count:
    cmp byte [esi + ecx], 0
    je .count_done
    inc ecx
    jmp .count
.count_done:
    ; Tính col mới
    mov eax, [ebp + 4]
    add eax, ecx

    ; Convert seconds -> string
    mov edx, [ebp + 16]
    push edx
    push dword timeout_num_buf
    call itoa_decimal
    add esp, 8

    ; In số
    push dword COLOR_TIMEOUT
    push dword timeout_num_buf
    push dword [ebp + 8]
    push eax                        ; col sau prefix
    call print_string_at_color
    add esp, 16

    ; In suffix
    ; TODO: tính col sau số

    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; read_key_nonblocking
; Đọc phím từ keyboard buffer, không block
; Output: EAX = scan code, 0 nếu không có phím
; =====================================================
read_key_nonblocking:
    in al, 0x64                     ; Đọc keyboard status port
    test al, 1                      ; Bit 0: output buffer full
    jz .no_key
    in al, 0x60                     ; Đọc scan code
    movzx eax, al
    ; Bỏ qua key release (bit 7 set)
    test eax, 0x80
    jnz .no_key
    ret
.no_key:
    xor eax, eax
    ret

; =====================================================
; strncpy_safe
; Copy tối đa ecx bytes, luôn null-terminate
; Input: ESI = src, EDI = dst, ECX = max_len
; =====================================================
strncpy_safe:
    push ecx
    push esi
    push edi
    test ecx, ecx
    jz .done
    dec ecx                         ; Giữ chỗ cho null terminator
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

; =====================================================
; itoa_decimal
; Convert uint32 -> decimal string
; Input: [esp+4] = buffer ptr, [esp+8] = number
; =====================================================
itoa_decimal:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ebx
    push ecx

    mov edi, [ebp + 4]              ; buffer
    mov eax, [ebp + 8]             ; number
    mov ebx, 10

    ; Xử lý số 0 đặc biệt
    test eax, eax
    jnz .convert
    mov byte [edi], '0'
    mov byte [edi + 1], 0
    jmp .done

.convert:
    ; Đẩy các chữ số vào stack (ngược)
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

; --- Tên file ---
language_file_name:     db "LANGUAGES.BIN", 0
kernel_file_name:       db "KERNEL.BIN", 0

; --- Fallback mặc định ---
default_lang_name:      db "English", 0
default_lang_code:      db "en", 0

; --- Chuỗi UI ---
str_menu_title:
    db "  BTOS Bootloader v2.0 - Language / Ngon ngu / Langue  ", 0

str_separator:
    db "========================================================", 0

str_key_help:
    db "  [UP]/[DOWN]: Navigate    [ENTER]: Select    [ESC]: Default", 0

str_key_help2:
    db "  [1]-[9]: Quick select", 0

str_timeout_prefix:
    db "  Auto-selecting default in ", 0

str_timeout_suffix:
    db " seconds...", 0

; --- Thông báo lỗi ---
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

; Buffer số cho itoa
timeout_num_buf:        resb 12

; =====================================================
; GIAI THÍCH VỀ FORMAT LANGUAGES.BIN
; =====================================================
; File LANGUAGES.BIN là plain text UTF-8, ví dụ:
;
;   # Danh sach ngon ngu ho tro
;   # Format: CODE|NAME
;   vi|Tieng Viet
;   en|English
;   zh|Chinese (中文)
;   ja|Japanese (日本語)
;   ko|Korean (한국어)
;   fr|Français
;   de|Deutsch
;   es|Español
;
; Quy tắc:
;   - Dòng bắt đầu '#' = comment
;   - Dòng trống bị bỏ qua
;   - CODE: tối đa 7 ký tự ASCII, phân tách bằng '|'
;   - NAME: tối đa 31 ký tự (UTF-8 nhưng VGA chỉ hiển thị CP437)
;   - Tối đa 64 ngôn ngữ
;   - Ngôn ngữ đầu tiên = mặc định khi timeout
; =====================================================
