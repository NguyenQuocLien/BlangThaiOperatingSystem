; =====================================================
; stage2/editing.asm
; Module: Bootloader Partition Editor
; Compile thành EDITING.BIN, load động bởi menu.asm
;
; CALLING CONVENTION (từ menu.asm):
;   push fat32_cache_addr    (0x00051000)
;   push boot_drive
;   call EDITOR_BUF_ADDR     (0x00041000)
;
; CHỨC NĂNG:
;   1. List files trong partition /BOOT
;   2. Hex viewer/editor cho từng file
;   3. Đọc/ghi raw sector (nguy hiểm!)
;   4. Backup/Restore MBR
;   5. Kiểm tra tính toàn vẹn (checksum)
;
; CẤU TRÚC BỘ NHỚ (editor dùng):
;   0x00058000 - Sector editor buffer    (512 bytes)
;   0x00058200 - File list buffer        (4 KB)
;   0x00059200 - Hex view buffer         (4 KB)
;   0x0005A200 - MBR backup buffer       (512 bytes)
;   0x0005A400 - FAT32 file list cache   (2 KB)
;   0x0005AC00 - Undo buffer             (512 bytes, 1 sector)
;
; GIAO DIỆN:
;   Màn hình chia 2 panel:
;   [Left: File List / Sector Nav] [Right: Hex View]
;   Bottom: Status bar + Command bar
; =====================================================

BITS 32

; =====================================================
; CONSTANTS
; =====================================================
EDITOR_VERSION          equ 0x0100      ; v1.0

; Memory regions
SECTOR_BUF              equ 0x00058000
FILE_LIST_BUF           equ 0x00058200
HEX_VIEW_BUF            equ 0x00059200
MBR_BACKUP_BUF          equ 0x0005A200
FAT32_LIST_BUF          equ 0x0005A400
UNDO_BUF                equ 0x0005AC00

; VGA
VGA_TEXT_BASE           equ 0xB8000
VGA_COLS                equ 80
VGA_ROWS                equ 25

; Màu sắc
COLOR_NORMAL            equ 0x07
COLOR_HIGHLIGHT         equ 0x70
COLOR_TITLE             equ 0x0F
COLOR_DANGER            equ 0x4F        ; White on Red
COLOR_KEY               equ 0x0E
COLOR_DESC              equ 0x08
COLOR_SUCCESS           equ 0x0A
COLOR_ERROR             equ 0x0C
COLOR_HEX_ADDR          equ 0x0B        ; Cyan - địa chỉ
COLOR_HEX_DATA          equ 0x07        ; Trắng - dữ liệu hex
COLOR_HEX_ASCII         equ 0x0A        ; Xanh lá - ASCII view
COLOR_HEX_MODIFIED      equ 0x0C        ; Đỏ sáng - byte đã sửa
COLOR_PANEL_BORDER      equ 0x0B
COLOR_STATUS            equ 0x30        ; Đen trên cyan

; Layout màn hình
PANEL_LEFT_W            equ 28          ; Độ rộng panel trái
PANEL_RIGHT_COL         equ 30          ; Cột bắt đầu panel phải
CONTENT_ROWS            equ 20          ; Row 2 đến 21
HEADER_ROW              equ 0
SUBHEADER_ROW           equ 1
STATUS_ROW              equ 23
CMD_ROW                 equ 24

; Hex view layout
HEX_BYTES_PER_ROW       equ 16
HEX_ROWS                equ 16          ; 16 rows = 256 bytes/màn hình

; Editor modes
MODE_FILE_LIST          equ 0           ; Xem danh sách file
MODE_HEX_VIEW           equ 1           ; Hex viewer (read-only)
MODE_HEX_EDIT           equ 2           ; Hex editor (write mode)
MODE_SECTOR_NAV         equ 3           ; Điều hướng sector thô
MODE_MBR_TOOL           equ 4           ; Công cụ MBR

; Sector size
SECTOR_SIZE             equ 512

; Max files trong list
MAX_FILE_ENTRIES        equ 64
FILE_ENTRY_SIZE         equ 40          ; 32 (name) + 4 (size) + 4 (cluster) = 40

; =====================================================
; EXPORTS
; =====================================================
global editor_entry
global editor_hex_view
global editor_hex_edit
global editor_sector_read
global editor_sector_write
global editor_mbr_backup
global editor_mbr_restore
global editor_checksum_file

; =====================================================
; IMPORTS
; =====================================================
extern fat32_load_file
extern fat32_write_file
extern fat32_list_dir
extern fat32_get_cluster
extern fat32_read_sector    ; (drive, sector_lba, buf) -> eax=0 OK
extern fat32_write_sector   ; (drive, sector_lba, buf) -> eax=0 OK

; =====================================================
; SECTION TEXT
; =====================================================
section .text

; =====================================================
; editor_entry
; Stack: [esp+4]=boot_drive, [esp+8]=fat32_cache_addr
; =====================================================
editor_entry:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push edx
    push esi
    push edi
    sub esp, 20             ; Locals:
                            ; [ebp-4]  = current_mode
                            ; [ebp-8]  = selected_file (list index)
                            ; [ebp-12] = current_sector (LBA)
                            ; [ebp-16] = hex_offset (byte offset trong sector)
                            ; [ebp-20] = dirty_flag (sector đã sửa chưa)

    mov eax, [ebp + 8]
    mov [drive], eax
    mov eax, [ebp + 12]
    mov [fat32_cache], eax

    ; Init state
    mov dword [ebp - 4],  MODE_FILE_LIST
    mov dword [ebp - 8],  0
    mov dword [ebp - 12], 0
    mov dword [ebp - 16], 0
    mov dword [ebp - 20], 0

    ; Load danh sách file trong /BOOT
    call load_file_list

    ; Vẽ màn hình ban đầu
    call draw_editor_frame
    call draw_file_list_panel
    call draw_hex_panel_empty
    call draw_status_bar

