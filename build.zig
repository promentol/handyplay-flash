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

    // core swf module (pure decoding; grows into the full core/flash.zig
    // umbrella once display/avm1/render exist).
    const swf_mod = b.addModule("swf", .{
        .root_source_file = b.path("core/swf/swf.zig"),
        .target = target,
        .optimize = optimize,
    });

    // --- tools -------------------------------------------------------------
    const Tool = struct { name: []const u8, src: []const u8 };
    const tools = [_]Tool{
        .{ .name = "swfinfo", .src = "tools/swfinfo.zig" },
        // M1: swfdump; M3: avm1dasm, trace_runner
    };
    for (tools) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "swf", .module = swf_mod }},
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
    const swf_tests = b.addTest(.{ .root_module = swf_mod });
    test_step.dependOn(&b.addRunArtifact(swf_tests).step);
}
