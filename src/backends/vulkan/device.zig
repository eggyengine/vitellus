const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vulkan");
const Device = @import("../../interface/device.zig").Device;
const DeviceDescriptor = @import("../../interface/device.zig").DeviceDescriptor;
const Queue = @import("../../interface/queue.zig").Queue;
const QueueDescriptor = @import("../../interface/queue.zig").QueueDescriptor;
const vkAdapter = @import("adapter.zig").vkAdapter;
const vkInstance = @import("instance.zig").vkInstance;
const vkQueue = @import("queue.zig").vkQueue;
const sync_impl = @import("sync.zig");
const shader_impl = @import("shader.zig");
const resource_impl = @import("resource.zig");
const binding_impl = @import("binding.zig");
const pipeline_impl = @import("pipeline.zig");
const command_impl = @import("command.zig");

const log = std.log.scoped(.vk_device);

pub const vkDevice = struct {
    allocator: std.mem.Allocator,
    instance: *vkInstance,
    handle: vk.Device,
    wrapper: vk.DeviceWrapper,
    proxy: vk.DeviceProxy,
    queues: @import("adapter.zig").QueueAllocation,
    memory_props: vk.PhysicalDeviceMemoryProperties,

    const vtable: Device.VTable = .{
        .deinitFn = deinitImpl,
        .createQueueFn = createQueueImpl,
        .createShaderFn = shader_impl.create,
        .createBufferFn = resource_impl.createBuffer,
        .createTextureFn = resource_impl.createTexture,
        .createTextureViewFn = resource_impl.createTextureView,
        .createSamplerFn = resource_impl.createSampler,
        .createBindGroupLayoutFn = binding_impl.createLayout,
        .createBindGroupFn = binding_impl.createGroup,
        .createPipelineLayoutFn = pipeline_impl.createLayout,
        .createGraphicsPipelineFn = pipeline_impl.createGraphics,
        .createComputePipelineFn = pipeline_impl.createCompute,
        .createCommandPoolFn = command_impl.createPool,
        .createQuerySetFn = command_impl.createQuerySet,
        .createFenceFn = sync_impl.createFence,
        .createSemaphoreFn = sync_impl.createSemaphore,
    };

    pub fn init(adapter_ptr: *anyopaque, allocator: std.mem.Allocator, desc: DeviceDescriptor) !Device {
        const adapter: *vkAdapter = @ptrCast(@alignCast(adapter_ptr));
        const self = try allocator.create(vkDevice);
        errdefer allocator.destroy(self);

        var queue_infos: [3]vk.DeviceQueueCreateInfo = undefined;
        var queue_info_count: usize = 0;
        const priority = [_]f32{1.0};
        const requested_families = [_]?u32{ adapter.queues.graphics_family, adapter.queues.compute_family, adapter.queues.copy_family };
        for (requested_families) |maybe_family| {
            const family = maybe_family orelse continue;
            var duplicate = false;
            for (queue_infos[0..queue_info_count]) |info| {
                if (info.queue_family_index == family) duplicate = true;
            }
            if (duplicate) continue;
            queue_infos[queue_info_count] = .{
                .queue_family_index = family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            };
            queue_info_count += 1;
        }

        const enabled_features = requiredVkFeatures(desc);
        var timeline_features: vk.PhysicalDeviceTimelineSemaphoreFeatures = .{ .timeline_semaphore = .true };
        var dynamic_rendering_features: vk.PhysicalDeviceDynamicRenderingFeatures = .{
            .p_next = @ptrCast(&timeline_features),
            .dynamic_rendering = .true,
        };
        var extension_names: [2][*:0]const u8 = undefined;
        const extensions = try deviceExtensions(adapter, allocator, &extension_names);
        const get_device_proc_addr = adapter.instance.wrapper.dispatch.vkGetDeviceProcAddr orelse
            return error.VulkanLoaderMissingGetDeviceProcAddr;
        const handle = try adapter.instance.wrapper.createDevice(adapter.physical_device, &.{
            .p_next = &dynamic_rendering_features,
            .queue_create_info_count = @intCast(queue_info_count),
            .p_queue_create_infos = queue_infos[0..queue_info_count].ptr,
            .enabled_extension_count = @intCast(extensions.len),
            .pp_enabled_extension_names = extensions.ptr,
            .p_enabled_features = &enabled_features,
        }, null);

        const wrapper = vk.DeviceWrapper.load(handle, get_device_proc_addr);
        errdefer if (wrapper.dispatch.vkDestroyDevice) |destroy_device| destroy_device(handle, null);
        if (wrapper.dispatch.vkDestroyDevice == null) return error.VulkanLoaderMissingDestroyDevice;

        self.allocator = allocator;
        self.instance = adapter.instance;
        self.handle = handle;
        self.wrapper = wrapper;
        self.proxy = vk.DeviceProxy.init(handle, &self.wrapper);
        self.queues = adapter.queues;
        self.memory_props = adapter.memory_props;

        self.instance.nameObject(allocator, self.proxy, .device, @intFromEnum(handle), desc.label);
        log.debug("created Vulkan logical device with {} queue family/families", .{queue_info_count});
        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *vkDevice = @ptrCast(@alignCast(ptr));
        _ = self.proxy.deviceWaitIdle() catch |err| log.warn("Vulkan device wait-idle failed during destruction: {}", .{err});
        self.proxy.destroyDevice(null);
        allocator.destroy(self);
        log.debug("destroyed Vulkan logical device", .{});
    }

    fn createQueueImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: QueueDescriptor) anyerror!Queue {
        return vkQueue.init(ptr, allocator, desc);
    }
};

