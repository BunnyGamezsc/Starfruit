# Automatic upgrade migration

Added to PR #1 on 2026-10-18.

Older native Starfruit stores its data in `StarfruitNative` and its preferences
under `com.starfruit.macnative`; older desktop editions also have individual
profile JSON files. The previous migration copied some files but did not parse
those desktop profiles into the active native profile array, could silently
ignore copy failures, and required manually reimporting collections.

The version-three migration now runs before app managers initialize. It merges
old native profiles/presets, decodes older desktop profiles and configurations,
bridges known desktop launch/save settings, retains selected native UUIDs and
resolves unambiguous desktop selected profile names after import. New destination
preferences and existing native profile contents win conflicts. Different older
desktop profiles with the same name are kept as separate `(Imported)` copies.
Old migration completion markers do not skip this new migration.

The file importer uses atomic writes, original-file backups and a per-source
journal. Stable IDs prevent duplicates even if a process stops after writing
profiles but before recording progress. Failed/corrupt inputs remain retryable;
unreadable destination data is never treated as empty. ModManager also refuses
to overwrite unreadable profile or preset stores. Credential migration has its
own completion stage so unrelated file failures do not repeatedly restore a
login the user subsequently logged out of. NexusClient preserves an older
fallback credential while secure migration is blocked, and explicit logout
removes that fallback.

Legacy collection metadata is imported during the normal mod scan. Existing
folders, mod versions and configurations remain untouched. A local imported
copy is distinguished from an authoritative Nexus revision; no revision number
or exact file ID is invented. Known profile-to-folder relationships are linked
automatically, while ambiguous copies require the user to choose. A subsequent
reviewed Nexus update uses managed external storage while retaining the original
copy during staging. Corrupt existing catalog records and intentionally
detached collections are respected.

Settings includes import status and a retry action. Existing configured users
without an explicit onboarding choice do not have to repeat initial setup.

Ambiguous legacy selections block launch until resolved. The UI also refuses
to launch if profile staging fails, instead of falling back to the ordinary mod
directory and bypassing the selected profile.

Validation: migration fixtures cover 60 assertions against actual file/model
code, using temporary directories and pure preference dictionaries. Cases
include old profile/preset import, missing/disabled metadata and configs,
UUID/selection retention, preference conflicts, credential-field exclusion,
interrupted journals, partial retries, unavailable backups, corrupt destination
data, legacy installed copies, ambiguous sources and pending-revision paths.
Existing core, Nexus, input, download and theme suites also pass. No test reads
real user defaults/Keychain or changes actual game mods. Live OS Keychain grants
and an interactive upgrade remain acceptance checks rather than fixture claims.
