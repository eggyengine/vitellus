const ComPtr = @import("utils.zig").ComPtr;
const std = @import("std");

const dx = @import("dx.zig").c;
const ValidationLevel = @import("../../interface/settings.zig").ValidationLevel;

const log = std.log.scoped(.dx12_debug);

pub const Dx12DebugController = struct {
    debug: ComPtr(dx.ID3D12Debug) = .{},

    /// Attempts to acquire `ID3D12Debug` and enable the D3D12 validation layer.
    ///
    /// If the debug interface is unavailable (SDK layers not installed, or a
    /// release build), the call is silently skipped and a no-op controller is
    /// returned.
    pub fn init(level: ValidationLevel) Dx12DebugController {
        var self: Dx12DebugController = .{};
        var raw_debug: ?*anyopaque = null;

        const hr = dx.D3D12GetDebugInterface(
            &dx.IID_ID3D12Debug,
            &raw_debug,
        );

        if (hr >= 0) {
            if (raw_debug) |raw| {
                const p: *dx.ID3D12Debug = @ptrCast(@alignCast(raw));
                self.debug = ComPtr(dx.ID3D12Debug).attach(p);

                if (p.lpVtbl) |vtbl| {
                    vtbl.*.EnableDebugLayer.?(p);
                    self.configureAdvancedValidation(level);
                    log.debug("debug layers enabled ({s})", .{@tagName(level)});
                } else {
                    log.warn("debug layers not enabled: {}", .{@src()});
                }
            } else {
                log.warn("debug layers not enabled: {}", .{@src()});
            }
        } else {
            log.warn("debug layers not enabled: {} at {}", .{ hr, @src() });
        } // huhh??? this is confusing

        return self;
    }

    /// Ensures the requested validation features are enabled before device creation.
    pub fn enable(self: *Dx12DebugController, level: ValidationLevel) void {
        if (level == .none) return;
        if (self.debug.get() == null) {
            self.* = init(level);
        } else {
            self.configureAdvancedValidation(level);
        }
    }

    fn configureAdvancedValidation(self: *Dx12DebugController, level: ValidationLevel) void {
        if (level == .none or level == .core) return;
        var advanced = self.debug.as(dx.ID3D12Debug1, &dx.IID_ID3D12Debug1) catch {
            log.warn("ID3D12Debug1 unavailable; advanced validation was not enabled", .{});
            return;
        };
        defer advanced.deinit();
        const controller = advanced.unwrap();
        controller.lpVtbl.*.SetEnableSynchronizedCommandQueueValidation.?(controller, 1);
        if (level == .gpu_based) controller.lpVtbl.*.SetEnableGPUBasedValidation.?(controller, 1);
    }

    pub fn deinit(self: *Dx12DebugController) void {
        const enabled = self.debug.get() != null;
        self.debug.deinit();
        if (enabled) log.debug("destroyed DX12 debug controller", .{});
    }
};

pub const Dx12DebugDevice = struct {
    debug: ComPtr(dx.ID3D12DebugDevice) = .{},
    info_queue: ComPtr(dx.ID3D12InfoQueue) = .{},

    pub fn init(device: ComPtr(dx.ID3D12Device)) Dx12DebugDevice {
        var self: Dx12DebugDevice = .{};

        self.debug = device.as(dx.ID3D12DebugDevice, &dx.IID_ID3D12DebugDevice) catch {
            log.warn("ID3D12DebugDevice unavailable", .{});
            return self;
        };
        self.info_queue = device.as(dx.ID3D12InfoQueue, &dx.IID_ID3D12InfoQueue) catch .{};

        log.debug("ID3D12DebugDevice acquired", .{});
        return self;
    }

    pub fn logMessages(self: Dx12DebugDevice) void {
        const queue = self.info_queue.get() orelse return;
        const count = queue.lpVtbl.*.GetNumStoredMessages.?(queue);
        var storage: [4096]u8 align(@alignOf(dx.D3D12_MESSAGE)) = undefined;
        for (0..count) |index| {
            var size: usize = storage.len;
            if (queue.lpVtbl.*.GetMessageA.?(queue, index, @ptrCast(&storage), &size) < 0) continue;
            const message: *const dx.D3D12_MESSAGE = @ptrCast(@alignCast(&storage));
            const description = message.pDescription orelse continue;
            const length = if (message.DescriptionByteLength > 0) message.DescriptionByteLength - 1 else 0;
            const args = .{ message.ID, description[0..length] };
            switch (message.Severity) {
                dx.D3D12_MESSAGE_SEVERITY_CORRUPTION,
                dx.D3D12_MESSAGE_SEVERITY_ERROR,
                => log.err("D3D12 [{}]: {s}", args),
                dx.D3D12_MESSAGE_SEVERITY_WARNING => log.warn("D3D12 [{}]: {s}", args),
                else => log.debug("D3D12 [{}]: {s}", args),
            }
        }
        queue.lpVtbl.*.ClearStoredMessages.?(queue);
    }

    pub fn reportLiveObjects(self: Dx12DebugDevice) void {
        const debug = self.debug.get() orelse return;
        if (debug.lpVtbl) |vtbl| {
            _ = vtbl.*.ReportLiveDeviceObjects.?(
                debug,
                dx.D3D12_RLDO_SUMMARY | dx.D3D12_RLDO_DETAIL,
            );
        }
    }

    pub fn deinit(self: *Dx12DebugDevice) void {
        const enabled = self.debug.get() != null;
        self.info_queue.deinit();
        self.debug.deinit();
        if (enabled) log.debug("destroyed DX12 debug device", .{});
    }
};
