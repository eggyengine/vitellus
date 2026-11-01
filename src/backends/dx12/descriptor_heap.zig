//! A DirectX 12 descriptor heap that hands out ranges from a free list and grows when full.
const std = @import("std");
const dx = @import("dx12_c");
const utils = @import("utils.zig");
const ComPtr = utils.ComPtr;
const checkHr = utils.checkHr;

const log = std.log.scoped(.dx12_descriptors);

/// Descriptors are written to CPU-only heaps. Render-target and depth-stencil heaps grow by
/// adding pages of their first size, which never move. Shader-visible heaps must be one heap
/// per kind while drawing, so they double instead: their descriptors are copied (`publish`)
/// from a CPU-only twin, which growth copies into the bigger pair, because D3D12 only copies
/// from CPU-only heaps. Their handles move on growth, so keep indices, not handles.
pub const DescriptorHeap = struct {
    kind: dx.D3D12_DESCRIPTOR_HEAP_TYPE,
    name: []const u8,
    stride: u32,
    max_capacity: u32,
    /// Where descriptors are written: fixed-size pages for CPU-only heaps, or a shader-visible
    /// heap's one CPU-only twin.
    pages: std.ArrayList(Page) = .empty,
    page_size: u32,
    /// What shaders read; empty for render-target and depth-stencil heaps.
    gpu_heap: ComPtr(dx.ID3D12DescriptorHeap) = .{},
    gpu_cpu_start: dx.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    gpu_start: dx.D3D12_GPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    ranges: FreeRanges = .{},
    /// Shader-visible heaps outgrown while command lists may still read them.
    // ponytail: outgrown heaps live until the device goes (at most as much as the live heap,
    // since each growth doubles); retire them by fence if that ever matters.
    outgrown: std.ArrayList(ComPtr(dx.ID3D12DescriptorHeap)) = .empty,
    /// Bumped when a shader-visible heap grows, so command lists know to bind the new one.
    generation: u32 = 0,

    pub const Visibility = enum { cpu_only, shader_visible };

    const Page = struct {
        heap: ComPtr(dx.ID3D12DescriptorHeap),
        start: dx.D3D12_CPU_DESCRIPTOR_HANDLE,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        device: *dx.ID3D12Device,
        kind: dx.D3D12_DESCRIPTOR_HEAP_TYPE,
        visibility: Visibility,
        capacity: u32,
        max_capacity: u32,
        name: []const u8,
    ) !DescriptorHeap {
        var self: DescriptorHeap = .{
            .kind = kind,
            .name = name,
            .stride = device.lpVtbl.*.GetDescriptorHandleIncrementSize.?(device, kind),
            .max_capacity = max_capacity,
            .page_size = capacity,
            .ranges = .{ .page = if (visibility == .cpu_only) capacity else null },
        };
        errdefer self.deinit(allocator);
        try self.pages.ensureTotalCapacity(allocator, 1);
        self.pages.appendAssumeCapacity(try self.makePage(allocator, device, capacity));
        if (visibility == .shader_visible) try self.makeVisible(allocator, device, capacity);
        try self.ranges.release(allocator, 0, capacity);
        return self;
    }

    pub fn deinit(self: *DescriptorHeap, allocator: std.mem.Allocator) void {
        for (self.outgrown.items) |*heap| heap.deinit();
        self.outgrown.deinit(allocator);
        self.ranges.deinit(allocator);
        self.gpu_heap.deinit();
        for (self.pages.items) |*page| page.heap.deinit();
        self.pages.deinit(allocator);
    }

    /// `count` consecutive descriptors, growing the heap when no free range fits.
    pub fn allocate(self: *DescriptorHeap, allocator: std.mem.Allocator, device: *dx.ID3D12Device, count: u32) !u32 {
        if (count == 0) return error.EmptyDescriptorRange;
        if (try self.ranges.take(allocator, count)) |index| return index;
        try self.grow(allocator, device, count);
        return (try self.ranges.take(allocator, count)) orelse error.DescriptorHeapFull;
    }

    /// Return a range `allocate` gave. Never fails: `allocate` reserved room to remember it.
    pub fn free(self: *DescriptorHeap, index: u32, count: u32) void {
        self.ranges.give(index, count);
    }

    /// Where descriptor `index` is written.
    pub fn cpu(self: *const DescriptorHeap, index: u32) dx.D3D12_CPU_DESCRIPTOR_HANDLE {
        const page = self.pages.items[index / self.page_size];
        return .{ .ptr = page.start.ptr + @as(usize, index % self.page_size) * self.stride };
    }

    /// Where shaders read descriptor `index`; the heap must be shader-visible.
    pub fn gpu(self: *const DescriptorHeap, index: u32) dx.D3D12_GPU_DESCRIPTOR_HANDLE {
        return .{ .ptr = self.gpu_start.ptr + @as(u64, index) * self.stride };
    }

    /// Copy descriptors written at `index..index + count` to where shaders read them.
    pub fn publish(self: *const DescriptorHeap, device: *dx.ID3D12Device, index: u32, count: u32) void {
        if (self.gpu_heap.get() == null or count == 0) return;
        const destination: dx.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = self.gpu_cpu_start.ptr + @as(usize, index) * self.stride };
        device.lpVtbl.*.CopyDescriptorsSimple.?(device, count, destination, self.cpu(index), self.kind);
    }

    /// The shader-visible heap command lists bind.
    pub fn visibleHeap(self: *const DescriptorHeap) *dx.ID3D12DescriptorHeap {
        return self.gpu_heap.unwrap();
    }

    /// Name descriptor `index` for RenderDoc, in the heap it is read from.
    pub fn nameDescriptor(self: *const DescriptorHeap, allocator: std.mem.Allocator, index: u32, label: ?[]const u8) void {
        if (self.gpu_heap.get()) |heap| return utils.setRenderDocDescriptorName(allocator, heap, index, label);
        utils.setRenderDocDescriptorName(allocator, self.pages.items[index / self.page_size].heap.unwrap(), index % self.page_size, label);
    }

    fn grow(self: *DescriptorHeap, allocator: std.mem.Allocator, device: *dx.ID3D12Device, count: u32) !void {
        const capacity = self.ranges.end;
        if (capacity >= self.max_capacity or count > self.max_capacity - capacity) return error.DescriptorHeapFull;
        if (self.gpu_heap.get() == null) return self.addPage(allocator, device, count);

        const grown = @min(@max(capacity *| 2, capacity + count), self.max_capacity);
        try self.outgrown.ensureUnusedCapacity(allocator, 2);
        try self.ranges.reserve(allocator);
        // Built beside the live pair, so a failure leaves it as it was.
        var next: DescriptorHeap = .{ .kind = self.kind, .name = self.name, .stride = self.stride, .max_capacity = self.max_capacity, .page_size = grown };
        var twin = try next.makePage(allocator, device, grown);
        errdefer twin.heap.deinit();
        try next.makeVisible(allocator, device, grown);
        errdefer next.gpu_heap.deinit();
        device.lpVtbl.*.CopyDescriptorsSimple.?(device, capacity, twin.start, self.pages.items[0].start, self.kind);
        device.lpVtbl.*.CopyDescriptorsSimple.?(device, capacity, next.gpu_cpu_start, twin.start, self.kind);

        self.outgrown.appendAssumeCapacity(self.pages.items[0].heap);
        self.outgrown.appendAssumeCapacity(self.gpu_heap);
        self.pages.items[0] = twin;
        self.page_size = grown;
        self.gpu_heap = next.gpu_heap;
        self.gpu_cpu_start = next.gpu_cpu_start;
        self.gpu_start = next.gpu_start;
        self.ranges.add(capacity, grown - capacity);
        self.ranges.end = grown;
        self.generation +%= 1;
        log.info("{s} heap grew from {d} to {d} descriptors", .{ self.name, capacity, grown });
    }

    fn addPage(self: *DescriptorHeap, allocator: std.mem.Allocator, device: *dx.ID3D12Device, count: u32) !void {
        if (count > self.page_size or self.page_size > self.max_capacity - self.ranges.end) return error.DescriptorHeapFull;
        try self.pages.ensureUnusedCapacity(allocator, 1);
        const page = try self.makePage(allocator, device, self.page_size);
        self.pages.appendAssumeCapacity(page);
        self.ranges.release(allocator, self.ranges.end, self.page_size) catch |err| {
            var dropped = self.pages.pop().?;
            dropped.heap.deinit();
            return err;
        };
        log.info("{s} heap grew to {d} descriptors", .{ self.name, self.ranges.end });
    }

    fn makePage(self: *const DescriptorHeap, allocator: std.mem.Allocator, device: *dx.ID3D12Device, capacity: u32) !Page {
        var page: Page = .{ .heap = .{}, .start = .{ .ptr = 0 } };
        try makeHeap(device, &page.heap, self.kind, capacity, .cpu_only);
        utils.setD3D12Name(allocator, page.heap.unwrap(), self.name);
        _ = page.heap.unwrap().lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(page.heap.unwrap(), &page.start);
        return page;
    }

    fn makeVisible(self: *DescriptorHeap, allocator: std.mem.Allocator, device: *dx.ID3D12Device, capacity: u32) !void {
        try makeHeap(device, &self.gpu_heap, self.kind, capacity, .shader_visible);
        utils.setD3D12Name(allocator, self.gpu_heap.unwrap(), self.name);
        const heap = self.gpu_heap.unwrap();
        _ = heap.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(heap, &self.gpu_cpu_start);
        _ = heap.lpVtbl.*.GetGPUDescriptorHandleForHeapStart.?(heap, &self.gpu_start);
    }
};

