; =====================================================
; stage2/menu.asm
; Menu chính BTOS Bootloader
; Phiên bản: 1.0
;
; FLOW:
;   stage2_entry  -->  show_main_menu
;                           |
;              +------------+------------+----------+
;              |            |            |          |
;          [1] Resume   [2] Language  [3] Settings  [4] Partition Editor
;              |            |            |          |
;         boot_resume  show_lang_menu  settings.asm  editing.asm
;
; MEMORY MAP (bổ sung từ entry.asm):
;   0x00040000 - Settings buffer (4 KB)
;   0x00041000 - Partition editor working buffer (64 KB)
;   0x00051000 - FAT32 sector cache (16 KB)
;
; TRẠNG THÁI BOOT:
;   BOOT_STATE_NORMAL   = 0  Boot bình thường (không hiện menu)
;   BOOT_STATE_RESUMED  = 1  Người dùng ngắt boot, hiện menu
;   BOOT_STATE_SETTINGS = 2  Vào thẳng settings từ boot key
; =====================================================

BITS 32

; =====================================================
; CONSTANTS — Menu
; =====================================================
MENU_ITEM_RESUME        equ 1
MENU_ITEM_LANGUAGE      equ 2
MENU_ITEM_SETTINGS      equ 3
MENU_ITEM_PARTITION     equ 4
MENU_ITEM_COUNT         equ 4

; Vị trí vẽ menu trên màn hình
MENU_START_ROW          equ 5
MENU_START_COL          equ 20
MENU_WIDTH              equ 40
MENU_ITEM_HEIGHT        equ 3           ; Mỗi item chiếm 3 dòng (có padding)

; Boot state flags (lưu tại 0x7FFC)
BOOT_STATE_ADDR         equ 0x7FFC
BOOT_STATE_NORMAL       equ 0
BOOT_STATE_INTERRUPTED  equ 1
BOOT_STATE_SETTINGS     equ 2

; Memory vùng làm việc
SETTINGS_BUF_ADDR       equ 0x00040000
EDITOR_BUF_ADDR         equ 0x00041000
FAT32_CACHE_ADDR        equ 0x00051000

; Màu sắc bổ sung
COLOR_MENU_BORDER       equ 0x0B        ; Cyan sáng trên đen
COLOR_MENU_ITEM         equ 0x07        ; Trắng trên đen
COLOR_MENU_SELECTED     equ 0x70        ; Đen trên trắng
COLOR_MENU_KEY          equ 0x0E        ; Vàng (phím tắt)
COLOR_MENU_DESC         equ 0x08        ; Xám (mô tả)
COLOR_WARNING           equ 0x0C        ; Đỏ sáng
COLOR_SUCCESS           equ 0x0A        ; Xanh lá sáng
COLOR_PARTITION_WARN    equ 0x4F        ; Trắng trên đỏ (nguy hiểm!)

; Thêm vào phần CONSTANTS của menu.asm:
VGA_COLS        equ 80
VGA_ROWS        equ 25
COLOR_TITLE     equ 0x0F

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

; =====================================================
; IMPORTS
; =====================================================
extern stage2_entry
extern show_boot_menu           ; Từ entry.asm
extern fat32_init
extern fat32_load_file
extern fat32_write_file
extern fat32_list_dir
extern pit_get_ticks
extern pit_init

; =====================================================
; SECTION TEXT
; =====================================================
section .text

; =====================================================
; show_main_menu
; Điểm vào menu chính. Gọi từ stage2_entry khi
; phát hiện boot bị ngắt HOẶC người dùng nhấn phím.
;
; Input:  Không có (đọc boot_state từ 0x7FFC)
; Output: Không return — luôn branch sang sub-menu
;         hoặc boot_resume
; =====================================================
show_main_menu:
    push ebx
    push ecx
    push edx
    push esi
    push edi
    push ebp
    mov ebp, esp
    sub esp, 8              ; [ebp-4] = selected (1-based), [ebp-8] = boot_state

    ; --- Đọc boot state ---
    movzx eax, byte [BOOT_STATE_ADDR]
    mov [ebp - 8], eax

    ; --- Vẽ khung menu ---
    call draw_main_menu_frame

    ; --- Mặc định chọn item 1 ---
    mov dword [ebp - 4], 1

    ; --- Nếu boot state = NORMAL: item 1 (Resume) không có ý nghĩa,
    ;     nhưng vẫn hiện để người dùng hiểu. Dim nó nếu cần. ---