.main_loop:
    ; Vẽ command bar theo mode
    push dword [ebp - 4]
    call draw_cmd_bar
    add esp, 4

    ; Đọc phím
    call read_key_blocking_e

    ; Dispatch theo mode
    mov ecx, [ebp - 4]
    cmp ecx, MODE_FILE_LIST
    je .dispatch_file_list
    cmp ecx, MODE_HEX_VIEW
    je .dispatch_hex_view
    cmp ecx, MODE_HEX_EDIT
    je .dispatch_hex_edit
    cmp ecx, MODE_SECTOR_NAV
    je .dispatch_sector_nav
    cmp ecx, MODE_MBR_TOOL
    je .dispatch_mbr
    jmp .main_loop

; -------------------------------------------------------
; FILE LIST MODE
; -------------------------------------------------------
.dispatch_file_list:
    cmp eax, 0x01           ; ESC = thoát
    je .do_exit
    cmp eax, 0x48           ; UP
    je .fl_up
    cmp eax, 0x50           ; DOWN
    je .fl_down
    cmp eax, 0x1C           ; ENTER = mở hex view
    je .fl_open_hex
    cmp eax, 0x1F           ; S = Sector Navigator
    je .fl_to_sector_nav
    cmp eax, 0x19           ; P (mBR tool)
    je .fl_to_mbr
    jmp .main_loop

.fl_up:
    mov eax, [ebp - 8]
    test eax, eax
    jz .main_loop
    dec eax
    mov [ebp - 8], eax
    push dword [ebp - 8]
    call draw_file_list_panel_sel
    add esp, 4
    jmp .main_loop

.fl_down:
    mov eax, [ebp - 8]
    inc eax
    cmp eax, [file_count]
    jge .main_loop
    mov [ebp - 8], eax
    push dword [ebp - 8]
    call draw_file_list_panel_sel
    add esp, 4
    jmp .main_loop

.fl_open_hex:
    ; Load file được chọn vào HEX_VIEW_BUF
    push dword [ebp - 8]
    call load_selected_file
    add esp, 4
    test eax, eax
    jnz .main_loop
    ; Chuyển sang hex view
    mov dword [ebp - 4], MODE_HEX_VIEW
    mov dword [ebp - 16], 0
    call draw_hex_view
    jmp .main_loop

.fl_to_sector_nav:
    mov dword [ebp - 4], MODE_SECTOR_NAV
    push dword 0            ; Sector LBA 0 = MBR
    call load_raw_sector
    add esp, 4
    mov dword [ebp - 12], 0
    call draw_sector_nav_panel
    jmp .main_loop

.fl_to_mbr:
    mov dword [ebp - 4], MODE_MBR_TOOL
    call draw_mbr_tool_panel
    jmp .main_loop

; -------------------------------------------------------
; HEX VIEW MODE
; -------------------------------------------------------
.dispatch_hex_view:
    cmp eax, 0x01           ; ESC = về file list
    je .hv_back
    cmp eax, 0x48           ; UP = scroll lên 16 bytes
    je .hv_up
    cmp eax, 0x50           ; DOWN = scroll xuống
    je .hv_down
    cmp eax, 0x12           ; E = chuyển sang edit mode
    je .hv_to_edit
    jmp .main_loop

.hv_back:
    mov dword [ebp - 4], MODE_FILE_LIST
    call draw_file_list_panel
    call draw_hex_panel_empty
    jmp .main_loop

.hv_up:
    mov eax, [ebp - 16]
    sub eax, HEX_BYTES_PER_ROW
    jl .hv_clamp_zero
    mov [ebp - 16], eax
    jmp .hv_redraw
.hv_clamp_zero:
    mov dword [ebp - 16], 0
.hv_redraw:
    call draw_hex_view
    jmp .main_loop

.hv_down:
    mov eax, [ebp - 16]
    add eax, HEX_BYTES_PER_ROW
    ; Giới hạn: không vượt quá file_size - visible_bytes
    cmp eax, [current_file_size]
    jge .main_loop
    mov [ebp - 16], eax
    call draw_hex_view
    jmp .main_loop

.hv_to_edit:
    ; Xác nhận chuyển sang edit mode
    push dword COLOR_DANGER
    push dword str_confirm_edit
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    call read_key_blocking_e
    cmp eax, 0x1C           ; ENTER = confirm
    jne .main_loop
    mov dword [ebp - 4], MODE_HEX_EDIT
    call draw_hex_edit_overlay
    jmp .main_loop

; -------------------------------------------------------
; HEX EDIT MODE
; -------------------------------------------------------
.dispatch_hex_edit:
    cmp eax, 0x01           ; ESC = back to view (prompt nếu dirty)
    je .he_back
    cmp eax, 0x1F           ; S = Save changes
    je .he_save
    cmp eax, 0x16           ; U = Undo (khôi phục từ UNDO_BUF)
    je .he_undo
    cmp eax, 0x48           ; UP
    je .he_cursor_up
    cmp eax, 0x50           ; DOWN
    je .he_cursor_down
    cmp eax, 0x4B           ; LEFT
    je .he_cursor_left
    cmp eax, 0x4D           ; RIGHT
    je .he_cursor_right
    ; Phím hex 0-9, A-F
    push eax
    call is_hex_key
    test eax, eax
    pop eax
    jnz .he_input_hex
    jmp .main_loop

.he_back:
    cmp dword [ebp - 20], 0
    je .he_back_no_confirm
    ; Có thay đổi chưa save
    push dword COLOR_DANGER
    push dword str_unsaved_warn
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    call read_key_blocking_e
    cmp eax, 0x01           ; ESC lần 2 = discard
    jne .main_loop
