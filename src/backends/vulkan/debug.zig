const vk = @import("vulkan");

/// Assigns a human-readable name to a Vulkan object for validation messages
/// and graphics debuggers.
///
/// `VK_EXT_debug_utils` must be enabled when the device dispatch table is
/// loaded. Convert typed Vulkan handles with `@intFromEnum`, for example:
///
/// ```zig
/// try nameVkObj(device, .buffer, @intFromEnum(buffer), "vertex buffer");
/// ```
pub fn nameVkObj(
    device: vk.DeviceProxy,
    object_type: vk.ObjectType,
    object_handle: u64,
    name: [:0]const u8,
) !void {
    if (device.wrapper.dispatch.vkSetDebugUtilsObjectNameEXT == null)
        return error.VulkanDebugUtilsUnavailable;

    try device.setDebugUtilsObjectNameEXT(&.{
        .object_type = object_type,
        .object_handle = object_handle,
        .p_object_name = name.ptr,
    });
}
