// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#pragma once

#include <algorithm>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <thread>
#include <vector>

namespace SwRenderer {

struct ScanlineEdge {
    std::int32_t first{};
    std::int32_t step{};

    // Used only for bounded coordinates to avoid signed overflow.
    static constexpr ScanlineEdge Make(int ax, int ay, int bx, int by, int x, int y, int bias) {
        return {bias + (bx - ax) * (y - ay) - (by - ay) * (x - ax), (ay - by) * 16};
    }
};

// Intersect a span with the inclusive nonnegative range of each linear edge.
// The caller uses bounded fixed-point coordinates; 64-bit intermediates also
// keep negation and ceiling division safe for every int32 edge value.
struct CoveredSpan {
    std::size_t first;
    std::size_t end;

    constexpr void Clip(ScanlineEdge edge) {
        const auto start = static_cast<std::int64_t>(edge.first);
        const auto step = static_cast<std::int64_t>(edge.step);
        if (step > 0 && start < 0) {
            const auto lower = static_cast<std::size_t>((-start + step - 1) / step);
            first = std::min(end, std::max(first, lower));
        } else if (step < 0) {
            if (start < 0) {
                end = first;
            } else {
                const auto upper = static_cast<std::size_t>(start / -step + 1);
                end = std::max(first, std::min(end, upper));
            }
        } else if (step == 0 && start < 0) {
            end = first;
        }
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
        if (workers <= 1 || rows < 8 || columns * rows <= 4096) {
            return {std::max<std::size_t>(rows, 1), true};
        }
        const auto target = workers;
        return {std::max<std::size_t>(1, (rows + target - 1) / target), false};
    }
};

// One synchronous publication per primitive. No queued tasks, per-row locks or
// allocations. The caller participates; workers cannot outlive the callback.
class RasterWorkGroup {
public:
    explicit RasterWorkGroup(std::size_t lanes) : lanes{std::max<std::size_t>(1, lanes)} {
        workers.reserve(this->lanes - 1);
        for (std::size_t lane = 1; lane < this->lanes; ++lane) {
            workers.emplace_back([this, lane] { Worker(lane); });
        }
    }

    ~RasterWorkGroup() {
        {
            std::lock_guard lock{mutex};
            stopping = true;
        }
        start.notify_all();
        for (auto& worker : workers) {
            worker.join();
        }
    }

    RasterWorkGroup(const RasterWorkGroup&) = delete;
    RasterWorkGroup& operator=(const RasterWorkGroup&) = delete;

    template <typename Fn>
    void Run(std::size_t rows, Fn& fn) {
        if (lanes == 1) {
            for (std::size_t row = 0; row < rows; ++row) {
                fn(row);
            }
            return;
        }
        {
            std::lock_guard lock{mutex};
            context = &fn;
            callback = [](void* ptr, std::size_t row) { (*static_cast<Fn*>(ptr))(row); };
            count = rows;
            remaining = workers.size();
            ++generation;
        }
        start.notify_all();
        Execute(0);
        std::unique_lock lock{mutex};
        done.wait(lock, [&] { return remaining == 0; });
        context = nullptr;
        callback = nullptr;
    }

private:
    void Execute(std::size_t lane) const {
        const auto first = count * lane / lanes;
        const auto end = count * (lane + 1) / lanes;
        for (auto row = first; row < end; ++row) {
            callback(context, row);
        }
    }

    void Worker(std::size_t lane) {
        std::size_t seen = 0;
        std::unique_lock lock{mutex};
        for (;;) {
            start.wait(lock, [&] { return stopping || generation != seen; });
            if (stopping) {
                return;
            }
            seen = generation;
            lock.unlock();
            Execute(lane);
            lock.lock();
            if (--remaining == 0) {
                done.notify_one();
            }
        }
    }

    const std::size_t lanes;
    std::mutex mutex;
    std::condition_variable start, done;
    std::size_t generation = 0;
    std::size_t remaining = 0;
    std::size_t count = 0;
    bool stopping = false;
    void* context = nullptr;
    void (*callback)(void*, std::size_t) = nullptr;
    std::vector<std::thread> workers;
};

} // namespace SwRenderer
