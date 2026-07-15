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
        self.debug.deinit();
    }
};

pub const Dx12DebugDevice = struct {
    debug: ComPtr(dx.ID3D12DebugDevice) = .{},

    pub fn init(device: ComPtr(dx.ID3D12Device)) Dx12DebugDevice {
        var self: Dx12DebugDevice = .{};

        self.debug = device.as(dx.ID3D12DebugDevice, &dx.IID_ID3D12DebugDevice) catch {
            log.warn("ID3D12DebugDevice unavailable", .{});
            return self;
        };

        log.debug("ID3D12DebugDevice acquired", .{});
        return self;
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
        self.debug.deinit();
    }
};