fn makeHeap(device: *dx.ID3D12Device, output: *ComPtr(dx.ID3D12DescriptorHeap), kind: dx.D3D12_DESCRIPTOR_HEAP_TYPE, capacity: u32, visibility: DescriptorHeap.Visibility) !void {
    const desc: dx.D3D12_DESCRIPTOR_HEAP_DESC = .{
        .Type = kind,
        .NumDescriptors = capacity,
        .Flags = if (visibility == .shader_visible) dx.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE else dx.D3D12_DESCRIPTOR_HEAP_FLAG_NONE,
        .NodeMask = 0,
    };
    try checkHr(device.lpVtbl.*.CreateDescriptorHeap.?(device, &desc, &dx.IID_ID3D12DescriptorHeap, @ptrCast(output.put())));
}

/// Free index ranges in `0..end`, sorted and merged, taken first-fit. With `page`, ranges
/// never merge across a multiple of it, so none spans two pages.
const FreeRanges = struct {
    list: std.ArrayList(Range) = .empty,
    page: ?u32 = null,
    /// One past the last index handed out or free: the heap's capacity.
    end: u32 = 0,
    /// Ranges handed out and not yet given back.
    live: u32 = 0,

    const Range = struct { start: u32, count: u32 };

    fn deinit(self: *FreeRanges, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
    }

    // Each live range, and each page boundary, can split the free list once more, so keep
    // room for one range per live one and per page, plus the tail and the range about to be
    // taken: `give` never allocates.
    fn reserve(self: *FreeRanges, allocator: std.mem.Allocator) !void {
        const pages = if (self.page) |size| self.end / size + 1 else 0;
        try self.list.ensureTotalCapacity(allocator, @as(usize, self.live) + pages + 3);
    }

    fn release(self: *FreeRanges, allocator: std.mem.Allocator, start: u32, count: u32) !void {
        try self.reserve(allocator);
        self.add(start, count);
        self.end = @max(self.end, start + count);
    }

    fn take(self: *FreeRanges, allocator: std.mem.Allocator, count: u32) !?u32 {
        try self.reserve(allocator);
        for (self.list.items, 0..) |*range, i| {
            if (range.count < count) continue;
            const start = range.start;
            range.start += count;
            range.count -= count;
            if (range.count == 0) _ = self.list.orderedRemove(i);
            self.live += 1;
            return start;
        }
        return null;
    }

    fn give(self: *FreeRanges, start: u32, count: u32) void {
        self.live -|= 1;
        self.add(start, count);
    }

    // Mark `start..start + count` free; the caller made room with `reserve`.
    fn add(self: *FreeRanges, start: u32, count: u32) void {
        if (count == 0) return;
        var at: usize = 0;
        while (at < self.list.items.len and self.list.items[at].start < start) : (at += 1) {}
        const at_page_start = if (self.page) |size| start % size == 0 else false;
        const at_page_end = if (self.page) |size| (start + count) % size == 0 else false;
        const joins_before = !at_page_start and at > 0 and self.list.items[at - 1].start + self.list.items[at - 1].count == start;
        const joins_after = !at_page_end and at < self.list.items.len and start + count == self.list.items[at].start;
        if (joins_before and joins_after) {
            self.list.items[at - 1].count += count + self.list.items[at].count;
            _ = self.list.orderedRemove(at);
        } else if (joins_before) {
            self.list.items[at - 1].count += count;
        } else if (joins_after) {
            self.list.items[at].start = start;
            self.list.items[at].count += count;
        } else {
            self.list.insertAssumeCapacity(at, .{ .start = start, .count = count });
        }
    }
};

