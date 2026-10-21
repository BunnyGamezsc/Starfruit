import Foundation
import Combine

@MainActor
final class CollectionManager: ObservableObject {
    @Published private(set) var records: [NativeCollection]
    @Published var selectedID: String?
    @Published private(set) var activeIDs: Set<String> = []
    @Published private(set) var isResolving = false
    @Published var status: String?
    @Published var error: String?
    @Published private(set) var storage: CollectionStorage
    private weak var modManager: ModManager?
    private var jobs: [String: Task<Void, Never>] = [:]
    private var resolver: Task<Void, Never>?
    var collections: [NativeCollection] { records.filter { !$0.isDetached } }
    private var hasCheckedConnection = false

    func importLegacyInstallations(mods: [ModEntry], profiles: [ModProfile]) throws -> LegacyCollectionImport {
        let imported = try LegacyCollectionMigration.run(mods: mods, profiles: profiles, storage: storage)
        records = imported.records
        return imported
    }

    func useImportedCollection(_ id: String) {
        guard let record = records.first(where: { $0.id == id && $0.isLegacyImport }) else { return }
        if let profile = modManager?.profiles.first(where: { $0.collectionSourceID == id }) {
            modManager?.selectedProfileID = profile.id
        }
        modManager?.syncCollectionProfile(record)
        modManager?.reloadCurrentModDirectories()
    }

    func nexusConnectionChanged(isConnected: Bool, nexusClient: NexusClient) {
        if !isConnected { hasCheckedConnection = false; return }
        guard !hasCheckedConnection else { return }
        hasCheckedConnection = true
        checkForUpdates(nexusClient: nexusClient)
    }

    func changeStorageRoot(to target: URL) async throws {
        guard activeIDs.isEmpty, !isResolving else { throw CollectionError.invalid("Wait for collection operations to finish before moving storage.") }
        guard modManager?.isGameRunning != true, modManager?.isLaunching != true else { throw CollectionError.invalid("Stop the game before moving collection storage.") }
        isResolving = true
        defer { isResolving = false }
        let oldStorage = storage
        let relocated = try await Task.detached { try oldStorage.relocated(to: target) }.value
        storage = relocated
        UserDefaults.standard.set(relocated.root.path, forKey: "nativeCollectionStorageRoot")
        modManager?.reloadCurrentModDirectories()
        // Remove the original only after the complete replacement is available and selected.
        if oldStorage.root.standardizedFileURL != relocated.root.standardizedFileURL { try? FileManager.default.removeItem(at: oldStorage.root) }
        status = "Collection storage moved to \(relocated.root.path)."
    }

    init(modManager: ModManager, storage: CollectionStorage = CollectionStorage()) {
        self.modManager = modManager
        self.storage = storage
        self.records = storage.load()
        // In-flight network tasks cannot survive app termination; make their persisted entries retryable.
        for index in records.indices {
            for entry in records[index].entries.indices where records[index].entries[entry].status == .downloading {
                records[index].entries[entry].status = .pending
            }
        }
    }

    func importCollection(link: String, nexusClient: NexusClient) {
        guard !isResolving else { return }
        error = nil
        isResolving = true
        resolver = Task { [weak self] in
            guard let self else { return }
            defer { self.isResolving = false; self.resolver = nil }
            do {
                let parsed = try Self.parseLink(link)
                try await self.prepare(slug: parsed.slug, revision: parsed.revision, nexusClient: nexusClient)
                self.status = "Collection ready. Review optional files, then install."
            } catch is CancellationError {
                self.status = "Collection import cancelled."
            } catch { self.error = error.localizedDescription }
        }
    }

    func cancelImport() { resolver?.cancel() }

