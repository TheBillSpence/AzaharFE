# AzaharFE iOS JIT runtime: architecture plan

Experimental branch: `ios-jit-experiment`. Stable `master` stays unchanged.
Target: iPhone 11 Pro Max / A13 / iOS 27.2.1, StikDebug universal.js.

## Baseline, not assumptions

- Ocarina of Time 3D boots using CPU JIT OFF (interpreter).
- A 16 KiB native ARM64 test executes and returns 42 with RW/RX mapping.
- In Build #24, Dynarmic completes 512 steps, multiple continuous runs,
  3DS SVC 0x21 (CreateAddressArbiter), and full run 79.
- Full run 80 enters at PC 0x0041A4AC. Completed scheduler slices remain
  at 591 at both the 3-second and 10-second checks. The first frame is
  still missing. This is our repeatable regression checkpoint.

## What we learned from ARMSX2 (design, not MIPS code)

Reviewed `ARMSX2/ARMSX2`:
- `platforms/ios/Runtime/SceneDelegate+VMThread.mm` isolates ownership
  of the VM thread and checks executable-memory readiness at idle points.
  It does not rewrite active JIT code from a competing thread.
- `pcsx2/arm64/iR5900-arm64.cpp` charges guest cycles before host-call
  / event exits, cooperatively honors host pause/stop requests, and
  reloads guest state after host callbacks change scheduling state.
- `tests/ctest/core/recompilers/ee_rec_timeout_loop_tests.cpp` uses
  JIT-versus-interpreter comparisons for self-loop and timing behavior.

ARMSX2 recompiles PS2 MIPS instructions. Azahar uses ARM32 Dynarmic;
transplanting PS2 ARM64 emitters would be wrong. Our new glue is Azahar-
specific code, not a copy of GPL-protected implementation details.

## Proposed end-state

Apple debugger JIT grant / TXM executable mappings
  -> AzaharFE JIT runtime (owned by our iOS frontend + Azahar core)
  -> Dynarmic compiler (guest ARM32 -> host ARM64)
  -> bounded execution slices + kernel scheduling + video

The runtime is responsible for: executable-code arena lifetime, explicit
RX/RW cache coherency, start/stop and abort requests, per-core budget and
event accounting, diagnostics, and reproducible correctness tests.
Dynarmic remains the guest instruction translator until there is
specific evidence that its code generator is wrong.

## Phase 1: safe exit and controls (Build #25)

Track active Dynarmic full-run objects in a mutex-protected registry.
Expose an optional C ABI symbol `azahar_jit_request_halt` on the iOS
libretro dylib. A front-end Stop button calls it, and a first-frame
watchdog calls it if completed scheduler slices are identical at 3s and
10s. It uses the supported Dynarmic `HaltExecution` flag, not forced
thread cancellation. The registry never holds a mutex while generated
instructions run, and the dylib stays loaded during the call.

Acceptance test: with the same ROM and JIT ON, if run 80 is stalled,
the log should show the host safe-exit request and possibly the run
returning (its return reason is now logged). If run 80 still does not
return, we know the halt condition is not being reached; that is
diagnostic evidence, not proof that every guest block is incorrect.

## Phase 2: validate run 80 against the interpreter

Capture a small deterministic checkpoint at run 79/80: PC, CPSR, GPRs,
remaining ticks, call return status, and memory-page generations.
Replay the same guest execution in JIT and interpreter, compare
registers and selected memory ranges, and identify the first
divergence. Never put game/ROM contents, keys, or device identifiers in
diagnostics. Add a regression test reproducing the divergent code path.

## Phase 3: own the iOS code-memory layer

Factor the iOS JIT arena out of per-build upstream Oaknut patch logic.
Give it strict allocate/remap/flush/patch/release invariants.
Test branch targets, relinking, guest self-modifying code, and CPU cache
invalidation with separate writable/executable aliases. Only validate
JIT eligibility while no generated code is executing.

## Phase 4: correct scheduling; then recover performance

Remove artificial 512-step and staged 64..262144-cycle diagnostics.
Give generated blocks predictable safe exits with correct timing;
ensure guest kernel calls never consume a full frame without yielding.
Confirm a first frame, responsive controls and reliable stop. Restore
block linking and fast dispatch only after regression tests pass.

## Safety / constraints

No `master` edits. No claim that a green CI build proves on-device JIT.
No live JIT-to-interpreter switch inside a generated execution stack.
`HaltExecution` is cooperative: if native code is truly uninterruptible,
the user may still have to relaunch the app.

## Build #26 evidence-based next experiment

The previous test's watchdog fired but run 80 did not return. The
cooperative halt request is not proof that it reached a registered
JIT, and even a delivered request cannot interrupt an ARM64 function
which does not observe a halt condition. Build #26 acknowledges both
layers, and executes run 80's next 1,024 guest instructions one by one
through Dynarmic's separate JIT Step() path. The first non-returning
step localizes the transition; if all return, the next comparison is
normal Run dispatcher and longer guest blocks. Prefer reproducible
JIT/interpreter state comparisons before replacing the code generator.
