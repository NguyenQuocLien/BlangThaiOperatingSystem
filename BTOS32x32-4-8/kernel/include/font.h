#ifndef FONT_H
#define FONT_H

#include <stdint.h>

extern const uint8_t font_8x8[256][8];

void draw_glyph(struct btos_hardware_profile *hw, 
                uint32_t x, uint32_t y, 
                uint8_t ch, 
                uint32_t fg_color, uint32_t bg_color);

#endif
