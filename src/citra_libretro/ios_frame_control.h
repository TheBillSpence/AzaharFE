// Shared by the iOS frontend and its bundled libretro core.
#pragma once

#include "libretro.h"

namespace LibRetro {
// Private environment query. Older or third-party frontends may decline.
constexpr unsigned GetFrameStopCallback = RETRO_ENVIRONMENT_PRIVATE | 0x415a;
constexpr unsigned GetAcceptedVideoFrame = RETRO_ENVIRONMENT_PRIVATE | 0x415b;
enum class ReadbackRecovery { Continue, RetrySoftware, ReportFailure };

constexpr ReadbackRecovery CheckReadback(unsigned failures, bool received_video) {
    if (failures < 3)
        return ReadbackRecovery::Continue;
    return received_video ? ReadbackRecovery::ReportFailure : ReadbackRecovery::RetrySoftware;
}

using FrameStopCallback = bool (*)(uint64_t completed_slices);
} // namespace LibRetro
