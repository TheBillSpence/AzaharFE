# AzaharFE native ARM64 JIT regression harness

This is a **host-side automated test**, separate from the iOS IPA build.
It executes the exact pinned Dynarmic A32 recompiler on native ARM64 macOS and Linux runners. It does **not** run an iPhone simulator, iOS
LiveContainer, StikDebug, a 3DS GPU or commercial ROM data.

## Test cases

| Test | Checked behavior |
|---|---|
| parity | 32 ARM32 guest instructions executed by Dynarmic Step agree with a small independently written interpreter after each step: all 16 registers, CPSR flags and guest memory |
| budget | Dynarmic Run returns at cycle budgets 32, 64 and 256 and reports consumed guest cycles through callbacks |
| svc | A synthetic SVC 0x21 reaches a host callback, requests a cooperative JIT halt and resumes execution |
| invalidate | A compiled ARM32 instruction can be modified, invalidated and re-executed with the new result |
| parity_long | 2,048 JIT instructions checked against an independent interpreter, including registers, CPSR and memory |
| budget_stress | Repeated runs of a four-instruction loop, including unaligned budgets and an upper bound of three extra ticks |
| step_run | Alternating Step and Run during loads, stores and arithmetic agree with the independent reference CPU |
| exclusive | An ARM exclusive load/store succeeds, fails after another processor wins the reservation, and succeeds again during Run |
| svc_chain | Three SVC 0x21 halt/resume cycles in one synthetic ARM32 program |
| invalidate_stress | Patch and invalidate the same guest instruction 32 times to catch stale code |
| opt_linked | Tests the block-linking speed preset on active ARM32 loops, verifying state and Run/Step budgets |
| opt_fast | Tests restored upstream dispatch optimizations with the same correctness checks |

The interpreter deliberately supports **only** this fixture. The longer parity
case keeps the loop active for all 2,048 instructions. These tests use
AzaharFE's conservative optimization flags and 16 MiB code cache, but the host's normal executable-memory path. Both lanes exercise the same compiled monitor lock as the iPhone build.

## Running locally on an Apple Silicon Mac

Install CMake 3.25+, Ninja and Boost, then run:

    git submodule update --init --recursive externals/dynarmic
    git -C externals/dynarmic apply "$PWD/ios-app/patches/dynarmic-host-monitor.patch"
    cmake -S tools/jit-harness -B build-jit-harness -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64
    cmake --build build-jit-harness --target azahar_jit_harness --parallel 3
    ctest --test-dir build-jit-harness --output-on-failure --timeout 25

Or use the AzaharFE ARM64 JIT Regression Harness Actions workflow.
Each case runs actual generated ARM64 code; failures propagate as nonzero
exits and hangs are terminated after a per-case timeout.

The iPhone trace entered an ARM LDREX and stopped before its return.
The exclusive test uses synthetic instructions and memory to exercise this
path. Rendering the first game frame still requires a device test.

## Optional iPhone JIT speed presets

Under Settings > JIT performance mode, choose:
- **Compatibility (current)**: the proven iPhone JIT settings, and the default.
- **Linked blocks (test)**: restores block linking, while leaving fast dispatch and
  return-stack prediction disabled.
- **Fast dispatch (test)**: restores all three upstream dispatch optimizations.

This setting is captured on game launch; restart a game to apply it. If a
mode stalls or crashes, reopen the game in Compatibility. Benchmark with the
same game scene and graphics settings; measure both emulated FPS and delivered
images/s in diagnostics. Host ARM64 tests cannot prove iOS TXM compatibility
or guarantee any performance benefit.
