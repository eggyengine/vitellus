const vk = @import("vulkan");
const std = @import("std");

const logz = @import("logz");

pub fn enabled(device: anytype) bool {
    return device.adapter.gpu.validation_layers_enabled and device.adapter.gpu.debug_utils_enabled;
}

/// Applies a debug label to a Vulkan object (which can be useful in cases like RenderDoc).
///
/// # Args
/// `device` - a `vkDevice` to set the label
///
/// `object_type` - the type of the Vulkan object (e.g. `vk.OBJECT_TYPE_BUFFER`)
///
/// `handle` - the handle of the Vulkan object (e.g. a `vk.Buffer`)
///
/// `label` - the label to apply to the object (if `null`, no label will be applied)
pub fn setObjectName(
    device: anytype,
    object_type: vk.ObjectType,
    handle: anytype,
    label: ?[*:0]const u8,
) void {
    const name = label orelse return;
    if (!enabled(device)) return;

    if (!@hasDecl(vk.DeviceProxy, "setDebugUtilsObjectNameEXT")) {
        logz.info().fmt("msg", "cannot apply label {s}: vulkan-zig DeviceProxy does not expose vkSetDebugUtilsObjectNameEXT", .{name}).log();
        return;
    }

    const info = vk.DebugUtilsObjectNameInfoEXT{
        .object_type = object_type,
        .object_handle = @intCast(@intFromEnum(handle)),
        .p_object_name = name,
    };

    device.device.setDebugUtilsObjectNameEXT(&info) catch |err| {
        logz.warn().fmt("msg", "failed to apply label {s} to {s}: {s}", .{ name, @tagName(object_type), @errorName(err) }).log();
        return;
    };

    // logz.info().fmt("msg", "applied label {s} to {s} 0x{x}", .{ name, @tagName(object_type), @intFromEnum(handle) }).log();
}
