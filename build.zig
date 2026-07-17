const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_dx12_requested = b.option(bool, "dx12", "Enable the DirectX 12 backend") orelse true;
    const enable_dx12 = enable_dx12_requested and target.result.os.tag == .windows;
    var dxc_bin_dir: ?std.Build.LazyPath = null;

    const enable_vk = b.option(bool, "vk", "Enable Vulkan backend") orelse true;

    const mod = b.addModule("vitellus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const candler = b.dependency("candler", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("candler", candler.module("candler"));

    // todo: make the sdl windowing stuff separate to vitellus core
    const sdl = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("sdl3", sdl.module("sdl3"));

    // directx
    if (enable_dx12) {
        if (b.lazyDependency("directx-headers", .{})) |dep| {
            mod.addIncludePath(dep.path("include/directx"));
        }
        if (b.lazyDependency("directx-shader-compiler", .{})) |dep| {
            const dxc_arch = switch (target.result.cpu.arch) {
                .x86 => "x86",
                .x86_64 => "x64",
                .aarch64 => "arm64",
                else => @panic("DXC has no prebuilt binary for this Windows architecture"),
            };
            const bin_dir = dep.path(b.fmt("bin/{s}", .{dxc_arch}));
            dxc_bin_dir = bin_dir;
            mod.addIncludePath(dep.path("inc"));
            mod.addLibraryPath(dep.path(b.fmt("lib/{s}", .{dxc_arch})));
            mod.linkSystemLibrary("dxcompiler", .{});

            const install_dxcompiler = b.addInstallFile(
                dep.path(b.fmt("bin/{s}/dxcompiler.dll", .{dxc_arch})),
                "bin/dxcompiler.dll",
            );
            const install_dxil = b.addInstallFile(
                dep.path(b.fmt("bin/{s}/dxil.dll", .{dxc_arch})),
                "bin/dxil.dll",
            );
            b.getInstallStep().dependOn(&install_dxcompiler.step);
            b.getInstallStep().dependOn(&install_dxil.step);
        }
        mod.linkSystemLibrary("dxgi", .{});
        mod.linkSystemLibrary("d3d12", .{});
    }

    // vulkan
    if (enable_vk) {
        const vulkan = b.lazyDependency("vulkan", .{
            .registry = b.lazyDependency("vulkan_headers", .{}).?.path("registry/vk.xml"),
        }).?.module("vulkan-zig");
        mod.addImport("vulkan", vulkan);
    }

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/bin/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "vitellus", .module = mod }, .{ .name = "sdl3", .module = sdl.module("sdl3") } },
    });

    // run step
    {
        const exe = b.addExecutable(.{
            .name = "vitellus",
            .root_module = exe_mod,
        });

        b.installArtifact(exe);
        const run_step = b.step("run", "Run the app");

        const run_cmd = b.addRunArtifact(exe);
        if (dxc_bin_dir) |dir| run_cmd.addPathDir(dir.getPath(b));
        run_step.dependOn(&run_cmd.step);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
    }

    // check step
    // required by zls
    {
        const exe_check = b.addExecutable(.{
            .name = "vitellus",
            .root_module = exe_mod,
        });
        const check = b.step("check", "Check if vitellus compiles");
        check.dependOn(&exe_check.step);
    }

    // triangle example in [example/] folder
    // might need to remove (its not really necessary)
    {
        const triangle = b.addExecutable(.{
            .name = "vitellus-triangle",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/triangle.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "vitellus", .module = mod },
                    .{ .name = "sdl3", .module = sdl.module("sdl3") },
                },
            }),
        });
        const triangle_step = b.step("triangle", "Build the triangle example");
        triangle_step.dependOn(&triangle.step);
    }

    // tests
    {
        const test_runner: std.Build.Step.Compile.TestRunner = .{
            .path = .{ .cwd_relative = b.graph.zig_lib_directory.join(
                b.allocator,
                &.{ "compiler", "test_runner.zig" },
            ) catch @panic("OOM") },
            .mode = .simple,
        };
        const mod_tests = b.addTest(.{
            .root_module = mod,
            .test_runner = test_runner,
        });

        const run_mod_tests = b.addRunArtifact(mod_tests);
        if (dxc_bin_dir) |dir| run_mod_tests.addPathDir(dir.getPath(b));

        const exe_tests = b.addTest(.{
            .root_module = exe_mod,
            .test_runner = test_runner,
        });

        const run_exe_tests = b.addRunArtifact(exe_tests);
        if (dxc_bin_dir) |dir| run_exe_tests.addPathDir(dir.getPath(b));

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);
    }
}
