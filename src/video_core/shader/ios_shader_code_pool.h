// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#pragma once

#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <new>
#include <oaknut/code_block.hpp>
#include "citra_libretro/environment.h"

namespace Pica::Shader {

// Session-owned slabs. Published slices are immutable and remain alive via shared ownership.
// The caller compiles shaders on the emulation thread; no executable region is recycled
// until all users of the slab have been destroyed.
class IOSShaderCodePool {
public:
    struct Slice {
        std::shared_ptr<oaknut::CodeBlock> block;
        std::size_t offset;
    };

    Slice Allocate(std::size_t bytes) {
        constexpr std::size_t page = 16 * 1024;
        constexpr std::size_t slab = 2 * 1024 * 1024;
        constexpr std::size_t limit = 32 * 1024 * 1024;
        if (!bytes || bytes > limit) {
            throw std::bad_alloc{};
        }
        const auto aligned = (bytes + 63) & ~std::size_t{63};
        if (!current || aligned > capacity - used) {
            const auto size = std::max(slab, (aligned + page - 1) & ~(page - 1));
            if (size > limit - allocated) {
                throw std::bad_alloc{};
            }
            char message[128];
            std::snprintf(message, sizeof(message),
                          "SUPER27 shader slab requesting %zu KiB (total %zu KiB)",
                          size / 1024, allocated / 1024);
            LibRetro::DisplayMessage(message);
            auto next = std::make_shared<oaknut::CodeBlock>(size);
            LibRetro::DisplayMessage("SUPER27 shader slab allocated");
            current = std::move(next);
            capacity = size;
            used = 0;
            allocated += size;
        }
        Slice result{current, used};
        used += aligned;
        return result;
    }

private:
    std::shared_ptr<oaknut::CodeBlock> current;
    std::size_t capacity = 0;
    std::size_t used = 0;
    std::size_t allocated = 0;
};

} // namespace Pica::Shader
#endif
