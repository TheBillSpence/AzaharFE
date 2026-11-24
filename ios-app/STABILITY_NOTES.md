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