.he_back_no_confirm:
    mov dword [ebp - 4], MODE_HEX_VIEW
    mov dword [ebp - 20], 0
    call draw_hex_view
    jmp .main_loop

.he_save:
    ; Backup trước khi ghi
    call backup_current_to_undo
    ; Ghi file
    push dword [current_file_size]
    push dword HEX_VIEW_BUF
    push dword current_filename
    call fat32_write_file
    add esp, 12
    cmp eax, -1
    je .he_save_fail
    mov dword [ebp - 20], 0
    push dword COLOR_SUCCESS
    push dword str_save_success
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .main_loop
.he_save_fail:
    push dword COLOR_ERROR
    push dword str_save_fail
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .main_loop

.he_undo:
    ; Khôi phục từ UNDO_BUF
    call restore_from_undo
    mov dword [ebp - 20], 0
    call draw_hex_view
    jmp .main_loop

.he_cursor_up:
    sub dword [hex_cursor], HEX_BYTES_PER_ROW
    jns .he_cursor_clamp
    mov dword [hex_cursor], 0
.he_cursor_clamp:
    call draw_hex_edit_overlay
    jmp .main_loop

.he_cursor_down:
    add dword [hex_cursor], HEX_BYTES_PER_ROW
    mov eax, [hex_cursor]
    cmp eax, [current_file_size]
    jl .he_cursor_clamp
    mov eax, [current_file_size]
    dec eax
    mov [hex_cursor], eax
    jmp .he_cursor_clamp

.he_cursor_left:
    mov eax, [hex_cursor]
    test eax, eax
    jz .he_cursor_clamp
    dec eax
    mov [hex_cursor], eax
    jmp .he_cursor_clamp

.he_cursor_right:
    inc dword [hex_cursor]
    mov eax, [hex_cursor]
    cmp eax, [current_file_size]
    jl .he_cursor_clamp
    dec dword [hex_cursor]
    jmp .he_cursor_clamp

.he_input_hex:
    ; Chuyển scancode -> hex digit
    push eax
    call scancode_to_hex_digit
    cmp eax, -1
    je .he_input_done
    ; Ghi vào nibble (nib_state: 0=high nibble, 1=low nibble)
    mov ecx, [hex_cursor]
    add ecx, HEX_VIEW_BUF
    cmp dword [nibble_state], 0
    je .write_high_nib
    ; Low nibble
    mov bl, [ecx]
    and bl, 0xF0
    or bl, al
    mov [ecx], bl
    mov dword [nibble_state], 0
    inc dword [hex_cursor]
    jmp .he_mark_dirty
.write_high_nib:
    mov bl, [ecx]
    and bl, 0x0F
    shl al, 4
    or bl, al
    mov [ecx], bl
    mov dword [nibble_state], 1
.he_mark_dirty:
    mov dword [ebp - 20], 1
    call draw_hex_edit_overlay
.he_input_done:
    pop eax                 ; Khôi phục stackcân bằng sau pop trước push
    jmp .main_loop

; -------------------------------------------------------
; SECTOR NAVIGATOR MODE
; -------------------------------------------------------
.dispatch_sector_nav:
    cmp eax, 0x01           ; ESC = về file list
    je .sn_back
    cmp eax, 0x48           ; UP = sector - 1
    je .sn_prev
    cmp eax, 0x50           ; DOWN = sector + 1
    je .sn_next
    cmp eax, 0x21           ; F = nhập sector number
    je .sn_goto
    cmp eax, 0x12           ; E = edit mode (sector)
    je .sn_to_edit
    jmp .main_loop

.sn_back:
    mov dword [ebp - 4], MODE_FILE_LIST
    call draw_file_list_panel
    call draw_hex_panel_empty
    jmp .main_loop

.sn_prev:
    mov eax, [ebp - 12]
    test eax, eax
    jz .main_loop
    dec eax
    mov [ebp - 12], eax
    push eax
    call load_raw_sector
    add esp, 4
    call draw_sector_nav_panel
    jmp .main_loop

.sn_next:
    inc dword [ebp - 12]
    push dword [ebp - 12]
    call load_raw_sector
    add esp, 4
    test eax, eax
    jz .sn_update
    ; Lỗi đọc sector -> rollback
    dec dword [ebp - 12]
    jmp .main_loop
.sn_update:
    call draw_sector_nav_panel
    jmp .main_loop

.sn_goto:
    ; Hiện input prompt cho số sector
    push dword COLOR_KEY
    push dword str_enter_sector
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    push dword sector_input_buf
    call read_string_e
    add esp, 4
    ; Convert decimal string -> dword
    push dword sector_input_buf
    call atoi_decimal
    add esp, 4
    mov [ebp - 12], eax
    push eax
    call load_raw_sector
    add esp, 4
    test eax, eax
    jnz .main_loop
    call draw_sector_nav_panel
    jmp .main_loop

.sn_to_edit:
    ; Cảnh báo: raw sector write là CỰC KỲ nguy hiểm
    push dword COLOR_DANGER
    push dword str_raw_edit_warn
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    call read_key_blocking_e
    cmp eax, 0x1C
    jne .main_loop
    ; Backup sector vào UNDO_BUF
    call backup_sector_to_undo
    ; Cho phép edit (giống hex edit nhưng target là SECTOR_BUF)
    ; ... (sử dụng lại hex edit logic với target khác)
    jmp .main_loop

; -------------------------------------------------------
; MBR TOOL MODE
; -------------------------------------------------------
.dispatch_mbr:
    cmp eax, 0x01           ; ESC
    je .mbr_back
    cmp eax, 0x30           ; B = Backup MBR
    je .mbr_backup
    cmp eax, 0x13           ; R = Restore MBR
    je .mbr_restore
    cmp eax, 0x2E           ; C = Checksum
    je .mbr_checksum
    jmp .main_loop