fn deviceExtensions(adapter: *vkAdapter, allocator: std.mem.Allocator, buf: *[2][*:0]const u8) ![]const [*:0]const u8 {
    return fillDeviceExtensions(try hasDeviceExtension(adapter, allocator, vk.extensions.khr_portability_subset.name), buf);
}

fn fillDeviceExtensions(portability: bool, buf: *[2][*:0]const u8) []const [*:0]const u8 {
    buf[0] = vk.extensions.khr_swapchain.name.ptr;
    if (!portability) return buf[0..1];
    buf[1] = vk.extensions.khr_portability_subset.name.ptr;
    return buf[0..2];
}

fn hasDeviceExtension(adapter: *vkAdapter, allocator: std.mem.Allocator, name: []const u8) !bool {
    const extensions = try adapter.instance.wrapper.enumerateDeviceExtensionPropertiesAlloc(adapter.physical_device, null, allocator);
    defer allocator.free(extensions);
    for (extensions) |*extension| {
        const len = std.mem.indexOfScalar(u8, &extension.extension_name, 0) orelse extension.extension_name.len;
        if (std.mem.eql(u8, extension.extension_name[0..len], name)) return true;
    }
    return false;
}

fn requiredVkFeatures(desc: DeviceDescriptor) vk.PhysicalDeviceFeatures {
    return .{
        .occlusion_query_precise = vkBool(desc.required_features.occlusion_query),
        .draw_indirect_first_instance = vkBool(desc.required_features.indirect_first_instance),
        .depth_clamp = vkBool(desc.required_features.depth_clip_control),
        .fill_mode_non_solid = vkBool(desc.required_features.wireframe),
        .sampler_anisotropy = vkBool(desc.required_features.anisotropic_filtering),
        .texture_compression_bc = vkBool(desc.required_features.bc_compression),
    };
}

fn vkBool(value: bool) vk.Bool32 {
    return if (value) .true else .false;
}

test "device extensions include portability subset when advertised" {
    var buf: [2][*:0]const u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), fillDeviceExtensions(false, &buf).len);
    try std.testing.expectEqual(@as(usize, 2), fillDeviceExtensions(true, &buf).len);
    try std.testing.expectEqualStrings(vk.extensions.khr_portability_subset.name, std.mem.span(buf[1]));
}

test "Vulkan logical device creates queues and semaphores" {
    if (builtin.target.os.tag != .windows and
        builtin.target.os.tag != .linux and
        builtin.target.os.tag != .macos)
    {
        return error.SkipZigTest;
    }

    const instance = @import("instance.zig").vkInstance.init(std.testing.allocator, .{
        .backend = .{ .vulkan = true },
        .validation = .none,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer instance.deinit();
    const adapter = try instance.createAdapter(.{});
    defer adapter.deinit();
    const device = try Device.init(adapter, .{ .label = "test Vulkan device" });
    defer device.deinit();

    const queue = try Queue.init(device, .{ .label = "test graphics queue" });
    defer queue.deinit();
    try queue.waitIdle();

    const semaphore = try @import("../../interface/sync.zig").Semaphore.init(device, .{ .label = "test semaphore" });
    semaphore.deinit();
}
