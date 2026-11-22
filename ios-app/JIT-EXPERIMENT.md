# Experimental JIT + FPS (separate branch)

The stable, playable IPA built from master is unchanged. This branch builds a separate
app with a different bundle identifier (com.thebillspence.azaharios.jitexperiment).
It has separate Documents storage, so import game files again for testing.

The optional JIT switch defaults to OFF. To try it, first enable JIT for this
specific app through a compatible external method, then opt in with "JIT OFF" in
the game library. The host probes executable memory mappings before reporting
JIT capability to Azahar's libretro backend. This is ONLY a mapping-permission
check. A passing test does not guarantee Dynarmic can generate/execute code on
your iOS version; it may crash. Turn the switch back off after a crash, or
return to the stable app.

The FPS readout counts libretro game-loop calls per second. It does not measure
GPU utilization or guarantee equivalent full-speed emulation.

Graphics remain software-rendered. Audio and touchscreen input are not yet
implemented. The action produces an unsigned IPA requiring normal code-signing.