.mbr_back:
    mov dword [ebp - 4], MODE_FILE_LIST
    call draw_file_list_panel
    call draw_hex_panel_empty
    jmp .main_loop

.mbr_backup:
    call editor_mbr_backup
    push dword (eax == 0 ? COLOR_SUCCESS : COLOR_ERROR)
    ; Dùng cmp/je:
    add esp, 0
    cmp eax, 0
    je .mbr_bk_ok
    push dword COLOR_ERROR
    push dword str_mbr_backup_fail
    jmp .mbr_status
.mbr_bk_ok:
    push dword COLOR_SUCCESS
    push dword str_mbr_backup_ok
.mbr_status:
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .main_loop

.mbr_restore:
    ; Xác nhận 2 lần
    push dword COLOR_DANGER
    push dword str_mbr_restore_warn
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    call read_key_blocking_e
    cmp eax, 0x1C
    jne .main_loop
    call editor_mbr_restore
    jmp .main_loop

.mbr_checksum:
    call editor_checksum_file
    jmp .main_loop

.do_exit:
    ; Kiểm tra dirty trước khi thoát
    cmp dword [ebp - 20], 0
    je .exit_clean
    push dword COLOR_DANGER
    push dword str_exit_dirty
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    call read_key_blocking_e
    cmp eax, 0x01           ; ESC = discard and exit
    jne .main_loop

.exit_clean:
    add esp, 20
    pop edi
    pop esi
    pop edx
    pop ecx
    pop ebx
    pop ebp
    ret

; =====================================================
; load_file_list
; Gọi fat32_list_dir để lấy danh sách file trong /BOOT
; Kết quả lưu vào FAT32_LIST_BUF
; =====================================================
load_file_list:
    push ebp
    mov ebp, esp

    push dword MAX_FILE_ENTRIES
    push dword FILE_ENTRY_SIZE
    push dword FAT32_LIST_BUF
    push dword str_boot_dir
    call fat32_list_dir
    add esp, 16

    ; eax = số file tìm thấy (hoặc -1)
    cmp eax, -1
    je .fail
    mov [file_count], eax
    xor eax, eax
    jmp .done
.fail:
    mov dword [file_count], 0
    mov eax, -1
.done:
    pop ebp
    ret

; =====================================================
; load_selected_file
; Input: [esp+4] = file index
; Output: EAX = 0 OK, -1 lỗi
; =====================================================
load_selected_file:
    push ebp
    mov ebp, esp

    mov eax, [ebp + 8]
    mov ecx, FILE_ENTRY_SIZE
    mul ecx
    add eax, FAT32_LIST_BUF     ; eax = &file_entry[index]

    ; Copy filename
    push esi
    push edi
    mov esi, eax
    mov edi, current_filename
    mov ecx, 32
    rep movsb
    ; Lấy file size (ở offset 32 trong entry)
    mov eax, [esi]              ; size (sau 32 bytes name)
    mov [current_file_size], eax
    pop edi
    pop esi

    ; Load file
    push dword [current_file_size]
    push dword HEX_VIEW_BUF
    push dword current_filename
    call fat32_load_file
    add esp, 12

    cmp eax, -1
    je .fail
    mov [current_file_size], eax
    xor eax, eax
    jmp .done
.fail:
    mov eax, -1
.done:
    pop ebp
    ret

; =====================================================
; load_raw_sector
; Input: [esp+4] = LBA sector number
; Output: EAX = 0 OK, -1 lỗi
; =====================================================
load_raw_sector:
    push ebp
    mov ebp, esp

    push dword SECTOR_BUF
    push dword [ebp + 8]        ; LBA
    push dword [drive]
    call fat32_read_sector
    add esp, 12

    pop ebp
    ret

; =====================================================
; editor_mbr_backup
; Đọc sector 0 và lưu vào MBR_BACKUP_BUF + file MBR.BAK
; =====================================================
editor_mbr_backup:
    push ebp
    mov ebp, esp

    ; Đọc MBR (sector LBA 0)
    push dword MBR_BACKUP_BUF
    push dword 0
    push dword [drive]
    call fat32_read_sector
    add esp, 12
    test eax, eax
    jnz .fail

    ; Ghi ra file MBR.BAK
    push dword SECTOR_SIZE
    push dword MBR_BACKUP_BUF
    push dword file_mbr_bak
    call fat32_write_file
    add esp, 12

    pop ebp
    ret
.fail:
    mov eax, -1
    pop ebp
    ret

; =====================================================
; editor_mbr_restore
; Đọc MBR.BAK và ghi vào sector 0
; CỰC KỲ NGUY HIỂM!
; =====================================================
editor_mbr_restore:
    push ebp
    mov ebp, esp

    ; Xác nhận lần cuối
    push dword COLOR_DANGER
    push dword str_mbr_final_warn
    push dword 22
    push dword 0
    call print_at_color_e
    add esp, 16
    call read_key_blocking_e
    cmp eax, 0x1C
    jne .cancelled

    ; Load MBR.BAK
    push dword SECTOR_SIZE
    push dword MBR_BACKUP_BUF
    push dword file_mbr_bak
    call fat32_load_file
    add esp, 12
    cmp eax, SECTOR_SIZE
    jne .fail

    ; Backup UNDO trước
    call backup_sector_to_undo

    ; Ghi vào sector 0
    push dword MBR_BACKUP_BUF
    push dword 0
    push dword [drive]
    call fat32_write_sector
    add esp, 12
    test eax, eax
    jnz .fail

    push dword COLOR_SUCCESS
    push dword str_mbr_restore_ok
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .done

.fail:
    push dword COLOR_ERROR
    push dword str_mbr_restore_fail
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .done

.cancelled:
    push dword COLOR_DESC
    push dword str_op_cancelled
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16

.done:
    pop ebp
    ret

