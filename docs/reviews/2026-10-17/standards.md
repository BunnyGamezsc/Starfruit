# Standards review — Starfruit fork and existing local work

## Scope and evidence

Read-only review of this repository.
Committed scope: `fdea35d4f97870a0deb83fb28c5f014184318307...95da4f8de90ed706a1a9a00020157872c56d1877` (four fork commits). Committed line references below refer to `95da4f8`, not a future merge.
Local scope: tracked modifications in native Swift/build sources and untracked Swift/C implementation files visible before the merge; binaries, `.serena`, generated IR, and third-party files excluded. Local line references refer to the existing working tree examined on 2026-10-17.

Repository standards consulted:
- `CONTRIBUTING.md:1`: issue reports should attach a log. This is a reporting requirement, not a source-code logging standard.
- `README.md:3`: cross-platform Avalonia mod manager; line 7: profiles support multiple mod groups. These are behavior claims handled primarily by the Spec review.
- `Stardrop/StardropMacNative/AGENTS.md:4`: prefix shell commands with `rtk`. Review commands complied.
No `CODING_STANDARDS` was identified. the `write-swift` skill informed Swift reasoning; its modern Swift preferences are not treated as repository mandates. Context-mode tools were unavailable, so commands used bounded output with `rtk proxy`.

## Documented rule violations

None established on the Standards axis. This does not assert that behavior is correct. In particular, the README's cross-platform/profile claims require the separate Spec review.

## Possible smells — committed scope

### 1. Duplicated Code: centralize manifest normalization and decoding
Location: `Stardrop/StardropMacNative/Sources/ModManager.swift:572` (committed), duplicated at 495–518. Current local counterparts remain at 683–706 and 757–772.
Hunk quote: `jsonString = jsonString.replacingOccurrences(of: "\r\n", with: "\n")` and `let blockCommentPattern = "/\\*[\\s\\S]*?\\*/"`.

`loadMods` and post-extraction auto-enabling independently implement the same encoding fallback, newline conversion, block-comment stripping, line-comment filtering, schema renaming, and `ModManifest` decoding. Any future manifest compatibility fix must be applied twice. Drift means a mod may appear in the catalog but fail auto-enabling, or the inverse. Extract one manifest-reader function that accepts a file URL and returns the decoded manifest or a diagnostic error. This is a possible maintainability finding, not a documented rule violation.

### 2. Data Clumps / Shotgun Surgery: own installation configuration in one type
Location: `Stardrop/StardropMacNative/Sources/ModManager.swift:283` (committed); repeated at 683–690. Related signature: `Stardrop/StardropMacNative/Sources/DownloadManager.swift:46` and 94.
Hunk quote: `let useWine = UserDefaults.standard.bool(forKey: "useWine")` followed by four directory-key lookups and a native/Wine selection.

The same persistence keys, defaults, and mode selection are spread across views, single-mod downloads, collections, and a long list of install-related parameters. There is already an inconsistent default: the views declare `@AppStorage("useWine") ... = true`, while a direct `UserDefaults.bool` returns false for an absent key. A small settings owner should define defaults and expose an immutable installation destination, which downloads retain as one value. Do not merely wrap arguments while leaving selection logic duplicated. This possible smell is consequential because the wrong destination installs files outside the selected gameplay setup.

## Possible smells — existing uncommitted scope

### 3. Primitive Obsession / Data Clumps: make trigger assignment atomic
Location: `Stardrop/StardropMacNative/Sources/AnimationCancelManager.swift:205` (local), with declarations 37–67 and application 163–170.
Hunk quote: `triggerType = "key"`, then `triggerKeyCode = Int(event.keyCode)`; `triggerType`'s `didSet` invokes `applySettings()`.

Trigger kind, key code, button number, modifiers, and display text represent one domain value but are mutated as independent published properties. Every mutation can apply a partially updated configuration to C. A mouse assignment sets the key code to -1; changing its kind to key subsequently calls `UInt16(triggerKeyCode)` before the new key code is stored, trapping at runtime. Use a single typed trigger value (`key` or `mouse`, with its required associated data); persist and apply once after capture. This is a possible smell backed by a concrete correctness consequence. Parent was separately notified for the Spec/correctness report.

## Mandatory heuristic coverage

- Mysterious Name: no consequential finding; short variables are generally locally understandable.
- Duplicated Code: finding 1. Focus observer duplication alone was too small to warrant another finding.
- Feature Envy: no clear misplaced method; view-to-manager access is expected here.
- Data Clumps: findings 2 and 3.
- Primitive Obsession: finding 3; no proposal to wrap all strings/integers indiscriminately.
- Repeated Switches: game-identification predicates recur in status/stop paths and the new detector. The detector intentionally uses broader focus rules, so no forced consolidation is prescribed without clarifying that policy.
- Shotgun Surgery: finding 2.
- Divergent Change: ModManager now owns persistence, dependency decisions, extraction, game state, and HTTP collection/update handling. Potential future seam, but no separate finding based only on file size or number of methods.
- Speculative Generality: no consequential finding. The hardcoded collection dry-run is an unrelated correctness issue, not speculative abstraction.
- Message Chains: nested GraphQL response navigation is limited to decoding/collection code; no consequential finding.
- Middle Man: no consequential finding; launcher and keychain helpers own real integration work.
- Refused Bequest: no consequential finding; NSObject inheritance supports URLSession delegate integration.

## Correctness leads passed to parent

- Local trigger switching trap described in finding 3.
- Committed `ModManager.swift:674–677` skips all collection downloads for slug `tckf0m`, leaving an apparently imported empty collection profile. The existing local source removes this dry-run; report only against the committed scope.

No source files were edited and no tests/builds were run by this reviewer; parent owns merge and validation.
