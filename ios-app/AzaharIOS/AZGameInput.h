#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <deque>
#include <mutex>
#include "libretro.h"

namespace AZInput {
inline int16_t Axis(double value) {
    return static_cast<int16_t>(std::lround(std::clamp(value, -1.0, 1.0) * 32767.0));
}

struct Pointer {
    int16_t x = 0, y = 0;
    bool down = false;
};

// ScaleAspectFit uses the entire composite framebuffer, including the space around each screen.
inline Pointer Project(double x, double y, double viewW, double viewH, double imageW, double imageH) {
    if (imageW <= 0 || imageH <= 0 || viewW <= 0 || viewH <= 0) return {};
    const double scale = std::min(viewW / imageW, viewH / imageH);
    const double w = imageW * scale, h = imageH * scale;
    const double u = (x - (viewW - w) / 2) / w, v = (y - (viewH - h) / 2) / h;
    if (u < 0 || u >= 1 || v < 0 || v >= 1) return {};
    return {Axis(u * 2 - 1), Axis(v * 2 - 1), true};
}

struct Pad {
    uint16_t buttons = 0;
    int16_t axes[2][2]{};
    void Button(unsigned id, bool pressed) {
        if (pressed && id < 16) buttons |= static_cast<uint16_t>(1u << id);
    }
};

class State {
public:
    void Enable(bool value) {
        std::lock_guard lock(mutex);
        enabled = value;
        if (!value) {
            onscreen = pad = {};
            pending.clear();
            pointer = {};
        }
    }
    void Button(unsigned id, bool down) {
        std::lock_guard lock(mutex);
        if (!enabled || id >= 16) return;
        if (down) onscreen.Button(id, true);
        else onscreen.buttons &= ~(1u << id);
    }
    void Circle(int16_t x, int16_t y) {
        std::lock_guard lock(mutex);
        if (enabled) {
            onscreen.axes[0][0] = x;
            onscreen.axes[0][1] = y;
        }
    }
    void Touch(Pointer event) {
        std::lock_guard lock(mutex);
        if (!enabled) return;
        // Preserve fast taps between polls, and coalesce consecutive drag positions.
        if (!pending.empty() && pending.back().down == event.down) {
            pending.back() = event;
        } else {
            if (pending.size() == 16) pending.pop_front();
            pending.push_back(event);
        }
    }
    void Poll(Pad physical) {
        std::lock_guard lock(mutex);
        if (!enabled) return;
        pad = physical;
        pad.buttons |= onscreen.buttons;
        if (onscreen.axes[0][0] || onscreen.axes[0][1]) {
            pad.axes[0][0] = onscreen.axes[0][0];
            pad.axes[0][1] = onscreen.axes[0][1];
        }
        if (!pending.empty()) {
            pointer = pending.front();
            pending.pop_front();
        }
    }
    int16_t Read(unsigned device, unsigned index, unsigned id) {
        std::lock_guard lock(mutex);
        if (device == RETRO_DEVICE_JOYPAD && index == 0 && id < 16)
            return (pad.buttons >> id) & 1u;
        if (device == RETRO_DEVICE_ANALOG && index < 2 && id < 2) return pad.axes[index][id];
        if (device == RETRO_DEVICE_POINTER && index == 0) {
            if (id == RETRO_DEVICE_ID_POINTER_PRESSED) return pointer.down;
            if (id == RETRO_DEVICE_ID_POINTER_X) return pointer.x;
            if (id == RETRO_DEVICE_ID_POINTER_Y) return pointer.y;
        }
        return 0;
    }
private:
    std::mutex mutex;
    bool enabled = false;
    Pad onscreen{}, pad{};
    Pointer pointer{};
    std::deque<Pointer> pending;
};
} // namespace AZInput
