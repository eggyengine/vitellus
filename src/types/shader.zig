const std = @import("std");
const pipeline = @import("pipeline.zig");

pub const ShaderModule = struct {
    pub const CompilationInfoError = error{NotImplemented};

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        code: []const u8,
        compilation_hints: []const CompilationHint = &.{},
    };

    pub const CompilationInfo = struct {
        messages: []const CompilationMessage = &.{},
    };

    pub const CompilationMessage = struct {
        message: []const u8,
        type: CompilationMessageType,
        lineNum: u64 = 0,
        linePos: u64 = 0,
        offset: u64 = 0,
        length: u64 = 0,
    };

    pub const CompilationMessageType = enum {
        @"error",
        warning,
        info,
    };

    pub const CompilationHint = struct {
        entry_point: []const u8,
        layout: ?Layout = null,

        pub const Layout = union(enum) {
            pipeline: *const pipeline.PipelineLayout,
            auto: AutoLayoutMode,
        };
    };

    pub const AutoLayoutMode = enum {
        auto,
    };

    pub fn getCompilationInfo(self: *@This(), io: std.Io) std.Io.Future(CompilationInfoError!CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{self});
    }

    fn getCompilationInfoInternal(self: *@This()) CompilationInfoError!CompilationInfo {
        _ = self;
        return error.NotImplemented;
    }
};
