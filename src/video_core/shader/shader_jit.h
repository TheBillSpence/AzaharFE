// Copyright 2016 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#pragma once

#include "common/arch.h"
#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)

#include <memory>
#include <unordered_map>
#include "common/common_types.h"
#include "video_core/shader/shader.h"

namespace Pica::Shader {

class JitShader;
#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
class IOSShaderCodePool;
#endif

class JitEngine final : public ShaderEngine {
public:
    JitEngine();
    ~JitEngine() override;

    void SetupBatch(ShaderSetup& setup, u32 entry_point) override;
    void Run(const ShaderSetup& setup, ShaderUnit& state) const override;

private:
    std::unordered_map<u64, std::unique_ptr<JitShader>> cache;
#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
    std::unique_ptr<IOSShaderCodePool> code_pool;
#endif
};

} // namespace Pica::Shader

#endif // CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)
