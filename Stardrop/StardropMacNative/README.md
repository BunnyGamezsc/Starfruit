# Starfruit for macOS

Starfruit is the native SwiftUI macOS application. Its executable is built from
`Sources/`; it does not compile or load the adjacent Stardrop C#/Avalonia project.
The Stardrop source is useful as upstream history and a feature reference, but
is not a runtime dependency of the native app.

## Build

Install Apple's Command Line Tools and GitHub CLI (`gh`), then build with
`bash build-native.sh --build-only`.
The first build downloads Sparkle 2.10.0 into `.deps/`, verifies its pinned
SHA-256 and replaces an outdated cached framework. The script produces
`Starfruit.app` in this directory. Build-only mode does not install or open it.
The default signing identity is `BunnyGamezDev`, matching Tokscale. The build
requires that certificate in Keychain and stops if it is missing or ambiguous;
it never silently substitutes an ad-hoc signature. `SIGN_IDENTITY` can also be
an exact certificate name or SHA-1 fingerprint. Use `SIGN_IDENTITY=-` explicitly
for local development ad-hoc signing. Running the script without
`--build-only` retains the existing install-and-launch behavior.

The app supports macOS 13 or newer. The build uses the host architecture by default;
set `BUILD_ARCHS="arm64 x86_64"` to create a universal macOS app.
Distribution builds should provide increasing `APP_VERSION` and `APP_BUILD`
values (the current defaults are 1.1.1, build 3).
The public update key is read from `sparkle-public-key.txt` and embedded
as `SUPublicEDKey`; `SPARKLE_PUBLIC_ED_KEY` can override it for another channel.
The default feed is the `appcast.xml` asset of the latest Starfruit GitHub release.
`SPARKLE_FEED_URL` can select a different update feed.

Run `bash Tests/run-regressions.sh` for isolated collection/profile/archive,
mod Trash/restore, mocked Nexus, input-callback and theme regression fixtures. They do not launch
the app, post input events, access real Nexus credentials, or modify game mods.
Trash fixtures move only uniquely named temporary mod folders to the macOS Trash
and clean them up afterward.
Builds and regression checks run locally. This repository has no GitHub Actions
workflows, and standalone source exports do not include CI configuration.

## Signing Sparkle releases

The app certificate and update archive signature are separate, as in Tokscale:
`BunnyGamezDev` signs the app, SMAPI wrapper and embedded Sparkle components.
Sparkle's Ed25519 key signs the downloadable archive. Starfruit uses its own
Keychain account, `com.bunnygamez.starfruit`, rather than Tokscale's update key.
Only the public update key is committed; neither private key is exported.
Preserve this Keychain item across releases; do not regenerate it for each build.

Build with `BUILD_ARCHS="arm64 x86_64" APP_VERSION=VERSION APP_BUILD=BUILD bash build-native.sh --build-only`.
Package `Starfruit.app` with `ditto -c -k --sequesterRsrc --keepParent`, then run
`bash generate-appcast.sh /path/to/archives https://github.com/BunnyGamezsc/Starfruit/releases/download/vVERSION/`.
The generator uses Starfruit's Keychain account and refuses to sign if its
public key does not match the configured app key. `SPARKLE_KEY_ACCOUNT` can
select another account when intentionally using a different key/channel.

Upload the signed archive and generated `appcast.xml` together when publishing
that version. These scripts only build/package/generate; they do not publish a
release. The checked-in appcast is a placeholder, not the release feed.

`BunnyGamezDev` is a self-signed certificate, not an Apple Developer ID or
notarization. Its use matches Tokscale; it does not change Gatekeeper policy.

## Removing mods

Right-click an ordinary mod and choose **Move to Trash…** to review which profiles
enable that installed copy before removing it. The entire folder, including its
config, moves to the macOS Trash. Profile selections and notes remain intact.
The Mods screen offers **Undo** for each removal in reverse order during the
current app session. Undo restores the original folder and refuses to overwrite
a replacement installed at the same location. After quitting Starfruit, recover
the folder from Trash in Finder instead. Moving or restoring mods requires the
game to be stopped; collection mods and SMAPI's built-in mods are protected.

## Translations

The native app bundles independent JSON dictionaries in `Resources/i18n`.
`sync-localizations.py` imports the adjacent Stardrop dictionaries when working
in the combined repository. A standalone export already contains those resources
and does not need the C# tree to build. Native controls look up matching upstream
English text and fall back to English where a translation is unavailable;
this is not a claim that every native-specific sentence has been translated.

## Upgrading from older Starfruit

The first launch imports older native preferences, profiles, presets and Nexus
credentials before creating the app's managers. Existing data in
`Application Support/StarfruitNative` remains usable. Older profile arrays and
desktop profile files under Starfruit/Stardrop data folders are detected
automatically, including the earlier desktop `.config` location. Known desktop
Wine/SMAPI paths, manual-save preferences and last-profile selection are bridged
to their native equivalents. Existing destination settings and profile edits
take priority.
An older desktop profile with a conflicting name is preserved as a separate
`(Imported)` copy rather than replacing the current profile.

Profile files are backed up under
`~/Library/Application Support/StarfruitNative/MigrationBackups/v3` before
rewriting them. Original import sources and old Keychain entries remain intact.
Completed file imports are recorded so retries do not create duplicate profiles
or resurrect profiles deliberately removed later. Failed imports retry on a
future launch; Settings → Data Migration also provides an explicit retry.
Unreadable destination profiles/presets/collection records are preserved rather
than replaced with empty/default data. Keychain permission failures remain
retryable; the old credential is not discarded before a secure copy exists.

Installed native collections under the game's `Mods/Collections/<slug>` are
recognized on the first mod scan. They appear as imported installed copies and
continue using their original files without moving or downloading mods. Old
Starfruit did not record exact Nexus revisions/file pins, so the UI labels that
metadata as unknown. Reviewing a known Nexus revision stages its replacement
separately, with the old copy remaining playable until the update succeeds.
Original legacy files remain in place.

When several old collections could match the same profile's enabled IDs, the
app retains all copies and does not guess which version was intended. Use the
Collections screen's **Use Installed Copy** action to choose the correct copy.
Migration status and any incomplete steps are shown in Settings.

## Maintain Starfruit independently

Keep this combined repository and its backup branch as the historical archive.
Run `python3 export-standalone.py /path/to/a/new/Starfruit` to create a native-only
source folder containing the Swift/C sources, resources, build scripts, license,
and provenance. The destination must not exist. The export excludes build
products, credentials, `.deps`, and the C#/Avalonia application.

Initialize a new Git repository in that exported folder when ready. It can have
its own remote and releases without tracking Stardrop development. Retain
`LICENSE`, source copyright notices, translation credits, and `UPSTREAM.md`.
The original four fork commits and all upstream history stay in this repository;
the source export deliberately does not rewrite or remove that history.

Removing the existing `upstream` remote only removes a remote name; it does not
make the current repository native-only. An independent source export is the
cleaner maintenance boundary for this Swift app. No remote has been removed.
