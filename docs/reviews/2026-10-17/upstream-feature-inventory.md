# Native Starfruit parity inventory for all 194 upstream commits

> Historical baseline: this audit was written before the native port. Its
> missing/partial labels describe the old app. See [the final implementation
> summary](README.md#features-ported-to-the-native-app) for completed behavior
> and [the authored changelog](upstream-changelog.md) for all 194 upstream commits.

Scope: committed upstream range fdea35d4f97870a0deb83fb28c5f014184318307..9c5e145bf55af07cd735cfadbc65c5aa5309fef4, compared with current dirty `Stardrop/StardropMacNative/Sources`. All 194 subjects were read from `/tmp/starfruit-upstream-commits.txt`; merge commits, releases, translation edits and CI revisions do not each represent a separate product feature. Source evidence refers to the merged desktop tree `Stardrop`; native evidence refers to `Stardrop/StardropMacNative`.

A git merge preserves upstream C# changes, but none of those C# classes is compiled by build-native.sh. Native parity requires Swift implementations and visible native controls. Current native has basic collection NXM fetching, individual downloads, dependency checks, profiles/presets, custom JSON sharing, SMAPI update checking, native/Wine launch, and native-only input helpers. Those are useful foundations, not full parity.

## Priority 0: collection data and installation correctness

1. **Durable collection model and cache: missing.** Persist slug/domain/sourceID, installed/target/latest revision, collection/profile linkage, curator/summary/instructions, per-entry exact file pins, optionality, source type, checksum, size, phase and status/failure reason. Native ModProfile only has name, UUID, enabled IDs and isCollectionProfile; collection metadata disappears after queueing. Evidence: upstream Models/Data/CollectionInstall.cs, Utilities/Internal/CollectionCache.cs; native ModManager.swift:4-27, 891-1035. Commits 00bda2b, ce15498, bb77f12. Acceptance: reopen app after partial install; identify exact remaining entries and resume the same collection rather than create another profile.

2. **Collection archive/index ingestion: missing.** Fetch collectionRevision metadata/downloadLink, download its archive, read collection.json, use bundled files, bundled directories, non-Nexus direct/manual sources and curator settings. Native fetches GraphQL modFiles only, which cannot contain bundled configs or full rules. Evidence: upstream NexusClientCollections.cs:28-193, Models/Nexus/CollectionIndex.cs, MainWindowCollections.cs:348-460, 988-1241; native ModManager.swift:1047-1109. Commits 802b0a1, a120e49, 13974dd, d8783d0. Acceptance: a collection with bundled mod/config installs all intended content, not just Nexus mods.

3. **Separate collection install root: missing.** Collection copies live outside the normal game Mods directory, configurable independently; create default root on startup; keep metadata in fixed application data location. Native puts Collections/slug under ordinary Mods, exposing duplicate IDs to unmanaged SMAPI launches. Evidence: upstream Pathing.cs:140-178, Models/Settings.cs:18-25; native ModManager.swift:959-960 and 727-736. Commits ce15498, 8b6b2b7, 595ddc8. Acceptance: launching SMAPI directly does not scan both ordinary and collection copies.

4. **Mod identity including collection source: missing.** Use a stable entry/reference identity `(UniqueID, SourceID)` or path-aware equivalent, so local copy and copies from separate collections coexist in UI and profiles, but only one copy of an ID is enabled in one launch. Native ModEntry.id == manifest.UniqueID; all references only Set<String>. Evidence: upstream Mod.cs, Models/Data/ModReference.cs, MainWindowViewModel profile filtering; native ModManager.swift:7, 106-110. Commits 97fc6b3, 1cb118f, 6424d61. Acceptance: local v1 and collection v2 of same mod select/launch independently with no duplicate SwiftUI identity and no double-loaded mod.

5. **Ordering, overlays and conflict rules: missing.** Resolve before/after/requires/conflicts references, match tags/file expressions/checksums/logical names, topologically order entries, detect cycles, apply non-manifest overlays to correct target after mod extraction. Native downloads each file independently into same collection folder. Evidence: upstream CollectionInstall.cs:346-477, CollectionReferenceMatcher.cs, MainWindowCollections.cs:540-580, 681-880. Commit cafb7c8. Acceptance: overwrite-rule fixture consistently yields curator-selected winner regardless of download completion order; bundled configs apply.

6. **Atomic cancel and trustworthy install states: missing.** Downloads can cancel; cancellation must skip installing queued archives and clean staging while preserving prior installed revision. Track byte progress/stage/current entry and durable pending/manual/failed/installed/optional/unsupported statuses. Native queue has per-file transport progress but no collection transaction or cancellation; extraction failures are silently completed. Evidence: upstream MainWindowCollections.cs:462-532, 882-940; CollectionModStatus.cs; native DownloadManager.swift and ModManager.swift:726-791. Commits 3251160, bb2cce5, 4f81169. Acceptance: cancel halfway through a collection leaves no partially enabled new collection; failed unzip never counts as installed.

7. **Exact-pinned update exclusions: missing.** Do not report individually updatable collection pins through SMAPI.io, normal update UI or SMAPI's own console checks; provide CollectionsSkipSMAPIUpdateCheck setting. Native sends every mod with UpdateKeys and hardcoded game/SMAPI versions. Evidence: upstream SMAPI.cs:118-122, MainWindow collection filtering and launch skip list, Settings.cs:45-50; native ModManager.swift:798-825. Commits fd9cdcd, 0295492. Acceptance: a pinned collection entry never advertises an ordinary mod upgrade that would break the collection.

## Priority 1: complete collection lifecycle and controls

8. **Collection management UI: missing.** Native sidebar has Mods/Downloads/Settings only. Add installed collections overview and selectable entry table with name/version/status sorting, curator/revision/profile/page links, progress/counts, missing-only filter and install outcome summary. Evidence: upstream CollectionsWindow.axaml and CollectionsWindowViewModel.cs; native ContentView.swift:25-34. Commits 8297f0d, 4d49b3d, 82ce9be, 15b8520, e623c75.

9. **Manual recovery matching: partial.** Native can resume a queued manual file by modID/fileID, but state is transient; ZIP drag/drop always installs ordinary mods and cannot match pending collection entries. Add durable ID/file-pin and checksum matching; exact manual page links, Open Missing, retry result counts and NXM/plain link preference. Evidence: upstream MainWindowCollections.cs:1371-1458, 1642-1867; native ContentView.swift:75-83; DownloadManager.swift:53-75. Commits 09331b1, 988e6d6, aab0c71, 3bedfef. Acceptance: manually downloaded ZIP after restart satisfies only its matching missing collection entry; unrelated archive does not.

10. **Optional entries: partial/incorrect semantics.** Native filters optional files out entirely; upstream lists them with optional status and supports manual completion without considering optional uninstalled entries required failures. Evidence: native ModManager.swift:947-948; upstream CollectionInstall.GetRequiredPendingCount/GetManualDownloads. Commit 70a1709. Acceptance: optional mods are visible and can be installed individually; collection can be complete without them.

11. **Latest revision checks/update/resume: missing.** Check once per Nexus connection plus explicit refresh; cache newest revision and show update badges/count; apply revisions with Added/Unchanged/Replaced/Removed diff. Preserve disabled-by-user state, notes/configs, renamed profiles and local/add-on mods; preserve working old file on failed replacement; offer deleting orphaned removed entries. Evidence: upstream CollectionUpdatePlan.cs, MainWindowCollections.cs:68-346, 1269-1313, 1581-1640, 1969-2128. Commits 3f98391, d04aae5, 5a7bd8f, 4b95c80, 6074b56. Acceptance: revision update modifies only changed pins and can resume partial target revision; user additions/settings survive.

12. **Collection deletion and dependent-profile handling: missing.** Separate removing record/profile from deleting installed files; detect dependent copied profiles and offer keep/detach/delete coherently. Native only deletes a profile JSON entry, leaving collection files. Evidence: upstream CollectionsWindow.axaml.cs and CollectionsWindowViewModel.GetDependentProfiles; Models/Profile.CopyAsPlainProfile/CopyWithName/DetachFromCollection. Commits 424a4d7, 14d8077, 82ce9be.

13. **Install extra mods into collection profiles: missing.** When collection profile active choose ordinary vs collection destination, with AlwaysAskForCollectionInstallTarget setting; track add-ons distinctly from pinned entries; retain add-ons across revisions. Evidence: upstream MainWindowCollections.cs:1460-1510, Profile.cs SourceId, Mod.IsCollectionAddon; native ordinary NXM install routing. Commits 995501a, 5215f54, b4e7d27.

14. **Robust collection URL parsing: partial.** Native parses NXM collection segments and defaults unspecified revision to 1. Upstream accepts NXM and current/legacy HTTPS collection URLs and asks API for latest revision when unspecified; strict game-domain validation. Evidence: upstream NexusClientCollections.cs:254-311, MainWindowCollections.cs:41-155; native ModManager.swift:891-908. Acceptance: no revision URL installs latest, specified revision installs exactly requested, other game rejected.

## Priority 1: profiles, notes and update experience

15. **Portable profile import/export parity: partial.** Native custom `starfruit.profile.v1` exports enabled mods only, contains no configs/notes/disabled mods, and cannot import upstream ProfileExternal. Add format compatibility or explicit versioned bridge; options IncludeModConfigs, IncludeDisabledMods, IncludeModNotes; richer portable mod metadata/URLs. Evidence: upstream ProfileExternal.cs, ProfileExportWindow.axaml.cs:32-71; native ModManager.swift:120-132,481-502. Commits 3c46021,153615a,5166446. Acceptance: round-trip supported settings/notes/configs and import real upstream export.

16. **Missing mods during import: missing.** Show concrete missing entries with links and offer download/manual add, ignore, cancel; refresh after downloads and preserve selected enabled references. Native silently intersects imported IDs with installed IDs and reports success, losing missing intent. Evidence: upstream ProfileEditor.axaml.cs:107-158, MissingModsWindow, MainWindowViewModel.DirectModInstallAsync; native ModManager.swift:496-501. Commits 35831e5,14f5df4,295cedb,c5227f9.

17. **Per-profile notes/config state and lossless rename/copy: missing.** Add note editor per mod, persist notes and optionally preserved config.json per profile, update save-pending state; rename/copy preserves all state, collection linkage and protected behavior; sanitize file names only if writing name-based paths. Native rename merely changes name in aggregate JSON, so upstream filename sanitization bug does not transfer literally. Evidence: upstream Profile.cs, Mod.Note, MainWindow.axaml.cs note save handler, ProfileEditorViewModel; native ModProfile fields. Commits 3999bdd,94a45e5,f20ebda,b3d0f8d.

18. **Ignore a specific update version: missing.** Store suggestedVersion and ignoredVersion, ignore/unignore toggle, persisted cache, visible ignored marker, suppressed badges; a newer release clears ignore. Native ModEntry has only hasUpdate Bool. Evidence: upstream Mod.cs:128-230, MainWindow.axaml.cs:871-923,2453-2497; native ModManager.swift:106-110. Commits f05b075,0cff35c,2c67182,1dd3256.

19. **Nexus mod changelog viewer: missing.** Fetch Nexus `/changelogs.json`, version-sort entries, loading/empty/error states and mod page link; expose row action/optional column. Evidence: upstream NexusClient.GetModChangelogs:642, ChangelogWindowViewModel.cs, ChangelogWindow.axaml; native no changelog model/view/API. Commits ab79215,5e51e1a,fa955df.

20. **Reactive update states and global actionable-update filtering: partial.** Native shows bool/name tint and status text; retain actual suggested version/update URL and refresh notifications immediately on response, ignore toggle and removal; show all actionable updatable local mods across profile filtering. Evidence: upstream Mod.SuggestedVersion notifications, MainWindowViewModel filtering; native ModManager.swift:854-876 and ContentView row. Commits 34221de,2b03681.

## Priority 2: UI, settings, localization and ownership

21. **Enable/disable visible mods: missing control.** Add bulk actions limited to filtered/current-profile visible entries, retaining core/protected policies and avoiding duplicate IDs. Native has no bulk buttons. Evidence: upstream MainWindow.axaml.cs:2010, GetVisibleMods; native ContentView ModsList. Commit c630c11.

22. **Column visibility/order persistence: missing equivalent.** Native hardcoded Name/Version/Status HStack; support reorder/show/hide for exposed columns, including notes/collection/changelog, restore saved layout and centered headers. Can use a native Table/settings implementation rather than Avalonia column APIs. Evidence: upstream LastSessionData/client cache and grid setup; native ContentView.swift:303-309. Commits a093055,2bd8e3b,fa955df,c69af2c,cbbe1a1.

23. **NXM association management: partial.** Bundle registers `nxm`, but native lacks inspect/register/remove controls and handler conflict reporting. Add macOS LaunchServices equivalent with predictable application ownership. Evidence: upstream Utility NXM handlers and SettingsWindow controls; native build-native.sh CFBundleURLTypes. Commits 96b913a,dde6bbb. Acceptance: user can make Starfruit default and remove its association without modifying another manager's registration.

24. **Custom themes with defaults/live reload: absent native equivalent.** Native supports system/light/dark and fixed Starfruit colors. Upstream user-defined themes inherit defaults, reload without restart and include collection/add-on brushes. Preserve Starfruit defaults; expose native semantic theme overrides/import with fallback/live preview if literal all-features parity required. Evidence: upstream ThemeManager.cs and Themes/Defaults.xaml; native StarfruitTheme.swift/SettingsView. Commits acde5b3,5e61666,b4e7d27.

25. **Discovered locales and translation updates: missing.** Native UI is hardcoded English. Upstream discovers translation files and adds Dutch/Bulgarian, with Polish repair and Chinese/Italian/other updates. Add localization infrastructure and reuse applicable translation data, then native-only strings; do not claim new locales supported until controls actually translated. Evidence: upstream Translation utility, i18n/*.json; native string literals. Commits 152a2e1,15332a3,bf30c94,8205d0e,681397b,99ec2c7.

26. **Mod discovery and safe archive support: partial.** Native enumerates every file, uses one manifest parsing pattern and `/usr/bin/unzip`; upstream prunes traversal once a mod found, caches source identity and supports ZIP/7z/RAR/TAR/GZ/BZ2/XZ via updated SharpCompress. Port behavior using a suitable maintained native extraction backend plus validated staging, not the C# package itself. Evidence: upstream MainWindowCollections archive extensions, discovery and secure SharpCompress upgrade; native ModManager.swift:665-713,726-791. Commits cc66264,9b10bd6,0ea2dbd. Parent correctness report separately covers error handling.

27. **Architecture-aware native packaging/updater ownership: partial.** Upstream adds macOS/Linux/Windows ARM packages and ARM updater selection. Native builds only host architecture, injects Sparkle version/key/feed from environment and defaults feed to Floogen repo. For standalone native product, provide macOS arm64/x86_64 or universal app, own version/build stamping, native release CI, fork-controlled feed and signed appcasts. C# Linux/Windows packaging is irrelevant unless creating those products. Commits 3d0d67d,8518dae,62e6bf5 and release/upload/nightly CI edits.

28. **Dialog ordering/progress interaction correctness: native design requirement.** Upstream fixes dialogs hidden under lock windows, hyperlink wrapping/custom widths, settings layout, safe update workflow overlays. Implement equivalent native sheets/alerts that stay accessible during async installs. These are acceptance requirements, not code to copy. Commits fd0876d,3727a40,87f4cb3,681397b. Preserve cancellation and keyboard navigation.

## Standalone recommendation and delivery boundary

Keep upstream as an optional read-only reference remote until parity work is complete. Native build is already independent of desktop C# sources. Establish one native source-of-truth directory, its own test fixtures/release workflow/version scheme, fork-controlled Sparkle feed and issue links, and preserve LICENSE and existing attribution files. After migration, stop automatically merging desktop upstream: selectively port reviewed behavior changes. Removing the upstream remote alone does not complete feature migration or release ownership.

Do not describe a thin collections screen plus notes/ignore/changelog as ALL features ported. The durable model, archive/index/rule pipeline, safe revision reconciliation, manual recovery, profile data round-trip and localization are separately observable behavior. Test with local fixture archives/API responses, temporary data directories and mocked launcher boundaries; do not mutate the user's real Mods, profiles, Keychain or Accessibility state.

## Build order and evidence

- First: durable backward-compatible profile/mod-source/collection models plus isolated data/storage and fixture tests.
- Second: validated collection/archive installation, ordering/config overlays, errors/cancellation/manual matching.
- Third: revision diff/resume/deletion/add-on semantics and collection UI.
- Fourth: portable profiles/notes/configs, ignore updates/changelog, bulk/column controls, NXM settings.
- Fifth: locale/theme parity and standalone native CI/updater assets.
- Parallel low-risk fixes: wrong migration Keychain service and input-helper keyUp/modifier handling (see `/tmp/starfruit-correctness-review.md`).

No native code was edited by this review agent. Source inspection establishes feature presence/absence; it is not a claim that live Nexus workflows or app UI were executed.

## Historical implementation handoff

These allocation notes record the initial work session. Final integration and
validation are documented in [merge-readiness.md](merge-readiness.md).

- correctness_review owns NexusClient, DownloadManager, Migration, RunApp.c, AnimationCancelManager and new NexusChangelog.swift. Implemented: typed/sorted Nexus changelog API; exact/latest collection revision metadata and mirror resolver; HTTP download validation, throwing installer result propagation, cancellation token/check contract; legacy login migration; synchronized trigger/lifecycle fixes. These changes require parent integration/typecheck and sibling installer implementation before being considered end-to-end verified.
- spec_review owns ModManager and new collection model/storage/manager/view files. Backend work in progress for portable profiles, source-aware mod identity, safe archives, durable collection records, manual matching and update lifecycle.
- standards_review owns ContentView/SettingsView/new UI files. UI work in progress for notes/ignored updates/changelog/profile controls and collection access.
- parent owns native build/release/Resources/localization, final compile/tests, ownership/docs and C# isolated merge.
- Presence of a new model/API is not completion of the associated feature: each acceptance condition above remains the closure criterion.
