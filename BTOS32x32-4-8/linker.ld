/* Xác định điểm khởi đầu của Kernel */
ENTRY(kernel_main)

SECTIONS
{
    /* Tải Kernel tại địa chỉ 1MB trong bộ nhớ RAM */
    . = 0x100000;

    /* Đoạn chứa mã lệnh thực thi (Code) */
    .text : AT(ADDR(.text))
    {
        *(.text)
    }

    /* Đoạn chứa dữ liệu chỉ đọc (Hằng số, Chuỗi ký tự) */
    .rodata : AT(ADDR(.rodata))
    {
        *(.rodata)
    }

    /* Đoạn chứa dữ liệu có thể ghi (Biến toàn cục đã khởi tạo) */
    .data : AT(ADDR(.data))
    {
        *(.data)
    }

    /* Đoạn chứa dữ liệu chưa khởi tạo (Biến tĩnh) */
    .bss : AT(ADDR(.bss))
    {
        *(.bss)
        *(COMMON)
    }
}
