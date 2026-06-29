const builtin = @import("builtin");

const dx = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cInclude("d3d12.h");
    @cInclude("dxgi1_6.h");
});

pub const adapter = @import("dx12/adapter.zig");
pub const device = @import("dx12/device.zig");
pub const debug = @import("dx12/debug.zig");
pub const utils = @import("dx12/utils.zig");
pub const queue = @import("dx12/queue.zig");
pub const swapchain = @import("dx12/swapchain.zig");
