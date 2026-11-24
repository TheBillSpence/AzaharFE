#pragma once
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <mutex>

// Bounded stereo PCM FIFO. Producer never waits for the hardware to drain.
// The realtime consumer uses try_lock and returns silence on contention.
class AZAudioBuffer {
public:
    static constexpr std::size_t Capacity = 4096;
    void Clear() {
        std::lock_guard<std::mutex> lock(mutex);
        read = count = 0;
        primed = false;
        lastL = lastR = 0;
    }
    void Push(const std::int16_t* samples, std::size_t frames) {
        if (!samples || !frames) return;
        if (frames > Capacity) {
            samples += (frames - Capacity) * 2;
            frames = Capacity;
        }
        std::lock_guard<std::mutex> lock(mutex);
        const auto drop = count + frames > Capacity ? count + frames - Capacity : 0;
        read = (read + drop) % Capacity;
        count -= drop;
        for (std::size_t i = 0; i < frames; ++i) {
            const auto pos = (read + count + i) % Capacity;
            pcm[pos * 2] = samples[i * 2];
            pcm[pos * 2 + 1] = samples[i * 2 + 1];
        }
        count += frames;
    }
    std::size_t Pull(std::int16_t* output, std::size_t frames) {
        std::fill_n(output, frames * 2, std::int16_t{0});
        std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        if (!lock.owns_lock()) return 0;
        const auto take = std::min(frames, count);
        for (std::size_t i = 0; i < take; ++i) {
            const auto pos = (read + i) % Capacity;
            output[i * 2] = pcm[pos * 2];
            output[i * 2 + 1] = pcm[pos * 2 + 1];
        }
        read = (read + take) % Capacity;
        count -= take;
        return take;
    }
    // Start only after accumulating several audio blocks. Rebuffer after a
    // starvation rather than playing alternating fragments of silence and PCM.
    std::size_t PullBuffered(std::int16_t* output, std::size_t frames,
                             std::size_t threshold) {
        std::fill_n(output, frames * 2, std::int16_t{0});
        std::unique_lock<std::mutex> lock(mutex, std::try_to_lock);
        if (!lock.owns_lock()) return 0;
        if (!primed && count < std::min(threshold, Capacity)) return 0;
        primed = true;
        const auto take = std::min(frames, count);
        for (std::size_t i = 0; i < take; ++i) {
            const auto pos = (read + i) % Capacity;
            output[i * 2] = pcm[pos * 2];
            output[i * 2 + 1] = pcm[pos * 2 + 1];
        }
        read = (read + take) % Capacity;
        count -= take;
        if (take) {
            lastL = output[(take - 1) * 2];
            lastR = output[(take - 1) * 2 + 1];
        }
        if (take < frames) {
            const auto fade = std::min<std::size_t>(64, frames - take);
            for (std::size_t i = 0; i < fade; ++i) {
                output[(take + i) * 2] = static_cast<std::int16_t>(lastL * static_cast<int>(fade-i-1) / static_cast<int>(fade));
                output[(take + i) * 2 + 1] = static_cast<std::int16_t>(lastR * static_cast<int>(fade-i-1) / static_cast<int>(fade));
            }
            lastL = lastR = 0;
            primed = false;
        }
        return take;
    }
private:
    bool primed = false;
    std::int16_t lastL = 0, lastR = 0;
    std::array<std::int16_t, Capacity * 2> pcm{};
    std::mutex mutex;
    std::size_t read = 0, count = 0;
};
