const ComPtr = @import("utils.zig").ComPtr;
const std = @import("std");

const dx = @import("dx.zig").c;

const log = std.log.scoped(.dx12_debug);

pub const Dx12DebugController = struct {
    debug: ComPtr(dx.ID3D12Debug) = .{},

    /// Attempts to acquire `ID3D12Debug` and enable the D3D12 validation layer.
    ///
    /// If the debug interface is unavailable (SDK layers not installed, or a
    /// release build), the call is silently skipped and a no-op controller is
    /// returned.
    pub fn init() Dx12DebugController {
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
                    log.debug("debug layers enabled", .{});
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