; =====================================================
; editor_checksum_file
; Tính CRC32 đơn giản (XOR-based) cho file đang mở
; =====================================================
editor_checksum_file:
    push ebp
    mov ebp, esp
    push esi
    push ecx

    mov esi, HEX_VIEW_BUF
    mov ecx, [current_file_size]
    xor eax, eax

.cksum_loop:
    test ecx, ecx
    jz .cksum_done
    xor al, [esi]
    ror eax, 1              ; Rotate để phân tán bit
    inc esi
    dec ecx
    jmp .cksum_loop

.cksum_done:
    mov [last_checksum], eax

    ; Hiển thị
    push eax
    push dword checksum_display_buf
    call itoa_hex
    add esp, 8

    push dword COLOR_KEY
    push dword checksum_display_buf
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16

    pop ecx
    pop esi
    pop ebp
    ret

; =====================================================
; backup_current_to_undo / backup_sector_to_undo
; =====================================================
backup_current_to_undo:
    push esi
    push edi
    push ecx
    mov esi, HEX_VIEW_BUF
    mov edi, UNDO_BUF
    mov ecx, SECTOR_SIZE    ; Backup 1 sector tại offset hex_cursor
    add esi, [hex_cursor]
    ; Align về đầu sector
    and esi, ~(SECTOR_SIZE - 1)
    rep movsb
    pop ecx
    pop edi
    pop esi
    ret

backup_sector_to_undo:
    push esi
    push edi
    push ecx
    mov esi, SECTOR_BUF
    mov edi, UNDO_BUF
    mov ecx, SECTOR_SIZE
    rep movsb
    pop ecx
    pop edi
    pop esi
    ret

restore_from_undo:
    push esi
    push edi
    push ecx
    mov esi, UNDO_BUF
    mov edi, HEX_VIEW_BUF
    add edi, [hex_cursor]
    and edi, ~(SECTOR_SIZE - 1)
    mov ecx, SECTOR_SIZE
    rep movsb
    pop ecx
    pop edi
    pop esi
    ret

; =====================================================
; DRAW FUNCTIONS
; =====================================================

draw_editor_frame:
    push ebp
    mov ebp, esp

    call clear_screen_e

    ; Header
    push dword COLOR_DANGER
    push dword str_editor_title
    push dword HEADER_ROW
    push dword 0
    call print_at_color_e
    add esp, 16

    ; Subheader
    push dword COLOR_KEY
    push dword str_editor_sub
    push dword SUBHEADER_ROW
    push dword 0
    call print_at_color_e
    add esp, 16

    ; Vertical divider (col 29, rows 2-21)
    push dword COLOR_PANEL_BORDER
    mov ecx, CONTENT_ROWS
    mov edx, 2              ; Start row
.div_loop:
    ; In '|' tại col 29
    mov eax, edx
    mov ebx, VGA_COLS
    mul ebx
    add eax, PANEL_LEFT_W
    shl eax, 1
    add eax, VGA_TEXT_BASE
    mov word [eax], 0x0B7C  ; '|' với color cyan
    inc edx
    dec ecx
    jnz .div_loop
    add esp, 4

    pop ebp
    ret

draw_file_list_panel:
    push dword 0
    call draw_file_list_panel_sel
    add esp, 4
    ret

draw_file_list_panel_sel:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push esi

    mov ebx, [ebp + 8]      ; selected index

    ; Panel title
    push dword COLOR_PANEL_BORDER
    push dword str_panel_files
    push dword 2
    push dword 0
    call print_at_color_e
    add esp, 16

    ; Danh sách file
    mov ecx, [file_count]
    xor esi, esi            ; current index

.file_loop:
    cmp esi, ecx
    jge .done
    cmp esi, CONTENT_ROWS - 2
    jge .done

    mov eax, COLOR_NORMAL
    cmp esi, ebx
    jne .no_hl
    mov eax, COLOR_HIGHLIGHT
.no_hl:
    ; Lấy tên file
    push esi
    mov eax, FILE_ENTRY_SIZE
    mul dword [esp]
    add eax, FAT32_LIST_BUF
    add esp, 4

    push dword eax
    mov eax, esi
    add eax, 3              ; row offset
    push eax
    push dword 1
    ; Không thể push local register trực tiếp, dùng eax
    mov eax, COLOR_NORMAL
    cmp esi, ebx
    jne .push_color
    mov eax, COLOR_HIGHLIGHT
.push_color:
    push eax
    call print_at_color_e
    add esp, 16

    inc esi
    jmp .file_loop

.done:
    ; Hiện số lượng file
    pop esi
    pop ecx
    pop ebx
    pop ebp
    ret

draw_hex_panel_empty:
    push ebp
    mov ebp, esp

    push dword COLOR_DESC
    push dword str_hex_empty
    push dword 12
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    pop ebp
    ret

; =====================================================
; draw_hex_view
; Vẽ hex dump của HEX_VIEW_BUF+hex_offset
; Layout: ADDR  | 16 bytes hex | ASCII
;         0000: 4D 5A 90 ...   MZ......
; =====================================================
draw_hex_view:
    push ebp
    mov ebp, esp
    push ebx
    push ecx
    push esi
    push edi

    ; Header
    push dword COLOR_HEX_ADDR
    push dword str_hex_header
    push dword 2
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    mov esi, HEX_VIEW_BUF
    add esi, [hex_view_offset]
    mov ecx, HEX_ROWS
    mov edi, 3              ; Start row

