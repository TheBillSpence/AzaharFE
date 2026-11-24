// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
//
// First-stage MoltenVK frontend for Azahar's existing libretro Vulkan PICA200
// renderer. The GPU renders into an offscreen Vulkan image; this bridge reads
// it back to the existing UIImage UI. This is deliberately synchronous and
// optimizes for correctness before zero-copy presentation.
#include "citra_libretro/ios_moltenvk_bridge.h"

#if defined(IOS) && defined(ENABLE_VULKAN)
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <vector>
#include <vulkan/vulkan.h>
#include "libretro_vulkan.h"

namespace {
struct Context {
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice gpu = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    std::uint32_t queue_family = 0;
    VkCommandPool command_pool = VK_NULL_HANDLE;
    VkImage image = VK_NULL_HANDLE;
    VkImageLayout image_layout = VK_IMAGE_LAYOUT_UNDEFINED;
    VkFormat image_format = VK_FORMAT_UNDEFINED;
    retro_hw_render_interface_vulkan interface{};
    std::mutex queue_mutex;
    std::vector<std::uint8_t> pixels;
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
    // Each frame's CPU readback waits for the GPU before the next frame.
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

bool CopyOutput(VkBuffer buffer, unsigned width, unsigned height) {
    VkCommandBufferAllocateInfo allocate{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
    allocate.commandPool = state.command_pool;
    allocate.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    allocate.commandBufferCount = 1;
    VkCommandBuffer command = VK_NULL_HANDLE;
    if (vkAllocateCommandBuffers(state.device, &allocate, &command) != VK_SUCCESS)
        return false;

    bool result = false;
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (vkBeginCommandBuffer(command, &begin) == VK_SUCCESS) {
        VkImageMemoryBarrier before{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        before.srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_READ_BIT;
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
        vkCmdCopyImageToBuffer(command, state.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buffer,
                               1, &copy);

        VkImageMemoryBarrier after = before;
        after.srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
        after.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
        after.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        after.newLayout = state.image_layout;
        vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, 0, 0, nullptr, 0, nullptr, 1,
                             &after);

        if (vkEndCommandBuffer(command) == VK_SUCCESS) {
            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
            submit.commandBufferCount = 1;
            submit.pCommandBuffers = &command;
            std::lock_guard lock{state.queue_mutex};
            if (vkQueueSubmit(state.queue, 1, &submit, VK_NULL_HANDLE) == VK_SUCCESS)
                result = vkQueueWaitIdle(state.queue) == VK_SUCCESS;
        }
    }
    vkFreeCommandBuffers(state.device, state.command_pool, 1, &command);
    return result;
}
} // namespace

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
    const char* extensions[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkApplicationInfo application{VK_STRUCTURE_TYPE_APPLICATION_INFO};
    application.pApplicationName = "AzaharFE iOS Vulkan";
    application.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo create{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    create.pApplicationInfo = &application;
    create.flags = portable ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0;
    create.enabledExtensionCount = portable ? 1u : 0u;
    create.ppEnabledExtensionNames = portable ? extensions : nullptr;
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

    retro_vulkan_context context{};
    if (!negotiation->create_device(&context, state.instance, state.gpu, VK_NULL_HANDLE,
                                    vkGetInstanceProcAddr, nullptr, 0, nullptr, 0, nullptr) ||
        !context.device || !context.queue) {
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

extern "C" bool azahar_ios_vk_readback(unsigned width, unsigned height, const void** pixels,
                                       std::size_t* pitch) {
    if (!pixels || !pitch || !state.device || !state.image || width == 0 || height == 0 ||
        width > 4096 || height > 4096 ||
        (state.image_format != VK_FORMAT_R8G8B8A8_UNORM &&
         state.image_format != VK_FORMAT_B8G8R8A8_UNORM))
        return false;

    const auto byte_count = static_cast<VkDeviceSize>(width) * height * 4;
    // PresentWindow does not submit external semaphores. Its Vulkan queues
    // must finish before reading the final output image.
    if (vkDeviceWaitIdle(state.device) != VK_SUCCESS)
        return false;

    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    bool coherent = false;
    bool okay = CreateStagingBuffer(byte_count, buffer, memory, coherent);
    if (okay)
        okay = CopyOutput(buffer, width, height);
    if (okay) {
        void* mapped = nullptr;
        okay = vkMapMemory(state.device, memory, 0, byte_count, 0, &mapped) == VK_SUCCESS;
        if (okay) {
            if (!coherent) {
                VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE};
                range.memory = memory;
                range.offset = 0;
                range.size = VK_WHOLE_SIZE;
                okay = vkInvalidateMappedMemoryRanges(state.device, 1, &range) == VK_SUCCESS;
            }
            if (okay) {
                state.pixels.resize(static_cast<std::size_t>(byte_count));
                std::memcpy(state.pixels.data(), mapped, state.pixels.size());
                // UIImage's existing XRGB8888 path consumes little-endian
                // BGRA bytes. Azahar Vulkan outputs RGBA8, so swap R and B.
                if (state.image_format == VK_FORMAT_R8G8B8A8_UNORM) {
                    for (std::size_t i = 0; i < state.pixels.size(); i += 4)
                        std::swap(state.pixels[i], state.pixels[i + 2]);
                }
                *pixels = state.pixels.data();
                *pitch = static_cast<std::size_t>(width) * 4;
            }
            vkUnmapMemory(state.device, memory);
        }
    }
    if (buffer)
        vkDestroyBuffer(state.device, buffer, nullptr);
    if (memory)
        vkFreeMemory(state.device, memory, nullptr);
    return okay;
}

extern "C" void azahar_ios_vk_shutdown() {
    if (state.device) {
        vkDeviceWaitIdle(state.device);
        if (state.command_pool)
            vkDestroyCommandPool(state.device, state.command_pool, nullptr);
        vkDestroyDevice(state.device, nullptr);
    }
    if (state.instance)
        vkDestroyInstance(state.instance, nullptr);
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
