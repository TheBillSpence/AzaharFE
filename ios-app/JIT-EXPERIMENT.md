# Azahar experimental JIT for iOS 27

This branch targets iOS 27 on the iPhone 11 Pro Max / A13. The stable
master branch is unchanged.

StikDebug's TXM detection treats essentially all iOS 27 iPhones as TXM
enabled, including the iPhone 11. A debugger attachment by itself isn't
enough to grant executable memory.

This experimental build requests executable code-cache memory through
StikDebug universal.js: BRK #0xf00d, x16=1, x0=null, x1=region size.
It creates RW aliases through vm_remap and vm_protect and makes Dynarmic
write emitted ARM64 code to the RW alias while executing the RX one.
The code cache is 16 MiB per CPU (Dynarmic documents ~8 MiB as minimum).
The earlier 4 MiB size was below its recommended minimum.
The frontend first preflights the same protocol with a 16 KiB region.

Important: universal.js MUST be assigned before turning JIT ON. If
CS_DEBUGGED is set but the debugger isn't running the universal script,
the BRK may crash. This is experimental, untested on a physical device.
The JIT status reports successful memory preparation only, not validated
JIT game execution.

LiveContainer: set StikDebug as the JIT enabler, enable Launch with JIT
for the Azahar guest, assign universal.js, connect LocalDevVPN, and
launch through LiveContainer. Then enable JIT ON inside Azahar.

The software renderer is still slow and audio/touchscreen are not yet
implemented. Stable master remains a fallback.

## Black-screen debugging (next test)

If JIT ON stalls, find `Documents/AzaharJITDiagnostics.txt` in the
experimental app's LiveContainer Files view. The file is written before each
potentially blocking stage. The last line tells us whether the app is waiting
for StikDebug, requesting the 16 KiB preflight mapping, initializing Azahar,
loading the game, or waiting for the first frame to return. Share that line.
The visible status label also shows the stage if UIKit is still running.
The JIT ON mode remains experimental and may freeze or crash; JIT OFF is safe.

## First-frame diagnostic trace (build after #12)

The earlier iOS 27 test passed the debugger, 16 KiB universal.js JIT
memory check, core init and game loading, but hung before returning from
the first frame. This test traces the *first libretro frame* through:

- `retro_run` entry
- `System::RunLoop` entry and exit, including bounded checks for many slices
- Dynarmic's `MakeJit`, `Run`, and `Step` first entry/exit
- first video frame submission

Events beginning `JIT27TRACE` are stored in the same Documents diagnostic
file as the seven frontend startup stages. If it hangs again, export the
last 10 lines of `AzaharJITDiagnostics.txt` for diagnosis. No automatic
switch to interpreter occurs while Dynarmic may already be executing.

## Build after #14: first Dynarmic instruction

On an iPhone 11 Pro Max (A13) running iOS 27.2.1, the Build #14 ARM64
JIT memory test successfully executed `mov x0, #42; ret`, returning 42.
Azahar created all five Dynarmic JIT caches but hung after the first
`Dynarmic::Run entered` trace. To distinguish invalid generated code from
a full-slice loop, the first `Run()` now calls Dynarmic's `Step()`
for exactly one guest instruction, reports whether it returned, then
allows normal full-slice runs. Oaknut now invalidates both the writable
and executable aliases after code emission and link patching. This
build has not yet been tested on device.

## Build after #16: 512-instruction JIT diagnostic

The A13 / iOS 27.2.1 test showed successful native ARM64 RX execution, then
completed the first Dynarmic JIT single-step and first `System::RunLoop`.
It subsequently stopped inside the first full-speed `Dynarmic::Run`.

Before calling full-speed `Run`, the experimental frontend now executes
512 bounded guest instructions through `jit->Step()` in successive core
scheduler slices. It logs selected step numbers together with core ID,
guest PC, and timer downcount before/after stepping. This distinguishes a
specific instruction/core failure from a problem in continuous execution.
After step 512 it restores normal full-speed `jit->Run()` for comparison.
The 512-step diagnostic is temporary, not a performance optimization.

## Build #18: responsive iPhone UI and version badge

