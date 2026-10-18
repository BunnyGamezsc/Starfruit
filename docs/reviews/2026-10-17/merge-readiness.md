# Local merge readiness — 2026-10-18

Starfruit 1.1.0 (build 2) was built locally from the final native sources for
Apple Silicon and Intel, with a macOS 13 minimum. The existing installed
application was not replaced or launched.

The build now pins Sparkle 2.10.0 and its official GitHub release asset SHA-256.
It verifies downloads before replacing cached dependencies, and refreshes an
older cached framework instead of silently continuing to use it. GitHub CLI
downloads the dependency; compilation and signing happen on this Mac.

Local validation passed:

- Full native regression runner: 78 collection/profile/archive assertions,
  60 migration assertions, and the mocked Nexus, download, C input-callback
  and theme suites. The download fixture has an existing SDK deprecation
  warning; it does not fail the suite.
- Both app and SMAPI wrapper architecture slices and macOS deployment targets.
- BunnyGamezDev leaf certificate matching on all nine app/wrapper/Sparkle
  executable components, plus strict verification across all architectures.
- Embedded Starfruit public update key, Sparkle 2.10.0, and 17 translations.
- ZIP creation, Sparkle Ed25519 archive authentication and strict verification
  of the app after extracting the ZIP. A SHA-256 sidecar and validation JSON
  accompany the local package.
- Standalone source export, shell syntax and changed-file whitespace checks.
  The export contains local build/tests/signing inputs and no CI workflows.
- Original fork head `95da4f8` and upstream head `9c5e145` remain ancestors.
  The PR branch contains its current development base and had no unresolved
  review threads or merge conflicts at the readiness check.

The app is `Stardrop/StardropMacNative/Starfruit.app`; the local archive,
appcast, checksum and validation JSON are under
`Stardrop/StardropMacNative/.build/releases/1.1.0-build2/`. These generated
artifacts are ignored by Git. No release or hosted update feed was published.
GitHub Actions remains disabled, and no workflows are tracked.

These checks do not claim live Nexus/game/UI or interactive-upgrade acceptance.
The earlier merged desktop Release build remains valid; the subsequent changes
only affected native sources, build/signing tooling, documentation and workflows.
