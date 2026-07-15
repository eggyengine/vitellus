const std = @import("std");
const Swapchain = @import("../../interface/swapchain.zig").Swapchain;
const swapchain_interface = @import("../../interface/swapchain.zig");
const SwapchainDescriptor = @import("../../interface/swapchain.zig").SwapchainDescriptor;
const SwapchainFormat = @import("../../interface/swapchain.zig").SwapchainFormat;
const PresentMode = @import("../../interface/swapchain.zig").PresentMode;
const CompositeAlpha = @import("../../interface/swapchain.zig").CompositeAlpha;
const ImageUsage = @import("../../interface/swapchain.zig").ImageUsage;
const resource = @import("../../interface/resource.zig");
const resource_impl = @import("resource.zig");
const sync = @import("../../interface/sync.zig");
const sync_impl = @import("sync.zig");
const adapter_mod = @import("adapter.zig");
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;
const Dx12Adapter = adapter_mod.Dx12Adapter;
const Dx12Queue = @import("queue.zig").Dx12Queue;
const dx = @import("dx.zig").c;

const log = std.log.scoped(.dx12_swapchain);

pub const Dx12Swapchain = struct {
    allocator: std.mem.Allocator,
    factory: ComPtr(dx.IDXGIFactory4) = .{},
    swapchain: ComPtr(dx.IDXGISwapChain3) = .{},
    rtv_heap: ComPtr(dx.ID3D12DescriptorHeap) = .{},
    buffers: []ComPtr(dx.ID3D12Resource) = &.{},
    views: []resource_impl.Dx12TextureView = &.{},
    hwnd: isize,
    dx_desc: dx.DXGI_SWAP_CHAIN_DESC1,
    present_mode: PresentMode,
    queue: *Dx12Queue,

    const vtable: Swapchain.VTable = .{
        .deinitFn = deinitImpl,
        .acquireNextImageFn = acquireNextImageImpl,
        .presentFn = presentImpl,
        .resizeFn = resizeImpl,
        .infoFn = infoImpl,
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
            .allocator = allocator,
            .factory = adapter.factory.clone(),
            .hwnd = hwnd,
            .dx_desc = dx_desc,
            .present_mode = desc.present_mode,
            .queue = queue,
        };
        errdefer {
            self.releaseBuffers();
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
        try self.createViews(queue);

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
        self.releaseBuffers();
        self.swapchain.deinit();
        self.factory.deinit();
        allocator.destroy(self);
    }

    fn acquireNextImageImpl(ptr: *anyopaque, signal: ?sync.Semaphore) anyerror!swapchain_interface.AcquireResult {
        const self: *Dx12Swapchain = @ptrCast(@alignCast(ptr));
        const index = self.swapchain.unwrap().lpVtbl.*.GetCurrentBackBufferIndex.?(self.swapchain.unwrap());
        if (index >= self.views.len) return error.InvalidBackBufferIndex;
        if (signal) |value| try sync_impl.signalSemaphoreCpu(value);
        return .{
            .index = index,
            .view = .{ .handle = @intCast(@intFromPtr(&self.views[index])) },
        };
    }

    fn presentImpl(ptr: *anyopaque, waits: []const sync.Semaphore) anyerror!swapchain_interface.PresentStatus {
        const self: *Dx12Swapchain = @ptrCast(@alignCast(ptr));
        for (waits) |value| try sync_impl.waitSemaphore(self.queue.queue.unwrap(), value);
        const interval: dx.UINT = if (self.present_mode == .fifo or self.present_mode == .fifo_relaxed) 1 else 0;
        const flags: dx.UINT = if (interval == 0 and (self.dx_desc.Flags & dx.DXGI_SWAP_CHAIN_FLAG_ALLOW_TEARING) != 0) dx.DXGI_PRESENT_ALLOW_TEARING else 0;
        const result = self.swapchain.unwrap().lpVtbl.*.Present.?(self.swapchain.unwrap(), interval, flags);
        if (result == dx.DXGI_STATUS_OCCLUDED) return .occluded;
        try checkHr(result);
        return .optimal;
    }

    fn resizeImpl(ptr: *anyopaque, extent: swapchain_interface.Extent2D) anyerror!void {
        const self: *Dx12Swapchain = @ptrCast(@alignCast(ptr));
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        try @import("queue.zig").waitIdle(self.queue);
        self.releaseBuffers();
        self.dx_desc.Width = extent.width;
        self.dx_desc.Height = extent.height;
        try checkHr(self.swapchain.unwrap().lpVtbl.*.ResizeBuffers.?(
            self.swapchain.unwrap(), self.dx_desc.BufferCount, extent.width, extent.height,
            self.dx_desc.Format, self.dx_desc.Flags,
        ));
        try self.createViews(self.queue);
    }

    fn infoImpl(ptr: *anyopaque) swapchain_interface.SwapchainInfo {
        const self: *Dx12Swapchain = @ptrCast(@alignCast(ptr));
        return .{
            .extent = .{ .width = self.dx_desc.Width, .height = self.dx_desc.Height },
            .format = fromDxFormat(self.dx_desc.Format),
            .image_count = self.dx_desc.BufferCount,
        };
    }

    fn createViews(self: *Dx12Swapchain, queue: *Dx12Queue) !void {
        const count: usize = @intCast(self.dx_desc.BufferCount);
        self.buffers = try self.allocator.alloc(ComPtr(dx.ID3D12Resource), count);
        for (self.buffers) |*buffer| buffer.* = .{};
        self.views = try self.allocator.alloc(resource_impl.Dx12TextureView, count);

        var raw_device: ComPtr(dx.ID3D12Device) = .{};
        defer raw_device.deinit();
        try checkHr(queue.queue.unwrap().lpVtbl.*.GetDevice.?(
            queue.queue.unwrap(),
            &dx.IID_ID3D12Device,
            @ptrCast(raw_device.put()),
        ));
        const device = raw_device.unwrap();
        const heap_desc = dx.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = dx.D3D12_DESCRIPTOR_HEAP_TYPE_RTV,
            .NumDescriptors = @intCast(count),
            .Flags = dx.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
            .NodeMask = 0,
        };
        try checkHr(device.lpVtbl.*.CreateDescriptorHeap.?(
            device,
            &heap_desc,
            &dx.IID_ID3D12DescriptorHeap,
            @ptrCast(self.rtv_heap.put()),
        ));
        const stride = device.lpVtbl.*.GetDescriptorHandleIncrementSize.?(device, dx.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        var handle: dx.D3D12_CPU_DESCRIPTOR_HANDLE = undefined;
        _ = self.rtv_heap.unwrap().lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(self.rtv_heap.unwrap(), &handle);
        for (self.buffers, 0..) |*buffer, i| {
            try checkHr(self.swapchain.unwrap().lpVtbl.*.GetBuffer.?(
                self.swapchain.unwrap(),
                @intCast(i),
                &dx.IID_ID3D12Resource,
                @ptrCast(buffer.put()),
            ));
            device.lpVtbl.*.CreateRenderTargetView.?(device, buffer.unwrap(), null, handle);
            self.views[i] = .{
                .resource = buffer.unwrap(),
                .rtv = handle,
                .width = self.dx_desc.Width,
                .height = self.dx_desc.Height,
                .dimension = .d2,
                .depth_or_layers = 1,
                .format = self.dx_desc.Format,
            };
            handle.ptr += stride;
        }
    }

    fn releaseBuffers(self: *Dx12Swapchain) void {
        for (self.buffers) |*buffer| buffer.deinit();
        if (self.buffers.len != 0) self.allocator.free(self.buffers);
        if (self.views.len != 0) self.allocator.free(self.views);
        self.buffers = &.{};
        self.views = &.{};
        self.rtv_heap.deinit();
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

fn fromDxFormat(format: dx.DXGI_FORMAT) SwapchainFormat {
    return switch (format) {
        dx.DXGI_FORMAT_B8G8R8A8_UNORM => .bgra8_unorm,
        dx.DXGI_FORMAT_B8G8R8A8_UNORM_SRGB => .bgra8_unorm_srgb,
        dx.DXGI_FORMAT_R8G8B8A8_UNORM => .rgba8_unorm,
        dx.DXGI_FORMAT_R8G8B8A8_UNORM_SRGB => .rgba8_unorm_srgb,
        dx.DXGI_FORMAT_R16G16B16A16_FLOAT => .rgba16_float,
        else => .bgra8_unorm,
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
