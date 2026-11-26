// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <vulkan/vulkan.h>
#include "libretro_vulkan.h"
#include "citra_libretro/ios_frame_control.h"
#include "citra_libretro/ios_moltenvk_bridge.h"

namespace {
void Check(bool passed, const char* operation) {
    if (!passed) {
        std::fprintf(stderr, "Failed: %s\n", operation);
        std::exit(1);
    }
}

bool CreateDevice(retro_vulkan_context* ctx, VkInstance, VkPhysicalDevice gpu, VkSurfaceKHR,
                  PFN_vkGetInstanceProcAddr, const char**, unsigned, const char**, unsigned,
                  const VkPhysicalDeviceFeatures*) {
    uint32_t count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, nullptr);
    std::vector<VkQueueFamilyProperties> families(count);
    vkGetPhysicalDeviceQueueFamilyProperties(gpu, &count, families.data());
    for (unsigned i = 0; i < count; ++i) {
        if (!(families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT))
            continue;
        const float priority = 1;
        VkDeviceQueueCreateInfo queue{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
        queue.queueCount = 1;
        queue.queueFamilyIndex = i;
        queue.pQueuePriorities = &priority;
        VkDeviceCreateInfo info{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
        info.queueCreateInfoCount = 1;
        info.pQueueCreateInfos = &queue;
        if (vkCreateDevice(gpu, &info, nullptr, &ctx->device) != VK_SUCCESS)
            return false;
        ctx->gpu = gpu;
        ctx->queue_family_index = i;
        vkGetDeviceQueue(ctx->device, i, 0, &ctx->queue);
        return true;
    }
    return false;
}

void CheckFrames(const retro_hw_render_interface_vulkan& vk, VkFormat format, bool async) {
    VkImageCreateInfo info{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
    info.imageType = VK_IMAGE_TYPE_2D;
    info.format = format;
    info.extent = {7, 5, 1};
    info.mipLevels = info.arrayLayers = 1;
    info.samples = VK_SAMPLE_COUNT_1_BIT;
    info.usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    VkImage image{};
    Check(vkCreateImage(vk.device, &info, nullptr, &image) == VK_SUCCESS, "create image");
    VkMemoryRequirements req{};
    vkGetImageMemoryRequirements(vk.device, image, &req);
    VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
    alloc.allocationSize = req.size;
    while (!(req.memoryTypeBits & (1u << alloc.memoryTypeIndex)))
        ++alloc.memoryTypeIndex;
    VkDeviceMemory memory{};
    Check(vkAllocateMemory(vk.device, &alloc, nullptr, &memory) == VK_SUCCESS, "image memory");
    Check(vkBindImageMemory(vk.device, image, memory, 0) == VK_SUCCESS, "bind image");
    VkCommandPoolCreateInfo pool_info{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
    pool_info.queueFamilyIndex = vk.queue_index;
    VkCommandPool pool{};
    Check(vkCreateCommandPool(vk.device, &pool_info, nullptr, &pool) == VK_SUCCESS, "command pool");
    retro_vulkan_image frame{};
    frame.image_layout = VK_IMAGE_LAYOUT_GENERAL;
    frame.create_info.image = image;
    frame.create_info.format = format;
    const void* pixels = nullptr;
    size_t pitch = 0;
    vk.set_image(vk.handle, nullptr, 0, nullptr, vk.queue_index);
    Check(!azahar_ios_vk_readback(7, 5, &pixels, &pitch), "reject missing image");
    for (unsigned pass = 0; pass < (async ? 12u : 3u); ++pass) {
        VkCommandBufferAllocateInfo cmd_info{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
        cmd_info.commandPool = pool;
        cmd_info.commandBufferCount = 1;
        VkCommandBuffer cmd{};
        Check(vkAllocateCommandBuffers(vk.device, &cmd_info, &cmd) == VK_SUCCESS, "command buffer");
        VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        Check(vkBeginCommandBuffer(cmd, &begin) == VK_SUCCESS, "begin producer");
        VkImageMemoryBarrier barrier{VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
        barrier.oldLayout = pass ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = VK_IMAGE_LAYOUT_GENERAL;
        barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
        barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.srcQueueFamilyIndex = barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                             0, 0, nullptr, 0, nullptr, 1, &barrier);
        VkClearColorValue clear{};
        clear.float32[pass % 3] = clear.float32[3] = 1;
        vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &barrier.subresourceRange);
        Check(vkEndCommandBuffer(cmd) == VK_SUCCESS, "end producer");
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        vk.lock_queue(vk.handle);
        auto result = vkQueueSubmit(vk.queue, 1, &submit, VK_NULL_HANDLE);
        vk.unlock_queue(vk.handle);
        Check(result == VK_SUCCESS, "submit producer");
        vk.set_image(vk.handle, &frame, 0, nullptr, vk.queue_index);
        const unsigned width = async ? (pass < 6 ? 3 : 7) : (pass == 1 ? 7 : 3);
        unsigned expected_pass = pass;
        bool rgba = false;
        if (async) {
            // Force previous copy completion for deterministic color comparisons.
            // The production bridge itself still uses nonblocking fence polling.
            Check(vkQueueWaitIdle(vk.queue) == VK_SUCCESS, "complete queued producer");
            const int status =
                azahar_ios_vk_readback_frame(width, 5, &pixels, &pitch, &rgba, true);
            if (pass == 1 || pass == 7) {
                Check(status == 0 && !pixels && !azahar_ios_vk_readback_failed(),
                      "pending is not failure");
                continue;
            }
            Check(status == 1, "pipelined frame");
            Check(rgba == (format == VK_FORMAT_R8G8B8A8_UNORM), "native byte order");
            if (pass != 0 && pass != 6)
                expected_pass = pass - 1;
        } else {
            Check(azahar_ios_vk_readback(width, 5, &pixels, &pitch), "read frame");
        }
        Check(pixels && pitch == width * 4, "geometry");
        std::array<uint8_t, 4> expected{0, 0, 0, 255};
        expected[rgba ? expected_pass % 3 : 2 - expected_pass % 3] = 255;
        for (size_t i = 0; i < pitch * 5; ++i)
            Check(static_cast<const uint8_t*>(pixels)[i] == expected[i % 4], "ordered BGRA pixels");
    }
    Check(azahar_ios_vk_drain_readback(), "drain pending copies");
    vk.set_image(vk.handle, nullptr, 0, nullptr, vk.queue_index);
    vkDestroyCommandPool(vk.device, pool, nullptr);
    vkDestroyImage(vk.device, image, nullptr);
    vkFreeMemory(vk.device, memory, nullptr);
}
} // namespace

int main() {
    using LibRetro::CheckReadback;
    using LibRetro::ReadbackRecovery;
    static_assert(CheckReadback(2, false) == ReadbackRecovery::Continue);
    static_assert(CheckReadback(2, true) == ReadbackRecovery::Continue);
    static_assert(CheckReadback(3, false) == ReadbackRecovery::RetrySoftware);
    static_assert(CheckReadback(3, true) == ReadbackRecovery::ReportFailure);
    retro_hw_render_context_negotiation_interface_vulkan setup{};
    setup.interface_type = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN;
    setup.interface_version = RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION;
    Check(!azahar_ios_vk_start(&setup), "reject missing device callback");
    setup.create_device = CreateDevice;
    for (auto format : {VK_FORMAT_R8G8B8A8_UNORM, VK_FORMAT_B8G8R8A8_UNORM}) {
        Check(azahar_ios_vk_start(&setup), "start bridge");
        const auto* vk = static_cast<const retro_hw_render_interface_vulkan*>(azahar_ios_vk_get_interface());
        Check(vk != nullptr, "live interface");
        const float rectangle[] = {0, 0, 1, 1, 0, 0, 1, 1};
        Check(azahar_ios_vk_present_frame(3, 5, 3, 5, rectangle, 1) == -1,
              "headless presentation falls back");
        unsigned surface_width = 1, surface_height = 1;
        azahar_ios_vk_present_extent(&surface_width, &surface_height);
        Check(surface_width == 0 && surface_height == 0, "headless surface extent");
        CheckFrames(*vk, format, false);
        CheckFrames(*vk, format, true);
        azahar_ios_vk_shutdown();
        Check(!azahar_ios_vk_get_interface(), "clean shutdown");
    }
    std::puts("PASS two sessions, synchronous and pipelined readbacks, resize and drain");
}
