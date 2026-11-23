// Copyright 2026 AzaharFE contributors
// Licensed under GPLv3 or any later version.
#pragma once

#ifdef IOS
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>

namespace AzaharProfile {
enum class Section : std::size_t {
    CoreExecution,
    DynarmicJIT,
    KernelSVC,
    PicaCommands,
    SoftwareTriangles,
    ScreenDecode,
    DSPMix,
    AudioOutput,
    Count,
};
constexpr std::size_t SectionCount = static_cast<std::size_t>(Section::Count);
using Clock = std::chrono::steady_clock;

struct Counter {
    std::atomic<std::uint64_t> ns{0};
    std::atomic<std::uint64_t> calls{0};
};
inline std::array<Counter, SectionCount> counters{};
inline std::atomic<bool> profiling_enabled{false};

// These guest data-memory callbacks run on the core thread, where snapshots
// are collected. The direct-page-table path does not invoke them.
inline thread_local std::uint64_t guest_reads = 0;
inline thread_local std::uint64_t guest_writes = 0;

inline bool Enabled() {
    return profiling_enabled.load(std::memory_order_relaxed);
}

inline void Configure(bool enabled) {
    profiling_enabled.store(false, std::memory_order_relaxed);
    for (auto& counter : counters) {
        counter.ns.store(0, std::memory_order_relaxed);
        counter.calls.store(0, std::memory_order_relaxed);
    }
    guest_reads = 0;
    guest_writes = 0;
    profiling_enabled.store(enabled, std::memory_order_relaxed);
}

class Scope final {
public:
    explicit Scope(Section section_) : section(section_), active(Enabled()) {
        if (active)
            started = Clock::now();
    }
    ~Scope() {
        if (!active)
            return;
        const auto elapsed =
            std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - started);
        auto& counter = counters[static_cast<std::size_t>(section)];
        counter.ns.fetch_add(static_cast<std::uint64_t>(elapsed.count()),
                             std::memory_order_relaxed);
        counter.calls.fetch_add(1, std::memory_order_relaxed);
    }
    Scope(const Scope&) = delete;
    Scope& operator=(const Scope&) = delete;

private:
    Section section;
    bool active;
    Clock::time_point started{};
};

struct Snapshot {
    std::array<std::uint64_t, SectionCount> ns{};
    std::array<std::uint64_t, SectionCount> calls{};
    std::uint64_t reads = 0;
    std::uint64_t writes = 0;

    double Milliseconds(Section section) const {
        return static_cast<double>(ns[static_cast<std::size_t>(section)]) / 1'000'000.0;
    }
};

inline Snapshot TakeSnapshot() {
    Snapshot result;
    for (std::size_t i = 0; i < SectionCount; ++i) {
        result.ns[i] = counters[i].ns.exchange(0, std::memory_order_relaxed);
        result.calls[i] = counters[i].calls.exchange(0, std::memory_order_relaxed);
    }
    result.reads = guest_reads;
    result.writes = guest_writes;
    guest_reads = 0;
    guest_writes = 0;
    return result;
}
} // namespace AzaharProfile
#endif