test "freed ranges merge with their neighbours and are reused first-fit" {
    const gpa = std.testing.allocator;
    var ranges: FreeRanges = .{};
    defer ranges.deinit(gpa);
    try ranges.release(gpa, 0, 10);

    const a = (try ranges.take(gpa, 3)).?;
    const b = (try ranges.take(gpa, 3)).?;
    const c = (try ranges.take(gpa, 3)).?;
    try std.testing.expectEqual(@as(u32, 0), a);
    try std.testing.expectEqual(@as(u32, 3), b);
    try std.testing.expectEqual(@as(u32, 6), c);
    // One descriptor left, so four don't fit until a neighbour comes back.
    try std.testing.expectEqual(@as(?u32, null), try ranges.take(gpa, 4));

    ranges.give(a, 3);
    ranges.give(c, 3);
    try std.testing.expectEqual(@as(usize, 2), ranges.list.items.len);
    ranges.give(b, 3);
    try std.testing.expectEqual(@as(usize, 1), ranges.list.items.len);
    try std.testing.expectEqual(@as(u32, 0), (try ranges.take(gpa, 10)).?);
}

test "growth adds its new descriptors after the old ones" {
    const gpa = std.testing.allocator;
    var ranges: FreeRanges = .{};
    defer ranges.deinit(gpa);
    try ranges.release(gpa, 0, 4);
    try std.testing.expectEqual(@as(u32, 0), (try ranges.take(gpa, 4)).?);
    try ranges.reserve(gpa);
    ranges.add(4, 4);
    ranges.end = 8;
    try std.testing.expectEqual(@as(u32, 4), (try ranges.take(gpa, 4)).?);
    try std.testing.expectEqual(@as(?u32, null), try ranges.take(gpa, 1));
}

test "paged ranges never merge across a page boundary" {
    const gpa = std.testing.allocator;
    var ranges: FreeRanges = .{ .page = 4 };
    defer ranges.deinit(gpa);
    try ranges.release(gpa, 0, 4);
    try ranges.release(gpa, 4, 4);
    try std.testing.expectEqual(@as(usize, 2), ranges.list.items.len);
    // Six free in a row, but split over two pages.
    try std.testing.expectEqual(@as(?u32, null), try ranges.take(gpa, 6));
    try std.testing.expectEqual(@as(u32, 0), (try ranges.take(gpa, 4)).?);
}
