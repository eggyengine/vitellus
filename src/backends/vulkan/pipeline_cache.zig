//! Keeps the Vulkan driver's compiled pipelines between runs, in a `ShaderDiskCache`.
const std = @import("std");
const vk = @import("vulkan");
const ShaderDiskCache = @import("../../shader_disk_cache.zig").ShaderDiskCache;

const log = std.log.scoped(.vk_pipeline_cache);

/// The device's pipeline cache, seeded from `disk`'s copy for this GPU and driver when there
/// is one. A copy the driver refuses is dropped and the cache starts empty.
pub fn open(device: vk.DeviceProxy, props: vk.PhysicalDeviceProperties, disk: ?*const ShaderDiskCache, allocator: std.mem.Allocator) !vk.PipelineCache {
    const saved = if (disk) |cache| cache.load(allocator, key(props)) else null;
    defer if (saved) |data| allocator.free(data);
    if (saved) |data| {
        if (device.createPipelineCache(&.{ .initial_data_size = data.len, .p_initial_data = data.ptr }, null)) |made| {
            log.debug("loaded {d} bytes of compiled pipelines", .{data.len});
            return made;
        } else |err| log.info("saved pipelines refused ({t}); compiling them again", .{err});
    }
    return device.createPipelineCache(&.{}, null);
}

/// Write `cache`'s contents to `disk`, for the next run. Best-effort: failures are logged.
pub fn save(device: vk.DeviceProxy, cache: vk.PipelineCache, props: vk.PhysicalDeviceProperties, disk: ?*const ShaderDiskCache, allocator: std.mem.Allocator) void {
    const target = disk orelse return;
    const data = read(device, cache, allocator) catch |err| {
        log.warn("compiled pipelines not saved: {t}", .{err});
        return;
    };
    defer allocator.free(data);
    if (data.len == 0) return;
    target.store(key(props), data);
}

// ponytail: vulkan-zig's getPipelineCacheDataAlloc doesn't compile (it returns []void); use it once fixed.
fn read(device: vk.DeviceProxy, cache: vk.PipelineCache, allocator: std.mem.Allocator) ![]u8 {
    var len: usize = 0;
    _ = try device.getPipelineCacheData(cache, &len, null);
    const data = try allocator.alloc(u8, len);
    errdefer allocator.free(data);
    // `incomplete` means it grew in between; what was written is still a valid cache.
    _ = try device.getPipelineCacheData(cache, &len, data.ptr);
    return allocator.realloc(data, len);
}

// The driver checks the data's own header too; keying by GPU and driver keeps one copy per
// GPU when several are installed rather than having them overwrite each other.
fn key(props: vk.PhysicalDeviceProperties) ShaderDiskCache.Key {
    return ShaderDiskCache.key(&.{
        "vulkan pipeline cache",
        &props.pipeline_cache_uuid,
        std.mem.asBytes(&props.vendor_id),
        std.mem.asBytes(&props.device_id),
        std.mem.asBytes(&props.driver_version),
    });
}

test "compiled pipelines are saved when the device goes and loaded by the next" {
    const vit = @import("../../root.zig");
    const gpa = std.testing.allocator;
    // An empty compute shader: `void main() {}` at local size 1x1x1.
    const words = [_]u32{
        0x07230203, 0x00010000, 0, 5, 0,
        (2 << 16) | 17, 1, // OpCapability Shader
        (3 << 16) | 14, 0, 1, // OpMemoryModel Logical GLSL450
        (5 << 16) | 15, 5, 3, 0x6e69616d, 0, // OpEntryPoint GLCompute %3 "main"
        (6 << 16) | 16, 3, 17, 1, 1, 1, // OpExecutionMode %3 LocalSize 1 1 1
        (2 << 16) | 19, 1, // %1 = OpTypeVoid
        (3 << 16) | 33, 2, 1, // %2 = OpTypeFunction %1
        (5 << 16) | 54, 1, 3, 0, 2, // %3 = OpFunction %1 None %2
        (2 << 16) | 248, 4, // %4 = OpLabel
        (1 << 16) | 253, // OpReturn
        (1 << 16) | 56, // OpFunctionEnd
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const disk: ShaderDiskCache = .{ .io = std.testing.io, .dir = tmp.dir };

    const instance = vit.Instance.init(gpa, .{ .backend = .{ .vulkan = true }, .validation = .none }) catch return error.SkipZigTest;
    defer instance.deinit();
    const adapter = vit.Adapter.init(instance, .{}) catch return error.SkipZigTest;
    defer adapter.deinit();
    for (0..2) |_| {
        const device = try vit.Device.init(adapter, .{ .pipeline_cache = &disk });
        defer device.deinit();
        const shader = try vit.Shader.init(device, .{ .stage = .compute, .source = vit.BinaryShaderModule.init(.{ .backend = .vulkan, .format = .spirv, .bytes = std.mem.sliceAsBytes(&words) }) });
        defer shader.deinit();
        const layout = try vit.PipelineLayout.init(device, .{});
        defer layout.deinit();
        const made = try vit.ComputePipeline.init(device, .{ .compute = shader, .layout = layout });
        made.deinit();
    }
    const vk_adapter: *@import("adapter.zig").vkAdapter = @ptrCast(@alignCast(adapter.ptr));
    const saved = disk.load(gpa, key(vk_adapter.props)) orelse return error.PipelineCacheNotSaved;
    defer gpa.free(saved);
    try std.testing.expect(saved.len > 0);
}
