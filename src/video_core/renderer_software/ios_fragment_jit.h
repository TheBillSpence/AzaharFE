// Copyright 2026 AzaharFE contributors
// Licensed under GPLv2 or any later version.
#pragma once

#if defined(IOS) && defined(AZAHAR_SUPER_EXPERIMENTAL) && defined(__aarch64__)
#include <algorithm>
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
#include "video_core/renderer_software/sw_texturing.h"
#include "video_core/shader/ios_shader_code_pool.h"

namespace SwRenderer {

// Compile all defined TEV operations into immutable native ARM64 leaf routines.
// Texture sampling, lighting, fog, depth/stencil and blending remain outside TEV.
// Constants and the initial combiner buffer are dynamic, so changing uniform
// colors does not force recompilation.
class IOSFragmentJit {
public:
    using Stage = Pica::TexturingRegs::TevStageConfig;
    using Source = Stage::Source;
    using Operation = Stage::Operation;
    using Color = Common::Vec4<u8>;
    using Inputs = std::array<u32, 7>;
    using Uniforms = std::array<u32, 7>;
    using Function = u32 (*)(const u32*, const u32*);
    struct Program {
        std::shared_ptr<oaknut::CodeBlock> block;
        Function run = nullptr;
    };

    const Program* Get(std::span<const Stage, 6> stages, u32 masks) {
        masks &= 0xff;
        std::array<u32, 25> key{};
        key[24] = masks;
        for (std::size_t i = 0; i < stages.size(); ++i) {
            key[i * 4] = stages[i].sources_raw;
            key[i * 4 + 1] = stages[i].modifiers_raw;
            key[i * 4 + 2] = stages[i].ops_raw;
            key[i * 4 + 3] = stages[i].scales_raw;
        }
        if (const auto it = cache.find(key); it != cache.end()) {
            return it->second.run ? &it->second : nullptr;
        }
        if (cache.size() >= 1024) {
            return nullptr;
        }
        Program program;
        try {
            program = Compile(stages, masks);
        } catch (const std::bad_alloc&) {
            LibRetro::DisplayMessage("SUPER27 fragment code allocation failed; using reference");
        }
        const auto it = cache.emplace(key, std::move(program)).first;
        return it->second.run ? &it->second : nullptr;
    }

    static Color Run(const Program& program, const Color& primary, const Color& lighting,
                     const Color& secondary, const std::array<Color, 4>& textures,
                     const Uniforms& uniforms) {
        const Inputs inputs{Pack(primary),     Pack(lighting),    Pack(secondary),
                            Pack(textures[0]), Pack(textures[1]), Pack(textures[2]),
                            Pack(textures[3])};
        return Unpack(program.run(inputs.data(), uniforms.data()));
    }

    static u32 Pack(const Color& c) {
        return u32(c.r()) | (u32(c.g()) << 8) | (u32(c.b()) << 16) | (u32(c.a()) << 24);
    }

private:
    static Color Unpack(u32 color) {
        return {static_cast<u8>(color), static_cast<u8>(color >> 8), static_cast<u8>(color >> 16),
                static_cast<u8>(color >> 24)};
    }

    static Source ColorSource(const Stage& s, std::size_t stage, unsigned input) {
        if (input == 2) {
            return s.color_source3.Value();
        }
        const auto src = input == 0 ? s.color_source1.Value() : s.color_source2.Value();
        return stage == 0 && src == Source::Previous ? s.color_source3.Value() : src;
    }

    static Source AlphaSource(const Stage& s, unsigned input) {
        return input == 0   ? s.alpha_source1.Value()
               : input == 1 ? s.alpha_source2.Value()
                            : s.alpha_source3.Value();
    }

    static Stage::ColorModifier ColorModifier(const Stage& s, unsigned input) {
        return input == 0   ? s.color_modifier1.Value()
               : input == 1 ? s.color_modifier2.Value()
                            : s.color_modifier3.Value();
    }

