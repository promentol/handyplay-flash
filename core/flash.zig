//! Umbrella host seam (mirrors handyplay-oss exen.zig). Frontend-agnostic, no I/O.
//! Contract (docs/ARCHITECTURE.md): init(allocator), loadSwf(bytes)->MovieInfo
//! (error.Avm2Unsupported on FileAttributes.ActionScript3), tick(elapsed_ms),
//! framebuffer() []const u32 (XRGB8888), setMouse/keyEvent, stateSize/saveState/
//! loadState, trace_sink. Wired up in M2 when display/render exist.
