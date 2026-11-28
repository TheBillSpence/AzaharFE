// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
#pragma once

#include <cstddef>

// The Objective-C++ iPhone frontend consumes only this small C ABI. All
// Vulkan types and MoltenVK linkage remain inside the libretro core dylib.
extern "C" {
__attribute__((visibility("default"))) bool azahar_ios_vk_start(const void* negotiation);
__attribute__((visibility("default"))) const void* azahar_ios_vk_get_interface();
// The frontend retains the CAMetalLayer for the full core lifetime. Rectangles
// contain normalized source and destination corners (8 floats per rectangle).
// 1: queued or submitted, 0: busy, -1: use CPU readback instead.
// The accepted count below advances only after successful queue presentation.
__attribute__((visibility("default"))) void azahar_ios_vk_set_metal_layer(void* layer);
__attribute__((visibility("default"))) void azahar_ios_vk_set_async_present(bool enabled);
// Lifecycle-only atomic flag; do not acquire new drawables while suspended.
__attribute__((visibility("default"))) void azahar_ios_vk_set_presentation_suspended(
    bool suspended);
__attribute__((visibility("default"))) bool azahar_ios_vk_separate_present_queue();
// Core-only synchronization before destroying the reusable output image.
void azahar_ios_vk_wait_graphics_idle();
// Core-internal scoped access to the scheduler during the video callback.
void azahar_ios_vk_begin_present(void* scheduler);
void azahar_ios_vk_end_present();
// Keep the raw Vulkan bridge separate from Vulkan-Hpp configuration macros.
bool azahar_ios_vk_wait_dispatched(void* scheduler, unsigned timeout_ms);
bool azahar_ios_vk_can_combine(void* scheduler);
void azahar_ios_vk_flush_render(void* scheduler);
// Opaque Vulkan handles are pointers on the 64-bit Apple bridge target.
void azahar_ios_vk_schedule_combined(void* scheduler, void* blit, void* acquired, void* ready,
                                     void* fence, void (*complete)(void*, void*, bool), void* slot,
                                     void* next);
void azahar_ios_vk_schedule_present(void* scheduler, void (*callback)(void*, void*, unsigned),
                                    void* slot, void* next, unsigned index);
__attribute__((visibility("default"))) int azahar_ios_vk_present_frame(
    unsigned width, unsigned height, unsigned drawable_width, unsigned drawable_height,
    const float* rectangles, unsigned count);
// Lock-free diagnostic: 0 idle, 1 validation, 2 rebuild, 3 fences, 4 acquire,
// 5 recording, 6 queue lock, 7 submit, 8 present.
__attribute__((visibility("default"))) unsigned azahar_ios_vk_present_stage();
// Monotonic per-session count of successful queue presents, not physical scanout.
__attribute__((visibility("default"))) unsigned azahar_ios_vk_presented_count();
// Actual surface extent in physical pixels, including a rejected extent.
__attribute__((visibility("default"))) void azahar_ios_vk_present_extent(unsigned* width,
                                                                         unsigned* height);
__attribute__((visibility("default"))) bool azahar_ios_vk_readback(unsigned width, unsigned height,
                                                                   const void** pixels,
                                                                   std::size_t* pitch);
// 1: completed pixels, 0: no completed frame yet, -1: failure. Native byte order
// is described by rgba; the returned pointer is valid until the next call.
__attribute__((visibility("default"))) int azahar_ios_vk_readback_frame(
    unsigned width, unsigned height, const void** pixels, std::size_t* pitch, bool* rgba,
    bool asynchronous);
// After an unsuccessful bounded wait, do not destroy a pending GPU copy.
__attribute__((visibility("default"))) bool azahar_ios_vk_readback_failed();
__attribute__((visibility("default"))) bool azahar_ios_vk_drain_readback();
__attribute__((visibility("default"))) void azahar_ios_vk_shutdown();
__attribute__((visibility("default"))) bool azahar_ios_vk_game_loaded();
}
