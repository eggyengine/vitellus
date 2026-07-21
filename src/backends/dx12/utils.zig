//! DirectX 12 utility types and helpers.

const std = @import("std");
const windows = std.os.windows;
const dx = @import("dx.zig").c;

const log = std.log.scoped(.dx12_names);

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
/// `T` should be a COM interface type - an `extern struct` whose first field
/// is a vtable pointer beginning with the three `IUnknown` slots
/// (`QueryInterface`, `AddRef`, `Release`).
///
/// **Ownership semantics**
/// - `ComPtr(T){}` - empty (null); no resource held.
/// - `ComPtr(T).attach(raw)` - takes ownership of `raw` without `AddRef`.
///   Use this immediately after a factory function that already returned a
///   new reference.
/// - `.clone()` - increments the reference count and returns a new owner.
/// - `.deinit()` - decrements the reference count and nulls the pointer.
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
        /// Idempotent - safe to call multiple times or on an empty `ComPtr`.
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
    if (hr < 0) {
        std.log.err("HRESULT 0x{X:0>8} ({})", .{ @as(u32, @bitCast(hr)), hr });
        return error.HrFailed;
    }
}

/// Assigns a UTF-8 debug label to an ID3D12Object-derived interface.
/// Naming is deliberately best-effort: an invalid label or a debug-runtime
/// failure must not make otherwise valid GPU object creation fail.
pub fn setD3D12Name(allocator: std.mem.Allocator, object: anytype, label: ?[]const u8) void {
    const name = label orelse return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, name) catch |err| {
        log.warn("could not encode DX12 object label '{s}': {}", .{ name, err });
        return;
    };
    defer allocator.free(wide);

    const hr = object.lpVtbl.*.SetName.?(object, wide.ptr);
    if (hr < 0) log.warn("could not set DX12 object label '{s}': HRESULT 0x{X:0>8}", .{ name, @as(u32, @bitCast(hr)) });
}

/// Assigns a UTF-8 debug label to an IDXGIObject-derived interface.
pub fn setDxgiName(object: anytype, label: ?[]const u8) void {
    const name = label orelse return;
    const hr = object.lpVtbl.*.SetPrivateData.?(
        object,
        &dx.WKPDID_D3DDebugObjectName,
        @intCast(name.len),
        if (name.len == 0) null else @ptrCast(name.ptr),
    );
    if (hr < 0) log.warn("could not set DXGI object label '{s}': HRESULT 0x{X:0>8}", .{ name, @as(u32, @bitCast(hr)) });
}

/// Builds a short derived name and applies it to a D3D12 object.
pub fn setD3D12DerivedName(allocator: std.mem.Allocator, object: anytype, label: ?[]const u8, suffix: []const u8) void {
    const base = label orelse return;
    const name = std.fmt.allocPrint(allocator, "{s} {s}", .{ base, suffix }) catch return;
    defer allocator.free(name);
    setD3D12Name(allocator, object, name);
}

const RenderDocDescriptorNamer = extern struct {
    lpVtbl: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*RenderDocDescriptorNamer, *const windows.GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*RenderDocDescriptorNamer) callconv(.winapi) windows.ULONG,
        Release: *const fn (*RenderDocDescriptorNamer) callconv(.winapi) windows.ULONG,
        SetName: *const fn (*RenderDocDescriptorNamer, dx.UINT, [*:0]const u8) callconv(.winapi) HRESULT,
    };
};

const renderdoc_descriptor_namer_iid = windows.GUID{
    .Data1 = 0x52528c37,
    .Data2 = 0xbfd9,
    .Data3 = 0x4bbb,
    .Data4 = .{ 0x99, 0xff, 0xfd, 0xb7, 0x18, 0x86, 0x19, 0xce },
};

/// Names one descriptor when running under RenderDoc 1.37 or newer. Outside
/// RenderDoc the private interface is absent and this is a no-op.
pub fn setRenderDocDescriptorName(allocator: std.mem.Allocator, heap: *dx.ID3D12DescriptorHeap, index: u32, label: ?[]const u8) void {
    const name = label orelse return;
    var raw: ?*anyopaque = null;
    const query_hr = heap.lpVtbl.*.QueryInterface.?(
        heap,
        @ptrCast(&renderdoc_descriptor_namer_iid),
        &raw,
    );
    if (query_hr < 0 or raw == null) return;

    const namer: *RenderDocDescriptorNamer = @ptrCast(@alignCast(raw.?));
    defer _ = namer.lpVtbl.Release(namer);
    const terminated = allocator.dupeZ(u8, name) catch return;
    defer allocator.free(terminated);
    _ = namer.lpVtbl.SetName(namer, index, terminated.ptr);
}
