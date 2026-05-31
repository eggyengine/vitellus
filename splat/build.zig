const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("splat", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const spirv_cross = b.dependency("spirv-cross", .{
        .target = target,
        .optimize = optimize,
    });
    const spirv_cross_root = spirv_cross.path("");

    const spirv_cross_lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
    });
    spirv_cross_lib_mod.addIncludePath(spirv_cross_root);
    spirv_cross_lib_mod.addCMacro("SPIRV_CROSS_C_API_GLSL", "1");
    spirv_cross_lib_mod.addCMacro("SPIRV_CROSS_C_API_HLSL", "1");
    spirv_cross_lib_mod.addCMacro("SPIRV_CROSS_C_API_MSL", "1");
    spirv_cross_lib_mod.addCMacro("SPIRV_CROSS_C_API_CPP", "1");
    spirv_cross_lib_mod.addCMacro("SPIRV_CROSS_C_API_REFLECT", "1");
    spirv_cross_lib_mod.addCSourceFiles(.{
        .root = spirv_cross_root,
        .files = &.{
            "spirv_cross.cpp",
            "spirv_parser.cpp",
            "spirv_cross_parsed_ir.cpp",
            "spirv_cfg.cpp",
            "spirv_glsl.cpp",
            "spirv_hlsl.cpp",
            "spirv_msl.cpp",
            "spirv_cpp.cpp",
            "spirv_reflect.cpp",
            "spirv_cross_util.cpp",
            "spirv_cross_c.cpp",
        },
        .flags = &.{"-std=c++17"},
        .language = .cpp,
    });

    const spirv_cross_lib = b.addLibrary(.{
        .name = "spirv-cross-c",
        .root_module = spirv_cross_lib_mod,
    });

    const translate_spirv_cross = b.addTranslateC(.{
        .root_source_file = spirv_cross.path("spirv_cross_c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_spirv_cross.addIncludePath(spirv_cross_root);

    const spirv_cross_mod = translate_spirv_cross.createModule();
    spirv_cross_mod.linkLibrary(spirv_cross_lib);
    spirv_cross_mod.link_libcpp = true;

    mod.addImport("spirv_cross", spirv_cross_mod);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
