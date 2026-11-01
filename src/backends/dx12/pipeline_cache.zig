//! Keeps the DirectX 12 driver's compiled pipelines between runs, each under a hash of what it was made from.
const std = @import("std");
const dx = @import("dx12_c");
const Dx12Device = @import("device.zig").Dx12Device;
const utils = @import("utils.zig");
const ShaderDiskCache = @import("../../shader_disk_cache.zig").ShaderDiskCache;
const ComPtr = utils.ComPtr;

const log = std.log.scoped(.dx12_pipeline_cache);

/// Builds a pipeline's key from everything that shapes it, field by field, so struct padding
/// and pointers never reach the hash: hash what pointers point at with `bytes`.
pub const Hasher = struct {
    inner: std.crypto.hash.Blake3,

    /// A key for one `kind` of pipeline made on `device`'s GPU.
    pub fn init(device: *const Dx12Device, kind: []const u8) Hasher {
        var self: Hasher = .{ .inner = .init(.{}) };
        self.bytes("d3d12 pipeline state");
        self.bytes(kind);
        self.value(device.vendor_id);
        self.value(device.device_id);
        return self;
    }

    /// Hash `data` with its length, so neighbouring parts can't run together.
    pub fn bytes(self: *Hasher, data: []const u8) void {
        self.inner.update(std.mem.asBytes(&std.mem.nativeToLittle(u64, data.len)));
        self.inner.update(data);
    }

    /// Hash every number in `item`, recursing into structs and arrays and skipping pointers.
    pub fn value(self: *Hasher, item: anytype) void {
        const T = @TypeOf(item);
        switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.field_names) |name| self.value(@field(item, name)),
            .array => for (item) |element| self.value(element),
            .int, .float, .bool, .@"enum" => self.inner.update(std.mem.asBytes(&item)),
            .pointer, .optional => {},
            else => @compileError("can't hash a " ++ @typeName(T)),
        }
    }

    pub fn finish(self: *Hasher) ShaderDiskCache.Key {
        var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
        self.inner.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }
};

/// Make the pipeline state `desc` describes (a graphics or compute desc) into `output`. With
/// `key`, a blob saved under it is offered to the driver first; one it refuses (another driver
/// version) is dropped, and the freshly compiled pipeline is saved in its place.
pub fn create(device: *Dx12Device, desc: anytype, key: ?ShaderDiskCache.Key, output: *ComPtr(dx.ID3D12PipelineState)) !void {
    const disk = device.disk;
    const saved = if (key != null and disk != null) disk.?.load(device.allocator, key.?) else null;
    defer if (saved) |blob| device.allocator.free(blob);
    if (saved) |blob| {
        desc.CachedPSO = .{ .pCachedBlob = blob.ptr, .CachedBlobSizeInBytes = blob.len };
        defer desc.CachedPSO = .{ .pCachedBlob = null, .CachedBlobSizeInBytes = 0 };
        const hr = make(device, desc, output);
        if (hr >= 0) return;
        output.deinit();
        log.info("saved pipeline refused (HRESULT 0x{X:0>8}); compiling it again", .{@as(u32, @bitCast(hr))});
    }
    const hr = make(device, desc, output);
    if (hr < 0) device.debug_device.logMessages();
    try utils.checkHr(hr);
    if (key != null and disk != null) store(disk.?, key.?, output.unwrap());
}

fn make(device: *Dx12Device, desc: anytype, output: *ComPtr(dx.ID3D12PipelineState)) dx.HRESULT {
    const raw = device.device.unwrap();
    return switch (@TypeOf(desc)) {
        *dx.D3D12_GRAPHICS_PIPELINE_STATE_DESC => raw.lpVtbl.*.CreateGraphicsPipelineState.?(raw, desc, &dx.IID_ID3D12PipelineState, @ptrCast(output.put())),
        *dx.D3D12_COMPUTE_PIPELINE_STATE_DESC => raw.lpVtbl.*.CreateComputePipelineState.?(raw, desc, &dx.IID_ID3D12PipelineState, @ptrCast(output.put())),
        else => @compileError("not a pipeline state desc: " ++ @typeName(@TypeOf(desc))),
    };
}

fn store(disk: *const ShaderDiskCache, key: ShaderDiskCache.Key, state: *dx.ID3D12PipelineState) void {
    var blob: ComPtr(dx.ID3DBlob) = .{};
    defer blob.deinit();
    const hr = state.lpVtbl.*.GetCachedBlob.?(state, @ptrCast(blob.put()));
    if (hr < 0) {
        log.debug("driver gave no cached blob (HRESULT 0x{X:0>8})", .{@as(u32, @bitCast(hr))});
        return;
    }
    const raw = blob.unwrap();
    const data: [*]const u8 = @ptrCast(raw.lpVtbl.*.GetBufferPointer.?(raw) orelse return);
    disk.store(key, data[0..raw.lpVtbl.*.GetBufferSize.?(raw)]);
}

test "a key ignores padding and pointers but not values" {
    const Padded = extern struct { small: u8, big: u32, name: ?[*:0]const u8 };
    var first: Padded = undefined;
    @memset(std.mem.asBytes(&first), 0xaa);
    first = .{ .small = 1, .big = 2, .name = "a" };
    var second: Padded = undefined;
    @memset(std.mem.asBytes(&second), 0x55);
    second = .{ .small = 1, .big = 2, .name = "b" };
    var a: Hasher = .{ .inner = .init(.{}) };
    a.value(first);
    var b: Hasher = .{ .inner = .init(.{}) };
    b.value(second);
    const same = a.finish();
    try std.testing.expectEqualSlices(u8, &same, &b.finish());
    second.big = 3;
    var c: Hasher = .{ .inner = .init(.{}) };
    c.value(second);
    try std.testing.expect(!std.mem.eql(u8, &same, &c.finish()));
}
