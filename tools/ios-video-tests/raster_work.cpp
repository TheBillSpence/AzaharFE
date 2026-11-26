// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#include <array>
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
    // Compare clipped spans against a scalar coverage mask, including empty,
    // single-pixel, flat and negative-slope edges.
    std::uniform_int_distribution<int> first_value(-1000000, 1000000);
    std::uniform_int_distribution<int> step_value(-262144, 262144);
    for (int i = 0; i < 100000; ++i) {
        const std::size_t count = static_cast<std::size_t>(i % 129);
        const std::array<ScanlineEdge, 3> edges{{
            {first_value(rng), i % 7 == 0 ? 0 : step_value(rng)},
            {first_value(rng), i % 11 == 0 ? 0 : step_value(rng)},
            {first_value(rng), i % 13 == 0 ? 0 : step_value(rng)},
        }};
        CoveredSpan span{0, count};
        for (const auto edge : edges) {
            span.Clip(edge);
        }
        assert(span.first <= span.end && span.end <= count);
        for (std::size_t x = 0; x < count; ++x) {
            bool covered = true;
            for (const auto edge : edges) {
                covered &= static_cast<std::int64_t>(edge.first) +
                               static_cast<std::int64_t>(edge.step) * static_cast<std::int64_t>(x) >=
                           0;
            }
            assert(covered == (x >= span.first && x < span.end));
        }
    }
    for (std::size_t workers : {1, 2, 4, 6}) {
        RasterWorkGroup group(workers);
        for (std::size_t iteration = 0; iteration < 1000; ++iteration) {
            const auto rows = iteration % 127 + 1;
            std::vector<int> hits(rows, 0);
            auto visit = [&](std::size_t row) { ++hits[row]; };
            group.Run(rows, visit);
            for (const auto hit : hits) {
                assert(hit == 1);
            }
        }
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
                assert(plan.inline_work || jobs <= workers);
                const auto reference = RasterWorkPlan::Make(columns, rows, workers, false);
                assert(!reference.inline_work && reference.rows_per_job == 1);
            }
        }
    }
}
