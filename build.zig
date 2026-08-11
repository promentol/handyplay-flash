//! handyplay-flash build graph (zig 0.16).
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
    // Release artifacts ship stripped: the debug info is a third of a
    // Linux `.so` and nothing on a player's machine reads it.
    const want_strip = b.option(bool, "strip", "Strip debug info from the binaries");
    // Android needs the NDK's Bionic — zig has no libc for it. Point
    // `--sysroot` at
    // `$NDK/toolchains/llvm/prebuilt/<host>/sysroot` and the API level
    // has to match a directory under its `usr/lib/<triple>/`.
    const android_api = b.option(u32, "android-api", "Android API level (NDK sysroot)") orelse 29;

    // Vendored simdra drawing core (vendor/simdra, MIT — see its LICENSE).
    // Needs libc + the stb C sources (SmFont/stb_truetype, decode/stb_image).
    const simdra_mod = b.createModule(.{
        .root_source_file = b.path("vendor/simdra/simdra.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    simdra_mod.addIncludePath(b.path("vendor/simdra"));
    // mingw's `malloc.h` gates `_ALLOCA_S_MARKER_SIZE` on `_X86_`, which
    // the gcc driver defines and translate-c does not — so every
    // `@cImport` that reaches malloc.h fails on 32-bit Windows only.
    if (target.result.os.tag == .windows and target.result.cpu.arch == .x86) {
        simdra_mod.addCMacro("_X86_", "1");
    }
    simdra_mod.addCSourceFiles(.{ .files = &.{
        "vendor/simdra/simdra/utils/stb_image.c",
        "vendor/simdra/simdra/utils/stb_truetype.c",
    } });
    androidSysroot(b, simdra_mod, target, android_api);

    // Core module rooted at the umbrella (re-exports swf/ + display/;
    // grows the host seam in M2).
    const flash_mod = b.addModule("flash", .{
        .root_source_file = b.path("core/flash.zig"),
        .target = target,
        .optimize = optimize,
    });
    flash_mod.addImport("simdra", simdra_mod);

    // The save-state container shared by every Handyplay core
    // (vendor/statefmt, ADR D5). Vendored verbatim so it can be re-synced
    // from handyplay-oss/common without a merge.
    const statefmt_mod = b.createModule(.{
        .root_source_file = b.path("vendor/statefmt/statefmt.zig"),
        .target = target,
        .optimize = optimize,
    });
    flash_mod.addImport("statefmt", statefmt_mod);

    // --- MP3 (M6) ----------------------------------------------------------
    // The vendored minimp3 (vendor/minimp3, CC0) behind the flat shim in
    // core/codecs/mp3_impl.c — the one dependency this project takes, and
    // the format every embedded sound in `games/` uses. `-Dmp3=false`
    // compiles the C out entirely: MP3s then decode to nothing and play
    // silent, while durations and completion timing are unchanged, since
    // those come from the header walk and the mixer's own clock.
    const want_mp3 = b.option(bool, "mp3", "Compile the vendored minimp3 decoder (C, needs libc)") orelse true;
    const flash_opts = b.addOptions();
    flash_opts.addOption(bool, "mp3_enabled", want_mp3);
    flash_mod.addOptions("build_options", flash_opts);
    if (want_mp3) {
        flash_mod.link_libc = true;
        flash_mod.addIncludePath(b.path("vendor/minimp3"));
        flash_mod.addCSourceFile(.{
            .file = b.path("core/codecs/mp3_impl.c"),
            .flags = &.{"-O2"},
        });
    }

    // Recorded-input replay, shared by the two harness frontends: the
    // trace runner scores text, the SDL frontend's headless mode scores
    // pixels, and both have to feed the same `input.json`.
    const replay_mod = b.createModule(.{
        .root_source_file = b.path("tools/input_replay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "flash", .module = flash_mod }},
    });

    // --- tools -------------------------------------------------------------
    const Tool = struct { name: []const u8, src: []const u8 };
    const tools = [_]Tool{
        .{ .name = "swfinfo", .src = "tools/swfinfo.zig" },
        .{ .name = "swfdump", .src = "tools/swfdump.zig" },
        .{ .name = "trace_runner", .src = "tools/trace_runner.zig" },
        .{ .name = "dumptext", .src = "tools/dumptext.zig" },
    };
    for (tools) |t| {
        const mod = b.createModule(.{
            .root_source_file = b.path(t.src),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flash", .module = flash_mod },
                .{ .name = "input_replay", .module = replay_mod },
            },
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

    // --- SDL3 frontend (separate step — needs Homebrew SDL3) --------------
    {
        const sdl_mod = b.createModule(.{
            .root_source_file = b.path("frontends/sdl/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "flash", .module = flash_mod },
                .{ .name = "input_replay", .module = replay_mod },
            },
        });
        sdl_mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        sdl_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        sdl_mod.linkSystemLibrary("SDL3", .{});
        const exe = b.addExecutable(.{ .name = "handyplay-flash-sdl", .root_module = sdl_mod });
        const inst = b.addInstallArtifact(exe, .{});
        b.step("sdl", "Build the SDL3 frontend").dependOn(&inst.step);
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        b.step("run-sdl", "Run the SDL3 frontend").dependOn(&run.step);
    }

    // --- native libretro core (retro_* C ABI shared library) ---------------
    // `zig build libretro` -> zig-out/libretro/flash_libretro.{dylib,so,dll}.
    // Same `flash` module the SDL player uses; this is only the host seam.
    {
        const lr_mod = b.createModule(.{
            .root_source_file = b.path("frontends/libretro/core.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true, // c_allocator: the frontend owns the process
            .imports = &.{
                .{ .name = "flash", .module = flash_mod },
                // The boot shell draws real type; simdra's stb_truetype
                // binding is what rasterises it.
                .{ .name = "simdra", .module = simdra_mod },
            },
        });
        // Poppins Medium (SIL OFL) — see vendor/fonts/OFL.txt. Embedded
        // because RetroArch ships no font a core may use and a system
        // font is not ours to ship.
        lr_mod.addAnonymousImport("font", .{
            .root_source_file = b.path("vendor/fonts/Poppins-Medium.ttf"),
        });
        lr_mod.strip = want_strip;
        androidSysroot(b, lr_mod, target, android_api);
        const lrlib = b.addLibrary(.{
            .name = "flash_libretro",
            .root_module = lr_mod,
            .linkage = .dynamic,
        });
        const ext = switch (target.result.os.tag) {
            .windows => "dll",
            .macos, .ios, .tvos, .watchos => "dylib",
            else => "so",
        };
        // `dest_sub_path` because zig would name it `libflash_libretro.dylib`
        // and a libretro frontend looks for the bare name.
        const inst = b.addInstallArtifact(lrlib, .{
            .dest_dir = .{ .override = .{ .custom = "libretro" } },
            .dest_sub_path = b.fmt("flash_libretro.{s}", .{ext}),
        });
        b.step("libretro", "Build the native libretro core (shared library)").dependOn(&inst.step);

        // The harness that exercises the core through its real C ABI —
        // dlopen, load, run, press a pad button — so the core is testable
        // without installing RetroArch.
        const host_mod = b.createModule(.{
            .root_source_file = b.path("frontends/libretro/test_host.zig"),
            .target = target,
            .optimize = optimize,
        });
        const host = b.addExecutable(.{ .name = "libretro_test_host", .root_module = host_mod });
        const host_inst = b.addInstallArtifact(host, .{});
        const host_step = b.step("libretro-test", "Build the dlopen harness for the libretro core");
        host_step.dependOn(&host_inst.step);
        host_step.dependOn(&inst.step);
    }

    // --- tests -------------------------------------------------------------
    const test_step = b.step("test", "Run unit tests");
    const core_tests = b.addTest(.{ .root_module = flash_mod });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
}

/// Point a module at the Android NDK's sysroot. Zig ships a libc for
/// every target it supports EXCEPT Bionic, so an Android build is the one
/// that needs an external SDK: `--sysroot
/// $NDK/toolchains/llvm/prebuilt/<host>/sysroot`, whose layout is
/// `usr/include`, `usr/include/<triple>` and `usr/lib/<triple>/<api>`.
///
/// The triple in those paths is NOT always the one zig names the target
/// with: 32-bit x86 is `i686-linux-android` there, and 32-bit ARM is
/// `arm-linux-androideabi` for both the headers and the libraries even
/// though the ABI everyone calls it by is `armeabi-v7a`.
fn androidSysroot(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    api: u32,
) void {
    const t = target.result;
    if (t.abi != .android and t.abi != .androideabi) return;
    const sysroot = b.sysroot orelse {
        std.debug.print(
            "android: pass --sysroot $NDK/toolchains/llvm/prebuilt/<host>/sysroot\n",
            .{},
        );
        std.process.exit(1);
    };
    const triple = switch (t.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => std.debug.panic("android: unsupported arch {s}", .{@tagName(t.cpu.arch)}),
    };
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sysroot}) });
    mod.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include/{s}", .{ sysroot, triple }) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}/{d}", .{ sysroot, triple, api }) });
    mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib/{s}", .{ sysroot, triple }) });
}
