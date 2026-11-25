# SUPER-EXPERIMENTAL — disposable iOS branch

Base: ios-jit-experiment build #81 source (f9047f2f686ab30c545baf05b37496c55fe8d01b). Never merge blindly into master or ios-jit-experiment. This branch is independently deletable. The dedicated workflow builds exactly one unsigned iPhone IPA with a separate app bundle identifier (com.thebillspence.azaharios.superexperimental); sideloading may rewrite the identifier, so confirm before installing and back up saves. Import a copy of the ROM/saves if needed.

## Automatic (SUPER JIT)
- CPU JIT, existing guarded 4 GiB Fastmem, fast dispatch, block linking, return-stack prediction, existing primary 128 MiB / secondary 32 MiB caches and startup safety probes.
- Existing ARM64 vertex shader compiler enabled only when CPU JIT is authorized. Adapted to Oaknut RW/RX aliases, session-owned 2 MiB slabs with a 32 MiB pool limit, fallback to shader interpreter when allocation throws bad_alloc.
- Restricted native fragment compiler for six-stage identity RGBA Replace/Modulate chains, same RGB/alpha sources and unity scales, no constant or combiner-buffer reads. Unsupported states use existing full TEV implementation; allocation failures negative-cached. Each newly generated program checks eight packed-color test vectors before publication. This is not a general fragment compiler.
- Optimized software rasterizer uses existing persistent workgroup, early depth rejection, tile traversal (8x8 within one primitive), exact four-pixel NEON coverage rejection. Primitive barrier retained; not a deferred tile-binning renderer or full SIMD shading pipeline. Non-JIT optimizations remain available with JIT Off.
- Vulkan via MoltenVK and Software remain separately selectable; Vulkan is experimental.
- Preserves second-launch teardown gate from #81. Shader pools are session-owned, not a process-wide CPU JIT memory pool. Full cross-session CPU pool, expanded Fastmem alias coverage, full fragment compiler, deferred tile binning, full SIMD pixel pipeline, and parallel guest CPU execution remain future work. No unsafe timing or monitor bypass.

## Test plan
Workflow: SUPER-EXPERIMENTAL IPA. Host input/preset tests and raster workgroup regression run before iOS compilation. Runtime markers SUPER27 identify shader allocation, first compiled vertex shader, native fragment self-test, or fallback. The JIT memory patch remains pinned to the existing Oaknut/Dynarmic versions. Green CI does not prove the phone can execute new shaders or restart safely.

Back up saves. Start with Software, 1x, Automatic (SUPER JIT), optimized rasterizer, profiling on. Compare with JIT Off and advanced shader JIT Off. Capture current and previous logs if frozen. Record graphics corruption and sustained FPS in the same scene. No device tests or performance claims yet.
