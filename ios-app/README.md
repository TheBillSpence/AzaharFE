# Azahar iOS experimental frontend (prototype)

This is an **experimental, unsigned iOS frontend** that attempts to run the fork's
existing libretro core with its **software renderer**. It is not a finished 3DS
emulator for iPhone, and passing CI alone does not prove gameplay works.

## What is implemented

- A UIKit iPhone app with Files import and a persistent Games folder.
- A libretro host using the existing iOS libretro dynamic library.
- Software video-frame display and A/B/X/Y, D-pad, L/R, Start/Select buttons.
- A separate worker-thread emulation loop.
- An unsigned IPA produced by GitHub Actions for signing/sideloading externally.

## Not implemented / still requiring device validation

- **JIT is reported unavailable** to libretro until device permissions and
  Dynarmic executable-memory behavior are actually validated.
- Audio is currently muted. Touchscreen/pointer, analog sticks, and motion
  input are not implemented. This can block games.
- No benchmark, compatibility claims, crash recovery, save-state UI, or
  on-device gameplay test exists yet.
- The app loads a bundled .dylib using dlopen; iOS requires that all embedded
  code is properly signed by the installation tool. IPA packaging doesn't sign it.
- Encrypted games, CIA installations, and game assets are not included.
- The core and this frontend are GPL-covered; follow the repository's
  licensing requirements when distributing modified binaries.

## Build

Trigger "Azahar iOS Experimental Frontend" in Actions or commit a change under
ios-app/. The workflow:
1. Generates the Xcode project with XcodeGen, and compiles the UIKit app.
2. Builds the Azahar libretro backend for iOS ARM64 (software renderer).
3. Bundles the dylib inside AzaharIOS.app/Frameworks.
4. Packages and structurally checks an unsigned .ipa.

The IPA artifact is for testing after signing with a compatible iOS sideloading
tool. The artifact is *not* automatically signed or installable as-is.

The earlier "iOS ARM64 Core Build and Validation" workflow is unchanged.
