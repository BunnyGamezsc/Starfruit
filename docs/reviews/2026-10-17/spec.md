# Starfruit Spec review — provisional commit-message specification

Scope: `git diff fdea35d4f97870a0deb83fb28c5f014184318307...95da4f8de90ed706a1a9a00020157872c56d1877`, four fork commits. Read-only inspection also compared the dirty native working tree. No external issue or formal product specification was supplied. Requirement quotations below are from the body of commit 5443fd7; README says profiles allow multiple mod groups for gameplay or multiplayer. These findings must be labelled commit-message/spec inferred, not formal issue compliance.

## 1. [P2] Apply profile collection filtering when staging enabled mods

**Requirement:** “Add profile-based filtering so normal profiles ignore mods located in `/Collections/` subfolders, while collection profiles expose all mods.” Also “Add isolated directory structure (`Mods/Collections/{collectionSlug}`) to extract modpack files without interfering with base game profiles.”

**Committed location:** `Stardrop/StardropMacNative/Sources/ModManager.swift:467`–472; tight review span 467–470.

`filteredMods` hides collection copies only in the list (108–118). `loadMods` discovers all copies (482–529); `prepareProfileForLaunch` instead iterates the entire `mods` array and checks `isModEnabled` by UniqueID. With `/Mods/Shared-v2/manifest.json` and `/Mods/Collections/pack/Shared/manifest.json` both declaring `Author.Shared`, enable the root mod in a normal profile and Play: both pass the enabled-ID predicate and are linked into staging even though the collection copy is invisible in the profile. This violates isolation and can cause SMAPI duplicate-ID failure or wrong-version loading. With matching leaf names the second symlink instead fails, so source order determines which version wins. Collection profiles suffer the same ambiguous version selection when multiple packs contain the same ID.

**Working tree:** still present at `ModManager.swift:624`–629. The new `uniqueStagingName` prevents basename collision but deliberately gives the second copy another name, making both copies load. `linkedSources` deduplicates paths, not UniqueIDs. Apply the selected profile’s directory policy to staging, and define one source per UniqueID when multiple versions are installed; preserve logical-ID selections separately.

## 2. [P2] Report archive extraction failure instead of a completed installation

**Requirement:** “Implement automated downloading and installation of Nexus Mods Collections (modpacks) via `nxm://stardewvalley/collections/{slug}/revisions/{id}` deep links using the Nexus Mods v2 GraphQL API.”

**Committed location:** `Stardrop/StardropMacNative/Sources/ModManager.swift:558`–563 and `Stardrop/StardropMacNative/Sources/DownloadManager.swift:142`–149.

The installer launches `/usr/bin/unzip` and waits without checking `terminationStatus`. Nonzero exit is not a thrown `Process` error. `installMod` returns Void, and the download delegate unconditionally removes the archive and sets `isCompleted = true`, including when the installer catches an executable launch error. Reproduction with a small invalid ZIP under a unique temporary fixture: the exact `/usr/bin/unzip -o -q archive -d destination` invocation exits 9, creates no destination, and the code still follows its success path. A corrupt collection download, CDN HTML/error payload, or non-ZIP archive is reported as “Download and extraction complete”; there is no surviving archive to retry. Check HTTP/extraction status, propagate installation result, retain retry data, and mark complete only after successful extraction.

**Working tree:** unresolved. Installer unchanged in this behavior at `ModManager.swift:743`–747; DownloadManager is unmodified from HEAD.

## Committed defects already repaired by dirty native changes

### 3. [P2] Remove the hardcoded production collection dry run

**Requirement:** same automated collection download/installation requirement quoted above.

HEAD `ModManager.swift:674`–678 returns immediately for slug `tckf0m`, after creating an empty collection profile; ordinary external deep links and the debugger share this handler, so this real collection can never install. The commit message does not specify this exception. **Working tree already removes it. Do not report as outstanding against the dirty checkout.**

### 4. [P2] Surface GraphQL application errors before creating a profile

**Requirement:** same automated collection download/installation requirement quoted above.

HEAD `ModManager.swift:806`–809 decodes only optional `data`, substitutes an empty mod-file array, and returns success for HTTP-200 `{"errors":[{"message":"permission denied"}],"data":null}`. Handler creates/selects an empty profile and logs a successful fetch of zero files. **Working tree adds GraphQL errors decoding/throwing at 1103–1106. Do not report as outstanding against dirty checkout.** A null collectionRevision with no errors still maps to empty success, but no independent finding is asserted without an observed API response.

## Validation boundaries

No app launch, network API call, real profile write, keychain access, or credential changes were made. Invalid-archive behavior reproduced in a temporary fixture. Source walkthrough establishes the launch-path filtering mismatch. An isolated Swift staging-method harness was prepared under a unique temporary directory and is tracked separately until its compiler finishes; do not imply an app-level end-to-end test passed.
