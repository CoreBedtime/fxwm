#ifndef iso_font_h
#define iso_font_h

#include <stdint.h>

extern unsigned char iso_font[256 * 16];

#define ISO_CHAR_MIN    0x00
#define ISO_CHAR_MAX    0xFF
#define ISO_CHAR_WIDTH  8
#define ISO_CHAR_HEIGHT 16

#endif /* iso_font_h */
