const std = @import("std");
const windows = std.os.windows;

const c = @cImport({
    @cDefine("COBJMACROS", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");

    @cInclude("windows.h");
    @cInclude("d3d12.h");
    @cInclude("dxgi.h");
});

pub const HResultError = error{
    HResultFailed,
};

pub fn hr(
    result: c.HRESULT,
    comptime src: std.builtin.SourceLocation,
) HResultError!void {
    if (result >= 0) return;

    std.log.err("HRESULT failed at {s}:{d} in {s}: 0x{x:0>8}", .{
        src.file,
        src.line,
        src.fn_name,
        @as(u32, @bitCast(result)),
    });

    return error.HResultFailed;
}

pub fn ComPtr(comptime T: type) type {
    return struct {
        ptr: ?*T = null,

        const Self = @This();

        /// Takes ownership of an existing COM reference.
        /// Use this for functions that already returned an AddRef'd pointer.
        pub fn adopt(ptr: ?*T) Self {
            return .{ .ptr = ptr };
        }

        /// Borrows a COM pointer and creates a new owned reference.
        pub fn init(ptr: ?*T) Self {
            if (ptr) |p| {
                _ = p.lpVtbl.*.AddRef.?(p);
            }

            return .{ .ptr = ptr };
        }

        pub fn deinit(self: *Self) void {
            if (self.ptr) |p| {
                _ = p.lpVtbl.*.Release.?(p);
                self.ptr = null;
            }
        }

        pub fn get(self: Self) ?*T {
            return self.ptr;
        }

        pub fn unwrap(self: Self) *T {
            return self.ptr.?;
        }

        /// Creates another ComPtr owning the same COM object.
        pub fn clone(self: Self) Self {
            if (self.ptr) |p| {
                _ = p.lpVtbl.*.AddRef.?(p);
            }

            return .{ .ptr = self.ptr };
        }

        /// Releases the old pointer and adopts a new already-owned reference.
        pub fn attach(self: *Self, ptr: ?*T) void {
            self.deinit();
            self.ptr = ptr;
        }

        /// Releases ownership without calling Release.
        pub fn detach(self: *Self) ?*T {
            const p = self.ptr;
            self.ptr = null;
            return p;
        }

        /// Releases the current pointer, then returns storage for a COM out-param.
        ///
        /// Example:
        ///     try device.CreateCommittedResource(..., resource.outPtr());
        pub fn outPtr(self: *Self) *?*T {
            self.deinit();
            return &self.ptr;
        }

        /// Sets a new pointer by borrowing it, AddRef'ing the new value first.
        pub fn reset(self: *Self, ptr: ?*T) void {
            if (ptr) |p| {
                _ = p.lpVtbl.*.AddRef.?(p);
            }

            self.deinit();
            self.ptr = ptr;
        }
    };
}
