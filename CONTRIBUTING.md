# Contributing

Thanks for testing Solo+.

## Issues

Please include:

- Device model, iOS version, jailbreak type (RootHide / rootless / other)
- Solo version (must be 1.0.1)
- Whether Atria is installed and its version
- The relevant `[Solo+]` lines from Solo's debug report
  (`dock`, `carousel fill`, `auto-evict`, `panel load`)

## Pull requests

- Keep one logical change per PR; avoid mixing unrelated formatting.
- Do not commit Solo/Atria binaries, `.deb` packages, decompiled dumps, or device logs.
- Build with `build.sh` and make sure the arm64e assertion passes:
  `isa: auth>0 plain=0`.
- Avoid adding owned Objective-C classes or captured blocks unless the build has been
  validated with an Apple toolchain; the local clang19 line is for pure swizzles and
  syntax checks.
