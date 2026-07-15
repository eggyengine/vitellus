//! DirectX 12 bind-group layouts, descriptors, and samplers.

const std = @import("std");
const binding = @import("../../interface/binding.zig");
const resource_interface = @import("../../interface/resource.zig");
const resource = @import("resource.zig");
const Dx12Device = @import("device.zig").Dx12Device;
const dx = @import("dx.zig").c;

pub const Dx12BindGroupLayout = struct {
    allocator: std.mem.Allocator,
    entries: []binding.BindGroupLayoutEntry,
    resource_count: u32,
    sampler_count: u32,

    pub fn fromHandle(value: binding.BindGroupLayout) !*Dx12BindGroupLayout {
        if (value.handle == 0) return error.InvalidBindGroupLayout;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const Dx12Sampler = struct {
    allocator: std.mem.Allocator,
    desc: dx.D3D12_SAMPLER_DESC,

    pub fn fromHandle(value: resource_interface.Sampler) !*Dx12Sampler {
        if (value.handle == 0) return error.InvalidSampler;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub const Dx12BindGroup = struct {
    allocator: std.mem.Allocator,
    layout: *Dx12BindGroupLayout,
    resources: ?dx.D3D12_GPU_DESCRIPTOR_HANDLE = null,
    samplers: ?dx.D3D12_GPU_DESCRIPTOR_HANDLE = null,
    resource_cpu: ?dx.D3D12_CPU_DESCRIPTOR_HANDLE = null,
    resource_index: u32 = 0,
    resource_count: u32 = 0,
    sampler_index: u32 = 0,
    sampler_count: u32 = 0,
    entries: []binding.BindGroupEntry = &.{},

    pub fn fromHandle(value: binding.BindGroup) !*Dx12BindGroup {
        if (value.handle == 0) return error.InvalidBindGroup;
        return @ptrFromInt(@as(usize, @intCast(value.handle)));
    }
};

pub fn createLayout(ptr: *anyopaque, desc: binding.BindGroupLayoutDescriptor) anyerror!binding.BindGroupLayout {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12BindGroupLayout);
    errdefer device.allocator.destroy(self);
    const entries = try device.allocator.dupe(binding.BindGroupLayoutEntry, desc.entries);
    errdefer device.allocator.free(entries);

    var resource_count: u32 = 0;
    var sampler_count: u32 = 0;
    for (entries, 0..) |entry, i| {
        if (!entry.visibility.vertex and !entry.visibility.fragment and !entry.visibility.compute) return error.EmptyShaderVisibility;
        for (entries[0..i]) |previous| if (previous.binding == entry.binding) return error.DuplicateBinding;
        if (entry.count == 0) return error.EmptyBindingArray;
        if (entry.kind == .sampler) sampler_count += entry.count else resource_count += entry.count;
    }
    self.* = .{
        .allocator = device.allocator,
        .entries = entries,
        .resource_count = resource_count,
        .sampler_count = sampler_count,
    };
    return .{ .handle = @intCast(@intFromPtr(self)) };
}

pub fn destroyLayout(_: *anyopaque, value: binding.BindGroupLayout) void {
    const self = Dx12BindGroupLayout.fromHandle(value) catch return;
    const allocator = self.allocator;
    allocator.free(self.entries);
    allocator.destroy(self);
}

pub fn createSampler(ptr: *anyopaque, desc: resource_interface.SamplerDescriptor) anyerror!resource_interface.Sampler {
    if (desc.max_anisotropy == 0 or desc.lod_min > desc.lod_max) return error.InvalidSamplerDescriptor;
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = try device.allocator.create(Dx12Sampler);
    errdefer device.allocator.destroy(self);
    self.* = .{
        .allocator = device.allocator,
        .desc = .{
            .Filter = filterMode(desc),
            .AddressU = addressMode(desc.address_u),
            .AddressV = addressMode(desc.address_v),
            .AddressW = addressMode(desc.address_w),
            .MipLODBias = 0,
            .MaxAnisotropy = @min(desc.max_anisotropy, 16),
            .ComparisonFunc = if (desc.compare) |op| compareOp(op) else dx.D3D12_COMPARISON_FUNC_ALWAYS,
            .BorderColor = .{ 0, 0, 0, 0 },
            .MinLOD = desc.lod_min,
            .MaxLOD = desc.lod_max,
        },
    };
    return .{ .handle = @intCast(@intFromPtr(self)) };
}

pub fn destroySampler(_: *anyopaque, value: resource_interface.Sampler) void {
    const self = Dx12Sampler.fromHandle(value) catch return;
    self.allocator.destroy(self);
}

pub fn createGroup(ptr: *anyopaque, desc: binding.BindGroupDescriptor) anyerror!binding.BindGroup {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const layout = try Dx12BindGroupLayout.fromHandle(desc.layout);
    if (desc.entries.len != layout.resource_count + layout.sampler_count) return error.BindingCountMismatch;

    const self = try device.allocator.create(Dx12BindGroup);
    self.* = .{ .allocator = device.allocator, .layout = layout, .entries = try device.allocator.dupe(binding.BindGroupEntry, desc.entries) };
    errdefer { device.allocator.free(self.entries); device.allocator.destroy(self); }

    const resource_allocation = if (layout.resource_count > 0) try device.allocateResourceDescriptors(layout.resource_count) else null;
    errdefer if (resource_allocation) |allocation| device.freeResourceDescriptors(allocation.index, allocation.count);
    const sampler_allocation = if (layout.sampler_count > 0) try device.allocateSamplerDescriptors(layout.sampler_count) else null;
    errdefer if (sampler_allocation) |allocation| device.freeSamplerDescriptors(allocation.index, allocation.count);
    if (resource_allocation) |allocation| { self.resources = allocation.gpu; self.resource_cpu = allocation.cpu; self.resource_index = allocation.index; self.resource_count = allocation.count; }
    if (sampler_allocation) |allocation| { self.samplers = allocation.gpu; self.sampler_index = allocation.index; self.sampler_count = allocation.count; }

    const raw_device = device.device.unwrap();
    const resource_stride = raw_device.lpVtbl.*.GetDescriptorHandleIncrementSize.?(raw_device, dx.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const sampler_stride = raw_device.lpVtbl.*.GetDescriptorHandleIncrementSize.?(raw_device, dx.D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER);
    var resource_index: u32 = 0;
    var sampler_index: u32 = 0;
    for (layout.entries) |layout_entry| {
        for (0..layout_entry.count) |array_element| {
        const entry = findEntry(desc.entries, layout_entry.binding, @intCast(array_element)) orelse return error.MissingBinding;
        switch (layout_entry.kind) {
            .buffer => |buffer_layout| {
                const value = switch (entry.resource) {
                    .buffer => |buffer| buffer,
                    else => return error.BindingTypeMismatch,
                };
                const buffer = try resource.Dx12Buffer.fromHandle(value.buffer);
                const size = value.size orelse buffer.size - value.offset;
                const alignment: u64 = if (buffer_layout.kind == .uniform) 256 else 4;
                if (value.offset >= buffer.size or value.offset % alignment != 0 or size == 0 or size > buffer.size - value.offset or size < buffer_layout.min_size) return error.InvalidBufferBinding;
                const cpu = offsetCpu(resource_allocation.?.cpu, resource_index, resource_stride);
                switch (buffer_layout.kind) {
                    .uniform => {
                        const aligned_size = std.mem.alignForward(u64, size, 256);
                        if (aligned_size > buffer.size - value.offset or aligned_size > std.math.maxInt(u32)) return error.BufferBindingTooLarge;
                        raw_device.lpVtbl.*.CreateConstantBufferView.?(raw_device, &.{ .BufferLocation = buffer.resource.unwrap().lpVtbl.*.GetGPUVirtualAddress.?(buffer.resource.unwrap()) + value.offset, .SizeInBytes = @intCast(aligned_size) }, cpu);
                    },
                    .storage_read => {
                        var srv: dx.D3D12_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(dx.D3D12_SHADER_RESOURCE_VIEW_DESC);
                        srv.Format = dx.DXGI_FORMAT_R32_TYPELESS; srv.ViewDimension = dx.D3D12_SRV_DIMENSION_BUFFER; srv.Shader4ComponentMapping = dx.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
                        srv.unnamed_0.Buffer = .{ .FirstElement = value.offset / 4, .NumElements = @intCast(size / 4), .StructureByteStride = 0, .Flags = dx.D3D12_BUFFER_SRV_FLAG_RAW };
                        raw_device.lpVtbl.*.CreateShaderResourceView.?(raw_device, buffer.resource.unwrap(), &srv, cpu);
                    },
                    .storage_read_write => {
                        var uav: dx.D3D12_UNORDERED_ACCESS_VIEW_DESC = std.mem.zeroes(dx.D3D12_UNORDERED_ACCESS_VIEW_DESC);
                        uav.Format = dx.DXGI_FORMAT_R32_TYPELESS; uav.ViewDimension = dx.D3D12_UAV_DIMENSION_BUFFER;
                        uav.unnamed_0.Buffer = .{ .FirstElement = value.offset / 4, .NumElements = @intCast(size / 4), .StructureByteStride = 0, .CounterOffsetInBytes = 0, .Flags = dx.D3D12_BUFFER_UAV_FLAG_RAW };
                        raw_device.lpVtbl.*.CreateUnorderedAccessView.?(raw_device, buffer.resource.unwrap(), null, &uav, cpu);
                    },
                }
                resource_index += 1;
            },
            .sampled_texture => {
                const value = switch (entry.resource) {
                    .texture_view => |view| view,
                    else => return error.BindingTypeMismatch,
                };
                const view = try resource.Dx12TextureView.fromHandle(value);
                const cpu = offsetCpu(resource_allocation.?.cpu, resource_index, resource_stride);
                var srv: dx.D3D12_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(dx.D3D12_SHADER_RESOURCE_VIEW_DESC);
                srv.Format = view.format;
                srv.Shader4ComponentMapping = dx.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
                switch (view.view_dimension) {
                    .d1 => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURE1D;
                        srv.unnamed_0.Texture1D = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .ResourceMinLODClamp = 0 };
                    },
                    .d1_array => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURE1DARRAY;
                        srv.unnamed_0.Texture1DArray = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .FirstArraySlice = view.base_layer, .ArraySize = view.layer_count, .ResourceMinLODClamp = 0 };
                    },
                    .d2 => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURE2D;
                        srv.unnamed_0.Texture2D = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .PlaneSlice = 0, .ResourceMinLODClamp = 0 };
                    },
                    .d2_array => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURE2DARRAY;
                        srv.unnamed_0.Texture2DArray = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .FirstArraySlice = view.base_layer, .ArraySize = view.layer_count, .PlaneSlice = 0, .ResourceMinLODClamp = 0 };
                    },
                    .cube => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURECUBE;
                        srv.unnamed_0.TextureCube = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .ResourceMinLODClamp = 0 };
                    },
                    .cube_array => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURECUBEARRAY;
                        srv.unnamed_0.TextureCubeArray = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .First2DArrayFace = view.base_layer, .NumCubes = view.layer_count / 6, .ResourceMinLODClamp = 0 };
                    },
                    .d3 => {
                        srv.ViewDimension = dx.D3D12_SRV_DIMENSION_TEXTURE3D;
                        srv.unnamed_0.Texture3D = .{ .MostDetailedMip = view.base_mip, .MipLevels = view.mip_count, .ResourceMinLODClamp = 0 };
                    },
                }
                raw_device.lpVtbl.*.CreateShaderResourceView.?(raw_device, view.resource, &srv, cpu);
                resource_index += 1;
            },
            .storage_texture => {
                const value = switch (entry.resource) { .texture_view => |view| view, else => return error.BindingTypeMismatch };
                const view = try resource.Dx12TextureView.fromHandle(value);
                const cpu = offsetCpu(resource_allocation.?.cpu, resource_index, resource_stride);
                var uav: dx.D3D12_UNORDERED_ACCESS_VIEW_DESC = std.mem.zeroes(dx.D3D12_UNORDERED_ACCESS_VIEW_DESC);
                uav.Format = view.format;
                switch (view.view_dimension) {
                    .d1 => { uav.ViewDimension = dx.D3D12_UAV_DIMENSION_TEXTURE1D; uav.unnamed_0.Texture1D.MipSlice = view.base_mip; },
                    .d1_array => { uav.ViewDimension = dx.D3D12_UAV_DIMENSION_TEXTURE1DARRAY; uav.unnamed_0.Texture1DArray = .{ .MipSlice = view.base_mip, .FirstArraySlice = view.base_layer, .ArraySize = view.layer_count }; },
                    .d2 => { uav.ViewDimension = dx.D3D12_UAV_DIMENSION_TEXTURE2D; uav.unnamed_0.Texture2D = .{ .MipSlice = view.base_mip, .PlaneSlice = 0 }; },
                    .d2_array, .cube, .cube_array => { uav.ViewDimension = dx.D3D12_UAV_DIMENSION_TEXTURE2DARRAY; uav.unnamed_0.Texture2DArray = .{ .MipSlice = view.base_mip, .FirstArraySlice = view.base_layer, .ArraySize = view.layer_count, .PlaneSlice = 0 }; },
                    .d3 => { uav.ViewDimension = dx.D3D12_UAV_DIMENSION_TEXTURE3D; uav.unnamed_0.Texture3D = .{ .MipSlice = view.base_mip, .FirstWSlice = view.base_layer, .WSize = view.layer_count }; },
                }
                raw_device.lpVtbl.*.CreateUnorderedAccessView.?(raw_device, view.resource, null, &uav, cpu);
                resource_index += 1;
            },
            .sampler => {
                const value = switch (entry.resource) {
                    .sampler => |sampler| sampler,
                    else => return error.BindingTypeMismatch,
                };
                const sampler = try Dx12Sampler.fromHandle(value);
                raw_device.lpVtbl.*.CreateSampler.?(raw_device, &sampler.desc, offsetCpu(sampler_allocation.?.cpu, sampler_index, sampler_stride));
                sampler_index += 1;
            },
        }
        }
    }
    return .{ .handle = @intCast(@intFromPtr(self)) };
}

