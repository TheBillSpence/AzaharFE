// Copyright 2026 Azahar Emulator Project
// Licensed under GPLv2 or any later version

#pragma once

#include <string_view>

#include <dynarmic/interface/optimization_flags.h>

namespace Core {

// Mode selection affects only newly constructed JITs. Never hot-patch code.
inline Dynarmic::OptimizationFlag SelectIOSJitOptimizations(Dynarmic::OptimizationFlag upstream,
                                                            std::string_view mode) {
    using Flag = Dynarmic::OptimizationFlag;
    if (mode == "fast" || mode == "turbo" || mode == "direct") {
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