    private func prepare(slug: String, revision: Int?, nexusClient: NexusClient) async throws {
        let metadata = try await nexusClient.fetchCollectionRevision(slug: slug, revision: revision)
        try Task.checkCancellation()
        let id = "stardewvalley-\(slug)"
        if let existing = records.first(where: { $0.id == id && $0.revision == metadata.revisionNumber && !$0.isDetached }) {
            selectedID = existing.id
            return
        }
        guard !activeIDs.contains(id) else { throw CollectionError.invalid("Cancel the current installation before choosing another revision.") }
        activeIDs.insert(id)
        defer { activeIDs.remove(id) }
        let archiveURL = try await nexusClient.resolveCollectionArchiveLink(metadata.downloadLink)
        let temporary = try await download(archiveURL)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let directory = try storage.directory(id).appendingPathComponent("revisions/\(metadata.revisionNumber)", isDirectory: true)
        let indexRoot = directory.appendingPathComponent("Index", isDirectory: true)
        if FileManager.default.fileExists(atPath: indexRoot.path) { try FileManager.default.removeItem(at: indexRoot) }
        try await extract(temporary, into: indexRoot)
        try Task.checkCancellation()
        guard let indexURL = Self.findFile("collection.json", in: indexRoot) else {
            throw CollectionError.invalid("No collection.json was found in the downloaded collection archive.")
        }
        var record = try NativeCollection.readIndex(Data(contentsOf: indexURL), metadata: metadata)
        if let previous = records.first(where: { $0.id == id }) {
            record.installedRevision = previous.installedRevision
            record.legacyModsDirectory = previous.legacyModsDirectory
            record.previousEntries = previous.installedRevision == previous.revision ? previous.entries : previous.previousEntries
            record.preserveRemovedMods = previous.preserveRemovedMods
            record.carryForwardSelections(from: previous)
            for index in record.entries.indices {
                if let old = previous.entries.first(where: { $0.id == record.entries[index].id || ($0.modID != nil && $0.modID == record.entries[index].modID) }) {
                    if record.entries[index].canReusePayload(from: old) {
                        let oldPayload = try storage.revisionDirectory(previous).appendingPathComponent("Payloads/\(old.id)")
                        let newPayload = directory.appendingPathComponent("Payloads/\(old.id)")
                        if FileManager.default.fileExists(atPath: oldPayload.path), oldPayload != newPayload {
                            try FileManager.default.createDirectory(at: newPayload.deletingLastPathComponent(), withIntermediateDirectories: true)
                            if FileManager.default.fileExists(atPath: newPayload.path) { try FileManager.default.removeItem(at: newPayload) }
                            try FileManager.default.copyItem(at: oldPayload, to: newPayload)
                            record.entries[index].status = .installed
                            record.entries[index].installedMods = old.installedMods
                        }
                    }
                }
            }
        }
        try storage.save(record)
        if let index = records.firstIndex(where: { $0.id == id }) { records[index] = record }
        else { records.append(record) }
        selectedID = id
    }

    func setOptional(collectionID: String, entryID: String, selected: Bool) {
        guard !isResolving, !activeIDs.contains(collectionID), let index = records.firstIndex(where: { $0.id == collectionID }),
              let entry = records[index].entries.firstIndex(where: { $0.id == entryID }), records[index].entries[entry].optional else { return }
        records[index].entries[entry].selected = selected
        records[index].entries[entry].status = selected ? .pending : .skipped
        records[index].resolveRequiredSelections()
        if !selected && records[index].entries[entry].selected { status = "That optional file is required by another selected mod." }
        persist(index)
    }

