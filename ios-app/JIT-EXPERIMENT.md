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
