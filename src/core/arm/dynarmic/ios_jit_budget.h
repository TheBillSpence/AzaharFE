// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version

#pragma once

#include <algorithm>
#include <cstdint>

namespace Core {

// Preserve short, proven scheduler slices for compatibility mode, but let
// Fast Dispatch execute longer native ARM64 blocks to reduce return overhead.
// The core timer's next event and cooperative JIT HaltExecution still apply.
constexpr std::uint64_t PostStartupJitCap(bool submitted_software_frame,
                                          bool fast_dispatch = false) {
    if (fast_dispatch) {
        return submitted_software_frame ? 262144 : 4096;
    }
    return submitted_software_frame ? 16384 : 256;
}

constexpr std::uint64_t LimitJitBudget(std::int64_t downcount, std::uint64_t cap) {
    return downcount > 0 ? std::min(static_cast<std::uint64_t>(downcount), cap) : 0;
}

} // namespace Core
