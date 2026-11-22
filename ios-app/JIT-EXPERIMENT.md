# Experimental iOS JIT + FPS (iPhone 11 Pro Max / A13)

The stable app on master remains unchanged. This branch uses a different
bundle ID and has a separate Documents directory.

## What changed

The previous JIT experiment checked RWX mmap permission before launching the
game. That did not match how Dynarmic actually emits ARM64 instructions.

This build patches the pinned Oaknut submodule at build time and gives its
code cache separate writable (RW) and executable (RX) mappings. Dynarmic's
Oaknut code generators and relocations now write through the RW alias,
while executing through RX. It also waits up to 15 seconds for the host
process's CS_DEBUGGED flag before attempting JIT initialization.

This is targeted at *pre-TXM* hardware, including iPhone 11 Pro Max (A13).
On iOS 26+ hardware that requires the universal.js JIT breakpoint
protocol (generally A15/M2+), it intentionally falls back to the interpreter
rather than trying to execute unprepared memory or issuing a dangerous BRK.
Implementing the newer StikDebug region preparation handshake is a separate
next step.

## Testing in LiveContainer

1. In LiveContainer, set up StikDebug as the JIT enabler.
2. Enable "Launch with JIT" for Azahar JIT Test.
3. In Azahar's game library enable JIT ON, then launch a game via LiveContainer.
4. It waits for CS_DEBUGGED, then tests the actual dual-mapped memory path.
5. FPS display shows "JIT dual-map test" when permitted; this still does
   not prove that generated Dynarmic code ran correctly. Compare FPS,
   gameplay, and log output; disable JIT if it crashes.

JIT is OFF by default. There is no automatic StikDebug URL opener because
LiveContainer already coordinates JIT for its guest apps.
The FPS value counts libretro frame calls, not GPU utilization. Graphics are
software-rendered; audio and touchscreen input remain unimplemented.
The workflow produces an unsigned IPA needing normal sideload signing.
