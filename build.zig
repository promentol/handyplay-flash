//! handyflash build graph (zig 0.16).
//!
//! Steps:
//!   zig build            — install tools (swfinfo; more as milestones land)
//!   zig build test       — unit tests
//!   zig build run-swfinfo -- <file.swf>
//!
//! Planned (see docs/ARCHITECTURE.md and the milestone plan):
//!   zig build sdl        — SDL3 frontend               (M2)
//!   zig build libretro   — zig-out/libretro/flash_libretro.{dylib,so,dll}  (M5)

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Vendored simdra drawing core (vendor/simdra, MIT — see its LICENSE).
    // Needs libc + the stb C sources (SmFont/stb_truetype, decode/stb_image).
    const simdra_mod = b.createModule(.{
        .root_source_file = b.path("vendor/simdra/simdra.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    simdra_mod.addIncludePath(b.path("vendor/simdra"));
    simdra_mod.addCSourceFiles(.{ .files = &.{
        "vendor/simdra/simdra/utils/stb_image.c",
        "vendor/simdra/simdra/utils/stb_truetype.c",
    } });

    // Core module rooted at the umbrella (re-exports swf/ + display/;
    // grows the host seam in M2).
    const flash_mod = b.addModule("flash", .{
        .root_source_file = b.path("core/flash.zig"),
        .target = target,
        .optimize = optimize,
    });
    flash_mod.addImport("simdra", simdra_mod);

    // --- tools -------------------------------------------------------------
    const Tool = struct { name: []const u8, src: []const u8 };
    const tools = [_]Tool{
        .{ .name = "swfinfo", .src = "tools/swfinfo.zig" },
        .{ .name = "swfdump", .src = "tools/swfdump.zig" },
        // M3: avm1dasm, trace_runner
    };
    for (tools) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "flash", .module = flash_mod }},
        });
        const exe = b.addExecutable(.{ .name = t.name, .root_module = mod });
        b.installArtifact(exe);

        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step(
            b.fmt("run-{s}", .{t.name}),
            b.fmt("Run {s}", .{t.name}),
        ).dependOn(&run.step);
    }

    // --- tests -------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    const core_tests = b.addTest(.{ .root_module = flash_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
}
