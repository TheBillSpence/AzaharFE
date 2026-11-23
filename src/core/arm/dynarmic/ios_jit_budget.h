// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version

#pragma once

#include <algorithm>
#include <cstdint>

namespace Core {

constexpr std::uint64_t PostStartupJitCap(bool submitted_software_frame) {
    return submitted_software_frame ? 16384 : 256;
}

constexpr std::uint64_t LimitJitBudget(std::int64_t downcount, std::uint64_t cap) {
    return downcount > 0 ? std::min(static_cast<std::uint64_t>(downcount), cap) : 0;
}

} // namespace Core
