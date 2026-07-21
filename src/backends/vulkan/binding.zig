const std = @import("std");
const vk = @import("vulkan");
const binding = @import("../../interface/binding.zig");
const vkDevice = @import("device.zig").vkDevice;
const resource_impl = @import("resource.zig");

pub const vkBindGroupLayout = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    handle: vk.DescriptorSetLayout,
    entries: []binding.BindGroupLayoutEntry,

    pub fn fromHandle(value: binding.BindGroupLayout) !*vkBindGroupLayout {
        if (value.handle == 0) return error.InvalidBindGroupLayout;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const vkBindGroup = struct {
    allocator: std.mem.Allocator,
    device: vk.DeviceProxy,
    pool: vk.DescriptorPool,
    set: vk.DescriptorSet,

    pub fn fromHandle(value: binding.BindGroup) !*vkBindGroup {
        if (value.handle == 0) return error.InvalidBindGroup;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

const layout_vtable: binding.BindGroupLayout.VTable = .{ .deinitFn = destroyLayout };
const group_vtable: binding.BindGroup.VTable = .{ .deinitFn = destroyGroup };

pub fn createLayout(ptr: *anyopaque, desc: binding.BindGroupLayoutDescriptor) !binding.BindGroupLayout {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const native = try device.allocator.alloc(vk.DescriptorSetLayoutBinding, desc.entries.len);
    defer device.allocator.free(native);
    for (desc.entries, native) |entry, *result| {
        if (entry.count == 0) return error.InvalidDescriptorCount;
        result.* = .{
            .binding = entry.binding,
            .descriptor_type = descriptorType(entry.kind),
            .descriptor_count = entry.count,
            .stage_flags = stageFlags(entry.visibility),
        };
    }
    const handle = try device.proxy.createDescriptorSetLayout(&.{
        .binding_count = @intCast(native.len),
        .p_bindings = if (native.len == 0) null else native.ptr,
    }, null);
    errdefer device.proxy.destroyDescriptorSetLayout(handle, null);
    const entries = try device.allocator.dupe(binding.BindGroupLayoutEntry, desc.entries);
    errdefer device.allocator.free(entries);
    const self = try device.allocator.create(vkBindGroupLayout);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .handle = handle, .entries = entries };
    device.instance.nameObject(device.allocator, device.proxy, .descriptor_set_layout, @intFromEnum(handle), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &layout_vtable };
}

pub fn createGroup(ptr: *anyopaque, desc: binding.BindGroupDescriptor) !binding.BindGroup {
    const device: *vkDevice = @ptrCast(@alignCast(ptr));
    const layout = try vkBindGroupLayout.fromHandle(desc.layout);
    const pool_sizes = try device.allocator.alloc(vk.DescriptorPoolSize, layout.entries.len);
    defer device.allocator.free(pool_sizes);
    for (layout.entries, pool_sizes) |entry, *size| size.* = .{
        .type = descriptorType(entry.kind),
        .descriptor_count = entry.count,
    };
    const pool = try device.proxy.createDescriptorPool(&.{
        .max_sets = 1,
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = if (pool_sizes.len == 0) null else pool_sizes.ptr,
    }, null);
    errdefer device.proxy.destroyDescriptorPool(pool, null);
    var set: vk.DescriptorSet = undefined;
    try device.proxy.allocateDescriptorSets(&.{
        .descriptor_pool = pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&layout.handle),
    }, @ptrCast(&set));

    const buffer_infos = try device.allocator.alloc(vk.DescriptorBufferInfo, desc.entries.len);
    defer device.allocator.free(buffer_infos);
    const image_infos = try device.allocator.alloc(vk.DescriptorImageInfo, desc.entries.len);
    defer device.allocator.free(image_infos);
    const writes = try device.allocator.alloc(vk.WriteDescriptorSet, desc.entries.len);
    defer device.allocator.free(writes);
    for (desc.entries, 0..) |entry, index| {
        const layout_entry = findEntry(layout.entries, entry.binding) orelse return error.UnknownBinding;
        writes[index] = .{
            .dst_set = set,
            .dst_binding = entry.binding,
            .dst_array_element = entry.array_element,
            .descriptor_count = 1,
            .descriptor_type = descriptorType(layout_entry.kind),
            .p_image_info = undefined, .p_buffer_info = undefined, .p_texel_buffer_view = undefined,
        };
        switch (entry.resource) {
            .buffer => |value| {
                const buffer = try resource_impl.vkBuffer.fromHandle(value.buffer);
                const range = value.size orelse buffer.size - value.offset;
                if (value.offset > buffer.size or range == 0 or range > buffer.size - value.offset) return error.InvalidBindingRange;
                buffer_infos[index] = .{ .buffer = buffer.buffer, .offset = value.offset, .range = range };
                writes[index].p_buffer_info = @ptrCast(&buffer_infos[index]);
            },
            .texture_view => |value| {
                const view = try resource_impl.vkTextureView.fromHandle(value);
                image_infos[index] = .{ .sampler = .null_handle, .image_view = view.view, .image_layout = switch (layout_entry.kind) { .storage_texture => .general, else => .shader_read_only_optimal } };
                writes[index].p_image_info = @ptrCast(&image_infos[index]);
            },
            .sampler => |value| {
                image_infos[index] = .{ .sampler = (try resource_impl.vkSampler.fromHandle(value)).handle, .image_view = .null_handle, .image_layout = .undefined };
                writes[index].p_image_info = @ptrCast(&image_infos[index]);
            },
        }
    }
    device.proxy.updateDescriptorSets(writes, null);
    const self = try device.allocator.create(vkBindGroup);
    self.* = .{ .allocator = device.allocator, .device = device.proxy, .pool = pool, .set = set };
    device.instance.nameObject(device.allocator, device.proxy, .descriptor_pool, @intFromEnum(pool), desc.label);
    return .{ .handle = @intCast(@intFromPtr(self)), .vtable = &group_vtable };
}

fn destroyLayout(value: binding.BindGroupLayout) void {
    const self = vkBindGroupLayout.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyDescriptorSetLayout(self.handle, null);
    allocator.free(self.entries);
    allocator.destroy(self);
}

fn destroyGroup(value: binding.BindGroup) void {
    const self = vkBindGroup.fromHandle(value) catch return;
    const allocator = self.allocator;
    self.device.destroyDescriptorPool(self.pool, null);
    allocator.destroy(self);
}

fn findEntry(entries: []const binding.BindGroupLayoutEntry, binding_number: u32) ?binding.BindGroupLayoutEntry {
    for (entries) |entry| if (entry.binding == binding_number) return entry;
    return null;
}

fn descriptorType(kind: binding.BindingType) vk.DescriptorType {
    return switch (kind) {
        .buffer => |value| switch (value.kind) {
            .uniform => if (value.dynamic_offset) .uniform_buffer_dynamic else .uniform_buffer,
            .storage_read, .storage_read_write => if (value.dynamic_offset) .storage_buffer_dynamic else .storage_buffer,
        },
        .sampled_texture => .sampled_image,
        .storage_texture => .storage_image,
        .sampler => .sampler,
    };
}

fn stageFlags(visibility: binding.ShaderVisibility) vk.ShaderStageFlags {
    return .{
        .vertex_bit = visibility.vertex,
        .fragment_bit = visibility.fragment,
        .compute_bit = visibility.compute,
    };
}
