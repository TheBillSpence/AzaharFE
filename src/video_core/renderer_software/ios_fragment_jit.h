// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#pragma once

#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
#include <array>
#include <cstring>
#include <map>
#include <memory>
#include <new>
#include <span>
#include <vector>
#include <oaknut/oaknut.hpp>
#include "common/common_types.h"
#include "common/vector_math.h"
#include "video_core/pica/regs_texturing.h"
#include "video_core/shader/ios_shader_code_pool.h"

namespace SwRenderer {

// A deliberately narrow native fragment compiler: identity RGBA Replace and
// Modulate stages with matching RGB/alpha sources, scale one, no buffer reads.
// Unsupported states use the complete existing software combiner.
class IOSFragmentJit {
public:
    using Stage = Pica::TexturingRegs::TevStageConfig;
    using Color = Common::Vec4<u8>;
    using Function = u32 (*)(const u32*);
    struct Program {
        std::shared_ptr<oaknut::CodeBlock> block;
        Function run = nullptr;
    };

    const Program* Get(std::span<const Stage, 6> stages) {
        std::array<u32, 24> key{};
        for (std::size_t i = 0; i < stages.size(); ++i) {
            key[i * 4] = stages[i].sources_raw;
            key[i * 4 + 1] = stages[i].modifiers_raw;
            key[i * 4 + 2] = stages[i].ops_raw;
            key[i * 4 + 3] = stages[i].scales_raw;
        }
        if (const auto it = cache.find(key); it != cache.end()) {
            return it->second.run ? &it->second : nullptr;
        }
        if (cache.size() >= 256) {
            return nullptr;
        }
        Program program;
        try {
            program = Compile(stages);
        } catch (const std::bad_alloc&) {
            // Negative-cache failures to avoid repeated debugger allocations.
        }
        const auto it = cache.emplace(key, std::move(program)).first;
        return it->second.run ? &it->second : nullptr;
    }

