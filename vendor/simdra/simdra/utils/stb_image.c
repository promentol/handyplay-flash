/* stb_image + stb_image_write implementation unit. Single TU defines
 * STB_IMAGE_IMPLEMENTATION and STB_IMAGE_WRITE_IMPLEMENTATION; every
 * other consumer (the @cImport from decode/stb.zig and encode/jpeg.zig
 * etc.) gets only the declarations.
 *
 * Format scope (kept):
 *   decode: PNG, JPEG, BMP, GIF (single-frame)
 *   encode: PNG, JPEG, BMP (TGA path compiled but unused)
 *
 * Stripped (saves ~22KB compiled):
 *   HDR / LINEAR / PIC / PNM / PSD / TGA decoders
 *
 * Allocator policy: default libc malloc/realloc/free. node-zigar links
 * libc on both targets (`useLibc: true` in node-zigar.config.json and
 * vite.config.js — same path stb_truetype.c already takes). Override
 * later via STBI_MALLOC if a Zig-side arena is wanted.
 */

#define STB_IMAGE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_NO_HDR
#define STBI_NO_LINEAR
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_FAILURE_STRINGS
#include "stb_image.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#define STBIW_NO_HDR
#include "stb_image_write.h"

/* C-side accessors for stb's process-global PNG compression level. They
 * live in the same TU as the variable definition so the symbol is
 * visible to the read/write — Zig's `@cImport` exposes the extern decl
 * but the WASM toolchain doesn't always wire writes through to the
 * underlying object. The Zig encoder calls these instead of touching
 * `stbi_write_png_compression_level` directly. */
int simdra_get_png_compression_level(void) {
    return stbi_write_png_compression_level;
}
void simdra_set_png_compression_level(int level) {
    stbi_write_png_compression_level = level;
}
