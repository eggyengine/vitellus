// Vulkan Memory Allocator's implementation, behind the few C calls `vma.zig` declares.
#include <cstdio>

#define VMA_IMPLEMENTATION
// Vulkan is loaded at run time (instance.zig), so VMA fetches its functions the same way.
#define VMA_STATIC_VULKAN_FUNCTIONS 0
#define VMA_DYNAMIC_VULKAN_FUNCTIONS 1
// A resource still alive at shutdown is reported, not fatal: the app is exiting anyway.
#define VMA_ASSERT_LEAK(expr) \
    do { \
        if (!(expr)) std::fprintf(stderr, "vitellus: GPU memory still allocated at device destruction\n"); \
    } while (0)
#include "vk_mem_alloc.h"

extern "C" {

VkResult vit_vma_create_allocator(
    VkInstance instance,
    VkPhysicalDevice physical_device,
    VkDevice device,
    uint32_t api_version,
    PFN_vkGetInstanceProcAddr get_instance_proc_addr,
    PFN_vkGetDeviceProcAddr get_device_proc_addr,
    VmaAllocator* out) {
    VmaVulkanFunctions functions = {};
    functions.vkGetInstanceProcAddr = get_instance_proc_addr;
    functions.vkGetDeviceProcAddr = get_device_proc_addr;
    VmaAllocatorCreateInfo info = {};
    info.instance = instance;
    info.physicalDevice = physical_device;
    info.device = device;
    info.vulkanApiVersion = api_version;
    info.pVulkanFunctions = &functions;
    return vmaCreateAllocator(&info, out);
}

void vit_vma_destroy_allocator(VmaAllocator allocator) {
    vmaDestroyAllocator(allocator);
}

// Matches `vma.HostAccess`.
enum VitHostAccess { VIT_HOST_NONE = 0, VIT_HOST_WRITE = 1, VIT_HOST_READ = 2 };

// Host-visible memory is coherent and mapped for the buffer's life, so mapping is free and
// needs no flushes.
VkResult vit_vma_create_buffer(
    VmaAllocator allocator,
    const VkBufferCreateInfo* buffer_info,
    int host_access,
    VkBuffer* buffer,
    VmaAllocation* allocation,
    void** mapped) {
    VmaAllocationCreateInfo info = {};
    info.usage = VMA_MEMORY_USAGE_AUTO;
    switch (host_access) {
    case VIT_HOST_WRITE:
        info.flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_SEQUENTIAL_WRITE_BIT | VMA_ALLOCATION_CREATE_MAPPED_BIT;
        info.requiredFlags = VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        break;
    case VIT_HOST_READ:
        info.flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT | VMA_ALLOCATION_CREATE_MAPPED_BIT;
        info.requiredFlags = VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        info.preferredFlags = VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
        break;
    default:
        info.usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
        break;
    }
    VmaAllocationInfo result = {};
    const VkResult status = vmaCreateBuffer(allocator, buffer_info, &info, buffer, allocation, &result);
    *mapped = status == VK_SUCCESS ? result.pMappedData : nullptr;
    return status;
}

void vit_vma_destroy_buffer(VmaAllocator allocator, VkBuffer buffer, VmaAllocation allocation) {
    vmaDestroyBuffer(allocator, buffer, allocation);
}

VkResult vit_vma_create_image(
    VmaAllocator allocator,
    const VkImageCreateInfo* image_info,
    VkImage* image,
    VmaAllocation* allocation) {
    VmaAllocationCreateInfo info = {};
    info.usage = VMA_MEMORY_USAGE_AUTO_PREFER_DEVICE;
    // Render targets are resized and recreated often; their own memory keeps blocks unfragmented.
    if (image_info->usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT))
        info.flags = VMA_ALLOCATION_CREATE_DEDICATED_MEMORY_BIT;
    return vmaCreateImage(allocator, image_info, &info, image, allocation, nullptr);
}

void vit_vma_destroy_image(VmaAllocator allocator, VkImage image, VmaAllocation allocation) {
    vmaDestroyImage(allocator, image, allocation);
}

} // extern "C"