The game view now uses a flexible screen-height constraint, so the live JIT
status is kept above the two rows of on-screen buttons rather than competing
with the image for fixed vertical space. Buttons scale their titles on
narrower screens; long ROM titles omit the extension in navigation; the
library instructions have a wrapping inset footer.

A persistent, non-interactive bottom-left badge reads `v0.1.0 · build N`,
using the actual bundle version. The GitHub Actions packaging workflow
stamps `CFBundleVersion` from `GITHUB_RUN_NUMBER` automatically; this commit
targets Build #18. Controls reserve the badge area above the iPhone safe
bottom inset. The Build #17 512-step Dynarmic diagnostics remain intact.

## Build after #18: conservative Dynarmic dispatcher

Build #18 on the user's A13 / iOS 27.2.1 completed all 512 JIT single
steps. Guest PC spent many steps cycling around 0x00100034..0x0010003c
while the timer downcount decreased by one each step. The first full
`jit->Run()` again failed to return, despite a positive 374845-cycle
budget.

This follow-up temporarily disables Dynarmic's BlockLinking,
ReturnStackBuffer, and FastDispatch optimization flags, while retaining
the other safe IR optimizations and explicitly enabling cycle counting.
This forces basic-block terminals through the generated dispatcher.
In pinned Dynarmic, the `LinkBlockFast` path can directly branch to
another generated block without the explicit Xticks check used by the
regular `LinkBlock` path. This is a diagnostic hypothesis, not a
confirmed root cause.

The Build #18 responsive game UI, persistent version label, 512-step
probe, and stable master branch remain unchanged. The expected outcome
is the first `Dynarmic::Run returned` trace, or more detail proving
that direct linking was not the cause.

## Build #20: bounded full-JIT execution and timer callback trace

On Build #19, all 512 JIT single-steps succeeded and the first
full `Dynarmic::Run` still failed to return even with BlockLinking,
ReturnStackBuffer and FastDispatch disabled.

This diagnostic build temporarily limits the cycle budget reported by
`DynarmicUserCallbacks::GetTicksRemaining()` to 64 guest ticks, starting
at the first full `Run` invocation. It also logs the first three
`GetTicksRemaining` and `AddTicks` callback calls. If the first full
run now returns, the issue likely depends on large JIT slices or the
full-speed dispatch behavior over many cycles. If the timer callback is
entered but it still fails, the issue is deeper in the generated loop
or return path. If it is never called, the full-run entry prelude is
suspect. This 64-tick cap is a DIAGNOSTIC, not a production setting;
it will slow emulation and should be removed when the issue is solved.

Keep testing with StikDebug universal.js on iOS 27.2.1. The Build #18
adaptive UI and the persistent build counter remain unchanged.

## Build #21: progressive JIT cycle-budget test

Build #20 on iOS 27.2.1 / iPhone 11 Pro Max passed the first full
`Dynarmic::Run` with `GetTicksRemaining()` capped at 64 cycles. The
first trace showed `AddTicks(65)` and `first full Dynarmic::Run returned`.
This confirms genuine continuous generated-code execution and cycle
accounting with short slices, but not yet successful video rendering.

Build #21 tests successively larger cycle budgets over repeated full JIT
runs: 64, 256, 1024, 4096, 16384, 65536, and 262144 ticks, 16 runs per
stage. It writes a `JIT27TRACE budget test stage=... budget=... entered`
line before the first run at each size and a `returned` line when
that run completes. If it freezes, the last stage identifies the first
budget that was too large for the current code path. A thread-local
setting passes the budget to the existing Dynarmic timer callback. The
512 single-step preflight is retained for diagnostic consistency.

The ramp is a diagnostic, NOT an FPS setting. It does not establish a
reliable maximum until verified on device. Adaptive UI and build
counter remain in place; stable master remains unchanged.

## Build #25: Azahar-owned cooperative execution control

Studied ARMSX2's iOS VM thread, ARM64 dispatcher event exits, and regression
harness. Implemented a new AzaharFE-only C ABI bridge to Dynarmic's
`HaltExecution()` so UI Stop can request a cooperative safe exit from a
live JIT run. A first-frame watchdog does the same when scheduler progress
remains unchanged between the 3s and 10s probes. It does not forcibly kill
a worker, patch active RX code, or switch CPU backend mid-run. We also log
the JIT return reason on budget-stage traces. See
`ios-app/IOS-JIT-RUNTIME-PLAN.md` for the staged architecture plan.

