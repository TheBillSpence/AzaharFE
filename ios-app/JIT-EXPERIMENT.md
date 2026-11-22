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
Each iOS Dynarmic cache is limited to 32 MiB, rather than 128 MiB.
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
