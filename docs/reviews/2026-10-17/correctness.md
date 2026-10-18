# Correctness review: Starfruit native and committed fork

Reviewed frozen committed fork 95da4f8, its dirty native worktree, and auto-merged C# against upstream 9c5e145. Read-only source review; no live app launch or live data mutation. Paths below refer to original dirty workspace unless integration stated. Findings are independent of the parent agents' collection/profile correctness review.

## Actionable findings

### [P2] Migrate the Keychain service actually used by the previous release
- Origin: dirty/untracked `Migration.swift`; committed predecessor stores the key in a different service.
- Location: `Stardrop/StardropMacNative/Sources/Migration.swift:98-105` (and oldBundleId at line 5).
- Trigger: upgrade from committed native build with a saved Nexus API key.
- Evidence: `git show 95da4f8:Stardrop/StardropMacNative/Sources/KeychainHelper.swift` line 5 uses `com.starfruit.native`; migration queries `com.starfruit.macnative`, which is the old bundle ID, not the old Keychain service. New helper reads `com.bunnygamez.starfruit`.
- Impact: every existing saved key is missed and user appears logged out; cached currentUser can still show connected/premium while API requests fail for no key. The one-time done flag then prevents retry.
- Fix: explicitly migrate `com.starfruit.native` to `KeychainHelper.service`, preserving an existing destination item, and mark migration complete only after recoverable migration failures have been accounted for.

### [P2] Stop keyboard repeat only on release of the assigned trigger key
- Origin: dirty/untracked RunApp.c.
- Location: `Stardrop/StardropMacNative/Sources/RunApp.c:160-164`.
- Trigger: assign a keyboard trigger, hold it, and release any other key while it is held.
- Evidence: callback never reads `kCGKeyboardEventKeycode` in keyUp branch; any keyUp clears both flags. Worker also posts R/ForwardDelete keyUp events (lines 65-67), so its own events can terminate the hold where observed by the session tap.
- Impact: repeat stops while trigger remains pressed; behavior is inconsistent with mouse hold and advertised keyboard hold.
- Fix: require keyUp code == gTriggerKeyCode and distinguish synthetic events if necessary.

### [P2] Process modifier releases before the mouse branch returns
- Origin: dirty/untracked RunApp.c.
- Location: `Stardrop/StardropMacNative/Sources/RunApp.c:140-141` (dead handler 168-175).
- Trigger: assign Ctrl+middle-click, hold mouse button, release Ctrl.
- Evidence: gUseMouseTrigger enters first branch and unconditionally returns before the flagsChanged handler below. The documented stop-on-modifier-release logic is unreachable for the only mode it accepts.
- Impact: synthetic clicks and animation-cancel keys continue after the configured chord is no longer down, until mouse release or focus shutdown.
- Fix: handle flagsChanged before the broad mouse branch or within it.

### [P2] Propagate failed extraction to download state
- Origin: committed native DownloadManager and installMod, unchanged failure handling in dirty code.
- Locations: `Stardrop/StardropMacNative/Sources/ModManager.swift:742-747`, `Stardrop/StardropMacNative/Sources/DownloadManager.swift:142-149`.
- Trigger: a download URL returns HTTP 403/404 with an HTML body, or a corrupt/unsupported archive downloads successfully at the transport layer.
- Evidence: delegate never checks HTTP status; installMod waits for unzip but never checks terminationStatus; it returns Void even after caught errors. Delegate then sets isCompleted=true unconditionally and deletes the downloaded file.
- Impact: an installation that produced no mods is shown as successful, including collection manual retry state, and its original archive is destroyed.
- Fix: check HTTP response, make extraction return/throw failure, check unzip terminationStatus, set per-task error and retain retry context rather than marking completed.

### [P1] Keep native launch when adding the C# Wine path
- Origin: committed fork; automatically retained by upstream merge. This applies to desktop C# product only, not native Swift product.
- Location: `Stardrop/Utilities/External/SMAPI.cs:50-51`.
- Trigger: choose ordinary macOS Stardew/SMAPI installation with StardewModdingAPI.dll and native executable, no Windows StardewModdingAPI.exe.
- Evidence: Pathing.GetSmapiPath still accepts native DLL, settings picker advertises DLL, but every macOS run creates a script executing `wine StardewModdingAPI.exe`. Confirmed installed native app contains DLL/native executable and no Windows exe (read-only file inventory).
- Impact: all normal native macOS installs fail to launch through desktop app; Wine may also be absent.
- Fix: branch on explicit Wine mode or detected executable type and retain native launch path. Given user clarified Swift native is product, retain as historical fork issue rather than spending migration effort on C#.

## Additional bounded observations

- The C# auto-merge keeps upstream collection update exclusion and fork GetVersion fallback; no lost fork logic seen there.
- Current installed native SMAPI executable is Intel Mach-O and StardewValley wrapper is a shell script. New SMAPIWrapper chooses Intel executable and Rosetta branch correctly for that installed shape; no speculative shell-format issue reported.
- Sparkle feed defaults to upstream Floogen/development native appcast path, while its files only exist in the fork, and public ED key is omitted unless environment supplied. Release readiness needs fork feed/key configuration; parent should resolve as standalone ownership work.
- No evidence established for a new exploitable archive path traversal; do not describe as confirmed vulnerability without a bounded malicious archive reproduction.

## Implementation status after expanded user authorization

Original native source changes now address wrong-service login migration (also versioned retry marker), unrelated/synthetic keyUp and mouse modifier release, shared-state C races and queued-start cancellation. DownloadManager now validates HTTP responses and propagates throwing installer/cancellation failures; matching ModManager staged extraction implementation is owned by spec_review. Added typed Nexus changelog/collection metadata APIs and stale-login validation generation guard. C# native/Wine historical finding remains outside clarified native product scope. Source parse/C syntax checks passed; final app typecheck and runtime fixture checks pending at this timestamp.
