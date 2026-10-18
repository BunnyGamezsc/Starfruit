# Starfruit review and upstream integration — 2026-10-17

[Final local merge-readiness check](merge-readiness.md): Starfruit 1.1.0
(build 2), Sparkle 2.10.0, passing local regression suites and a verified
BunnyGamezDev-signed universal app/archive. Builds remain local only.

The integration preserves every original fork commit and merges all 194 commits
from Floogen/Stardrop development through `9c5e145bf55af07cd735cfadbc65c5aa5309fef4`.
The PR combines its Starfruit work into one integration commit while keeping
the 194 upstream commits separate and unchanged. The original fork head remains
`95da4f8de90ed706a1a9a00020157872c56d1877` on local `development` and the backup
branch. All integration and native changes belong to
`codex/starfruit-upstream-native-modernization`.

## Review basis

The review used independent GPT-6.1 Sol agents with high reasoning. The initial
diff is `git diff fdea35d4f97870a0deb83fb28c5f014184318307...95da4f8de90ed706a1a9a00020157872c56d1877`.
The review also includes the existing uncommitted native implementation, the
upstream integration, and an independent audit of the new native work.

There was no formal issue/specification. The Spec axis uses the detailed
`5443fd7` feature commit, the repository README, and upstream behavior as a
reconstructed specification. No tracker was configured for the skill; its
optional tracker setup command is `/setup-matt-pocock-skills`.

## Standards

[Baseline report](standards.md): **zero documented-rule violations, three
possible design smells**. These are judgment calls, not hard violations:
duplicated manifest readers, repeated installation/settings parameters, and
primitive parallel trigger state. The port consolidates manifest/archive
handling and guards invalid trigger values; the remaining naming/type-design
opportunities are maintenance work, not release blockers.

## Spec

[Baseline report](spec.md): **two outstanding behavior defects identified and
fixed**: collection copies could leak into normal launch staging, and failed
archive extraction could be reported as an installed download. Source-aware
profile resolution and checked, throwing installation now cover those paths.
Two additional historical collection defects were already corrected in the
uncommitted implementation before this integration.

## Correctness and final audit

[Baseline correctness review](correctness.md) records native Keychain migration,
hotkey release/lifecycle, download failures and historical desktop Wine issues.
The native fixes are included. The desktop C# Wine-only launch behavior remains
a recorded historical issue; the native Swift launcher has separate Wine and
native paths.

[Final independent audit](final-audit.md) verifies all eight initial new-port
findings and follow-on fixes, including revision/config preservation, add-on
folder collisions, storage-move locking, copied-profile replacements, and
manual downloads retaining their original destination after profile changes.
No unresolved actionable finding remained in that audit's assigned scope.

## Features ported to the native app

[Automatic upgrade migration](automatic-upgrade-migration.md) describes the
subsequent first-launch import for older Starfruit installations, its backups
and retries, and the handling of installed collections with unknown revisions.

[BunnyGamezDev signing](signing-and-updates.md) records the subsequent
certificate-signed universal build, dedicated Sparkle key and signed archive
validation, matching Tokscale's macOS signing setup.

[Commit-by-commit changelog with authors](upstream-changelog.md),
[all 194 raw commit subjects](upstream-commits.txt), and the [feature inventory](upstream-feature-inventory.md)
provide the upstream audit trail. The inventory's numbered gap descriptions
are the **pre-port baseline**, followed by ownership/status notes; the current
implementation is summarized here:

| Area | Native implementation |
| --- | --- |
| Collections | Durable records, authoritative collection archives/indexes, exact file pins, optional files, bundled/direct/manual sources, rules and overlays, per-entry progress/errors, checksum recovery, cancellation, revision updates and unchanged payload reuse |
| Isolation and lifecycle | External revision storage, source-aware profiles, protected primary profiles and editable copies, config/add-on preservation, dependent-profile checks, keep-files conversion and safe folder relocation |
| Collection interaction | Management screen, sorting/missing filter, batch missing links, archive drops, latest-revision checks on connection, extra-mod destination choice and staged SMAPI pinned-update suppression |
| Profiles | Notes, manual/automatic saves, native/upstream portable profile metadata, enabled/disabled/missing entries, configuration inclusion and restoration, source links and missing-mod recovery |
| Updates | Exact-version ignore/unignore, raw update availability independent of profile ignores, global loose-mod checks, validated suggested update links and Nexus changelog viewer |
| Native interface | Persistent column visibility/order, filtered bulk enable/disable, NXM association management, inherited JSON theme overrides and live reload, discovered bundled translations including Dutch/Bulgarian |
| Installation/build | Checked archive staging and rollback, ZIP/TAR-family/7z/RAR dispatch through macOS libarchive, HTTP/extraction errors, cancellation, input helper fixes, standalone source exporter, local build/test scripts, universal macOS packaging and fork-owned Sparkle feed |

Translations fall back to English for native-specific text absent from the
upstream catalogs. macOS's extractor reports unsupported/encrypted formats as
installation failures rather than silently marking them installed.

## Validation

- Merged desktop Release build: passed, zero errors and 231 warnings.
- Core collection/profile/archive fixtures: 78 assertions against the actual
  model, reference-matching and storage sources using temporary directories.
- Mocked Nexus fixtures: changelog order, revision/mirror parsing, credential
  boundaries, HTTP and GraphQL errors.
- Download fixtures: custom installation, failure/cancellation/cleanup,
  destination preferences and preserved manual queue context.
- C callback fixtures: exact releases, synthetic-event exclusion, modifiers,
  Fn and stop-before-start; no keyboard/mouse events are posted.
- Theme fixtures: import, default inheritance, live reload, invalid-save
  recovery, export and reset.
- Final standalone universal app and SMAPI wrapper: both arm64/x86_64 slices
  compiled with a macOS 13 minimum; strict deep signature verification passed.
  All 17 language dictionaries are packaged in the app.

The fixtures do not constitute live Nexus/game/UI acceptance testing. No test
launched the app, changed real Mods/profiles/Keychain/Accessibility state, or
posted input. The core fixture suite does not directly instantiate the full
ModManager/CollectionManager lifecycle; that code also received source review.

## Independent maintenance

The native build does not compile the adjacent C#/Avalonia tree. The
[native README](../../../Stardrop/StardropMacNative/README.md) documents a
native-only source export including required resources, tests, license and
provenance. Keep the combined repository as the history archive, and use that
export for a separate native repository if desired. No remote was removed.

The original 27 uncommitted files were backed up outside Git before integration.
Unrelated scratch directories and generated binaries are excluded from the PR.

Standards: 0 hard violations / 3 heuristics, most consequential trigger-state
risk guarded. Spec: 2 baseline behavior findings, both fixed; collection
isolation was the most consequential within that axis.

## Local builds only

At the owner’s request, GitHub Actions workflow definitions were removed on
2026-10-18. Builds, regression checks, BunnyGamezDev signing and Sparkle archive
preparation run locally. Earlier CI results in these review notes are historical;
standalone exports no longer copy workflow configuration.