.menu_loop:
    ; Vẽ lại tất cả items với trạng thái highlight hiện tại
    push dword [ebp - 4]
    push dword [ebp - 8]    ; boot_state (để dim item 1 nếu normal)
    call draw_all_menu_items
    add esp, 8

    ; Đọc phím
    call read_key_blocking  ; eax = scan code (blocking, vì menu chính không timeout)

    ; --- Xử lý phím điều hướng ---
    cmp eax, 0x48           ; UP
    je .key_up
    cmp eax, 0x50           ; DOWN
    je .key_down
    cmp eax, 0x1C           ; ENTER
    je .key_enter

    ; --- Phím số 1-4 (scancode 0x02 - 0x05) ---
    cmp eax, 0x02
    je .select_1
    cmp eax, 0x03
    je .select_2
    cmp eax, 0x04
    je .select_3
    cmp eax, 0x05
    je .select_4
    jmp .menu_loop

.key_up:
    mov eax, [ebp - 4]
    dec eax
    jnz .set_sel            ; Nếu >= 1, OK
    mov eax, MENU_ITEM_COUNT ; Wrap về cuối
    jmp .set_sel

.key_down:
    mov eax, [ebp - 4]
    inc eax
    cmp eax, MENU_ITEM_COUNT + 1
    jl .set_sel
    mov eax, 1              ; Wrap về đầu
    jmp .set_sel

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
    jmp .menu_loop          ; Không hợp lệ, bỏ qua

.do_resume:
    call menu_resume_boot
    ; Nếu resume_boot return (lỗi), quay lại menu
    jmp show_main_menu

.do_language:
    call menu_enter_language
    ; Sau khi chọn ngôn ngữ xong, quay lại menu chính
    jmp show_main_menu

.do_settings:
    call menu_enter_settings
    jmp show_main_menu

.do_partition:
    call menu_enter_partition_editor
    jmp show_main_menu

; =====================================================
; draw_main_menu_frame
; Vẽ toàn bộ khung giao diện menu chính
; =====================================================
draw_main_menu_frame:
    push ebp
    mov ebp, esp
    push esi
    push edi

    call clear_screen

    ; --- Header ---
    ;  Row 0: Tiêu đề hệ thống
    push dword COLOR_TITLE
    push dword str_header_title
    push dword 0
    push dword 12
    call print_string_at_color
    add esp, 16

    ;  Row 1: Phiên bản
    push dword COLOR_MENU_DESC
    push dword str_header_version
    push dword 1
    push dword 15
    call print_string_at_color
    add esp, 16

    ;  Row 2: Đường kẻ đơn
    push dword COLOR_MENU_BORDER
    push dword str_line_single
    push dword 2
    push dword 0
    call print_string_at_color
    add esp, 16

    ;  Row 3: Trạng thái boot
    call draw_boot_status_line

    ;  Row 4: Đường kẻ
    push dword COLOR_MENU_BORDER
    push dword str_line_single
    push dword 4
    push dword 0
    call print_string_at_color
    add esp, 16

    ; --- Footer ---
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

    push dword COLOR_MENU_BORDER
    push dword str_line_single
    push dword 21
    push dword 0
    call print_string_at_color
    add esp, 16

    pop edi
    pop esi
    pop ebp
    ret

; =====================================================
; draw_boot_status_line
; In dòng trạng thái boot (row 3)
; =====================================================
draw_boot_status_line:
    push ebp
    mov ebp, esp

    movzx eax, byte [BOOT_STATE_ADDR]
    cmp eax, BOOT_STATE_INTERRUPTED
    je .interrupted
    cmp eax, BOOT_STATE_SETTINGS
    je .settings_mode

    ; Normal state
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
; Vẽ cả 4 menu items, highlight item được chọn
;
; Input (cdecl):
;   [esp+4]  = selected item (1-based)
;   [esp+8]  = boot_state
; =====================================================
draw_all_menu_items:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push esi

    mov ebx, [ebp + 8]      ; selected
    mov ecx, [ebp + 12]     ; boot_state

    ; --- Item 1: Resume ---
    mov eax, 1
    cmp eax, ebx
    je .item1_selected
    ; Item 1 dim nếu boot state = NORMAL (boot chưa bị ngắt)
    cmp ecx, BOOT_STATE_NORMAL
    je .item1_dim
    push dword COLOR_MENU_ITEM
    jmp .item1_draw