    static Stage::AlphaModifier AlphaModifier(const Stage& s, unsigned input) {
        return input == 0   ? s.alpha_modifier1.Value()
               : input == 1 ? s.alpha_modifier2.Value()
                            : s.alpha_modifier3.Value();
    }

    static bool ValidSource(Source src) {
        return static_cast<u32>(src) <= 6 || src == Source::PreviousBuffer ||
               src == Source::Constant || src == Source::Previous;
    }

    static bool ValidStage(const Stage& s, std::size_t stage) {
        const auto color = static_cast<u32>(s.color_op.Value());
        const auto alpha = static_cast<u32>(s.alpha_op.Value());
        if (color > 9 || (color != 7 && (alpha > 9 || alpha == 6 || alpha == 7))) {
            return false;
        }
        for (unsigned i = 0; i < 3; ++i) {
            const auto mod = static_cast<u32>(ColorModifier(s, i));
            if (!ValidSource(ColorSource(s, stage, i)) ||
                !(mod <= 5 || mod == 8 || mod == 9 || mod == 12 || mod == 13)) {
                return false;
            }
            if (color != 7 && !ValidSource(AlphaSource(s, i))) {
                return false;
            }
        }
        return true;
    }

    static unsigned Arity(Operation op) {
        switch (op) {
        case Operation::Replace:
            return 1;
        case Operation::Lerp:
        case Operation::MultiplyThenAdd:
        case Operation::AddThenMultiply:
            return 3;
        default:
            return 2;
        }
    }

    // Independent reference using the existing renderer's arithmetic, modifiers
    // and one-stage-delayed combiner-buffer update order.
    static u32 Reference(std::span<const Stage, 6> stages, u32 masks, const Inputs& inputs,
                         const Uniforms& uniforms) {
        Color previous{}, buffer{}, next = Unpack(uniforms[6]);
        for (std::size_t i = 0; i < stages.size(); ++i) {
            const auto& s = stages[i];
            const auto source = [&](Source src) -> Color {
                switch (src) {
                case Source::Previous:
                    return previous;
                case Source::PreviousBuffer:
                    return buffer;
                case Source::Constant:
                    return Unpack(uniforms[i]);
                default:
                    return Unpack(inputs[static_cast<u32>(src)]);
                }
            };
            std::array<Common::Vec3<u8>, 3> rgb{};
            for (unsigned j = 0; j < Arity(s.color_op.Value()); ++j) {
                rgb[j] = GetColorModifier(ColorModifier(s, j), source(ColorSource(s, i, j)));
            }
            const auto color = ColorCombine(s.color_op, rgb);
            u8 alpha = color.x;
            if (s.color_op != Operation::Dot3_RGBA) {
                std::array<u8, 3> a{};
                for (unsigned j = 0; j < Arity(s.alpha_op.Value()); ++j) {
                    a[j] = GetAlphaModifier(AlphaModifier(s, j), source(AlphaSource(s, j)));
                }
                alpha = AlphaCombine(s.alpha_op, a);
            }
            previous = {static_cast<u8>(std::min(255U, color.r() * s.GetColorMultiplier())),
                        static_cast<u8>(std::min(255U, color.g() * s.GetColorMultiplier())),
                        static_cast<u8>(std::min(255U, color.b() * s.GetColorMultiplier())),
                        static_cast<u8>(std::min(255U, alpha * s.GetAlphaMultiplier()))};
            buffer = next;
            if (i < 4 && (masks & (1U << i))) {
                next.r() = previous.r();
                next.g() = previous.g();
                next.b() = previous.b();
            }
            if (i < 4 && (masks & (16U << i))) {
                next.a() = previous.a();
            }
        }
        return Pack(previous);
    }

