const std = @import("std");
const hal = @import("../backends/hal.zig");
const pipeline = @import("pipeline.zig");

pub const ShaderModule = struct {
    backend: ?hal.ShaderModule = null,
    label: ?[*:0]const u8 = null,

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

    pub fn destroy(self: *@This()) void {
        if (self.backend) |backend| {
            backend.destroy();
            self.backend = null;
        }
    }

    pub fn deinit(self: *@This()) void {
        self.destroy();
    }
};