.item1_dim:
    push dword COLOR_MENU_DESC
    jmp .item1_draw
.item1_selected:
    push dword COLOR_MENU_SELECTED
.item1_draw:
    push dword str_item1_key
    push dword str_item1_name
    push dword str_item1_desc
    push dword MENU_START_ROW
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    ; --- Item 2: Language ---
    mov eax, 2
    push dword (eax == ebx ? COLOR_MENU_SELECTED : COLOR_MENU_ITEM)
    ; NASM không hỗ trợ ternary, dùng cmp/je:
    add esp, 4              ; Undone push trên (syntax demo, dùng cmp thực)
    mov eax, COLOR_MENU_ITEM
    cmp dword [ebp + 8], 2
    jne .item2_draw
    mov eax, COLOR_MENU_SELECTED
.item2_draw:
    push eax
    push dword str_item2_key
    push dword str_item2_name
    push dword str_item2_desc
    push dword (MENU_START_ROW + MENU_ITEM_HEIGHT)
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    ; --- Item 3: Settings ---
    mov eax, COLOR_MENU_ITEM
    cmp dword [ebp + 8], 3
    jne .item3_draw
    mov eax, COLOR_MENU_SELECTED
.item3_draw:
    push eax
    push dword str_item3_key
    push dword str_item3_name
    push dword str_item3_desc
    push dword (MENU_START_ROW + MENU_ITEM_HEIGHT * 2)
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    ; --- Item 4: Partition Editor ---
    mov eax, COLOR_MENU_ITEM
    cmp dword [ebp + 8], 4
    jne .item4_draw
    mov eax, COLOR_MENU_SELECTED
.item4_draw:
    push eax
    push dword str_item4_key
    push dword str_item4_name
    push dword str_item4_desc
    push dword (MENU_START_ROW + MENU_ITEM_HEIGHT * 3)
    push dword MENU_START_COL
    call draw_single_menu_item
    add esp, 24

    pop esi
    pop ecx
    pop ebx
    pop ebp
    ret

; =====================================================
; draw_single_menu_item
; Vẽ 1 menu item (2 dòng: tên + mô tả)
;
; Input (cdecl, push ngược):
;   [esp+4]  = col
;   [esp+8]  = row
;   [esp+12] = desc_ptr (mô tả)
;   [esp+16] = name_ptr (tên)
;   [esp+20] = key_ptr  (phím tắt, vd "[1]")
;   [esp+24] = color (màu nền item)
; =====================================================
draw_single_menu_item:
    push ebp
    mov ebp, esp
    push ebx
    push esi
    push edi

    mov ebx, [ebp + 28]     ; color

    ; Dòng 1: "  [N] NAME"
    ; -- In key (màu vàng nếu không selected, màu item nếu selected) --
    push ebx                ; color cho key
    push dword [ebp + 24]   ; key_ptr
    push dword [ebp + 12]   ; row
    push dword [ebp + 8]    ; col
    call print_string_at_color
    add esp, 16

    ; Tính col sau key (len("[N] ") = 4)
    mov eax, [ebp + 8]
    add eax, 4

    ; -- In tên --
    push ebx
    push dword [ebp + 20]   ; name_ptr
    push dword [ebp + 12]   ; row
    push eax                ; col sau key
    call print_string_at_color
    add esp, 16

    ; Dòng 2: "     <desc>" (indent thêm)
    mov eax, [ebp + 12]
    inc eax                 ; row + 1
    push dword COLOR_MENU_DESC
    push dword [ebp + 16]   ; desc_ptr
    push eax
    push dword [ebp + 8]    ; col gốc
    call print_string_at_color
    add esp, 16

    pop edi
    pop esi
    pop ebx
    pop ebp
    ret

