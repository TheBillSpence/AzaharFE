# AzaharFE — error, failure and AI handoff log

**Snapshot:** 2026-11-24, through iOS IPA workflow build #76 (in progress at last check).  
**Repository:** https://github.com/TheBillSpence/AzaharFE  
**Active branch:** `ios-jit-experiment`  
**Snapshot commit:** `18be4895d6708254974ed108c9c6cb4c26e6cc71`  
**Purpose:** Continue development without repeating failed experiments, losing evidence, or confusing CI success with physical-device success.

## 1. Read this first

- Target: iPhone 11 Pro Max, A13, iOS 27.2.1 (user-reported). StikDebug JIT, universal.js, LiveContainer/LocalDevVPN in the original setup. Verify the actual current launch method before testing.
- Test game: decrypted Ocarina of Time 3D, title ID `0004000000033500`. Interpreter (JIT OFF) boots, so the original failure was not evidence of a bad ROM.
- Architecture: native iOS Objective-C/Objective-C++ frontend → libretro core → Dynarmic ARM32-to-ARM64 JIT; software PICA renderer or experimental Vulkan/MoltenVK; audio and UIKit presentation. Do not transplant a PS2 MIPS recompiler.
- Keep `master` unchanged. All experimental changes go to `ios-jit-experiment` unless the maintainer explicitly decides otherwise. Preserve saves and the established compatibility paths.
- Do not equate successful executable-memory preparation, Linux ARM64 harness, Linux Vulkan test, IPA compilation, first frame, and stable gameplay. Each is a different acceptance gate.
- **Current work:** validate #76, then isolate any device freezes with exact traces. Do not blindly increase cache size, remove startup probes, or bypass the exclusive monitor.
- This is a reconstructed log of the accessible repository history, selected CI logs, and recalled device-test records. It is not a complete dump of every historical build log. Unknown causes and missing runs are explicitly marked.

### Evidence terminology

**Device-confirmed** = reported phone test; **CI-confirmed** = retrieved workflow result/log; **source fix** = implemented but not necessarily validated on device; **hypothesis** = requires reproduction; **cancelled** = not a failed test by itself.

## 2. Latest state (build #76)

