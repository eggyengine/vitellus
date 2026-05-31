const std = @import("std");
const hal = @import("../backends/hal.zig");
const pipeline = @import("pipeline.zig");

pub const ShaderModule = struct {
    backend: ?hal.ShaderModule = null,
    label: ?[*:0]const u8 = null,

    pub const CompilationInfoError = error{NotImplemented};

    pub const ShaderSource = union(enum) {
        spirv: []const u8,
    };

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        source: ShaderSource,
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
        layout: ?*const pipeline.PipelineLayout = null,
    };

    pub fn getCompilationInfo(self: *@This(), io: std.Io) std.Io.Future(CompilationInfoError!CompilationInfo) {
        return io.async(getCompilationInfoInternal, .{ self, io });
    }

    fn getCompilationInfoInternal(self: *@This(), io: std.Io) CompilationInfoError!CompilationInfo {
        if (self.backend) |backend| {
            var future = backend.getCompilationInfo(io);
            defer _ = future.cancel(io) catch {};
            return future.await(io) catch error.NotImplemented;
        }
        return .{};
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
