// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version

#pragma once

#include <string_view>
#include <cstddef>

#include <dynarmic/interface/optimization_flags.h>

namespace Core {

// Keep one policy shared by the actual iOS CPU and native ARM64 harness.
constexpr bool IOSJitHyper(std::string_view mode) {
    return mode == "hyper" || mode == "hyperfp" || mode == "fastmem" || mode == "fastmemfp";
}
constexpr bool IOSJitDirectMemory(std::string_view mode) {
    return mode == "direct" || IOSJitHyper(mode);
}
constexpr bool IOSJitRelaxedFP(std::string_view mode) {
    return mode == "hyperfp" || mode == "fastmemfp";
}
constexpr bool IOSJitSkipProbes(std::string_view mode) {
    return mode == "turbo" || IOSJitDirectMemory(mode);
}
constexpr bool IOSJitTrueFastmem(std::string_view mode) {
    return mode == "fastmem" || mode == "fastmemfp";
}
constexpr std::size_t IOSJitCacheSize(std::string_view mode) {
    return (IOSJitHyper(mode) ? 128 : IOSJitSkipProbes(mode) ? 32 : 16) * 1024 * 1024;
}

// Mode selection affects only newly constructed JITs. Never hot-patch code.
inline Dynarmic::OptimizationFlag SelectIOSJitOptimizations(Dynarmic::OptimizationFlag upstream,
                                                            std::string_view mode) {
    using Flag = Dynarmic::OptimizationFlag;
    if (IOSJitRelaxedFP(mode)) {
        // Deliberately opt in to approximate FP only; never bypass the exclusive
        // monitor, and never relax cycle accounting.
        return upstream | Flag::Unsafe_ReducedErrorFP | Flag::Unsafe_InaccurateNaN |
               Flag::Unsafe_IgnoreStandardFPCRValue;
    }
    if (mode == "fast" || IOSJitSkipProbes(mode)) {
        // Restore upstream block linking, return-stack prediction
        // and fast dispatch. Verify stability on the target iPhone.
        return upstream;
    }
    if (mode == "linked") {
        // Experimental intermediate step: block linking enabled only.
        return upstream & ~(Flag::ReturnStackBuffer | Flag::FastDispatch);
    }
    // Compatibility: preserve the iPhone configuration already shown to run.
    return upstream & ~(Flag::BlockLinking | Flag::ReturnStackBuffer | Flag::FastDispatch);
}

} // namespace Core
