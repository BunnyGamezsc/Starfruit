# Independent native correctness audit

**Final status: complete; no unresolved actionable findings in this audit's assigned scope.** The historical checkpoints below record findings while owners were implementing fixes. The final reinspection confirmed all eight original defects and all follow-on regressions reported here are resolved in source, including the final manual-resume profile context patch. The owner reports the expanded core regression suite passing 78 assertions; parent owns aggregate regressions and the fresh universal standalone build. This auditor performed read-only source/schema review, not live game/UI/network acceptance testing.

Read-only source audit of the current native implementation against upstream `9c5e145bf55af07cd735cfadbc65c5aa5309fef4`, reconstructed inventory, and authoritative C# collection/profile behavior. No live app, game, event tap, Keychain or user profile mutation. Findings were sent immediately to implementation owners; this is a moving-worktree checkpoint, not a claim of release approval.

## Concrete defects identified

1. **P1: Directory bundles lose their semantic root.** `CollectionManager.stageArchive` copied every directory's contents directly into its payload. A bundled mod `MyMod/manifest.json` consequently became `Mod-<entryID>`, and an overlay targeting `MyMod/config.json` missed it. A bundle directory holding only `config.json` lost `MyMod` entirely. Authoritative `MainWindowCollections.cs:1188-1234` preserves the folder for manifest or loose-only bundles, flattening only a container with subdirectories. Sent to `collections_finish`.
2. **P1: Extensionless collection identifiers can turn downloaded archives into loose files.** The original staging branch preferred `logicalFilename`/`fileExpression` over the chosen archive filename when deciding archive extraction. A valid ZIP with an extensionless logical identifier was copied as bytes, marked installed without a manifest, and composed as an overlay. Sent to `collections_finish`; archive detection must inspect payload or trust explicit archive source/selected filename while retaining actual loose-file semantics.
3. **P2: Revision resolution can race installation/removal.** `prepare` checked active IDs once, then awaited download/extraction without owning the collection ID. Other actions could mutate/delete the record underneath it. Owner has now added active-ID reservation and matching mutation guards; verify with final fixture suite.
4. **P2: Add-ons vanish with removed-mod preservation disabled.** Composition treated unpinned user add-ons as removed curator entries. Owner confirmed and is adding prior-pinned-aware retention.
5. **P2: Add-on pin guard checks the wrong revision during pending updates.** Guard used new target entries while destination pointed at the installed revision. This allowed overwriting old playable curator pins. Latest source now selects previous entries when target differs; fixture requested.
6. **P2: Imported config edits are reset on every launch.** New `prepareProfileForLaunch` writes immutable imported preserved configurations every time, while no lifecycle path updates the stored snapshots. A GMCM edit made in-game is overwritten on the next launch. Sent to `collections_finish`; capture changes for the launched profile or consume imported defaults once.
7. **P2: Ignoring updates leaks across profiles.** Shared `ModEntry.hasUpdate` includes current-profile ignore state. Ignoring in A suppresses the badge in B until checking again. Sent to parent: keep raw availability separate from per-profile ignore display.
8. **P2: Suggested update URLs are discarded.** Native decodes SMAPI suggested URL but retained only version and offered original Nexus page. GitHub/unofficial/moved updates lack the authoritative target. Sent to parent for model/UI wiring.

## Verified earlier corrections

- Curator overlays are applied after preserved user configs, in resolved overlay order.
- Same-revision rebuild now preserves user files from the installed revision.
- Installed revision remains selected for ordinary loading while a target revision is pending.
- Current collection/profile identities separate physical sources and ordinary copies; collection delete checks dependent profile references.

## Remaining parity work communicated to owners

- Profile-scoped `SMAPI-config.json` suppression of pinned collection update checks, with upstream's default-on setting.
- Automatic latest-revision check after Nexus connection; reuse unchanged pinned payloads during updates.
- Independently configurable collection installation root.
- Normal NXM extra-mod destination chooser for an active collection profile (archive add-on import exists).
- Latest owner reports collection sort/missing-only/Open Missing/manual-drop support was added after the initial UI observation; do not repeat that observation as an unresolved finding.

Final owner tests and final-source reinspection must resolve each checkpoint above before claiming literal full feature parity.

## Final-source recheck (later checkpoint)

Reinspected the eight original findings after the implementation owners' changes. All eight have source-level fixes: directory bundle staging retains roots; shared payload staging handles extensionless ZIP names; resolving owns/guards mutation; prior pinned IDs distinguish add-ons; pending revision uses installed pin references; game-exit/before-launch config capture exists; availability is independent of profile ignore; suggested update URLs are retained and exposed. The parent also wired the Nexus connection hook, storage setting, default-on SMAPI suppression, and add-on-target preference. Unchanged entry payloads are now reused across revisions.

Additional issues found during that recheck:

- Default collection-root add-on collision bypass (blanket `/Collections/` existing-mod exclusion) is now fixed with destination-relative legacy exclusion; owner adding fixture.
- Storage relocation mutation races now guard all public mutators during resolving.
- Optimistic launch state no longer clears config capture before the game has actually been observed. App termination now captures launched configs.
- Export preserves an inactive profile's own config snapshot instead of overwriting it with another profile's shared disk state.
- Sent the final staging endpoint edge to owner: a direct/browse `/download` URL must respect explicit loose `logicalFilename=config.json`.
- Sent parent the copied-profile replacement source issue: normal ZIP/NXM replacement must explicitly change the editable profile's source reference, otherwise it keeps using its retained collection copy.
- Sent parent the running-game storage move guard: moving/deleting the old root must not invalidate active SMAPI staging symlinks during play.

Deletion recovery actually exists as **Remove Collection, Keep Mods**, which converts the generated profile into an editable profile and leaves copies/source references playable. **Remove Collection and Files** refuses deletion with dependent profile names. Copy preserves notes/configs/source references while clearing generated-profile linkage and protection. No unsafe dependent cascade was found.

Validation scope: the reported 66-assertion suite compiles actual collection models, reference matching, profile models, storage, archive installation and isolated fixtures. It does not compile CollectionManager or ModManager, so lifecycle/dispatch conclusions here are source audit results, not app runtime test results. Parent is running the aggregate suite and app build separately. No new live-state testing was performed by this auditor.

### Final resolution checks

Latest source also confirms the final endpoint naming fixture/fix, the editable copied-profile UUID captured for ordinary NXM and drop replacement, and backend rejection of storage relocation while the game runs/launches. New regression fixtures explicitly exercise an add-on basename collision with a pinned different ID and loose direct endpoint naming. One last dispatch context edge was sent to `nxm_collection_target`: a resumed manual task's explicit nil `autoEnableInProfileID` should remain nil instead of adopting the newly selected profile. Aside from that final small dispatch check, no remaining concrete blocker was identified in this recheck's assigned scope.

Final dispatch reinspection: `DownloadManager.startOrResumeDownload` now leaves every queued manual installation context unchanged, including explicit nil profile ownership; the resume-time profile assignment was removed. Associated download regression fixtures now cover retained original profile context. This closes the final pending item above.

Signoff scope is native collection index parsing, bundle/direct/manual staging, order/config composition, revision/payload reuse, add-on pin protection and preservation, storage relocation guards, profile portability/copy/protection/config lifecycle, update URL/ignore behavior, and deletion dependency safety. It is not an assertion that every historical C# feature, every remote Nexus payload, macOS permission interaction, or every live game configuration has been exercised. No additional concrete new-194-feature regression was identified after final fixes.