- [IPA #76](https://github.com/TheBillSpence/AzaharFE/actions/runs/45447160822): in progress at snapshot. #75 was cancelled; #74 failed at export verification. No #76 phone test yet.
- [Export fix 466aea7](https://github.com/TheBillSpence/AzaharFE/commit/466aea7d680948ae00ac7208914321fff1e4bb50): added `_azahar_ios_vk_readback_failed` and `_azahar_ios_vk_drain_readback` to the iOS generated Mach-O export allowlist in `src/citra_libretro/CMakeLists.txt`. Both functions already existed in the bridge and header. Kept all seven required Vulkan exports and JIT halt export.
- [Formatting fix 18be489](https://github.com/TheBillSpence/AzaharFE/commit/18be4895d6708254974ed108c9c6cb4c26e6cc71): applied all 13 exact clang-format 19.1.7 diff hunks from CI across five files. Verified non-whitespace character sequence unchanged. No intended behavior change.
- [MoltenVK fast compile #12](https://github.com/TheBillSpence/AzaharFE/actions/runs/45446903418): success on export-fix commit, but Linux does not test Mach-O exports. [#13](https://github.com/TheBillSpence/AzaharFE/actions/runs/45447160401) queued at snapshot.
- [ARM64 regression harness #23](https://github.com/TheBillSpence/AzaharFE/actions/runs/45447160609): in progress. [Formatting #106](https://github.com/TheBillSpence/AzaharFE/actions/runs/45447160423) queued. Upstream `citra-build`/`citra-libretro` also queued; not yet validated.
- Most recent CI-green IPA before #76: [#70](https://github.com/TheBillSpence/AzaharFE/actions/runs/45427828289). Earlier [#62](https://github.com/TheBillSpence/AzaharFE/actions/runs/45386051331) is the documented 1.0.0 source baseline. Green IPA is not proof of device stability.

## 3. Chronological device failures and attempted fixes

| ID | Build / period | Evidence / symptoms | Attempt and outcome | Status |
|---|---|---|---|---|
| D01 | Early iOS 27 | JIT ON black screen/unresponsive. Debugger attached but executable memory was not guaranteed by attachment alone on target OS. | Introduced StikDebug universal.js executable-memory protocol, RW/RX aliasing and 16 KiB executable preflight. | Native preflight later device-confirmed; game execution separate. |
| D02 | #14 | `ARM64 RX test returned 42 (expected 42)`; all five JIT caches created; stopped at `Dynarmic::Run entered`. | First-instruction `Step()` test and instruction-cache invalidation for both writable/executable aliases. | Native generated code worked; continuous dispatch still hung. |
| D03 | #16–18 | First JIT step and first `System::RunLoop` returned. 512 guest steps returned. PC repeatedly around `0x00100034..0x0010003c`; downcount decremented. First full Run stalled with 374845-cycle budget. | 512-step bounded startup diagnostic, core ID/PC/ticks traces; UI overlap fixed and build badge added. | Startup steps passed; original full-run problem remained. |
| D04 | #19 | Full Run still stalled even with BlockLinking, ReturnStackBuffer, FastDispatch disabled. | Conservative dispatcher and explicit cycle counting. | Failed as a standalone fix; don't assume block linking was root cause. |
| D05 | #20 | `GetTicksRemaining ... capped=64`, `AddTicks(65)`, first full Run returned. | 64-tick cap confirmed continuous generated execution and timer accounting. | Device-confirmed short-slice success; not playable-performance solution. |
| D06 | #21–25 | Staged full Run budgets 64, 256, 1024, 4096, 16384, 65536, 262144 (16 runs/stage). Run 79 and SVC 0x21/CreateAddressArbiter returned; run 80 at PC `0x0041A4AC` stalled. Both 3s and 10s checks showed 591 slices; no video. | Cooperative halt bridge/watchdog added. Halt request did not make frozen execution return. | Original freeze persisted; a request is not proof of delivery or interruption. |
| D07 | #26–28 | At run 80, targeted 1,024 guest Step probes: first 32 returned, step 32 ended at `0x003019D4`; no step-64 checkpoint, scheduler stopped at 626 slices. `frontend halt bridge unavailable (missing symbol)`. | Trace steps 33–64 individually; add iOS-only `_azahar_jit_request_halt` export; verify with `nm -gU`. | Missing symbol fixed in source; watchdog cannot forcibly interrupt arbitrary generated code. |
| D08 | Pre-#37 | Prior debugging record localizes original freeze to run-80 step 36, `LDREX`. | #37 replaced runtime-generated Dynarmic host lock helper with compiled ARM64 atomic operations; subsequent phone test completed 1,024 probes and delivered first frame. | Strong device evidence for original fix. Exact internal lock failure not independently traced; preserve compiled host exclusive monitor. |
| D09 | #37–51 | Software rendering slow; reported Fast Dispatch ~6 FPS vs interpreter ~5 FPS in one comparison (conditions incomplete). 1×–4× software output upscales pixels rather than adding actual 3D detail. | Reduced post-startup trace/scheduling overhead, Fast Dispatch mode, longer bounded slices, LTO; opt-in Turbo/Direct RAM, software framebuffer reuse, configurable worker count, detailed profiling. | Performance varies by mode/game/renderer; no universal speedup proven. |
| D10 | #45+ | Direct startup previously hung; page-table mode unverified at introduction. | Fast baseline retained 512-step/run-80 startup probes; Turbo and Direct RAM opt-in initially skip probes. Do not remove diagnostic safety path without reproducing device startup. | Some later experimental modes booted; not blanket validation. |
| D11 | #52–62 | Experimental MoltenVK renderer introduced; risk of initialization failure, readback ordering, shader/pipeline errors, misleading first-frame signals. | Offscreen Vulkan bridge, fallback to software for early failures, Linux readback test; later real frame checks and lifecycle improvements. | One retrieved device log confirms successful MoltenVK delivery and high FPS (see §4); all titles/configurations not validated. |
| D12 | #63–69 | Hyper JIT + guarded fastmem: 128 MiB per mapped JIT, 4 GiB virtual guest alias window. Build #69 log: 389 mapped host groups (6224 KiB); first code fetch `0x00100000`; zero scheduler slices; watchdog fired. | #70 restored 512 steps, staged budgets and targeted startup probes for Hyper/Fastmem, plus opcode/STREX traces; empty/null-table caches 16 MiB. | #69 phone freeze confirmed; #70 IPA CI green. |
| D13 | #70-era | Later device run completed 512 + 1,024 probes, STREX, syscalls and first software frame, then hung at optional CPU-only benchmark. No score produced on that run. | Removed synthetic benchmark from `retro_run` while retaining real-game profiling and native regression harness. | Source fix; newer #76 phone retest needed. |
| D14 | #70-era, subsequent launch | Stopped during fourth `Dynarmic::MakeJit allocating code cache` with 128 MiB allocation regime. | Primary mapped core remains 128 MiB; secondary mapped cores capped at 32 MiB, unmapped 16 MiB; log core, mapping, cache size and allocation latency. | Memory pressure plausible, not confirmed cause; retest. |
| D15 | #72 | Risk of changing settings while a session owns generated code; a stalled worker must not be unloaded/replaced. | Coalesce settings changes, stop asynchronously, restart only after acknowledged worker release, expose timeout/retry, pause via cooperative halt, audio mute/rebuffer instead of routine queue recreation. | Source fix; device validation needed. Unsaved progress not preserved by restart. |
| D16 | #73–76 | GPU fence waits could be infinite; pending copy ownership unsafe if destroyed prematurely. | Two-second readback fence timeout; failed copy leaves frame loop; drain pending copies on worker before teardown, never destroy resources still in use. | Source fix; if driver never returns, session may remain owned and force-close necessary. Vulkan device-idle/driver calls not guaranteed bounded. |
| D17 | #74–76 | Cover management scattered across UI and older storage paths. | Game Prep cover import/replace/remove, read both legacy and current art storage, remove standalone Covers tab; explicit controller types fix settings shell compilation. | Source change; #74 shell compiled successfully; UI/cover migration still needs phone test. |

### Original startup diagnostics (representative excerpts)

```text
1/7 Waiting for StikDebug debugger permission
2/7 Debugger found; requesting 16 KB JIT memory
2b/7 RW/RX mappings ready; writing ARM64 test
2c/7 Executing ARM64 test in RX memory
2d/7 ARM64 RX test returned 42 (expected 42)
3/7 JIT mapping prepared; initializing core
4/7 Calling retro_init
5/7 Core initialized; loading game
JIT27TRACE Dynarmic::MakeJit allocating code cache
JIT27TRACE Dynarmic::MakeJit returned
```

Do not infer first-frame success from these startup lines. Look for scheduler progress, actual video delivery, and subsequent gameplay. For hangs, export `Documents/AzaharJITDiagnostics.txt` / Log Data, preserving complete final traces and build number.

## 4. Benchmarks and performance evidence

- A prior retrieved device-log excerpt (build number not identified) reports `First MoltenVK image delivered` and a successful CPU-only direct JIT benchmark: **549.33 M guest ticks/s (3.818 ms, 2097152 ticks)**. Later reported emulated FPS: **62.3, 54.1, 62.3**; mean MoltenVK readback **1.85, 1.99, 2.38 ms**. These are individual observations, not a guaranteed average or apples-to-apples comparison with software. The exact mode/scene/thermal conditions were not all retrieved.
- Another run of the same class of synthetic benchmark stalled after first frame and printed no score. Do not confuse it with the successful earlier sample. The benchmark's finite ARM ADD/branch loop (~2.1M guest ticks) is not game FPS, GPU performance, or an interpreter speed ratio. It has been removed from live `retro_run` as a result of the later stall.
- `PERF27` timings are inclusive/overlapping. CPU includes JIT/SVC activity; worker CPU times may exceed elapsed wall time. Do not sum categories or turn them into exclusive percentages. Profiling changes performance; disable for controlled FPS comparisons.
- Use same ROM, scene, output scale (1×), renderer, temperature, and at least 60s of steady gameplay. Separate emulated FPS, presented FPS, core run time, GPU/readback time and audio underruns. Record startup latency and stop latency independently.

## 5. CI failure ledger — IPA workflow

Run links are direct GitHub evidence. Failures below are from retrieved workflow results and selected logs. Do not mistake text printed by a shell script for an actual executed error, or optional dependency detection failures for fatal errors.

| Build | Failed stage / error | Fix / status |
|---|---|---|
| [#8](https://github.com/TheBillSpence/AzaharFE/actions/runs/45030918213) | `iOS RW/RX dual mapping: expected 1 matching regions, found 2` | Narrow Oaknut patch selector, avoid matching OpenBSD mapping. |
| [#9](https://github.com/TheBillSpence/AzaharFE/actions/runs/45034855503) | Same selector, found 0 regions | Correct literal newline selector; #10 passed. |
| [#15](https://github.com/TheBillSpence/AzaharFE/actions/runs/45091411289) | `invalidate RW and RX aliases: expected 1 matching regions, found 0` | Correct Oaknut icache patch newline selector; #16 passed. |
| [#34](https://github.com/TheBillSpence/AzaharFE/actions/runs/45169486927), [#35](https://github.com/TheBillSpence/AzaharFE/actions/runs/45169522020) | Workflow marked failed; no failed job detail returned. | #36 switched experimental build to Intel macOS runner and passed; actual preceding cause not verified. |
| [#41](https://github.com/TheBillSpence/AzaharFE/actions/runs/45228077669), [#42](https://github.com/TheBillSpence/AzaharFE/actions/runs/45228231759) | `libretro_window.cpp:284,290,291: error: cannot jump from switch statement to this case label` | Scope the resolution factor inside switch case braces. #43 change cancelled; #45 passed. |
| [#52](https://github.com/TheBillSpence/AzaharFE/actions/runs/45262225454) | CMake `target_sources`: cannot find `ios_moltenvk_bridge.cpp` | Add actual bridge source; #53 compiled it, but linked failed. |
| [#53](https://github.com/TheBillSpence/AzaharFE/actions/runs/45262470769) | Undefined ARM64 symbols `_OBJC_CLASS_$_UIScreen`, `_OBJC_CLASS_$_UIView` in `libMoltenVK.a`; link failed | Link UIKit for MoltenVK on iOS. Later #58 passed. |
| [#54](https://github.com/TheBillSpence/AzaharFE/actions/runs/45262672964), [#57](https://github.com/TheBillSpence/AzaharFE/actions/runs/45263735435) | `AzaharEmulator.mm` ivar declaration errors (`expected ';' at end of declaration list`), Xcode exit 65. | #58 fixed ivar syntax, tvOS MoltenVK target and formatting; passed. |
| [#73](https://github.com/TheBillSpence/AzaharFE/actions/runs/45437854772) | Xcode `AzaharLibraryViewController.mm` compile failed, exit 65. Exact compiler diagnostic not recovered from excerpt. | #74 changed `typeof(self)` weak/strong variables to explicit `AzaharGameViewController *`; #74 passed shell stage. |
| [#74](https://github.com/TheBillSpence/AzaharFE/actions/runs/45440803303) | Core compiled; `Verify MoltenVK frontend bridge exports` failed: `MoltenVK interface export is missing: azahar_ios_vk_readback_failed` | Both `readback_failed` and `drain_readback` absent from iOS linker allowlist; commit `466aea7` fixed. #75 cancelled; #76 in progress. |

### Other CI failures and warnings

- `citra-format` #103 and #104 failed; #104 log showed exact whitespace differences in `ios_moltenvk_bridge.cpp` (1), `citra_libretro.cpp` (1), `ios_jit_optimizations.h` (1), `ios_fastmem_arena.h` (6), `arm_dynarmic.cpp` (4). Commit `18be489` applied all 13 hunks. `ktlint` #104 succeeded. [#104 formatting run](https://github.com/TheBillSpence/AzaharFE/actions/runs/45440803337). #106 verification pending.
- ARM64 regression harness failures: [#4](https://github.com/TheBillSpence/AzaharFE/actions/runs/45151679769), [#5](https://github.com/TheBillSpence/AzaharFE/actions/runs/45204424059), [#6](https://github.com/TheBillSpence/AzaharFE/actions/runs/45211449021), [#7](https://github.com/TheBillSpence/AzaharFE/actions/runs/45226516158), [#9](https://github.com/TheBillSpence/AzaharFE/actions/runs/45237194763), [#10](https://github.com/TheBillSpence/AzaharFE/actions/runs/45240186707). Job listing did not return failed-job details, so do not assign a root cause. Later #8, #16, #17, #20, #21 and #22 passed. #23 in progress.
- Earlier default-branch iOS build history includes AppKit/Cocoa macOS-only source inclusion, missing interval-set/boost source entries, LibreSSL syslog/explicit_bzero/reallocarray/timingsafe_memcmp compatibility, ARM64 `lipo` argument order, missing UniformTypeIdentifiers framework, and Objective-C factory C linkage. These are commit-history descriptions, not individually re-audited raw CI failures. See default-branch commits for exact details.
- Nonfatal checks seen in recent successful compile phase: optional mcl/tsl-robin-map/OpenMP detection, feature probes for ARM CRC/PMULL/SHA, missing optional headers, clang-format unavailable on macOS, duplicate libraries, Node.js 20 deprecation. Do not treat them as the cause of #74.

### IPA run inventory from retrieved Actions pages

- Success: 5, 10, 12, 14, 16–27, 36, 37, 39, 40, 45, 46, 50, 51, 58, 60, 62, 69, 70.
- Failure: 8, 9, 15, 34, 35, 41, 42, 52, 53, 54, 57, 73, 74.
- Cancelled: 6, 7, 11, 13, 28, 29, 33, 38, 43, 44, 47, 48, 49, 55, 56, 59, 61, 63–68, 71, 72, 75. Superseded runs are not evidence of compile failure.
- In progress: 76. Builds 1–4 and 30–32 not identified in the retrieved filtered records; do not invent their outcomes. Other upstream workflow histories are not exhaustively audited.

## 6. What must not be regressed

1. Valid StikDebug authorization and RW/RX instruction coherency; both aliases must remain synchronized. Do not rely on a debugger attachment flag alone.
2. Compiled atomic host exclusive monitor (LDREX/STREX path). Never bypass exclusives just to gain FPS. Keep cycle accounting and safe scheduler exits.
3. Preserve user-selectable compatibility/interpreter and Fast Dispatch baselines. Guarded fastmem uses real aliased RAM, valid-group checks, and callbacks for unmapped, rasterizer-cached, watchpoint or crossing accesses. It must not deliberately rely on debugger-intercepted faults. The 4 GiB window is virtual, not 4 GiB physical allocation.
4. Keep current cache budgets unless evidence supports change. Increased cache size can increase allocation pressure, not necessarily FPS. For experimental fastmem primary 128 MiB, secondary mapped 32 MiB, empty 16 MiB; check actual current mode/default settings before testing (earlier docs say Automatic=Fast, later notes say Hyper/Fastmem experimental automatic).
5. No mid-execution JIT-to-interpreter replacement, forced worker termination, or dylib unload while executing native code. No destroying pending GPU fence/image resources. Cooperative halt may not return immediately.
6. Preserve real first-frame delivery check and software fallback on safe early Vulkan init failure. Runtime device failure is not guaranteed recoverable automatically. Keep all exported frontend/core ABI functions in both declarations and iOS generated allowlist.
7. Keep current input/controller/touch mappings, cover management in Game Prep, JIT badge shows active when actually detected, and default access to JIT options with advanced toggles. Preserve stable build fallback.
8. Do not remove diagnostics or CI assertions to hide failures. Use clang-format 19.1.7 on changed C++ files and compile actual iOS frontend before declaring a build fixed.

## 7. Next actions / acceptance criteria

| Priority | Test | What to record / pass criterion |
|---|---|---|
| P0 | Check #76 and all latest CI jobs | IPA builds, export checks pass, artifact uploaded; format #106, Vulkan #13, harness #23 results known. Inspect first actual fatal error if failure. |
| P0 | Baseline phone startup | JIT OFF then Fast Dispatch at 1×, same ROM; actual first frame, 60s gameplay, clean Stop. Record build, selected and effective mode, renderer. |
| P0 | Guarded Fastmem retest | Confirm per-core cache allocation completion, first fetch, startup probes, STREX and scheduler progress. No synthetic benchmark invoked. First frame and continued gameplay. |
| P1 | MoltenVK vs software | Same scene/resolution/mode, 60s profiling OFF; FPS, frame latency, visual correctness. Verify timeout and safe ownership on readback failure (controlled test, not destructive). |
| P1 | Session settings | Change renderer/JIT setting; one controlled stop/relaunch only; unchanged settings resume; no double worker; timeout shown when stalled. Verify saves survive. |
| P1 | Audio/lifecycle | Suspend/resume five times, audio route change, controller/touch combos, settings open/close, clean stop/restart; check queue underruns and pacing. |
| P2 | Performance work | Identify measured bottleneck (CPU/JIT, renderer, shader, DSP or presentation) before changing architecture. Compare modes at equal thermal conditions. |

If #76 freezes: capture complete last log and time elapsed, whether UI responds, first-frame status, active JIT mode/cache, renderer, exact ROM/scene; compare with D12–D16. If allocation stalls, inspect per-core elapsed and alias coverage; if scheduler stalls, inspect last guest PC/opcode/SVC and counters; if video stalls after scheduler progress, inspect renderer/readback trace. Do not return to generic JIT permission debugging when preflight already passed.

## 8. Code map and source of truth

- Workflow: https://github.com/TheBillSpence/AzaharFE/blob/ios-jit-experiment/.github/workflows/ios-frontend.yml — `Azahar iOS JIT + FPS Experiment`, unsigned artifact `azahar-ios-jit-test-unsigned`.
- JIT history: https://github.com/TheBillSpence/AzaharFE/blob/ios-jit-experiment/ios-app/JIT-EXPERIMENT.md
- Runtime plan: https://github.com/TheBillSpence/AzaharFE/blob/ios-jit-experiment/ios-app/IOS-JIT-RUNTIME-PLAN.md
- Latest notes: https://github.com/TheBillSpence/AzaharFE/blob/ios-jit-experiment/ios-app/STABILITY_NOTES.md (newest sections supersede older claims).
- `src/core/arm/dynarmic/arm_dynarmic.cpp`, `ios_jit_budget.h`, `ios_jit_optimizations.h`, `ios_fastmem_arena.h` — JIT scheduling, modes, cache sizes, trace and fastmem.
- `ios-app/patches/apply-ios-jit-memory.py`, `apply-guarded-fastmem.py`, `dynarmic-host-monitor.patch` — patched pinned dependencies; verify selectors and context before editing.
- `src/citra_libretro/CMakeLists.txt`, `ios_moltenvk_bridge.cpp/.h`, `citra_libretro.cpp`, `libretro_vk.cpp` — core exports, Vulkan bridge, frame lifecycle.
- `ios-app/AzaharIOS/AzaharEmulator.mm`, `AzaharLibraryViewController.mm`, `AZSettings.m`, `AZPreferences.m`, `AZAudioOutput.mm`, `AZAudioBuffer.h` — frontend, settings, artwork, session ownership, audio.
- `.github/workflows/jit-harness.yml`, `.github/workflows/ios-vulkan-bridge-check.yml`, `tools/ios-video-tests/readback.cpp` — host regression and fast Vulkan tests.
- GitHub Actions: https://github.com/TheBillSpence/AzaharFE/actions?query=branch%3Aios-jit-experiment

## 9. Append-only template for every future failure

```text
Date / build / commit:
Workflow / run URL / job ID (if CI):
Device / iOS / app install method (if device):
ROM / scene / renderer / scale / selected and effective JIT mode:
Expected behavior:
Observed behavior and reproduction steps:
Exact fatal log / final trace lines:
What still worked (preflight, allocations, scheduler, video, UI, audio):
Confirmed cause vs hypothesis:
Fix attempted / commit / files:
CI verification:
Device verification:
Regression risk / next action:
Status: OPEN / SOURCE FIXED / CI VERIFIED / DEVICE VERIFIED / SUPERSEDED
```

## 10. Instructions to the next AI

Read this file and the three repository design/history notes. Fetch current branch head and latest workflow results before edits. Treat current source as authoritative over older descriptions. Work on the experimental branch, make narrowly scoped commits, and report exactly which tests passed, which remain unknown, and what changed. Never claim a fix is device-verified solely from CI. If the user reports a failure, inspect relevant build and logs instead of asking them to repeat accessible information. Append new evidence rather than rewriting earlier failed experiments as successes.

## Device profiling follow-up — 2026-11-24 (after IPA #77 CI success)

- IPA #77 succeeded; #76 was cancelled. ARM64 harness #23, MoltenVK bridge #13 and formatting #106 passed. Separate multiplatform build #106 failed; not diagnosed here.
- Two device logs (installed build number unreported) confirm all initial and mapped JIT allocations, 512 startup steps, targeted run80 1024 steps, STREX success samples, first software frame and clean shutdown. Guarded fastmem initial alias coverage: 389 groups / 6224 KiB. No evidence of another JIT allocation stall in those sessions.
- Unprofiled software run: 25.1, 14.8, 23.4, 7.1, 7.0, 6.8 FPS; final mean retro_run 138.4 ms and output 0.6 ms/frame. Profiled run: 32.6, 7.5, 7.3, 7.2, 7.4 FPS. A 5.2 s PERF27 window reports CPU 4810.5 ms, JIT 4810.3 ms, SVC 4741.1 ms, PICA 4708.4 ms, triangles 4247.0 ms, decode 12.7 ms, DSP 3.3 ms, scheduler 0.6 ms. Inclusive times overlap; do not add them. This identifies software rasterization as dominant in that scene, not proof of thermal throttling or a JIT regression.
- Next experiment: optimized software rasterizer with reference setting for A/B; inline small triangles, batch larger scanline jobs, preserve per-triangle join; incremental bounded edge equations, skip redundant clipping copies, hoist depth and scissor state, skip full-channel logic Copy destination read, skip unused TEV Replace inputs. No deliberate graphics precision changes, no JIT or Vulkan changes. Adds one-thread option and PERF27 SW job/row/inline counters. New regression workflow tests edge arithmetic and row partitioning; does not test full framebuffer equivalence or A13 performance. Device test pending. Compare identical scene, native 1x, same JIT, software reference versus optimized, then 1/2/4/6 threads, profiling on for attribution and off for FPS. Keep reference fallback if glitches or stalls. Do not expand JIT caches without measured need.

### Build #78 CI outcome

- [IPA #78](https://github.com/TheBillSpence/AzaharFE/actions/runs/45468239139), [software rasterizer regression #1](https://github.com/TheBillSpence/AzaharFE/actions/runs/45468239670), [MoltenVK bridge #14](https://github.com/TheBillSpence/AzaharFE/actions/runs/45468239251): passed. New rasterizer still needs device FPS and correctness testing.
- [Formatting #108](https://github.com/TheBillSpence/AzaharFE/actions/runs/45468239666): four clang-format hunks in sw_rasterizer.cpp; applied exact CI whitespace corrections in the follow-up commit.
- [Multiplatform #108](https://github.com/TheBillSpence/AzaharFE/actions/runs/45468239173): overall failure, all completed build jobs succeeded; macOS cancelled. [Libretro #108](https://github.com/TheBillSpence/AzaharFE/actions/runs/45468239191): overall failure, iOS/Linux/Windows/Android succeeded; macOS x86_64, macOS arm64 and tvOS cancelled. Cancellation cause unverified; do not treat as compiler errors.

## 2026-11-25: software workgroup v2 and settings freeze mitigation

- Device log after #78 (installed exact build/thread count unreported): 31.3 FPS startup; 5.9, 5.8, 5.6 FPS demanding scene. At 5.2s CPU 4886.0 ms, JIT 4885.7 ms, SVC 4797.0 ms, PICA 4753.4 ms, triangles 4185.0 ms; 10645 triangles, 473900 rows, 97153 dispatched jobs, 775 inline. Compared with 7.2–7.5 FPS earlier, apparent regression, but settings/temperature/scene not controlled. Startup probes, exclusive monitor, frame delivery and clean shutdown succeeded. User reports settings changes still freeze.
- Replaced optimized path's queued scanline work with persistent synchronous RasterWorkGroup, one publication per large triangle, caller participates, fixed disjoint row partitions; small bounding boxes (<=4096 pixels or <8 rows) run inline. Reference path retains existing queue. PERF27 jobs now counts batch publications for optimized path and queued rows for reference; not directly equivalent to old per-job metric. Regression exercises repeated workgroup submissions and exact row coverage; full framebuffer and iPhone results pending.
- Read-only early depth rejection before shading only in normal fragment mode with depth testing enabled and stencil disabled; retains original alpha/depth write ordering. Skip interpolation for unneeded texture coordinates. No intentional precision loss or Vulkan/JIT changes. No external code copied.
- Settings close no longer automatically destroys/recreates core: save configuration for next launch, offer continue or explicit stop and return to library. Normal menu pause uses cooperative scheduler boundaries instead of cross-thread halt. Stop first allows cooperative exit, delays halt request 500 ms, and records library close markers. Avoid debugger probing during live session status checks. These mitigate known risky paths but exact freeze root cause remains unverified; if still stuck, collect current and previous diagnostic files and note whether menu, stopping, library close, or next launch hangs. Do not promise in-place backend changes or unsafe forced teardown.

### Clarified settings/relaunch freeze (2026-11-25)

User reproduction: leave game screen to Library, change a setting in the separate Settings tab, return to Library, launch game again, then entire app freezes and buttons cannot be clicked. This is NOT the automatic in-game settings restart path. Prior workaround alone does not address this. Current fix: Stop stays on game screen until worker completion (including dlclose); navigation Back can still leave, but library explicitly refuses a new launch while previous owner exists. No main-thread waits. Each launch logs process-local session number, resolved options, before/after dlopen, and completed teardown. Existing first-frame/BRK diagnostics remain. If entire app stops responding after the new session starts, obtain current AND previous diagnostics; debugger BRK/second JIT allocation, core reinitialization and driver are distinct possibilities, not established root causes. Compare second launch without any setting change and JIT-off second launch. Preserve JIT mappings, cache sizes and exclusive-monitor implementation. Full device validation pending.

## 2026-11-26: SUPER-EXPERIMENTAL IPA #3 build failure

- Branch `SUPER-EXPERIMENTAL`, head `83eb0abfb07ae109198bd42f8735bb252d3373ca`. [IPA #3](https://github.com/TheBillSpence/AzaharFE/actions/runs/45682744784), job 139447248780, failed in Build Azahar libretro backend: `citra_libretro.cpp` includes `renderer_software.h` -> `sw_rasterizer.h` -> `ios_fragment_jit.h`, whose `#include <oaknut/oaknut.hpp>` was not found. Compiler invocation had IOS, AZAHAR_SUPER_EXPERIMENTAL and arm64 but no Oaknut include directory. The existing Oaknut CMake target is enabled for ARM64; video_core receives it, but citra_libretro did not. Fix: explicitly link Oaknut's interface target privately to citra_libretro in the IOS/ARM64 block. No shader JIT features disabled or generated code altered. Requires fresh CI; later errors may still surface. No device runtime validated.
- Format #115 passed; multiplatform #115 all 11 completed jobs passed, macOS cancelled; libretro #115 Android/Linux/Windows passed, iOS/tvOS/macOS x86_64/arm64 cancelled. No compiler errors reported for cancelled jobs; runner cancellation cause unverified. No workflow coverage removed.

### SUPER-EXPERIMENTAL IPA #4: missing shader diagnostics (2026-11-26)
- IPA #4 (45778313575), format #117 and libretro #117 passed on `5f22614`; multiplatform #117 was in progress at check. User supplied session log with combined preset, shader JIT on, software optimized and auto threads, 1x, deep profile. CPU JIT preflight 42, startup probes and clean teardown passed; demanding FPS 13.6–15.8. Exact installed build and native shader execution cannot be proven from old log.
- Confirmed diagnostic routing bug: frontend RETRO_ENVIRONMENT_SET_MESSAGE persisted JIT27TRACE, SHADER27 and PERF27 only, assigning other messages (including SUPER27 validation and SW27 renderer selection) to _lastMessage. Fix persists SUPER27 and SW27 via writeDiagnostic, without updating lifecycle stage. Adds explicit fragment-JIT disabled reason at renderer construction; same short-circuit activation criteria as before. No JIT compiler, memory or rasterization behavior changes. Existing validation messages should be visible if emitted. No device validation of fix yet; absence of old messages was not evidence of native shader failure.

### SUPER-EXPERIMENTAL rasterizer hot-path pass (2026-11-26)
- Target the observed PICA-heavy 13.6–15.8 FPS software run. Earlier native shader messages were lost by frontend logging; do not attribute gains to shader JIT until validated.
- Optimized software path: prepare texture metadata and fixed physical base pointers per primitive, not decoded texels (texture contents remain live; cube faces keep dynamic address resolution); skip unused tc0_w interpolation; defer reciprocal W interpolation until after read-only early depth rejection for Z buffering. Preserve special texture modes, W buffering, alpha/stencil/depth ordering, and reference fallback. Skip empty bounding boxes before shader preparation.
- Bounded fixed-point long spans: exact integer intersection of three linear edge ranges, preserving original sample centers/top-left biases and scalar coverage check. Existing NEON four-lane rejection runs only when first pixel is outside. Existing synchronous tile/workgroup barrier retained; no cross-primitive reordering or aggressive floating-point flags.
- Native TEV: cache last full shader key/program (including fallback), immutable map ownership retained; full RGBA Replace from the same unmodified source becomes a single packed load/MOV or no-op, preserving delayed buffer updates and existing 32-sample reference validation. Cache-limit diagnostic once per session. Blend RGB/alpha identical equations only evaluated once in optimized path. Framebuffer first binding now initializes both addresses deterministically.
- Existing software regression workflow now includes SUPER-EXPERIMENTAL and 100,000 randomized span/edge coverage comparisons, in addition to existing worker coverage. New code requires compilation and runtime validation; no FPS or pixel-perfect claim. Do not remove reference mode. Compare identical scene at 1x, profiling on then off, 2/4/6/auto threads, shader JIT off/on, and visual correctness. No new workflow, no changes to CPU JIT memory or renderer backend.

### SUPER-EXPERIMENTAL Vulkan pipelined framebuffer readback (2026-11-26)
- A/B/C device tests at 4x (1600x1920), async shaders off, profiling on: A interpreter 48.5/39.8 FPS; B CPU JIT only 41.4/40.4/41.9/42.3 FPS; C CPU + shader JIT 40.5/40.6/41.3/40.0 FPS. Final readback 15.10/14.50/15.20 ms; CPU profile 636.4/432.3/530.4 ms respectively, windows not exactly aligned. Short, uncontrolled workloads; shader JIT execution not established. CPU JIT helps later samples, not proof of causal shader slowdown.
- New exported azahar_ios_vk_readback_frame ABI: 1 completed frame, 0 normal pending (keep previous image), -1 failure. Native RGBA/BGRA order returned without intermediate vector copy or channel swap. Existing synchronous BGRA ABI preserved. Three lazily allocated persistent mapped staging slots, per-slot command/fence/geometry/format/serial; poll vkGetFenceStatus; newest completed frame wins, no buffer reused until completion. First/resize/mode-change frames synchronously wait with old bounded timeout; steady state skips submit if full. Existing same-queue producer WaitWorker and image layout barriers retained. One shared libretro output image; GPU queue ordering and transfer-to-all-commands barrier protect subsequent producer access. Do not move copies to separate queue without ownership synchronization. No change to renderer image destruction paths; existing scheduler.Finish on resize and frontend drain before unloading retained. Pending copies drained before shutdown; device stall reported after two seconds of pending work. Existing driver teardown may still block.
- Frontend setting Vulkan framebuffer readback: Pipelined (3 buffers) default, Synchronous (compatibility) for A/B. Core Graphics interprets native byte order; NSData still owns one CPU copy for UI lifetime. Readback diagnostic now reports calls/pending/mean CPU-side call time, NOT actual GPU elapsed time. FPS and delivered images must both be compared (pipelining may increase emulated FPS but drop displayed frames or add latency).
- Extend existing Linux Vulkan regression workflow to SUPER-EXPERIMENTAL; test ordered colors in both byte orders, pending status, resize and drain, plus original sync checks. Add ABI export check. Apply exact six clang-format hunks from failed format #119 (rasterizer and fragment JIT); regression #5 passed before these edits. New code compile/device tests pending. Direct Metal/CAMetalLayer zero-readback presentation, GPU timestamp profiling, native shader verification and expanded fastmem deferred: these need separate renderer/UI ownership and correctness work. No claim of FPS gain or zero-copy. CPU JIT untouched.

### GPU-only presentation + adaptive display UI (2026-11-26)
- Experimental Direct Metal surface uses VK_EXT_metal_surface + VK_KHR_swapchain on CAMetalLayer. Existing Vulkan PICA rendering remains; GPU blits the offscreen composite (or top/bottom subregions) into drawable images, with no host framebuffer mapping, NSData or UIImage creation on this path. FIFO presentation, 3 command slots, acquire semaphore per slot, present semaphore per drawable, same graphics queue ordering, source layout restoration. Surface creation/queue selection checked; unsupported or repeatedly unavailable presentation switches to existing CPU readback. Resize waits for GPU ownership to finish on worker; underlying driver wait is not guaranteed bounded. Metal submitted frames are not measured physical scanout.
- Native emulation timing untouched: user cancelled FPS limiter. Presentation defaults to direct Metal when Vulkan selected; explicit CPU-readback compatibility option. No changes to JIT, rendering resolution, audio timing or CPU scheduling.
- Portrait/left/right landscape enabled. Default landscape Option B corner, Option A stacked, top-only, adjustable secondary height, preserve aspect or stretch, translucent controls, hide/restore extended gamepad controls, touchscreen remapping. Live in-game top-left Display Options and Game Prep section. New geometry applies to the default dual-screen core layout only; other core layouts aspect-fit. Device rotation/controller and real Metal performance still require device validation. Existing workflow verifies two added C ABI exports; Linux readback regression remains independent of Apple surface APIs.

- IPA #8 (45817081813) failed before app compilation: new display geometry test calls CGRectGetMin/MaxX/Y but macOS test command omitted CoreGraphics. Added the framework to both existing frontend workflows. Applied 16 whitespace-only formatting hunks from citra-format #121; Linux Vulkan bridge #18 passed. No renderer or FPS behavior changes in this fix.

### Build #7 baseline redo: isolate GPU-only Metal presentation (2026-11-26)
- User explicitly requested the successful IPA #7 commit 83db6b0f as the source baseline, with only direct Metal presentation added. Reconstructed tree from that commit, retaining the formatted Metal surface bridge, ABI export checks, GPU lifetime protections, Metal/QuartzCore linkage, headless fallback regression and original portrait aspect-fit UI adapted to the surface. No force-push; previous layout experiment remains available in history.
- Removed the #8/#9 adaptive landscape redesign and related settings/tests from this revision; no FPS cap, no frame duplication/interpolation, no guest timing, JIT, resolution or audio changes. Metal vs CPU readback remains a per-game launch option (Metal default for Vulkan); software path unchanged. Native 30 FPS games can run at 60 emulated refreshes per second; accepted Metal submissions and UIImage deliveries are not counts of unique game frames or physical scanout. Separate diagnostic counters now make this distinction explicit. Do not claim doubling of visual FPS. Compare same scene/resolution and mode on device, including heat and battery, with a native 60 FPS title for high-rate testing.
- #9 frontend and layout/input tests passed before this redo; Apple GPU surface runtime remains untested. Linux bridge only verifies non-Apple compatibility path. The Metal surface still uses MoltenVK for Vulkan commands, not a full native Metal renderer.

### Retina Metal presentation correction (after IPA #10, 2026-11-26)
- IPA #10 built successfully, but user reported 4x looked native. Found manual CAMetalLayer had drawableSize set from screen scale but contentsScale left at 1. MoltenVK obtains currentExtent from natural drawable size (bounds * contentsScale) and uses it for swapchain creation; a point-sized surface can discard most supersampled detail. Set layer contentsScale at creation and every layout, use supported linear GPU blit (nearest fallback), and reject substantially undersized surfaces (>10% smaller than requested) rather than silently degrading resolution. Preserve original aspect fit and core settings.
- New optional C ABI reports actual surface extent; diagnostics record core framebuffer dimensions, requested and actual drawable pixel dimensions and result. Linux regression checks headless extent=0; IPA workflow verifies export. No FPS cap, JIT, game timing or layout changes. Source-level defect found, on-device image quality not verified. If still pixelated, compare CPU readback and check actual Vulkan vs software mode and dimensions in the diagnostic log.

### Separate SUPER-EXPERIMENTAL-DISPLAY workflow (build #11 baseline)
- User requested keeping everything from #11 and adding display options A/B in a new workflow. Isolated branch SUPER-EXPERIMENTAL-DISPLAY; base 45f883e6 (IPA #11). Existing SUPER-EXPERIMENTAL and workflow remain unchanged. Separate workflow .github/workflows/super-experimental-display.yml uses same packaging/JIT/core settings and distinct artifact name. App bundle identifier intentionally unchanged to preserve app data on upgrade; this is not a side-by-side app.
- Restored earlier frontend A/B implementation: corner B default, stacked A, top-only, bottom height 15–60% default 30%, aspect/stretch, controller auto-hide and opacity, Game Prep and in-game top-left display options. No core restart for layout-only changes (menu pauses while open). Default dual-screen composite is split, others aspect-fit. Main thread sets Retina CAMetalLayer contentsScale and drawable size before worker geometry update; build #11 linear blit, undersized-surface guard and real resolution diagnostics retained. Shared geometry maps Metal, CPU fallback and touchscreen; tests cover A/B, Retina proportional scaling, swapping, top-only, portrait and no-restart. Fresh layer per session, no FPS cap or changes to JIT/timing/audio. Applied #124 formatting-only correction to bridge. IPA #11 was in progress when starting this branch; real-device rendering, rotation, and touchscreen behavior not yet verified.

### Display IPA #2: compact landscape chrome and screenshot-stall diagnostics
- User observed intermittent freeze after entering an Ocarina crawl hole on Metal; same hole succeeded on repeat. CPU readback 4x with CPU+shader JIT and deep profiling completed clean stop, ~60 emulated FPS. Metal log had ~59.8 emulated FPS, 1600x1920 framebuffer, requested/actual Retina dimensions equal, no CPU images, no shutdown at first freeze. Subsequent user reports first-install lag warms up across launches (shader cache hypothesis only), and freeze after iOS screenshot. Screenshot IMG_1060 shows oversized navigation prompt/title and bottom FPS strip compressing landscape content. No reproducible root cause yet.
- Landscape replaces system navigation and bottom FPS strip with a 36-point custom toolbar (Back, Display, compact status, Stop, Settings), removes extra game-view padding and corner clipping, preserves safe-area bounds, original portrait UI and A/B geometry. Native aspect ratio and touch size remain configurable; no forced stretching or resolution reduction. Navigation restored when leaving game. External LiveContainer/system overlays are outside our app control.
- Screenshot and active/inactive notification markers log current frame/video counters and worker phase; screenshot itself does not force a resize, pause or JIT halt. Gameplay watchdog samples every 2 s, logs after two consecutive no-progress samples, including paused in-flight frames, scheduler progress, main queue responsiveness and lock-free bridge stage (0 idle, 1 validation, 2 swapchain rebuild, 3 fences, 4 acquire, 5 record, 6 queue lock, 7 submit, 8 present). Worker phase 0 idle, 1 retro_run, 2 Metal, 3 readback, 4 video copy/callback. Optional ABI lifetime protected with existing bridge mutex; no GPU wait or forced resource destruction from watchdog. Headless stage regression and IPA export verification. No change to JIT optimization, internal resolution, GPU blit, frame pacing or rendering algorithm. Diagnostic instrumentation only for freeze; no claim that hang is repaired until device reproduction identifies exact cause.

### Display IPA #3: enlarge bottom-right touch panel, low-risk frontend hot-path optimization
- User requested wider corner touchscreen without moving or resizing top screen. Kept exact old top rectangle formula for every view, ratio, aspect setting; expanded bottom panel into the free right-hand region, anchored at lower-right; native 4:3 preserved (stretch mode retains requested behavior). Stacked and top-only layouts unchanged. Shared geometry ensures GPU blits, CPU fallback and touch mapping remain aligned. Touch-size preset still affects original corner top-screen geometry as before; corner bottom now maximizes available space rather than strictly following preset height. Added tests for 96 viewport/ratio/aspect combinations verifying old top exact, non-overlap, size, right/bottom alignment, native aspect.
- Hot-path audit: removed repeated Objective-C layout/dictionary lookups and rectangle normalization on unchanged Metal frames via worker-only cache keyed by main-thread geometry revision + source framebuffer dimensions. Skip duplicate layout publication/copies. Reduce new gameplay watchdog atomic increments to first slice/every 64 slices while retaining exact startup count and stop/pause checks at every boundary; diagnostic label sliceSamples reflects sampling. No JIT/cache/timing changes or shader cache changes. Avoid risky GPU synchronization modifications pending screenshot-freeze diagnostic. Performance impact expected small, not measured. Existing workflow used; no new workflow. Previous Display #2 queued when inspected, validation pending.