pub fn destroyGroup(ptr: *anyopaque, value: binding.BindGroup) void {
    const device: *Dx12Device = @ptrCast(@alignCast(ptr));
    const self = Dx12BindGroup.fromHandle(value) catch return;
    if (self.resource_count != 0) device.freeResourceDescriptors(self.resource_index, self.resource_count);
    if (self.sampler_count != 0) device.freeSamplerDescriptors(self.sampler_index, self.sampler_count);
    self.allocator.free(self.entries);
    self.allocator.destroy(self);
}

pub fn dynamicResources(device: *Dx12Device, group: *Dx12BindGroup, offsets: []const u32) !Dx12Device.DescriptorAllocation {
    const allocation = try device.allocateResourceDescriptors(group.resource_count);
    errdefer device.freeResourceDescriptors(allocation.index, allocation.count);
    const raw = device.device.unwrap();
    raw.lpVtbl.*.CopyDescriptorsSimple.?(raw, group.resource_count, allocation.cpu, group.resource_cpu.?, dx.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    const stride = raw.lpVtbl.*.GetDescriptorHandleIncrementSize.?(raw, dx.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    var descriptor_index: u32 = 0;
    var dynamic_index: usize = 0;
    for (group.layout.entries) |layout_entry| {
        switch (layout_entry.kind) {
            .buffer => |buffer_layout| {
                for (0..layout_entry.count) |array_element| {
                    if (buffer_layout.dynamic_offset) {
                    const entry = findEntry(group.entries, layout_entry.binding, @intCast(array_element)) orelse return error.MissingBinding;
                    const value = switch (entry.resource) { .buffer => |item| item, else => return error.BindingTypeMismatch };
                    const buffer = try resource.Dx12Buffer.fromHandle(value.buffer);
                    const offset = value.offset + offsets[dynamic_index];
                    const size = value.size orelse buffer.size - value.offset;
                    const alignment: u64 = if (buffer_layout.kind == .uniform) 256 else 4;
                    if (offset >= buffer.size or offset % alignment != 0 or size > buffer.size - offset) return error.InvalidDynamicOffset;
                    const cpu = offsetCpu(allocation.cpu, descriptor_index, stride);
                    switch (buffer_layout.kind) {
                        .uniform => raw.lpVtbl.*.CreateConstantBufferView.?(raw, &.{ .BufferLocation = buffer.resource.unwrap().lpVtbl.*.GetGPUVirtualAddress.?(buffer.resource.unwrap()) + offset, .SizeInBytes = @intCast(std.mem.alignForward(u64, size, 256)) }, cpu),
                        .storage_read => {
                            var srv: dx.D3D12_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(dx.D3D12_SHADER_RESOURCE_VIEW_DESC);
                            srv.Format = dx.DXGI_FORMAT_R32_TYPELESS; srv.ViewDimension = dx.D3D12_SRV_DIMENSION_BUFFER; srv.Shader4ComponentMapping = dx.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
                            srv.unnamed_0.Buffer = .{ .FirstElement = offset / 4, .NumElements = @intCast(size / 4), .StructureByteStride = 0, .Flags = dx.D3D12_BUFFER_SRV_FLAG_RAW };
                            raw.lpVtbl.*.CreateShaderResourceView.?(raw, buffer.resource.unwrap(), &srv, cpu);
                        },
                        .storage_read_write => {
                            var uav: dx.D3D12_UNORDERED_ACCESS_VIEW_DESC = std.mem.zeroes(dx.D3D12_UNORDERED_ACCESS_VIEW_DESC);
                            uav.Format = dx.DXGI_FORMAT_R32_TYPELESS; uav.ViewDimension = dx.D3D12_UAV_DIMENSION_BUFFER;
                            uav.unnamed_0.Buffer = .{ .FirstElement = offset / 4, .NumElements = @intCast(size / 4), .StructureByteStride = 0, .CounterOffsetInBytes = 0, .Flags = dx.D3D12_BUFFER_UAV_FLAG_RAW };
                            raw.lpVtbl.*.CreateUnorderedAccessView.?(raw, buffer.resource.unwrap(), null, &uav, cpu);
                        },
                    }
                        dynamic_index += 1;
                    }
                    descriptor_index += 1;
                }
            },
            .sampled_texture, .storage_texture => descriptor_index += layout_entry.count,
            .sampler => {},
        }
    }
    return allocation;
}

fn findEntry(entries: []const binding.BindGroupEntry, number: u32, array_element: u32) ?binding.BindGroupEntry {
    for (entries) |entry| if (entry.binding == number and entry.array_element == array_element) return entry;
    return null;
}

fn compareOp(value: resource_interface.CompareOp) dx.D3D12_COMPARISON_FUNC { return switch (value) { .never => dx.D3D12_COMPARISON_FUNC_NEVER, .less => dx.D3D12_COMPARISON_FUNC_LESS, .equal => dx.D3D12_COMPARISON_FUNC_EQUAL, .less_equal => dx.D3D12_COMPARISON_FUNC_LESS_EQUAL, .greater => dx.D3D12_COMPARISON_FUNC_GREATER, .not_equal => dx.D3D12_COMPARISON_FUNC_NOT_EQUAL, .greater_equal => dx.D3D12_COMPARISON_FUNC_GREATER_EQUAL, .always => dx.D3D12_COMPARISON_FUNC_ALWAYS }; }

fn offsetCpu(handle: dx.D3D12_CPU_DESCRIPTOR_HANDLE, index: u32, stride: u32) dx.D3D12_CPU_DESCRIPTOR_HANDLE {
    return .{ .ptr = handle.ptr + @as(usize, index) * stride };
}

fn addressMode(value: resource_interface.AddressMode) dx.D3D12_TEXTURE_ADDRESS_MODE {
    return switch (value) {
        .repeat => dx.D3D12_TEXTURE_ADDRESS_MODE_WRAP,
        .mirror_repeat => dx.D3D12_TEXTURE_ADDRESS_MODE_MIRROR,
        .clamp_to_edge => dx.D3D12_TEXTURE_ADDRESS_MODE_CLAMP,
    };
}

fn filterMode(desc: resource_interface.SamplerDescriptor) dx.D3D12_FILTER {
    if (desc.max_anisotropy > 1) return if (desc.compare == null) dx.D3D12_FILTER_ANISOTROPIC else dx.D3D12_FILTER_COMPARISON_ANISOTROPIC;
    const bits = @as(u3, @intFromBool(desc.min_filter == .linear)) << 2 |
        @as(u3, @intFromBool(desc.mag_filter == .linear)) << 1 |
        @as(u3, @intFromBool(desc.mipmap_filter == .linear));
    if (desc.compare != null) return switch (bits) {
        0b000 => dx.D3D12_FILTER_COMPARISON_MIN_MAG_MIP_POINT,
        0b001 => dx.D3D12_FILTER_COMPARISON_MIN_MAG_POINT_MIP_LINEAR,
        0b010 => dx.D3D12_FILTER_COMPARISON_MIN_POINT_MAG_LINEAR_MIP_POINT,
        0b011 => dx.D3D12_FILTER_COMPARISON_MIN_POINT_MAG_MIP_LINEAR,
        0b100 => dx.D3D12_FILTER_COMPARISON_MIN_LINEAR_MAG_MIP_POINT,
        0b101 => dx.D3D12_FILTER_COMPARISON_MIN_LINEAR_MAG_POINT_MIP_LINEAR,
        0b110 => dx.D3D12_FILTER_COMPARISON_MIN_MAG_LINEAR_MIP_POINT,
        0b111 => dx.D3D12_FILTER_COMPARISON_MIN_MAG_MIP_LINEAR,
    };
    return switch (bits) {
        0b000 => dx.D3D12_FILTER_MIN_MAG_MIP_POINT,
        0b001 => dx.D3D12_FILTER_MIN_MAG_POINT_MIP_LINEAR,
        0b010 => dx.D3D12_FILTER_MIN_POINT_MAG_LINEAR_MIP_POINT,
        0b011 => dx.D3D12_FILTER_MIN_POINT_MAG_MIP_LINEAR,
        0b100 => dx.D3D12_FILTER_MIN_LINEAR_MAG_MIP_POINT,
        0b101 => dx.D3D12_FILTER_MIN_LINEAR_MAG_POINT_MIP_LINEAR,
        0b110 => dx.D3D12_FILTER_MIN_MAG_LINEAR_MIP_POINT,
        0b111 => dx.D3D12_FILTER_MIN_MAG_MIP_LINEAR,
    };
}
