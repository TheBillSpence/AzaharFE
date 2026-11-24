// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#include <cassert>
#include <cstdint>
#include <random>
#include "video_core/renderer_software/sw_raster_work.h"

int main() {
    using namespace SwRenderer;
    std::mt19937 rng(0x27);
    std::uniform_int_distribution<int> coord(0, 16384);
    for (int i = 0; i < 100000; ++i) {
        const int ax = coord(rng), ay = coord(rng), bx = coord(rng), by = coord(rng);
        const int x = coord(rng) % 16000, y = coord(rng), bias = (i & 1) ? -1 : 0;
        const auto edge = ScanlineEdge::Make(ax, ay, bx, by, x, y, bias);
        auto value = edge.first;
        for (int n = 0; n < 16; ++n) {
            const auto expected = static_cast<std::int64_t>(bx - ax) * (y - ay) -
                                  static_cast<std::int64_t>(by - ay) * (x + n * 16 - ax) + bias;
            assert(value == expected);
            value += edge.step;
        }
    }
    for (std::size_t workers : {1, 2, 4, 6}) {
        for (std::size_t rows = 1; rows <= 1024; ++rows) {
            for (std::size_t columns : {1, 8, 400}) {
                const auto plan = RasterWorkPlan::Make(columns, rows, workers, true);
                assert(plan.rows_per_job >= 1);
                std::size_t processed = 0, jobs = 0;
                for (std::size_t start = 0; start < rows; start += plan.rows_per_job) {
                    const auto end = std::min(rows, start + plan.rows_per_job);
                    for (auto row = start; row < end; ++row) {
                        assert(row == processed++);
                    }
                    ++jobs;
                }
                assert(processed == rows);
                assert(plan.inline_work || jobs <= workers * 2);
                const auto reference = RasterWorkPlan::Make(columns, rows, workers, false);
                assert(!reference.inline_work && reference.rows_per_job == 1);
            }
        }
    }
}
