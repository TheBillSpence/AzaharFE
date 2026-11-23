// Shared by the iOS frontend and its bundled libretro core.
#pragma once

#include "libretro.h"

namespace LibRetro {
// Private environment query. Older or third-party frontends may decline.
constexpr unsigned GetFrameStopCallback = RETRO_ENVIRONMENT_PRIVATE | 0x415a;
using FrameStopCallback = bool (*)(uint64_t completed_slices);
} // namespace LibRetro