    func setPreserveRemovedMods(_ id: String, preserve: Bool) {
        guard !isResolving, !activeIDs.contains(id), let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].preserveRemovedMods = preserve
        persist(index)
    }

    func addAddonArchive(_ archive: URL, collectionID: String) {
        guard !isResolving, !activeIDs.contains(collectionID), jobs[collectionID] == nil else { return }
        jobs[collectionID] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs[collectionID] = nil }
            do { try await self.installAddonArchive(archive, collectionID: collectionID) }
            catch is CancellationError { self.status = "Add-on installation cancelled." }
            catch { self.error = error.localizedDescription }
        }
    }

    func installAddonArchive(_ archive: URL, collectionID: String, cancellationCheck: @escaping @Sendable () throws -> Void = {}) async throws {
        guard !isResolving, !activeIDs.contains(collectionID), let record = records.first(where: { $0.id == collectionID }), record.installedRevision != nil else {
            throw CollectionError.invalid("Wait for collection operations to finish before installing an add-on.")
        }
        activeIDs.insert(collectionID)
        defer { activeIDs.remove(collectionID) }
        let scoped = archive.startAccessingSecurityScopedResource()
        defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
        let destination = try storage.modsDirectory(record)
        if record.hasLegacyInstalledCopy, FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) {
            throw CollectionError.invalid("This older archive installed a mod at the collection folder's root. Review a Nexus revision or install extra mods normally in an editable profile copy.")
        }
        let pinnedEntries = record.installedRevision == record.revision ? record.entries : record.previousEntries ?? record.entries
        let pinned = Set(pinnedEntries.flatMap(\.installedMods).map { $0.uniqueID.lowercased() })
        let work = Task.detached(priority: .userInitiated) {
            try CollectionStorage.installOrdinaryArchive(archive, destination: destination, protectedModIDs: pinned, cancellationCheck: {
                try Task.checkCancellation()
                try cancellationCheck()
            })
        }
        let installed = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        modManager?.enableCollectionAddons(sourceID: collectionID, ids: installed)
        modManager?.reloadCurrentModDirectories()
        status = "Collection add-on installed. It will be preserved during revision updates."
    }

    func install(_ id: String, nexusClient: NexusClient) {
        guard !isResolving, !activeIDs.contains(id) else { return }
        guard records.first(where: { $0.id == id })?.isLegacyImport != true else {
            error = "This installed copy is already available. Review a Nexus revision before installing an update."
            return
        }
        error = nil
        activeIDs.insert(id)
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs[id] = nil; self.activeIDs.remove(id) }
            do {
                try await self.installEntries(id, nexusClient: nexusClient)
            } catch is CancellationError {
                self.status = "Collection installation cancelled. Completed files remain available to resume."
                self.resetDownloading(id)
            } catch {
                self.error = error.localizedDescription
                self.resetDownloading(id)
            }
        }
    }

    func cancel(_ id: String) { jobs[id]?.cancel() }

    private func installEntries(_ id: String, nexusClient: NexusClient) async throws {
        guard let record = records.first(where: { $0.id == id }) else { return }
        let order = try record.orderedEntryIDs()
        for entryID in order {
            try Task.checkCancellation()
            guard let entry = currentEntry(id, entryID), entry.status != .installed else { continue }
            if entry.source == .nexus && nexusClient.currentUser?.is_premium != true {
                updateEntry(id, entryID) { $0.status = .manual; $0.failure = "Open the pinned file's Nexus page, then choose its downloaded archive." }
                continue
            }
            if entry.source == .browse {
                updateEntry(id, entryID) { $0.status = .manual; $0.failure = "This file requires a browser download." }
                continue
            }
            do {
                updateEntry(id, entryID) { $0.status = .downloading; $0.failure = nil }
                let archive: URL
                if entry.source == .bundle {
                    guard let bundled = try bundledFile(entry, collection: record) else {
                        throw CollectionError.invalid("Bundled file not found: \(entry.name)")
                    }
                    archive = bundled
                } else {
                    let remote: URL
                    if entry.source == .nexus {
                        guard let modID = entry.modID, let fileID = entry.fileID else { throw CollectionError.invalid("Nexus entry is missing its pinned file ID.") }
                        let (link, reason) = await nexusClient.getFileDownloadLink(modID: modID, fileID: fileID)
                        guard let link else { throw CollectionError.invalid(reason ?? "Nexus did not return a file download link.") }
                        remote = link
                    } else {
                        guard let link = entry.url, ["https", "http"].contains(link.scheme?.lowercased() ?? "") else { throw CollectionError.invalid("Invalid direct file URL.") }
                        remote = link
                    }
                    archive = try await download(remote)
                }
                defer { if entry.source != .bundle { try? FileManager.default.removeItem(at: archive) } }
                try Task.checkCancellation()
                try await stageArchive(archive, collectionID: id, entryID: entryID)
            } catch is CancellationError { throw CancellationError() }
            catch {
                updateEntry(id, entryID) { $0.status = entry.pageURL == nil ? .failed : .manual; $0.failure = error.localizedDescription }
            }
        }
        try Task.checkCancellation()
        try await finishIfReady(id)
        status = records.first(where: { $0.id == id })?.isComplete == true ? "Collection installed." : "Some files need a manual download. Open their file pages and select the archives below."
    }

    /// An explicitly chosen file is validated against the curator's checksum before it is admitted.
    func installManualArchive(_ archive: URL, collectionID: String, entryID: String, nexusClient: NexusClient) {
        guard !isResolving, !activeIDs.contains(collectionID) else { return }
        error = nil
        activeIDs.insert(collectionID)
        jobs[collectionID] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs[collectionID] = nil; self.activeIDs.remove(collectionID) }
            let scoped = archive.startAccessingSecurityScopedResource()
            defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
            do {
                try await self.stageArchive(archive, collectionID: collectionID, entryID: entryID)
                try await self.installEntries(collectionID, nexusClient: nexusClient)
            } catch is CancellationError { self.resetDownloading(collectionID) }
            catch { self.error = error.localizedDescription; self.resetDownloading(collectionID) }
        }
    }

    /// A drop has no selected file identity: only the curator's exact checksum can admit it automatically.
    func acceptManualArchives(_ archives: [URL], collectionID: String, nexusClient: NexusClient) {
        guard !isResolving, !activeIDs.contains(collectionID) else { return }
        error = nil
        activeIDs.insert(collectionID)
        jobs[collectionID] = Task { [weak self] in
            guard let self else { return }
            defer { self.jobs[collectionID] = nil; self.activeIDs.remove(collectionID) }
            do {
                var accepted = 0
                for archive in archives {
                    let scoped = archive.startAccessingSecurityScopedResource()
                    defer { if scoped { archive.stopAccessingSecurityScopedResource() } }
                    try Task.checkCancellation()
                    let checksum = try await Task.detached { try CollectionStorage.checksum(archive) }.value
                    let matches = self.records.first { $0.id == collectionID }?.entries.filter {
                        $0.selected && $0.status != .installed && $0.checksum?.caseInsensitiveCompare(checksum) == .orderedSame
                    } ?? []
                    guard !matches.isEmpty else {
                        throw CollectionError.invalid("\(archive.lastPathComponent) does not match the checksum of a missing collection file. Use that entry's Choose Archive button when its curator supplied no checksum.")
                    }
                    for entry in matches { try await self.stageArchive(archive, collectionID: collectionID, entryID: entry.id); accepted += 1 }
                }
                try await self.installEntries(collectionID, nexusClient: nexusClient)
                self.status = "Matched \(accepted) collection file(s). " + (self.status ?? "")
            } catch is CancellationError { self.resetDownloading(collectionID) }
            catch { self.error = error.localizedDescription; self.resetDownloading(collectionID) }
        }
    }

    /// Per-file NXM tokens permit free accounts to finish a collection without downloading a different file.
    func handleFileLink(_ url: URL, nexusClient: NexusClient) -> Bool {
        guard url.host?.lowercased() == "stardewvalley" else { return false }
        let components = url.pathComponents
        guard let modIndex = components.firstIndex(of: "mods"), components.indices.contains(modIndex + 1), let modID = Int(components[modIndex + 1]),
              let fileIndex = components.firstIndex(of: "files"), components.indices.contains(fileIndex + 1), let fileID = Int(components[fileIndex + 1]) else { return false }
        let matches = records.flatMap { collection in collection.entries.filter { $0.selected && $0.status != .installed && $0.modID == modID && $0.fileID == fileID }.map { (collection.id, $0.id) } }
        guard !matches.isEmpty else { return false }
        guard !isResolving else { error = "Wait for the collection operation to finish, then open the download link again."; return true }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let key = query.first(where: { $0.name == "key" })?.value
        let expires = query.first(where: { $0.name == "expires" })?.value
        for (id, entryID) in matches where !activeIDs.contains(id) {
            activeIDs.insert(id)
            jobs[id] = Task { [weak self] in
                guard let self else { return }
                defer { self.jobs[id] = nil; self.activeIDs.remove(id) }
                do {
                    let (link, reason) = await nexusClient.getFileDownloadLink(modID: modID, fileID: fileID, nxmKey: key, nxmExpires: expires)
                    guard let link else { throw CollectionError.invalid(reason ?? "Could not resolve the pinned download.") }
                    let archive = try await self.download(link)
                    defer { try? FileManager.default.removeItem(at: archive) }
                    try await self.stageArchive(archive, collectionID: id, entryID: entryID)
                    try await self.installEntries(id, nexusClient: nexusClient)
                } catch is CancellationError { self.resetDownloading(id) }
                catch { self.error = error.localizedDescription; self.resetDownloading(id) }
            }
        }
        return true
    }

    func checkForUpdates(nexusClient: NexusClient) {
        Task {
            for collection in collections where !activeIDs.contains(collection.id) {
                do {
                    let latest = try await nexusClient.fetchCollectionRevision(slug: collection.slug, revision: nil)
                    guard let index = records.firstIndex(where: { $0.id == collection.id }) else { continue }
                    records[index].latestRevision = latest.revisionNumber
                    persist(index)
                } catch { self.error = error.localizedDescription }
            }
            status = "Collection revision check finished."
        }
    }

    func prepareUpdate(_ id: String, nexusClient: NexusClient) {
        guard let collection = records.first(where: { $0.id == id }) else { return }
        importCollection(link: "nxm://stardewvalley/collections/\(collection.slug)", nexusClient: nexusClient)
    }

    func remove(_ id: String, deleteFiles: Bool) {
        guard !isResolving, !activeIDs.contains(id), let index = records.firstIndex(where: { $0.id == id }) else { return }
        do {
            if deleteFiles {
                guard !records[index].hasLegacyInstalledCopy else { throw CollectionError.invalid("Imported mod files remain in the older installation. Use Remove Collection, Keep Mods to preserve that installation.") }
                let dependent = modManager?.profiles.filter { $0.collectionSourceID != id && $0.modSources.values.contains(id) } ?? []
                guard dependent.isEmpty else { throw CollectionError.invalid("This collection is used by: \(dependent.map(\.name).joined(separator: ", ")). Remove those references before deleting its files.") }
                try storage.remove(id)
                records.remove(at: index)
                modManager?.removeCollectionProfile(sourceID: id, keepMods: false)
            } else {
                records[index].isDetached = true
                try storage.save(records[index])
                modManager?.removeCollectionProfile(sourceID: id, keepMods: true)
            }
            modManager?.reloadCurrentModDirectories()
        } catch { self.error = error.localizedDescription }
    }

    private func stageArchive(_ archive: URL, collectionID: String, entryID: String) async throws {
        guard let record = records.first(where: { $0.id == collectionID }), let entry = currentEntry(collectionID, entryID) else { return }
        if let expected = entry.checksum, !expected.isEmpty {
            let actual = try await Task.detached { try CollectionStorage.checksum(archive) }.value
            guard expected.caseInsensitiveCompare(actual) == .orderedSame else { throw CollectionError.invalid("Checksum mismatch for \(entry.name). Download the exact file pinned by this revision.") }
        }
        try Task.checkCancellation()
        let revisionRoot = try storage.revisionDirectory(record)
        let payload = revisionRoot.appendingPathComponent("Payloads/\(entryID)", isDirectory: true)
        if FileManager.default.fileExists(atPath: payload.path) { try FileManager.default.removeItem(at: payload) }
        let work = Task.detached(priority: .userInitiated) {
            try CollectionStorage.stagePayload(archive, entry: entry, into: payload, cancelled: { Task.isCancelled })
        }
        try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        let manifests = CollectionStorage.manifests(in: payload)
        let refs = manifests.map { manifest, folder in
            CollectionModReference(uniqueID: manifest.UniqueID, folder: folder.path.replacingOccurrences(of: payload.path + "/", with: ""))
        }
        // Payloads are composed only after all selected archives are available, preserving rule order for manual files too.
        updateEntry(collectionID, entryID) { $0.status = .installed; $0.failure = nil; $0.installedMods = refs }
    }

    private func finishIfReady(_ id: String) async throws {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isComplete else { return }
        let record = records[index]
        let destination = try storage.modsDirectory(record, pending: true)
        let candidate = destination.deletingLastPathComponent().appendingPathComponent("Composed-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: candidate) }
        let revisionRoot = try storage.revisionDirectory(record)
        let previous = try record.installedRevision.map { _ in
            try storage.modsDirectory(record)
        }
        let retainedIDs = Set((modManager?.profiles ?? []).filter { $0.collectionSourceID != id }.flatMap { profile in
            profile.modSources.filter { $0.value == id }.map(\.key)
        }.map { $0.lowercased() })
        let work = Task.detached(priority: .userInitiated) {
            try CollectionStorage.compose(record, revisionRoot: revisionRoot, into: candidate, previous: previous, retainedIDs: retainedIDs, cancelled: { Task.isCancelled })
        }
        let installed = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        try Task.checkCancellation()
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: candidate)
        } else { try manager.moveItem(at: candidate, to: destination) }
        guard let current = records.firstIndex(where: { $0.id == id }) else { return }
        records[current].installedRevision = record.revision
        for entry in records[current].entries.indices {
            if let references = installed[records[current].entries[entry].id] { records[current].entries[entry].installedMods = references }
        }
        records[current].updatedAt = Date()
        try storage.save(records[current])
        modManager?.syncCollectionProfile(records[current])
        records[current].previousEntries = nil
        try storage.save(records[current])
        modManager?.reloadCurrentModDirectories()
    }

    private func bundledFile(_ entry: NativeCollectionEntry, collection: NativeCollection) throws -> URL? {
        let root = try storage.revisionDirectory(collection).appendingPathComponent("Index", isDirectory: true)
        let names = [entry.fileExpression, entry.logicalFilename].compactMap { $0 }.filter { !$0.isEmpty }
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var candidates: [URL] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.lastPathComponent.lowercased() != "collection.json" else { continue }
            if names.contains(where: { CollectionReferenceMatcher.bundleMatches(file.lastPathComponent, expression: $0) }) { candidates.append(file) }
        }
        return candidates.sorted { left, right in
            let archives: Set<String> = ["zip", "7z", "rar", "tar", "gz", "bz2", "xz"]
            let leftArchive = archives.contains(left.pathExtension.lowercased())
            let rightArchive = archives.contains(right.pathExtension.lowercased())
            return leftArchive != rightArchive ? leftArchive : left.path < right.path
        }.first
    }

    private func download(_ url: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(for: URLRequest(url: url))
        do {
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw CollectionError.invalid("The file server did not return a successful download.")
            }
            let retained = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".archive")
            try FileManager.default.moveItem(at: temporary, to: retained)
            return retained
        } catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }

    private func extract(_ archive: URL, into destination: URL) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try NativeArchiveInstaller.extract(archive, to: destination, cancelled: { Task.isCancelled })
        }
        try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private func currentEntry(_ collectionID: String, _ entryID: String) -> NativeCollectionEntry? {
        records.first(where: { $0.id == collectionID })?.entries.first(where: { $0.id == entryID })
    }

    private func updateEntry(_ id: String, _ entryID: String, change: (inout NativeCollectionEntry) -> Void) {
        guard let collection = records.firstIndex(where: { $0.id == id }), let entry = records[collection].entries.firstIndex(where: { $0.id == entryID }) else { return }
        change(&records[collection].entries[entry])
        persist(collection)
    }

    private func persist(_ index: Int) {
        do { try storage.save(records[index]) } catch { self.error = error.localizedDescription }
    }

    private func resetDownloading(_ id: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        for entry in records[index].entries.indices where records[index].entries[entry].status == .downloading {
            records[index].entries[entry].status = .cancelled
        }
        persist(index)
    }

    private static func findFile(_ name: String, in root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL { if file.lastPathComponent.lowercased() == name { return file } }
        return nil
    }

    private static func parseLink(_ link: String) throws -> (slug: String, revision: Int?) {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["nxm", "https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw CollectionError.invalid("Paste a Nexus collection link.") }
        let parts = url.pathComponents
        let isNXM = url.scheme?.lowercased() == "nxm"
        let domainValid = isNXM ? url.host?.lowercased() == "stardewvalley" :
            (["www.nexusmods.com", "nexusmods.com", "next.nexusmods.com"].contains(url.host?.lowercased() ?? "") && parts.contains("stardewvalley"))
        guard domainValid, let index = parts.firstIndex(where: { $0 == "collections" || $0 == "collection" }), parts.indices.contains(index + 1) else {
            throw CollectionError.invalid("Only Stardew Valley Nexus collection links are supported.")
        }
        let slug = parts[index + 1].lowercased()
        guard !slug.isEmpty, slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw CollectionError.invalid("Invalid collection slug.") }
        var revision: Int?
        if let position = parts.firstIndex(where: { $0 == "revisions" || $0 == "revision" }) {
            guard parts.indices.contains(position + 1), let value = Int(parts[position + 1]), value > 0 else { throw CollectionError.invalid("Invalid collection revision.") }
            revision = value
        }
        return (slug, revision)
    }
}
