// Copyright 2023-2025 Citra Emulator Project / Azahar Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include "common/color.h"
#ifdef IOS
#include "citra_libretro/ios_perf_profile.h"
#endif
#include "core/core.h"
#include "video_core/gpu.h"
#include "video_core/pica/pica_core.h"
#include "video_core/renderer_software/renderer_software.h"

namespace SwRenderer {
namespace {
constexpr std::size_t MirroredPixel(std::size_t x, std::size_t y, std::size_t stride) {
    return y * stride + (stride - 1 - x);
}
static_assert(MirroredPixel(0, 0, 3) == 2 && MirroredPixel(2, 0, 3) == 0);
static_assert(MirroredPixel(0, 1, 3) == 5 && MirroredPixel(2, 1, 3) == 3);
} // namespace

RendererSoftware::RendererSoftware(Core::System& system, Pica::PicaCore& pica_,
                                   Frontend::EmuWindow& window)
    : VideoCore::RendererBase{system, window, nullptr}, memory{system.Memory()}, pica{pica_},
      rasterizer{memory, pica} {}

RendererSoftware::~RendererSoftware() = default;

void RendererSoftware::SwapBuffers() {
    system.perf_stats->StartSwap();
    PrepareRenderTarget();
    system.perf_stats->EndSwap();
    EndFrame();
}

void RendererSoftware::PrepareRenderTarget() {
#ifdef IOS
    AzaharProfile::Scope decode_profile{AzaharProfile::Section::ScreenDecode};
#endif
    const auto& regs_lcd = pica.regs_lcd;
#ifdef IOS
    // Both top-eye buffers currently use the same PICA framebuffer and
    // top color fill. Decode once, copy pixels for the second eye, and
    // preserve independent storage for the existing layout consumers.
    LoadFBToScreenInfo(0, regs_lcd.color_fill_top);
    screen_infos[1] = screen_infos[0];
    LoadFBToScreenInfo(2, regs_lcd.color_fill_bottom);
#else
    for (u32 i = 0; i < 3; i++) {
        const u32 fb_id = i == 2 ? 1 : 0;

        const auto color_fill = fb_id == 0 ? regs_lcd.color_fill_top : regs_lcd.color_fill_bottom;
        LoadFBToScreenInfo(i, color_fill);
    }
#endif
}

void RendererSoftware::LoadFBToScreenInfo(int i, const Pica::ColorFill& color_fill) {
    const u32 fb_id = i == 2 ? 1 : 0;
    const auto& framebuffer = pica.regs.framebuffer_config[fb_id];
    auto& info = screen_infos[i];

    const PAddr framebuffer_addr =
        framebuffer.active_fb == 0 ? framebuffer.address_left1 : framebuffer.address_left2;
    const s32 bpp = Pica::BytesPerPixel(framebuffer.color_format);
    const u8* framebuffer_data = memory.GetPhysicalPointer(framebuffer_addr);

    const s32 pixel_stride = framebuffer.stride / bpp;
    info.height = framebuffer.height;
    info.width = pixel_stride;
    info.pixels.resize(info.width * info.height * 4);

    for (u32 y = 0; y < info.height; y++) {
        for (u32 x = 0; x < info.width; x++) {
            Common::Vec4 color = [&] {
                if (color_fill.is_enabled) {
                    return Common::Vec4<u8>(color_fill.color_r, color_fill.color_g,
                                            color_fill.color_b, 255);
                }

                const u8* pixel = framebuffer_data + MirroredPixel(x, y, pixel_stride) * bpp;
                switch (framebuffer.color_format) {
                case Pica::PixelFormat::RGBA8:
                    return Common::Color::DecodeRGBA8(pixel);
                case Pica::PixelFormat::RGB8:
                    return Common::Color::DecodeRGB8(pixel);
                case Pica::PixelFormat::RGB565:
                    return Common::Color::DecodeRGB565(pixel);
                case Pica::PixelFormat::RGB5A1:
                    return Common::Color::DecodeRGB5A1(pixel);
                case Pica::PixelFormat::RGBA4:
                    return Common::Color::DecodeRGBA4(pixel);
                }
                UNREACHABLE();
            }();
            const u32 output_offset = (x * info.height + y) * 4;
            u8* dest = info.pixels.data() + output_offset;
            std::memcpy(dest, color.AsArray(), sizeof(color));
        }
    }
}

} // namespace SwRenderer
