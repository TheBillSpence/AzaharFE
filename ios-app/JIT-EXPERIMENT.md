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
Each iOS Dynarmic code cache is now capped at 4 MiB to reduce how many
16 KiB pages the debugger needs to prepare at once.
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