    static Color Run(const Program& program, const Color& primary, const Color& lighting,
                     const Color& secondary, const std::array<Color, 4>& textures) {
        const auto pack = [](const Color& c) {
            return u32(c.r()) | (u32(c.g()) << 8) | (u32(c.b()) << 16) | (u32(c.a()) << 24);
        };
        const std::array<u32, 7> inputs{pack(primary), pack(lighting), pack(secondary),
                                        pack(textures[0]), pack(textures[1]), pack(textures[2]),
                                        pack(textures[3])};
        const auto color = program.run(inputs.data());
        return {static_cast<u8>(color), static_cast<u8>(color >> 8),
                static_cast<u8>(color >> 16), static_cast<u8>(color >> 24)};
    }

private:
    Program Compile(std::span<const Stage, 6> stages) {
        using namespace oaknut;
        using Source = Stage::Source;
        using Operation = Stage::Operation;
        using CM = Stage::ColorModifier;
        using AM = Stage::AlphaModifier;
        std::vector<u32> code;
        VectorCodeGenerator out(code);
        // X0 = input pointer, W1 = previous output, W2/W3 = source colors,
        // W4/W5 = temporary channel, W6 = 255, W7 = packed result.
        out.MOV(W1, 0);
        out.MOV(W6, 255);
        for (std::size_t i = 0; i < stages.size(); ++i) {
            const auto& s = stages[i];
            const auto op = s.color_op.Value();
            const auto color1 = i == 0 && s.color_source1 == Source::Previous
                                    ? s.color_source3.Value()
                                    : s.color_source1.Value();
            const auto color2 = i == 0 && s.color_source2 == Source::Previous
                                    ? s.color_source3.Value()
                                    : s.color_source2.Value();
            if ((op != Operation::Replace && op != Operation::Modulate) ||
                s.alpha_op.Value() != op || s.GetColorMultiplier() != 1 ||
                s.GetAlphaMultiplier() != 1 || s.color_modifier1 != CM::SourceColor ||
                s.alpha_modifier1 != AM::SourceAlpha || color1 != s.alpha_source1.Value()) {
                return {};
            }
            const auto valid = [](Source src) {
                return static_cast<u32>(src) <= 6 || src == Source::Previous;
            };
            if (!valid(color1)) {
                return {};
            }
            const auto load = [&](WReg dst, Source src) {
                if (src == Source::Previous) {
                    out.MOV(dst, W1);
                } else {
                    out.LDR(dst, X0, static_cast<u32>(src) * 4);
                }
            };
            if (op == Operation::Replace) {
                if (color1 != Source::Previous) {
                    load(W1, color1);
                }
                continue;
            }
            if (!valid(color2) || color2 != s.alpha_source2.Value() ||
                s.color_modifier2 != CM::SourceColor || s.alpha_modifier2 != AM::SourceAlpha) {
                return {};
            }
            load(W2, color1);
            load(W3, color2);
            out.MOV(W7, 0);
            for (unsigned channel = 0; channel < 4; ++channel) {
                const unsigned shift = channel * 8;
                out.UBFX(W4, W2, shift, 8);
                out.UBFX(W5, W3, shift, 8);
                out.MUL(W4, W4, W5);
                out.UDIV(W4, W4, W6);
                if (shift) {
                    out.LSL(W4, W4, shift);
                }
                out.ORR(W7, W7, W4);
            }
            out.MOV(W1, W7);
        }
        out.MOV(W0, W1);
        out.RET();
        const auto bytes = code.size() * sizeof(u32);
        auto slice = pool.Allocate(bytes);
        auto* rx = reinterpret_cast<std::byte*>(slice.block->ptr()) + slice.offset;
        auto* rw = reinterpret_cast<std::byte*>(slice.block->wptr()) + slice.offset;
        slice.block->unprotect();
        std::memcpy(rw, code.data(), bytes);
        slice.block->protect();
        slice.block->invalidate(reinterpret_cast<u32*>(rx), bytes);
        Program result{std::move(slice.block), reinterpret_cast<Function>(rx)};
        // Verify generated code before any raster worker can see it. This
        // checks arithmetic/ABI for the supported subset, not full rendering.
        for (u32 sample = 0; sample < 8; ++sample) {
            std::array<u32, 7> inputs{};
            for (u32 i = 0; i < inputs.size(); ++i) {
                inputs[i] = (sample * 0x9e3779b9U) ^ (i * 0x6f31915bU);
            }
            u32 previous = 0;
            for (std::size_t i = 0; i < stages.size(); ++i) {
                const auto& s = stages[i];
                const auto src = [&](Source source) -> u32 {
                    return source == Source::Previous ? previous : inputs[static_cast<u32>(source)];
                };
                const auto source1 = i == 0 && s.color_source1 == Source::Previous
                                         ? s.color_source3.Value()
                                         : s.color_source1.Value();
                const auto source2 = i == 0 && s.color_source2 == Source::Previous
                                         ? s.color_source3.Value()
                                         : s.color_source2.Value();
                const u32 a = src(source1);
                if (s.color_op == Operation::Replace) {
                    previous = a;
                } else {
                    const u32 b = src(source2);
                    u32 output = 0;
                    for (u32 shift = 0; shift < 32; shift += 8) {
                        output |= ((((a >> shift) & 255) * ((b >> shift) & 255)) / 255) << shift;
                    }
                    previous = output;
                }
            }
            if (result.run(inputs.data()) != previous) {
                LibRetro::DisplayMessage("SUPER27 fragment validation mismatch; using reference");
                return {};
            }
        }
        if (!reported_native) {
            reported_native = true;
            LibRetro::DisplayMessage("SUPER27 native fragment program passed arithmetic self-test");
        }
        return result;
    }

    bool reported_native = false;
    Pica::Shader::IOSShaderCodePool pool;
    std::map<std::array<u32, 24>, Program> cache;
};

} // namespace SwRenderer
#endif