; =====================================================
; menu_resume_boot
; Option 1: Tiếp tục quá trình boot bị ngắt
;
; Kiểm tra boot state — nếu NORMAL thì không có gì để resume.
; Nếu INTERRUPTED thì jump vào kernel đã load trước đó
; (hoặc reload nếu cần).
; =====================================================
menu_resume_boot:
    push ebp
    mov ebp, esp

    ; Kiểm tra có thực sự bị ngắt không
    movzx eax, byte [BOOT_STATE_ADDR]
    cmp eax, BOOT_STATE_INTERRUPTED
    jne .not_interrupted

    ; Hiện thông báo đang tiếp tục
    call clear_screen
    push dword COLOR_SUCCESS
    push dword str_resuming
    push dword 12
    push dword 15
    call print_string_at_color
    add esp, 16

    ; Đặt lại boot state về normal
    mov byte [BOOT_STATE_ADDR], BOOT_STATE_NORMAL

    ; TODO: Jump vào kernel entry point đã lưu
    ; Địa chỉ kernel entry nên được lưu khi boot bị ngắt
    ; mov eax, [kernel_entry_point]
    ; jmp eax

    ; Placeholder: Halt
    cli
    hlt

.not_interrupted:
    ; Hiện thông báo không có gì để resume
    push dword COLOR_WARNING
    push dword str_no_resume
    push dword 12
    push dword 10
    call print_string_at_color
    add esp, 16

    ; Chờ phím
    call read_key_blocking

    pop ebp
    ret                     ; Quay lại menu chính

; =====================================================
; menu_enter_language
; Option 2: Chọn ngôn ngữ
; Gọi show_boot_menu từ entry.asm, lưu kết quả
; =====================================================
menu_enter_language:
    push ebp
    mov ebp, esp

    call show_boot_menu     ; eax = index được chọn

    ; Lưu lựa chọn ngôn ngữ
    mov [selected_language_global], eax

    ; Hiện xác nhận
    call clear_screen
    push dword COLOR_SUCCESS
    push dword str_lang_saved
    push dword 12
    push dword 15
    call print_string_at_color
    add esp, 16

    ; Delay ngắn (~1 giây)
    call pit_get_ticks
    add eax, 18
    mov [temp_tick], eax
.wait:
    call pit_get_ticks
    cmp eax, [temp_tick]
    jl .wait

    pop ebp
    ret

; =====================================================
; menu_enter_settings
; Option 3: Boot Settings
; Load và execute settings.asm (đã compile thành SETTINGS.BIN)
; =====================================================
menu_enter_settings:
    push ebp
    mov ebp, esp

    ; Hiện "Loading Settings..."
    call clear_screen
    push dword COLOR_MENU_KEY
    push dword str_loading_settings
    push dword 12
    push dword 20
    call print_string_at_color
    add esp, 16

    ; Load SETTINGS.BIN từ FAT32 vào SETTINGS_BUF_ADDR
    push dword 0x1000               ; max 4 KB
    push dword SETTINGS_BUF_ADDR
    push dword file_settings
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .settings_load_error
    test eax, eax
    jz .settings_load_error

    ; Gọi settings module
    ; Convention: settings_entry(boot_drive)
    push dword [boot_drive_global]
    call SETTINGS_BUF_ADDR
    add esp, 4

    ; settings.asm trả về khi người dùng thoát
    pop ebp
    ret

.settings_load_error:
    push dword COLOR_WARNING
    push dword str_err_load_settings
    push dword 14
    push dword 10
    call print_string_at_color
    add esp, 16
    call read_key_blocking
    pop ebp
    ret

; =====================================================
; menu_enter_partition_editor
; Option 4: Can thiệp sâu vào phân vùng Bootloader
;
; ██ CẢNH BÁO ██
; Đây là chức năng nguy hiểm. Sai lầm có thể
; làm mất toàn bộ bootloader và không thể boot.
; Yêu cầu xác nhận 2 bước trước khi vào.
; =====================================================
menu_enter_partition_editor:
    push ebp
    mov ebp, esp
    sub esp, 4              ; [ebp-4] = confirm_state

    ; --- Bước 1: Cảnh báo đầu tiên ---
    call draw_partition_warning_screen

    ; Đọc phím xác nhận lần 1
    call read_key_blocking
    cmp eax, 0x01           ; ESC = hủy
    je .cancel
    cmp eax, 0x1C           ; ENTER = tiếp tục
    jne .cancel

    ; --- Bước 2: Xác nhận lần 2 (gõ "YES") ---
    call draw_partition_confirm_screen
    push dword confirm_buf
    call read_string        ; Đọc chuỗi từ bàn phím vào confirm_buf
    add esp, 4

    ; So sánh với "YES"
    mov esi, confirm_buf
    mov edi, str_confirm_yes
    call strcmp
    test eax, eax
    jnz .cancel             ; Không gõ YES -> hủy

    ; --- Load EDITING.BIN ---
    call clear_screen
    push dword COLOR_PARTITION_WARN
    push dword str_loading_editor
    push dword 12
    push dword 18
    call print_string_at_color
    add esp, 16

    push dword 0xF000               ; max 60 KB cho editor
    push dword EDITOR_BUF_ADDR
    push dword file_editing
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .editor_load_error
    test eax, eax
    jz .editor_load_error

    ; Gọi partition editor
    ; Convention: editor_entry(boot_drive, fat32_cache_addr)
    push dword FAT32_CACHE_ADDR
    push dword [boot_drive_global]
    call EDITOR_BUF_ADDR
    add esp, 8

    ; Editor trả về khi người dùng thoát
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