## Build #26: targeted JIT single steps at run 80

The Build #25 Ocarina test still stopped at full JIT run 80 (PC
0x0041A4AC) after SVC 0x21/CreateAddressArbiter returned. The 3- and
10-second checks both reported exactly 591 scheduler slices. The watchdog
fired, but no subsequent full JIT return was logged. Its request was not
separately acknowledged, so Build #26 adds both a frontend and a core
acknowledgment reporting how many JITs were actively registered.

Build #26 executes 1,024 *generated-code* single instruction steps at
run 80 instead of the original 16,384-tick full Run. It logs CPU PC,
CPSR, registers r0/r1/LR, tick downcount and halt reason before and
after the first 24 steps and selected later checkpoints. After those
steps, full Run resumes with a conservative 256-cycle cap. This isolates
whether an individual instruction/backend call stalls or only the
full-speed dispatcher path does. This is diagnostic-only, not playable
performance. Stable master unchanged.

## Post-Build #26 device log: narrow step-33-to-64 window and missing halt export

The next iPhone test confirms the ARM64 RX preflight returned 42, the first
512 JIT steps and full JIT runs 1-79 returned, and run 80's targeted steps
1-32 all returned. Step 32 ended at ARM32 PC 0x003019D4. The scheduler
stopped at 626 completed slices, with no step-64 checkpoint and no video
frame. The exact non-returning step is still unknown; trace steps 33-64
individually before changing JIT dispatch code.

The watchdog explicitly logged `frontend halt bridge unavailable (missing symbol)`.
The source defines `azahar_jit_request_halt`, but the macOS/iOS libretro
linker applies an allowlist in `libretro.osx.def` that lacks the symbol.
Generate an iOS-only extension of the export list at CMake configure time,
keeping regular macOS builds unaffected. The IPA workflow now inspects the
built dylib with `nm -gU` and fails CI if the export is absent. This
repairs the frontend dlsym contract but does not establish that cooperative
HaltExecution can interrupt the JIT's currently frozen instruction.

## iOS output resolution (1×–4×)

The iPhone settings offer **Output resolution** at 1× native, 2×, 3× or
4× (default **1×**) globally or per-game. The libretro core already parses
`citra_resolution_factor`; the iOS frontend now supplies that value before
loading the game. The available iOS core-option values are limited to 1–4,
leaving other platforms' 1–18× choices unchanged. Restart a game to apply a
changed scale.

**Important:** The current iOS build uses the software renderer. Its 3DS
screen pixels are rasterized at native resolution and then upscaled into the
larger output buffer. Increasing this factor does **not** increase real 3D
rendering detail without a hardware renderer (such as a future Vulkan/Metal
backend). It does increase frame memory, copies, and CPU compositing work.
For best performance, use 1×. In Large and small screen layout, iOS software
output also respects 1×–3× instead of silently forcing a 4× framebuffer.

## Build #45: fast JIT by default (iPhone performance experiment)

Fast Dispatch is now the default for new/unconfigured game profiles. It
restores Dynarmic block linking, return-stack buffering, and fast dispatch.
Existing explicit global/per-game compatibility settings remain respected.
The post-startup JIT budget is increased to **4,096 guest ticks before video**
and **262,144 guest ticks after video** for Fast Dispatch, still bounded by
CoreTiming's next event and with HaltExecution available. Compatibility retains
256 / 16,384 ticks, the existing tested behavior. The iOS Release workflow
requests **LTO** when supported, retaining the existing software renderer and
16 MiB JIT cache size.

Crucially, the 512-step / run-80 startup safety workarounds are retained
because earlier direct full runs hung on device. They are startup-only and
removing them risks breaking boot rather than improving steady gameplay.
Likewise, the direct guest page table remains disabled until device-verified.
This is a performance experiment, not an assurance of higher FPS: software
graphics still lacks Metal acceleration. Benchmark with the same game at
1× output resolution; compare 5-second FPS and frame/output timings.
