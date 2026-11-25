// Copyright 2016-2026 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include "common/arch.h"
#if CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)

#include "common/assert.h"
#include "common/hash.h"
#include "common/microprofile.h"
#include "video_core/shader/shader.h"
#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
#include <new>
#include "video_core/shader/ios_shader_code_pool.h"
#include "video_core/shader/shader_interpreter.h"
#endif
#include "video_core/shader/shader_jit.h"
#if CITRA_ARCH(arm64)
#include "video_core/shader/shader_jit_a64_compiler.h"
#endif
#if CITRA_ARCH(x86_64)
#include "video_core/shader/shader_jit_x64_compiler.h"
#endif

namespace Pica::Shader {

JitEngine::JitEngine()
#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
    : code_pool(std::make_unique<IOSShaderCodePool>())
#endif
{
}
JitEngine::~JitEngine() = default;

void JitEngine::SetupBatch(ShaderSetup& setup, u32 entry_point) {
    ASSERT(entry_point < MAX_PROGRAM_CODE_LENGTH);
    setup.entry_point = entry_point;

    setup.DoProgramCodeFixup();
    const u64 code_hash = setup.GetProgramCodeHash();
    const u64 swizzle_hash = setup.GetSwizzleDataHash();

    const u64 cache_key = Common::HashCombine(code_hash, swizzle_hash);
    auto iter = cache.find(cache_key);
    if (iter != cache.end()) {
        setup.cached_shader = iter->second.get();
    } else {
        auto shader = std::make_unique<JitShader>();
#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
        try {
            shader->Compile(&setup.GetProgramCode(), &setup.GetSwizzleData(), code_pool.get());
            if (cache.empty()) {
                LibRetro::DisplayMessage("SUPER27 native ARM64 vertex shader compiled");
            }
        } catch (const std::bad_alloc&) {
            // Remember this failed program; use the interpreter instead of retrying a BRK each draw.
            shader.reset();
            LibRetro::DisplayMessage("SUPER27 shader allocation failed; using shader interpreter");
        }
#else
        shader->Compile(&setup.GetProgramCode(), &setup.GetSwizzleData());
#endif
        setup.cached_shader = shader.get();
        cache.emplace_hint(iter, cache_key, std::move(shader));
    }
}

MICROPROFILE_DECLARE(GPU_Shader);

void JitEngine::Run(const ShaderSetup& setup, ShaderUnit& state) const {
#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
    if (!setup.cached_shader) {
        InterpreterEngine{}.Run(setup, state);
        return;
    }
#endif
    ASSERT(setup.cached_shader != nullptr);

    MICROPROFILE_SCOPE(GPU_Shader);

    const JitShader* shader = static_cast<const JitShader*>(setup.cached_shader);
    shader->Run(setup, state, setup.entry_point);
}

} // namespace Pica::Shader

#endif // CITRA_ARCH(x86_64) || CITRA_ARCH(arm64)
