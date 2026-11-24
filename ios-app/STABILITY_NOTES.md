# AzaharFE 1.0.1 stability notes

Based on the successful 1.0.0 / build 62 source, not a replacement of the original JIT implementation.

- iOS lifecycle: the application resign-active and interruption events pause guest execution at scheduler boundaries and clear input. Audio queues are stopped/recreated by the worker rather than disposed on UIKit. Stop requests are asynchronous; the dynamic-library halt bridge is protected by its original mutex.
- Audio: use the libretro-reported sample rate and FPS, bounded FIFO, prebuffer and underrun fade. Slow emulation still cannot generate full-speed audio; diagnose rather than masking severe CPU/GPU bottlenecks.
- Vulkan: the upstream disk resource loader already loads per-title pipeline/shader caches. Game Prep now exposes its real cache setting and the core emits progress during cache initialization. Async shader compilation is optional, disabled by default due to potential missing draws. New guest shaders must be encountered in gameplay before their cache can be warmed.
- CPU JIT: automatic mode uses Fast dispatch rather than experimental direct guest RAM. Turbo/direct remain explicit per-game choices. Do not remove the compiled host exclusive-monitor fix or enable unsafe monitor bypasses.
- Presentation: original graphite, color-coded ABXY diamond, directional cross, circle pad and ZL/ZR buttons, with distinct pressed states. Existing touchscreen mapping and external controllers stay intact.
- CI: audio-buffer regression tests, preset/cache assertions, and packaged icon/name checks. IPA build success is not equivalent to on-device stability.

## References
- Apple: https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
- Azahar: https://github.com/azahar-emu/azahar/discussions/1942
- PPSSPP shader compilation analysis: https://github.com/hrydgard/ppsspp/blob/master/docs/shader-compilation.md
- Libretro Azahar options: https://docs.libretro.com/library/azahar/

## On-device acceptance tests
Use the same ROM and scene at native 1x with profiling off. Test interpreter and Fast dispatch, then Vulkan if desired. Capture 60 seconds of FPS/core run/readback diagnostics. Play until audio is audible, suspend/resume five times, open/close Settings, switch audio route, stop/relaunch, and verify save persistence. Compare first Vulkan launch with second launch and shader progress. Check all touch controls, held simultaneous buttons and controller pairing. Do not publish 1.0.1 as stable until these are verified.

## Hyper JIT experiment (unreleased)
Automatic preset on ios-jit-experiment now uses Hyper: skips obsolete startup probes, direct page-table accesses (with page-crossing fallback), 64 MiB code cache per JIT, 65,536 startup ticks and the actual scheduler deadline after accepted video. Hyper + relaxed FP enables only three Dynarmic approximate FP flags. Cycle counting and global exclusive monitor stay enabled. Compare against Fast and Direct RAM at identical graphics settings. Cache allocation can increase memory pressure and longer runs can increase stop latency. Back up saves; not a release candidate.

## 128 MiB + guarded true fastmem
The automatic experimental preset now requests 128 MiB per Hyper/fastmem JIT and uses a real 4 GiB virtual guest window on iOS. The same RAM is aliased with vm_remap, not copied. A scratch RAM probe verifies writes through both aliases before enabling the arena. Only complete aligned contiguous 16 KiB host groups are marked valid. Native ARM64 loads/stores use base+guest address; explicit guards route unmapped, rasterizer-cached, watchpoint and crossing accesses to existing callbacks. Exclusive accesses keep the compiled host monitor. This avoids intentional debugger-intercepted access faults, unlike unchecked fault-driven fastmem. Mapping failures use callbacks; reservation failure or unpatched Dynarmic uses the regular page table. First coverage is recorded in the diagnostic log. Actual alias coverage and speed depend on device mappings. New ARM64 harness checks emitted load/store/guard behavior; physical iOS remap and TXM 128 MiB allocation still require device testing. Back up saves.

## Build 69 device freeze: retain first-run diagnostics
The iPhone reported successful 128 MiB allocations and 389 mapped host groups (6224 KiB), then stalled after first code fetch at 0x00100000 with no completed scheduler slice. This does not identify the root cause. Hyper and Fastmem now run the previous 512 single-step probes, staged Run budgets and targeted startup probes before the full deadline policy. Null page-table JITs reserve only 16 MiB, while game address spaces retain 128 MiB. Initial translation opcode and STREX callback traces provide more precise device evidence. The guarded fastmem emitter and compiled exclusive monitor are unchanged; actual gameplay must be retested.
