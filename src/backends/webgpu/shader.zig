//! WGSL shader modules.

const std = @import("std");
const c = @import("webgpu_c");
const shader_if = @import("../../interface/shader.zig");
const ptrOf = @import("utils.zig").ptrOf;

pub const WgpuShader = struct {
    allocator: std.mem.Allocator,
    module: c.WGPUShaderModule,
    entry_point: []u8,

    pub const vtable: shader_if.Shader.VTable = .{ .deinitFn = deinit };

    fn deinit(value: shader_if.Shader) void {
        const self = ptrOf(WgpuShader, value.handle);
        c.wgpuShaderModuleRelease(self.module);
        self.allocator.free(self.entry_point);
        self.allocator.destroy(self);
    }
};
