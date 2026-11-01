//! Shader-visible resources grouped by explicit binding layouts.

const resource = @import("resource.zig");
const shader = @import("shader.zig");

/// Pipeline stages that may access a binding.
pub const ShaderVisibility = packed struct(u32) {
    vertex: bool = false,
    fragment: bool = false,
    compute: bool = false,
    _pad: u29 = 0,
};

pub const BufferBindingType = enum { uniform, storage_read, storage_read_write };
pub const TextureSampleType = enum { float_filterable, float_unfilterable, sint, uint, depth };
pub const StorageTextureAccess = enum { read, write, read_write };
pub const SamplerBindingType = enum { filtering, non_filtering, comparison };
pub const SampledTextureBindingLayout = struct { sample_type: TextureSampleType = .float_filterable, dimension: resource.TextureViewDimension = .d2, multisampled: bool = false };

/// Resource represented by a bind-group entry, including the validation data
/// needed by Vulkan, Metal, and DirectX 12.
pub const BindingType = union(enum) {
    buffer: struct { kind: BufferBindingType = .uniform, dynamic_offset: bool = false, min_size: u64 = 0 },
    sampled_texture: SampledTextureBindingLayout,
    combined_texture_sampler: SampledTextureBindingLayout,
    storage_texture: struct { access: StorageTextureAccess = .write, format: resource.Format, dimension: resource.TextureViewDimension = .d2 },
    sampler: SamplerBindingType,
};

/// One binding declared by shaders and a pipeline layout.
pub const BindGroupLayoutEntry = struct {
    binding: u32,
    kind: BindingType,
    visibility: ShaderVisibility,
    count: u32 = 1,
};

/// Ordered set of bindings accepted by one bind-group slot.
pub const BindGroupLayoutDescriptor = struct {
    label: ?[]const u8 = null,
    entries: []const BindGroupLayoutEntry = &.{},
    shader: ?shader.Shader = null,
    set: u32 = 0,
};

/// Opaque backend bind-group-layout handle.
pub const BindGroupLayout = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (BindGroupLayout) void };

    /// Declare the bindings one bind-group slot holds, for pipeline layouts and bind groups to
    /// match. Destroy it after every pipeline layout and bind group that uses it.
    pub fn init(device: anytype, desc: BindGroupLayoutDescriptor) !BindGroupLayout {
        return if (device.vtable.createBindGroupLayoutFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the layout.
    pub fn deinit(self: BindGroupLayout) void {
        self.vtable.deinitFn(self);
    }
};

/// Range of a buffer exposed to a shader.
pub const BufferBinding = struct {
    buffer: resource.Buffer,
    offset: u64 = 0,
    size: ?u64 = null,
};

/// Resource stored in one bind-group entry.
pub const BindingResource = union(enum) {
    buffer: BufferBinding,
    texture_view: resource.TextureView,
    sampler: resource.Sampler,
    combined_texture_sampler: struct { view: resource.TextureView, sampler: resource.Sampler },
};

/// Resource assigned to a numbered layout binding.
pub const BindGroupEntry = struct {
    binding: u32,
    array_element: u32 = 0,
    resource: BindingResource,
};

/// Layout and resources used to create a bind group.
pub const BindGroupDescriptor = struct {
    label: ?[]const u8 = null,
    layout: BindGroupLayout,
    entries: []const BindGroupEntry,
};

/// Opaque backend bind-group handle.
pub const BindGroup = struct {
    handle: u64 = 0,
    vtable: *const VTable,
    pub const VTable = struct { deinitFn: *const fn (BindGroup) void };

    /// Bind resources to `desc.layout`'s bindings. Every binding the layout declares needs an
    /// entry; the resources must outlive the group and the GPU's use of it.
    pub fn init(device: anytype, desc: BindGroupDescriptor) !BindGroup {
        return if (device.vtable.createBindGroupFn) |f| f(device.ptr, desc) else error.Unsupported;
    }
    /// Destroy the group. Command buffers that set it must have finished on the GPU.
    pub fn deinit(self: BindGroup) void {
        self.vtable.deinitFn(self);
    }
};

const std = @import("std");
// Doc tests below: Zig's generated docs show each one as its type's example, and
// `zig build test` runs it, on the machine's GPU when it has one.
const vit = @import("../root.zig");
const ExampleGpu = @import("example_gpu.zig");

test BindGroupLayout {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();

    // The shape of what a shader reads, by binding number: uniforms at 0 for both stages,
    // then a texture and its sampler at 1 and 2 for the fragment shader.
    const layout = try vit.BindGroupLayout.init(gpu.device, .{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
        .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        .{ .binding = 2, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
    } });
    defer layout.deinit();
}

test BindGroup {
    const gpu = try ExampleGpu.open(.{});
    defer gpu.close();
    const layout = try vit.BindGroupLayout.init(gpu.device, .{ .entries = &.{
        .{ .binding = 0, .kind = .{ .buffer = .{ .kind = .uniform } }, .visibility = .{ .vertex = true, .fragment = true } },
        .{ .binding = 1, .kind = .{ .sampled_texture = .{} }, .visibility = .{ .fragment = true } },
        .{ .binding = 2, .kind = .{ .sampler = .filtering }, .visibility = .{ .fragment = true } },
    } });
    defer layout.deinit();

    const uniforms = try vit.Buffer.init(gpu.device, .{ .size = 256, .usage = .{ .uniform = true }, .memory = .upload });
    defer uniforms.deinit();
    const pixel = [4]u8{ 255, 255, 255, 255 };
    const texture = try vit.Texture.init(gpu.device, .{ .width = 1, .height = 1, .format = .rgba8_unorm, .usage = .{ .sampled = true }, .initial_data = &pixel });
    defer texture.deinit();
    const view = try vit.TextureView.init(gpu.device, .{ .texture = texture });
    defer view.deinit();
    const sampler = try vit.Sampler.init(gpu.device, .{});
    defer sampler.deinit();

    // The resources themselves, one per layout entry. Bind with
    // `cmd.setBindGroup(0, group, &.{})`; the resources must outlive the group's use.
    const group = try vit.BindGroup.init(gpu.device, .{ .layout = layout, .entries = &.{
        .{ .binding = 0, .resource = .{ .buffer = .{ .buffer = uniforms } } },
        .{ .binding = 1, .resource = .{ .texture_view = view } },
        .{ .binding = 2, .resource = .{ .sampler = sampler } },
    } });
    defer group.deinit();
}
