//! Builds the guide's full program from src/ (written there by check.sh).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vit = b.dependency("vitellus", .{ .target = target, .optimize = optimize });
    const sdl3 = b.dependency("sdl3", .{ .target = target, .optimize = optimize });
    const vitellus_sdl3 = b.createModule(.{
        .root_source_file = vit.path("src/windowing/sdl3.zig"),
        .target = target,
        .optimize = optimize,
    });
    vitellus_sdl3.addImport("vitellus", vit.module("vitellus"));
    vitellus_sdl3.addImport("sdl3", sdl3.module("sdl3"));
    const exe = b.addExecutable(.{
        .name = "example",
        // Zig 0.16's self-hosted linker rejects R_X86_64_PC64 in glibc/GCC .sframe.
        .use_llvm = target.result.os.tag == .linux,
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });
    exe.root_module.addImport("vitellus", vit.module("vitellus"));
    exe.root_module.addImport("vitellus_spirv", vit.module("vitellus_spirv"));
    exe.root_module.addImport("vitellus_sdl3", vitellus_sdl3);
    exe.root_module.addImport("sdl3", sdl3.module("sdl3"));
    b.installArtifact(exe);
}