.row_loop:
    test ecx, ecx
    jz .done

    ; In địa chỉ (4 hex digits)
    push esi
    mov eax, esi
    sub eax, HEX_VIEW_BUF
    push eax
    push dword addr_buf
    call itoa_hex_short
    add esp, 8

    push dword COLOR_HEX_ADDR
    push dword addr_buf
    push edi
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    ; In 16 bytes hex
    push edi
    push esi
    push dword (PANEL_RIGHT_COL + 6)    ; col sau địa chỉ
    call draw_hex_row_data
    add esp, 12

    ; In ASCII
    push edi
    push esi
    push dword (PANEL_RIGHT_COL + 56)   ; col ASCII (6 + 16*3 + 1 = 56)
    call draw_hex_row_ascii
    add esp, 12

    add esi, HEX_BYTES_PER_ROW
    inc edi
    dec ecx
    jmp .row_loop

.done:
    pop edi
    pop esi
    pop ecx
    pop ebx
    pop ebp
    ret

draw_hex_row_data:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ecx

    mov esi, [ebp + 12]     ; data ptr
    mov ecx, HEX_BYTES_PER_ROW
    mov edi, [ebp + 8]      ; col start
    mov ebx, [ebp + 16]     ; row

.loop:
    test ecx, ecx
    jz .done
    ; Convert byte to hex
    movzx eax, byte [esi]
    push eax
    push dword byte_hex_buf
    call byte_to_hex
    add esp, 8

    push dword COLOR_HEX_DATA
    push dword byte_hex_buf
    push ebx
    push edi
    call print_at_color_e
    add esp, 16

    add edi, 3              ; "XX " = 3 chars
    inc esi
    dec ecx
    jmp .loop

.done:
    pop ecx
    pop edi
    pop esi
    pop ebp
    ret

draw_hex_row_ascii:
    push ebp
    mov ebp, esp
    push esi
    push ecx

    mov esi, [ebp + 12]
    mov ecx, HEX_BYTES_PER_ROW
    mov edi, [ebp + 8]
    mov ebx, [ebp + 16]

.loop:
    test ecx, ecx
    jz .done
    movzx eax, byte [esi]
    ; Printable ASCII: 0x20-0x7E
    cmp al, 0x20
    jl .non_print
    cmp al, 0x7E
    jle .print
.non_print:
    mov al, '.'
.print:
    mov [ascii_char_buf], al
    mov byte [ascii_char_buf + 1], 0
    push dword COLOR_HEX_ASCII
    push dword ascii_char_buf
    push ebx
    push edi
    call print_at_color_e
    add esp, 16
    inc edi
    inc esi
    dec ecx
    jmp .loop
.done:
    pop ecx
    pop esi
    pop ebp
    ret

draw_hex_edit_overlay:
    ; Giống draw_hex_view nhưng highlight cursor position
    ; và dùng COLOR_HEX_MODIFIED cho byte đã sửa
    ; (Simplified: gọi draw_hex_view + overlay cursor)
    call draw_hex_view
    ; TODO: highlight hex_cursor position
    ret

draw_sector_nav_panel:
    push ebp
    mov ebp, esp

    push dword COLOR_KEY
    push dword str_sector_label
    push dword 2
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    ; Hiện sector number
    push dword [current_sector_lba]
    push dword sector_num_buf
    call itoa_decimal_e
    add esp, 8

    push dword COLOR_HEX_ADDR
    push dword sector_num_buf
    push dword 2
    push dword (PANEL_RIGHT_COL + 15)
    call print_at_color_e
    add esp, 16

    ; Hex dump của sector
    push dword HEX_VIEW_BUF    ; Reuse hex view buffer với SECTOR_BUF
    ; Copy SECTOR_BUF -> HEX_VIEW_BUF
    push esi
    push edi
    push ecx
    mov esi, SECTOR_BUF
    mov edi, HEX_VIEW_BUF
    mov ecx, SECTOR_SIZE
    rep movsb
    pop ecx
    pop edi
    pop esi
    add esp, 4

    call draw_hex_view
    pop ebp
    ret

draw_mbr_tool_panel:
    push ebp
    mov ebp, esp

    call clear_right_panel

    push dword COLOR_DANGER
    push dword str_mbr_title
    push dword 3
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    push dword COLOR_NORMAL
    push dword str_mbr_opt_backup
    push dword 5
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    push dword COLOR_NORMAL
    push dword str_mbr_opt_restore
    push dword 6
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    push dword COLOR_NORMAL
    push dword str_mbr_opt_checksum
    push dword 7
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    push dword COLOR_DESC
    push dword str_mbr_note
    push dword 10
    push dword PANEL_RIGHT_COL
    call print_at_color_e
    add esp, 16

    pop ebp
    ret

draw_status_bar:
    push ebp
    mov ebp, esp

    push dword COLOR_STATUS
    push dword str_status_default
    push dword STATUS_ROW
    push dword 0
    call print_at_color_e
    add esp, 16

    pop ebp
    ret

draw_cmd_bar:
    push ebp
    mov ebp, esp

    mov eax, [ebp + 8]      ; mode

    cmp eax, MODE_FILE_LIST
    je .cmd_file_list
    cmp eax, MODE_HEX_VIEW
    je .cmd_hex_view
    cmp eax, MODE_HEX_EDIT
    je .cmd_hex_edit
    cmp eax, MODE_SECTOR_NAV
    je .cmd_sector_nav
    cmp eax, MODE_MBR_TOOL
    je .cmd_mbr
    jmp .done

.cmd_file_list:
    push dword COLOR_KEY
    push dword str_cmd_file_list
    push dword CMD_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .done

.cmd_hex_view:
    push dword COLOR_KEY
    push dword str_cmd_hex_view
    push dword CMD_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .done

.cmd_hex_edit:
    push dword COLOR_DANGER
    push dword str_cmd_hex_edit
    push dword CMD_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .done

.cmd_sector_nav:
    push dword COLOR_KEY
    push dword str_cmd_sector
    push dword CMD_ROW
    push dword 0
    call print_at_color_e
    add esp, 16
    jmp .done

