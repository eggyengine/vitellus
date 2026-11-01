//! Places DirectX 12 buffers and textures in large shared heaps with the D3D12 Memory Allocator (`d3d12ma.cpp`).
const dx = @import("dx12_c");
const MemoryBudget = @import("../../interface/device.zig").MemoryBudget;
const checkHr = @import("utils.zig").checkHr;

pub const Allocator = *opaque {};
pub const Allocation = *opaque {};

/// Whether a resource shares a heap with others or gets its own.
pub const Placement = enum(c_int) { shared = 0, committed = 1 };

/// The allocator for `device`; destroy it before the device, after every resource it made.
pub fn createAllocator(device: *dx.ID3D12Device, adapter: *dx.IDXGIAdapter) !Allocator {
    var allocator: ?Allocator = null;
    try checkHr(vit_d3d12ma_create_allocator(device, adapter, &allocator));
    return allocator orelse error.HrFailed;
}

/// Destroy the allocator, after every allocation it made is released.
pub fn destroyAllocator(allocator: Allocator) void {
    vit_d3d12ma_destroy_allocator(allocator);
}

/// Creates a resource in `heap_type` memory. The caller owns both: release the resource, then
/// the allocation (`releaseAllocation`).
pub fn createResource(
    allocator: Allocator,
    heap_type: dx.D3D12_HEAP_TYPE,
    placement: Placement,
    desc: *const dx.D3D12_RESOURCE_DESC,
    initial_state: dx.D3D12_RESOURCE_STATES,
    resource: *?*dx.ID3D12Resource,
) !Allocation {
    var allocation: ?Allocation = null;
    try checkHr(vit_d3d12ma_create_resource(allocator, heap_type, placement, desc, initial_state, &allocation, resource));
    return allocation orelse error.HrFailed;
}

/// Free an allocation's memory, after releasing its resource.
pub fn releaseAllocation(allocation: Allocation) void {
    vit_d3d12ma_release_allocation(allocation);
}

extern fn vit_d3d12ma_create_allocator(*dx.ID3D12Device, *dx.IDXGIAdapter, *?Allocator) dx.HRESULT;
extern fn vit_d3d12ma_destroy_allocator(Allocator) void;
extern fn vit_d3d12ma_create_resource(Allocator, dx.D3D12_HEAP_TYPE, Placement, *const dx.D3D12_RESOURCE_DESC, dx.D3D12_RESOURCE_STATES, *?Allocation, *?*dx.ID3D12Resource) dx.HRESULT;
extern fn vit_d3d12ma_release_allocation(Allocation) void;
extern fn vit_d3d12ma_budget(Allocator, *[4]u64) void;

/// Video memory in use and allowed, then system memory the GPU reads.
pub fn budget(allocator: Allocator) MemoryBudget {
    var totals: [4]u64 = @splat(0);
    vit_d3d12ma_budget(allocator, &totals);
    return .{
        .device_local = .{ .usage_bytes = totals[0], .budget_bytes = totals[1] },
        .shared = .{ .usage_bytes = totals[2], .budget_bytes = totals[3] },
    };
}
