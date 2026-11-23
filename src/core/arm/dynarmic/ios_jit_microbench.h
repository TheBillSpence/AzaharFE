// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#pragma once
#ifdef IOS
#include <string>
#include <string_view>

namespace Core {
// Synthetic ARM32 ALU and branch workload executed by the actual on-device
// Dynarmic ARM64 backend. It does not emulate graphics, HLE, audio, or RAM.
std::string RunIOSJitMicrobenchmark(std::string_view mode);
} // namespace Core
#endif
