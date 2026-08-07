/* stb_truetype implementation unit. STB single-header libraries require
 * exactly one TU to define STB_TRUETYPE_IMPLEMENTATION before including the
 * header — that pulls in the actual function bodies. Every other consumer
 * (the @cImport from SmFont.zig) just gets the declarations.
 */

#define STB_TRUETYPE_IMPLEMENTATION

/* stb_truetype's default allocators call malloc/free; we ship libc on both
 * native (linkLibC) and WASM (wasi-libc), so the defaults work everywhere
 * we target. Override here later if we want a page_allocator-backed arena. */

#include "stb_truetype.h"
