const std = @import("std");
const Instance = @import("../../interface/instance.zig").Instance;
const Adapter = @import("../../interface/adapter.zig").Adapter;
const AdapterDescriptor = @import("../../interface/adapter.zig").AdapterDescriptor;
const VitellusConfig = @import("../../interface/settings.zig").VitellusConfig;
const Dx12Adapter = @import("adapter.zig").Dx12Adapter;
const dx = @import("dx.zig").c;
const ComPtr = @import("utils.zig").ComPtr;
const checkHr = @import("utils.zig").checkHr;
const debug = @import("debug.zig");

pub const Dx12Instance = struct {
    debug_ctrl: debug.Dx12DebugController = .{},
    factory: ComPtr(dx.IDXGIFactory4) = .{},

    const vtable: Instance.VTable = .{
        .deinitFn = deinitImpl,
        .createAdapterFn = createAdapterImpl,
    };

    pub fn init(allocator: std.mem.Allocator, config: VitellusConfig) !Instance {
        const self = try allocator.create(Dx12Instance);
        self.* = .{};
        errdefer {
            self.debug_ctrl.deinit();
            allocator.destroy(self);
        }

        if (config.validation != .none)
            self.debug_ctrl = debug.Dx12DebugController.init(config.validation);

        var raw_factory: ?*anyopaque = null;
        try checkHr(dx.CreateDXGIFactory1(&dx.IID_IDXGIFactory4, &raw_factory));
        self.factory = .attach(@ptrCast(@alignCast(raw_factory orelse return error.HrFailed)));

        return .{ .ptr = self, .vtable = &vtable, .allocator = allocator };
    }

    fn deinitImpl(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Dx12Instance = @ptrCast(@alignCast(ptr));
        self.factory.deinit();
        self.debug_ctrl.deinit();
        allocator.destroy(self);
    }

    fn createAdapterImpl(ptr: *anyopaque, allocator: std.mem.Allocator, desc: AdapterDescriptor) !Adapter {
        return Dx12Adapter.init(ptr, allocator, desc);
    }
};