.cmd_mbr:
    push dword COLOR_DANGER
    push dword str_cmd_mbr
    push dword CMD_ROW
    push dword 0
    call print_at_color_e
    add esp, 16

.done:
    pop ebp
    ret

clear_right_panel:
    push edi
    push ecx
    push eax
    mov ecx, CONTENT_ROWS
    mov edx, 2
.loop:
    mov eax, edx
    mov ebx, VGA_COLS
    mul ebx
    add eax, PANEL_RIGHT_COL
    shl eax, 1
    add eax, VGA_TEXT_BASE
    mov edi, eax
    ; Fill với spaces (VGA_COLS - PANEL_RIGHT_COL chars)
    mov ecx, VGA_COLS - PANEL_RIGHT_COL
    mov ax, 0x0720
    rep stosw
    inc edx
    loop .loop
    pop eax
    pop ecx
    pop edi
    ret

; =====================================================
; HELPER FUNCTIONS (standalone)
; =====================================================

clear_screen_e:
    push edi
    push ecx
    mov edi, VGA_TEXT_BASE
    mov ecx, VGA_COLS * VGA_ROWS
    mov ax, 0x0720
    rep stosw
    pop ecx
    pop edi
    ret

print_at_color_e:
    push ebp
    mov ebp, esp
    push esi
    push edi
    mov eax, [ebp + 12]     ; row
    mov ecx, VGA_COLS
    mul ecx
    add eax, [ebp + 8]      ; col
    shl eax, 1
    add eax, VGA_TEXT_BASE
    mov edi, eax
    mov esi, [ebp + 16]     ; string
    mov ah, [ebp + 20]      ; color
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

read_key_blocking_e:
.wait:
    in al, 0x64
    test al, 1
    jz .wait
    in al, 0x60
    movzx eax, al
    test eax, 0x80
    jnz .wait
    ret

read_string_e:
    push ebp
    mov ebp, esp
    push edi
    push ecx
    mov edi, [ebp + 8]
    xor ecx, ecx
.loop:
    call read_key_blocking_e
    cmp eax, 0x1C
    je .done
    cmp eax, 0x0E
    je .bs
    cmp ecx, 15
    jge .loop
    ; Digit only
    cmp eax, 0x02
    jl .loop
    cmp eax, 0x0B
    jg .loop
    sub eax, 0x02
    add al, '1'
    cmp al, '9' + 1
    jle .store
    mov al, '0'
.store:
    mov [edi + ecx], al
    inc ecx
    jmp .loop
.bs:
    test ecx, ecx
    jz .loop
    dec ecx
    jmp .loop
.done:
    mov byte [edi + ecx], 0
    pop ecx
    pop edi
    pop ebp
    ret

byte_to_hex:
    push ebp
    mov ebp, esp
    push edi
    mov edi, [ebp + 8]      ; buf
    mov eax, [ebp + 12]     ; byte value
    mov ecx, eax
    shr ecx, 4
    and ecx, 0xF
    cmp ecx, 10
    jl .high_digit
    add ecx, 'A' - 10
    jmp .store_high
.high_digit:
    add ecx, '0'
.store_high:
    mov [edi], cl
    mov ecx, eax
    and ecx, 0xF
    cmp ecx, 10
    jl .low_digit
    add ecx, 'A' - 10
    jmp .store_low
.low_digit:
    add ecx, '0'
.store_low:
    mov [edi + 1], cl
    mov byte [edi + 2], ' '
    mov byte [edi + 3], 0
    pop edi
    pop ebp
    ret

itoa_hex:
    push ebp
    mov ebp, esp
    push edi
    push ecx
    mov edi, [ebp + 8]
    mov eax, [ebp + 12]
    mov ecx, 8
    add edi, 8
    mov byte [edi], 0
.loop:
    dec edi
    mov edx, eax
    and edx, 0xF
    cmp edx, 10
    jl .digit
    add edx, 'A' - 10
    jmp .store
.digit:
    add edx, '0'
.store:
    mov [edi], dl
    shr eax, 4
    dec ecx
    jnz .loop
    pop ecx
    pop edi
    pop ebp
    ret

itoa_hex_short:
    push ebp
    mov ebp, esp
    push edi
    push ecx
    mov edi, [ebp + 8]
    mov eax, [ebp + 12]
    mov ecx, 4
    add edi, 4
    mov byte [edi], ':'
    mov byte [edi + 1], 0
.loop:
    dec edi
    mov edx, eax
    and edx, 0xF
    cmp edx, 10
    jl .digit
    add edx, 'A' - 10
    jmp .store
.digit:
    add edx, '0'
.store:
    mov [edi], dl
    shr eax, 4
    dec ecx
    jnz .loop
    pop ecx
    pop edi
    pop ebp
    ret

itoa_decimal_e:
    push ebp
    mov ebp, esp
    push esi
    push edi
    push ecx
    push ebx
    mov edi, [ebp + 8]
    mov eax, [ebp + 12]
    mov ebx, 10
    test eax, eax
    jnz .convert
    mov byte [edi], '0'
    mov byte [edi + 1], 0
    jmp .done
.convert:
    xor ecx, ecx
.div:
    test eax, eax
    jz .write
    xor edx, edx
    div ebx
    add dl, '0'
    push edx
    inc ecx
    jmp .div
.write:
    pop edx
    mov [edi], dl
    inc edi
    dec ecx
    jnz .write
    mov byte [edi], 0
.done:
    pop ebx
    pop ecx
    pop edi
    pop esi
    pop ebp
    ret

is_hex_key:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]
    ; Scancodes cho 0-9: 0x02-0x0B
    cmp eax, 0x02
    jl .notnum
    cmp eax, 0x0B
    jle .yes
    ; Scancodes cho A-F: 0x1E(A) 0x30(B) 0x2E(C) 0x20(D) 0x12(E) 0x21(F)
    cmp eax, 0x1E
    je .yes
    cmp eax, 0x30
    je .yes
    cmp eax, 0x2E
    je .yes
    cmp eax, 0x20
    je .yes
    cmp eax, 0x12
    je .yes
    cmp eax, 0x21
    je .yes