.editor_load_error:
    push dword COLOR_WARNING
    push dword str_err_load_editor
    push dword 18
    push dword 10
    call print_string_at_color
    add esp, 16
    call read_key_blocking

.done:
    mov esp, ebp
    pop ebp
    ret

; =====================================================
; draw_partition_warning_screen
; Màn hình cảnh báo nguy hiểm trước khi vào editor
; =====================================================
draw_partition_warning_screen:
    push ebp
    mov ebp, esp

    call clear_screen

    ; Header đỏ rực
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

    ; Tiêu đề WARNING
    push dword COLOR_WARNING
    push dword str_warn_title
    push dword 4
    push dword 20
    call print_string_at_color
    add esp, 16

    ; Nội dung cảnh báo
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

    ; Hướng dẫn
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
; Yêu cầu gõ "YES" để xác nhận
; =====================================================
draw_partition_confirm_screen:
    push ebp
    mov ebp, esp

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

    ; Cursor tại (10, 14) để nhập
    ; (VGA cursor positioning qua port 0x3D4)
    mov eax, 14 * VGA_COLS + 46    ; row 14, col 46
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, [cursor_pos_low]
    out dx, al
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, [cursor_pos_high]
    out dx, al

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
    mov [BOOT_STATE_ADDR], al
    ret

; =====================================================
; HELPER: read_key_blocking
; Block cho đến khi có phím, return scan code
; =====================================================
read_key_blocking:
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    movzx eax, al
    test eax, 0x80          ; Key release, bỏ qua
    jnz .wait
    ret

; =====================================================
; HELPER: read_string
; Đọc chuỗi từ keyboard vào buffer (echo lên màn hình)
; Input: [esp+4] = buffer ptr (max 16 bytes)
; =====================================================
read_string:
    push ebp
    mov ebp, esp
    push edi
    push ecx

    mov edi, [ebp + 8]      ; buffer ptr
    xor ecx, ecx            ; char count
    mov dword [read_str_col], 46    ; Vị trí hiển thị (col)
    mov dword [read_str_row], 14

.read_loop:
    call read_key_blocking
    cmp eax, 0x1C           ; Enter = kết thúc
    je .done
    cmp eax, 0x0E           ; Backspace
    je .backspace
    cmp ecx, 15             ; Max 15 chars + null
    jge .read_loop

    ; Convert scancode -> ASCII (uppercase only cho YES)
    push eax
    call scancode_to_ascii_upper
    test eax, eax
    jz .skip_char

    ; Lưu vào buffer
    mov [edi + ecx], al
    inc ecx

    ; Echo lên màn hình
    push dword COLOR_MENU_KEY
    ; Tạo 1-char string tạm
    mov [temp_char_buf], al
    mov byte [temp_char_buf + 1], 0
    push dword temp_char_buf
    push dword [read_str_row]
    push dword [read_str_col]
    call print_string_at_color
    add esp, 16
    inc dword [read_str_col]
    jmp .read_loop

.skip_char:
    pop eax
    jmp .read_loop

.backspace:
    test ecx, ecx
    jz .read_loop
    dec ecx
    dec dword [read_str_col]
    ; Xóa ký tự trên màn hình
    push dword COLOR_MENU_ITEM
    push dword str_space
    push dword [read_str_row]
    push dword [read_str_col]
    call print_string_at_color
    add esp, 16
    jmp .read_loop

.done:
    mov byte [edi + ecx], 0 ; Null terminate
    pop ecx
    pop edi
    pop ebp
    ret

; =====================================================
; HELPER: strcmp
; Input: ESI = str1, EDI = str2
; Output: EAX = 0 nếu bằng nhau
; =====================================================
strcmp:
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
    ret
