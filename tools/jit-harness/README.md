# AzaharFE native ARM64 JIT regression harness

This is a **host-side automated test**, separate from the iOS IPA build.
It executes the exact pinned Dynarmic A32 recompiler on a real Apple Silicon
GitHub Actions macOS runner. It does **not** run an iPhone simulator, iOS
LiveContainer, StikDebug, a 3DS GPU or commercial ROM data.

## Test cases

| Test | Checked behavior |
|---|---|
| parity | 32 ARM32 guest instructions executed by Dynarmic Step agree with a small independently written interpreter after each step: all 16 registers, CPSR flags and guest memory |
| budget | Dynarmic Run returns at cycle budgets 32, 64 and 256 and reports consumed guest cycles through callbacks |
| svc | A synthetic SVC 0x21 reaches a host callback, requests a cooperative JIT halt and resumes execution |
| invalidate | A compiled ARM32 instruction can be modified, invalidated and re-executed with the new result |

The interpreter deliberately supports **only** this fixture. These tests use
AzaharFE's conservative optimization flags and 16 MiB code cache, but the
**normal macOS executable-memory path**, not iOS 27 TXM or the patched
Oaknut iOS mapping code.

## Running locally on an Apple Silicon Mac

Install CMake 3.25+, Ninja and Boost, then run:

    git submodule update --init --recursive externals/dynarmic
    cmake -S tools/jit-harness -B build-jit-harness -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
    cmake --build build-jit-harness --target azahar_jit_harness --parallel 3
    ctest --test-dir build-jit-harness --output-on-failure --timeout 25

Or use the AzaharFE ARM64 JIT Regression Harness Actions workflow.
Each case runs actual generated ARM64 code; failures propagate as nonzero
exits and hangs are terminated after a per-case timeout.

## Next phase

Build #25's iPhone log ended at JIT run 80, after ARM32 SVC 0x21
(CreateAddressArbiter) returned. The watchdog fired but did not restore
execution. Build #26 adds instruction-level tracing around that boundary.
When those on-device results are available, create a **minimal synthetic
reproducer** here for the actual failing path, without depending on
game ROM contents, firmware, device data or decryption keys.

**A green workflow means only the host-native fixtures passed.**
The iPhone remains necessary for iOS JIT permissions/TXM, LiveContainer,
UI responsiveness and rendering. Stable master is unchanged.
