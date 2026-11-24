// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace SwRenderer {

struct ScanlineEdge {
    std::int32_t first{};
    std::int32_t step{};

    // Used only for bounded coordinates to avoid signed overflow.
    static constexpr ScanlineEdge Make(int ax, int ay, int bx, int by, int x, int y, int bias) {
        return {bias + (bx - ax) * (y - ay) - (by - ay) * (x - ax), (ay - by) * 16};
    }
};

struct RasterWorkPlan {
    std::size_t rows_per_job;
    bool inline_work;

    static constexpr RasterWorkPlan Make(std::size_t columns, std::size_t rows, std::size_t workers,
                                         bool optimized) {
        if (!optimized) {
            return {1, false};
        }
        if (workers <= 1 || rows <= 1 || columns * rows <= 64) {
            return {std::max<std::size_t>(rows, 1), true};
        }
        const auto target = workers * 2;
        return {std::max<std::size_t>(1, (rows + target - 1) / target), false};
    }
};

} // namespace SwRenderer
