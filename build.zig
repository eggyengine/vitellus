const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_dx12_requested = b.option(bool, "dx12", "Enable the DirectX 12 backend") orelse true;
    const enable_dx12 = enable_dx12_requested and target.result.os.tag == .windows;

    const mod = b.addModule("vitellus", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const candler = b.dependency("candler", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl = b.dependency("sdl3", .{
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("candler", candler.module("candler"));
    mod.addImport("sdl3", sdl.module("sdl3"));

    if (enable_dx12) {
        if (b.lazyDependency("directx-headers", .{})) |dep| {
            mod.addIncludePath(dep.path("include/directx"));
        }
        mod.linkSystemLibrary("dxgi", .{});
        mod.linkSystemLibrary("d3d12", .{});
    }

    const exe = b.addExecutable(.{
        .name = "vitellus",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "vitellus", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("sdl3", sdl.module("sdl3"));

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
