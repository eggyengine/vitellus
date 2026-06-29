//! DirectX 12 utility types and helpers.

const std = @import("std");
const windows = std.os.windows;

pub const HRESULT = i32;

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) windows.ULONG,
    Release: *const fn (*anyopaque) callconv(.winapi) windows.ULONG,
};

const IUnknownLayout = extern struct {
    vtbl: *const IUnknownVtbl,
};

/// Zig equivalent of `Microsoft::WRL::ComPtr<T>`.
///
/// Manages the lifetime of a COM interface pointer via reference counting.
/// `T` should be a COM interface type — an `extern struct` whose first field
/// is a vtable pointer beginning with the three `IUnknown` slots
/// (`QueryInterface`, `AddRef`, `Release`).
///
/// **Ownership semantics**
/// - `ComPtr(T){}` — empty (null); no resource held.
/// - `ComPtr(T).attach(raw)` — takes ownership of `raw` without `AddRef`.
///   Use this immediately after a factory function that already returned a
///   new reference.
/// - `.clone()` — increments the reference count and returns a new owner.
/// - `.deinit()` — decrements the reference count and nulls the pointer.
///   Safe to call on a null `ComPtr`; idempotent.
///
/// **Common factory pattern**
/// ```zig
/// var device: ComPtr(ID3D12Device) = .{};
/// defer device.deinit();
/// try checkHr(D3D12CreateDevice(
///     adapter, level, &IID_ID3D12Device,
///     @ptrCast(device.put()),   // *?*ID3D12Device → *?*anyopaque
/// ));
/// ```
///
/// **QueryInterface pattern**
/// ```zig
/// var debug = try device.as(ID3D12DebugDevice, &IID_ID3D12DebugDevice);
/// defer debug.deinit();
/// ```
pub fn ComPtr(comptime T: type) type {
    return struct {
        ptr: ?*T = null,

        const Self = @This();

        /// Wraps `raw`, taking ownership without calling `AddRef`.
        pub fn attach(raw: *T) Self {
            return .{ .ptr = raw };
        }

        /// Returns `true` if the internal pointer is null.
        pub fn isNull(self: Self) bool {
            return self.ptr == null;
        }

        /// Returns the raw interface pointer, or `null` if empty.
        pub fn get(self: Self) ?*T {
            return self.ptr;
        }

        /// Returns the raw interface pointer, panicking if it is null.
        pub fn unwrap(self: Self) *T {
            return self.ptr orelse @panic("ComPtr.unwrap: pointer is null");
        }

        /// Calls `AddRef` and returns a new `ComPtr` sharing the same object.
        pub fn clone(self: Self) Self {
            if (self.ptr) |p| {
                const unk: *IUnknownLayout = @ptrCast(@alignCast(p));
                _ = unk.vtbl.AddRef(@ptrCast(p));
            }
            return .{ .ptr = self.ptr };
        }

        /// Calls `Release` on the managed pointer (if non-null) and nulls it.
        /// Idempotent — safe to call multiple times or on an empty `ComPtr`.
        pub fn deinit(self: *Self) void {
            if (self.ptr) |p| {
                const unk: *IUnknownLayout = @ptrCast(@alignCast(p));
                _ = unk.vtbl.Release(@ptrCast(p));
                self.ptr = null;
            }
        }

        /// Releases any held reference and returns a pointer-to-pointer for
        /// use as an output parameter in factory functions.
        ///
        /// After the factory call succeeds, the `ComPtr` owns the new reference.
        pub fn put(self: *Self) *?*T {
            self.deinit();
            return &self.ptr;
        }

        /// Returns the address of the internal pointer *without* releasing it.
        /// Useful when passing `**T` to a function that is known to not release
        /// the existing value (e.g. `GetParent`-style queries).
        pub fn getAddressOf(self: *Self) *?*T {
            return &self.ptr;
        }

        /// Queries the underlying object for a different COM interface `U` via
        /// `IUnknown::QueryInterface`.
        ///
        /// On success the returned `ComPtr(U)` holds a new reference; the
        /// caller is responsible for calling `deinit()` on it.
        /// Returns `error.NoInterface` if `QueryInterface` fails.
        pub fn as(self: Self, comptime U: type, iid: anytype) error{NoInterface}!ComPtr(U) {
            const p = self.ptr orelse return error.NoInterface;
            var out: ?*U = null;
            const unk: *IUnknownLayout = @ptrCast(@alignCast(p));
            const guid: *const windows.GUID = @ptrCast(@alignCast(iid));
            const hr = unk.vtbl.QueryInterface(@ptrCast(p), guid, @ptrCast(&out));
            if (hr < 0) return error.NoInterface;
            return ComPtr(U){ .ptr = out };
        }
    };
}

/// Returned by `checkHr` when a COM call reports failure (negative HRESULT).
pub const HrError = error{
    /// The operation returned a negative HRESULT (COM failure code).
    HrFailed,
};

/// Converts a COM `HRESULT` into a Zig error.
///
/// Returns `void` on success (HRESULT ≥ 0) and `error.HrFailed` on failure
/// (HRESULT < 0).  Use this to integrate COM calls into `try` expressions:
///
///   try checkHr(device.lpVtbl.?.CreateCommandQueue.?(device, &desc, &IID_..., @ptrCast(queue.put())));
pub fn checkHr(hr: HRESULT) HrError!void {
    if (hr < 0) return error.HrFailed;
}
