const std = @import("std");
const Swapchain = @import("../../interface/swapchain.zig").Swapchain;
const SwapchainDescriptor = @import("../../interface/swapchain.zig").SwapchainDescriptor;
const SwapchainFormat = @import("../../interface/swapchain.zig").SwapchainFormat;
const PresentMode = @import("../../interface/swapchain.zig").PresentMode;
const CompositeAlpha = @import("../../interface/swapchain.zig").CompositeAlpha;
const ImageUsage = @import("../../interface/swapchain.zig").ImageUsage;
const adapter_mod = @import("adapter.zig");
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;
const Dx12Adapter = adapter_mod.Dx12Adapter;
const Dx12Queue = @import("queue.zig").Dx12Queue;
const dx = @import("dx.zig").c;

const log = std.log.scoped(.dx12_swapchain);

pub const Dx12Swapchain = struct {
    factory: ComPtr(dx.IDXGIFactory4) = .{},
    swapchain: ComPtr(dx.IDXGISwapChain3) = .{},
    hwnd: isize,
    dx_desc: dx.DXGI_SWAP_CHAIN_DESC1,

    const vtable: Swapchain.VTable = .{
        .deinitFn = deinitImpl,
    };

    pub fn init(adapter_ptr: *anyopaque, allocator: std.mem.Allocator, desc: SwapchainDescriptor) !Swapchain {
        const adapter: *Dx12Adapter = @ptrCast(@alignCast(adapter_ptr));
        const queue: *Dx12Queue = @ptrCast(@alignCast(desc.queue.ptr));
        if (queue.kind != .graphics) return error.InvalidQueueKind;

        const window_handle = try desc.window.window_handle.windowHandle();
        const hwnd = switch (window_handle.asRaw()) {
            .win32 => |win32| win32.hwnd,
            else => return error.NotSupported,
        };

        const dx_desc = toDxSwapchainDesc(desc);
        const self = try allocator.create(Dx12Swapchain);
        self.* = .{
            .factory = adapter.factory.clone(),
            .hwnd = hwnd,
            .dx_desc = dx_desc,
        };
        errdefer {
            self.swapchain.deinit();
            self.factory.deinit();
            allocator.destroy(self);
        }

        var swapchain1: ComPtr(dx.IDXGISwapChain1) = .{};
        defer swapchain1.deinit();

        const factory = self.factory.unwrap();
        try checkHr(factory.lpVtbl.*.CreateSwapChainForHwnd.?(
            factory,
            @ptrCast(queue.queue.unwrap()),
            hwndFromInt(hwnd),
            &self.dx_desc,
            null,
            null,
            @ptrCast(swapchain1.put()),
        ));

        self.swapchain = try swapchain1.as(dx.IDXGISwapChain3, &dx.IID_IDXGISwapChain3);

        log.debug("created DX12 swapchain for HWND={} buffers={} size={}x{}", .{
            hwnd,
            dx_desc.BufferCount,
            dx_desc.Width,
            dx_desc.Height,
        });
        return Swapchain{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Swapchain = @ptrCast(@alignCast(ptr));
        self.swapchain.deinit();
        self.factory.deinit();
        allocator.destroy(self);
    }
};

fn hwndFromInt(hwnd: isize) dx.HWND {
    // HWND is an opaque OS handle. It is not dereferenced here and is not
    // guaranteed to satisfy Zig's pointer alignment checks.
    @setRuntimeSafety(false);
    return @ptrFromInt(@as(usize, @intCast(hwnd)));
}

fn toDxSwapchainDesc(desc: SwapchainDescriptor) dx.DXGI_SWAP_CHAIN_DESC1 {
    return .{
        .Width = desc.extent.width,
        .Height = desc.extent.height,
        .Format = toDxFormat(desc.format),
        .Stereo = 0,
        .SampleDesc = .{
            .Count = 1,
            .Quality = 0,
        },
        .BufferUsage = toDxUsage(desc.usage),
        .BufferCount = @max(desc.image_count, 2),
        .Scaling = dx.DXGI_SCALING_STRETCH,
        .SwapEffect = dx.DXGI_SWAP_EFFECT_FLIP_DISCARD,
        .AlphaMode = toDxAlphaMode(desc.composite_alpha),
        .Flags = toDxFlags(desc.present_mode),
    };
}

fn toDxFormat(format: SwapchainFormat) dx.DXGI_FORMAT {
    return switch (format) {
        .bgra8_unorm => dx.DXGI_FORMAT_B8G8R8A8_UNORM,
        .bgra8_unorm_srgb => dx.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        .rgba8_unorm => dx.DXGI_FORMAT_R8G8B8A8_UNORM,
        .rgba8_unorm_srgb => dx.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB,
        .rgba16_float => dx.DXGI_FORMAT_R16G16B16A16_FLOAT,
    };
}

fn toDxUsage(usage: ImageUsage) dx.DXGI_USAGE {
    var flags: dx.DXGI_USAGE = 0;

    if (usage.render_target) flags |= dx.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    if (usage.sampled) flags |= dx.DXGI_USAGE_SHADER_INPUT;
    if (usage.transfer_src) flags |= dx.DXGI_USAGE_READ_ONLY;
    if (usage.transfer_dst) flags |= dx.DXGI_USAGE_RENDER_TARGET_OUTPUT;

    if (flags == 0) return dx.DXGI_USAGE_RENDER_TARGET_OUTPUT;
    return flags;
}

fn toDxAlphaMode(alpha: CompositeAlpha) dx.DXGI_ALPHA_MODE {
    return switch (alpha) {
        .opaque_alpha => dx.DXGI_ALPHA_MODE_IGNORE,
        .premultiplied => dx.DXGI_ALPHA_MODE_PREMULTIPLIED,
        .postmultiplied => dx.DXGI_ALPHA_MODE_STRAIGHT,
        .inherit => dx.DXGI_ALPHA_MODE_UNSPECIFIED,
    };
}

fn toDxFlags(present_mode: PresentMode) dx.UINT {
    return switch (present_mode) {
        .immediate, .mailbox => dx.DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING,
        .fifo, .fifo_relaxed => 0,
    };
}
