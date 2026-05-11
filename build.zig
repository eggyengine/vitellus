const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_sdl3 = b.option(bool, "sdl3", "Enable SDL3 integration (used for testing, but definitely usable)") orelse true;

    const mod = b.addModule("vitellus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(bool, "enable_sdl3", enable_sdl3);
    mod.addOptions("build_options", options);

    // --- imports ---

    const candler = b.dependency("candler", .{
        .target = target,
        .optimize = optimize,
    });

    const vulkan = b.dependency("vulkan", .{
        .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
    }).module("vulkan-zig");

    mod.addImport("candler", candler.module("candler"));
    mod.addImport("vulkan", vulkan);

    const sdl3 = if (enable_sdl3) b.lazyDependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    }) else null;

    if (sdl3) |dep| {
        mod.addImport("sdl3", dep.module("sdl3"));
    }

    // ---------------

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vitellus", mod);
    exe_mod.addImport("candler", candler.module("candler"));
    exe_mod.addImport("vulkan", vulkan);
    exe_mod.addOptions("build_options", options);
    if (sdl3) |dep| {
        exe_mod.addImport("sdl3", dep.module("sdl3"));
    }

    const exe = b.addExecutable(.{
        .name = "vitellus",
        .root_module = exe_mod,
        .use_llvm = true,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }

    const run_step = b.step("run", "Run the vitellus executable");
    run_step.dependOn(&run_exe.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.use_llvm = true;

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const example_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_test_mod.addImport("candler", candler.module("candler"));
    example_test_mod.addImport("vulkan", vulkan);
    example_test_mod.addOptions("build_options", options);
    if (sdl3) |dep| {
        example_test_mod.addImport("sdl3", dep.module("sdl3"));
    }

    const example_tests = b.addTest(.{
        .root_module = example_test_mod,
    });
    example_tests.use_llvm = true;

    const run_example_tests = b.addRunArtifact(example_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_example_tests.step);
}
