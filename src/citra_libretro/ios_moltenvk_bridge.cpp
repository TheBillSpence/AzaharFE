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
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>
#include <vulkan/vulkan.h>
#if defined(__APPLE__)
#include <vulkan/vulkan_metal.h>
#endif
#include "libretro_vulkan.h"

namespace {
#if defined(__APPLE__)
// Observed by the gameplay watchdog. Never acquire a Vulkan lock to sample it.
std::atomic<unsigned> present_stage{0};
std::atomic<unsigned> async_worker_stage{0};
std::atomic<unsigned> async_submit_stage{0};
std::atomic<unsigned> accepted_presentations{0};
#if defined(AZAHAR_IOS_MOLTENVK_BRIDGE)
thread_local void* present_scheduler = nullptr;
thread_local bool defer_present = false;
#endif
struct PresentStageScope {
    ~PresentStageScope() {
        present_stage.store(0, std::memory_order_relaxed);
    }
};
#endif
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
    std::timed_mutex queue_mutex;
    std::vector<std::uint8_t> pixels;
#if defined(__APPLE__)
    void* metal_layer = nullptr;
    bool async_present = true;
    VkQueue presentation_queue = VK_NULL_HANDLE;
    std::timed_mutex presentation_mutex;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkExtent2D extent{};
    VkFormat surface_format = VK_FORMAT_UNDEFINED;
    VkFilter present_filter = VK_FILTER_NEAREST;
    unsigned requested_width = 0, requested_height = 0;
    bool rebuild_surface = false;
    struct PresentSlot {
        VkCommandBuffer command = VK_NULL_HANDLE;
        VkSemaphore acquired = VK_NULL_HANDLE;
        VkFence fence = VK_NULL_HANDLE;
        VkFence acquire_fence = VK_NULL_HANDLE;
        bool acquisition_pending = false;
        bool pending = false;
    };
    std::array<PresentSlot, 3> present_slots{};
    std::vector<VkImage> present_images;
    std::vector<VkSemaphore> present_ready;
    enum class AsyncPhase {
        Idle,
        AcquireRequested,
        Acquiring,
        Ready,
        SubmitQueued,
        PresentRequested,
        Presenting,
        Failed
    };
    std::mutex async_mutex;
    std::condition_variable async_cv;
    std::thread async_thread;
    AsyncPhase async_phase = AsyncPhase::Idle;
    bool async_stop = false;
    bool async_exited = false;
    bool async_rebuild = false;
    PresentSlot* async_slot = nullptr;
    PresentSlot* async_next = nullptr;
    uint32_t async_index = 0;
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
                std::unique_lock lock{state.queue_mutex, std::defer_lock};
                if (!lock.try_lock_for(std::chrono::seconds(2))) {
                    state.device_failed = true;
                    return false;
                }
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

bool DrainStagingCopies() {
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
using AsyncPhase = Context::AsyncPhase;

// The worker never reads the renderer's reusable source image or records its
// command buffers. The producer enqueues the blit on the graphics queue first;
// the worker only acquires drawables and presents images already submitted.
void AsyncPresentLoop() {
    std::unique_lock lock{state.async_mutex};
    for (;;) {
        state.async_cv.wait(lock, [] {
            return (state.async_stop && state.async_phase != AsyncPhase::SubmitQueued) ||
                   state.async_phase == AsyncPhase::AcquireRequested ||
                   state.async_phase == AsyncPhase::PresentRequested;
        });
        // Finish an already submitted presentation, but do not acquire more
        // drawables once shutdown has been requested.
        if (state.async_stop && state.async_phase != AsyncPhase::PresentRequested)
            break;
        if (state.async_phase == AsyncPhase::AcquireRequested) {
            auto* slot = state.async_slot;
            state.async_phase = AsyncPhase::Acquiring;
            lock.unlock();
            async_worker_stage.store(4, std::memory_order_relaxed);
            uint32_t index = 0;
            VkResult result = vkResetFences(state.device, 1, &slot->acquire_fence);
            if (result == VK_SUCCESS)
                result = vkAcquireNextImageKHR(state.device, state.swapchain, 0, slot->acquired,
                                               slot->acquire_fence, &index);
            async_worker_stage.store(0, std::memory_order_relaxed);
            lock.lock();
            if (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) {
                slot->acquisition_pending = true;
                state.async_index = index;
                state.async_phase =
                    index < state.present_images.size() ? AsyncPhase::Ready : AsyncPhase::Failed;
            } else if (result == VK_NOT_READY || result == VK_TIMEOUT ||
                       result == VK_ERROR_OUT_OF_DATE_KHR) {
                state.async_rebuild = result == VK_ERROR_OUT_OF_DATE_KHR;
                state.async_phase = AsyncPhase::Idle;
            } else {
                state.async_phase = AsyncPhase::Failed;
            }
        } else {
            const uint32_t index = state.async_index;
            const VkSemaphore ready = state.present_ready[index];
            const VkSwapchainKHR swapchain = state.swapchain;
            auto* next = state.async_next;
            state.async_next = nullptr;
            state.async_phase = AsyncPhase::Presenting;
            lock.unlock();
            VkPresentInfoKHR present{VK_STRUCTURE_TYPE_PRESENT_INFO_KHR};
            present.waitSemaphoreCount = 1;
            present.pWaitSemaphores = &ready;
            present.swapchainCount = 1;
            present.pSwapchains = &swapchain;
            present.pImageIndices = &index;
            async_worker_stage.store(6, std::memory_order_relaxed);
            VkResult result;
            {
                // Queue host access must be externally synchronized. A second
                // queue in the same family, when supported, avoids contention
                // with the emulation scheduler. The binary semaphore orders blit
                // completion before presentation across either queue.
                std::lock_guard queue_lock{state.presentation_queue == state.queue
                                               ? state.queue_mutex
                                               : state.presentation_mutex};
                async_worker_stage.store(8, std::memory_order_relaxed);
                result = vkQueuePresentKHR(state.presentation_queue, &present);
            }
            async_worker_stage.store(0, std::memory_order_relaxed);
            lock.lock();
            if (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) {
                accepted_presentations.fetch_add(1, std::memory_order_release);
                if (next && !state.async_stop) {
                    state.async_slot = next;
                    state.async_phase = AsyncPhase::AcquireRequested;
                } else {
                    state.async_phase = AsyncPhase::Idle;
                }
            } else if (result == VK_ERROR_OUT_OF_DATE_KHR) {
                state.async_rebuild = true;
                state.async_phase = AsyncPhase::Idle;
            } else {
                state.async_phase = AsyncPhase::Failed;
            }
        }
    }
    state.async_exited = true;
    async_worker_stage.store(0, std::memory_order_relaxed);
}

bool EnsureAsyncWorker() {
    if (state.async_thread.joinable())
        return true;
    try {
        state.async_thread = std::thread(AsyncPresentLoop);
        return true;
    } catch (...) {
        return false;
    }
}

void RequestAsyncStop() {
    if (!state.async_thread.joinable())
        return;
    std::lock_guard lock{state.async_mutex};
    state.async_stop = true;
    state.async_cv.notify_one();
}

bool StopAsyncWorker() {
    if (!state.async_thread.joinable())
        return true;
    RequestAsyncStop();
    {
        std::lock_guard lock{state.async_mutex};
        if (!state.async_exited)
            return false;
    }
    state.async_thread.join();
    return true;
}

Context::PresentSlot* FindPresentSlot(bool& failed) {
    Context::PresentSlot* slot = nullptr;
    for (auto& candidate : state.present_slots) {
        if (candidate.pending) {
            const auto result = vkGetFenceStatus(state.device, candidate.fence);
            if (result == VK_SUCCESS)
                candidate.pending = false;
            else if (result != VK_NOT_READY) {
                failed = true;
                return nullptr;
            }
        }
        if (!candidate.pending && !candidate.acquisition_pending && !slot)
            slot = &candidate;
    }
    return slot;
}

// Submit on the existing graphics worker after the renderer submission, before
// any later command chunk can reuse the source image. No frontend objects or
// mutable source metadata are accessed here; the recorded blit owns the handles.
void SubmitAsyncBlit(Context::PresentSlot* slot, Context::PresentSlot* next, VkSemaphore ready) {
    const VkPipelineStageFlags stage = VK_PIPELINE_STAGE_TRANSFER_BIT;
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &slot->acquired;
    submit.pWaitDstStageMask = &stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &slot->command;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &ready;
    async_submit_stage.store(6, std::memory_order_relaxed);
    VkResult result;
    {
        std::lock_guard lock{state.queue_mutex};
        async_submit_stage.store(7, std::memory_order_relaxed);
        result = vkQueueSubmit(state.queue, 1, &submit, slot->fence);
    }
    async_submit_stage.store(0, std::memory_order_relaxed);
    std::lock_guard lock{state.async_mutex};
    if (result == VK_SUCCESS) {
        slot->pending = true;
        slot->acquisition_pending = false;
        state.async_next = state.async_stop ? nullptr : next;
        state.async_phase = AsyncPhase::PresentRequested;
    } else {
        state.async_phase = AsyncPhase::Failed;
    }
    state.async_cv.notify_one();
}

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
        if (state.presentation_queue != state.queue &&
            vkQueueWaitIdle(state.presentation_queue) != VK_SUCCESS)
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
    // Do not silently display a point-sized surface on a Retina screen.
    // Allow small rounding/platform differences, but use the old path when
    // the surface is substantially smaller than the physical view request.
    if (static_cast<double>(state.extent.width) < width * 0.9 ||
        static_cast<double>(state.extent.height) < height * 0.9)
        return false;
    state.present_filter =
        (src.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT)
            ? VK_FILTER_LINEAR
            : VK_FILTER_NEAREST;
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

extern "C" void azahar_ios_vk_set_async_present(bool enabled) {
#if defined(__APPLE__)
    if (!state.instance)
        state.async_present = enabled;
#else
    (void)enabled;
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
#if defined(__APPLE__)
    state.presentation_queue =
        context.presentation_queue && context.presentation_queue_family_index == state.queue_family
            ? context.presentation_queue
            : state.queue;
#endif

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
                vkCreateFence(state.device, &fence, nullptr, &slot.acquire_fence) != VK_SUCCESS ||
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

#if defined(__APPLE__) && defined(AZAHAR_IOS_MOLTENVK_BRIDGE)
extern "C" void azahar_ios_vk_begin_present(void* opaque_scheduler) {
    {
        std::lock_guard lock{state.async_mutex};
        defer_present = state.async_present && state.surface && !state.async_stop;
    }
    present_scheduler = opaque_scheduler;
    if (!defer_present && !state.device_failed &&
        !azahar_ios_vk_wait_dispatched(present_scheduler, 2000)) {
        state.device_failed = true;
    }
}

extern "C" void azahar_ios_vk_end_present() {
    present_scheduler = nullptr;
    defer_present = false;
}
#endif

extern "C" int azahar_ios_vk_readback_frame(unsigned width, unsigned height, const void** pixels,
                                            std::size_t* pitch, bool* rgba, bool asynchronous) {
    if (!pixels || !pitch || !rgba || !state.device || !state.image || state.device_failed ||
        width == 0 || height == 0 || width > 4096 || height > 4096 ||
        (state.image_format != VK_FORMAT_R8G8B8A8_UNORM &&
         state.image_format != VK_FORMAT_B8G8R8A8_UNORM))
        return -1;
    *pixels = nullptr;
#if defined(__APPLE__) && defined(AZAHAR_IOS_MOLTENVK_BRIDGE)
    // A fallback must retain the old producer-before-copy ordering.
    if (present_scheduler && defer_present &&
        !azahar_ios_vk_wait_dispatched(present_scheduler, 2000)) {
        state.device_failed = true;
        RequestAsyncStop();
        return -1;
    }
#endif
#if defined(__APPLE__)
    // Fallback may be needed because acquisition is stalled. Stop requesting
    // drawables, but do not wait for that worker to return before CPU readback.
    // The swapchain and its resources remain owned until safe session teardown.
    RequestAsyncStop();
#endif
    // Drain only staging copies before changing readback geometry or mode.
    // Presentation blits already restore the source on the graphics queue.
    if (state.width != width || state.height != height || state.asynchronous != asynchronous) {
        if (!DrainStagingCopies())
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
    const PresentStageScope stage_scope;
    present_stage.store(1, std::memory_order_relaxed);
    if (!state.surface || !state.device || !state.image || state.device_failed || !rectangles ||
        !width || !height || !count || count > 2 || !drawable_width || !drawable_height)
        return -1;
    Context::PresentSlot* slot = nullptr;
    uint32_t index = 0;
    bool resize = !state.swapchain || state.rebuild_surface ||
                  state.requested_width != drawable_width ||
                  state.requested_height != drawable_height;
    if (state.async_present) {
        if (!EnsureAsyncWorker())
            return -1;
        // No driver calls while holding the handoff mutex. When a drawable
        // is already acquired, consume it before recreating its swapchain.
        {
            std::lock_guard lock{state.async_mutex};
            if (state.async_phase == AsyncPhase::Failed || state.async_stop)
                return -1;
            resize |= state.async_rebuild;
            if (resize)
                state.async_next = nullptr;
            if (state.async_phase == AsyncPhase::Ready) {
                slot = state.async_slot;
                index = state.async_index;
                if (resize)
                    state.rebuild_surface = true;
            } else if (state.async_phase != AsyncPhase::Idle) {
                return 0;
            }
        }
        if (!slot) {
            if (resize) {
                present_stage.store(2, std::memory_order_relaxed);
                if (!CreateSwapchain(drawable_width, drawable_height))
                    return -1;
                std::lock_guard lock{state.async_mutex};
                state.async_rebuild = false;
            }
            present_stage.store(3, std::memory_order_relaxed);
            bool failed = false;
            auto* next = FindPresentSlot(failed);
            if (failed)
                return -1;
            if (next) {
                std::lock_guard lock{state.async_mutex};
                state.async_slot = next;
                state.async_phase = AsyncPhase::AcquireRequested;
                state.async_cv.notify_one();
            }
            return 0;
        }
    } else {
        if (resize) {
            present_stage.store(2, std::memory_order_relaxed);
            if (!CreateSwapchain(drawable_width, drawable_height))
                return -1;
        }
        present_stage.store(3, std::memory_order_relaxed);
        bool failed = false;
        slot = FindPresentSlot(failed);
        if (failed)
            return -1;
        if (!slot)
            return 0;
        present_stage.store(4, std::memory_order_relaxed);
        if (vkResetFences(state.device, 1, &slot->acquire_fence) != VK_SUCCESS)
            return -1;
        const auto acquire = vkAcquireNextImageKHR(state.device, state.swapchain, 0, slot->acquired,
                                                   slot->acquire_fence, &index);
        if (acquire == VK_NOT_READY || acquire == VK_TIMEOUT)
            return 0;
        if (acquire == VK_ERROR_OUT_OF_DATE_KHR) {
            state.rebuild_surface = true;
            return 0;
        }
        if (acquire != VK_SUCCESS && acquire != VK_SUBOPTIMAL_KHR)
            return -1;
        slot->acquisition_pending = true;
    }
    if (index >= state.present_images.size())
        return -1;
    present_stage.store(5, std::memory_order_relaxed);
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
                           &blit, state.present_filter);
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
    if (state.async_present) {
        bool failed = false;
        auto* next = resize ? nullptr : FindPresentSlot(failed);
        if (failed)
            next = nullptr;
        {
            std::lock_guard lock{state.async_mutex};
            state.async_phase = AsyncPhase::SubmitQueued;
        }
#if defined(AZAHAR_IOS_MOLTENVK_BRIDGE)
        if (present_scheduler && defer_present) {
            // Record only a host callback. Earlier Flush work is ahead of this
            // chunk and future rendering is behind it, even when CPU runs ahead.
            azahar_ios_vk_schedule_present(
                present_scheduler,
                [](void* current, void* following, unsigned image_index) {
                    // SubmitQueued pins the swapchain until this callback publishes its result.
                    SubmitAsyncBlit(static_cast<Context::PresentSlot*>(current),
                                    static_cast<Context::PresentSlot*>(following),
                                    state.present_ready[image_index]);
                },
                slot, next, index);
            return 1;
        }
#endif
        SubmitAsyncBlit(slot, next, ready);
        return 1;
    }
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
    present_stage.store(6, std::memory_order_relaxed);
    {
        std::lock_guard lock{state.queue_mutex};
        present_stage.store(7, std::memory_order_relaxed);
        if (vkQueueSubmit(state.queue, 1, &submit, slot->fence) != VK_SUCCESS)
            return -1;
    }
    slot->pending = true;
    // The submitted fence now covers consumption of the acquired semaphore.
    slot->acquisition_pending = false;
    present_stage.store(8, std::memory_order_relaxed);
    std::lock_guard queue_lock{state.presentation_queue == state.queue ? state.queue_mutex
                                                                       : state.presentation_mutex};
    const auto result = vkQueuePresentKHR(state.presentation_queue, &present);
    if (result == VK_ERROR_OUT_OF_DATE_KHR) {
        state.rebuild_surface = true;
        return 0;
    }
    if (result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR) {
        accepted_presentations.fetch_add(1, std::memory_order_release);
        return 1;
    }
    return -1;
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

extern "C" unsigned azahar_ios_vk_presented_count() {
#if defined(__APPLE__)
    return accepted_presentations.load(std::memory_order_acquire);
#else
    return 0;
#endif
}

extern "C" unsigned azahar_ios_vk_present_stage() {
#if defined(__APPLE__)
    const unsigned submit = async_submit_stage.load(std::memory_order_relaxed);
    const unsigned worker = async_worker_stage.load(std::memory_order_relaxed);
    return submit ? submit : worker ? worker : present_stage.load(std::memory_order_relaxed);
#else
    return 0;
#endif
}

extern "C" void azahar_ios_vk_present_extent(unsigned* width, unsigned* height) {
    if (width)
        *width = 0;
    if (height)
        *height = 0;
#if defined(__APPLE__)
    if (width)
        *width = state.extent.width;
    if (height)
        *height = state.extent.height;
#endif
}

extern "C" void azahar_ios_vk_wait_graphics_idle() {
    if (state.device && state.queue) {
        std::lock_guard lock{state.queue_mutex};
        vkQueueWaitIdle(state.queue);
    }
}

extern "C" bool azahar_ios_vk_separate_present_queue() {
#if defined(__APPLE__)
    return state.presentation_queue && state.presentation_queue != state.queue;
#else
    return false;
#endif
}

extern "C" bool azahar_ios_vk_readback_failed() {
    return state.device_failed;
}

extern "C" bool azahar_ios_vk_drain_readback() {
#if defined(__APPLE__)
    if (!StopAsyncWorker())
        return false;
    for (auto& slot : state.present_slots) {
        if (slot.acquisition_pending) {
            const auto acquire =
                vkWaitForFences(state.device, 1, &slot.acquire_fence, VK_TRUE, 1'000'000'000ULL);
            if (acquire != VK_SUCCESS && acquire != VK_ERROR_DEVICE_LOST)
                return false;
            slot.acquisition_pending = false;
        }
        if (!slot.pending)
            continue;
        const auto result =
            vkWaitForFences(state.device, 1, &slot.fence, VK_TRUE, 1'000'000'000ULL);
        if (result != VK_SUCCESS && result != VK_ERROR_DEVICE_LOST)
            return false;
        slot.pending = false;
    }
#endif
    return DrainStagingCopies();
}

extern "C" void azahar_ios_vk_shutdown() {
#if defined(__APPLE__)
    // A blocked driver call must never outlive its core, swapchain or layer.
    while (!StopAsyncWorker())
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    if (state.device) {
        for (auto& slot : state.present_slots) {
            if (!slot.acquisition_pending)
                continue;
            VkResult result;
            do {
                result = vkWaitForFences(state.device, 1, &slot.acquire_fence, VK_TRUE,
                                         1'000'000'000ULL);
            } while (result == VK_TIMEOUT);
            slot.acquisition_pending = false;
        }
    }
#endif
    if (state.device) {
        std::lock_guard lock{state.queue_mutex};
        vkDeviceWaitIdle(state.device);
#if defined(__APPLE__)
        DestroySwapchain();
        for (auto& slot : state.present_slots) {
            vkDestroySemaphore(state.device, slot.acquired, nullptr);
            vkDestroyFence(state.device, slot.fence, nullptr);
            vkDestroyFence(state.device, slot.acquire_fence, nullptr);
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
    state.async_present = true;
    state.presentation_queue = VK_NULL_HANDLE;
    state.async_phase = AsyncPhase::Idle;
    state.async_stop = state.async_exited = state.async_rebuild = false;
    state.async_slot = state.async_next = nullptr;
    state.async_index = 0;
    accepted_presentations.store(0, std::memory_order_relaxed);
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
