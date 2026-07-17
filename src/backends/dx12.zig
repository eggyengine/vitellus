const builtin = @import("builtin");

const dx = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cInclude("d3d12.h");
    @cInclude("dxgi1_6.h");
});

pub const adapter = @import("dx12/adapter.zig");
pub const instance = @import("dx12/instance.zig");
pub const device = @import("dx12/device.zig");
pub const debug = @import("dx12/debug.zig");
pub const utils = @import("dx12/utils.zig");
pub const queue = @import("dx12/queue.zig");
pub const swapchain = @import("dx12/swapchain.zig");
pub const shader = @import("dx12/shader.zig");
pub const hlsl_shader_module = @import("dx12/hlsl_shader_module.zig");
pub const HLSLShaderModule = hlsl_shader_module.HLSLShaderModule;
pub const HLSLProfile = hlsl_shader_module.HLSLProfile;
pub const resource = @import("dx12/resource.zig");
pub const pipeline = @import("dx12/pipeline.zig");
pub const command = @import("dx12/command.zig");
pub const sync = @import("dx12/sync.zig");
pub const binding = @import("dx12/binding.zig");