    Program Compile(std::span<const Stage, 6> stages, u32 masks) {
        using namespace oaknut;
        using namespace oaknut::util;
        for (std::size_t i = 0; i < stages.size(); ++i) {
            if (!ValidStage(stages[i], i)) {
                return {};
            }
        }
        std::vector<u32> code;
        VectorCodeGenerator out(code);
        // X0/X1: dynamic inputs/uniforms. W2: previous, W3: buffer,
        // W4: next buffer, W5: output, W6/W7/W8: operands, W9: scratch,
        // W10: 255, W11: 256, W12: unscaled dot3. Only caller-saved
        // registers are used; no platform-reserved X18 or host callbacks.
        out.MOV(W2, WZR);
        out.MOV(W3, WZR);
        out.LDR(W4, X1, 24);
        out.MOV(W10, 255);
        out.MOV(W11, 256);
        const auto clamp = [&](WReg reg) {
            out.CMP(reg, 0);
            out.CSEL(reg, WZR, reg, Cond::LT);
            out.CMP(reg, W10);
            out.CSEL(reg, W10, reg, Cond::GT);
        };
        const auto load = [&](WReg dst, Source src, std::size_t stage) {
            switch (src) {
            case Source::Previous:
                out.MOV(dst, W2);
                break;
            case Source::PreviousBuffer:
                out.MOV(dst, W3);
                break;
            case Source::Constant:
                out.LDR(dst, X1, static_cast<u32>(stage * 4));
                break;
            default:
                out.LDR(dst, X0, static_cast<u32>(src) * 4);
                break;
            }
        };
        const auto operand = [&](WReg dst, const Stage& s, std::size_t stage, unsigned input,
                                 unsigned channel) {
            const bool alpha = channel == 3;
            const auto src = alpha ? AlphaSource(s, input) : ColorSource(s, stage, input);
            const auto modifier = alpha ? static_cast<u32>(AlphaModifier(s, input))
                                        : static_cast<u32>(ColorModifier(s, input));
            unsigned component = channel;
            if (alpha) {
                constexpr std::array<unsigned, 4> swizzle{3, 0, 1, 2};
                component = swizzle[modifier / 2];
            } else {
                switch (modifier & ~1U) {
                case 2:
                    component = 3;
                    break;
                case 4:
                    component = 0;
                    break;
                case 8:
                    component = 1;
                    break;
                case 12:
                    component = 2;
                    break;
                default:
                    break;
                }
            }
            load(dst, src, stage);
            out.UBFX(dst, dst, component * 8, 8);
            if (modifier & 1) {
                out.SUB(dst, W10, dst);
            }
        };
        const auto combine = [&](Operation op) {
            switch (op) {
            case Operation::Replace:
                break;
            case Operation::Modulate:
                out.MUL(W6, W6, W7);
                out.UDIV(W6, W6, W10);
                break;
            case Operation::Add:
                out.ADD(W6, W6, W7);
                clamp(W6);
                break;
            case Operation::AddSigned:
                out.ADD(W6, W6, W7);
                out.SUB(W6, W6, 128);
                clamp(W6);
                break;
            case Operation::Lerp:
                out.MUL(W6, W6, W8);
                out.SUB(W9, W10, W8);
                out.MUL(W7, W7, W9);
                out.ADD(W6, W6, W7);
                out.UDIV(W6, W6, W10);
                break;
            case Operation::Subtract:
                out.SUB(W6, W6, W7);
                clamp(W6);
                break;
            case Operation::MultiplyThenAdd:
                out.MUL(W6, W6, W7);
                out.MUL(W8, W8, W10);
                out.ADD(W6, W6, W8);
                out.UDIV(W6, W6, W10);
                clamp(W6);
                break;
            case Operation::AddThenMultiply:
                out.ADD(W6, W6, W7);
                clamp(W6);
                out.MUL(W6, W6, W8);
                out.UDIV(W6, W6, W10);
                break;
            default:
                break; // dot3 emitted separately
            }
        };
        for (std::size_t i = 0; i < stages.size(); ++i) {
            const auto& s = stages[i];
            const auto color_op = s.color_op.Value();
            const bool dot = color_op == Operation::Dot3_RGB || color_op == Operation::Dot3_RGBA;
            const bool pass_through =
                i != 0 && color_op == Operation::Replace && s.alpha_op == Operation::Replace &&
                s.color_source1 == Source::Previous && s.alpha_source1 == Source::Previous &&
                s.color_modifier1 == Stage::ColorModifier::SourceColor &&
                s.alpha_modifier1 == Stage::AlphaModifier::SourceAlpha &&
                s.GetColorMultiplier() == 1 && s.GetAlphaMultiplier() == 1;
            if (!pass_through) {
                if (dot) {
                    out.MOV(W12, WZR);
                    for (unsigned channel = 0; channel < 3; ++channel) {
                        operand(W6, s, i, 0, channel);
                        operand(W7, s, i, 1, channel);
                        out.LSL(W6, W6, 1);
                        out.LSL(W7, W7, 1);
                        out.SUB(W6, W6, W10);
                        out.SUB(W7, W7, W10);
                        out.MUL(W6, W6, W7);
                        out.ADD(W6, W6, 128);
                        // Signed divide truncates toward zero, matching the reference.
                        out.SDIV(W6, W6, W11);
                        out.ADD(W12, W12, W6);
                    }
                    clamp(W12);
                }
                out.MOV(W5, WZR);
                for (unsigned channel = 0; channel < 4; ++channel) {
                    const bool alpha = channel == 3;
                    if (dot && (!alpha || color_op == Operation::Dot3_RGBA)) {
                        out.MOV(W6, W12);
                    } else {
                        const auto op = alpha ? s.alpha_op.Value() : color_op;
                        operand(W6, s, i, 0, channel);
                        if (Arity(op) >= 2) {
                            operand(W7, s, i, 1, channel);
                        }
                        if (Arity(op) == 3) {
                            operand(W8, s, i, 2, channel);
                        }
                        combine(op);
                    }
                    const auto scale = alpha ? s.GetAlphaMultiplier() : s.GetColorMultiplier();
                    if (scale != 1) {
                        out.LSL(W6, W6, scale == 2 ? 1 : 2);
                        clamp(W6);
                    }
                    if (channel) {
                        out.LSL(W6, W6, channel * 8);
                    }
                    out.ORR(W5, W5, W6);
                }
                out.MOV(W2, W5);
            }
            // Both channels must observe the previous stage, not each other.
            out.MOV(W3, W4);
            const bool rgb_update = i < 4 && (masks & (1U << i));
            const bool alpha_update = i < 4 && (masks & (16U << i));
            if (rgb_update && alpha_update) {
                out.MOV(W4, W2);
            } else if (rgb_update) {
                out.AND(W4, W4, 0xff000000U);
                out.AND(W9, W2, 0x00ffffffU);
                out.ORR(W4, W4, W9);
            } else if (alpha_update) {
                out.AND(W4, W4, 0x00ffffffU);
                out.AND(W9, W2, 0xff000000U);
                out.ORR(W4, W4, W9);
            }
        }
        out.MOV(W0, W2);
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
        // Validate every program against the reference before publishing it to
        // raster workers. Vary both inputs and uniform colors independently.
        u32 seed = 0x27c0ffeeU;
        const auto random = [&] {
            seed ^= seed << 13;
            seed ^= seed >> 17;
            seed ^= seed << 5;
            return seed;
        };
        for (unsigned sample = 0; sample < 32; ++sample) {
            Inputs inputs{};
            Uniforms uniforms{};
            for (auto& input : inputs) {
                input = sample == 0 ? 0 : sample == 1 ? 0xffffffffU : random();
            }
            for (auto& uniform : uniforms) {
                uniform = sample == 0 ? 0xffffffffU : sample == 1 ? 0 : random();
            }
            if (result.run(inputs.data(), uniforms.data()) !=
                Reference(stages, masks, inputs, uniforms)) {
                LibRetro::DisplayMessage("SUPER27 full TEV validation mismatch; using reference");
                return {};
            }
        }
        if (!reported_native) {
            reported_native = true;
            LibRetro::DisplayMessage("SUPER27 full TEV native program passed 32 reference tests");
        }
        return result;
    }

    bool reported_native = false;
    Pica::Shader::IOSShaderCodePool pool;
    std::map<std::array<u32, 25>, Program> cache;
};

} // namespace SwRenderer
#endif
