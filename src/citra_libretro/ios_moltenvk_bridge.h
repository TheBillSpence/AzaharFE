// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
#pragma once

#include <cstddef>

// The Objective-C++ iPhone frontend consumes only this small C ABI. All
// Vulkan types and MoltenVK linkage remain inside the libretro core dylib.
extern "C" {
__attribute__((visibility("default"))) bool azahar_ios_vk_start(const void* negotiation);
__attribute__((visibility("default"))) const void* azahar_ios_vk_get_interface();
__attribute__((visibility("default"))) bool azahar_ios_vk_readback(unsigned width, unsigned height,
                                                                   const void** pixels,
                                                                   std::size_t* pitch);
// After an unsuccessful bounded wait, do not destroy a pending GPU copy.
__attribute__((visibility("default"))) bool azahar_ios_vk_readback_failed();
__attribute__((visibility("default"))) bool azahar_ios_vk_drain_readback();
__attribute__((visibility("default"))) void azahar_ios_vk_shutdown();
__attribute__((visibility("default"))) bool azahar_ios_vk_game_loaded();
}