.not_equal:
    movzx eax, al
    movzx ebx, bl
    sub eax, ebx
    ret

; =====================================================
; HELPER: scancode_to_ascii_upper
; Chuyển scan code -> ASCII uppercase
; Input: [esp+4] = scancode (đã pop khi gọi)
;   Thực ra: eax = scancode (sau push/call)
; Output: EAX = ASCII char, 0 nếu không map được
; =====================================================
scancode_to_ascii_upper:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]
    ; Bảng scancode -> ASCII đơn giản cho A-Z, 0-9
    cmp eax, 0x10           ; Q
    je .q
    cmp eax, 0x11           ; W
    je .w
    cmp eax, 0x12           ; E
    je .e
    cmp eax, 0x15           ; Y
    je .y
    cmp eax, 0x1F           ; S
    je .s
    xor eax, eax
    pop ebp
    ret
.q: mov eax, 'Q' & 0xFF
    jmp .done
.w: mov eax, 'W' & 0xFF
    jmp .done
.e: mov eax, 'E' & 0xFF
    jmp .done
.y: mov eax, 'Y' & 0xFF
    jmp .done
.s: mov eax, 'S' & 0xFF
.done:
    pop ebp
    ret

; =====================================================
; Re-export các hàm VGA từ entry.asm để dùng ở đây
; (Giả định link cùng object)
; =====================================================
extern print_string_at_color
extern clear_screen

; =====================================================
; SECTION DATA
; =====================================================
section .data align=4

boot_drive_global:      dd 0
selected_language_global: dd 0
temp_tick:              dd 0
cursor_pos_low:         db 0
cursor_pos_high:        db 0
read_str_col:           dd 46
read_str_row:           dd 14

; --- Tên file module ---
file_settings:          db "SETTINGS.BIN", 0
file_editing:           db "EDITING.BIN", 0

; --- UI strings ---
str_header_title:
    db "BTOS Bootloader v2.0", 0
str_header_version:
    db "Build 2025 | Protected Mode 32-bit", 0

str_line_single:
    db "--------------------------------------------------------------------------------", 0

str_state_normal:
    db "Status: System initialized normally", 0
str_state_interrupted:
    db "Status: [!] Boot was interrupted - use option 1 to resume", 0
str_state_settings:
    db "Status: Entered boot configuration mode", 0

; --- Menu items ---
; Item 1
str_item1_key:  db "[1]", 0
str_item1_name: db " Resume Boot", 0
str_item1_desc: db "    Continue the interrupted boot process", 0

; Item 2
str_item2_key:  db "[2]", 0
str_item2_name: db " Change Language / Doi ngon ngu", 0
str_item2_desc: db "    Select display language for the OS", 0

; Item 3
str_item3_key:  db "[3]", 0
str_item3_name: db " Boot Settings", 0
str_item3_desc: db "    Configure boot parameters and hardware options", 0

; Item 4
str_item4_key:  db "[4]", 0
str_item4_name: db " Partition Editor  [ADVANCED]", 0
str_item4_desc: db "    Direct intervention into bootloader partition", 0

; --- Footer ---
str_footer_nav:
    db "[UP][DOWN] Navigate   [1-4] Direct select", 0
str_footer_select:
    db "[ENTER] Confirm", 0

; --- Thông báo ---
str_resuming:
    db "Resuming boot process...", 0
str_no_resume:
    db "[!] No interrupted boot session found. Nothing to resume.", 0
str_lang_saved:
    db "Language selection saved.", 0
str_loading_settings:
    db "Loading Boot Settings...", 0
str_loading_editor:
    db "Loading Partition Editor...", 0
str_editor_cancelled:
    db "Operation cancelled.", 0
str_err_load_settings:
    db "[ERROR] Cannot load SETTINGS.BIN from FAT32 partition.", 0
str_err_load_editor:
    db "[ERROR] Cannot load EDITING.BIN from FAT32 partition.", 0
str_space:
    db " ", 0

; --- Cảnh báo Partition Editor ---
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

; --- Xác nhận gõ YES ---
str_confirm_title:
    db "FINAL CONFIRMATION", 0
str_confirm_prompt:
    db "Type YES (uppercase) and press ENTER to proceed: ", 0
str_confirm_yes:
    db "YES", 0

; =====================================================
; SECTION BSS
; =====================================================
section .bss align=4

confirm_buf:    resb 16
temp_char_buf:  resb 4