.notnum:
    xor eax, eax
    pop ebp
    ret
.yes:
    mov eax, 1
    pop ebp
    ret

scancode_to_hex_digit:
    push ebp
    mov ebp, esp
    mov eax, [ebp + 8]
    cmp eax, 0x02
    jl .notfound
    cmp eax, 0x0B
    jg .try_alpha
    sub eax, 0x02
    cmp eax, 9
    jle .is_0_to_9
    xor eax, eax    ; '0' key (0x0B) -> 0
    jmp .done
.is_0_to_9:
    inc eax         ; 0x02 -> 1, ... 0x0A -> 9
    jmp .done
.try_alpha:
    cmp eax, 0x1E
    jne .try_b
    mov eax, 0xA
    jmp .done
.try_b:
    cmp eax, 0x30
    jne .try_c
    mov eax, 0xB
    jmp .done
.try_c:
    cmp eax, 0x2E
    jne .try_d
    mov eax, 0xC
    jmp .done
.try_d:
    cmp eax, 0x20
    jne .try_e
    mov eax, 0xD
    jmp .done
.try_e:
    cmp eax, 0x12
    jne .try_f
    mov eax, 0xE
    jmp .done
.try_f:
    cmp eax, 0x21
    jne .notfound
    mov eax, 0xF
    jmp .done
.notfound:
    mov eax, -1
.done:
    pop ebp
    ret

; =====================================================
; SECTION DATA
; =====================================================
section .data align=4

drive:              dd 0
fat32_cache:        dd 0
file_count:         dd 0
current_file_size:  dd 0
hex_cursor:         dd 0
nibble_state:       dd 0    ; 0=high nibble, 1=low nibble
hex_view_offset:    dd 0
current_sector_lba: dd 0
last_checksum:      dd 0

; File names
str_boot_dir:       db "/BOOT", 0
file_mbr_bak:       db "MBR.BAK", 0

; UI strings
str_editor_title:
    db "BTOS Partition Editor v1.0 [!! MODIFYING BOOT PARTITION !!]", 0
str_editor_sub:
    db "Drive: 0x80  Mode: Protected 32-bit  FAT32", 0

str_panel_files:    db "[ BOOT Files ]", 0
str_hex_empty:      db "Select a file to view", 0
str_hex_header:     db "ADDR  00 01 02 03 04 05 06 07 08 09 0A 0B 0C 0D 0E 0F  ASCII", 0
str_sector_label:   db "Sector LBA: ", 0

str_mbr_title:      db "[ MBR Tools ]", 0
str_mbr_opt_backup:     db "[B] Backup MBR -> MBR.BAK", 0
str_mbr_opt_restore:    db "[R] Restore MBR from MBR.BAK", 0
str_mbr_opt_checksum:   db "[C] Checksum current file", 0
str_mbr_note:
    db "MBR.BAK stored in /BOOT on FAT32 partition", 0

str_status_default: db " BTOS Editor | F=Goto Sector | S=Sector Nav | P=MBR Tools | ESC=Back", 0

str_cmd_file_list:
    db "[ENTER] Open  [S] Sector Nav  [P] MBR Tools  [UP/DOWN] Navigate  [ESC] Exit", 0
str_cmd_hex_view:
    db "[UP/DOWN] Scroll  [E] Edit Mode  [ESC] Back to list", 0
str_cmd_hex_edit:
    db "[ARROWS] Move  [0-9 A-F] Edit Hex  [S] Save  [U] Undo  [ESC] Exit Edit", 0
str_cmd_sector:
    db "[UP/DOWN] Prev/Next Sector  [F] Goto  [E] Edit  [ESC] Back", 0
str_cmd_mbr:
    db "[B] Backup  [R] Restore  [C] Checksum  [ESC] Back", 0

str_confirm_edit:
    db "[!] ENTERING EDIT MODE. Changes write directly to disk. [ENTER]=Confirm [ESC]=Cancel", 0
str_unsaved_warn:
    db "[!] Unsaved changes! [ESC]=Discard and exit  Any other key=Stay", 0
str_exit_dirty:
    db "[!] Modified data not saved! [ESC]=Exit anyway  Any other key=Stay", 0
str_save_success:   db "File saved successfully.", 0
str_save_fail:      db "[ERROR] Failed to write file.", 0
str_enter_sector:   db "Enter sector LBA (decimal): ", 0
str_raw_edit_warn:
    db "[!!!] RAW SECTOR EDIT! Wrong data = unbootable system! [ENTER]=Proceed [ESC]=Cancel", 0
str_mbr_backup_ok:  db "MBR backed up to /BOOT/MBR.BAK", 0
str_mbr_backup_fail: db "[ERROR] MBR backup failed.", 0
str_mbr_restore_warn:
    db "[!!!] Restore MBR? This OVERWRITES sector 0! [ENTER]=Yes [ESC]=No", 0
str_mbr_final_warn:
    db "[!!!] FINAL WARNING: Overwriting MBR sector 0. [ENTER]=I accept [ESC]=Cancel", 0
str_mbr_restore_ok: db "MBR restored from /BOOT/MBR.BAK", 0
str_mbr_restore_fail: db "[ERROR] MBR restore failed.", 0
str_op_cancelled:   db "Operation cancelled.", 0

; =====================================================
; SECTION BSS
; =====================================================
section .bss align=4

current_filename:       resb 32
sector_input_buf:       resb 16
addr_buf:               resb 8
byte_hex_buf:           resb 4
ascii_char_buf:         resb 4
sector_num_buf:         resb 12
checksum_display_buf:   resb 24
