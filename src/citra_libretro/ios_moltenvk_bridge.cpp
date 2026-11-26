// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
//
// First-stage MoltenVK frontend for Azahar's existing libretro Vulkan PICA200
// renderer. The GPU renders into an offscreen Vulkan image; this bridge reads
// it back to the existing UIImage UI. A bounded staging ring allows the CPU
// to consume completed frames without waiting after every submission.
#include "citra_libretro/ios_moltenvk_bridge.h"

#if defined(IOS) && defined(ENABLE_VULKAN)
#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>
#include <vulkan/vulkan.h>
#if defined(__APPLE__)
#include <vulkan/vulkan_metal.h>
#endif
#include "libretro_vulkan.h"

namespace {
struct StagingSlot {
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkFence copied = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkDeviceSize capacity = 0;
    void* mapped = nullptr;
    bool coherent = false;
    bool pending = false;
    std::uint64_t serial = 0;
    unsigned width = 0;
    unsigned height = 0;
    VkFormat format = VK_FORMAT_UNDEFINED;
    std::chrono::steady_clock::time_point submitted{};
};

struct Context {
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    std::uint32_t queue_family = 0;
    VkCommandPool command_pool = VK_NULL_HANDLE;
    std::array<StagingSlot, 3> slots{};
    std::uint64_t serial = 0;
    bool device_failed = false;
    bool delivered = false;
    bool asynchronous = false;
    unsigned width = 0;
    unsigned height = 0;
    VkImage image = VK_NULL_HANDLE;
    VkImageLayout image_layout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkFormat image_format = VK_FORMAT_UNDEFINED;
    retro_hw_render_interface_vulkan interface{};
    std::mutex queue_mutex;
    std::vector<std::uint8_t> pixels;
#if defined(__APPLE__)
    void* metal_layer = nullptr;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkExtent2D extent{};
    VkFormat surface_format = VK_FORMAT_UNDEFINED;
    unsigned requested_width = 0, requested_height = 0;
    bool rebuild_surface = false;
    struct PresentSlot {
        VkCommandBuffer command = VK_NULL_HANDLE;
        VkSemaphore acquired = VK_NULL_HANDLE;
        VkFence fence = VK_NULL_HANDLE;
        bool pending = false;
    };
    std::array<PresentSlot, 3> present_slots{};
    std::vector<VkImage> present_images;
    std::vector<VkSemaphore> present_ready;
#endif
} state;

bool HasInstanceExtension(const char* name) {
    std::uint32_t count = 0;
    if (vkEnumerateInstanceExtensionProperties(nullptr, &count, nullptr) != VK_SUCCESS)
        return false;
    std::vector<VkExtensionProperties> available(count);
    if (vkEnumerateInstanceExtensionProperties(nullptr, &count, available.data()) != VK_SUCCESS)
        return false;
    return std::any_of(available.begin(), available.end(), [name](const auto& extension) {
        return std::strcmp(extension.extensionName, name) == 0;
    });
}

void SetImage(void*, const retro_vulkan_image* image, unsigned num_semaphores, const VkSemaphore*,
              std::uint32_t) {
    // The current Azahar presenter passes no external semaphores. Reject
    // unsupported ownership transitions rather than reading unfinished data.
    if (!image || num_semaphores != 0) {
        state.image = VK_NULL_HANDLE;
        return;
    }
    state.image = image->create_info.image;
    state.image_layout = image->image_layout;
    state.image_format = image->create_info.format;
}

void LockQueue(void*) {
    state.queue_mutex.lock();
}

void UnlockQueue(void*) {
    state.queue_mutex.unlock();
}

std::uint32_t GetSyncIndex(void*) {
    return 0;
}

std::uint32_t GetSyncMask(void*) {
    return 1;
}

void WaitSyncIndex(void*) {
    // Producer and staging copies are ordered on the same queue; the copy
    // restores the image layout before subsequent rendering. No host wait here.
}

bool CreateStagingBuffer(VkDeviceSize size, VkBuffer& buffer, VkDeviceMemory& memory,
                         bool& coherent) {
    VkBufferCreateInfo create{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    create.size = size;
    create.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    create.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    if (vkCreateBuffer(state.device, &create, nullptr, &buffer) != VK_SUCCESS)
        return false;

    VkMemoryRequirements requirements{};
    vkGetBufferMemoryRequirements(state.device, buffer, &requirements);
    VkPhysicalDeviceMemoryProperties properties{};
    vkGetPhysicalDeviceMemoryProperties(state.gpu, &properties);

    std::uint32_t choice = UINT32_MAX;
    for (std::uint32_t index = 0; index < properties.memoryTypeCount; ++index) {
        if ((requirements.memoryTypeBits & (1u << index)) == 0)
            continue;
        const auto flags = properties.memoryTypes[index].propertyFlags;
        if ((flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0)
            continue;
        if (choice == UINT32_MAX || (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) {
            choice = index;
            coherent = (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
            if (coherent)
                break;
        }
    }
    if (choice == UINT32_MAX)
        return false;
    VkMemoryAllocateInfo allocate{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    allocate.allocationSize = requirements.size;
    allocate.memoryTypeIndex = choice;
    if (vkAllocateMemory(state.device, &allocate, nullptr, &memory) != VK_SUCCESS)
        return false;
    return vkBindBufferMemory(state.device, buffer, memory, 0) == VK_SUCCESS;
}

void ReleaseStagingBuffer(StagingSlot& slot) {
    if (slot.mapped)
        vkUnmapMemory(state.device, slot.memory);
    vkDestroyBuffer(state.device, slot.buffer, nullptr);
    vkFreeMemory(state.device, slot.memory, nullptr);
    slot.buffer = VK_NULL_HANDLE;
    slot.memory = VK_NULL_HANDLE;
    slot.mapped = nullptr;
    slot.capacity = 0;
}

bool EnsureStagingBuffer(StagingSlot& slot, VkDeviceSize size) {
    if (slot.capacity >= size)
        return true;
    ReleaseStagingBuffer(slot);
    if (!CreateStagingBuffer(size, slot.buffer, slot.memory, slot.coherent) ||
        vkMapMemory(state.device, slot.memory, 0, VK_WHOLE_SIZE, 0, &slot.mapped) != VK_SUCCESS) {
        ReleaseStagingBuffer(slot);
        return false;
    }
    slot.capacity = size;
    return true;
}

bool CopyOutput(StagingSlot& slot, unsigned width, unsigned height) {
    const auto command = slot.command;
    if (vkResetCommandBuffer(command, 0) != VK_SUCCESS ||
        vkResetFences(state.device, 1, &slot.copied) != VK_SUCCESS)
        return false;
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(command, &begin) == VK_SUCCESS) {
        VkImageMemoryBarrier before{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        before.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
        before.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        before.oldLayout = state.image_layout;
        before.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        before.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        before.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        before.image = state.image;
        before.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        before.subresourceRange.levelCount = 1;
        before.subresourceRange.layerCount = 1;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                             VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 1, &before);

        VkBufferImageCopy copy{};
        copy.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = {width, height, 1};
        vkCmdCopyImageToBuffer(command, state.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                               slot.buffer, 1, &copy);

        VkBufferMemoryBarrier host{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
        host.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        host.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        host.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        host.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        host.buffer = slot.buffer;
        host.size = VK_WHOLE_SIZE;
        VkImageMemoryBarrier after = before;
        after.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        after.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        after.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        after.newLayout = state.image_layout;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_HOST_BIT, 0, 0,
                             nullptr, 1, &host, 1, &after);

        if (vkEndCommandBuffer(command) == VK_SUCCESS) {
            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &command;
            {
                std::lock_guard lock{state.queue_mutex};
                if (vkQueueSubmit(state.queue, 1, &submit, slot.copied) != VK_SUCCESS) {
                    state.device_failed = true;
                    return false;
                }
            }
            slot.pending = true;
            slot.serial = ++state.serial;
            slot.width = width;
            slot.height = height;
            slot.format = state.image_format;
            slot.submitted = std::chrono::steady_clock::now();
            return true;
        }
    }
    return false;
}

bool WaitCopy(StagingSlot& slot, std::uint64_t timeout) {
    const auto result = vkWaitForFences(state.device, 1, &slot.copied, VK_TRUE, timeout);
    if (result == VK_SUCCESS || result == VK_ERROR_DEVICE_LOST)
        slot.pending = false;
    if (result != VK_SUCCESS)
        state.device_failed = true;
    return result == VK_SUCCESS;
}

bool ReadPixels(StagingSlot& slot, const void** pixels, std::size_t* pitch, bool* rgba) {
    if (!slot.coherent) {
        VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
        range.memory = slot.memory;
        range.offset = 0;
        range.size = VK_WHOLE_SIZE;
        if (vkInvalidateMappedMemoryRanges(state.device, 1, &range) != VK_SUCCESS)
            return false;
    }
    *pixels = slot.mapped;
    *pitch = static_cast<std::size_t>(slot.width) * 4;
    *rgba = slot.format == VK_FORMAT_R8G8B8A8_UNORM;
    state.delivered = true;
    return true;
}
#if defined(__APPLE__)
void DestroySwapchain() {
    // All use of the drawable images and semaphores has finished.
    for (auto semaphore : state.present_ready)
        vkDestroySemaphore(state.device, semaphore, nullptr);
    state.present_ready.clear();
    state.present_images.clear();
    if (state.swapchain)
        vkDestroySwapchainKHR(state.device, state.swapchain, nullptr);
    state.swapchain = VK_NULL_HANDLE;
    state.extent = {};
}

bool CreateSwapchain(unsigned width, unsigned height) {
    if (!state.surface || !state.device || !width || !height)
        return false;
    if (state.swapchain) {
        // Resizing is rare. Never release drawable resources still owned by the GPU.
        std::lock_guard lock{state.queue_mutex};
        if (vkQueueWaitIdle(state.queue) != VK_SUCCESS)
            return false;
        DestroySwapchain();
        for (auto& slot : state.present_slots)
            slot.pending = false;
    }
    VkSurfaceCapabilitiesKHR caps{};
    if (vkGetPhysicalDeviceSurfaceCapabilitiesKHR(state.gpu, state.surface, &caps) != VK_SUCCESS ||
        !(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT))
        return false;
    uint32_t count = 0;
    if (vkGetPhysicalDeviceSurfaceFormatsKHR(state.gpu, state.surface, &count, nullptr) !=
            VK_SUCCESS ||
        !count)
        return false;
    std::vector<VkSurfaceFormatKHR> formats(count);
    if (vkGetPhysicalDeviceSurfaceFormatsKHR(state.gpu, state.surface, &count, formats.data()) !=
        VK_SUCCESS)
        return false;
    VkSurfaceFormatKHR chosen{};
    for (const auto& format : formats) {
        if ((format.format == VK_FORMAT_B8G8R8A8_UNORM ||
             format.format == VK_FORMAT_R8G8B8A8_UNORM || format.format == VK_FORMAT_UNDEFINED) &&
            format.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            chosen = format;
            if (chosen.format == VK_FORMAT_UNDEFINED)
                chosen.format = VK_FORMAT_B8G8R8A8_UNORM;
            break;
        }
    }
    if (chosen.format == VK_FORMAT_UNDEFINED)
        return false;
    VkFormatProperties src{}, dst{};
    vkGetPhysicalDeviceFormatProperties(state.gpu, state.image_format, &src);
    vkGetPhysicalDeviceFormatProperties(state.gpu, chosen.format, &dst);
    if (!(src.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT) ||
        !(dst.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT))
        return false;
    state.extent =
        caps.currentExtent.width != UINT32_MAX
            ? caps.currentExtent
            : VkExtent2D{
                  std::clamp(width, caps.minImageExtent.width, caps.maxImageExtent.width),
                  std::clamp(height, caps.minImageExtent.height, caps.maxImageExtent.height)};
    if (!state.extent.width || !state.extent.height)
        return false;
    const uint32_t image_count = std::max(3u, caps.minImageCount);
    VkSwapchainCreateInfoKHR info{VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR};
    info.surface = state.surface;
    info.minImageCount =
        caps.maxImageCount ? std::min(image_count, caps.maxImageCount) : image_count;
    info.imageFormat = chosen.format;
    info.imageColorSpace = chosen.colorSpace;
    info.imageExtent = state.extent;
    info.imageArrayLayers = 1;
    info.imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    info.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    info.preTransform = caps.currentTransform;
    info.compositeAlpha =
        (caps.supportedCompositeAlpha & VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)
            ? VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR
            : static_cast<VkCompositeAlphaFlagBitsKHR>(caps.supportedCompositeAlpha &
                                                       (~caps.supportedCompositeAlpha + 1));
    info.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    info.clipped = VK_TRUE;
    if (vkCreateSwapchainKHR(state.device, &info, nullptr, &state.swapchain) != VK_SUCCESS)
        return false;
    count = 0;
    if (vkGetSwapchainImagesKHR(state.device, state.swapchain, &count, nullptr) != VK_SUCCESS ||
        !count)
        return false;
    state.present_images.resize(count);
    if (vkGetSwapchainImagesKHR(state.device, state.swapchain, &count,
                                state.present_images.data()) != VK_SUCCESS)
        return false;
    state.present_images.resize(count);
    state.present_ready.resize(count);
    VkSemaphoreCreateInfo semaphore{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    for (auto& ready : state.present_ready)
        if (vkCreateSemaphore(state.device, &semaphore, nullptr, &ready) != VK_SUCCESS)
            return false;
    state.surface_format = chosen.format;
    state.requested_width = width;
    state.requested_height = height;
    state.rebuild_surface = false;
    return true;
}
#endif
} // namespace

extern "C" void azahar_ios_vk_set_metal_layer(void* layer) {
#if defined(__APPLE__)
    if (!state.instance)
        state.metal_layer = layer;
#else
    (void)layer;
#endif
}

extern "C" bool azahar_ios_vk_start(const void* opaque_negotiation) {
    if (!opaque_negotiation || state.instance)
        return false;
    const auto* negotiation =
        static_cast<const retro_hw_render_context_negotiation_interface_vulkan*>(
            opaque_negotiation);
    if (negotiation->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN ||
        !negotiation->create_device)
        return false;

    const bool portable = HasInstanceExtension(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
    std::vector<const char*> extensions;
    if (portable)
        extensions.push_back(VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
#if defined(__APPLE__)
    const bool metal = state.metal_layer && HasInstanceExtension(VK_KHR_SURFACE_EXTENSION_NAME) &&
                       HasInstanceExtension(VK_EXT_METAL_SURFACE_EXTENSION_NAME);
    if (metal) {
        extensions.push_back(VK_KHR_SURFACE_EXTENSION_NAME);
        extensions.push_back(VK_EXT_METAL_SURFACE_EXTENSION_NAME);
    }
#endif
    VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    application.pApplicationName = "AzaharFE iOS Vulkan";
    application.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo create{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    create.pApplicationInfo = &application;
    create.flags = portable ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
    create.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
    create.ppEnabledExtensionNames = extensions.data();
    if (vkCreateInstance(&create, nullptr, &state.instance) != VK_SUCCESS)
        return false;

    std::uint32_t gpu_count = 0;
    if (vkEnumeratePhysicalDevices(state.instance, &gpu_count, nullptr) != VK_SUCCESS ||
        gpu_count == 0) {
        azahar_ios_vk_shutdown();
        return false;
    }
    std::vector<VkPhysicalDevice> gpus(gpu_count);
    if (vkEnumeratePhysicalDevices(state.instance, &gpu_count, gpus.data()) != VK_SUCCESS) {
        azahar_ios_vk_shutdown();
        return false;
    }
    state.gpu = gpus[0];

    VkSurfaceKHR surface = VK_NULL_HANDLE;
#if defined(__APPLE__)
    if (metal) {
        auto create_surface = reinterpret_cast<PFN_vkCreateMetalSurfaceEXT>(
            vkGetInstanceProcAddr(state.instance, "vkCreateMetalSurfaceEXT"));
        VkMetalSurfaceCreateInfoEXT info{VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT};
        info.pLayer = static_cast<const CAMetalLayer*>(state.metal_layer);
        if (create_surface &&
            create_surface(state.instance, &info, nullptr, &state.surface) == VK_SUCCESS)
            surface = state.surface;
    }
#endif
    retro_vulkan_context context{};
    bool created =
        negotiation->create_device(&context, state.instance, state.gpu, surface,
                                   vkGetInstanceProcAddr, nullptr, 0, nullptr, 0, nullptr);
#if defined(__APPLE__)
    if (!created && surface) {
        vkDestroySurfaceKHR(state.instance, state.surface, nullptr);
        state.surface = VK_NULL_HANDLE;
        context = {};
        created =
            negotiation->create_device(&context, state.instance, state.gpu, VK_NULL_HANDLE,
                                       vkGetInstanceProcAddr, nullptr, 0, nullptr, 0, nullptr);
    }
#endif
    if (!created || !context.device || !context.queue) {
        azahar_ios_vk_shutdown();
        return false;
    }

    state.device = context.device;
    state.queue = context.queue;
    state.queue_family = context.queue_family_index;

    VkCommandPoolCreateInfo pool{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool.queueFamilyIndex = state.queue_family;
    if (vkCreateCommandPool(state.device, &pool, nullptr, &state.command_pool) != VK_SUCCESS) {
        azahar_ios_vk_shutdown();
        return false;
    }

    VkCommandBufferAllocateInfo alloc{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    alloc.commandPool = state.command_pool;
    alloc.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    alloc.commandBufferCount = 1;
    VkFenceCreateInfo fence{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    for (auto& slot : state.slots) {
        if (vkAllocateCommandBuffers(state.device, &alloc, &slot.command) != VK_SUCCESS ||
            vkCreateFence(state.device, &fence, nullptr, &slot.copied) != VK_SUCCESS) {
            azahar_ios_vk_shutdown();
            return false;
        }
    }

#if defined(__APPLE__)
    if (state.surface) {
        VkSemaphoreCreateInfo semaphore{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
        bool complete = true;
        for (auto& slot : state.present_slots) {
            if (vkAllocateCommandBuffers(state.device, &alloc, &slot.command) != VK_SUCCESS ||
                vkCreateFence(state.device, &fence, nullptr, &slot.fence) != VK_SUCCESS ||
                vkCreateSemaphore(state.device, &semaphore, nullptr, &slot.acquired) !=
                    VK_SUCCESS) {
                complete = false;
                break;
            }
        }
        if (!complete) {
            vkDestroySurfaceKHR(state.instance, state.surface, nullptr);
            state.surface = VK_NULL_HANDLE;
        }
    }
#endif
    auto& intf = state.interface;
    intf.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
    intf.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
    intf.handle = &state;
    intf.instance = state.instance;
    intf.gpu = state.gpu;
    intf.device = state.device;
    intf.get_device_proc_addr = vkGetDeviceProcAddr;
    intf.get_instance_proc_addr = vkGetInstanceProcAddr;
    intf.queue = state.queue;
    intf.queue_index = state.queue_family;
    intf.set_image = SetImage;
    intf.get_sync_index = GetSyncIndex;
    intf.get_sync_index_mask = GetSyncMask;
    intf.wait_sync_index = WaitSyncIndex;
    intf.lock_queue = LockQueue;
    intf.unlock_queue = UnlockQueue;
    return true;
}

extern "C" const void* azahar_ios_vk_get_interface() {
    return state.device ? &state.interface : nullptr;
}

extern "C" int azahar_ios_vk_readback_frame(unsigned width, unsigned height, const void** pixels,
                                            std::size_t* pitch, bool* rgba, bool asynchronous) {
    if (!pixels || !pitch || !rgba || !state.device || !state.image || state.device_failed ||
        width == 0 || height == 0 || width > 4096 || height > 4096 ||
        (state.image_format != VK_FORMAT_R8G8B8A8_UNORM &&
         state.image_format != VK_FORMAT_B8G8R8A8_UNORM))
        return -1;
    *pixels = nullptr;
    // Drain before changing dimensions or switching modes. No old-size frame
    // may escape with the current callback's geometry.
    if (state.width != width || state.height != height || state.asynchronous != asynchronous) {
        if (!azahar_ios_vk_drain_readback())
            return -1;
        state.width = width;
        state.height = height;
        state.asynchronous = asynchronous;
        state.delivered = false;
    }
    const auto bytes = static_cast<VkDeviceSize>(width) * height * 4;
    StagingSlot* ready = nullptr;
    StagingSlot* free = nullptr;
    for (auto& slot : state.slots) {
        if (slot.pending) {
            const auto status = vkGetFenceStatus(state.device, slot.copied);
            if (status == VK_SUCCESS) {
                slot.pending = false;
                if (!ready || slot.serial > ready->serial)
                    ready = &slot;
            } else if (status != VK_NOT_READY || std::chrono::steady_clock::now() - slot.submitted >
                                                     std::chrono::seconds(2)) {
                state.device_failed = true;
                return -1;
            }
        }
    }
    // Do not overwrite the slot returned to the caller. Its pointer is valid
    // until the next readback call (the frontend immediately copies it).
    for (auto& slot : state.slots) {
        if (!slot.pending && &slot != ready) {
            free = &slot;
            break;
        }
    }
    if (!free) {
        // All slots busy: retain the previous displayed image, not a failure.
        return ready ? (ReadPixels(*ready, pixels, pitch, rgba) ? 1 : -1) : 0;
    }
    if (!EnsureStagingBuffer(*free, bytes) || !CopyOutput(*free, width, height)) {
        state.device_failed = true;
        return -1;
    }
    // First frame and compatibility mode keep the bounded blocking path.
    if (!asynchronous || !state.delivered) {
        if (!WaitCopy(*free, 2'000'000'000ULL))
            return -1;
        ready = free;
    }
    return ready ? (ReadPixels(*ready, pixels, pitch, rgba) ? 1 : -1) : 0;
}

extern "C" bool azahar_ios_vk_readback(unsigned width, unsigned height, const void** pixels,
                                       std::size_t* pitch) {
    bool rgba = false;
    const void* raw = nullptr;
    if (!pixels || azahar_ios_vk_readback_frame(width, height, &raw, pitch, &rgba, false) != 1)
        return false;
    // Preserve the legacy BGRA ABI for older frontends and regression tests.
    if (rgba) {
        state.pixels.resize(*pitch * height);
        std::memcpy(state.pixels.data(), raw, state.pixels.size());
        for (std::size_t i = 0; i < state.pixels.size(); i += 4)
            std::swap(state.pixels[i], state.pixels[i + 2]);
        *pixels = state.pixels.data();
    } else {
        *pixels = raw;
    }
    return true;
}

extern "C" int azahar_ios_vk_present_frame(unsigned width, unsigned height, unsigned drawable_width,
                                           unsigned drawable_height, const float* rectangles,
                                           unsigned count) {
#if defined(__APPLE__)
    if (!state.surface || !state.device || !state.image || state.device_failed || !rectangles ||
        !width || !height || !count || count > 2 || !drawable_width || !drawable_height)
        return -1;
    if (!state.swapchain || state.rebuild_surface || state.requested_width != drawable_width ||
        state.requested_height != drawable_height) {
        if (!CreateSwapchain(drawable_width, drawable_height))
            return -1;
    }
    Context::PresentSlot* slot = nullptr;
    for (auto& candidate : state.present_slots) {
        if (candidate.pending) {
            const auto result = vkGetFenceStatus(state.device, candidate.fence);
            if (result == VK_SUCCESS)
                candidate.pending = false;
            else if (result != VK_NOT_READY)
                return -1;
        }
        if (!candidate.pending && !slot)
            slot = &candidate;
    }
    if (!slot)
        return 0;
    uint32_t index = 0;
    const auto acquire = vkAcquireNextImageKHR(state.device, state.swapchain, 0, slot->acquired,
                                               VK_NULL_HANDLE, &index);
    if (acquire == VK_NOT_READY || acquire == VK_TIMEOUT)
        return 0;
    if (acquire == VK_ERROR_OUT_OF_DATE_KHR) {
        state.rebuild_surface = true;
        return 0;
    }
    if (acquire != VK_SUCCESS && acquire != VK_SUBOPTIMAL_KHR)
        return -1;
    if (index >= state.present_images.size())
        return -1;
    auto command = slot->command;
    if (vkResetCommandBuffer(command, 0) != VK_SUCCESS ||
        vkResetFences(state.device, 1, &slot->fence) != VK_SUCCESS)
        return -1;
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(command, &begin) != VK_SUCCESS)
        return -1;
    VkImageMemoryBarrier barriers[2]{};
    for (auto& barrier : barriers) {
        barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    }
    auto& source = barriers[0];
    source.srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT;
    source.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    source.oldLayout = state.image_layout;
    source.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    source.image = state.image;
    auto& dest = barriers[1];
    dest.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    dest.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    dest.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    dest.image = state.present_images[index];
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, nullptr, 0, nullptr, 2, barriers);
    VkClearColorValue black{};
    black.float32[3] = 1.0f;
    vkCmdClearColorImage(command, dest.image, dest.newLayout, &black, 1, &dest.subresourceRange);
    VkImageMemoryBarrier cleared = dest;
    cleared.oldLayout = cleared.newLayout;
    cleared.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                         0, nullptr, 0, nullptr, 1, &cleared);
    auto pixel = [](float v, unsigned size) {
        return static_cast<int32_t>(std::clamp(v, 0.0f, 1.0f) * size + 0.5f);
    };
    for (unsigned n = 0; n < count; ++n) {
        const float* r = rectangles + n * 8;
        VkImageBlit blit{};
        blit.srcSubresource = blit.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
        blit.srcOffsets[0] = {pixel(r[0], width), pixel(r[1], height), 0};
        blit.srcOffsets[1] = {pixel(r[2], width), pixel(r[3], height), 1};
        blit.dstOffsets[0] = {pixel(r[4], state.extent.width), pixel(r[5], state.extent.height), 0};
        blit.dstOffsets[1] = {pixel(r[6], state.extent.width), pixel(r[7], state.extent.height), 1};
        if (blit.srcOffsets[1].x > blit.srcOffsets[0].x &&
            blit.srcOffsets[1].y > blit.srcOffsets[0].y &&
            blit.dstOffsets[1].x > blit.dstOffsets[0].x &&
            blit.dstOffsets[1].y > blit.dstOffsets[0].y)
            vkCmdBlitImage(command, source.image, source.newLayout, dest.image, dest.newLayout, 1,
                           &blit, VK_FILTER_NEAREST);
    }
    source.oldLayout = source.newLayout;
    source.newLayout = state.image_layout;
    source.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    source.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    dest.oldLayout = dest.newLayout;
    dest.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    dest.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    dest.dstAccessMask = 0;
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 2,
                         barriers);
    if (vkEndCommandBuffer(command) != VK_SUCCESS)
        return -1;
    const VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    const VkSemaphore ready = state.present_ready[index];
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &slot->acquired;
    submit.pWaitDstStageMask = &stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &command;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &ready;
    VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &ready;
    present.swapchainCount = 1;
    present.pSwapchains = &state.swapchain;
    present.pImageIndices = &index;
    std::lock_guard lock{state.queue_mutex};
    if (vkQueueSubmit(state.queue, 1, &submit, slot->fence) != VK_SUCCESS)
        return -1;
    slot->pending = true;
    const auto result = vkQueuePresentKHR(state.queue, &present);
    if (result == VK_ERROR_OUT_OF_DATE_KHR) {
        state.rebuild_surface = true;
        return 0;
    }
    return result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR ? 1 : -1;
#else
    (void)width;
    (void)height;
    (void)drawable_width;
    (void)drawable_height;
    (void)rectangles;
    (void)count;
    return -1;
#endif
}

extern "C" bool azahar_ios_vk_readback_failed() {
    return state.device_failed;
}

extern "C" bool azahar_ios_vk_drain_readback() {
#if defined(__APPLE__)
    for (auto& slot : state.present_slots) {
        if (!slot.pending)
            continue;
        const auto result =
            vkWaitForFences(state.device, 1, &slot.fence, VK_TRUE, 1'000'000'000ULL);
        if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST)
            return false;
        slot.pending = false;
    }
#endif
    for (auto& slot : state.slots) {
        if (!slot.pending)
            continue;
        const auto result =
            vkWaitForFences(state.device, 1, &slot.copied, VK_TRUE, 1'000'000'000ULL);
        if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST)
            return false;
        slot.pending = false;
    }
    return true;
}

extern "C" void azahar_ios_vk_shutdown() {
    if (state.device) {
        std::lock_guard lock{state.queue_mutex};
        vkDeviceWaitIdle(state.device);
#if defined(__APPLE__)
        DestroySwapchain();
        for (auto& slot : state.present_slots) {
            vkDestroySemaphore(state.device, slot.acquired, nullptr);
            vkDestroyFence(state.device, slot.fence, nullptr);
        }
        state.present_slots = {};
#endif
        for (auto& slot : state.slots) {
            ReleaseStagingBuffer(slot);
            vkDestroyFence(state.device, slot.copied, nullptr);
        }
        if (state.command_pool)
            vkDestroyCommandPool(state.device, state.command_pool, nullptr);
        vkDestroyDevice(state.device, nullptr);
    }
#if defined(__APPLE__)
    if (state.surface)
        vkDestroySurfaceKHR(state.instance, state.surface, nullptr);
    state.surface = VK_NULL_HANDLE;
    state.metal_layer = nullptr;
    state.requested_width = state.requested_height = 0;
    state.rebuild_surface = false;
#endif
    if (state.instance)
        vkDestroyInstance(state.instance, nullptr);
    state.slots = {};
    state.serial = 0;
    state.device_failed = false;
    state.delivered = false;
    state.asynchronous = false;
    state.width = state.height = 0;
    state.command_pool = VK_NULL_HANDLE;
    state.device = VK_NULL_HANDLE;
    state.instance = VK_NULL_HANDLE;
    state.gpu = VK_NULL_HANDLE;
    state.queue = VK_NULL_HANDLE;
    state.image = VK_NULL_HANDLE;
    state.image_layout = VK_IMAGE_LAYOUT_UNDEFINED;
    state.image_format = VK_FORMAT_UNDEFINED;
    state.pixels.clear();
    state.interface = {};
}
#endif
