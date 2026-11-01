// D3D12 Memory Allocator behind the few C calls `d3d12ma.zig` declares.
#include <cstdio>
#include "D3D12MemAlloc.h"

extern "C" {

HRESULT vit_d3d12ma_create_allocator(ID3D12Device* device, IDXGIAdapter* adapter, D3D12MA::Allocator** out) {
    D3D12MA::ALLOCATOR_DESC desc = {};
    desc.pDevice = device;
    desc.pAdapter = adapter;
    return D3D12MA::CreateAllocator(&desc, out);
}

void vit_d3d12ma_destroy_allocator(D3D12MA::Allocator* allocator) {
    allocator->Release();
}

// `committed` gives the resource its own heap: render targets are resized and remade often,
// and keeping them out of shared blocks avoids fragmenting those.
HRESULT vit_d3d12ma_create_resource(
    D3D12MA::Allocator* allocator,
    D3D12_HEAP_TYPE heap_type,
    int committed,
    const D3D12_RESOURCE_DESC* resource_desc,
    D3D12_RESOURCE_STATES initial_state,
    D3D12MA::Allocation** allocation,
    ID3D12Resource** resource) {
    D3D12MA::ALLOCATION_DESC desc = {};
    desc.HeapType = heap_type;
    if (committed) desc.Flags = D3D12MA::ALLOCATION_FLAG_COMMITTED;
    return allocator->CreateResource(&desc, resource_desc, initial_state, nullptr, allocation, IID_PPV_ARGS(resource));
}

// Releases the allocation's memory; the resource must already be released.
void vit_d3d12ma_release_allocation(D3D12MA::Allocation* allocation) {
    allocation->Release();
}

} // extern "C"
