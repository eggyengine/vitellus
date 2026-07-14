const std = @import("std");
const Queue = @import("queue.zig").Queue;
const QueueDescriptor = @import("queue.zig").QueueDescriptor;
const ValidationLevel = @import("settings.zig").ValidationLevel;
const shader = @import("shader.zig");
const resource = @import("resource.zig");
const pipeline = @import("pipeline.zig");
const command = @import("command.zig");

pub const DeviceDescriptor = struct {
    validation: ValidationLevel = .none,
};

pub const Device = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    allocator: std.mem.Allocator,

    pub const VTable = struct {
        deinitFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
        createQueueFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) anyerror!Queue,
        createShaderFn: ?*const fn (*anyopaque, std.mem.Allocator, shader.ShaderDescriptor) anyerror!shader.Shader = null,
        createBufferFn: ?*const fn (*anyopaque, resource.BufferDescriptor) anyerror!resource.Buffer = null,
        createGraphicsPipelineFn: ?*const fn (*anyopaque, pipeline.GraphicsPipelineDescriptor) anyerror!pipeline.GraphicsPipeline = null,
        createCommandPoolFn: ?*const fn (*anyopaque, command.CommandPoolDescriptor) anyerror!command.CommandPool = null,
        createCommandBufferFn: ?*const fn (*anyopaque, command.CommandPool) anyerror!command.CommandBuffer = null,
        destroyShaderFn: ?*const fn (*anyopaque, shader.Shader) void = null,
        destroyBufferFn: ?*const fn (*anyopaque, resource.Buffer) void = null,
        destroyGraphicsPipelineFn: ?*const fn (*anyopaque, pipeline.GraphicsPipeline) void = null,
        destroyCommandPoolFn: ?*const fn (*anyopaque, command.CommandPool) void = null,
    };

    pub fn createQueue(self: Device, desc: QueueDescriptor) !Queue {
        return self.vtable.createQueueFn(self.ptr, self.allocator, desc);
    }

    pub fn createShader(self: Device, desc: shader.ShaderDescriptor) !shader.Shader {
        return if (self.vtable.createShaderFn) |f| f(self.ptr, self.allocator, desc) else error.Unsupported;
    }
    pub fn createBuffer(self: Device, desc: resource.BufferDescriptor) !resource.Buffer {
        return if (self.vtable.createBufferFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    pub fn createGraphicsPipeline(self: Device, desc: pipeline.GraphicsPipelineDescriptor) !pipeline.GraphicsPipeline {
        return if (self.vtable.createGraphicsPipelineFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    pub fn createCommandPool(self: Device, desc: command.CommandPoolDescriptor) !command.CommandPool {
        return if (self.vtable.createCommandPoolFn) |f| f(self.ptr, desc) else error.Unsupported;
    }
    pub fn createCommandBuffer(self: Device, pool: command.CommandPool) !command.CommandBuffer {
        return if (self.vtable.createCommandBufferFn) |f| f(self.ptr, pool) else error.Unsupported;
    }
    pub fn destroyShader(self: Device, value: shader.Shader) void {
        if (self.vtable.destroyShaderFn) |f| f(self.ptr, value);
    }
    pub fn destroyBuffer(self: Device, value: resource.Buffer) void {
        if (self.vtable.destroyBufferFn) |f| f(self.ptr, value);
    }
    pub fn destroyGraphicsPipeline(self: Device, value: pipeline.GraphicsPipeline) void {
        if (self.vtable.destroyGraphicsPipelineFn) |f| f(self.ptr, value);
    }
    pub fn destroyCommandPool(self: Device, value: command.CommandPool) void {
        if (self.vtable.destroyCommandPoolFn) |f| f(self.ptr, value);
    }

    pub fn deinit(self: Device) void {
        self.vtable.deinitFn(self.ptr, self.allocator);
    }
};
