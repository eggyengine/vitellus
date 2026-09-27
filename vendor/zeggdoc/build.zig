const std = @import("std");

/// Add the generator to a build step, passing `b.dependency("zeggdoc", .{}).path(".")`.
/// Read the [cross-reference guide](#guide=04-cross-references%2Findex).
pub fn addDocsStep(b: *std.Build, package_root: std.Build.LazyPath) *std.Build.Step {
    return addDocsStepWithOptions(b, package_root, .{});
}

pub const DocsOptions = struct {
    exclude: []const []const u8 = &.{},
};

/// Add the generator with project-relative paths or globs to exclude.
pub fn addDocsStepWithOptions(b: *std.Build, package_root: std.Build.LazyPath, options: DocsOptions) *std.Build.Step {
    const install = b.addSystemCommand(&.{ "bun", "install", "--frozen-lockfile" });
    install.setCwd(package_root);

    const command = b.addSystemCommand(&.{ "bun", "run", "cli/index.ts" });
    command.setCwd(package_root);
    command.addDirectoryArg(b.path("."));
    for (options.exclude) |pattern| {
        command.addArgs(&.{ "--exclude", pattern });
    }
    command.step.dependOn(&install.step);
    return &command.step;
}

pub fn build(b: *std.Build) void {
    b.step("doc", "Generate documentation").dependOn(addDocsStep(b, b.path(".")));
}
