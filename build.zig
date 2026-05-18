const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_noop = optimize == .Debug;
    const enable_sdl3 = b.option(bool, "sdl3", "Enable SDL3 integration (used for testing, but definitely usable)") orelse true;
    const enable_splat = b.option(bool, "splat", "Expose the optional splat shader translation module") orelse true;
    const enable_vulkan = b.option(bool, "vulkan", "Enable the Vulkan backend") orelse true;
    const enable_dx12 = b.option(bool, "dx12", "Enable the DirectX 12 backend") orelse true;
    const enable_metal = b.option(bool, "metal", "Enable the Metal backend") orelse true;
    const enable_browser_webgpu = b.option(bool, "browser_webgpu", "Enable the browser WebGPU backend") orelse true;
    const enable_opengl = b.option(bool, "opengl", "Enable the OpenGL/WebGL backend") orelse false;
    const enable_noop = b.option(bool, "noop", "Enable the noop backend") orelse default_noop;

    const mod = b.addModule("vitellus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(bool, "enable_splat", enable_splat);
    options.addOption(bool, "enable_sdl3", enable_sdl3);
    options.addOption(bool, "enable_backend_vulkan", enable_vulkan);
    options.addOption(bool, "enable_backend_dx12", enable_dx12);
    options.addOption(bool, "enable_backend_metal", enable_metal);
    options.addOption(bool, "enable_backend_browser_webgpu", enable_browser_webgpu);
    options.addOption(bool, "enable_backend_opengl", enable_opengl);
    options.addOption(bool, "enable_backend_noop", enable_noop);
    mod.addOptions("build_options", options);

    // --- imports ---

    const candler = b.dependency("candler", .{
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("candler", candler.module("candler"));

    const logz = b.dependency("logz", .{
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("logz", logz.module("logz"));

    const vulkan = if (enable_vulkan) vulkan: {
        const headers = b.lazyDependency("vulkan_headers", .{}) orelse break :vulkan null;
        const dep = b.lazyDependency("vulkan", .{
            .registry = headers.path("registry/vk.xml"),
        }) orelse break :vulkan null;
        break :vulkan dep.module("vulkan-zig");
    } else null;

    if (vulkan) |vulkan_mod| {
        mod.addImport("vulkan", vulkan_mod);
    }

    const sdl3 = if (enable_sdl3) b.lazyDependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    }) else null;

    if (sdl3) |dep| {
        mod.addImport("sdl3", dep.module("sdl3"));
    }

    if (enable_splat) {
        if (b.lazyDependency("splat", .{
            .target = target,
            .optimize = optimize,
        })) |dep| {
            const splat_mod = b.addModule("splat", .{
                .root_source_file = dep.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
            });
            mod.addImport("splat", splat_mod);
        }
    }

    // ---------------

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("vitellus", mod);
    exe_mod.addImport("candler", candler.module("candler"));
    exe_mod.addOptions("build_options", options);
    if (vulkan) |vulkan_mod| {
        exe_mod.addImport("vulkan", vulkan_mod);
    }
    if (sdl3) |dep| {
        exe_mod.addImport("sdl3", dep.module("sdl3"));
    }

    const exe = b.addExecutable(.{
        .name = "vitellus",
        .root_module = exe_mod,
        .use_llvm = true, // keep this there for the time-being
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
    example_test_mod.addImport("logz", logz.module("logz"));
    example_test_mod.addOptions("build_options", options);
    if (vulkan) |vulkan_mod| {
        example_test_mod.addImport("vulkan", vulkan_mod);
    }
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
